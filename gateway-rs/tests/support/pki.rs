#![allow(dead_code)]
#![allow(clippy::similar_names, clippy::too_many_lines)]

use std::{
    fs,
    path::{Path, PathBuf},
};

use rcgen::{
    BasicConstraints, Certificate, CertificateParams, CertifiedIssuer, DnType,
    ExtendedKeyUsagePurpose, IsCa, KeyPair, KeyUsagePurpose, SanType, date_time_ymd,
    string::Ia5String,
};
use rustls::{ClientConfig, RootCertStore, ServerConfig, server::WebPkiClientVerifier};
use rustls_pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};

pub struct TestPki {
    directory: TestDirectory,
    pub root_a: PathBuf,
    pub intermediate_a: PathBuf,
    pub relay_cert_a: PathBuf,
    pub relay_key_a: PathBuf,
    pub gateway_cert_a: PathBuf,
    pub gateway_key_a: PathBuf,
    pub gateway_denied_cert_a: PathBuf,
    pub gateway_denied_key_a: PathBuf,
    pub gateway_wrong_eku_cert: PathBuf,
    pub gateway_wrong_eku_key: PathBuf,
    pub root_b: PathBuf,
    pub gateway_cert_b: PathBuf,
    pub gateway_key_b: PathBuf,
    pub gateway_expired_cert: PathBuf,
    pub gateway_expired_key: PathBuf,
}

impl TestPki {
    pub fn generate() -> anyhow::Result<Self> {
        let directory = TestDirectory::new()?;

        let root_a_key = KeyPair::generate()?;
        let root_a = CertifiedIssuer::self_signed(ca_params("Teremoq Test Root A", 1), root_a_key)?;
        let intermediate_a_key = KeyPair::generate()?;
        let intermediate_a = CertifiedIssuer::signed_by(
            ca_params("Teremoq Test Intermediate A", 0),
            intermediate_a_key,
            &root_a,
        )?;

        let relay_key = KeyPair::generate()?;
        let relay_cert = end_entity(
            "Teremoq Relay A",
            &["127.0.0.1", "relay.test"],
            None,
            ExtendedKeyUsagePurpose::ServerAuth,
            None,
            &relay_key,
            &intermediate_a,
        )?;
        let gateway_key = KeyPair::generate()?;
        let gateway_cert = end_entity(
            "Teremoq Gateway A",
            &[],
            Some("spiffe://teremoq.local/gateway/gateway-dev-1"),
            ExtendedKeyUsagePurpose::ClientAuth,
            None,
            &gateway_key,
            &intermediate_a,
        )?;
        let wrong_eku_key = KeyPair::generate()?;
        let wrong_eku_cert = end_entity(
            "Teremoq Gateway Wrong EKU",
            &[],
            Some("spiffe://teremoq.local/gateway/gateway-dev-1"),
            ExtendedKeyUsagePurpose::ServerAuth,
            None,
            &wrong_eku_key,
            &intermediate_a,
        )?;
        let expired_key = KeyPair::generate()?;
        let expired_cert = end_entity(
            "Teremoq Gateway Expired",
            &[],
            Some("spiffe://teremoq.local/gateway/gateway-dev-1"),
            ExtendedKeyUsagePurpose::ClientAuth,
            Some((date_time_ymd(2020, 1, 1), date_time_ymd(2021, 1, 1))),
            &expired_key,
            &intermediate_a,
        )?;
        let denied_key = KeyPair::generate()?;
        let denied_cert = end_entity(
            "Teremoq Gateway Denied",
            &[],
            Some("spiffe://teremoq.local/gateway/gateway-dev-2"),
            ExtendedKeyUsagePurpose::ClientAuth,
            None,
            &denied_key,
            &intermediate_a,
        )?;

        let root_b_key = KeyPair::generate()?;
        let root_b = CertifiedIssuer::self_signed(ca_params("Teremoq Test Root B", 1), root_b_key)?;
        let gateway_b_key = KeyPair::generate()?;
        let gateway_b_cert = end_entity(
            "Teremoq Gateway B",
            &[],
            Some("spiffe://teremoq.local/gateway/gateway-dev-2"),
            ExtendedKeyUsagePurpose::ClientAuth,
            None,
            &gateway_b_key,
            &root_b,
        )?;

        let root_a_path = directory.write("root-a.pem", &root_a.pem(), false)?;
        let intermediate_a_path =
            directory.write("intermediate-a.pem", &intermediate_a.pem(), false)?;
        let relay_cert_a = directory.write(
            "relay-a-chain.pem",
            &format!("{}{}", relay_cert.pem(), intermediate_a.pem()),
            false,
        )?;
        let relay_key_a = directory.write("relay-a-key.pem", &relay_key.serialize_pem(), true)?;
        let gateway_cert_a = directory.write(
            "gateway-a-chain.pem",
            &format!("{}{}", gateway_cert.pem(), intermediate_a.pem()),
            false,
        )?;
        let gateway_key_a =
            directory.write("gateway-a-key.pem", &gateway_key.serialize_pem(), true)?;
        let gateway_denied_cert_a = directory.write(
            "gateway-denied-chain.pem",
            &format!("{}{}", denied_cert.pem(), intermediate_a.pem()),
            false,
        )?;
        let gateway_denied_key_a =
            directory.write("gateway-denied-key.pem", &denied_key.serialize_pem(), true)?;
        let gateway_wrong_eku_cert = directory.write(
            "gateway-wrong-eku-chain.pem",
            &format!("{}{}", wrong_eku_cert.pem(), intermediate_a.pem()),
            false,
        )?;
        let gateway_wrong_eku_key = directory.write(
            "gateway-wrong-eku-key.pem",
            &wrong_eku_key.serialize_pem(),
            true,
        )?;
        let gateway_expired_cert = directory.write(
            "gateway-expired-chain.pem",
            &format!("{}{}", expired_cert.pem(), intermediate_a.pem()),
            false,
        )?;
        let gateway_expired_key = directory.write(
            "gateway-expired-key.pem",
            &expired_key.serialize_pem(),
            true,
        )?;
        let root_b_path = directory.write("root-b.pem", &root_b.pem(), false)?;
        let gateway_cert_b = directory.write("gateway-b.pem", &gateway_b_cert.pem(), false)?;
        let gateway_key_b =
            directory.write("gateway-b-key.pem", &gateway_b_key.serialize_pem(), true)?;

        Ok(Self {
            directory,
            root_a: root_a_path,
            intermediate_a: intermediate_a_path,
            relay_cert_a,
            relay_key_a,
            gateway_cert_a,
            gateway_key_a,
            gateway_denied_cert_a,
            gateway_denied_key_a,
            gateway_wrong_eku_cert,
            gateway_wrong_eku_key,
            root_b: root_b_path,
            gateway_cert_b,
            gateway_key_b,
            gateway_expired_cert,
            gateway_expired_key,
        })
    }

    pub fn directory(&self) -> &Path {
        self.directory.path()
    }

    pub fn relay_tls(&self) -> anyhow::Result<moq_native_ietf::tls::Config> {
        let provider = std::sync::Arc::new(rustls::crypto::ring::default_provider());
        let roots = root_store(&self.root_a)?;
        let verifier = WebPkiClientVerifier::builder_with_provider(
            std::sync::Arc::new(roots.clone()),
            provider.clone(),
        )
        .build()?;
        let chain =
            CertificateDer::pem_file_iter(&self.relay_cert_a)?.collect::<Result<Vec<_>, _>>()?;
        let key = PrivateKeyDer::from_pem_file(&self.relay_key_a)?;
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
}

fn root_store(path: &Path) -> anyhow::Result<RootCertStore> {
    let mut roots = RootCertStore::empty();
    for certificate in CertificateDer::pem_file_iter(path)? {
        roots.add(certificate?)?;
    }
    Ok(roots)
}

fn ca_params(common_name: &str, path_length: u8) -> CertificateParams {
    let mut params = CertificateParams::default();
    params
        .distinguished_name
        .push(DnType::CommonName, common_name);
    params.is_ca = IsCa::Ca(BasicConstraints::Constrained(path_length));
    params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];
    params
}

fn end_entity(
    common_name: &str,
    sans: &[&str],
    uri_san: Option<&str>,
    eku: ExtendedKeyUsagePurpose,
    validity: Option<(time::OffsetDateTime, time::OffsetDateTime)>,
    key: &KeyPair,
    issuer: &rcgen::Issuer<'_, impl rcgen::SigningKey>,
) -> Result<Certificate, rcgen::Error> {
    let mut params = CertificateParams::new(
        sans.iter()
            .map(|name| (*name).to_owned())
            .collect::<Vec<_>>(),
    )?;
    if let Some(uri) = uri_san {
        params
            .subject_alt_names
            .push(SanType::URI(Ia5String::try_from(uri)?));
    }
    params
        .distinguished_name
        .push(DnType::CommonName, common_name);
    params.is_ca = IsCa::ExplicitNoCa;
    params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
    params.extended_key_usages = vec![eku];
    if let Some((not_before, not_after)) = validity {
        params.not_before = not_before;
        params.not_after = not_after;
    }
    params.signed_by(key, issuer)
}

pub struct TestDirectory(PathBuf);

impl TestDirectory {
    pub fn new() -> anyhow::Result<Self> {
        let mut random = [0_u8; 8];
        getrandom::fill(&mut random)?;
        let name = format!(
            "teremoq-mtls-test-{}-{}",
            std::process::id(),
            u64::from_le_bytes(random)
        );
        let path = std::env::temp_dir().join(name);
        fs::create_dir(&path)?;
        Ok(Self(path))
    }

    pub fn path(&self) -> &Path {
        &self.0
    }

    pub fn write(&self, name: &str, contents: &str, private: bool) -> anyhow::Result<PathBuf> {
        let path = self.0.join(name);
        fs::write(&path, contents)?;
        set_permissions(&path, private)?;
        Ok(path)
    }
}

impl Drop for TestDirectory {
    fn drop(&mut self) {
        let _result = fs::remove_dir_all(&self.0);
    }
}

#[cfg(unix)]
fn set_permissions(path: &Path, private: bool) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;

    fs::set_permissions(
        path,
        fs::Permissions::from_mode(if private { 0o600 } else { 0o644 }),
    )
}

#[cfg(not(unix))]
fn set_permissions(_path: &Path, _private: bool) -> std::io::Result<()> {
    Ok(())
}
