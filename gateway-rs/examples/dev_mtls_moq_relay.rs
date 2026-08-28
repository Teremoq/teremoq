//! Laboratorio loopback de federación mTLS basado en el relay oficial.

use std::{net::SocketAddr, num::NonZeroUsize, path::PathBuf, sync::Arc, time::Duration};

use async_trait::async_trait;
use gateway_rs::security::federated_identity::{
    FederatedPrincipal, InitialPublishOperation, authenticate_verified_peer,
};
use moq_native_ietf::quic::{self, HandshakeCapacityPolicy, ServerAdmissionConfig};
use moq_relay_ietf::{
    AuthenticatedSession, AuthorizationError, Coordinator, CoordinatorContext, CoordinatorError,
    CoordinatorResult, NamespaceOrigin, NamespaceRegistration, Operation, RelayConfig,
    RequestedConnectionPath, ScopeInfo, ScopePermissions, SessionAuthorizer, SessionConfig,
};
use moq_transport::coding::TrackNamespace;
use rustls::{ClientConfig, RootCertStore, ServerConfig, server::WebPkiClientVerifier};
use rustls_pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};
use tokio_util::sync::CancellationToken;

const DEFAULT_BIND: &str = "127.0.0.1:4443";
const FEDERATED_SCOPE: &str = "teremoq-federated-mtls-lab";
const UPSTREAM_QUIC_IDLE_TIMEOUT: Duration = Duration::from_secs(10);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(10);
const CACHE_IDLE_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_BUFFERED_INCOMING: usize = 32;
const MAX_PENDING_HANDSHAKES: usize = 8;
const MAX_INBOUND_SESSIONS: usize = 16;
const MAX_OUTBOUND_SESSIONS: usize = 4;

#[tokio::main(flavor = "multi_thread")]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter("info,quinn=warn,moq_transport=info")
        .try_init()
        .map_err(|source| anyhow::anyhow!(source.to_string()))?;

    let bind = env_socket("TEREMOQ_DEV_MTLS_RELAY_BIND", DEFAULT_BIND)?;
    if !bind.ip().is_loopback() {
        anyhow::bail!("the mTLS development relay must remain bound to loopback");
    }
    let cert = required_env_path("TEREMOQ_DEV_MTLS_RELAY_TLS_CERT")?;
    let key = required_env_path("TEREMOQ_DEV_MTLS_RELAY_TLS_KEY")?;
    let client_ca = required_env_path("TEREMOQ_DEV_MTLS_RELAY_CLIENT_CA")?;
    let tls = load_mtls_server(cert, key, client_ca).await?;

    let admission = ServerAdmissionConfig::new(
        non_zero(MAX_BUFFERED_INCOMING, "max buffered incoming")?,
        non_zero(MAX_PENDING_HANDSHAKES, "max pending handshakes")?,
        HANDSHAKE_TIMEOUT,
        HandshakeCapacityPolicy::Refuse,
    )?;
    let endpoint =
        quic::Endpoint::new_bounded(quic::Config::new(bind, None, tls.clone())?, admission)?;
    let coordinator: Arc<dyn Coordinator> = Arc::new(PublishOnlyCoordinator);
    let authorizer: Arc<dyn SessionAuthorizer> = Arc::new(PublishOnlyAuthorizer);
    let relay = RelayConfig {
        bind: None,
        endpoints: vec![endpoint],
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
    .build_required_bounded_with_cache_idle_timeout(
        authorizer,
        MAX_INBOUND_SESSIONS,
        MAX_OUTBOUND_SESSIONS,
        SHUTDOWN_TIMEOUT,
        CACHE_IDLE_TIMEOUT,
    )?;

    tracing::info!(
        schema_version = 1_u8,
        event = "dev_mtls_moq_relay_ready",
        bind = %bind,
        publisher_path = "/publish",
        client_certificate_required = true,
        tls_protocol = "1.3",
        quic_idle_timeout_ms = duration_millis(UPSTREAM_QUIC_IDLE_TIMEOUT),
        handshake_deadline_enforced = true,
        handshake_capacity_enforced = true,
        session_capacity_enforced = true,
        authenticated_authorization_required = true,
        cache_idle_timeout_ms = duration_millis(CACHE_IDLE_TIMEOUT),
        "integration laboratory; not the final production federated service"
    );

    let shutdown = CancellationToken::new();
    let relay_run = relay.run_until(shutdown.clone());
    tokio::pin!(relay_run);
    tokio::select! {
        result = &mut relay_run => {
            let _report = result?;
            Ok(())
        },
        result = gateway_rs::lifecycle::shutdown_signal() => {
            result.map_err(|source| anyhow::anyhow!(source.to_string()))?;
            shutdown.cancel();
            let _report = relay_run.await?;
            Ok(())
        }
    }
}

fn non_zero(value: usize, name: &str) -> anyhow::Result<NonZeroUsize> {
    NonZeroUsize::new(value).ok_or_else(|| anyhow::anyhow!("{name} must be non-zero"))
}

async fn load_mtls_server(
    cert_path: PathBuf,
    key_path: PathBuf,
    client_ca_path: PathBuf,
) -> anyhow::Result<moq_native_ietf::tls::Config> {
    let cert_pem = tokio::fs::read(cert_path).await?;
    let mut key_pem = tokio::fs::read(key_path).await?;
    let ca_pem = tokio::fs::read(client_ca_path).await?;

    let chain = CertificateDer::pem_slice_iter(&cert_pem).collect::<Result<Vec<_>, _>>()?;
    anyhow::ensure!(!chain.is_empty(), "server certificate chain is empty");
    let mut keys = PrivateKeyDer::pem_slice_iter(&key_pem);
    let key = keys
        .next()
        .transpose()?
        .ok_or_else(|| anyhow::anyhow!("server private key is missing"))?;
    anyhow::ensure!(
        keys.next().is_none(),
        "server key file must contain one key"
    );
    key_pem.fill(0);

    let mut roots = RootCertStore::empty();
    for certificate in CertificateDer::pem_slice_iter(&ca_pem) {
        roots.add(certificate?)?;
    }
    anyhow::ensure!(!roots.is_empty(), "client CA trust store is empty");

    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let verifier =
        WebPkiClientVerifier::builder_with_provider(Arc::new(roots.clone()), provider.clone())
            .build()?;
    let server = ServerConfig::builder_with_provider(provider.clone())
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .with_client_cert_verifier(verifier)
        .with_single_cert(chain, key)?;
    let client = ClientConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .with_root_certificates(roots)
        .with_no_client_auth();
    Ok(moq_native_ietf::tls::Config {
        client,
        server: Some(server),
        fingerprints: Vec::new(),
    })
}

struct PublishOnlyCoordinator;

#[async_trait]
impl Coordinator for PublishOnlyCoordinator {
    async fn resolve_scope(
        &self,
        connection_path: Option<&str>,
    ) -> CoordinatorResult<Option<ScopeInfo>> {
        if connection_path != Some("/publish") {
            return Err(CoordinatorError::NamespaceNotFound);
        }
        Ok(Some(ScopeInfo {
            scope_id: FEDERATED_SCOPE.to_owned(),
            permissions: ScopePermissions::ReadWrite,
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
    ) -> CoordinatorResult<(NamespaceOrigin, Option<moq_native_ietf::quic::Client>)> {
        Err(CoordinatorError::NamespaceNotFound)
    }
}

struct PublishOnlyAuthorizer;

#[async_trait]
impl SessionAuthorizer for PublishOnlyAuthorizer {
    async fn authenticate(
        &self,
        peer: &moq_native_ietf::quic::VerifiedPeerEvidence,
    ) -> Result<AuthenticatedSession, AuthorizationError> {
        let principal = authenticate_verified_peer(peer)
            .map_err(|_| AuthorizationError::AuthenticationRejected)?;
        Ok(AuthenticatedSession::new(principal))
    }

    async fn resolve_scope(
        &self,
        session: &AuthenticatedSession,
        path: &RequestedConnectionPath,
    ) -> Result<Option<ScopeInfo>, AuthorizationError> {
        authenticated_publisher(session)?;
        if path.as_str() != "/publish" {
            return Err(AuthorizationError::AuthorizationDenied);
        }
        Ok(Some(ScopeInfo {
            scope_id: FEDERATED_SCOPE.to_owned(),
            permissions: ScopePermissions::ReadWrite,
        }))
    }

    async fn authorize(
        &self,
        session: &AuthenticatedSession,
        operation: &Operation,
    ) -> Result<(), AuthorizationError> {
        let principal = authenticated_publisher(session)?;
        let permitted = match operation {
            Operation::Publish { namespace } => {
                principal.authorizes_initial_publish(InitialPublishOperation::Publish, namespace)
            }
            Operation::PublishNamespace { namespace } => principal
                .authorizes_initial_publish(InitialPublishOperation::PublishNamespace, namespace),
            // Subscribe, discovery, track status, relay-peer and future operations are denied.
            _ => false,
        };
        if permitted {
            Ok(())
        } else {
            Err(AuthorizationError::AuthorizationDenied)
        }
    }
}

fn authenticated_publisher(
    session: &AuthenticatedSession,
) -> Result<&FederatedPrincipal, AuthorizationError> {
    session
        .downcast_ref::<FederatedPrincipal>()
        .ok_or(AuthorizationError::ContextTypeMismatch)
}

fn required_env_path(name: &str) -> anyhow::Result<PathBuf> {
    let value = std::env::var_os(name).ok_or_else(|| anyhow::anyhow!("{name} is required"))?;
    anyhow::ensure!(!value.is_empty(), "{name} must not be empty");
    Ok(PathBuf::from(value))
}

fn env_socket(name: &str, default: &str) -> anyhow::Result<SocketAddr> {
    std::env::var(name)
        .unwrap_or_else(|_| default.to_owned())
        .parse::<SocketAddr>()
        .map_err(|source| anyhow::anyhow!("{name} must be an IP socket address: {source}"))
}

fn duration_millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}
