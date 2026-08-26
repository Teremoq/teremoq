use std::{
    fs,
    net::{SocketAddr, UdpSocket},
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use async_trait::async_trait;
use bytes::Bytes;
use gateway_rs::{
    adapters::moq::run_moq_publisher,
    config::{GatewayConfig, MoqConfig},
    media::{AccessUnitKind, Codec, Group, MediaObject, Track},
    observability::EventLogger,
    routing::TrackId,
    scheduler::{SchedulerSnapshot, SubscriberScheduler},
    supervisor::SignalMonitor,
};
use moq_native_ietf::quic;
use moq_relay_ietf::{
    Coordinator, CoordinatorContext, CoordinatorError, CoordinatorResult, NamespaceOrigin,
    NamespaceRegistration, RelayConfig, ScopeInfo, ScopePermissions, SessionConfig,
};
use moq_transport::{
    coding::TrackNamespace,
    serve::{
        ServeError, SubgroupObjectReader, SubgroupReader, Subgroups, SubgroupsReader,
        Track as MoqServeTrack, TrackReaderMode,
    },
    session::{SessionError, Subscribe, Subscriber},
};
use tokio::task::JoinHandle;
use tokio_util::sync::CancellationToken;
use url::Url;

mod support;

use support::pki::TestPki;

const NAMESPACE: &str = "teremoq/interop";
const TRACK: &str = "0-video-hq";
const LAB_GOP_OBJECTS: u64 = 30;
const MAX_METRIC_SAMPLES: usize = 100_000;

#[tokio::test(flavor = "current_thread")]
async fn gateway_relay_and_two_different_speed_subscribers_interoperate() -> anyhow::Result<()> {
    tokio::task::LocalSet::new().run_until(run_interop()).await
}

#[tokio::test(flavor = "current_thread")]
#[ignore = "requires the isolated harness; run chaos/federation/run.sh --profile hostile"]
async fn hostile_network_reconnect_and_finite_video_progress() -> anyhow::Result<()> {
    tokio::task::LocalSet::new()
        .run_until(run_hostile_network_lab())
        .await
}

#[tokio::test]
async fn subgroup_reader_drains_every_object_in_one_group_in_order() -> anyhow::Result<()> {
    let track = Arc::new(MoqServeTrack::new(
        TrackNamespace::from_utf8_path("teremoq/reader-regression"),
        "video",
    ));
    let (mut writer, mut groups) = Subgroups { track }.produce();
    let started = tokio::time::Instant::now();
    let mut subgroup_writer = writer.append(0)?;
    for sequence in 0..5 {
        subgroup_writer.write(lab_payload(sequence, started.elapsed(), 1_024))?;
    }
    drop(subgroup_writer);
    drop(writer);

    let mut subgroup = groups
        .next()
        .await?
        .ok_or_else(|| anyhow::anyhow!("regression reader received no Subgroup"))?;
    let cancellation = CancellationToken::new();
    let mut metrics = SubscriberMetrics::default();
    let mut last_sequence = None;
    let mut recovery_started = None;
    let outcome = tokio::time::timeout(
        Duration::from_secs(2),
        drain_subgroup(
            "regression",
            &mut subgroup,
            Duration::ZERO,
            started,
            &cancellation,
            &mut metrics,
            &mut last_sequence,
            &mut recovery_started,
        ),
    )
    .await??;

    anyhow::ensure!(
        matches!(outcome, SubgroupReadOutcome::Complete),
        "Subgroup did not finish normally"
    );
    assert_eq!(metrics.received, 5);
    assert_eq!(last_sequence, Some(4));
    assert_eq!(metrics.sequence_gaps, 0);
    assert_eq!(metrics.reordered, 0);
    Ok(())
}

async fn run_hostile_network_lab() -> anyhow::Result<()> {
    let duration = lab_duration()?;
    let rate_hz = lab_rate_hz()?;
    let slow_delay = lab_slow_delay()?;
    let payload_bytes = lab_payload_bytes()?;
    let pki = TestPki::generate()?;
    let relay_addr = available_udp_addr()?;
    let relay_task = restart_relay(relay_addr, &pki, Duration::from_secs(10)).await?;

    let (config, scheduler, cancellation, publisher_task) =
        start_publisher(relay_addr, &pki, "hostile-network-gateway").await?;
    wait_for_publisher(&scheduler).await?;

    relay_task.abort();
    let _relay_result = relay_task.await;
    wait_for_subscriber_count(&scheduler, 0, Duration::from_secs(10)).await?;
    tokio::time::sleep(Duration::from_millis(500)).await;
    let reconnect_started = tokio::time::Instant::now();
    let relay_task = restart_relay(relay_addr, &pki, Duration::from_secs(10)).await?;
    wait_for_subscriber_count(&scheduler, 1, Duration::from_secs(10)).await?;
    let publisher_recovery_ms = millis(reconnect_started.elapsed());

    let watch_url = Url::parse(&format!("https://{relay_addr}/watch"))?;
    let fast = connect_subscriber(&watch_url, relay_addr, &pki).await?;
    let slow = connect_subscriber(&watch_url, relay_addr, &pki).await?;
    let lab_started = tokio::time::Instant::now();
    let readers_done = CancellationToken::new();
    let fast_task = tokio::spawn(collect_subscriber(
        "fast",
        fast,
        watch_url.clone(),
        relay_addr,
        pki.root_a.clone(),
        pki.gateway_cert_a.clone(),
        pki.gateway_key_a.clone(),
        Duration::ZERO,
        lab_started,
        readers_done.child_token(),
    ));
    let slow_task = tokio::spawn(collect_subscriber(
        "slow",
        slow,
        watch_url,
        relay_addr,
        pki.root_a.clone(),
        pki.gateway_cert_a.clone(),
        pki.gateway_key_a.clone(),
        slow_delay,
        lab_started,
        readers_done.child_token(),
    ));

    let rss_start_kib = process_rss_kib()?;
    let tasks_start = process_task_count()?;
    let interval = Duration::from_nanos(1_000_000_000_u64 / u64::from(rate_hz));
    let deadline = lab_started + duration;
    let mut sequence = 0_u64;
    let mut next_send = lab_started;
    while tokio::time::Instant::now() < deadline {
        tokio::time::sleep_until(next_send).await;
        let payload = lab_payload(sequence, lab_started.elapsed(), payload_bytes);
        scheduler
            .fanout(
                media_object_with_sequence(payload, sequence),
                tokio::time::Instant::now(),
            )
            .map_err(|source| anyhow::anyhow!(source.to_string()))?;
        sequence = sequence.saturating_add(1);
        next_send += interval;
    }
    tokio::time::sleep(Duration::from_millis(500)).await;
    readers_done.cancel();
    let fast_metrics = fast_task.await??;
    let slow_metrics = slow_task.await??;
    let rss_end_kib = process_rss_kib()?;

    cancellation.cancel();
    publisher_task
        .await?
        .map_err(|source| anyhow::anyhow!(source.to_string()))?;
    relay_task.abort();
    let _relay_result = relay_task.await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    let tasks_end = process_task_count()?;

    LabResult {
        duration,
        rate_hz,
        payload_bytes,
        sequence,
        publisher_recovery_ms,
        fast: fast_metrics,
        slow: slow_metrics,
        rss_start_kib,
        rss_end_kib,
        tasks_start,
        tasks_end,
        relay_addr,
        namespace: config.namespace,
    }
    .report_and_validate(scheduler.snapshot())
}

async fn run_interop() -> anyhow::Result<()> {
    let pki = TestPki::generate()?;
    let relay_addr = available_udp_addr()?;
    let relay = build_relay(relay_addr, &pki)?;
    let relay_task = tokio::task::spawn_local(relay.run());

    let mut base = GatewayConfig::new("interop-gateway", "info", 2_000)
        .map_err(|source| anyhow::anyhow!(source.to_string()))?;
    let publisher_url = Url::parse(&format!("https://{relay_addr}/publish"))?;
    base.moq = MoqConfig {
        relay_url: publisher_url,
        bind_addr: "127.0.0.1:0".parse()?,
        namespace: NAMESPACE.to_owned(),
        tls_root: pki.root_a.clone(),
        tls_client_cert: pki.gateway_cert_a.clone(),
        tls_client_key: pki.gateway_key_a.clone(),
        reconnect_delay: Duration::from_millis(50),
        reconnect_max_delay: Duration::from_millis(200),
        retry_max_attempts: 20,
        retry_window: Duration::from_secs(2),
        connect_timeout: Duration::from_secs(2),
    };
    let logger = EventLogger::new("interop-gateway".to_owned());
    let scheduler = Arc::new(SubscriberScheduler::new(base.scheduler, logger.clone()));
    let monitor = Arc::new(SignalMonitor::new(1));
    let cancellation = CancellationToken::new();
    let endpoint = gateway_rs::security::mtls::prepare_endpoint(&base.moq).await?;
    let publisher_task = tokio::spawn(run_moq_publisher(
        base.moq,
        endpoint,
        Arc::clone(&scheduler),
        monitor,
        cancellation.child_token(),
        logger,
    ));

    wait_for_publisher(&scheduler).await?;
    tokio::time::sleep(Duration::from_millis(150)).await;
    let watch_url = Url::parse(&format!("https://{relay_addr}/watch"))?;
    let fast = connect_subscriber(&watch_url, relay_addr, &pki).await?;
    let slow = connect_subscriber(&watch_url, relay_addr, &pki).await?;

    let payload = Bytes::from_static(b"annex-b-h264-access-unit");
    scheduler
        .fanout(media_object(payload.clone()), tokio::time::Instant::now())
        .map_err(|source| anyhow::anyhow!(source.to_string()))?;

    let received_fast = read_one(fast.track).await?;
    tokio::time::sleep(Duration::from_millis(250)).await;
    let received_slow = read_one(slow.track).await?;
    assert_eq!(received_fast, payload);
    assert_eq!(received_slow, payload);

    drop(fast.subscription);
    drop(slow.subscription);
    fast.session_task.abort();
    slow.session_task.abort();
    cancellation.cancel();
    publisher_task
        .await?
        .map_err(|source| anyhow::anyhow!(source.to_string()))?;
    relay_task.abort();
    let _relay_result = relay_task.await;
    Ok(())
}

type PublisherTask = JoinHandle<gateway_rs::error::GatewayResult<()>>;

async fn start_publisher(
    relay_addr: SocketAddr,
    pki: &TestPki,
    instance_id: &str,
) -> anyhow::Result<(
    MoqConfig,
    Arc<SubscriberScheduler>,
    CancellationToken,
    PublisherTask,
)> {
    let mut base = GatewayConfig::new(instance_id, "info", 2_000)
        .map_err(|source| anyhow::anyhow!(source.to_string()))?;
    base.moq = MoqConfig {
        relay_url: Url::parse(&format!("https://{relay_addr}/publish"))?,
        bind_addr: "127.0.0.1:0".parse()?,
        namespace: NAMESPACE.to_owned(),
        tls_root: pki.root_a.clone(),
        tls_client_cert: pki.gateway_cert_a.clone(),
        tls_client_key: pki.gateway_key_a.clone(),
        reconnect_delay: Duration::from_millis(50),
        reconnect_max_delay: Duration::from_millis(500),
        retry_max_attempts: 30,
        retry_window: Duration::from_secs(10),
        connect_timeout: Duration::from_secs(2),
    };
    let logger = EventLogger::new(instance_id.to_owned());
    let scheduler = Arc::new(SubscriberScheduler::new(base.scheduler, logger.clone()));
    let monitor = Arc::new(SignalMonitor::new(1));
    let cancellation = CancellationToken::new();
    let endpoint = gateway_rs::security::mtls::prepare_endpoint(&base.moq).await?;
    let publisher_task = tokio::spawn(run_moq_publisher(
        base.moq.clone(),
        endpoint,
        Arc::clone(&scheduler),
        monitor,
        cancellation.child_token(),
        logger,
    ));
    Ok((base.moq, scheduler, cancellation, publisher_task))
}

#[derive(Default)]
struct SubscriberMetrics {
    received: u64,
    sequence_gaps: u64,
    reordered: u64,
    latency_ms: Vec<u64>,
    latency_samples_dropped: u64,
    keyframe_recoveries: u64,
    keyframe_recovery_ms: Vec<u64>,
    keyframe_recovery_samples_dropped: u64,
    recovery_pending: bool,
    terminal_reason: Option<String>,
    terminal_at_ms: Option<u64>,
    terminal_events: u64,
    reconnects: u64,
    reconnect_max_ms: u64,
}

impl SubscriberMetrics {
    fn summary(&self) -> serde_json::Value {
        let mut latency = self.latency_ms.clone();
        latency.sort_unstable();
        let mut keyframe_recovery = self.keyframe_recovery_ms.clone();
        keyframe_recovery.sort_unstable();
        serde_json::json!({
            "received": self.received,
            "sequence_gaps": self.sequence_gaps,
            "reordered": self.reordered,
            "latency_metric": "publish_enqueue_to_subscriber",
            "latency_samples": latency.len(),
            "latency_samples_dropped": self.latency_samples_dropped,
            "latency_p50_ms": sample_percentile(&latency, 50),
            "latency_p95_ms": sample_percentile(&latency, 95),
            "latency_p99_ms": sample_percentile(&latency, 99),
            "latency_max_ms": latency.last().copied(),
            "keyframe_recoveries": self.keyframe_recoveries,
            "keyframe_recovery_samples": keyframe_recovery.len(),
            "keyframe_recovery_samples_dropped": self.keyframe_recovery_samples_dropped,
            "keyframe_recovery_p95_ms": sample_percentile(&keyframe_recovery, 95),
            "keyframe_recovery_max_ms": keyframe_recovery.last().copied(),
            "recovery_pending_at_shutdown": self.recovery_pending,
            "terminal_reason": self.terminal_reason,
            "terminal_at_ms": self.terminal_at_ms,
            "terminal_events": self.terminal_events,
            "reconnects": self.reconnects,
            "reconnect_max_ms": self.reconnect_max_ms,
        })
    }
}

struct LabResult {
    duration: Duration,
    rate_hz: u32,
    payload_bytes: usize,
    sequence: u64,
    publisher_recovery_ms: u64,
    fast: SubscriberMetrics,
    slow: SubscriberMetrics,
    rss_start_kib: u64,
    rss_end_kib: u64,
    tasks_start: usize,
    tasks_end: usize,
    relay_addr: SocketAddr,
    namespace: String,
}

impl LabResult {
    fn report_and_validate(self, scheduler: SchedulerSnapshot) -> anyhow::Result<()> {
        let rss_growth_kib = self.rss_end_kib.saturating_sub(self.rss_start_kib);
        let report = serde_json::json!({
            "schema_version": 1,
            "event": "step7_resilience_lab_result",
            "draft": "draft-16",
            "alpn": "moqt-16",
            "network_profile": std::env::var("TEREMOQ_LAB_NETEM_PROFILE").unwrap_or_else(|_| "external".to_owned()),
            "duration_ms": millis(self.duration),
            "rate_hz": self.rate_hz,
            "payload_bytes": self.payload_bytes,
            "objects_sent": self.sequence,
            "publisher_recovery_ms": self.publisher_recovery_ms,
            "publisher_recovery_samples": 1,
            "topology": {
                "relay": 1,
                "publisher": 1,
                "subscribers": {"fast": 1, "slow": 1},
            },
            "published_tracks": ["video_hq"],
            "multitrack_transport_evidence": "not_applicable_video_only",
            "fast": self.fast.summary(),
            "slow": self.slow.summary(),
            "rss_start_kib": self.rss_start_kib,
            "rss_end_kib": self.rss_end_kib,
            "rss_growth_kib": rss_growth_kib,
            "tasks_start": self.tasks_start,
            "tasks_end": self.tasks_end,
            "publisher_queue_objects": scheduler.queued_objects,
            "publisher_queue_bytes": scheduler.queued_bytes,
            "publisher_accepted": scheduler.accepted,
            "publisher_dropped": scheduler.dropped,
            "publisher_evicted": scheduler.evicted,
            "relay_origin": format!("https://{}", self.relay_addr),
            "configured_namespace": self.namespace,
        });
        println!("{report}");

        anyhow::ensure!(self.sequence > 0, "lab sent no Objects");
        anyhow::ensure!(
            self.fast.received > 0,
            "fast subscriber received no Objects"
        );
        anyhow::ensure!(
            self.fast.received > self.slow.received,
            "slow consumer did not demonstrate isolated lag"
        );
        anyhow::ensure!(
            self.fast.received.saturating_mul(100) / self.sequence >= 95,
            "fast subscriber received less than 95% under the hostile profile"
        );
        let fast_unrecovered_terminations = self
            .fast
            .terminal_events
            .saturating_sub(self.fast.reconnects);
        if fast_unrecovered_terminations > 0
            && let Some(terminal_at_ms) = self.fast.terminal_at_ms
        {
            anyhow::ensure!(
                terminal_at_ms.saturating_add(1_000) >= millis(self.duration),
                "fast subscriber terminated before the final second of the lab"
            );
        }
        anyhow::ensure!(
            rss_growth_kib <= 64 * 1_024,
            "RSS grew by more than the 64 MiB lab ceiling"
        );
        anyhow::ensure!(
            self.tasks_end <= self.tasks_start.saturating_add(2),
            "tasks remained after coordinated shutdown"
        );
        anyhow::ensure!(
            scheduler.queued_objects == 0 && scheduler.queued_bytes == 0,
            "publisher queue was not drained on shutdown"
        );
        Ok(())
    }
}

#[allow(clippy::too_many_arguments)]
async fn collect_subscriber(
    label: &'static str,
    subscriber: ConnectedSubscriber,
    watch_url: Url,
    relay_addr: SocketAddr,
    root: PathBuf,
    client_cert: PathBuf,
    client_key: PathBuf,
    read_delay: Duration,
    lab_started: tokio::time::Instant,
    cancellation: CancellationToken,
) -> anyhow::Result<SubscriberMetrics> {
    let mut metrics = SubscriberMetrics::default();
    let mut last_sequence = None;
    let mut recovery_started = None;
    let mut current = Some(subscriber);

    'sessions: loop {
        let Some(subscriber) = current.take() else {
            anyhow::bail!("{label} subscriber reconnect state was empty");
        };
        read_subscriber_session(
            label,
            subscriber,
            read_delay,
            lab_started,
            &cancellation,
            &mut metrics,
            &mut last_sequence,
            &mut recovery_started,
        )
        .await?;
        if cancellation.is_cancelled() {
            break;
        }

        let reconnect_started = tokio::time::Instant::now();
        loop {
            let attempt = tokio::select! {
                biased;
                () = cancellation.cancelled() => break 'sessions,
                result = connect_subscriber_with_identity(
                    &watch_url,
                    relay_addr,
                    &root,
                    &client_cert,
                    &client_key,
                ) => result,
            };
            match attempt {
                Ok(subscriber) => {
                    metrics.reconnects = metrics.reconnects.saturating_add(1);
                    metrics.reconnect_max_ms = metrics
                        .reconnect_max_ms
                        .max(millis(reconnect_started.elapsed()));
                    current = Some(subscriber);
                    break;
                }
                Err(_source) => {
                    tokio::select! {
                        biased;
                        () = cancellation.cancelled() => break 'sessions,
                        () = tokio::time::sleep(Duration::from_millis(100)) => {}
                    }
                }
            }
        }
    }

    metrics.recovery_pending = recovery_started.is_some();
    Ok(metrics)
}

#[allow(clippy::too_many_arguments)]
async fn read_subscriber_session(
    label: &'static str,
    subscriber: ConnectedSubscriber,
    read_delay: Duration,
    lab_started: tokio::time::Instant,
    cancellation: &CancellationToken,
    metrics: &mut SubscriberMetrics,
    last_sequence: &mut Option<u64>,
    recovery_started: &mut Option<tokio::time::Instant>,
) -> anyhow::Result<()> {
    let ConnectedSubscriber {
        _endpoint,
        subscription,
        track,
        session_task,
    } = subscriber;
    let mode = tokio::select! {
        biased;
        () = cancellation.cancelled() => {
            drop(subscription);
            session_task.abort();
            let _session_result = session_task.await;
            return Ok(());
        }
        result = tokio::time::timeout(Duration::from_secs(5), track.mode()) => result??,
    };
    let TrackReaderMode::Subgroups(mut groups) = mode else {
        anyhow::bail!("subscriber track did not use MoQT subgroup mode");
    };
    'read: loop {
        let next_result = tokio::select! {
            biased;
            () = cancellation.cancelled() => break,
            result = groups.next() => result,
        };
        let next = match next_result {
            Ok(next) => next,
            Err(_source) if cancellation.is_cancelled() => break,
            Err(source) if is_normal_track_termination(&source) => {
                record_terminal(metrics, &source, lab_started);
                break;
            }
            Err(source) => {
                anyhow::bail!("{label} subscriber failed while reading Groups: {source}")
            }
        };
        let Some(mut subgroup) = next else {
            record_terminal(metrics, &ServeError::Done, lab_started);
            break;
        };
        match drain_subgroup(
            label,
            &mut subgroup,
            read_delay,
            lab_started,
            cancellation,
            metrics,
            last_sequence,
            recovery_started,
        )
        .await?
        {
            SubgroupReadOutcome::Complete => {}
            SubgroupReadOutcome::Cancelled => break,
            SubgroupReadOutcome::Terminal(source) => {
                record_terminal(metrics, &source, lab_started);
                break 'read;
            }
        }
    }
    drop(subscription);
    session_task.abort();
    let _session_result = session_task.await;
    Ok(())
}

enum SubgroupReadOutcome {
    Complete,
    Cancelled,
    Terminal(ServeError),
}

enum ObjectReadOutcome {
    Header([u8; 16]),
    Cancelled,
    Terminal(ServeError),
}

#[allow(clippy::too_many_arguments)]
async fn drain_subgroup(
    label: &'static str,
    subgroup: &mut SubgroupReader,
    read_delay: Duration,
    lab_started: tokio::time::Instant,
    cancellation: &CancellationToken,
    metrics: &mut SubscriberMetrics,
    last_sequence: &mut Option<u64>,
    recovery_started: &mut Option<tokio::time::Instant>,
) -> anyhow::Result<SubgroupReadOutcome> {
    loop {
        if !read_delay.is_zero() {
            tokio::select! {
                biased;
                () = cancellation.cancelled() => return Ok(SubgroupReadOutcome::Cancelled),
                () = tokio::time::sleep(read_delay) => {}
            }
        }
        let next_object = tokio::select! {
            biased;
            () = cancellation.cancelled() => return Ok(SubgroupReadOutcome::Cancelled),
            result = subgroup.next() => result,
        };
        let Some(mut object) = (match next_object {
            Ok(next) => next,
            Err(source) if is_normal_track_termination(&source) => {
                return Ok(SubgroupReadOutcome::Terminal(source));
            }
            Err(source) => {
                anyhow::bail!("{label} subscriber failed while reading a Subgroup: {source}")
            }
        }) else {
            return Ok(SubgroupReadOutcome::Complete);
        };

        let header = match read_object_header(label, &mut object, cancellation).await? {
            ObjectReadOutcome::Header(header) => header,
            ObjectReadOutcome::Cancelled => return Ok(SubgroupReadOutcome::Cancelled),
            ObjectReadOutcome::Terminal(source) => {
                return Ok(SubgroupReadOutcome::Terminal(source));
            }
        };
        record_object(
            &header,
            lab_started,
            metrics,
            last_sequence,
            recovery_started,
        )?;
    }
}

async fn read_object_header(
    label: &'static str,
    object: &mut SubgroupObjectReader,
    cancellation: &CancellationToken,
) -> anyhow::Result<ObjectReadOutcome> {
    let mut header = [0_u8; 16];
    let mut header_len = 0_usize;
    loop {
        let next_chunk = tokio::select! {
            biased;
            () = cancellation.cancelled() => return Ok(ObjectReadOutcome::Cancelled),
            result = object.read() => result,
        };
        match next_chunk {
            Ok(Some(chunk)) => {
                let remaining = header.len().saturating_sub(header_len);
                let copy_len = remaining.min(chunk.len());
                header[header_len..header_len + copy_len].copy_from_slice(&chunk[..copy_len]);
                header_len += copy_len;
            }
            Ok(None) => {
                anyhow::ensure!(
                    header_len == header.len(),
                    "{label} subscriber received an Object shorter than its correlation header"
                );
                return Ok(ObjectReadOutcome::Header(header));
            }
            Err(source) if is_normal_track_termination(&source) => {
                return Ok(ObjectReadOutcome::Terminal(source));
            }
            Err(source) => {
                anyhow::bail!("{label} subscriber failed while reading an Object: {source}")
            }
        }
    }
}

fn record_object(
    header: &[u8; 16],
    lab_started: tokio::time::Instant,
    metrics: &mut SubscriberMetrics,
    last_sequence: &mut Option<u64>,
    recovery_started: &mut Option<tokio::time::Instant>,
) -> anyhow::Result<()> {
    let sequence = read_u64(header, 0)?;
    let sent_ns = read_u64(header, 8)?;
    let received_ns = nanos(lab_started.elapsed());
    push_metric_sample(
        &mut metrics.latency_ms,
        received_ns.saturating_sub(sent_ns) / 1_000_000,
        &mut metrics.latency_samples_dropped,
    );
    if let Some(previous) = *last_sequence {
        if sequence > previous + 1 {
            metrics.sequence_gaps = metrics
                .sequence_gaps
                .saturating_add(sequence.saturating_sub(previous + 1));
            if recovery_started.is_none() {
                *recovery_started = Some(tokio::time::Instant::now());
            }
        } else if sequence <= previous {
            metrics.reordered = metrics.reordered.saturating_add(1);
        }
    }
    if sequence.is_multiple_of(LAB_GOP_OBJECTS)
        && let Some(started) = recovery_started.take()
    {
        metrics.keyframe_recoveries = metrics.keyframe_recoveries.saturating_add(1);
        push_metric_sample(
            &mut metrics.keyframe_recovery_ms,
            millis(started.elapsed()),
            &mut metrics.keyframe_recovery_samples_dropped,
        );
    }
    *last_sequence = Some(sequence);
    metrics.received = metrics.received.saturating_add(1);
    Ok(())
}

fn push_metric_sample(samples: &mut Vec<u64>, value: u64, dropped: &mut u64) {
    if samples.len() < MAX_METRIC_SAMPLES {
        samples.push(value);
    } else {
        *dropped = dropped.saturating_add(1);
    }
}

fn is_normal_track_termination(source: &ServeError) -> bool {
    matches!(
        source,
        ServeError::Cancel | ServeError::Done | ServeError::Closed(0)
    )
}

fn record_terminal(
    metrics: &mut SubscriberMetrics,
    source: &ServeError,
    lab_started: tokio::time::Instant,
) {
    metrics.terminal_reason = Some(source.to_string());
    metrics.terminal_at_ms = Some(millis(lab_started.elapsed()));
    metrics.terminal_events = metrics.terminal_events.saturating_add(1);
}

fn lab_payload(sequence: u64, elapsed: Duration, payload_bytes: usize) -> Bytes {
    let mut payload = Vec::with_capacity(payload_bytes);
    payload.extend_from_slice(&sequence.to_be_bytes());
    payload.extend_from_slice(&nanos(elapsed).to_be_bytes());
    payload.resize(payload_bytes, 0xA5);
    Bytes::from(payload)
}

fn read_u64(payload: &[u8], offset: usize) -> anyhow::Result<u64> {
    let end = offset.saturating_add(std::mem::size_of::<u64>());
    let bytes = payload
        .get(offset..end)
        .ok_or_else(|| anyhow::anyhow!("lab Object is shorter than its correlation header"))?;
    Ok(u64::from_be_bytes(bytes.try_into()?))
}

fn sample_percentile(sorted: &[u64], requested: usize) -> Option<u64> {
    if sorted.is_empty() {
        return None;
    }
    let rank = requested
        .saturating_mul(sorted.len().saturating_sub(1))
        .saturating_add(50)
        / 100;
    sorted.get(rank).copied()
}

fn process_rss_kib() -> anyhow::Result<u64> {
    let status = fs::read_to_string("/proc/self/status")?;
    let value = status
        .lines()
        .find_map(|line| line.strip_prefix("VmRSS:"))
        .and_then(|line| line.split_whitespace().next())
        .ok_or_else(|| anyhow::anyhow!("VmRSS is unavailable in /proc/self/status"))?;
    Ok(value.parse()?)
}

fn process_task_count() -> anyhow::Result<usize> {
    Ok(fs::read_dir("/proc/self/task")?.count())
}

fn lab_duration() -> anyhow::Result<Duration> {
    Ok(Duration::from_secs(lab_env_u64(
        "TEREMOQ_LAB_DURATION_SECS",
        60,
        10,
        3_600,
    )?))
}

fn lab_rate_hz() -> anyhow::Result<u32> {
    let value = lab_env_u64("TEREMOQ_LAB_RATE_HZ", 20, 1, 1_000)?;
    Ok(u32::try_from(value)?)
}

fn lab_slow_delay() -> anyhow::Result<Duration> {
    Ok(Duration::from_millis(lab_env_u64(
        "TEREMOQ_LAB_SLOW_DELAY_MS",
        120,
        1,
        10_000,
    )?))
}

fn lab_payload_bytes() -> anyhow::Result<usize> {
    let value = lab_env_u64("TEREMOQ_LAB_PAYLOAD_BYTES", 8 * 1_024, 1_024, 1_024 * 1_024)?;
    Ok(usize::try_from(value)?)
}

fn lab_env_u64(name: &str, default: u64, minimum: u64, maximum: u64) -> anyhow::Result<u64> {
    let value = match std::env::var(name) {
        Ok(value) => value.parse()?,
        Err(std::env::VarError::NotPresent) => default,
        Err(source) => return Err(source.into()),
    };
    anyhow::ensure!(
        (minimum..=maximum).contains(&value),
        "{name} must be between {minimum} and {maximum}"
    );
    Ok(value)
}

fn millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

fn nanos(duration: Duration) -> u64 {
    u64::try_from(duration.as_nanos()).unwrap_or(u64::MAX)
}

struct ConnectedSubscriber {
    _endpoint: quic::Endpoint,
    subscription: Subscribe,
    track: moq_transport::serve::TrackReader,
    session_task: JoinHandle<Result<(), SessionError>>,
}

async fn connect_subscriber(
    url: &Url,
    relay_addr: SocketAddr,
    pki: &TestPki,
) -> anyhow::Result<ConnectedSubscriber> {
    connect_subscriber_with_identity(
        url,
        relay_addr,
        &pki.root_a,
        &pki.gateway_cert_a,
        &pki.gateway_key_a,
    )
    .await
}

async fn connect_subscriber_with_identity(
    url: &Url,
    relay_addr: SocketAddr,
    root: &Path,
    client_cert: &Path,
    client_key: &Path,
) -> anyhow::Result<ConnectedSubscriber> {
    let mut config = GatewayConfig::new("test-subscriber", "info", 1_000)
        .map_err(|source| anyhow::anyhow!(source.to_string()))?
        .moq;
    config.bind_addr = "127.0.0.1:0".parse()?;
    config.tls_root = root.to_path_buf();
    config.tls_client_cert = client_cert.to_path_buf();
    config.tls_client_key = client_key.to_path_buf();
    let endpoint = gateway_rs::security::mtls::prepare_endpoint(&config).await?;
    let (webtransport, _connection_id, transport) =
        endpoint.client.connect(url, Some(relay_addr)).await?;
    let (session, mut subscriber) = Subscriber::connect(webtransport, transport).await?;
    let session_task = tokio::spawn(session.run());
    let namespace = TrackNamespace::from_utf8_path(NAMESPACE);
    let (track_writer, track) = moq_transport::serve::Track::new(namespace, TRACK).produce();
    let subscription = tokio::time::timeout(
        Duration::from_secs(2),
        subscriber.subscribe_open(track_writer),
    )
    .await??;
    Ok(ConnectedSubscriber {
        _endpoint: endpoint,
        subscription,
        track,
        session_task,
    })
}

async fn read_one(track: moq_transport::serve::TrackReader) -> anyhow::Result<Bytes> {
    let mode = tokio::time::timeout(Duration::from_secs(2), track.mode()).await??;
    let TrackReaderMode::Subgroups(groups) = mode else {
        anyhow::bail!("subscriber track did not use MoQT subgroup mode");
    };
    read_subgroup(groups).await
}

async fn read_subgroup(mut groups: SubgroupsReader) -> anyhow::Result<Bytes> {
    let mut group = tokio::time::timeout(Duration::from_secs(2), groups.next())
        .await??
        .ok_or_else(|| anyhow::anyhow!("subscriber did not receive a Group"))?;
    let mut object = group
        .next()
        .await?
        .ok_or_else(|| anyhow::anyhow!("subscriber did not receive an Object"))?;
    Ok(object.read_all().await?)
}

async fn wait_for_publisher(scheduler: &SubscriberScheduler) -> anyhow::Result<()> {
    wait_for_subscriber_count(scheduler, 1, Duration::from_secs(3)).await
}

async fn wait_for_subscriber_count(
    scheduler: &SubscriberScheduler,
    expected: usize,
    timeout: Duration,
) -> anyhow::Result<()> {
    tokio::time::timeout(timeout, async {
        loop {
            if scheduler.snapshot().subscribers == expected {
                return;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await?;
    Ok(())
}

fn media_object(payload: Bytes) -> MediaObject {
    media_object_with_sequence(payload, 0)
}

fn media_object_with_sequence(payload: Bytes, sequence: u64) -> MediaObject {
    let object_id = sequence % LAB_GOP_OBJECTS;
    let random_access = object_id == 0;
    MediaObject {
        group: Group {
            id: sequence / LAB_GOP_OBJECTS + 1,
            track: Track {
                id: TrackId::VideoHq,
            },
            random_access: true,
        },
        object_id,
        program_number: 1,
        pid: 256,
        codec: Codec::H264,
        kind: if random_access {
            AccessUnitKind::RandomAccess
        } else {
            AccessUnitKind::Delta
        },
        pts_ns: Some(sequence.saturating_mul(50_000_000)),
        dts_ns: Some(sequence.saturating_mul(50_000_000)),
        payload,
        cmaf_init: None,
        connection_id: Arc::from("srt-interop"),
        peer: SocketAddr::from(([127, 0, 0, 1], 9000)),
        received_at: tokio::time::Instant::now(),
    }
}

fn build_relay(bind: SocketAddr, pki: &TestPki) -> anyhow::Result<moq_relay_ietf::Relay> {
    let tls = pki.relay_tls()?;
    let coordinator: Arc<dyn Coordinator> = Arc::new(TestCoordinator);
    RelayConfig {
        bind: Some(bind),
        endpoints: Vec::new(),
        tls,
        qlog_dir: None,
        mlog_dir: None,
        announce: None,
        node: None,
        coordinator,
        session: SessionConfig {
            max_request_id: 100,
        },
        connection_tagger: None,
    }
    .build_with_cache_idle_timeout(Duration::from_secs(10))
}

async fn restart_relay(
    bind: SocketAddr,
    pki: &TestPki,
    timeout: Duration,
) -> anyhow::Result<JoinHandle<anyhow::Result<()>>> {
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        match build_relay(bind, pki) {
            Ok(relay) => return Ok(tokio::task::spawn_local(relay.run())),
            Err(source) if tokio::time::Instant::now() < deadline => {
                tokio::time::sleep(Duration::from_millis(100)).await;
                drop(source);
            }
            Err(source) => return Err(source),
        }
    }
}

struct TestCoordinator;

#[async_trait]
impl Coordinator for TestCoordinator {
    async fn resolve_scope(
        &self,
        connection_path: Option<&str>,
    ) -> CoordinatorResult<Option<ScopeInfo>> {
        let permissions = match connection_path {
            Some("/publish") => ScopePermissions::ReadWrite,
            Some("/watch") => ScopePermissions::ReadOnly,
            _ => return Err(CoordinatorError::NamespaceNotFound),
        };
        Ok(Some(ScopeInfo {
            scope_id: "interop".to_owned(),
            permissions,
        }))
    }

    async fn register_namespace(
        &self,
        _scope: Option<&str>,
        _namespace: &TrackNamespace,
        _context: &CoordinatorContext,
    ) -> CoordinatorResult<NamespaceRegistration> {
        Ok(NamespaceRegistration::new(()))
    }

    async fn unregister_namespace(
        &self,
        _scope: Option<&str>,
        _namespace: &TrackNamespace,
    ) -> CoordinatorResult<()> {
        Ok(())
    }

    async fn lookup(
        &self,
        _scope: Option<&str>,
        _namespace: &TrackNamespace,
    ) -> CoordinatorResult<(NamespaceOrigin, Option<quic::Client>)> {
        Err(CoordinatorError::NamespaceNotFound)
    }
}

fn available_udp_addr() -> anyhow::Result<SocketAddr> {
    let socket = UdpSocket::bind("127.0.0.1:0")?;
    Ok(socket.local_addr()?)
}
