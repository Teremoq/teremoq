//! Laboratorio loopback de federación mTLS basado en el relay oficial.

use std::{net::SocketAddr, path::PathBuf, sync::Arc, time::Duration};

use async_trait::async_trait;
use moq_relay_ietf::{
    Coordinator, CoordinatorContext, CoordinatorError, CoordinatorResult, NamespaceOrigin,
    NamespaceRegistration, RelayConfig, ScopeInfo, ScopePermissions, SessionConfig,
};
use moq_transport::coding::TrackNamespace;
use rustls::{ClientConfig, RootCertStore, ServerConfig, server::WebPkiClientVerifier};
use rustls_pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};

const DEFAULT_BIND: &str = "127.0.0.1:4443";
const FEDERATED_SCOPE: &str = "teremoq-federated-mtls-lab";
const UPSTREAM_QUIC_IDLE_TIMEOUT: Duration = Duration::from_secs(10);

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

    let coordinator: Arc<dyn Coordinator> = Arc::new(PublishOnlyCoordinator);
    let relay = RelayConfig {
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
    .build_with_cache_idle_timeout(Duration::from_secs(5))?;

    tracing::info!(
        schema_version = 1_u8,
        event = "dev_mtls_moq_relay_ready",
        bind = %bind,
        publisher_path = "/publish",
        client_certificate_required = true,
        tls_protocol = "1.3",
        quic_idle_timeout_ms = duration_millis(UPSTREAM_QUIC_IDLE_TIMEOUT),
        handshake_deadline_enforced = false,
        handshake_capacity_enforced = false,
        session_capacity_enforced = false,
        "integration laboratory; not the final production federated service"
    );
    tracing::warn!(
        schema_version = 1_u8,
        event = "federation_capacity_unenforced",
        reason = "upstream_api_missing",
        "moq-rs does not expose handshake or authenticated-session admission at the pinned revision"
    );
    tokio::select! {
        result = relay.run() => result,
        result = gateway_rs::lifecycle::shutdown_signal() => {
            result.map_err(|source| anyhow::anyhow!(source.to_string()))?;
            Ok(())
        }
    }
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
