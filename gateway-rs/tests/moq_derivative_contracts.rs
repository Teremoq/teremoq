use std::{
    fs,
    io::{self, Write},
    net::{SocketAddr, UdpSocket},
    num::NonZeroUsize,
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
    },
    time::Duration,
};

use async_trait::async_trait;
use gateway_rs::{
    config::GatewayConfig,
    security::{
        federated_identity::{
            FederatedPrincipal, INITIAL_GATEWAY_NODE_ID, INITIAL_PUBLISH_NAMESPACE,
            InitialPublishOperation, authenticate_verified_peer,
        },
        mtls::prepare_endpoint,
    },
};
use moq_native_ietf::quic;
use moq_relay_ietf::{
    AuthenticatedSession, AuthorizationError, Coordinator, CoordinatorContext, CoordinatorError,
    CoordinatorResult, NamespaceOrigin, NamespaceRegistration, Operation, RelayConfig,
    RelayInboundSessionMonitor, RelayPeerOperation, RelayShutdownReport, RequestedConnectionPath,
    ScopeInfo, ScopePermissions, SessionAuthorizer, SessionConfig, TrackRegistration,
};
use moq_transport::{
    coding::{KeyValuePairs, TrackNamespace, TrackNamespacePrefix},
    message::SubscribeOptions,
    serve::{Track, Tracks},
    session::{Publisher, Session, Subscriber, Transport},
};
use tokio::sync::Semaphore;
use tokio_util::sync::CancellationToken;
use url::Url;

mod support;

use support::pki::TestPki;

const TEST_TIMEOUT: Duration = Duration::from_secs(15);
const NAMESPACE: &str = INITIAL_PUBLISH_NAMESPACE;
const CACHE_IDLE_TIMEOUT: Duration = Duration::from_secs(5);
const CAPACITY_CLOSE_CODE: u32 = 0x3;
const CAPACITY_CLOSE_REASON: &str = "relay session capacity reached";
static LOG_DIRECTORY_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Default)]
struct TraceCapture(Arc<Mutex<Vec<u8>>>);

struct TraceWriter(Arc<Mutex<Vec<u8>>>);

impl TraceCapture {
    fn output(&self) -> anyhow::Result<String> {
        let bytes = self
            .0
            .lock()
            .map_err(|_| anyhow::anyhow!("trace capture is unavailable"))?;
        Ok(String::from_utf8_lossy(&bytes).into_owned())
    }
}

impl Write for TraceWriter {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.0
            .lock()
            .map_err(|_| io::Error::other("trace capture is unavailable"))?
            .extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for TraceCapture {
    type Writer = TraceWriter;

    fn make_writer(&'a self) -> Self::Writer {
        TraceWriter(self.0.clone())
    }
}

struct TestLogDirectories {
    root: PathBuf,
    qlog: PathBuf,
    mlog: PathBuf,
}

impl TestLogDirectories {
    fn new() -> anyhow::Result<Self> {
        let sequence = LOG_DIRECTORY_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "teremoq-required-redaction-{}-{sequence}",
            std::process::id()
        ));
        let qlog = root.join("qlog");
        let mlog = root.join("mlog");
        fs::create_dir_all(&qlog)?;
        fs::create_dir_all(&mlog)?;
        Ok(Self { root, qlog, mlog })
    }

    fn is_empty(path: &Path) -> anyhow::Result<bool> {
        Ok(fs::read_dir(path)?.next().is_none())
    }
}

impl Drop for TestLogDirectories {
    fn drop(&mut self) {
        let _result = fs::remove_dir_all(&self.root);
    }
}

fn assert_redacted_observability(
    logs: &TestLogDirectories,
    trace: &TraceCapture,
    canaries: &[&str],
) -> anyhow::Result<()> {
    anyhow::ensure!(
        TestLogDirectories::is_empty(&logs.mlog)?,
        "required mode created an mlog containing authenticated traffic"
    );
    anyhow::ensure!(
        TestLogDirectories::is_empty(&logs.qlog)?,
        "explicit product endpoint unexpectedly created qlog output"
    );
    let output = trace.output()?;
    anyhow::ensure!(
        output.contains("required session scope authorized"),
        "trace capture did not observe the fixed required-mode event"
    );
    for canary in canaries {
        anyhow::ensure!(
            !output.contains(canary),
            "required tracing exposed protected product material"
        );
    }
    Ok(())
}

struct RelayHarness {
    pki: TestPki,
    address: SocketAddr,
    state: Arc<PolicyState>,
    policy: Arc<RequiredPolicy>,
    handshake: quic::HandshakeAdmission,
    inbound: RelayInboundSessionMonitor,
    shutdown: CancellationToken,
    relay_task: tokio::task::JoinHandle<anyhow::Result<RelayShutdownReport>>,
}

fn start_required_relay(
    max_sessions: usize,
    logs: Option<&TestLogDirectories>,
) -> anyhow::Result<RelayHarness> {
    let pki = TestPki::generate()?;
    let address = available_udp_addr()?;
    let tls = pki.relay_tls()?;
    let endpoint = quic::Endpoint::new_bounded(
        quic::Config::new(address, None, tls.clone())?,
        quic::ServerAdmissionConfig::new(
            non_zero(4, "buffered incoming")?,
            non_zero(2, "pending handshakes")?,
            Duration::from_secs(5),
            quic::HandshakeCapacityPolicy::Refuse,
        )?,
    )?;
    let handshake = endpoint
        .server
        .as_ref()
        .and_then(quic::Server::handshake_admission)
        .ok_or_else(|| anyhow::anyhow!("C1 controller is unavailable"))?;
    let state = Arc::new(PolicyState::default());
    let policy = Arc::new(RequiredPolicy {
        state: state.clone(),
    });
    let relay = RelayConfig {
        bind: None,
        endpoints: vec![endpoint],
        tls,
        qlog_dir: logs.map(|directories| directories.qlog.clone()),
        mlog_dir: logs.map(|directories| directories.mlog.clone()),
        announce: None,
        node: None,
        coordinator: Arc::new(ProbeCoordinator {
            state: state.clone(),
        }),
        session: SessionConfig::default(),
        connection_tagger: None,
    }
    .build_required_bounded_with_cache_idle_timeout(
        policy.clone(),
        max_sessions,
        1,
        Duration::from_secs(5),
        CACHE_IDLE_TIMEOUT,
    )?;
    let inbound = relay.inbound_session_monitor();
    let shutdown = CancellationToken::new();
    let relay_task = tokio::spawn(relay.run_until(shutdown.clone()));
    Ok(RelayHarness {
        pki,
        address,
        state,
        policy,
        handshake,
        inbound,
        shutdown,
        relay_task,
    })
}

#[derive(Clone, Copy)]
enum Route {
    RawQuic,
    WebTransport,
}

impl Route {
    fn url(self, address: SocketAddr) -> anyhow::Result<Url> {
        let scheme = match self {
            Self::RawQuic => "moqt",
            Self::WebTransport => "https",
        };
        Ok(Url::parse(&format!(
            "{scheme}://127.0.0.1:{}/publish",
            address.port()
        ))?)
    }

    const fn transport(self) -> Transport {
        match self {
            Self::RawQuic => Transport::RawQuic,
            Self::WebTransport => Transport::WebTransport,
        }
    }
}

#[tokio::test(flavor = "current_thread")]
async fn required_bounded_relay_composes_identity_authorization_and_capacity() -> anyhow::Result<()>
{
    for route in [Route::RawQuic, Route::WebTransport] {
        exercise_route(route).await?;
    }
    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn verified_but_unauthorized_gateway_is_denied_before_scope() -> anyhow::Result<()> {
    for identity in [
        DeniedIdentity::GatewayNotAllowlisted,
        DeniedIdentity::MissingUri,
        DeniedIdentity::RelayRole,
    ] {
        for route in [Route::RawQuic, Route::WebTransport] {
            exercise_denied_identity(route, identity).await?;
        }
    }
    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_verified_identities_remain_connection_isolated() -> anyhow::Result<()> {
    for route in [Route::RawQuic, Route::WebTransport] {
        exercise_concurrent_identity_isolation(route).await?;
    }
    Ok(())
}

async fn exercise_concurrent_identity_isolation(route: Route) -> anyhow::Result<()> {
    let deadline = tokio::time::Instant::now()
        .checked_add(TEST_TIMEOUT)
        .ok_or_else(|| anyhow::anyhow!("test watchdog is not representable"))?;
    let harness = start_required_relay(2, None)?;
    let state = &harness.state;
    let valid_client = authenticated_client(&harness.pki).await?;
    let denied_client = authenticated_client_with(
        &harness.pki,
        &harness.pki.gateway_denied_cert_a,
        &harness.pki.gateway_denied_key_a,
    )
    .await?;
    let url = route.url(harness.address)?;
    let (valid_native, denied_native) = tokio::join!(
        tokio::time::timeout_at(
            deadline,
            valid_client.client.connect(&url, Some(harness.address)),
        ),
        tokio::time::timeout_at(
            deadline,
            denied_client.client.connect(&url, Some(harness.address)),
        ),
    );
    let (valid_native, _, valid_transport) = valid_native??;
    let (denied_native, _, denied_transport) = denied_native??;
    anyhow::ensure!(valid_transport == route.transport());
    anyhow::ensure!(denied_transport == route.transport());
    let (valid_setup, denied_setup) = tokio::join!(
        tokio::time::timeout_at(
            deadline,
            Session::connect_with_config(
                valid_native,
                None,
                valid_transport,
                SessionConfig::default(),
            ),
        ),
        tokio::time::timeout_at(
            deadline,
            Session::connect_with_config(
                denied_native,
                None,
                denied_transport,
                SessionConfig::default(),
            ),
        ),
    );
    let (valid_session, valid_publisher, valid_subscriber) = valid_setup??;
    anyhow::ensure!(denied_setup?.is_err(), "denied peer completed MoQT setup");
    let valid_session_task = tokio::spawn(valid_session.run());

    anyhow::ensure!(state.authentication_attempts.load(Ordering::Acquire) == 2);
    anyhow::ensure!(state.authenticate_calls.load(Ordering::Acquire) == 1);
    anyhow::ensure!(state.resolve_calls.load(Ordering::Acquire) == 1);
    let authenticated = state
        .authenticated_context
        .lock()
        .map_err(|_| anyhow::anyhow!("authenticated context probe is unavailable"))?
        .clone()
        .ok_or_else(|| anyhow::anyhow!("authenticated context probe was not populated"))?;
    let principal = authenticated
        .downcast_ref::<FederatedPrincipal>()
        .ok_or_else(|| anyhow::anyhow!("authenticated context type changed"))?;
    anyhow::ensure!(principal.node_id() == INITIAL_GATEWAY_NODE_ID);
    assert_product_effects_zero(state)?;

    drop(valid_publisher);
    drop(valid_subscriber);
    finish_task(valid_session_task).await;
    harness.shutdown.cancel();
    let report = tokio::time::timeout_at(deadline, harness.relay_task).await???;
    anyhow::ensure!(report.inbound.active_inbound_sessions == 0);
    anyhow::ensure!(report.inbound.inflight_inbound_futures == 0);
    Ok(())
}

#[tokio::test(flavor = "current_thread")]
async fn disallowed_operations_are_denied_before_product_effects() -> anyhow::Result<()> {
    for route in [Route::RawQuic, Route::WebTransport] {
        exercise_disallowed_operations(route).await?;
    }
    Ok(())
}

async fn exercise_disallowed_operations(route: Route) -> anyhow::Result<()> {
    let deadline = tokio::time::Instant::now()
        .checked_add(TEST_TIMEOUT)
        .ok_or_else(|| anyhow::anyhow!("test watchdog is not representable"))?;
    let trace = TraceCapture::default();
    let subscriber = tracing_subscriber::fmt()
        .without_time()
        .with_ansi(false)
        .with_env_filter("moq_relay_ietf=trace")
        .with_writer(trace.clone())
        .finish();
    let _trace_guard = tracing::subscriber::set_default(subscriber);
    let logs = TestLogDirectories::new()?;
    let harness = start_required_relay(1, Some(&logs))?;
    let state = &harness.state;
    let client = authenticated_client(&harness.pki).await?;
    let url = route.url(harness.address)?;
    let (native, _connection_id, transport) =
        tokio::time::timeout_at(deadline, client.client.connect(&url, Some(harness.address)))
            .await??;
    let (session, mut publisher, mut subscriber) = tokio::time::timeout_at(
        deadline,
        Session::connect_with_config(native, None, transport, SessionConfig::default()),
    )
    .await??;
    let session_task = tokio::spawn(session.run());

    exercise_default_denials(
        &mut publisher,
        &mut subscriber,
        state,
        &harness.policy,
        deadline,
    )
    .await?;
    assert_product_effects_zero(state)?;
    assert_redacted_observability(
        &logs,
        &trace,
        &[
            "teremoq/denied",
            "prefix-canary-f03",
            "missing",
            url.as_str(),
        ],
    )?;

    drop(publisher);
    drop(subscriber);
    finish_task(session_task).await;
    harness.shutdown.cancel();
    let report = tokio::time::timeout_at(deadline, harness.relay_task).await???;
    anyhow::ensure!(report.inbound.active_inbound_sessions == 0);
    anyhow::ensure!(report.inbound.inflight_inbound_futures == 0);
    Ok(())
}

async fn exercise_default_denials(
    publisher: &mut Publisher,
    subscriber: &mut Subscriber,
    state: &PolicyState,
    policy: &RequiredPolicy,
    deadline: tokio::time::Instant,
) -> anyhow::Result<()> {
    let denied_namespace = TrackNamespace::from_utf8_path("teremoq/denied");
    let (_writer, reader) = Track::new(denied_namespace.clone(), "video").produce();
    let mut denied_publish = tokio::time::timeout_at(
        deadline,
        publisher.publish(reader, KeyValuePairs::default()),
    )
    .await??;
    let publish_response = tokio::time::timeout_at(deadline, denied_publish.ok()).await?;
    anyhow::ensure!(
        publish_response.is_err(),
        "wrong-namespace PUBLISH was accepted"
    );

    let (_tracks_writer, _requests, tracks_reader) = Tracks::new(denied_namespace).produce();
    let namespace_publish =
        tokio::time::timeout_at(deadline, publisher.publish_namespace(tracks_reader)).await?;
    anyhow::ensure!(
        namespace_publish.is_err(),
        "wrong-namespace PUBLISH_NAMESPACE was accepted"
    );

    let (subscribe_writer, _subscribe_reader) =
        Track::new(TrackNamespace::from_utf8_path(NAMESPACE), "missing").produce();
    let subscribe_response =
        tokio::time::timeout_at(deadline, subscriber.subscribe_open(subscribe_writer)).await?;
    anyhow::ensure!(subscribe_response.is_err(), "SUBSCRIBE was accepted");

    let namespace_subscription = tokio::time::timeout_at(
        deadline,
        subscriber.subscribe_namespace(
            TrackNamespacePrefix::from_utf8_path("prefix-canary-f03"),
            SubscribeOptions::Namespace,
            KeyValuePairs::default(),
        ),
    )
    .await??;
    let namespace_response = tokio::time::timeout_at(deadline, namespace_subscription.ok()).await?;
    anyhow::ensure!(
        namespace_response.is_err(),
        "SUBSCRIBE_NAMESPACE was accepted"
    );

    subscriber.track_status(&TrackNamespace::from_utf8_path(NAMESPACE), "video");
    for _ in 0..5 {
        acquire_before(&state.operation_attempt_seen, deadline).await?;
    }
    let authenticated = state
        .authenticated_context
        .lock()
        .map_err(|_| anyhow::anyhow!("authenticated context probe is unavailable"))?
        .clone()
        .ok_or_else(|| anyhow::anyhow!("authenticated context probe was not populated"))?;
    for operation in [
        Operation::DiscoverNamespace {
            namespace: TrackNamespace::from_utf8_path(NAMESPACE),
        },
        Operation::RelayPeer {
            operation: RelayPeerOperation::Publish {
                namespace: TrackNamespace::from_utf8_path(NAMESPACE),
            },
        },
    ] {
        anyhow::ensure!(
            policy.authorize(&authenticated, &operation).await.is_err(),
            "default-denied operation was accepted"
        );
    }

    anyhow::ensure!(state.authentication_attempts.load(Ordering::Acquire) == 1);
    anyhow::ensure!(state.authenticate_calls.load(Ordering::Acquire) == 1);
    anyhow::ensure!(state.resolve_calls.load(Ordering::Acquire) == 1);
    anyhow::ensure!(state.authorization_attempts.load(Ordering::Acquire) == 7);
    anyhow::ensure!(state.authorize_calls.load(Ordering::Acquire) == 0);
    Ok(())
}

#[derive(Clone, Copy)]
enum DeniedIdentity {
    GatewayNotAllowlisted,
    MissingUri,
    RelayRole,
}

async fn exercise_denied_identity(route: Route, identity: DeniedIdentity) -> anyhow::Result<()> {
    let deadline = tokio::time::Instant::now()
        .checked_add(TEST_TIMEOUT)
        .ok_or_else(|| anyhow::anyhow!("test watchdog is not representable"))?;
    let harness = start_required_relay(1, None)?;
    let state = &harness.state;
    let (certificate, key) = match identity {
        DeniedIdentity::GatewayNotAllowlisted => (
            &harness.pki.gateway_denied_cert_a,
            &harness.pki.gateway_denied_key_a,
        ),
        DeniedIdentity::MissingUri => (
            &harness.pki.gateway_no_uri_cert_a,
            &harness.pki.gateway_no_uri_key_a,
        ),
        DeniedIdentity::RelayRole => (
            &harness.pki.relay_role_cert_a,
            &harness.pki.relay_role_key_a,
        ),
    };
    let client_endpoint = authenticated_client_with(&harness.pki, certificate, key).await?;
    let url = route.url(harness.address)?;
    let (native, _connection_id, transport) = tokio::time::timeout_at(
        deadline,
        client_endpoint.client.connect(&url, Some(harness.address)),
    )
    .await??;
    anyhow::ensure!(transport == route.transport(), "transport route changed");
    let setup = tokio::time::timeout_at(
        deadline,
        Session::connect_with_config(native, None, transport, SessionConfig::default()),
    )
    .await?;
    anyhow::ensure!(setup.is_err(), "unauthorized identity completed MoQT setup");
    anyhow::ensure!(state.authentication_attempts.load(Ordering::Acquire) == 1);
    anyhow::ensure!(state.authenticate_calls.load(Ordering::Acquire) == 0);
    anyhow::ensure!(state.resolve_calls.load(Ordering::Acquire) == 0);
    anyhow::ensure!(state.authorize_calls.load(Ordering::Acquire) == 0);
    anyhow::ensure!(state.register_calls.load(Ordering::Acquire) == 0);
    anyhow::ensure!(state.register_track_calls.load(Ordering::Acquire) == 0);
    anyhow::ensure!(state.lookup_calls.load(Ordering::Acquire) == 0);
    anyhow::ensure!(state.subscribe_namespace_calls.load(Ordering::Acquire) == 0);
    anyhow::ensure!(state.forward_lookup_calls.load(Ordering::Acquire) == 0);
    anyhow::ensure!(state.legacy_scope_calls.load(Ordering::Acquire) == 0);

    harness.shutdown.cancel();
    let report = tokio::time::timeout_at(deadline, harness.relay_task).await???;
    anyhow::ensure!(report.inbound.active_inbound_sessions == 0);
    anyhow::ensure!(report.inbound.inflight_inbound_futures == 0);
    Ok(())
}

async fn exercise_route(route: Route) -> anyhow::Result<()> {
    let deadline = tokio::time::Instant::now()
        .checked_add(TEST_TIMEOUT)
        .ok_or_else(|| anyhow::anyhow!("test watchdog is not representable"))?;
    let trace = TraceCapture::default();
    let subscriber = tracing_subscriber::fmt()
        .without_time()
        .with_ansi(false)
        .with_env_filter("moq_relay_ietf=trace")
        .with_writer(trace.clone())
        .finish();
    let _trace_guard = tracing::subscriber::set_default(subscriber);
    let logs = TestLogDirectories::new()?;
    let harness = start_required_relay(1, Some(&logs))?;
    let state = &harness.state;
    let inbound = &harness.inbound;
    let client_endpoint = authenticated_client(&harness.pki).await?;
    let url = route.url(harness.address)?;
    let (native, _connection_id, transport) = tokio::time::timeout_at(
        deadline,
        client_endpoint.client.connect(&url, Some(harness.address)),
    )
    .await??;
    anyhow::ensure!(transport == route.transport(), "transport route changed");
    let (session, mut publish_sender, subscriber) = tokio::time::timeout_at(
        deadline,
        Session::connect_with_config(native, None, transport, SessionConfig::default()),
    )
    .await??;
    let session_task = tokio::spawn(session.run());

    let (served_track_writer, served_track_reader) =
        Track::new(TrackNamespace::from_utf8_path(NAMESPACE), "video").produce();
    let mut published_track = tokio::time::timeout_at(
        deadline,
        publish_sender.publish(served_track_reader, KeyValuePairs::default()),
    )
    .await??;
    tokio::time::timeout_at(deadline, published_track.ok()).await??;
    acquire_before(&state.operation_seen, deadline).await?;
    acquire_before(&state.effect_seen, deadline).await?;

    let (namespace_writer, _track_requests, namespace_reader) =
        Tracks::new(TrackNamespace::from_utf8_path(NAMESPACE)).produce();
    let publish_task =
        tokio::spawn(async move { publish_sender.publish_namespace(namespace_reader).await });
    acquire_before(&state.operation_seen, deadline).await?;
    acquire_before(&state.effect_seen, deadline).await?;

    assert_required_effect_order(state, inbound)?;

    let capacity_test = CapacityTestContext {
        route,
        deadline,
        address: harness.address,
        client_endpoint: &client_endpoint,
        url: &url,
        state,
        inbound,
    };
    assert_capacity_rejection(&capacity_test).await?;

    drop(published_track);
    drop(served_track_writer);
    drop(namespace_writer);
    drop(subscriber);
    finish_task(publish_task).await;
    finish_task(session_task).await;
    wait_for_active_sessions(inbound, 0, deadline).await?;

    let recovered_session_task = recover_session_capacity(&capacity_test).await?;
    harness.shutdown.cancel();
    let report = tokio::time::timeout_at(deadline, harness.relay_task).await???;
    anyhow::ensure!(report.inbound.active_inbound_sessions == 0);
    anyhow::ensure!(report.inbound.inflight_inbound_futures == 0);
    anyhow::ensure!(report.outbound.active_outbound_sessions == 0);
    anyhow::ensure!(report.outbound.inflight_outbound_futures == 0);
    anyhow::ensure!(harness.handshake.snapshot().pending_handshakes == 0);

    assert_redacted_observability(
        &logs,
        &trace,
        &[
            "Teremoq Gateway A",
            "spiffe://teremoq.local/gateway/gateway-dev-1",
            "gateway-dev-1",
            "/publish",
            NAMESPACE,
            "video",
            "FederatedPrincipal",
            "AuthenticatedSession",
            "CertificateDer",
        ],
    )?;

    finish_task(recovered_session_task).await;
    Ok(())
}

struct CapacityTestContext<'a> {
    route: Route,
    deadline: tokio::time::Instant,
    address: SocketAddr,
    client_endpoint: &'a quic::Endpoint,
    url: &'a Url,
    state: &'a PolicyState,
    inbound: &'a RelayInboundSessionMonitor,
}

async fn assert_capacity_rejection(context: &CapacityTestContext<'_>) -> anyhow::Result<()> {
    let (extra, _connection_id, extra_transport) = tokio::time::timeout_at(
        context.deadline,
        context
            .client_endpoint
            .client
            .connect(context.url, Some(context.address)),
    )
    .await??;
    anyhow::ensure!(
        extra_transport == context.route.transport(),
        "N+1 transport route changed"
    );
    let capacity_close = tokio::time::timeout_at(context.deadline, extra.closed()).await?;
    assert_capacity_close(context.route, capacity_close)?;
    anyhow::ensure!(
        context
            .state
            .authentication_attempts
            .load(Ordering::Acquire)
            == 1
    );
    anyhow::ensure!(context.state.authenticate_calls.load(Ordering::Acquire) == 1);
    anyhow::ensure!(context.state.resolve_calls.load(Ordering::Acquire) == 1);
    anyhow::ensure!(context.state.authorize_calls.load(Ordering::Acquire) == 2);
    anyhow::ensure!(context.state.register_calls.load(Ordering::Acquire) == 1);
    anyhow::ensure!(context.state.register_track_calls.load(Ordering::Acquire) == 1);
    let capacity = context.inbound.snapshot();
    anyhow::ensure!(capacity.admitted_total == 1);
    anyhow::ensure!(capacity.rejected_capacity_total == 1);
    anyhow::ensure!(capacity.active_inbound_sessions == 1);
    Ok(())
}

async fn recover_session_capacity(
    context: &CapacityTestContext<'_>,
) -> anyhow::Result<tokio::task::JoinHandle<Result<(), moq_transport::session::SessionError>>> {
    let (recovered, _connection_id, recovered_transport) = tokio::time::timeout_at(
        context.deadline,
        context
            .client_endpoint
            .client
            .connect(context.url, Some(context.address)),
    )
    .await??;
    anyhow::ensure!(
        recovered_transport == context.route.transport(),
        "recovered transport route changed"
    );
    let (recovered_session, recovered_publisher, recovered_subscriber) = tokio::time::timeout_at(
        context.deadline,
        Session::connect_with_config(
            recovered,
            None,
            recovered_transport,
            SessionConfig::default(),
        ),
    )
    .await??;
    let recovered_session_task = tokio::spawn(recovered_session.run());
    anyhow::ensure!(
        context
            .state
            .authentication_attempts
            .load(Ordering::Acquire)
            == 2
    );
    anyhow::ensure!(context.state.authenticate_calls.load(Ordering::Acquire) == 2);
    anyhow::ensure!(context.state.resolve_calls.load(Ordering::Acquire) == 2);
    anyhow::ensure!(context.state.authorize_calls.load(Ordering::Acquire) == 2);
    anyhow::ensure!(context.state.register_calls.load(Ordering::Acquire) == 1);
    anyhow::ensure!(context.state.register_track_calls.load(Ordering::Acquire) == 1);
    let recovered_capacity = context.inbound.snapshot();
    anyhow::ensure!(recovered_capacity.admitted_total == 2);
    anyhow::ensure!(recovered_capacity.rejected_capacity_total == 1);
    anyhow::ensure!(recovered_capacity.active_inbound_sessions == 1);

    drop(recovered_publisher);
    drop(recovered_subscriber);
    Ok(recovered_session_task)
}

fn assert_capacity_close(route: Route, error: web_transport::Error) -> anyhow::Result<()> {
    match route {
        Route::RawQuic => match error {
            web_transport::Error::Session(web_transport::quinn::SessionError::ConnectionError(
                web_transport::quinn::quinn::ConnectionError::ApplicationClosed(close),
            )) => {
                anyhow::ensure!(
                    close.error_code.into_inner() == u64::from(CAPACITY_CLOSE_CODE),
                    "raw QUIC capacity close code changed"
                );
                anyhow::ensure!(
                    close.reason.as_ref() == CAPACITY_CLOSE_REASON.as_bytes(),
                    "raw QUIC capacity close reason changed"
                );
            }
            _ => anyhow::bail!("raw QUIC capacity rejection used an unexpected public close"),
        },
        Route::WebTransport => match error {
            web_transport::Error::Session(
                web_transport::quinn::SessionError::WebTransportError(
                    web_transport::quinn::WebTransportError::Closed(code, reason),
                ),
            ) => {
                anyhow::ensure!(
                    code == CAPACITY_CLOSE_CODE,
                    "WebTransport capacity close code changed"
                );
                anyhow::ensure!(
                    reason == CAPACITY_CLOSE_REASON,
                    "WebTransport capacity close reason changed"
                );
            }
            _ => anyhow::bail!("WebTransport capacity rejection used an unexpected public close"),
        },
    }
    Ok(())
}

async fn wait_for_active_sessions(
    inbound: &RelayInboundSessionMonitor,
    expected: usize,
    deadline: tokio::time::Instant,
) -> anyhow::Result<()> {
    tokio::time::timeout_at(deadline, async {
        loop {
            if inbound.snapshot().active_inbound_sessions == expected {
                return;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .map_err(|_| anyhow::anyhow!("session capacity recovery watchdog elapsed"))?;
    Ok(())
}

async fn finish_task<T>(task: tokio::task::JoinHandle<T>) {
    if !task.is_finished() {
        task.abort();
    }
    let _result = task.await;
}

fn assert_required_effect_order(
    state: &PolicyState,
    inbound: &RelayInboundSessionMonitor,
) -> anyhow::Result<()> {
    anyhow::ensure!(state.authentication_attempts.load(Ordering::Acquire) == 1);
    anyhow::ensure!(state.authenticate_calls.load(Ordering::Acquire) == 1);
    anyhow::ensure!(state.resolve_calls.load(Ordering::Acquire) == 1);
    anyhow::ensure!(state.authorization_attempts.load(Ordering::Acquire) == 2);
    anyhow::ensure!(state.authorize_calls.load(Ordering::Acquire) == 2);
    anyhow::ensure!(state.register_calls.load(Ordering::Acquire) == 1);
    anyhow::ensure!(state.register_track_calls.load(Ordering::Acquire) == 1);
    anyhow::ensure!(state.total_effect_calls.load(Ordering::Acquire) == 2);
    anyhow::ensure!(!state.order_violation.load(Ordering::Acquire));
    anyhow::ensure!(state.legacy_scope_calls.load(Ordering::Acquire) == 0);
    anyhow::ensure!(inbound.snapshot().active_inbound_sessions == 1);
    Ok(())
}

fn assert_product_effects_zero(state: &PolicyState) -> anyhow::Result<()> {
    anyhow::ensure!(state.register_calls.load(Ordering::Acquire) == 0);
    anyhow::ensure!(state.register_track_calls.load(Ordering::Acquire) == 0);
    anyhow::ensure!(state.lookup_calls.load(Ordering::Acquire) == 0);
    anyhow::ensure!(state.subscribe_namespace_calls.load(Ordering::Acquire) == 0);
    anyhow::ensure!(state.forward_lookup_calls.load(Ordering::Acquire) == 0);
    anyhow::ensure!(state.total_effect_calls.load(Ordering::Acquire) == 0);
    anyhow::ensure!(state.legacy_scope_calls.load(Ordering::Acquire) == 0);
    anyhow::ensure!(!state.order_violation.load(Ordering::Acquire));
    Ok(())
}

async fn acquire_before(
    semaphore: &Semaphore,
    deadline: tokio::time::Instant,
) -> anyhow::Result<()> {
    let permit = tokio::time::timeout_at(deadline, semaphore.acquire()).await??;
    permit.forget();
    Ok(())
}

fn non_zero(value: usize, label: &str) -> anyhow::Result<NonZeroUsize> {
    NonZeroUsize::new(value).ok_or_else(|| anyhow::anyhow!("{label} must be non-zero"))
}

fn available_udp_addr() -> anyhow::Result<SocketAddr> {
    let socket = UdpSocket::bind("127.0.0.1:0")?;
    Ok(socket.local_addr()?)
}

async fn authenticated_client(pki: &TestPki) -> anyhow::Result<quic::Endpoint> {
    authenticated_client_with(pki, &pki.gateway_cert_a, &pki.gateway_key_a).await
}

async fn authenticated_client_with(
    pki: &TestPki,
    certificate: &Path,
    key: &Path,
) -> anyhow::Result<quic::Endpoint> {
    let mut config = GatewayConfig::new("moq-derivative-contract-test", "info", 1_000)
        .map_err(|source| anyhow::anyhow!(source.to_string()))?
        .moq;
    config.bind_addr = "127.0.0.1:0".parse()?;
    config.tls_root.clone_from(&pki.root_a);
    config.tls_client_cert = certificate.to_owned();
    config.tls_client_key = key.to_owned();
    prepare_endpoint(&config).await.map_err(Into::into)
}

struct PolicyState {
    authentication_attempts: AtomicUsize,
    authenticate_calls: AtomicUsize,
    resolve_calls: AtomicUsize,
    authorization_attempts: AtomicUsize,
    authorize_calls: AtomicUsize,
    register_calls: AtomicUsize,
    register_track_calls: AtomicUsize,
    lookup_calls: AtomicUsize,
    subscribe_namespace_calls: AtomicUsize,
    forward_lookup_calls: AtomicUsize,
    total_effect_calls: AtomicUsize,
    legacy_scope_calls: AtomicUsize,
    order_violation: AtomicBool,
    operation_seen: Semaphore,
    operation_attempt_seen: Semaphore,
    effect_seen: Semaphore,
    authenticated_context: Mutex<Option<AuthenticatedSession>>,
}

impl Default for PolicyState {
    fn default() -> Self {
        Self {
            authentication_attempts: AtomicUsize::new(0),
            authenticate_calls: AtomicUsize::new(0),
            resolve_calls: AtomicUsize::new(0),
            authorization_attempts: AtomicUsize::new(0),
            authorize_calls: AtomicUsize::new(0),
            register_calls: AtomicUsize::new(0),
            register_track_calls: AtomicUsize::new(0),
            lookup_calls: AtomicUsize::new(0),
            subscribe_namespace_calls: AtomicUsize::new(0),
            forward_lookup_calls: AtomicUsize::new(0),
            total_effect_calls: AtomicUsize::new(0),
            legacy_scope_calls: AtomicUsize::new(0),
            order_violation: AtomicBool::new(false),
            operation_seen: Semaphore::new(0),
            operation_attempt_seen: Semaphore::new(0),
            effect_seen: Semaphore::new(0),
            authenticated_context: Mutex::new(None),
        }
    }
}

impl PolicyState {
    fn record_effect(&self) {
        let effects = self.total_effect_calls.fetch_add(1, Ordering::AcqRel) + 1;
        if self.authorize_calls.load(Ordering::Acquire) < effects {
            self.order_violation.store(true, Ordering::Release);
        }
        self.effect_seen.add_permits(1);
    }
}

struct RequiredPolicy {
    state: Arc<PolicyState>,
}

#[async_trait]
impl SessionAuthorizer for RequiredPolicy {
    async fn authenticate(
        &self,
        peer: &quic::VerifiedPeerEvidence,
    ) -> Result<AuthenticatedSession, AuthorizationError> {
        self.state
            .authentication_attempts
            .fetch_add(1, Ordering::AcqRel);
        let principal = authenticate_verified_peer(peer)
            .map_err(|_| AuthorizationError::AuthenticationRejected)?;
        self.state.authenticate_calls.fetch_add(1, Ordering::AcqRel);
        let session = AuthenticatedSession::new(principal);
        *self
            .state
            .authenticated_context
            .lock()
            .map_err(|_| AuthorizationError::AuthenticationRejected)? = Some(session.clone());
        Ok(session)
    }

    async fn resolve_scope(
        &self,
        session: &AuthenticatedSession,
        path: &RequestedConnectionPath,
    ) -> Result<Option<ScopeInfo>, AuthorizationError> {
        authenticated_gateway(session)?;
        if path.as_str() != "/publish" {
            return Err(AuthorizationError::AuthorizationDenied);
        }
        if self.state.authenticate_calls.load(Ordering::Acquire)
            <= self.state.resolve_calls.load(Ordering::Acquire)
        {
            self.state.order_violation.store(true, Ordering::Release);
        }
        self.state.resolve_calls.fetch_add(1, Ordering::AcqRel);
        Ok(Some(ScopeInfo {
            scope_id: "required-test-scope".to_owned(),
            permissions: ScopePermissions::ReadWrite,
        }))
    }

    async fn authorize(
        &self,
        session: &AuthenticatedSession,
        operation: &Operation,
    ) -> Result<(), AuthorizationError> {
        let principal = authenticated_gateway(session)?;
        self.state
            .authorization_attempts
            .fetch_add(1, Ordering::AcqRel);
        self.state.operation_attempt_seen.add_permits(1);
        let exact_publish = match operation {
            Operation::Publish { namespace } => {
                principal.authorizes_initial_publish(InitialPublishOperation::Publish, namespace)
            }
            Operation::PublishNamespace { namespace } => principal
                .authorizes_initial_publish(InitialPublishOperation::PublishNamespace, namespace),
            _ => false,
        };
        if !exact_publish {
            return Err(AuthorizationError::AuthorizationDenied);
        }
        self.state.authorize_calls.fetch_add(1, Ordering::AcqRel);
        self.state.operation_seen.add_permits(1);
        Ok(())
    }
}

fn authenticated_gateway(
    session: &AuthenticatedSession,
) -> Result<&FederatedPrincipal, AuthorizationError> {
    session
        .downcast_ref::<FederatedPrincipal>()
        .ok_or(AuthorizationError::ContextTypeMismatch)
}

struct ProbeCoordinator {
    state: Arc<PolicyState>,
}

#[async_trait]
impl Coordinator for ProbeCoordinator {
    async fn resolve_scope(
        &self,
        _connection_path: Option<&str>,
    ) -> CoordinatorResult<Option<ScopeInfo>> {
        self.state.legacy_scope_calls.fetch_add(1, Ordering::AcqRel);
        Err(CoordinatorError::NamespaceNotFound)
    }

    async fn register_namespace(
        &self,
        _scope: Option<&str>,
        namespace: &TrackNamespace,
        _context: &CoordinatorContext,
    ) -> CoordinatorResult<NamespaceRegistration> {
        if namespace != &TrackNamespace::from_utf8_path(NAMESPACE) {
            self.state.order_violation.store(true, Ordering::Release);
            return Err(CoordinatorError::NamespaceNotFound);
        }
        self.state.register_calls.fetch_add(1, Ordering::AcqRel);
        self.state.record_effect();
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
        self.state.lookup_calls.fetch_add(1, Ordering::AcqRel);
        Err(CoordinatorError::NamespaceNotFound)
    }

    async fn subscribe_namespace(
        &self,
        _scope: Option<&str>,
        _prefix: &TrackNamespacePrefix,
        _context: &CoordinatorContext,
    ) -> CoordinatorResult<moq_relay_ietf::NamespaceSubscription> {
        self.state
            .subscribe_namespace_calls
            .fetch_add(1, Ordering::AcqRel);
        Ok(moq_relay_ietf::NamespaceSubscription::default())
    }

    async fn lookup_namespace_subscribers(
        &self,
        _scope: Option<&str>,
        _namespace: &TrackNamespace,
        _context: &CoordinatorContext,
    ) -> CoordinatorResult<Vec<moq_relay_ietf::RelayInfo>> {
        self.state
            .forward_lookup_calls
            .fetch_add(1, Ordering::AcqRel);
        Ok(Vec::new())
    }

    async fn register_track(
        &self,
        _scope: Option<&str>,
        namespace: &TrackNamespace,
        track: &str,
    ) -> CoordinatorResult<TrackRegistration> {
        if namespace != &TrackNamespace::from_utf8_path(NAMESPACE) || track != "video" {
            self.state.order_violation.store(true, Ordering::Release);
            return Err(CoordinatorError::NamespaceNotFound);
        }
        self.state
            .register_track_calls
            .fetch_add(1, Ordering::AcqRel);
        self.state.record_effect();
        Ok(TrackRegistration::default())
    }
}
