use std::{
    fs,
    net::{SocketAddr, UdpSocket},
    num::NonZeroUsize,
    path::Path,
    sync::Arc,
    time::Duration,
};

use bytes::Bytes;
use gateway_rs::{
    config::{GatewayConfig, MoqConfig, SchedulerConfig},
    media::{AccessUnitKind, Codec, Group, MediaObject, Track},
    observability::EventLogger,
    routing::TrackId,
    scheduler::{ReceiveOutcome, SubscriberId, SubscriberScheduler},
    security::mtls::prepare_endpoint,
};
use moq_native_ietf::quic;
use moq_transport::session::{Publisher, Session};
use rustls::{ClientConfig, RootCertStore};
use rustls_pki_types::{CertificateDer, pem::PemObject};
use tokio::{sync::oneshot, task::JoinSet};
use url::Url;

mod support;

use support::pki::TestPki;

const TEST_TIMEOUT: Duration = Duration::from_secs(15);

/// Exercises the explicit C1 bound and the I1 evidence-aware acceptor with real
/// QUINN/rustls clients. Session admission remains a separate C2 concern.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[allow(clippy::too_many_lines)]
async fn valid_peer_progresses_during_invalid_transport_connects_and_delayed_moqt_setup()
-> anyhow::Result<()> {
    tokio::time::timeout(TEST_TIMEOUT, async {
        let pki = TestPki::generate()?;
        let relay_addr = available_udp_addr()?;
        let limits = quic::ServerAdmissionConfig::new(
            NonZeroUsize::new(16)
                .ok_or_else(|| anyhow::anyhow!("buffered incoming limit must be non-zero"))?,
            NonZeroUsize::new(8)
                .ok_or_else(|| anyhow::anyhow!("pending handshake limit must be non-zero"))?,
            Duration::from_secs(5),
            quic::HandshakeCapacityPolicy::Refuse,
        )?;
        let endpoint = quic::Endpoint::new_bounded(
            quic::Config::new(relay_addr, None, pki.relay_tls()?)?,
            limits,
        )?;
        let server = endpoint
            .server
            .ok_or_else(|| anyhow::anyhow!("test mTLS server is unavailable"))?;
        let handshake_admission = server
            .handshake_admission()
            .ok_or_else(|| anyhow::anyhow!("bounded handshake controller is unavailable"))?;
        let mut server = server.with_peer_evidence()?;
        let rss_initial_kib = process_rss_kib()?;
        let tasks_initial = process_task_count()?;
        let sockets_initial = process_socket_count()?;

        let server_task = tokio::spawn(async move {
            let mut sessions = JoinSet::new();
            for _accepted in 0..2 {
                let accepted = server
                    .accept()
                    .await
                    .ok_or_else(|| anyhow::anyhow!("mTLS server stopped accepting"))??;
                let (connection, info, evidence) = accepted.into_parts();
                match evidence {
                    quic::PeerEvidence::Rustls(peer) => anyhow::ensure!(
                        !peer.certificates().is_empty(),
                        "verified peer evidence unexpectedly has no certificate"
                    ),
                    quic::PeerEvidence::Absent => {
                        anyhow::bail!("mutually authenticated connection has no peer evidence")
                    }
                    _ => anyhow::bail!("unsupported verified peer evidence variant"),
                }
                sessions.spawn(async move {
                    let (session, _publisher, _subscriber) =
                        Session::accept(connection, None, info.transport).await?;
                    drop(session);
                    Ok::<(), anyhow::Error>(())
                });
            }
            while let Some(result) = sessions.join_next().await {
                result??;
            }
            Ok::<(), anyhow::Error>(())
        });

        let url = Url::parse(&format!("https://127.0.0.1:{}/publish", relay_addr.port()))?;
        let (release_delayed, delayed_released) = oneshot::channel();
        let (delayed_transport_tx, delayed_transport_rx) = oneshot::channel();
        let delayed_config = client_config(&pki, &pki.gateway_cert_a, &pki.gateway_key_a)?;
        let delayed_url = url.clone();
        let delayed_task = tokio::spawn(async move {
            let endpoint = prepare_endpoint(&delayed_config).await?;
            let transport_started = tokio::time::Instant::now();
            let (connection, _connection_id, transport) = tokio::time::timeout(
                Duration::from_secs(3),
                endpoint.client.connect(&delayed_url, Some(relay_addr)),
            )
            .await??;
            let transport_connect_ms = millis(transport_started.elapsed());
            let hold_started = tokio::time::Instant::now();
            delayed_transport_tx
                .send(transport_connect_ms)
                .map_err(|_| anyhow::anyhow!("delayed peer transport observer stopped"))?;
            delayed_released.await?;
            let moqt_started = tokio::time::Instant::now();
            let (session, _publisher) = tokio::time::timeout(
                Duration::from_secs(3),
                Publisher::connect(connection, transport),
            )
            .await??;
            let sample = DelayedSetupSample {
                transport_connect: transport_connect_ms,
                moqt_hold: millis(hold_started.elapsed()),
                moqt_setup: millis(moqt_started.elapsed()),
            };
            drop(session);
            Ok::<DelayedSetupSample, anyhow::Error>(sample)
        });
        let delayed_transport_connect_ms =
            tokio::time::timeout(Duration::from_secs(3), delayed_transport_rx).await??;

        let mut invalid = JoinSet::new();
        invalid.spawn(rejected_transport_connect(
            "anonymous",
            anonymous_endpoint(&pki.root_a)?,
            url.clone(),
            relay_addr,
        ));
        invalid.spawn(rejected_identity_transport_connect(
            "wrong_ca",
            client_config(&pki, &pki.gateway_cert_b, &pki.gateway_key_b)?,
            url.clone(),
            relay_addr,
        ));
        invalid.spawn(rejected_identity_transport_connect(
            "wrong_eku",
            client_config(
                &pki,
                &pki.gateway_wrong_eku_cert,
                &pki.gateway_wrong_eku_key,
            )?,
            url.clone(),
            relay_addr,
        ));
        invalid.spawn(rejected_identity_transport_connect(
            "expired",
            client_config(&pki, &pki.gateway_expired_cert, &pki.gateway_expired_key)?,
            url.clone(),
            relay_addr,
        ));

        let valid_config = client_config(&pki, &pki.gateway_cert_a, &pki.gateway_key_a)?;
        let valid_endpoint = prepare_endpoint(&valid_config).await?;
        let valid_transport_started = tokio::time::Instant::now();
        let (connection, _connection_id, transport) = tokio::time::timeout(
            Duration::from_secs(3),
            valid_endpoint.client.connect(&url, Some(relay_addr)),
        )
        .await??;
        let valid_transport_connect_ms = millis(valid_transport_started.elapsed());
        let valid_moqt_started = tokio::time::Instant::now();
        let (valid_session, _publisher) = tokio::time::timeout(
            Duration::from_secs(3),
            Publisher::connect(connection, transport),
        )
        .await??;
        let valid_moqt_setup_ms = millis(valid_moqt_started.elapsed());
        drop(valid_session);
        assert!(
            !delayed_task.is_finished(),
            "delayed peer unexpectedly completed MoQT setup before release"
        );

        release_delayed
            .send(())
            .map_err(|()| anyhow::anyhow!("delayed peer stopped before release"))?;
        let delayed = delayed_task.await??;
        assert_eq!(
            delayed.transport_connect, delayed_transport_connect_ms,
            "delayed transport timing changed after publication"
        );

        let mut rejected = Vec::new();
        while let Some(result) = invalid.join_next().await {
            rejected.push(result??);
        }
        rejected.sort_unstable_by_key(|sample| sample.reason);
        server_task.await??;
        let handshake = handshake_admission.snapshot();
        anyhow::ensure!(
            handshake.pending_handshakes == 0,
            "handshake capacity was not fully recovered"
        );
        anyhow::ensure!(
            handshake.completed_total == 2,
            "accepted handshake terminal count is not exact"
        );
        anyhow::ensure!(
            handshake.admitted_total
                == handshake.completed_total
                    + handshake.transport_error_total
                    + handshake.timeout_total
                    + handshake.cancelled_total,
            "every admitted handshake must have exactly one terminal"
        );

        let rss_final_kib = process_rss_kib()?;
        let tasks_final = process_task_count()?;
        let sockets_final = process_socket_count()?;
        let rejection_samples: Vec<_> = rejected
            .iter()
            .map(|sample| {
                serde_json::json!({
                    "reason": sample.reason,
                    "transport_connect_rejection_ms": sample.elapsed_ms,
                    "samples": 1,
                })
            })
            .collect();

        println!(
            "{}",
            serde_json::json!({
                "schema_version": 1,
                "event": "federation_concurrency_hermetic_result",
                "scope": "bounded_handshake_and_verified_peer_evidence",
                "clients_requested": {
                    "anonymous": 1,
                    "wrong_ca": 1,
                    "wrong_eku": 1,
                    "expired": 1,
                    "valid": 1,
                    "delayed_moqt_setup": 1,
                },
                "clients_observed": {
                    "transport_connect_rejected": rejected.len(),
                    "transport_connect_succeeded": 2,
                    "moqt_setup_succeeded": 2,
                },
                "transport_connect_rejection_ms_by_reason": rejection_samples,
                "transport_connect_rejection_samples": rejected.len(),
                "valid_transport_connect_ms": valid_transport_connect_ms,
                "valid_transport_connect_samples": 1,
                "valid_moqt_setup_ms": valid_moqt_setup_ms,
                "valid_moqt_setup_samples": 1,
                "delayed_transport_connect_ms": delayed.transport_connect,
                "delayed_transport_connect_samples": 1,
                "delayed_moqt_hold_ms": delayed.moqt_hold,
                "delayed_moqt_setup_ms": delayed.moqt_setup,
                "delayed_moqt_setup_samples": 1,
                "recovery_ms": null,
                "recovery_samples": 0,
                "rss_initial_kib": rss_initial_kib,
                "rss_final_kib": rss_final_kib,
                "tasks_initial": tasks_initial,
                "tasks_final": tasks_final,
                "sockets_initial": sockets_initial,
                "sockets_final": sockets_final,
                "task_and_socket_cleanup_scope": "test_process_exit_and_harness_container_removal",
                "pending_transport_handshake": handshake.pending_handshakes,
                "handshake_capacity_limit": handshake.limit,
                "handshake_admitted_total": handshake.admitted_total,
                "handshake_completed_total": handshake.completed_total,
                "handshake_transport_error_total": handshake.transport_error_total,
                "handshake_timeout_total": handshake.timeout_total,
                "handshake_cancelled_total": handshake.cancelled_total,
                "session_capacity_limit": "covered_by_required_bounded_relay_tests",
                "authenticated_authorization": "covered_by_required_bounded_relay_tests"
            })
        );

        assert_eq!(rejected.len(), 4);
        Ok::<(), anyhow::Error>(())
    })
    .await??;
    Ok(())
}

#[test]
fn scheduler_rejects_n_plus_one_recovers_capacity_and_isolates_a_slow_peer()
-> gateway_rs::error::GatewayResult<()> {
    let scheduler = Arc::new(SubscriberScheduler::new(
        SchedulerConfig {
            max_subscribers: 2,
            queue_objects: 1,
            queue_bytes: 1_024,
            delta_deadline: Duration::from_millis(50),
            random_access_deadline: Duration::from_millis(200),
            critical_deadline: Duration::from_millis(500),
        },
        EventLogger::new("federation-scheduler-test".to_owned()),
    ));
    let fast = scheduler.register(SubscriberId::new("fast")?)?;
    let slow = scheduler.register(SubscriberId::new("slow")?)?;
    assert!(
        scheduler
            .register(SubscriberId::new("n-plus-one")?)
            .is_err()
    );

    let now = tokio::time::Instant::now();
    scheduler.fanout(video_object(1, now), now)?;
    assert!(matches!(
        fast.try_receive_at(now)?,
        ReceiveOutcome::Object(_)
    ));
    drop(slow);
    let replacement = scheduler.register(SubscriberId::new("replacement")?)?;
    assert_eq!(scheduler.snapshot().subscribers, 2);

    scheduler.fanout(critical_object(1, now), now)?;
    assert!(matches!(
        fast.try_receive_at(now)?,
        ReceiveOutcome::Object(_)
    ));
    let report = scheduler.fanout(critical_object(2, now), now)?;
    assert_eq!(report.accepted, 1);
    assert_eq!(report.evicted, 1);
    assert!(matches!(
        fast.try_receive_at(now)?,
        ReceiveOutcome::Object(_)
    ));
    assert!(matches!(
        replacement.try_receive_at(now)?,
        ReceiveOutcome::Evicted
    ));
    drop(replacement);
    assert_eq!(scheduler.snapshot().subscribers, 1);
    drop(fast);
    assert_eq!(scheduler.snapshot().subscribers, 0);
    assert_eq!(scheduler.snapshot().queued_objects, 0);
    assert_eq!(scheduler.snapshot().queued_bytes, 0);
    Ok(())
}

struct DelayedSetupSample {
    transport_connect: u64,
    moqt_hold: u64,
    moqt_setup: u64,
}

struct RejectedTransportConnect {
    reason: &'static str,
    elapsed_ms: u64,
}

async fn rejected_identity_transport_connect(
    reason: &'static str,
    config: MoqConfig,
    url: Url,
    relay_addr: SocketAddr,
) -> anyhow::Result<RejectedTransportConnect> {
    let endpoint = prepare_endpoint(&config).await?;
    rejected_transport_connect(reason, endpoint, url, relay_addr).await
}

async fn rejected_transport_connect(
    reason: &'static str,
    endpoint: quic::Endpoint,
    url: Url,
    relay_addr: SocketAddr,
) -> anyhow::Result<RejectedTransportConnect> {
    let started = tokio::time::Instant::now();
    let result = tokio::time::timeout(
        Duration::from_secs(3),
        endpoint.client.connect(&url, Some(relay_addr)),
    )
    .await?;
    anyhow::ensure!(result.is_err(), "{reason} peer unexpectedly authenticated");
    Ok(RejectedTransportConnect {
        reason,
        elapsed_ms: millis(started.elapsed()),
    })
}

fn anonymous_endpoint(root: &Path) -> anyhow::Result<quic::Endpoint> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut roots = RootCertStore::empty();
    for certificate in CertificateDer::pem_file_iter(root)? {
        roots.add(certificate?)?;
    }
    let client = ClientConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .with_root_certificates(roots)
        .with_no_client_auth();
    let tls = moq_native_ietf::tls::Config {
        client,
        server: None,
        fingerprints: Vec::new(),
    };
    quic::Endpoint::new(quic::Config::new("127.0.0.1:0".parse()?, None, tls)?)
}

fn client_config(pki: &TestPki, cert: &Path, key: &Path) -> anyhow::Result<MoqConfig> {
    let mut config = GatewayConfig::new("federation-concurrency-test", "info", 1_000)
        .map_err(|source| anyhow::anyhow!(source.to_string()))?
        .moq;
    config.bind_addr = "127.0.0.1:0".parse()?;
    config.tls_root.clone_from(&pki.root_a);
    config.tls_client_cert = cert.to_path_buf();
    config.tls_client_key = key.to_path_buf();
    config.connect_timeout = Duration::from_secs(2);
    Ok(config)
}

fn video_object(group_id: u64, now: tokio::time::Instant) -> MediaObject {
    media_object(
        TrackId::VideoHq,
        AccessUnitKind::RandomAccess,
        Codec::H264,
        group_id,
        now,
    )
}

fn critical_object(object_id: u64, now: tokio::time::Instant) -> MediaObject {
    media_object(
        TrackId::CriticalAudio,
        AccessUnitKind::Audio,
        Codec::Aac,
        object_id,
        now,
    )
}

fn media_object(
    track: TrackId,
    kind: AccessUnitKind,
    codec: Codec,
    object_id: u64,
    now: tokio::time::Instant,
) -> MediaObject {
    MediaObject {
        group: Group {
            id: object_id,
            track: Track { id: track },
            random_access: true,
        },
        object_id,
        program_number: 1,
        pid: 256,
        codec,
        kind,
        pts_ns: Some(object_id),
        dts_ns: Some(object_id),
        payload: Bytes::from_static(b"already-encoded-payload"),
        cmaf_init: None,
        connection_id: Arc::from("srt-federation-test"),
        peer: SocketAddr::from(([127, 0, 0, 1], 9_000)),
        received_at: now,
    }
}

fn available_udp_addr() -> anyhow::Result<SocketAddr> {
    let socket = UdpSocket::bind("127.0.0.1:0")?;
    Ok(socket.local_addr()?)
}

fn process_rss_kib() -> anyhow::Result<u64> {
    let status = fs::read_to_string("/proc/self/status")?;
    let value = status
        .lines()
        .find_map(|line| line.strip_prefix("VmRSS:"))
        .and_then(|line| line.split_whitespace().next())
        .ok_or_else(|| anyhow::anyhow!("VmRSS is unavailable"))?;
    Ok(value.parse()?)
}

fn process_task_count() -> anyhow::Result<usize> {
    Ok(fs::read_dir("/proc/self/task")?.count())
}

fn process_socket_count() -> anyhow::Result<usize> {
    let mut sockets = 0_usize;
    for entry in fs::read_dir("/proc/self/fd")? {
        let target = fs::read_link(entry?.path())?;
        if target.to_string_lossy().starts_with("socket:[") {
            sockets = sockets.saturating_add(1);
        }
    }
    Ok(sockets)
}

fn millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}
