//! Demultiplexado MPEG-TS zero-transcoding mediante `GStreamer`.

use std::{
    collections::{HashMap, HashSet},
    net::SocketAddr,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};

use bytes::Bytes;
use gstreamer as gst;
use gstreamer::prelude::*;
use gstreamer_app as gst_app;
use tokio::sync::mpsc;

use crate::{
    BoxFuture,
    config::MediaConfig,
    error::{GatewayError, GatewayResult},
    ingest::IngestPacket,
    observability::EventLogger,
    routing::{RouteTable, TrackId},
};

const REQUIRED_FACTORIES: &[&str] = &[
    "appsrc",
    "tsdemux",
    "queue",
    "capsfilter",
    "appsink",
    "fakesink",
    "h264parse",
    "h265parse",
    "mpegvideoparse",
    "aacparse",
    "opusparse",
    "ac3parse",
    "identity",
    "cmafmux",
];
const CMAF_FRAGMENT_DURATION_NS: u64 = 1_000_000_000;
const CMAF_CHUNK_DURATION_NS: u64 = 33_333_333;
const CRITICAL_OBJECTS_PER_GROUP: u64 = 32;
const _: () = assert!(CMAF_CHUNK_DURATION_NS <= 1_000_000_000 / 30);
const _: () = assert!(CMAF_CHUNK_DURATION_NS < CMAF_FRAGMENT_DURATION_NS);

/// Códec codificado que conserva un Object sin decodificación.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Codec {
    /// AVC/H.264.
    H264,
    /// HEVC/H.265.
    H265,
    /// MPEG-2 Video.
    Mpeg2Video,
    /// Advanced Audio Coding.
    Aac,
    /// Opus.
    Opus,
    /// Dolby Digital.
    Ac3,
    /// Dolby Digital Plus.
    Eac3,
    /// Telemetría JSON transportada como datos privados.
    Json,
}

impl Codec {
    /// Etiqueta estable para observabilidad y el supervisor web.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::H264 => "h264",
            Self::H265 => "h265",
            Self::Mpeg2Video => "mpeg2video",
            Self::Aac => "aac",
            Self::Opus => "opus",
            Self::Ac3 => "ac3",
            Self::Eac3 => "eac3",
            Self::Json => "json",
        }
    }
}

/// Clasificación temporal de una access unit codificada.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AccessUnitKind {
    /// Punto de acceso aleatorio de vídeo.
    RandomAccess,
    /// Imagen de vídeo dependiente.
    Delta,
    /// Access unit de audio.
    Audio,
    /// Mensaje de telemetría.
    Telemetry,
}

/// Track lógico e inmutable de un Object.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Track {
    /// Identidad lógica estable 0..=3.
    pub id: TrackId,
}

/// Group lógico iniciado por random access cuando aplica.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Group {
    /// Identidad única durante la vida del proceso.
    pub id: u64,
    /// Track propietario.
    pub track: Track,
    /// Indica si el Group comenzó en un punto decodificable.
    pub random_access: bool,
}

/// Object codificado listo para la futura capa `MoQ`.
#[derive(Clone, Debug)]
pub struct MediaObject {
    /// Group lógico al que pertenece.
    pub group: Group,
    /// Secuencia creciente dentro del Group.
    pub object_id: u64,
    /// Programa MPEG-TS de origen.
    pub program_number: u16,
    /// PID elemental de origen.
    pub pid: u16,
    /// Códec que permanece comprimido.
    pub codec: Codec,
    /// Clasificación temporal para el scheduler futuro.
    pub kind: AccessUnitKind,
    /// PTS conservado en nanosegundos.
    pub pts_ns: Option<u64>,
    /// DTS conservado en nanosegundos.
    pub dts_ns: Option<u64>,
    /// Access unit codificada e inmutable.
    pub payload: Bytes,
    /// Inicialización CMAF compartida cuando el payload es un chunk `moof+mdat`.
    pub cmaf_init: Option<Bytes>,
    /// Identidad opaca de la conexión SRT.
    pub connection_id: Arc<str>,
    /// Peer SRT de origen.
    pub peer: SocketAddr,
    /// Último instante monotónico de ingesta asociado a la unidad producida.
    pub received_at: tokio::time::Instant,
}

/// Puerto asíncrono entre la ingesta SRT y el pipeline multimedia.
pub trait MediaDemux: Send {
    /// Encola un mensaje SRT en los programas configurados.
    ///
    /// # Errors
    ///
    /// Devuelve error únicamente ante un fallo del puerto; los fallos de una
    /// sesión multimedia se aíslan y se registran.
    fn push(&mut self, packet: IngestPacket) -> GatewayResult<()>;
    /// Espera el siguiente Object codificado o el cierre del puerto.
    ///
    /// # Errors
    ///
    /// Devuelve error si el adaptador de salida falla.
    fn receive(&mut self) -> BoxFuture<'_, GatewayResult<Option<MediaObject>>>;
    /// Procesa el bus nativo y libera sesiones inactivas.
    fn maintain(&mut self, now: tokio::time::Instant);
    /// Libera todos los pipelines.
    ///
    /// # Errors
    ///
    /// Devuelve error si un adaptador no puede completar su cierre ordenado.
    fn shutdown(&mut self) -> GatewayResult<()>;
}

/// Implementación oficial `gstreamer-rs`: `appsrc → tsdemux → parser → appsink`.
pub struct GstreamerMediaDemux {
    config: MediaConfig,
    max_sessions: usize,
    routes: RouteTable,
    logger: EventLogger,
    sessions: HashMap<Arc<str>, MediaSession>,
    outputs: TrackOutputs,
    next_group_id: Arc<AtomicU64>,
}

impl GstreamerMediaDemux {
    /// Inicializa `GStreamer` y audita que no haya codecs de transcodificación.
    ///
    /// # Errors
    ///
    /// Devuelve error si el runtime o cualquiera de los elementos nativos
    /// requeridos no está disponible o infringe zero-transcoding.
    pub fn new(
        config: MediaConfig,
        max_sessions: usize,
        routes: RouteTable,
        logger: EventLogger,
    ) -> GatewayResult<Self> {
        gst::init().map_err(|source| {
            GatewayError::with_source("failed to initialize GStreamer", Box::new(source)).boxed()
        })?;
        audit_factories()?;
        logger.media_runtime_ready(gst::version_string().as_str(), REQUIRED_FACTORIES);
        Ok(Self {
            outputs: TrackOutputs::new(config.output_queue_objects),
            config,
            max_sessions,
            routes,
            logger,
            sessions: HashMap::new(),
            next_group_id: Arc::new(AtomicU64::new(1)),
        })
    }

    fn open_session(&mut self, packet: &IngestPacket) -> GatewayResult<MediaSession> {
        if self.sessions.len() >= self.max_sessions {
            return Err(GatewayError::new("media session limit reached").boxed());
        }
        let programs: HashSet<u16> = self
            .routes
            .rules()
            .iter()
            .filter(|rule| rule.stream_id == packet.stream_id.as_ref())
            .map(|rule| rule.program_number)
            .collect();
        if programs.is_empty() {
            return Err(GatewayError::new("authorized Stream ID has no media routes").boxed());
        }
        let source = self
            .routes
            .source_for_stream(packet.stream_id.as_ref())
            .ok_or_else(|| GatewayError::new("authorized Stream ID has no source label").boxed())?;
        let context = SessionContext {
            connection_id: Arc::clone(&packet.connection_id),
            peer: packet.peer,
            stream_id: Arc::clone(&packet.stream_id),
            source: Arc::from(source),
            latest_received_at: Arc::new(Mutex::new(packet.received_at)),
        };
        let mut pipelines = Vec::with_capacity(programs.len());
        for program_number in programs {
            pipelines.push(ProgramPipeline::build(
                program_number,
                &context,
                &self.routes,
                &self.config,
                self.outputs.senders(),
                Arc::clone(&self.next_group_id),
                self.logger.clone(),
            )?);
        }
        self.logger.media_pipeline_opened(
            context.connection_id.as_ref(),
            context.peer,
            context.source.as_ref(),
            pipelines.len(),
        );
        Ok(MediaSession {
            context,
            pipelines,
            last_seen: packet.received_at,
        })
    }

    fn remove_session(&mut self, connection_id: &Arc<str>, reason: &'static str) {
        if let Some(mut session) = self.sessions.remove(connection_id) {
            for pipeline in &mut session.pipelines {
                pipeline.stop(&self.logger, &session.context, reason);
            }
        }
    }
}

impl MediaDemux for GstreamerMediaDemux {
    fn push(&mut self, packet: IngestPacket) -> GatewayResult<()> {
        if !self.sessions.contains_key(&packet.connection_id) {
            match self.open_session(&packet) {
                Ok(session) => {
                    self.sessions
                        .insert(Arc::clone(&packet.connection_id), session);
                }
                Err(source) => {
                    self.logger.media_pipeline_rejected(
                        packet.connection_id.as_ref(),
                        packet.peer,
                        source.as_ref(),
                    );
                    return Ok(());
                }
            }
        }
        let mut failure = None;
        if let Some(session) = self.sessions.get_mut(&packet.connection_id) {
            session.last_seen = packet.received_at;
            for pipeline in &mut session.pipelines {
                if let Err(source) = pipeline.push(&packet, self.config.input_queue_bytes) {
                    failure = Some(source);
                    break;
                }
            }
        }
        if let Some(source) = failure {
            self.logger.media_pipeline_failed(
                packet.connection_id.as_ref(),
                packet.peer,
                source.as_ref(),
            );
            self.remove_session(&packet.connection_id, "pipeline_error");
        }
        Ok(())
    }

    fn receive(&mut self) -> BoxFuture<'_, GatewayResult<Option<MediaObject>>> {
        Box::pin(self.outputs.receive())
    }

    fn maintain(&mut self, now: tokio::time::Instant) {
        let mut expired = Vec::new();
        for (connection_id, session) in &mut self.sessions {
            let bus_failed = session
                .pipelines
                .iter_mut()
                .any(|pipeline| pipeline.drain_bus(&self.logger, &session.context));
            if bus_failed
                || now.duration_since(session.last_seen) >= self.config.session_idle_timeout
            {
                expired.push(Arc::clone(connection_id));
            }
        }
        for connection_id in expired {
            self.remove_session(&connection_id, "idle_or_bus_error");
        }
    }

    fn shutdown(&mut self) -> GatewayResult<()> {
        let ids: Vec<_> = self.sessions.keys().cloned().collect();
        for id in ids {
            self.remove_session(&id, "gateway_shutdown");
        }
        Ok(())
    }
}

struct TrackOutputs {
    senders: TrackSenders,
    hq: mpsc::Receiver<MediaObject>,
    lq: mpsc::Receiver<MediaObject>,
    audio: mpsc::Receiver<MediaObject>,
    telemetry: mpsc::Receiver<MediaObject>,
}

impl TrackOutputs {
    fn new(capacity: usize) -> Self {
        let (hq_tx, hq) = mpsc::channel(capacity);
        let (lq_tx, lq) = mpsc::channel(capacity);
        let (audio_tx, audio) = mpsc::channel(capacity);
        let (telemetry_tx, telemetry) = mpsc::channel(capacity);
        Self {
            senders: TrackSenders {
                hq: hq_tx,
                lq: lq_tx,
                audio: audio_tx,
                telemetry: telemetry_tx,
            },
            hq,
            lq,
            audio,
            telemetry,
        }
    }
    fn senders(&self) -> TrackSenders {
        self.senders.clone()
    }
    async fn receive(&mut self) -> GatewayResult<Option<MediaObject>> {
        tokio::select! {
            value = self.audio.recv() => Ok(value), value = self.telemetry.recv() => Ok(value),
            value = self.hq.recv() => Ok(value), value = self.lq.recv() => Ok(value),
        }
    }
}

#[derive(Clone)]
struct TrackSenders {
    hq: mpsc::Sender<MediaObject>,
    lq: mpsc::Sender<MediaObject>,
    audio: mpsc::Sender<MediaObject>,
    telemetry: mpsc::Sender<MediaObject>,
}
impl TrackSenders {
    fn for_track(&self, track: TrackId) -> mpsc::Sender<MediaObject> {
        match track {
            TrackId::VideoHq => self.hq.clone(),
            TrackId::VideoLq => self.lq.clone(),
            TrackId::CriticalAudio => self.audio.clone(),
            TrackId::Telemetry => self.telemetry.clone(),
        }
    }
}

#[derive(Clone)]
struct SessionContext {
    connection_id: Arc<str>,
    peer: SocketAddr,
    stream_id: Arc<str>,
    source: Arc<str>,
    latest_received_at: Arc<Mutex<tokio::time::Instant>>,
}
struct MediaSession {
    context: SessionContext,
    pipelines: Vec<ProgramPipeline>,
    last_seen: tokio::time::Instant,
}
struct ProgramPipeline {
    program_number: u16,
    pipeline: gst::Pipeline,
    appsrc: gst_app::AppSrc,
    latest_received_at: Arc<Mutex<tokio::time::Instant>>,
}

impl ProgramPipeline {
    #[allow(clippy::too_many_arguments)]
    fn build(
        program_number: u16,
        context: &SessionContext,
        routes: &RouteTable,
        config: &MediaConfig,
        senders: TrackSenders,
        next_group_id: Arc<AtomicU64>,
        logger: EventLogger,
    ) -> GatewayResult<Self> {
        let caps = gst::Caps::builder("video/mpegts")
            .field("systemstream", true)
            .field("packetsize", 188_i32)
            .build();
        let appsrc = gst_app::AppSrc::builder()
            .caps(&caps)
            .format(gst::Format::Bytes)
            .is_live(true)
            .block(false)
            .max_bytes(u64::try_from(config.input_queue_bytes).map_err(|source| {
                GatewayError::with_source("media input queue does not fit u64", Box::new(source))
                    .boxed()
            })?)
            .build();
        let demux = make_element("tsdemux")?;
        demux.set_property("program-number", i32::from(program_number));
        demux.set_property("latency", 0_i32);
        let pipeline = gst::Pipeline::new();
        pipeline
            .add_many([appsrc.upcast_ref(), &demux])
            .map_err(gst_error("failed to add MPEG-TS source elements"))?;
        appsrc
            .link(&demux)
            .map_err(gst_error("failed to link appsrc to tsdemux"))?;
        let dynamic_context = DynamicPadContext {
            pipeline: pipeline.clone(),
            session: context.clone(),
            program_number,
            routes: routes.clone(),
            config: config.clone(),
            senders,
            next_group_id,
            logger: logger.clone(),
        };
        demux.connect_pad_added(move |_demux, pad| dynamic_context.attach(pad));
        let removed_logger = logger;
        let removed_session = context.clone();
        demux.connect_pad_removed(move |_demux, pad| {
            if let Some(pid) = pid_from_pad_name(pad.name().as_str()) {
                removed_logger.mpegts_program_changed(
                    removed_session.connection_id.as_ref(),
                    program_number,
                    pid,
                    "stream_removed",
                );
            }
        });
        pipeline
            .set_state(gst::State::Playing)
            .map_err(gst_error("failed to start MPEG-TS pipeline"))?;
        Ok(Self {
            program_number,
            pipeline,
            appsrc,
            latest_received_at: Arc::clone(&context.latest_received_at),
        })
    }

    fn push(&mut self, packet: &IngestPacket, max_queue_bytes: usize) -> GatewayResult<()> {
        let mut latest_received_at = self
            .latest_received_at
            .lock()
            .map_err(|_| GatewayError::new("media ingress timestamp lock is poisoned").boxed())?;
        *latest_received_at = packet.received_at;
        drop(latest_received_at);
        let queued = self.appsrc.current_level_bytes();
        let payload_len = u64::try_from(packet.payload.len()).map_err(|source| {
            GatewayError::with_source("SRT payload length does not fit u64", Box::new(source))
                .boxed()
        })?;
        let limit = u64::try_from(max_queue_bytes).map_err(|source| {
            GatewayError::with_source("media queue limit does not fit u64", Box::new(source))
                .boxed()
        })?;
        if queued.saturating_add(payload_len) > limit {
            return Err(GatewayError::new(format!(
                "MPEG-TS input backpressure for program {}",
                self.program_number
            ))
            .boxed());
        }
        self.appsrc
            .push_buffer(gst::Buffer::from_slice(packet.payload.clone()))
            .map_err(|source| {
                GatewayError::with_source("GStreamer rejected MPEG-TS payload", Box::new(source))
                    .boxed()
            })?;
        Ok(())
    }

    fn drain_bus(&mut self, logger: &EventLogger, context: &SessionContext) -> bool {
        let Some(bus) = self.pipeline.bus() else {
            logger.media_pipeline_failed_message(
                context.connection_id.as_ref(),
                context.peer,
                "pipeline has no bus",
            );
            return true;
        };
        let mut failed = false;
        for message in bus.iter_timed(gst::ClockTime::ZERO) {
            match message.view() {
                gst::MessageView::Error(error) => {
                    logger.media_pipeline_failed_message(
                        context.connection_id.as_ref(),
                        context.peer,
                        error.error().to_string().as_str(),
                    );
                    failed = true;
                }
                gst::MessageView::Warning(warning) => logger.media_pipeline_warning(
                    context.connection_id.as_ref(),
                    self.program_number,
                    warning.error().to_string().as_str(),
                ),
                _ => {}
            }
        }
        failed
    }

    fn stop(&mut self, logger: &EventLogger, context: &SessionContext, reason: &'static str) {
        if let Err(source) = self.appsrc.end_of_stream() {
            logger.media_pipeline_warning(
                context.connection_id.as_ref(),
                self.program_number,
                source.to_string().as_str(),
            );
        }
        if let Err(source) = self.pipeline.set_state(gst::State::Null) {
            logger.media_pipeline_warning(
                context.connection_id.as_ref(),
                self.program_number,
                source.to_string().as_str(),
            );
        }
        logger.media_pipeline_closed(
            context.connection_id.as_ref(),
            context.peer,
            self.program_number,
            reason,
        );
    }
}

#[derive(Clone)]
struct DynamicPadContext {
    pipeline: gst::Pipeline,
    session: SessionContext,
    program_number: u16,
    routes: RouteTable,
    config: MediaConfig,
    senders: TrackSenders,
    next_group_id: Arc<AtomicU64>,
    logger: EventLogger,
}

impl DynamicPadContext {
    fn attach(&self, pad: &gst::Pad) {
        if let Err(source) = self.try_attach(pad) {
            self.logger.media_stream_rejected(
                self.session.connection_id.as_ref(),
                self.program_number,
                pid_from_pad_name(pad.name().as_str()),
                source.as_ref(),
            );
            if let Err(fallback) = attach_fakesink(&self.pipeline, pad) {
                self.logger.media_pipeline_failed(
                    self.session.connection_id.as_ref(),
                    self.session.peer,
                    fallback.as_ref(),
                );
            }
        }
    }

    fn try_attach(&self, pad: &gst::Pad) -> GatewayResult<()> {
        let pid = pid_from_pad_name(pad.name().as_str())
            .ok_or_else(|| GatewayError::new("tsdemux pad has no MPEG-TS PID suffix").boxed())?;
        let track = self
            .routes
            .resolve(self.session.stream_id.as_ref(), self.program_number, pid)
            .ok_or_else(|| GatewayError::new("PID is not configured for this Stream ID").boxed())?;
        let caps = pad.current_caps().unwrap_or_else(|| pad.query_caps(None));
        let codec = codec_for_caps(track, &caps)?;
        let queue = make_element("queue")?;
        queue.set_property("max-size-buffers", 64_u32);
        queue.set_property("max-size-bytes", 0_u32);
        queue.set_property("max-size-time", 0_u64);
        let parser = make_element(parser_for(codec))?;
        let uses_cmaf =
            codec == Codec::H264 && matches!(track, TrackId::VideoHq | TrackId::VideoLq);
        let appsink = build_appsink(self.config.output_queue_objects, codec, uses_cmaf)?;
        let callback = SampleContext {
            session: self.session.clone(),
            program_number: self.program_number,
            pid,
            track,
            codec,
            uses_cmaf,
            max_object_bytes: self.config.max_object_bytes,
            sender: self.senders.for_track(track),
            sequence: Arc::new(Mutex::new(SequenceState::default())),
            cmaf_init: Arc::new(Mutex::new(None)),
            next_group_id: Arc::clone(&self.next_group_id),
            logger: self.logger.clone(),
        };
        let preroll_callback = callback.clone();
        appsink.set_callbacks(
            gst_app::AppSinkCallbacks::builder()
                .new_sample(move |sink| callback.handle_sample(sink))
                .new_preroll(move |sink| preroll_callback.handle_preroll(sink))
                .build(),
        );
        let mut branch = vec![queue.clone(), parser.clone()];
        if uses_cmaf {
            let caps_filter = make_element("capsfilter")?;
            caps_filter.set_property(
                "caps",
                gst::Caps::builder("video/x-h264")
                    .field("stream-format", "avc")
                    .field("alignment", "au")
                    .build(),
            );
            let muxer = make_element("cmafmux")?;
            muxer.set_property("fragment-duration", CMAF_FRAGMENT_DURATION_NS);
            muxer.set_property("chunk-duration", CMAF_CHUNK_DURATION_NS);
            branch.push(caps_filter);
            branch.push(muxer);
        }
        branch.push(appsink.clone().upcast());
        self.pipeline
            .add_many(branch.iter())
            .map_err(gst_error("failed to add encoded media branch"))?;
        gst::Element::link_many(branch.iter())
            .map_err(gst_error("failed to link encoded media branch"))?;
        let sink_pad = queue
            .static_pad("sink")
            .ok_or_else(|| GatewayError::new("queue has no static sink pad").boxed())?;
        pad.link(&sink_pad)
            .map_err(gst_error("failed to link tsdemux dynamic pad"))?;
        for element in &branch {
            element
                .sync_state_with_parent()
                .map_err(gst_error("failed to synchronize encoded media branch"))?;
        }
        self.logger.mpegts_stream_discovered(
            self.session.connection_id.as_ref(),
            self.program_number,
            pid,
            track.value(),
            codec.as_str(),
        );
        Ok(())
    }
}

fn build_appsink(
    output_queue_objects: usize,
    codec: Codec,
    uses_cmaf: bool,
) -> GatewayResult<gst_app::AppSink> {
    let max_buffers = u32::try_from(output_queue_objects).map_err(|source| {
        GatewayError::with_source("media output queue does not fit u32", Box::new(source)).boxed()
    })?;
    let builder = gst_app::AppSink::builder()
        .max_buffers(max_buffers)
        .drop(false)
        .sync(false)
        .wait_on_eos(false);
    let appsink = if uses_cmaf {
        let caps = gst::Caps::builder("video/quicktime")
            .field("variant", "cmaf")
            .build();
        builder.caps(&caps).build()
    } else if let Some(caps) = parser_output_caps(codec) {
        builder.caps(&caps).build()
    } else {
        builder.build()
    };
    if uses_cmaf {
        appsink.set_property("buffer-list", true);
        appsink.set_property("async", false);
    }
    Ok(appsink)
}

#[derive(Clone)]
struct SampleContext {
    session: SessionContext,
    program_number: u16,
    pid: u16,
    track: TrackId,
    codec: Codec,
    uses_cmaf: bool,
    max_object_bytes: usize,
    sender: mpsc::Sender<MediaObject>,
    sequence: Arc<Mutex<SequenceState>>,
    cmaf_init: Arc<Mutex<Option<Bytes>>>,
    next_group_id: Arc<AtomicU64>,
    logger: EventLogger,
}

impl SampleContext {
    fn handle_sample(&self, sink: &gst_app::AppSink) -> Result<gst::FlowSuccess, gst::FlowError> {
        let sample = sink.pull_sample().map_err(|_| gst::FlowError::Error)?;
        self.process_sample(&sample)
    }

    fn handle_preroll(&self, sink: &gst_app::AppSink) -> Result<gst::FlowSuccess, gst::FlowError> {
        let sample = sink.pull_preroll().map_err(|_| gst::FlowError::Error)?;
        self.process_sample(&sample)
    }

    fn process_sample(&self, sample: &gst::Sample) -> Result<gst::FlowSuccess, gst::FlowError> {
        self.ensure_cmaf_initialization(sample)?;
        let extracted = match sample_payload(sample, self.uses_cmaf) {
            Ok(extracted) => extracted,
            Err(source) => {
                self.logger.media_output_backpressure(
                    self.session.connection_id.as_ref(),
                    self.track.value(),
                    "invalid_gstreamer_sample",
                );
                return Err(source);
            }
        };
        let Some(extracted) = extracted else {
            return Ok(gst::FlowSuccess::Ok);
        };
        if extracted.payload.len() > self.max_object_bytes {
            self.logger.media_output_backpressure(
                self.session.connection_id.as_ref(),
                self.track.value(),
                "object_too_large",
            );
            return Err(gst::FlowError::Error);
        }
        if self.uses_cmaf && is_cmaf_initialization(&extracted.payload) {
            let mut initialization = self.cmaf_init.lock().map_err(|_| gst::FlowError::Error)?;
            *initialization = Some(extracted.payload);
            return Ok(gst::FlowSuccess::Ok);
        }
        let cmaf_init = self.cmaf_initialization_for_payload(&extracted.payload)?;
        if self.track == TrackId::Telemetry
            && serde_json::from_slice::<serde_json::Value>(&extracted.payload).is_err()
        {
            self.logger.telemetry_invalid_json(
                self.session.connection_id.as_ref(),
                self.program_number,
                self.pid,
                extracted.payload.len(),
            );
            return Ok(gst::FlowSuccess::Ok);
        }
        let kind = self.classify(&extracted.payload, extracted.flags)?;
        self.record_discontinuity(extracted.flags);
        let object = self.build_object(extracted, cmaf_init, kind)?;
        if self.sender.try_send(object).is_err() {
            self.logger.media_output_backpressure(
                self.session.connection_id.as_ref(),
                self.track.value(),
                "track_queue_full",
            );
            return Err(gst::FlowError::Error);
        }
        Ok(gst::FlowSuccess::Ok)
    }

    fn ensure_cmaf_initialization(&self, sample: &gst::Sample) -> Result<(), gst::FlowError> {
        if !self.uses_cmaf
            || self
                .cmaf_init
                .lock()
                .map_err(|_| gst::FlowError::Error)?
                .is_some()
        {
            return Ok(());
        }
        let initialization = cmaf_initialization_from_caps(sample).inspect_err(|_source| {
            self.logger.media_output_backpressure(
                self.session.connection_id.as_ref(),
                self.track.value(),
                "missing_cmaf_initialization",
            );
        })?;
        let mut stored = self.cmaf_init.lock().map_err(|_| gst::FlowError::Error)?;
        *stored = Some(initialization);
        Ok(())
    }

    fn cmaf_initialization_for_payload(
        &self,
        payload: &Bytes,
    ) -> Result<Option<Bytes>, gst::FlowError> {
        if !self.uses_cmaf {
            return Ok(None);
        }
        if !is_cmaf_chunk(payload) {
            self.logger.media_output_backpressure(
                self.session.connection_id.as_ref(),
                self.track.value(),
                "invalid_cmaf_chunk",
            );
            return Err(gst::FlowError::Error);
        }
        self.cmaf_init
            .lock()
            .map_err(|_| gst::FlowError::Error)?
            .clone()
            .ok_or(gst::FlowError::Error)
            .map(Some)
    }

    fn classify(
        &self,
        payload: &Bytes,
        flags: gst::BufferFlags,
    ) -> Result<AccessUnitKind, gst::FlowError> {
        let is_delta = if self.uses_cmaf {
            match crate::cmsf::cmaf_chunk_is_random_access(payload) {
                Ok(random_access) => !random_access,
                Err(source) => {
                    self.logger.media_output_backpressure(
                        self.session.connection_id.as_ref(),
                        self.track.value(),
                        "invalid_cmaf_sample_flags",
                    );
                    tracing::warn!(
                        event = "invalid_cmaf_sample_flags",
                        connection_id = self.session.connection_id.as_ref(),
                        track = self.track.value(),
                        error = %source,
                        "rejected CMAF chunk with invalid sample flags"
                    );
                    return Err(gst::FlowError::Error);
                }
            }
        } else {
            flags.contains(gst::BufferFlags::DELTA_UNIT)
        };
        Ok(match self.track {
            TrackId::VideoHq | TrackId::VideoLq if is_delta => AccessUnitKind::Delta,
            TrackId::VideoHq | TrackId::VideoLq => AccessUnitKind::RandomAccess,
            TrackId::CriticalAudio => AccessUnitKind::Audio,
            TrackId::Telemetry => AccessUnitKind::Telemetry,
        })
    }

    fn record_discontinuity(&self, flags: gst::BufferFlags) {
        if flags.contains(gst::BufferFlags::DISCONT) {
            self.logger.mpegts_discontinuity(
                self.session.connection_id.as_ref(),
                self.program_number,
                self.pid,
                self.track.value(),
            );
        }
    }

    fn build_object(
        &self,
        extracted: ExtractedSample,
        cmaf_init: Option<Bytes>,
        kind: AccessUnitKind,
    ) -> Result<MediaObject, gst::FlowError> {
        let mut sequence = self.sequence.lock().map_err(|_| gst::FlowError::Error)?;
        if should_start_new_group(&sequence, kind) {
            sequence.group_id = Some(self.next_group_id.fetch_add(1, Ordering::Relaxed));
            sequence.object_id = 0;
            sequence.group_random_access = kind == AccessUnitKind::RandomAccess;
        }
        let group_id = sequence.group_id.ok_or(gst::FlowError::Error)?;
        let received_at = *self
            .session
            .latest_received_at
            .lock()
            .map_err(|_| gst::FlowError::Error)?;
        let object = MediaObject {
            group: Group {
                id: group_id,
                track: Track { id: self.track },
                random_access: sequence.group_random_access,
            },
            object_id: sequence.object_id,
            program_number: self.program_number,
            pid: self.pid,
            codec: self.codec,
            kind,
            pts_ns: extracted.pts_ns,
            dts_ns: extracted.dts_ns,
            payload: extracted.payload,
            cmaf_init,
            connection_id: Arc::clone(&self.session.connection_id),
            peer: self.session.peer,
            received_at,
        };
        sequence.object_id = sequence.object_id.saturating_add(1);
        Ok(object)
    }
}

fn should_start_new_group(sequence: &SequenceState, kind: AccessUnitKind) -> bool {
    sequence.group_id.is_none()
        || kind == AccessUnitKind::RandomAccess
        || (matches!(kind, AccessUnitKind::Audio | AccessUnitKind::Telemetry)
            && sequence.object_id >= CRITICAL_OBJECTS_PER_GROUP)
}

struct ExtractedSample {
    payload: Bytes,
    flags: gst::BufferFlags,
    pts_ns: Option<u64>,
    dts_ns: Option<u64>,
}

fn cmaf_initialization_from_caps(sample: &gst::Sample) -> Result<Bytes, gst::FlowError> {
    let caps = sample.caps().ok_or(gst::FlowError::NotNegotiated)?;
    let structure = caps.structure(0).ok_or(gst::FlowError::NotNegotiated)?;
    let headers = structure
        .get::<gst::ArrayRef>("streamheader")
        .map_err(|_| gst::FlowError::NotNegotiated)?;
    let header = headers
        .first()
        .and_then(|value| value.get::<gst::Buffer>().ok())
        .ok_or(gst::FlowError::NotNegotiated)?;
    let map = header.map_readable().map_err(|_| gst::FlowError::Error)?;
    if !is_cmaf_initialization(map.as_slice()) {
        return Err(gst::FlowError::NotNegotiated);
    }
    Ok(Bytes::copy_from_slice(map.as_slice()))
}

fn sample_payload(
    sample: &gst::Sample,
    uses_cmaf: bool,
) -> Result<Option<ExtractedSample>, gst::FlowError> {
    if let Some(list) = sample.buffer_list() {
        let (first_index, first_offset) = if uses_cmaf {
            match cmaf_fragment_header_position(list)? {
                Some(position) => position,
                None => return Ok(None),
            }
        } else {
            (0, 0)
        };
        let first = list.get(first_index).ok_or(gst::FlowError::Error)?;
        let mut payload = Vec::with_capacity(list.calculate_size().saturating_sub(first_offset));
        for (relative_index, buffer) in list.iter().skip(first_index).enumerate() {
            let map = buffer.map_readable().map_err(|_| gst::FlowError::Error)?;
            let offset = if relative_index == 0 { first_offset } else { 0 };
            let bytes = map.as_slice().get(offset..).ok_or(gst::FlowError::Error)?;
            payload.extend_from_slice(bytes);
        }
        return Ok(Some(ExtractedSample {
            payload: Bytes::from(payload),
            flags: first.flags(),
            pts_ns: first.pts().map(gst::ClockTime::nseconds),
            dts_ns: first.dts().map(gst::ClockTime::nseconds),
        }));
    }
    let buffer = sample.buffer().ok_or(gst::FlowError::Error)?;
    let map = buffer.map_readable().map_err(|_| gst::FlowError::Error)?;
    Ok(Some(ExtractedSample {
        payload: Bytes::copy_from_slice(map.as_slice()),
        flags: buffer.flags(),
        pts_ns: buffer.pts().map(gst::ClockTime::nseconds),
        dts_ns: buffer.dts().map(gst::ClockTime::nseconds),
    }))
}

fn cmaf_fragment_header_position(
    list: &gst::BufferListRef,
) -> Result<Option<(usize, usize)>, gst::FlowError> {
    for (index, buffer) in list.iter().enumerate() {
        let map = buffer.map_readable().map_err(|_| gst::FlowError::Error)?;
        if let Some(offset) = iso_box_offset(map.as_slice(), *b"moof") {
            return Ok(Some((index, offset)));
        }
    }
    let mut initialization = Vec::with_capacity(list.calculate_size());
    for buffer in list {
        let map = buffer.map_readable().map_err(|_| gst::FlowError::Error)?;
        initialization.extend_from_slice(map.as_slice());
    }
    if is_cmaf_initialization(&initialization) {
        Ok(None)
    } else {
        Err(gst::FlowError::Error)
    }
}

fn iso_box_offset(bytes: &[u8], wanted_type: [u8; 4]) -> Option<usize> {
    let mut offset = 0_usize;
    while bytes.len().saturating_sub(offset) >= 8 {
        let size_bytes: [u8; 4] = bytes
            .get(offset..offset.saturating_add(4))?
            .try_into()
            .ok()?;
        let box_size = usize::try_from(u32::from_be_bytes(size_bytes)).ok()?;
        if bytes.get(offset.saturating_add(4)..offset.saturating_add(8)) == Some(&wanted_type) {
            return Some(offset);
        }
        if box_size < 8 || box_size > bytes.len().saturating_sub(offset) {
            return None;
        }
        offset = offset.saturating_add(box_size);
    }
    None
}

#[derive(Default)]
struct SequenceState {
    group_id: Option<u64>,
    object_id: u64,
    group_random_access: bool,
}

fn audit_factories() -> GatewayResult<()> {
    for name in REQUIRED_FACTORIES {
        let factory = gst::ElementFactory::find(name).ok_or_else(|| {
            GatewayError::new(format!(
                "required GStreamer element '{name}' is unavailable"
            ))
            .boxed()
        })?;
        let class = factory.metadata("klass").unwrap_or_default();
        if class.contains("Decoder") || class.contains("Encoder") {
            return Err(GatewayError::new(format!(
                "zero-transcoding policy rejects GStreamer element '{name}' ({class})"
            ))
            .boxed());
        }
    }
    Ok(())
}

fn make_element(factory: &'static str) -> GatewayResult<gst::Element> {
    gst::ElementFactory::make(factory)
        .build()
        .map_err(|source| {
            GatewayError::with_source(
                format!("failed to create GStreamer element '{factory}'"),
                Box::new(source),
            )
            .boxed()
        })
}

fn attach_fakesink(pipeline: &gst::Pipeline, pad: &gst::Pad) -> GatewayResult<()> {
    let sink = make_element("fakesink")?;
    sink.set_property("sync", false);
    pipeline
        .add(&sink)
        .map_err(gst_error("failed to add fallback fakesink"))?;
    let sink_pad = sink
        .static_pad("sink")
        .ok_or_else(|| GatewayError::new("fakesink has no static sink pad").boxed())?;
    pad.link(&sink_pad)
        .map_err(gst_error("failed to link fallback fakesink"))?;
    sink.sync_state_with_parent()
        .map_err(gst_error("failed to start fallback fakesink"))?;
    Ok(())
}

fn codec_for_caps(track: TrackId, caps: &gst::Caps) -> GatewayResult<Codec> {
    let structure = caps
        .structure(0)
        .ok_or_else(|| GatewayError::new("elementary stream has no caps").boxed())?;
    let name = structure.name();
    let codec = match (track, name.as_str()) {
        (TrackId::VideoHq | TrackId::VideoLq, "video/x-h264") => Codec::H264,
        (TrackId::VideoHq | TrackId::VideoLq, "video/x-h265") => Codec::H265,
        (TrackId::VideoHq | TrackId::VideoLq, "video/mpeg")
            if structure.get::<i32>("mpegversion") == Ok(2) =>
        {
            Codec::Mpeg2Video
        }
        (TrackId::CriticalAudio, "audio/mpeg") if structure.get::<i32>("mpegversion") == Ok(4) => {
            Codec::Aac
        }
        (TrackId::CriticalAudio, "audio/x-opus") => Codec::Opus,
        (TrackId::CriticalAudio, "audio/x-ac3") => Codec::Ac3,
        (TrackId::CriticalAudio, "audio/x-eac3") => Codec::Eac3,
        (TrackId::Telemetry, "private/teletext" | "meta/x-klv" | "application/x-id3") => {
            Codec::Json
        }
        _ => {
            return Err(GatewayError::new(format!(
                "unsupported or mismatched caps '{name}' for Track {}",
                track.value()
            ))
            .boxed());
        }
    };
    Ok(codec)
}

const fn parser_for(codec: Codec) -> &'static str {
    match codec {
        Codec::H264 => "h264parse",
        Codec::H265 => "h265parse",
        Codec::Mpeg2Video => "mpegvideoparse",
        Codec::Aac => "aacparse",
        Codec::Opus => "opusparse",
        Codec::Ac3 | Codec::Eac3 => "ac3parse",
        Codec::Json => "identity",
    }
}

fn parser_output_caps(codec: Codec) -> Option<gst::Caps> {
    match codec {
        Codec::H265 => Some(
            gst::Caps::builder("video/x-h265")
                .field("stream-format", "byte-stream")
                .field("alignment", "au")
                .build(),
        ),
        _ => None,
    }
}

fn is_cmaf_initialization(payload: &[u8]) -> bool {
    payload.get(4..8) == Some(b"ftyp") && payload.windows(4).any(|window| window == b"moov")
}

fn is_cmaf_chunk(payload: &[u8]) -> bool {
    payload.get(4..8) == Some(b"moof") && payload.windows(4).any(|window| window == b"mdat")
}

fn pid_from_pad_name(name: &str) -> Option<u16> {
    name.rsplit('_')
        .next()
        .and_then(|suffix| u16::from_str_radix(suffix, 16).ok())
}

fn gst_error<E>(message: &'static str) -> impl FnOnce(E) -> crate::error::BoxError
where
    E: std::error::Error + Send + Sync + 'static,
{
    move |source| GatewayError::with_source(message, Box::new(source)).boxed()
}

#[must_use]
pub const fn maintenance_interval() -> Duration {
    Duration::from_secs(1)
}

#[cfg(test)]
mod tests {
    use super::{
        AccessUnitKind, CRITICAL_OBJECTS_PER_GROUP, Codec, SequenceState, audit_factories,
        codec_for_caps, pid_from_pad_name, should_start_new_group,
    };
    use crate::routing::TrackId;
    use gstreamer as gst;

    #[test]
    fn extracts_pid_from_real_tsdemux_pad_name() {
        assert_eq!(pid_from_pad_name("video_0_0100"), Some(0x100));
        assert_eq!(pid_from_pad_name("audio_1_0101"), Some(0x101));
        assert_eq!(pid_from_pad_name("video_without_pid"), None);
    }

    #[test]
    fn classifies_supported_encoded_caps() -> crate::error::GatewayResult<()> {
        gst::init().map_err(|source| {
            crate::error::GatewayError::with_source(
                "failed to initialize GStreamer in test",
                Box::new(source),
            )
            .boxed()
        })?;
        let caps = gst::Caps::builder("video/x-h264").build();
        assert_eq!(codec_for_caps(TrackId::VideoHq, &caps)?, Codec::H264);
        assert!(codec_for_caps(TrackId::CriticalAudio, &caps).is_err());
        Ok(())
    }

    #[test]
    fn required_topology_has_no_encoder_or_decoder() -> crate::error::GatewayResult<()> {
        gst::init().map_err(|source| {
            crate::error::GatewayError::with_source(
                "failed to initialize GStreamer in test",
                Box::new(source),
            )
            .boxed()
        })?;
        audit_factories()
    }

    #[test]
    fn rotates_critical_groups_before_the_subgroup_object_limit() {
        let sequence = SequenceState {
            group_id: Some(7),
            object_id: CRITICAL_OBJECTS_PER_GROUP,
            group_random_access: false,
        };
        assert!(should_start_new_group(&sequence, AccessUnitKind::Audio));
        assert!(should_start_new_group(&sequence, AccessUnitKind::Telemetry));
        assert!(!should_start_new_group(&sequence, AccessUnitKind::Delta));
    }
}
