//! Publisher `MoQT` draft-16 sobre la implementación oficial de `moq-rs`.

use std::{collections::VecDeque, sync::Arc, time::Duration};

use moq_native_ietf::quic;
use moq_transport::{
    coding::TrackNamespace,
    serve::{self, Subgroup, SubgroupWriter, SubgroupsWriter},
    session::Publisher,
};
use tokio_util::sync::CancellationToken;

use crate::{
    cmsf::{CATALOG_TRACK, h264_video_catalogs},
    config::MoqConfig,
    error::{GatewayError, GatewayResult},
    observability::EventLogger,
    routing::TrackId,
    scheduler::{ScheduledObject, SubscriberId, SubscriberReceiver, SubscriberScheduler},
    supervisor::SignalMonitor,
};

const TRACK_VIDEO_HQ: &str = "0-video-hq";
const TRACK_VIDEO_LQ: &str = "1-video-lq";
const TRACK_CRITICAL_AUDIO: &str = "2-critical-audio";
const TRACK_TELEMETRY: &str = "3-telemetry";

/// Ejecuta un publisher resiliente. Una caída del relay vacía solo su sesión y
/// activa reconexión; nunca termina la ingesta ni conserva vídeo indefinidamente.
///
/// # Errors
///
/// Devuelve error si la configuración TLS/QUIC local no puede inicializarse o
/// si el scheduler deja de mantener sus invariantes internas.
pub async fn run_moq_publisher(
    config: MoqConfig,
    endpoint: quic::Endpoint,
    scheduler: Arc<SubscriberScheduler>,
    monitor: Arc<SignalMonitor>,
    cancellation: CancellationToken,
    logger: EventLogger,
) -> GatewayResult<()> {
    let local_addr = endpoint.client.local_addr().map_err(|source| {
        GatewayError::with_source(
            "failed to inspect MoQT client socket",
            source.into_boxed_dyn_error(),
        )
        .boxed()
    })?;
    logger.moq_publisher_ready(local_addr, "draft-16", "moqt-16");

    let mut generation = 0_u64;
    let mut retries = RetryPolicy::new(&config);
    loop {
        if cancellation.is_cancelled() {
            return Ok(());
        }
        if !retries
            .admit_attempt(&cancellation, &logger, &relay_origin(&config))
            .await
        {
            return Ok(());
        }
        generation = generation.saturating_add(1);
        let relay = relay_origin(&config);
        logger.moq_connection_attempt(&relay, generation);

        let connected =
            connect_publisher_session(endpoint.client.clone(), &config, &cancellation).await;
        let Some((session, publisher, connection_id)) = (match connected {
            Ok(connected) => connected,
            Err(source) => {
                logger.moq_mtls_handshake_failed(classify_handshake_failure(source.as_ref()));
                handle_connection_failure(
                    &mut retries,
                    &cancellation,
                    &logger,
                    &relay,
                    generation,
                    source.to_string(),
                )
                .await;
                continue;
            }
        }) else {
            return Ok(());
        };
        retries.connected();

        let subscriber_id = SubscriberId::new(format!("moq-relay-{generation}"))?;
        let receiver = match scheduler.register(subscriber_id) {
            Ok(receiver) => receiver,
            Err(source) => {
                handle_connection_failure(
                    &mut retries,
                    &cancellation,
                    &logger,
                    &relay,
                    generation,
                    source.to_string(),
                )
                .await;
                continue;
            }
        };
        monitor.record_scheduler(scheduler.snapshot(), None);
        monitor.record_moq_connected(&connection_id, &relay);
        logger.moq_connected(&connection_id, &relay, generation);

        let result = Box::pin(serve_connection(
            session,
            publisher,
            receiver,
            &config.namespace,
            Arc::clone(&scheduler),
            Arc::clone(&monitor),
            cancellation.child_token(),
            &logger,
        ))
        .await;
        monitor.record_moq_disconnected();
        monitor.record_scheduler(scheduler.snapshot(), Some(tokio::time::Instant::now()));

        if cancellation.is_cancelled() {
            return Ok(());
        }
        match result {
            Ok(()) => logger.moq_disconnected(&connection_id, "peer_closed"),
            Err(source) => logger.moq_session_failed(&connection_id, source.as_ref()),
        }
        retries
            .wait_after_failure(&cancellation, &logger, &relay, generation)
            .await;
    }
}

async fn connect_publisher_session(
    client: quic::Client,
    config: &MoqConfig,
    cancellation: &CancellationToken,
) -> GatewayResult<Option<(moq_transport::session::Session, Publisher, String)>> {
    let connection = tokio::select! {
        () = cancellation.cancelled() => return Ok(None),
        result = tokio::time::timeout(
            config.connect_timeout,
            client.connect(&config.relay_url, None),
        ) => result,
    }
    .map_err(|source| external_error("MoQT connection timed out", source))?
    .map_err(|source| {
        GatewayError::with_source("MoQT connection failed", source.into_boxed_dyn_error()).boxed()
    })?;
    let (webtransport, connection_id, transport) = connection;
    let setup = tokio::select! {
        () = cancellation.cancelled() => return Ok(None),
        result = tokio::time::timeout(
            config.connect_timeout,
            Publisher::connect(webtransport, transport),
        ) => result,
    }
    .map_err(|source| external_error("MoQT setup timed out", source))?
    .map_err(|source| external_error("MoQT setup failed", source))?;
    let (session, publisher) = setup;
    Ok(Some((session, publisher, connection_id)))
}

async fn handle_connection_failure(
    retries: &mut RetryPolicy,
    cancellation: &CancellationToken,
    logger: &EventLogger,
    relay: &str,
    generation: u64,
    source: String,
) {
    logger.moq_connection_failed(relay, generation, &source);
    retries
        .wait_after_failure(cancellation, logger, relay, generation)
        .await;
}

#[allow(clippy::too_many_arguments)]
async fn serve_connection(
    session: moq_transport::session::Session,
    publisher: Publisher,
    receiver: SubscriberReceiver,
    namespace: &str,
    scheduler: Arc<SubscriberScheduler>,
    monitor: Arc<SignalMonitor>,
    cancellation: CancellationToken,
    logger: &EventLogger,
) -> GatewayResult<()> {
    let namespace = TrackNamespace::from_utf8_path(namespace);
    let (mut tracks_writer, _track_requests, tracks_reader) =
        serve::Tracks::new(namespace.clone()).produce();
    let mut tracks = MoqTrackWriters::new(&mut tracks_writer)?;
    logger.moq_namespace_publish_started(&namespace.to_utf8_path());

    let mut namespace_publisher = publisher.clone();
    tokio::select! {
        biased;
        () = cancellation.cancelled() => Ok(()),
        result = session.run() => result.map_err(|source| {
            GatewayError::with_source("MoQT session ended", Box::new(source)).boxed()
        }),
        result = namespace_publisher.publish_namespace(tracks_reader) => result.map_err(|source| {
            GatewayError::with_source("MoQT namespace publication ended", Box::new(source)).boxed()
        }),
        result = publish_objects(
            &receiver,
            &mut tracks,
            scheduler,
            monitor,
            cancellation.clone(),
            logger,
        ) => result,
    }
}

async fn publish_objects(
    receiver: &SubscriberReceiver,
    tracks: &mut MoqTrackWriters,
    scheduler: Arc<SubscriberScheduler>,
    monitor: Arc<SignalMonitor>,
    cancellation: CancellationToken,
    logger: &EventLogger,
) -> GatewayResult<()> {
    loop {
        let object = tokio::select! {
            () = cancellation.cancelled() => return Ok(()),
            result = receiver.receive() => result?,
        };
        let Some(object) = object else {
            return Err(GatewayError::new("MoQT relay scheduler session was evicted").boxed());
        };
        tracks.ensure_catalog(&object)?;
        publish_object(tracks.writer(object.track), &object)?;
        logger.moq_object_published(&object);
        monitor.record_moq_object(&object);
        monitor.record_scheduler(scheduler.snapshot(), Some(tokio::time::Instant::now()));
    }
}

fn publish_object(writer: &mut MoqTrackPublisher, object: &ScheduledObject) -> GatewayResult<()> {
    writer.write(object)
}

struct MoqTrackPublisher {
    subgroups: SubgroupsWriter,
    active: Option<(u64, SubgroupWriter)>,
}

impl MoqTrackPublisher {
    fn new(subgroups: SubgroupsWriter) -> Self {
        Self {
            subgroups,
            active: None,
        }
    }

    fn write(&mut self, object: &ScheduledObject) -> GatewayResult<()> {
        if let Some((group_id, _)) = self.active.as_ref()
            && object.group.id < *group_id
        {
            return Err(GatewayError::new("MoQT Object belongs to an obsolete Group").boxed());
        }
        if self
            .active
            .as_ref()
            .is_none_or(|(group_id, _)| *group_id != object.group.id)
        {
            self.active = None;
            let subgroup = self
                .subgroups
                .create(Subgroup {
                    group_id: object.group.id,
                    subgroup_id: 0,
                    priority: object.priority.value(),
                })
                .map_err(|source| {
                    GatewayError::with_source(
                        "failed to create upstream MoQT subgroup",
                        Box::new(source),
                    )
                    .boxed()
                })?;
            self.active = Some((object.group.id, subgroup));
        }
        let Some((_, subgroup)) = self.active.as_mut() else {
            return Err(GatewayError::new("MoQT subgroup state was not initialized").boxed());
        };
        subgroup.write(object.payload.clone()).map_err(|source| {
            GatewayError::with_source("failed to write upstream MoQT Object", Box::new(source))
                .boxed()
        })
    }
}

struct MoqTrackWriters {
    catalog: SubgroupsWriter,
    catalog_inits: [Option<bytes::Bytes>; 2],
    catalog_generation: u64,
    video_hq: MoqTrackPublisher,
    video_lq: MoqTrackPublisher,
    critical_audio: MoqTrackPublisher,
    telemetry: MoqTrackPublisher,
}

impl MoqTrackWriters {
    fn new(writer: &mut serve::TracksWriter) -> GatewayResult<Self> {
        Ok(Self {
            catalog: create_track(writer, CATALOG_TRACK)?,
            catalog_inits: [None, None],
            catalog_generation: 0,
            video_hq: MoqTrackPublisher::new(create_track(writer, TRACK_VIDEO_HQ)?),
            video_lq: MoqTrackPublisher::new(create_track(writer, TRACK_VIDEO_LQ)?),
            critical_audio: MoqTrackPublisher::new(create_track(writer, TRACK_CRITICAL_AUDIO)?),
            telemetry: MoqTrackPublisher::new(create_track(writer, TRACK_TELEMETRY)?),
        })
    }

    fn writer(&mut self, track: TrackId) -> &mut MoqTrackPublisher {
        match track {
            TrackId::VideoHq => &mut self.video_hq,
            TrackId::VideoLq => &mut self.video_lq,
            TrackId::CriticalAudio => &mut self.critical_audio,
            TrackId::Telemetry => &mut self.telemetry,
        }
    }

    fn ensure_catalog(&mut self, object: &ScheduledObject) -> GatewayResult<()> {
        let Some(initialization) = object.cmaf_init.as_ref() else {
            return Ok(());
        };
        let Some(index) = video_catalog_index(object.track) else {
            return Ok(());
        };
        if self.catalog_inits[index].as_ref() == Some(initialization) {
            return Ok(());
        }
        let mut next_inits = self.catalog_inits.clone();
        next_inits[index] = Some(initialization.clone());
        let mut entries = Vec::with_capacity(2);
        if let Some(init) = next_inits[0].as_ref() {
            entries.push((TRACK_VIDEO_HQ, init));
        }
        if let Some(init) = next_inits[1].as_ref() {
            entries.push((TRACK_VIDEO_LQ, init));
        }
        let payload = h264_video_catalogs(&entries)?;
        let mut subgroup = self
            .catalog
            .create(Subgroup {
                group_id: self.catalog_generation,
                subgroup_id: 0,
                priority: 0,
            })
            .map_err(|source| {
                GatewayError::with_source("failed to create MSF catalog subgroup", Box::new(source))
                    .boxed()
            })?;
        subgroup.write(payload).map_err(|source| {
            GatewayError::with_source("failed to publish MSF catalog", Box::new(source)).boxed()
        })?;
        self.catalog_inits = next_inits;
        self.catalog_generation = self.catalog_generation.saturating_add(1);
        Ok(())
    }
}

const fn video_catalog_index(track: TrackId) -> Option<usize> {
    match track {
        TrackId::VideoHq => Some(0),
        TrackId::VideoLq => Some(1),
        TrackId::CriticalAudio | TrackId::Telemetry => None,
    }
}

fn create_track(
    writer: &mut serve::TracksWriter,
    name: &'static str,
) -> GatewayResult<SubgroupsWriter> {
    let track = writer.create(name).ok_or_else(|| {
        GatewayError::new(format!("MoQT Tracks writer closed while creating '{name}'")).boxed()
    })?;
    track.subgroups().map_err(|source| {
        GatewayError::with_source(
            format!("failed to create MoQT Track '{name}'"),
            Box::new(source),
        )
        .boxed()
    })
}

struct RetryPolicy {
    initial_delay: Duration,
    maximum_delay: Duration,
    maximum_attempts: usize,
    window: Duration,
    consecutive_failures: u32,
    attempts: VecDeque<tokio::time::Instant>,
}

impl RetryPolicy {
    fn new(config: &MoqConfig) -> Self {
        Self {
            initial_delay: config.reconnect_delay,
            maximum_delay: config.reconnect_max_delay,
            maximum_attempts: config.retry_max_attempts,
            window: config.retry_window,
            consecutive_failures: 0,
            attempts: VecDeque::with_capacity(config.retry_max_attempts),
        }
    }

    async fn admit_attempt(
        &mut self,
        cancellation: &CancellationToken,
        logger: &EventLogger,
        relay: &str,
    ) -> bool {
        loop {
            let now = tokio::time::Instant::now();
            self.prune(now);
            if self.attempts.len() < self.maximum_attempts {
                self.attempts.push_back(now);
                return true;
            }
            let Some(oldest) = self.attempts.front().copied() else {
                continue;
            };
            let wait = self
                .window
                .saturating_sub(now.saturating_duration_since(oldest));
            logger.moq_retry_budget_exhausted(
                relay,
                self.maximum_attempts,
                duration_millis(self.window),
                duration_millis(wait),
            );
            tokio::select! {
                () = cancellation.cancelled() => return false,
                () = tokio::time::sleep(wait) => {}
            }
        }
    }

    async fn wait_after_failure(
        &mut self,
        cancellation: &CancellationToken,
        logger: &EventLogger,
        relay: &str,
        generation: u64,
    ) {
        let delay = backoff_delay(
            self.initial_delay,
            self.maximum_delay,
            self.consecutive_failures,
        );
        self.consecutive_failures = self.consecutive_failures.saturating_add(1);
        logger.moq_reconnect_scheduled(
            relay,
            generation,
            self.consecutive_failures,
            duration_millis(delay),
        );
        tokio::select! {
            () = cancellation.cancelled() => {}
            () = tokio::time::sleep(delay) => {}
        }
    }

    fn connected(&mut self) {
        self.consecutive_failures = 0;
    }

    fn prune(&mut self, now: tokio::time::Instant) {
        while self
            .attempts
            .front()
            .is_some_and(|attempt| now.saturating_duration_since(*attempt) >= self.window)
        {
            self.attempts.pop_front();
        }
    }
}

fn backoff_delay(initial: Duration, maximum: Duration, consecutive_failures: u32) -> Duration {
    let exponent = consecutive_failures.min(16);
    let factor = 1_u32.checked_shl(exponent).unwrap_or(u32::MAX);
    let base = initial.saturating_mul(factor).min(maximum);
    jitter(base).min(maximum)
}

fn jitter(delay: Duration) -> Duration {
    let mut random = [0_u8; 1];
    let percentage = if getrandom::fill(&mut random).is_ok() {
        80_u32.saturating_add(u32::from(random[0]) % 41)
    } else {
        100
    };
    delay.saturating_mul(percentage) / 100
}

fn duration_millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).map_or(u64::MAX, std::convert::identity)
}

fn relay_origin(config: &MoqConfig) -> String {
    let host = config.relay_url.host_str().unwrap_or("invalid-host");
    let port = config
        .relay_url
        .port()
        .map_or_else(String::new, |port| format!(":{port}"));
    format!("{}://{host}{port}", config.relay_url.scheme())
}

fn external_error(
    context: &str,
    source: impl std::error::Error + Send + Sync + 'static,
) -> crate::error::BoxError {
    GatewayError::with_source(context, Box::new(source)).boxed()
}

fn classify_handshake_failure(source: &(dyn std::error::Error + 'static)) -> &'static str {
    let mut current = Some(source);
    while let Some(error) = current {
        if error.is::<tokio::time::error::Elapsed>() {
            return "handshake_timeout";
        }
        let message = error.to_string().to_ascii_lowercase();
        if message.contains("certificate") || message.contains("cert") {
            return "peer_certificate_rejected";
        }
        current = error.source();
    }
    "handshake_failed"
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use bytes::Bytes;
    use moq_transport::{coding::TrackNamespace, serve::TrackReaderMode};

    use super::{
        MoqTrackWriters, RetryPolicy, TRACK_VIDEO_HQ, backoff_delay, jitter, publish_object,
    };
    use crate::{
        config::GatewayConfig,
        error::{GatewayError, GatewayResult},
        media::{Codec, Group, Track},
        routing::TrackId,
        scheduler::{Priority, ScheduledObject},
    };

    #[test]
    fn reconnect_jitter_remains_inside_twenty_percent() {
        let base = std::time::Duration::from_millis(1_000);
        for _sample in 0..256 {
            let value = jitter(base);
            assert!(value >= std::time::Duration::from_millis(800));
            assert!(value <= std::time::Duration::from_millis(1_200));
        }
    }

    #[test]
    fn reconnect_backoff_never_exceeds_its_effective_ceiling() {
        let initial = std::time::Duration::from_secs(1);
        let maximum = std::time::Duration::from_secs(30);
        for failures in 0..=64 {
            assert!(backoff_delay(initial, maximum, failures) <= maximum);
        }
    }

    #[test]
    fn retry_budget_discards_attempts_outside_its_window() -> GatewayResult<()> {
        let mut config = GatewayConfig::new("retry-test", "info", 1_000)?.moq;
        config.retry_window = std::time::Duration::from_secs(1);
        config.retry_max_attempts = 2;
        let mut policy = RetryPolicy::new(&config);
        let now = tokio::time::Instant::now();
        policy
            .attempts
            .push_back(now - std::time::Duration::from_secs(2));
        policy.attempts.push_back(now);
        policy.prune(now);
        assert_eq!(policy.attempts.len(), 1);
        Ok(())
    }

    #[tokio::test]
    async fn keeps_group_objects_on_one_ordered_subgroup() -> GatewayResult<()> {
        let namespace = TrackNamespace::from_utf8_path("teremoq/test");
        let (mut writer, _requests, mut reader) =
            moq_transport::serve::Tracks::new(namespace.clone()).produce();
        let mut writers = MoqTrackWriters::new(&mut writer)?;
        let track = reader
            .get_track_reader(&namespace, TRACK_VIDEO_HQ)
            .ok_or_else(|| GatewayError::new("test track missing").boxed())?;
        let mut object = ScheduledObject {
            payload: Bytes::from_static(b"encoded-h264"),
            cmaf_init: None,
            connection_id: Arc::from("srt-test"),
            track: TrackId::VideoHq,
            program_number: 1,
            pid: 256,
            codec: Codec::H264,
            group: Group {
                id: 41,
                track: Track {
                    id: TrackId::VideoHq,
                },
                random_access: true,
            },
            object_id: 7,
            priority: Priority::RandomAccess,
            pts_ns: Some(10),
            dts_ns: Some(9),
            received_at: tokio::time::Instant::now(),
        };

        publish_object(writers.writer(TrackId::VideoHq), &object)?;
        object.object_id = 8;
        object.priority = Priority::Delta;
        object.payload = Bytes::from_static(b"encoded-h264-delta");
        publish_object(writers.writer(TrackId::VideoHq), &object)?;
        let TrackReaderMode::Subgroups(mut groups) = track.mode().await? else {
            return Err(GatewayError::new("test track did not use subgroup mode").boxed());
        };
        let mut group = groups
            .next()
            .await?
            .ok_or_else(|| GatewayError::new("test subgroup missing").boxed())?;
        assert_eq!(group.group_id, 41);
        assert_eq!(group.subgroup_id, 0);
        assert_eq!(group.priority, 1);
        let payload = group
            .next()
            .await?
            .ok_or_else(|| GatewayError::new("test object missing").boxed())?
            .read_all()
            .await?;
        assert_eq!(payload, Bytes::from_static(b"encoded-h264"));
        let second = group
            .next()
            .await?
            .ok_or_else(|| GatewayError::new("second test object missing").boxed())?
            .read_all()
            .await?;
        assert_eq!(second, Bytes::from_static(b"encoded-h264-delta"));
        Ok(())
    }
}
