//! Supervisor web local y snapshots acotados del camino de señal.

use std::{
    collections::{HashMap, VecDeque},
    fs,
    sync::{
        Arc, RwLock,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};

use axum::{
    Json, Router,
    extract::State,
    http::{HeaderValue, StatusCode, header},
    response::{Html, IntoResponse, Response},
    routing::get,
};
use serde::Serialize;
use tokio_util::sync::CancellationToken;

use crate::{
    config::{MoqConfig, SupervisorConfig},
    error::GatewayResult,
    ingest::IngestPacket,
    media::{AccessUnitKind, MediaObject},
    observability::EventLogger,
    routing::TrackId,
    scheduler::ScheduledObject,
    scheduler::SchedulerSnapshot,
};

const SNAPSHOT_SCHEMA_VERSION: u8 = 1;
const SIGNAL_ACTIVE_WINDOW: Duration = Duration::from_secs(3);
const RETRY_DELAY: Duration = Duration::from_secs(5);
const LATENCY_WINDOW_SAMPLES: usize = 4_096;

#[derive(Clone)]
struct WebState {
    monitor: Arc<SignalMonitor>,
    playback: PlaybackRuntime,
}

#[derive(Clone)]
struct PlaybackRuntime {
    input_preview_url: Option<String>,
    input_origin: Option<String>,
    output_relay_url: Option<String>,
    output_origin: Option<String>,
    namespaces: Vec<String>,
    fingerprint: Option<String>,
}

impl PlaybackRuntime {
    fn load(config: &SupervisorConfig, moq: &MoqConfig) -> Self {
        let input_preview_url = config.input_preview_url.as_ref().map(url::Url::to_string);
        let input_origin = config
            .input_preview_url
            .as_ref()
            .map(|url| url.origin().ascii_serialization());
        let mut subscriber_url = moq.relay_url.clone();
        let browser_relay = (subscriber_url.scheme() == "https").then(|| {
            subscriber_url.set_path("/watch");
            subscriber_url.set_query(None);
            subscriber_url.set_fragment(None);
            subscriber_url
        });
        let output_origin = browser_relay
            .as_ref()
            .map(|url| url.origin().ascii_serialization());
        let output_relay_url = browser_relay.as_ref().map(url::Url::to_string);
        let fingerprint = config
            .moq_fingerprint_path
            .as_ref()
            .and_then(|path| fs::read_to_string(path).ok())
            .map(|value| value.trim().to_ascii_lowercase())
            .filter(|value| is_sha256_hex(value));
        Self {
            input_preview_url,
            input_origin,
            output_relay_url,
            output_origin,
            namespaces: moq.namespace.split('/').map(str::to_owned).collect(),
            fingerprint,
        }
    }

    fn content_security_policy(&self) -> HeaderValue {
        let connect_origin = self.output_origin.as_deref().unwrap_or("");
        let frame_origin = self.input_origin.as_deref().unwrap_or("");
        let value = format!(
            "default-src 'self'; connect-src 'self' {connect_origin}; frame-src {frame_origin}; media-src 'self' blob:; img-src 'self'; style-src 'self'; script-src 'self'; base-uri 'none'; frame-ancestors 'none'"
        );
        HeaderValue::from_str(&value).unwrap_or_else(|_| {
            HeaderValue::from_static(
                "default-src 'self'; connect-src 'self'; frame-src 'none'; media-src 'self' blob:; img-src 'self'; style-src 'self'; script-src 'self'; base-uri 'none'; frame-ancestors 'none'",
            )
        })
    }
}

fn is_sha256_hex(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// Estado compartido de baja sobrecarga; nunca retiene payloads multimedia.
pub struct SignalMonitor {
    started_at: tokio::time::Instant,
    revision: AtomicU64,
    max_sources: usize,
    state: RwLock<MonitorState>,
}

impl SignalMonitor {
    /// Construye un monitor con el mismo límite de fuentes que la ingesta SRT.
    #[must_use]
    pub fn new(max_sources: usize) -> Self {
        Self {
            started_at: tokio::time::Instant::now(),
            revision: AtomicU64::new(0),
            max_sources,
            state: RwLock::new(MonitorState::new()),
        }
    }

    /// Actualiza contadores de ingesta sin conservar Stream ID ni payload.
    pub fn record_ingest(&self, packet: &IngestPacket) {
        let Ok(mut state) = self.state.try_write() else {
            return;
        };
        if !state.sources.contains_key(packet.connection_id.as_ref())
            && state.sources.len() >= self.max_sources
            && let Some(oldest) = state
                .sources
                .iter()
                .min_by_key(|(_, source)| source.last_seen)
                .map(|(connection_id, _)| connection_id.clone())
        {
            state.sources.remove(&oldest);
        }
        let source = state
            .sources
            .entry(packet.connection_id.to_string())
            .or_insert_with(|| SourceState {
                connection_id: packet.connection_id.to_string(),
                peer: packet.peer.to_string(),
                packets: 0,
                bytes: 0,
                last_seen: packet.received_at,
            });
        source.peer = packet.peer.to_string();
        source.packets = source.packets.saturating_add(1);
        source.bytes = source
            .bytes
            .saturating_add(usize_to_u64(packet.payload.len()));
        source.last_seen = packet.received_at;
        state.ingest_packets = state.ingest_packets.saturating_add(1);
        state.ingest_bytes = state
            .ingest_bytes
            .saturating_add(usize_to_u64(packet.payload.len()));
        state.last_ingest = Some(packet.received_at);
        drop(state);
        self.revision.fetch_add(1, Ordering::Relaxed);
    }

    /// Actualiza la última access unit de un Track sin copiar su payload.
    pub fn record_object(&self, object: &MediaObject) {
        let Ok(mut state) = self.state.try_write() else {
            return;
        };
        let track = &mut state.tracks[usize::from(object.group.track.id.value())];
        track.codec = Some(object.codec.as_str());
        track.program_number = Some(object.program_number);
        track.pid = Some(object.pid);
        track.group_id = Some(object.group.id);
        track.object_id = Some(object.object_id);
        track.kind = Some(access_unit_label(object.kind));
        track.pts_ns = object.pts_ns;
        track.dts_ns = object.dts_ns;
        track.objects = track.objects.saturating_add(1);
        track.bytes = track
            .bytes
            .saturating_add(usize_to_u64(object.payload.len()));
        track.last_seen = Some(object.received_at);
        state.demux_objects = state.demux_objects.saturating_add(1);
        state.demux_bytes = state
            .demux_bytes
            .saturating_add(usize_to_u64(object.payload.len()));
        state.last_demux = Some(object.received_at);
        drop(state);
        self.revision.fetch_add(1, Ordering::Relaxed);
    }

    /// Actualiza contadores del scheduler sin retener Objects ni bloquear el directo.
    pub fn record_scheduler(
        &self,
        snapshot: SchedulerSnapshot,
        activity_at: Option<tokio::time::Instant>,
    ) {
        let Ok(mut state) = self.state.try_write() else {
            return;
        };
        state.scheduler.snapshot = snapshot;
        if let Some(activity_at) = activity_at {
            state.scheduler.last_seen = Some(activity_at);
        }
        drop(state);
        self.revision.fetch_add(1, Ordering::Relaxed);
    }

    /// Marca una sesión real con el relay, sin conservar su URL completa.
    pub fn record_moq_connected(&self, connection_id: &str, relay: &str) {
        let Ok(mut state) = self.state.try_write() else {
            return;
        };
        state.moq.connected = true;
        state.moq.connection_id = Some(connection_id.to_owned());
        state.moq.relay = Some(relay.to_owned());
        drop(state);
        self.revision.fetch_add(1, Ordering::Relaxed);
    }

    /// Cuenta un Object realmente entregado al writer upstream de `moq-rs`.
    pub fn record_moq_object(&self, object: &ScheduledObject) {
        let now = tokio::time::Instant::now();
        let Ok(mut state) = self.state.try_write() else {
            return;
        };
        state.moq.objects = state.moq.objects.saturating_add(1);
        state.moq.bytes = state
            .moq
            .bytes
            .saturating_add(usize_to_u64(object.payload.len()));
        state.moq.last_seen = Some(now);
        state.latency.record(duration_millis(
            now.saturating_duration_since(object.received_at),
        ));
        drop(state);
        self.revision.fetch_add(1, Ordering::Relaxed);
    }

    /// Marca la desconexión; conserva contadores históricos, no payloads.
    pub fn record_moq_disconnected(&self) {
        let Ok(mut state) = self.state.try_write() else {
            return;
        };
        state.moq.connected = false;
        state.moq.connection_id = None;
        drop(state);
        self.revision.fetch_add(1, Ordering::Relaxed);
    }

    fn snapshot(&self, now: tokio::time::Instant) -> SignalSnapshot {
        let uptime_ms = duration_millis(now.saturating_duration_since(self.started_at));
        let revision = self.revision.load(Ordering::Relaxed);
        let Ok(state) = self.state.try_read() else {
            return SignalSnapshot::unavailable(uptime_ms, revision);
        };
        let ingest_age = age_ms(now, state.last_ingest);
        let demux_age = age_ms(now, state.last_demux);
        let scheduler_age = age_ms(now, state.scheduler.last_seen);
        let moq_age = age_ms(now, state.moq.last_seen);
        let mut sources: Vec<_> = state
            .sources
            .values()
            .map(|source| SourceSnapshot {
                connection_id: source.connection_id.clone(),
                peer: source.peer.clone(),
                packets: source.packets,
                bytes: source.bytes,
                last_activity_ms: duration_millis(now.saturating_duration_since(source.last_seen)),
                status: signal_status(Some(source.last_seen), now),
            })
            .collect();
        sources.sort_by(|left, right| left.connection_id.cmp(&right.connection_id));
        let tracks = state
            .tracks
            .iter()
            .map(|track| TrackSnapshot {
                track: track.track.value(),
                name: track_name(track.track),
                status: signal_status(track.last_seen, now),
                codec: track.codec,
                program_number: track.program_number,
                pid: track.pid,
                group_id: track.group_id,
                object_id: track.object_id,
                kind: track.kind,
                pts_ns: track.pts_ns,
                dts_ns: track.dts_ns,
                objects: track.objects,
                bytes: track.bytes,
                last_activity_ms: age_ms(now, track.last_seen),
            })
            .collect();
        SignalSnapshot {
            schema_version: SNAPSHOT_SCHEMA_VERSION,
            service: "gateway-rs",
            revision,
            uptime_ms,
            phases: vec![
                PhaseSnapshot {
                    id: "srt_ingest",
                    label: "SRT Ingest",
                    status: signal_status(state.last_ingest, now),
                    items: state.ingest_packets,
                    bytes: state.ingest_bytes,
                    last_activity_ms: ingest_age,
                    note: "Listener y mensajes MPEG-TS recibidos",
                },
                PhaseSnapshot {
                    id: "mpegts_demux",
                    label: "MPEG-TS Demux",
                    status: signal_status(state.last_demux, now),
                    items: state.demux_objects,
                    bytes: state.demux_bytes,
                    last_activity_ms: demux_age,
                    note: "PAT/PMT/PES a access units codificadas",
                },
                PhaseSnapshot {
                    id: "object_scheduler",
                    label: "Object Scheduler",
                    status: signal_status(state.scheduler.last_seen, now),
                    items: state.scheduler.snapshot.accepted,
                    bytes: state.scheduler.snapshot.accepted_bytes,
                    last_activity_ms: scheduler_age,
                    note: "Colas por suscriptor reales y acotadas",
                },
                PhaseSnapshot {
                    id: "moq_distribution",
                    label: "MoQ Distribution",
                    status: moq_status(&state.moq, now),
                    items: state.moq.objects,
                    bytes: state.moq.bytes,
                    last_activity_ms: moq_age,
                    note: "Publisher MoQT draft-16 hacia relay reutilizado",
                },
            ],
            sources,
            tracks,
            scheduler: SchedulerView::from(state.scheduler.snapshot),
            moq: MoqView::from(&state.moq),
            latency: LatencyView::from(&state.latency),
        }
    }
}

/// Ejecuta el panel local y reintenta fallos sin propagar presión al directo.
///
/// # Errors
///
/// Conserva el contrato de las tasks del Gateway. Los fallos HTTP recuperables
/// se registran y reintentan; una cancelación coordinada devuelve éxito.
pub async fn run_web_supervisor(
    config: SupervisorConfig,
    moq: MoqConfig,
    monitor: Arc<SignalMonitor>,
    cancellation: CancellationToken,
    logger: EventLogger,
) -> GatewayResult<()> {
    loop {
        let binding = tokio::net::TcpListener::bind(config.bind_addr).await;
        let listener = match binding {
            Ok(listener) => listener,
            Err(source) => {
                logger.supervisor_web_unavailable(config.bind_addr, &source);
                tokio::select! {
                    () = cancellation.cancelled() => return Ok(()),
                    () = tokio::time::sleep(RETRY_DELAY) => continue,
                }
            }
        };
        logger.supervisor_web_bound(config.bind_addr);
        let state = WebState {
            monitor: Arc::clone(&monitor),
            playback: PlaybackRuntime::load(&config, &moq),
        };
        let router = build_router(state);
        let shutdown = cancellation.child_token();
        let result = axum::serve(listener, router)
            .with_graceful_shutdown(shutdown.cancelled_owned())
            .await;
        if cancellation.is_cancelled() {
            return Ok(());
        }
        if let Err(source) = result {
            logger.supervisor_web_unavailable(config.bind_addr, &source);
        }
        tokio::select! {
            () = cancellation.cancelled() => return Ok(()),
            () = tokio::time::sleep(RETRY_DELAY) => {}
        }
    }
}

fn build_router(state: WebState) -> Router {
    Router::new()
        .route("/", get(index))
        .route("/assets/app.css", get(styles))
        .route("/assets/scheduler.css", get(scheduler_styles))
        .route("/assets/app.js", get(script))
        .route("/api/v1/snapshot", get(snapshot))
        .route("/api/v1/playback", get(playback))
        .route("/api/v1/moq-certificate.sha256", get(moq_fingerprint))
        .route("/healthz", get(health))
        .with_state(state)
}

async fn index(State(state): State<WebState>) -> Response {
    let headers = [
        (header::CACHE_CONTROL, HeaderValue::from_static("no-store")),
        (
            header::CONTENT_SECURITY_POLICY,
            state.playback.content_security_policy(),
        ),
        (
            header::X_CONTENT_TYPE_OPTIONS,
            HeaderValue::from_static("nosniff"),
        ),
    ];
    (headers, Html(include_str!("../assets/supervisor.html"))).into_response()
}

async fn styles() -> Response {
    static_asset(
        "text/css; charset=utf-8",
        include_str!("../assets/supervisor.css"),
    )
}

async fn scheduler_styles() -> Response {
    static_asset(
        "text/css; charset=utf-8",
        include_str!("../assets/scheduler.css"),
    )
}

async fn script() -> Response {
    static_asset(
        "text/javascript; charset=utf-8",
        include_str!("../assets/supervisor.js"),
    )
}

fn static_asset(content_type: &'static str, body: &'static str) -> Response {
    (
        [
            (header::CONTENT_TYPE, HeaderValue::from_static(content_type)),
            (header::CACHE_CONTROL, HeaderValue::from_static("no-store")),
            (
                header::X_CONTENT_TYPE_OPTIONS,
                HeaderValue::from_static("nosniff"),
            ),
        ],
        body,
    )
        .into_response()
}

async fn snapshot(State(state): State<WebState>) -> Response {
    let response = Json(state.monitor.snapshot(tokio::time::Instant::now())).into_response();
    no_store(response)
}

#[derive(Serialize)]
struct PlaybackView {
    schema_version: u8,
    input_preview_url: Option<String>,
    output_relay_url: Option<String>,
    namespaces: Vec<String>,
    fingerprint_available: bool,
}

async fn playback(State(state): State<WebState>) -> Response {
    let response = Json(PlaybackView {
        schema_version: 1,
        input_preview_url: state.playback.input_preview_url.clone(),
        output_relay_url: state.playback.output_relay_url.clone(),
        namespaces: state.playback.namespaces.clone(),
        fingerprint_available: state.playback.fingerprint.is_some(),
    })
    .into_response();
    no_store(response)
}

async fn moq_fingerprint(State(state): State<WebState>) -> Response {
    let Some(fingerprint) = state.playback.fingerprint.clone() else {
        return no_store(StatusCode::NOT_FOUND.into_response());
    };
    no_store(
        (
            [(
                header::CONTENT_TYPE,
                HeaderValue::from_static("text/plain; charset=utf-8"),
            )],
            fingerprint,
        )
            .into_response(),
    )
}

async fn health() -> Response {
    no_store(StatusCode::OK.into_response())
}

fn no_store(mut response: Response) -> Response {
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response.headers_mut().insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    response
}

#[derive(Serialize)]
struct SignalSnapshot {
    schema_version: u8,
    service: &'static str,
    revision: u64,
    uptime_ms: u64,
    phases: Vec<PhaseSnapshot>,
    sources: Vec<SourceSnapshot>,
    tracks: Vec<TrackSnapshot>,
    scheduler: SchedulerView,
    moq: MoqView,
    latency: LatencyView,
}

impl SignalSnapshot {
    fn unavailable(uptime_ms: u64, revision: u64) -> Self {
        Self {
            schema_version: SNAPSHOT_SCHEMA_VERSION,
            service: "gateway-rs",
            revision,
            uptime_ms,
            phases: vec![PhaseSnapshot {
                id: "monitor",
                label: "Signal Monitor",
                status: "unavailable",
                items: 0,
                bytes: 0,
                last_activity_ms: None,
                note: "Estado interno temporalmente no disponible",
            }],
            sources: Vec::new(),
            tracks: Vec::new(),
            scheduler: SchedulerView::default(),
            moq: MoqView::default(),
            latency: LatencyView::default(),
        }
    }
}

#[derive(Serialize)]
struct PhaseSnapshot {
    id: &'static str,
    label: &'static str,
    status: &'static str,
    items: u64,
    bytes: u64,
    last_activity_ms: Option<u64>,
    note: &'static str,
}

#[derive(Serialize)]
struct SourceSnapshot {
    connection_id: String,
    peer: String,
    packets: u64,
    bytes: u64,
    last_activity_ms: u64,
    status: &'static str,
}

#[derive(Serialize)]
struct TrackSnapshot {
    track: u8,
    name: &'static str,
    status: &'static str,
    codec: Option<&'static str>,
    program_number: Option<u16>,
    pid: Option<u16>,
    group_id: Option<u64>,
    object_id: Option<u64>,
    kind: Option<&'static str>,
    pts_ns: Option<u64>,
    dts_ns: Option<u64>,
    objects: u64,
    bytes: u64,
    last_activity_ms: Option<u64>,
}

#[derive(Default, Serialize)]
struct SchedulerView {
    subscribers: usize,
    queued_objects: usize,
    queued_bytes: usize,
    accepted: u64,
    accepted_bytes: u64,
    dropped: u64,
    evicted: u64,
    dequeued: u64,
}

impl From<SchedulerSnapshot> for SchedulerView {
    fn from(snapshot: SchedulerSnapshot) -> Self {
        Self {
            subscribers: snapshot.subscribers,
            queued_objects: snapshot.queued_objects,
            queued_bytes: snapshot.queued_bytes,
            accepted: snapshot.accepted,
            accepted_bytes: snapshot.accepted_bytes,
            dropped: snapshot.dropped,
            evicted: snapshot.evicted,
            dequeued: snapshot.dequeued,
        }
    }
}

#[derive(Default, Serialize)]
struct MoqView {
    connected: bool,
    connection_id: Option<String>,
    relay: Option<String>,
    objects: u64,
    bytes: u64,
}

impl From<&MoqState> for MoqView {
    fn from(state: &MoqState) -> Self {
        Self {
            connected: state.connected,
            connection_id: state.connection_id.clone(),
            relay: state.relay.clone(),
            objects: state.objects,
            bytes: state.bytes,
        }
    }
}

#[derive(Default, Serialize)]
struct LatencyView {
    metric: &'static str,
    samples: usize,
    window_capacity: usize,
    p50_ms: Option<u64>,
    p95_ms: Option<u64>,
    p99_ms: Option<u64>,
    max_ms: Option<u64>,
    network_and_subscriber_ms: Option<u64>,
    presentation_ms: Option<u64>,
    glass_to_glass_ms: Option<u64>,
}

impl From<&LatencyWindow> for LatencyView {
    fn from(window: &LatencyWindow) -> Self {
        let mut samples = window.samples.iter().copied().collect::<Vec<_>>();
        samples.sort_unstable();
        Self {
            metric: "ingest_to_publish",
            samples: samples.len(),
            window_capacity: LATENCY_WINDOW_SAMPLES,
            p50_ms: percentile(&samples, 50),
            p95_ms: percentile(&samples, 95),
            p99_ms: percentile(&samples, 99),
            max_ms: samples.last().copied(),
            network_and_subscriber_ms: None,
            presentation_ms: None,
            glass_to_glass_ms: None,
        }
    }
}

#[derive(Default)]
struct LatencyWindow {
    samples: VecDeque<u64>,
}

impl LatencyWindow {
    fn record(&mut self, value_ms: u64) {
        if self.samples.len() == LATENCY_WINDOW_SAMPLES {
            self.samples.pop_front();
        }
        self.samples.push_back(value_ms);
    }
}

struct MonitorState {
    sources: HashMap<String, SourceState>,
    tracks: [TrackState; 4],
    ingest_packets: u64,
    ingest_bytes: u64,
    demux_objects: u64,
    demux_bytes: u64,
    last_ingest: Option<tokio::time::Instant>,
    last_demux: Option<tokio::time::Instant>,
    scheduler: SchedulerState,
    moq: MoqState,
    latency: LatencyWindow,
}

impl MonitorState {
    fn new() -> Self {
        Self {
            sources: HashMap::new(),
            tracks: [
                TrackState::new(TrackId::VideoHq),
                TrackState::new(TrackId::VideoLq),
                TrackState::new(TrackId::CriticalAudio),
                TrackState::new(TrackId::Telemetry),
            ],
            ingest_packets: 0,
            ingest_bytes: 0,
            demux_objects: 0,
            demux_bytes: 0,
            last_ingest: None,
            last_demux: None,
            scheduler: SchedulerState::default(),
            moq: MoqState::default(),
            latency: LatencyWindow::default(),
        }
    }
}

#[derive(Default)]
struct SchedulerState {
    snapshot: SchedulerSnapshot,
    last_seen: Option<tokio::time::Instant>,
}

#[derive(Default)]
struct MoqState {
    connected: bool,
    connection_id: Option<String>,
    relay: Option<String>,
    objects: u64,
    bytes: u64,
    last_seen: Option<tokio::time::Instant>,
}

struct SourceState {
    connection_id: String,
    peer: String,
    packets: u64,
    bytes: u64,
    last_seen: tokio::time::Instant,
}

struct TrackState {
    track: TrackId,
    codec: Option<&'static str>,
    program_number: Option<u16>,
    pid: Option<u16>,
    group_id: Option<u64>,
    object_id: Option<u64>,
    kind: Option<&'static str>,
    pts_ns: Option<u64>,
    dts_ns: Option<u64>,
    objects: u64,
    bytes: u64,
    last_seen: Option<tokio::time::Instant>,
}

impl TrackState {
    const fn new(track: TrackId) -> Self {
        Self {
            track,
            codec: None,
            program_number: None,
            pid: None,
            group_id: None,
            object_id: None,
            kind: None,
            pts_ns: None,
            dts_ns: None,
            objects: 0,
            bytes: 0,
            last_seen: None,
        }
    }
}

fn signal_status(
    last_seen: Option<tokio::time::Instant>,
    now: tokio::time::Instant,
) -> &'static str {
    match last_seen {
        Some(last_seen) if now.saturating_duration_since(last_seen) <= SIGNAL_ACTIVE_WINDOW => {
            "active"
        }
        Some(_) => "stale",
        None => "waiting",
    }
}

fn moq_status(state: &MoqState, _now: tokio::time::Instant) -> &'static str {
    if state.connected {
        "active"
    } else if state.last_seen.is_some() {
        "stale"
    } else {
        "waiting"
    }
}

fn age_ms(now: tokio::time::Instant, instant: Option<tokio::time::Instant>) -> Option<u64> {
    instant.map(|instant| duration_millis(now.saturating_duration_since(instant)))
}

const fn access_unit_label(kind: AccessUnitKind) -> &'static str {
    match kind {
        AccessUnitKind::RandomAccess => "random_access",
        AccessUnitKind::Delta => "delta",
        AccessUnitKind::Audio => "audio",
        AccessUnitKind::Telemetry => "telemetry",
    }
}

const fn track_name(track: TrackId) -> &'static str {
    match track {
        TrackId::VideoHq => "Video HQ",
        TrackId::VideoLq => "Video LQ",
        TrackId::CriticalAudio => "Audio crítico",
        TrackId::Telemetry => "Telemetría",
    }
}

fn duration_millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).map_or(u64::MAX, std::convert::identity)
}

fn percentile(sorted: &[u64], requested: usize) -> Option<u64> {
    if sorted.is_empty() {
        return None;
    }
    let rank = requested
        .saturating_mul(sorted.len().saturating_sub(1))
        .saturating_add(50)
        / 100;
    sorted.get(rank).copied()
}

fn usize_to_u64(value: usize) -> u64 {
    u64::try_from(value).map_or(u64::MAX, std::convert::identity)
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::{
        LatencyView, LatencyWindow, PlaybackRuntime, SignalMonitor, WebState, index, is_sha256_hex,
        playback, snapshot,
    };
    use crate::{
        error::GatewayResult,
        ingest::IngestPacket,
        media::{AccessUnitKind, Codec, Group, MediaObject, Track},
        routing::TrackId,
        scheduler::SchedulerSnapshot,
    };
    use axum::extract::State;
    use axum::http::StatusCode;
    use bytes::Bytes;

    fn web_state() -> WebState {
        WebState {
            monitor: Arc::new(SignalMonitor::new(2)),
            playback: PlaybackRuntime {
                input_preview_url: Some("http://127.0.0.1:8889/input".to_owned()),
                input_origin: Some("http://127.0.0.1:8889".to_owned()),
                output_relay_url: Some("https://127.0.0.1:4433/watch".to_owned()),
                output_origin: Some("https://127.0.0.1:4433".to_owned()),
                namespaces: vec!["teremoq".to_owned(), "live".to_owned()],
                fingerprint: Some("a".repeat(64)),
            },
        }
    }

    #[test]
    fn empty_monitor_exposes_all_four_phases() {
        let monitor = SignalMonitor::new(2);
        let snapshot = monitor.snapshot(tokio::time::Instant::now());
        assert_eq!(snapshot.phases.len(), 4);
        assert_eq!(snapshot.tracks.len(), 4);
        assert_eq!(snapshot.phases[0].status, "waiting");
        assert_eq!(snapshot.phases[2].status, "waiting");
        assert_eq!(snapshot.phases[3].status, "waiting");
    }

    #[test]
    fn records_ingest_and_demux_without_retaining_payloads() -> GatewayResult<()> {
        let monitor = SignalMonitor::new(2);
        let now = tokio::time::Instant::now();
        let connection_id: Arc<str> = Arc::from("srt-test-1");
        let peer = "127.0.0.1:42000".parse()?;
        let packet = IngestPacket {
            payload: Bytes::from_static(b"secret-media"),
            connection_id: Arc::clone(&connection_id),
            peer,
            stream_id: Arc::from("private-stream-id"),
            message_number: 1,
            srt_timestamp: 2,
            received_at: now,
        };
        monitor.record_ingest(&packet);
        monitor.record_object(&MediaObject {
            group: Group {
                id: 7,
                track: Track {
                    id: TrackId::VideoHq,
                },
                random_access: true,
            },
            object_id: 3,
            program_number: 1,
            pid: 256,
            codec: Codec::H264,
            kind: AccessUnitKind::RandomAccess,
            pts_ns: Some(42),
            dts_ns: Some(40),
            payload: Bytes::from_static(b"encoded-access-unit"),
            cmaf_init: None,
            connection_id,
            peer,
            received_at: now,
        });

        let snapshot = monitor.snapshot(now);
        assert_eq!(snapshot.revision, 2);
        assert_eq!(snapshot.sources.len(), 1);
        assert_eq!(snapshot.sources[0].bytes, 12);
        assert_eq!(snapshot.phases[0].status, "active");
        assert_eq!(snapshot.phases[1].status, "active");
        assert_eq!(snapshot.tracks[0].codec, Some("h264"));
        assert_eq!(snapshot.tracks[0].group_id, Some(7));
        Ok(())
    }

    #[test]
    fn records_real_scheduler_counters() {
        let monitor = SignalMonitor::new(2);
        let now = tokio::time::Instant::now();
        monitor.record_scheduler(
            SchedulerSnapshot {
                subscribers: 2,
                queued_objects: 3,
                queued_bytes: 4_096,
                accepted: 10,
                accepted_bytes: 8_192,
                dropped: 2,
                evicted: 1,
                dequeued: 7,
            },
            Some(now),
        );

        let snapshot = monitor.snapshot(now);
        assert_eq!(snapshot.phases[2].status, "active");
        assert_eq!(snapshot.phases[2].items, 10);
        assert_eq!(snapshot.scheduler.queued_objects, 3);
        assert_eq!(snapshot.scheduler.dropped, 2);
    }

    #[test]
    fn records_real_moq_session_without_media_payload() {
        let monitor = SignalMonitor::new(1);
        let now = tokio::time::Instant::now();
        monitor.record_moq_connected("cid-test", "https://127.0.0.1:4433");

        let snapshot = monitor.snapshot(now);
        assert_eq!(snapshot.phases[3].status, "active");
        assert!(snapshot.moq.connected);
        assert_eq!(snapshot.moq.connection_id.as_deref(), Some("cid-test"));
    }

    #[test]
    fn latency_window_is_bounded_and_reports_percentiles() {
        let mut window = LatencyWindow::default();
        for sample in 1..=5_000_u64 {
            window.record(sample);
        }
        let view = LatencyView::from(&window);
        assert_eq!(view.samples, 4_096);
        assert_eq!(view.p50_ms, Some(2_953));
        assert_eq!(view.p95_ms, Some(4_795));
        assert_eq!(view.p99_ms, Some(4_959));
        assert_eq!(view.max_ms, Some(5_000));
        assert_eq!(view.glass_to_glass_ms, None);
    }

    #[tokio::test]
    async fn dashboard_has_security_headers() {
        let response = index(State(web_state())).await;
        assert_eq!(response.status(), StatusCode::OK);
        assert!(response.headers().contains_key("content-security-policy"));
        assert_eq!(
            response
                .headers()
                .get("x-content-type-options")
                .and_then(|value| value.to_str().ok()),
            Some("nosniff")
        );
        assert_eq!(
            response
                .headers()
                .get("cache-control")
                .and_then(|value| value.to_str().ok()),
            Some("no-store")
        );
    }

    #[tokio::test]
    async fn snapshot_disables_caching() {
        let response = snapshot(State(web_state())).await;
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response
                .headers()
                .get("cache-control")
                .and_then(|value| value.to_str().ok()),
            Some("no-store")
        );
    }

    #[tokio::test]
    async fn custom_playback_config_is_available() {
        let state = web_state();
        assert_eq!(playback(State(state)).await.status(), StatusCode::OK);
    }

    #[test]
    fn accepts_only_plain_sha256_fingerprints() {
        assert!(is_sha256_hex(&"0a".repeat(32)));
        assert!(!is_sha256_hex("AA:BB"));
        assert!(!is_sha256_hex(&"g".repeat(64)));
    }
}
