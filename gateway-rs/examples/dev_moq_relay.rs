//! Relay local de evaluación basado íntegramente en `moq-relay-ietf`.

use std::{
    fs,
    io::Write,
    net::SocketAddr,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use async_trait::async_trait;
use moq_relay_ietf::{
    Coordinator, CoordinatorContext, CoordinatorError, CoordinatorResult, NamespaceOrigin,
    NamespaceRegistration, RelayConfig, ScopeInfo, ScopePermissions, SessionConfig,
};
use moq_transport::coding::TrackNamespace;
use rcgen::{CertificateParams, KeyPair};
use sha2::{Digest, Sha256};
use time::{Duration as CalendarDuration, OffsetDateTime};

const DEFAULT_BIND: &str = "127.0.0.1:4433";
const DEFAULT_CERT: &str = ".teremoq-dev/tls/relay-cert.pem";
const DEFAULT_KEY: &str = ".teremoq-dev/tls/relay-key.pem";
const DEFAULT_FINGERPRINT: &str = ".teremoq-dev/tls/relay-cert.sha256";
const DEFAULT_IDENTITY_PROFILE: &str = ".teremoq-dev/tls/relay-webtransport-v1";
const LOCAL_SCOPE: &str = "teremoq-local";
const WEBTRANSPORT_CERTIFICATE_DAYS: i64 = 13;
const WEBTRANSPORT_CLOCK_SKEW_MINUTES: i64 = 5;

#[tokio::main(flavor = "multi_thread")]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter("info,quinn=warn,moq_transport=info")
        .try_init()
        .map_err(|source| anyhow::anyhow!(source.to_string()))?;

    let bind = env_socket("TEREMOQ_DEV_RELAY_BIND", DEFAULT_BIND)?;
    if !bind.ip().is_loopback() {
        anyhow::bail!("the development relay must remain bound to loopback");
    }
    let cert = env_path("TEREMOQ_DEV_RELAY_TLS_CERT", DEFAULT_CERT);
    let key = env_path("TEREMOQ_DEV_RELAY_TLS_KEY", DEFAULT_KEY);
    let fingerprint = env_path("TEREMOQ_DEV_RELAY_TLS_FINGERPRINT", DEFAULT_FINGERPRINT);
    let identity_profile = env_path("TEREMOQ_DEV_RELAY_TLS_PROFILE", DEFAULT_IDENTITY_PROFILE);
    ensure_persistent_identity(&cert, &key, &fingerprint, &identity_profile)?;

    let tls = moq_native_ietf::tls::Args {
        cert: vec![cert.clone()],
        key: vec![key],
        root: vec![cert.clone()],
        disable_verify: false,
    }
    .load()?;
    let coordinator: Arc<dyn Coordinator> = Arc::new(LocalCoordinator);
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
        event = "dev_moq_relay_ready",
        bind = %bind,
        publisher_path = "/publish",
        subscriber_path = "/watch",
        tls_cert = %cert.display(),
        tls_fingerprint = %fingerprint.display(),
        "development relay uses persistent TLS and loopback access control"
    );
    tokio::select! {
        result = relay.run() => result,
        result = gateway_rs::lifecycle::shutdown_signal() => {
            result.map_err(|source| anyhow::anyhow!(source.to_string()))?;
            Ok(())
        }
    }
}

struct LocalCoordinator;

#[async_trait]
impl Coordinator for LocalCoordinator {
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
            scope_id: LOCAL_SCOPE.to_owned(),
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
    ) -> CoordinatorResult<(NamespaceOrigin, Option<moq_native_ietf::quic::Client>)> {
        Err(CoordinatorError::NamespaceNotFound)
    }
}

fn ensure_persistent_identity(
    cert_path: &Path,
    key_path: &Path,
    fingerprint_path: &Path,
    identity_profile_path: &Path,
) -> anyhow::Result<()> {
    match (cert_path.exists(), key_path.exists()) {
        (true, true) if identity_profile_path.exists() => {
            return ensure_fingerprint(cert_path, fingerprint_path);
        }
        (true, true) => {
            anyhow::bail!(
                "the persistent relay identity predates the WebTransport short-lived certificate profile; rotate the explicit development identity files"
            );
        }
        (true, false) | (false, true) => {
            anyhow::bail!(
                "refusing to replace a partial TLS identity; restore or remove the explicit development files"
            );
        }
        (false, false) => {}
    }
    if let Some(parent) = cert_path.parent() {
        fs::create_dir_all(parent)?;
    }
    if let Some(parent) = key_path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut params = CertificateParams::new(vec!["127.0.0.1".to_owned(), "localhost".to_owned()])?;
    let now = OffsetDateTime::now_utc();
    params.not_before = now
        .checked_sub(CalendarDuration::minutes(WEBTRANSPORT_CLOCK_SKEW_MINUTES))
        .ok_or_else(|| anyhow::anyhow!("cannot calculate certificate start time"))?;
    params.not_after = now
        .checked_add(CalendarDuration::days(WEBTRANSPORT_CERTIFICATE_DAYS))
        .ok_or_else(|| anyhow::anyhow!("cannot calculate certificate expiry"))?;
    let signing_key = KeyPair::generate()?;
    let cert = params.self_signed(&signing_key)?;
    write_new(cert_path, cert.pem().as_bytes(), false)?;
    write_new(key_path, signing_key.serialize_pem().as_bytes(), true)?;
    ensure_fingerprint(cert_path, fingerprint_path)?;
    write_new(identity_profile_path, b"webtransport-hash-v1\n", false)
}

fn ensure_fingerprint(cert_path: &Path, fingerprint_path: &Path) -> anyhow::Result<()> {
    let certificate = pem::parse(fs::read(cert_path)?)?;
    let digest = Sha256::digest(certificate.contents());
    let mut expected = String::with_capacity(64);
    for byte in digest {
        std::fmt::Write::write_fmt(&mut expected, format_args!("{byte:02x}"))?;
    }
    if fingerprint_path.exists() {
        let existing = fs::read_to_string(fingerprint_path)?;
        if existing.trim().eq_ignore_ascii_case(&expected) {
            return Ok(());
        }
        anyhow::bail!(
            "relay fingerprint does not match the persistent certificate; remove only the stale fingerprint file"
        );
    }
    if let Some(parent) = fingerprint_path.parent() {
        fs::create_dir_all(parent)?;
    }
    write_new(fingerprint_path, format!("{expected}\n").as_bytes(), false)
}

fn write_new(path: &Path, contents: &[u8], private: bool) -> anyhow::Result<()> {
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    set_private_mode(&mut options, private);
    let mut file = options.open(path)?;
    file.write_all(contents)?;
    file.sync_all()?;
    Ok(())
}

#[cfg(unix)]
fn set_private_mode(options: &mut fs::OpenOptions, private: bool) {
    use std::os::unix::fs::OpenOptionsExt;

    options.mode(if private { 0o600 } else { 0o644 });
}

#[cfg(not(unix))]
fn set_private_mode(_options: &mut fs::OpenOptions, _private: bool) {}

fn env_path(name: &str, default: &str) -> PathBuf {
    std::env::var_os(name).map_or_else(|| PathBuf::from(default), PathBuf::from)
}

fn env_socket(name: &str, default: &str) -> anyhow::Result<SocketAddr> {
    std::env::var(name)
        .unwrap_or_else(|_| default.to_owned())
        .parse::<SocketAddr>()
        .map_err(|source| anyhow::anyhow!("{name} must be an IP socket address: {source}"))
}

#[cfg(test)]
mod tests {
    use super::{CalendarDuration, WEBTRANSPORT_CERTIFICATE_DAYS, WEBTRANSPORT_CLOCK_SKEW_MINUTES};

    #[test]
    fn certificate_profile_remains_below_webtransport_limit() {
        let validity = CalendarDuration::days(WEBTRANSPORT_CERTIFICATE_DAYS)
            + CalendarDuration::minutes(WEBTRANSPORT_CLOCK_SKEW_MINUTES);
        assert!(validity < CalendarDuration::days(14));
    }
}
