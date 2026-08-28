use std::{
    net::{SocketAddr, UdpSocket},
    num::NonZeroUsize,
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::Duration,
};

use async_trait::async_trait;
use gateway_rs::{
    config::GatewayConfig,
    security::{
        federated_identity::{
            FederatedPrincipal, INITIAL_PUBLISH_NAMESPACE, InitialPublishOperation,
            authenticate_verified_peer,
        },
        mtls::prepare_endpoint,
    },
};
use moq_native_ietf::quic;
use moq_relay_ietf::{
    AuthenticatedSession, AuthorizationError, Coordinator, CoordinatorContext, CoordinatorError,
    CoordinatorResult, NamespaceOrigin, NamespaceRegistration, Operation, RelayConfig,
    RelayInboundSessionMonitor, RequestedConnectionPath, ScopeInfo, ScopePermissions,
    SessionAuthorizer, SessionConfig,
};
use moq_transport::{
    coding::TrackNamespace,
    serve::Tracks,
    session::{Session, Transport},
};
use tokio::sync::Semaphore;
use tokio_util::sync::CancellationToken;
use url::Url;

mod support;

use support::pki::TestPki;

const TEST_TIMEOUT: Duration = Duration::from_secs(15);
const NAMESPACE: &str = INITIAL_PUBLISH_NAMESPACE;
const CACHE_IDLE_TIMEOUT: Duration = Duration::from_secs(5);

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

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn required_bounded_relay_composes_identity_authorization_and_capacity() -> anyhow::Result<()>
{
    for route in [Route::RawQuic, Route::WebTransport] {
        exercise_route(route).await?;
    }
    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn verified_but_unauthorized_gateway_is_denied_before_scope() -> anyhow::Result<()> {
    for route in [Route::RawQuic, Route::WebTransport] {
        exercise_denied_identity(route).await?;
    }
    Ok(())
}

async fn exercise_denied_identity(route: Route) -> anyhow::Result<()> {
    let deadline = tokio::time::Instant::now()
        .checked_add(TEST_TIMEOUT)
        .ok_or_else(|| anyhow::anyhow!("test watchdog is not representable"))?;
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
    let state = Arc::new(PolicyState::default());
    let relay = RelayConfig {
        bind: None,
        endpoints: vec![endpoint],
        tls,
        qlog_dir: None,
        mlog_dir: None,
        announce: None,
        node: None,
        coordinator: Arc::new(ProbeCoordinator {
            state: state.clone(),
        }),
        session: SessionConfig::default(),
        connection_tagger: None,
    }
    .build_required_bounded_with_cache_idle_timeout(
        Arc::new(RequiredPolicy {
            state: state.clone(),
        }),
        1,
        1,
        Duration::from_secs(5),
        CACHE_IDLE_TIMEOUT,
    )?;
    let shutdown = CancellationToken::new();
    let relay_task = tokio::spawn(relay.run_until(shutdown.clone()));
    let client_endpoint =
        authenticated_client_with(&pki, &pki.gateway_denied_cert_a, &pki.gateway_denied_key_a)
            .await?;
    let url = route.url(address)?;
    let (native, _connection_id, transport) = tokio::time::timeout_at(
        deadline,
        client_endpoint.client.connect(&url, Some(address)),
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
    anyhow::ensure!(state.legacy_scope_calls.load(Ordering::Acquire) == 0);

    shutdown.cancel();
    let report = tokio::time::timeout_at(deadline, relay_task).await???;
    anyhow::ensure!(report.inbound.active_inbound_sessions == 0);
    anyhow::ensure!(report.inbound.inflight_inbound_futures == 0);
    Ok(())
}

async fn exercise_route(route: Route) -> anyhow::Result<()> {
    let deadline = tokio::time::Instant::now()
        .checked_add(TEST_TIMEOUT)
        .ok_or_else(|| anyhow::anyhow!("test watchdog is not representable"))?;
    let pki = TestPki::generate()?;
    let address = available_udp_addr()?;
    let tls = pki.relay_tls()?;
    let handshake_limits = quic::ServerAdmissionConfig::new(
        non_zero(4, "buffered incoming")?,
        non_zero(2, "pending handshakes")?,
        Duration::from_secs(5),
        quic::HandshakeCapacityPolicy::Refuse,
    )?;
    let endpoint = quic::Endpoint::new_bounded(
        quic::Config::new(address, None, tls.clone())?,
        handshake_limits,
    )?;
    let handshake = endpoint
        .server
        .as_ref()
        .and_then(quic::Server::handshake_admission)
        .ok_or_else(|| anyhow::anyhow!("C1 controller is unavailable"))?;

    let state = Arc::new(PolicyState::default());
    let coordinator: Arc<dyn Coordinator> = Arc::new(ProbeCoordinator {
        state: state.clone(),
    });
    let authorizer: Arc<dyn SessionAuthorizer> = Arc::new(RequiredPolicy {
        state: state.clone(),
    });
    let relay = RelayConfig {
        bind: None,
        endpoints: vec![endpoint],
        tls,
        qlog_dir: None,
        mlog_dir: None,
        announce: None,
        node: None,
        coordinator,
        session: SessionConfig::default(),
        connection_tagger: None,
    }
    .build_required_bounded_with_cache_idle_timeout(
        authorizer,
        1,
        1,
        Duration::from_secs(5),
        CACHE_IDLE_TIMEOUT,
    )?;
    let inbound = relay.inbound_session_monitor();
    let shutdown = CancellationToken::new();
    let relay_task = tokio::spawn(relay.run_until(shutdown.clone()));

    let client_endpoint = authenticated_client(&pki).await?;
    let url = route.url(address)?;
    let (native, _connection_id, transport) = tokio::time::timeout_at(
        deadline,
        client_endpoint.client.connect(&url, Some(address)),
    )
    .await??;
    anyhow::ensure!(transport == route.transport(), "transport route changed");
    let (session, mut publisher, _subscriber) = tokio::time::timeout_at(
        deadline,
        Session::connect_with_config(native, None, transport, SessionConfig::default()),
    )
    .await??;
    let session_task = tokio::spawn(session.run());

    let (tracks_writer, _track_requests, tracks_reader) =
        Tracks::new(TrackNamespace::from_utf8_path(NAMESPACE)).produce();
    let publish_task =
        tokio::spawn(async move { publisher.publish_namespace(tracks_reader).await });
    acquire_before(&state.operation_seen, deadline).await?;
    acquire_before(&state.effect_seen, deadline).await?;

    assert_required_effect_order(&state, &inbound)?;

    let (extra, _connection_id, extra_transport) = tokio::time::timeout_at(
        deadline,
        client_endpoint.client.connect(&url, Some(address)),
    )
    .await??;
    anyhow::ensure!(
        extra_transport == route.transport(),
        "N+1 transport route changed"
    );
    let _capacity_close = tokio::time::timeout_at(deadline, extra.closed()).await?;
    anyhow::ensure!(state.authenticate_calls.load(Ordering::Acquire) == 1);
    let capacity = inbound.snapshot();
    anyhow::ensure!(capacity.admitted_total == 1);
    anyhow::ensure!(capacity.rejected_capacity_total == 1);
    anyhow::ensure!(capacity.active_inbound_sessions == 1);

    drop(tracks_writer);
    shutdown.cancel();
    let report = tokio::time::timeout_at(deadline, relay_task).await???;
    anyhow::ensure!(report.inbound.active_inbound_sessions == 0);
    anyhow::ensure!(report.inbound.inflight_inbound_futures == 0);
    anyhow::ensure!(report.outbound.active_outbound_sessions == 0);
    anyhow::ensure!(report.outbound.inflight_outbound_futures == 0);
    anyhow::ensure!(handshake.snapshot().pending_handshakes == 0);

    finish_task(publish_task).await;
    finish_task(session_task).await;
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
    anyhow::ensure!(state.authorize_calls.load(Ordering::Acquire) == 1);
    anyhow::ensure!(state.register_calls.load(Ordering::Acquire) == 1);
    anyhow::ensure!(!state.order_violation.load(Ordering::Acquire));
    anyhow::ensure!(state.legacy_scope_calls.load(Ordering::Acquire) == 0);
    anyhow::ensure!(inbound.snapshot().active_inbound_sessions == 1);
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
    sequence: AtomicUsize,
    authentication_attempts: AtomicUsize,
    authenticate_calls: AtomicUsize,
    resolve_calls: AtomicUsize,
    authorize_calls: AtomicUsize,
    register_calls: AtomicUsize,
    legacy_scope_calls: AtomicUsize,
    authorization_complete: AtomicBool,
    order_violation: AtomicBool,
    operation_seen: Semaphore,
    effect_seen: Semaphore,
}

impl Default for PolicyState {
    fn default() -> Self {
        Self {
            sequence: AtomicUsize::new(0),
            authentication_attempts: AtomicUsize::new(0),
            authenticate_calls: AtomicUsize::new(0),
            resolve_calls: AtomicUsize::new(0),
            authorize_calls: AtomicUsize::new(0),
            register_calls: AtomicUsize::new(0),
            legacy_scope_calls: AtomicUsize::new(0),
            authorization_complete: AtomicBool::new(false),
            order_violation: AtomicBool::new(false),
            operation_seen: Semaphore::new(0),
            effect_seen: Semaphore::new(0),
        }
    }
}

impl PolicyState {
    fn step(&self, expected: usize) {
        let observed = self.sequence.fetch_add(1, Ordering::AcqRel);
        if observed != expected {
            self.order_violation.store(true, Ordering::Release);
        }
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
        self.state.step(0);
        Ok(AuthenticatedSession::new(principal))
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
        self.state.resolve_calls.fetch_add(1, Ordering::AcqRel);
        self.state.step(1);
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
        self.state.step(2);
        self.state
            .authorization_complete
            .store(true, Ordering::Release);
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
        if !self.state.authorization_complete.load(Ordering::Acquire)
            || namespace != &TrackNamespace::from_utf8_path(NAMESPACE)
        {
            self.state.order_violation.store(true, Ordering::Release);
            return Err(CoordinatorError::NamespaceNotFound);
        }
        self.state.register_calls.fetch_add(1, Ordering::AcqRel);
        self.state.step(3);
        self.state.effect_seen.add_permits(1);
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
