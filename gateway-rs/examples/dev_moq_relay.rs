//! Relay local de evaluación basado íntegramente en `moq-relay-ietf`.

use std::{
    fs,
    io::Write,
    net::{Ipv4Addr, SocketAddr},
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
use x509_parser::extensions::GeneralName;

const DEFAULT_BIND: &str = "127.0.0.1:4433";
const DEFAULT_CERT: &str = ".teremoq-dev/tls/relay-cert.pem";
const DEFAULT_KEY: &str = ".teremoq-dev/tls/relay-key.pem";
const DEFAULT_FINGERPRINT: &str = ".teremoq-dev/tls/relay-cert.sha256";
const DEFAULT_IDENTITY_PROFILE: &str = ".teremoq-dev/tls/relay-webtransport-v1";
const DEFAULT_PROFILE_MARKER: &str = "webtransport-hash-v1\n";
const LAN_PROFILE_VERSION: &str = "webtransport-hash-v2-lan-ip-sha256";
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
    ensure_loopback_bind(bind)?;
    let lan_ip_san = env_lan_ip_san("TEREMOQ_DEV_RELAY_LAN_IP_SAN")?;
    let cert = env_path("TEREMOQ_DEV_RELAY_TLS_CERT", DEFAULT_CERT);
    let key = env_path("TEREMOQ_DEV_RELAY_TLS_KEY", DEFAULT_KEY);
    let fingerprint = env_path("TEREMOQ_DEV_RELAY_TLS_FINGERPRINT", DEFAULT_FINGERPRINT);
    let identity_profile = env_path("TEREMOQ_DEV_RELAY_TLS_PROFILE", DEFAULT_IDENTITY_PROFILE);
    ensure_persistent_identity(&cert, &key, &fingerprint, &identity_profile, lan_ip_san)?;

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
        lan_ip_san_configured = lan_ip_san.is_some(),
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
    lan_ip_san: Option<Ipv4Addr>,
) -> anyhow::Result<()> {
    let expected_profile = identity_profile(lan_ip_san);
    let state = [
        cert_path.exists(),
        key_path.exists(),
        fingerprint_path.exists(),
        identity_profile_path.exists(),
    ];
    match state {
        [true, true, true, true] => {
            let existing_profile = fs::read(identity_profile_path)?;
            if existing_profile != expected_profile.as_bytes() {
                anyhow::bail!(
                    "the persistent relay identity profile does not match the requested SAN mode; rotate all explicit development identity files"
                );
            }
            validate_certificate_profile(cert_path, lan_ip_san)?;
            return ensure_fingerprint(cert_path, fingerprint_path);
        }
        [false, false, false, false] => {}
        _ => {
            anyhow::bail!(
                "refusing a partial persistent relay identity; rotate all explicit development identity files together"
            );
        }
    }
    if let Some(parent) = cert_path.parent() {
        fs::create_dir_all(parent)?;
    }
    if let Some(parent) = key_path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut subject_alt_names = vec!["127.0.0.1".to_owned(), "localhost".to_owned()];
    if let Some(lan_ip_san) = lan_ip_san {
        subject_alt_names.push(lan_ip_san.to_string());
    }
    let mut params = CertificateParams::new(subject_alt_names)?;
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
    write_new(identity_profile_path, expected_profile.as_bytes(), false)
}

fn identity_profile(lan_ip_san: Option<Ipv4Addr>) -> String {
    lan_ip_san.map_or_else(
        || DEFAULT_PROFILE_MARKER.to_owned(),
        |lan_ip_san| {
            let digest = sha256_hex(lan_ip_san.to_string().as_bytes());
            format!("{LAN_PROFILE_VERSION}:{digest}\n")
        },
    )
}

fn validate_certificate_profile(
    cert_path: &Path,
    lan_ip_san: Option<Ipv4Addr>,
) -> anyhow::Result<()> {
    let certificate = pem::parse(fs::read(cert_path)?)?;
    let (remaining, certificate) = x509_parser::parse_x509_certificate(certificate.contents())
        .map_err(|_| {
            anyhow::anyhow!(
                "the persistent relay certificate profile cannot be validated; rotate all explicit development identity files"
            )
        })?;
    if !remaining.is_empty() {
        anyhow::bail!(
            "the persistent relay certificate profile cannot be validated; rotate all explicit development identity files"
        );
    }
    let alternative_names = certificate
        .subject_alternative_name()
        .map_err(|_| {
            anyhow::anyhow!(
                "the persistent relay certificate profile cannot be validated; rotate all explicit development identity files"
            )
        })?
        .ok_or_else(|| {
            anyhow::anyhow!(
                "the persistent relay certificate profile cannot be validated; rotate all explicit development identity files"
            )
        })?;
    let mut localhost_count = 0_u8;
    let mut loopback_count = 0_u8;
    let mut lan_count = 0_u8;
    for name in &alternative_names.value.general_names {
        match name {
            GeneralName::DNSName("localhost") => localhost_count += 1,
            GeneralName::IPAddress(bytes) if *bytes == Ipv4Addr::LOCALHOST.octets() => {
                loopback_count += 1;
            }
            GeneralName::IPAddress(bytes)
                if lan_ip_san.is_some_and(|lan_ip_san| *bytes == lan_ip_san.octets()) =>
            {
                lan_count += 1;
            }
            _ => {
                anyhow::bail!(
                    "the persistent relay certificate SAN profile does not match the requested mode; rotate all explicit development identity files"
                );
            }
        }
    }
    let expected_lan_count = u8::from(lan_ip_san.is_some());
    if localhost_count != 1 || loopback_count != 1 || lan_count != expected_lan_count {
        anyhow::bail!(
            "the persistent relay certificate SAN profile does not match the requested mode; rotate all explicit development identity files"
        );
    }
    let validity_seconds = certificate
        .validity()
        .not_after
        .timestamp()
        .checked_sub(certificate.validity().not_before.timestamp())
        .ok_or_else(|| anyhow::anyhow!("the persistent relay certificate validity is invalid"))?;
    if validity_seconds <= 0 || validity_seconds >= 14 * 24 * 60 * 60 {
        anyhow::bail!(
            "the persistent relay certificate validity exceeds the WebTransport profile; rotate all explicit development identity files"
        );
    }
    Ok(())
}

fn ensure_fingerprint(cert_path: &Path, fingerprint_path: &Path) -> anyhow::Result<()> {
    let certificate = pem::parse(fs::read(cert_path)?)?;
    let expected = sha256_hex(certificate.contents());
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

fn sha256_hex(contents: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";

    let digest = Sha256::digest(contents);
    let mut encoded = String::with_capacity(64);
    for byte in digest {
        encoded.push(char::from(HEX[usize::from(byte >> 4)]));
        encoded.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    encoded
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

fn ensure_loopback_bind(bind: SocketAddr) -> anyhow::Result<()> {
    if !bind.ip().is_loopback() {
        anyhow::bail!("the development relay must remain bound to loopback");
    }
    Ok(())
}

fn env_lan_ip_san(name: &str) -> anyhow::Result<Option<Ipv4Addr>> {
    let Some(raw) = std::env::var_os(name) else {
        return Ok(None);
    };
    let raw = raw
        .into_string()
        .map_err(|_| anyhow::anyhow!("{name} must be a canonical RFC1918 IPv4 literal"))?;
    parse_lan_ip_san(name, &raw).map(Some)
}

fn parse_lan_ip_san(name: &str, raw: &str) -> anyhow::Result<Ipv4Addr> {
    let lan_ip = raw
        .parse::<Ipv4Addr>()
        .map_err(|_| anyhow::anyhow!("{name} must be a canonical RFC1918 IPv4 literal"))?;
    if raw != lan_ip.to_string() || !is_rfc1918_host(lan_ip) {
        anyhow::bail!("{name} must be a canonical RFC1918 IPv4 literal");
    }
    Ok(lan_ip)
}

fn is_rfc1918_host(address: Ipv4Addr) -> bool {
    let [first, second, _, last] = address.octets();
    let is_private = first == 10
        || (first == 172 && (16..=31).contains(&second))
        || (first == 192 && second == 168);
    is_private && last != 0 && last != 255
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        net::{Ipv4Addr, SocketAddr},
        path::{Path, PathBuf},
        str::FromStr,
        sync::atomic::{AtomicU64, Ordering},
    };

    use x509_parser::extensions::GeneralName;

    use super::{
        CalendarDuration, DEFAULT_BIND, DEFAULT_PROFILE_MARKER, WEBTRANSPORT_CERTIFICATE_DAYS,
        WEBTRANSPORT_CLOCK_SKEW_MINUTES, ensure_loopback_bind, ensure_persistent_identity,
        identity_profile, parse_lan_ip_san, sha256_hex,
    };

    static TEST_DIRECTORY_SEQUENCE: AtomicU64 = AtomicU64::new(0);

    struct IdentityPaths {
        root: PathBuf,
        cert: PathBuf,
        key: PathBuf,
        fingerprint: PathBuf,
        profile: PathBuf,
    }

    impl IdentityPaths {
        fn new(label: &str) -> Self {
            let sequence = TEST_DIRECTORY_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let root = std::env::temp_dir().join(format!(
                "teremoq-dev-relay-{label}-{}-{sequence}",
                std::process::id()
            ));
            Self {
                cert: root.join("relay-cert.pem"),
                key: root.join("relay-key.pem"),
                fingerprint: root.join("relay-cert.sha256"),
                profile: root.join("relay-profile"),
                root,
            }
        }

        fn ensure(&self, lan_ip_san: Option<Ipv4Addr>) -> anyhow::Result<()> {
            ensure_persistent_identity(
                &self.cert,
                &self.key,
                &self.fingerprint,
                &self.profile,
                lan_ip_san,
            )
        }

        fn snapshot(&self) -> Vec<Vec<u8>> {
            [&self.cert, &self.key, &self.fingerprint, &self.profile]
                .into_iter()
                .map(|path| fs::read(path).expect("test identity file must exist"))
                .collect()
        }
    }

    impl Drop for IdentityPaths {
        fn drop(&mut self) {
            if self.root.exists() {
                fs::remove_dir_all(&self.root).expect("test identity directory must be removable");
            }
        }
    }

    struct CertificateSummary {
        dns_names: Vec<String>,
        ip_addresses: Vec<Ipv4Addr>,
        validity_seconds: i64,
        fingerprint: String,
    }

    fn certificate_summary(path: &Path) -> CertificateSummary {
        let pem = pem::parse(fs::read(path).expect("test certificate must be readable"))
            .expect("test certificate PEM must parse");
        let (remaining, certificate) = x509_parser::parse_x509_certificate(pem.contents())
            .expect("test certificate DER must parse");
        assert!(
            remaining.is_empty(),
            "certificate DER must have no trailing data"
        );
        let alternative_names = certificate
            .subject_alternative_name()
            .expect("test certificate SAN extension must parse")
            .expect("test certificate must contain SANs");
        let mut dns_names = Vec::new();
        let mut ip_addresses = Vec::new();
        for name in &alternative_names.value.general_names {
            match name {
                GeneralName::DNSName(name) => dns_names.push((*name).to_owned()),
                GeneralName::IPAddress(bytes) if bytes.len() == 4 => {
                    ip_addresses.push(Ipv4Addr::new(bytes[0], bytes[1], bytes[2], bytes[3]));
                }
                _ => {}
            }
        }
        CertificateSummary {
            dns_names,
            ip_addresses,
            validity_seconds: certificate.validity().not_after.timestamp()
                - certificate.validity().not_before.timestamp(),
            fingerprint: sha256_hex(pem.contents()),
        }
    }

    #[test]
    fn certificate_profile_remains_below_webtransport_limit() {
        let validity = CalendarDuration::days(WEBTRANSPORT_CERTIFICATE_DAYS)
            + CalendarDuration::minutes(WEBTRANSPORT_CLOCK_SKEW_MINUTES);
        assert!(validity < CalendarDuration::days(14));
    }

    #[test]
    fn default_profile_and_loopback_bind_remain_unchanged() {
        let paths = IdentityPaths::new("default");
        paths
            .ensure(None)
            .expect("default identity must be created");
        let first_snapshot = paths.snapshot();
        paths
            .ensure(None)
            .expect("default identity must be reusable");

        assert!(
            paths.snapshot() == first_snapshot,
            "reusing an identity must not change certificate or key material"
        );
        assert_eq!(
            fs::read_to_string(&paths.profile).expect("profile must be readable"),
            DEFAULT_PROFILE_MARKER
        );
        let summary = certificate_summary(&paths.cert);
        assert_eq!(summary.dns_names, ["localhost"]);
        assert_eq!(summary.ip_addresses, [Ipv4Addr::LOCALHOST]);
        assert!(summary.validity_seconds > 0);
        assert!(summary.validity_seconds < 14 * 24 * 60 * 60);
        assert_eq!(
            fs::read_to_string(&paths.fingerprint)
                .expect("fingerprint must be readable")
                .trim(),
            summary.fingerprint
        );

        let default_bind = SocketAddr::from_str(DEFAULT_BIND).expect("default bind must parse");
        assert_eq!(default_bind, SocketAddr::from(([127, 0, 0, 1], 4433)));
        ensure_loopback_bind(default_bind).expect("default bind must remain loopback");
        assert!(
            ensure_loopback_bind(SocketAddr::from(([192, 168, 10, 20], 4433))).is_err(),
            "LAN SAN mode must not permit a LAN listener"
        );
    }

    #[test]
    fn accepts_only_canonical_rfc1918_ipv4_literals() {
        for valid in ["10.1.2.3", "172.16.0.1", "172.31.255.254", "192.168.50.10"] {
            assert_eq!(
                parse_lan_ip_san("TEST_LAN_IP", valid)
                    .expect("canonical RFC1918 address must be accepted")
                    .to_string(),
                valid
            );
        }
        for invalid in [
            "",
            "lan.example",
            "fd00::1",
            "192.168.1.2/24",
            "192.168.1.2:4433",
            "8.8.8.8",
            "169.254.1.2",
            "224.0.0.1",
            "255.255.255.255",
            "0.0.0.0",
            "127.0.0.2",
            "100.64.0.1",
            "10.1.2.255",
            "192.168.1.0",
            " 192.168.1.2",
            "192.168.1.2 ",
            "192.168.1.2/path",
            "192.168.001.2",
            "192.168.1.2\n",
            "192.168.1.2\0",
        ] {
            assert!(
                parse_lan_ip_san("TEST_LAN_IP", invalid).is_err(),
                "non-canonical or non-RFC1918 input must be rejected"
            );
        }
    }

    #[test]
    fn lan_profile_contains_exact_ip_san_validity_and_fingerprint() {
        let paths = IdentityPaths::new("lan");
        let lan_ip = Ipv4Addr::new(192, 168, 50, 10);
        paths
            .ensure(Some(lan_ip))
            .expect("LAN identity must be created");

        let summary = certificate_summary(&paths.cert);
        assert_eq!(summary.dns_names, ["localhost"]);
        assert_eq!(summary.ip_addresses, [Ipv4Addr::LOCALHOST, lan_ip]);
        assert!(summary.validity_seconds > 0);
        assert!(summary.validity_seconds < 14 * 24 * 60 * 60);
        assert_eq!(
            fs::read_to_string(&paths.fingerprint)
                .expect("fingerprint must be readable")
                .trim(),
            summary.fingerprint
        );
        let profile = fs::read_to_string(&paths.profile).expect("profile must be readable");
        assert_eq!(profile, identity_profile(Some(lan_ip)));
        assert!(!profile.contains(&lan_ip.to_string()));
    }

    #[test]
    fn profile_and_certificate_ip_mismatches_fail_closed_without_overwrite() {
        let paths = IdentityPaths::new("mismatch");
        let first_ip = Ipv4Addr::new(10, 20, 30, 40);
        let second_ip = Ipv4Addr::new(192, 168, 20, 30);
        paths
            .ensure(Some(first_ip))
            .expect("first LAN identity must be created");
        let original = paths.snapshot();

        assert!(paths.ensure(Some(second_ip)).is_err());
        assert!(
            paths.snapshot() == original,
            "a profile mismatch must not change identity material"
        );

        fs::write(&paths.profile, identity_profile(Some(second_ip)))
            .expect("test profile replacement must succeed");
        let forged_profile_snapshot = paths.snapshot();
        assert!(paths.ensure(Some(second_ip)).is_err());
        assert!(
            paths.snapshot() == forged_profile_snapshot,
            "a certificate SAN mismatch must not change identity material"
        );

        fs::write(&paths.profile, DEFAULT_PROFILE_MARKER)
            .expect("test legacy profile replacement must succeed");
        let legacy_profile_snapshot = paths.snapshot();
        assert!(paths.ensure(Some(first_ip)).is_err());
        assert!(
            paths.snapshot() == legacy_profile_snapshot,
            "a legacy marker mismatch must not change identity material"
        );
    }

    #[test]
    fn every_partial_identity_state_fails_closed() {
        for mask in 1_u8..15 {
            let paths = IdentityPaths::new("partial");
            for (index, path) in [&paths.cert, &paths.key, &paths.fingerprint, &paths.profile]
                .into_iter()
                .enumerate()
            {
                if mask & (1 << index) != 0 {
                    fs::create_dir_all(path.parent().expect("test path must have parent"))
                        .expect("test directory must be created");
                    fs::write(path, b"synthetic test state")
                        .expect("synthetic partial state must be written");
                }
            }
            let before = [
                paths.cert.exists(),
                paths.key.exists(),
                paths.fingerprint.exists(),
                paths.profile.exists(),
            ];
            assert!(paths.ensure(None).is_err());
            assert_eq!(
                [
                    paths.cert.exists(),
                    paths.key.exists(),
                    paths.fingerprint.exists(),
                    paths.profile.exists(),
                ],
                before
            );
        }
    }
}
