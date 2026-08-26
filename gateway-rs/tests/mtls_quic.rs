use std::{
    fs,
    net::{SocketAddr, UdpSocket},
    path::{Path, PathBuf},
    process::Command,
    sync::Arc,
    time::Duration,
};

use gateway_rs::{
    config::{GatewayConfig, MoqConfig},
    security::mtls::{MtlsFailureReason, prepare_endpoint},
};
use moq_native_ietf::quic;
use moq_transport::session::{Publisher, Session};
use rustls::{ClientConfig, RootCertStore};
use rustls_pki_types::{CertificateDer, pem::PemObject};
use tokio::{sync::oneshot, task::JoinSet};
use url::Url;

mod support;

use support::pki::TestPki;

const TEST_TIMEOUT: Duration = Duration::from_secs(10);

#[tokio::test]
async fn valid_identity_and_complete_chain_load_once() -> anyhow::Result<()> {
    let pki = TestPki::generate()?;
    let config = client_config(&pki, &pki.gateway_cert_a, &pki.gateway_key_a)?;
    let endpoint = prepare_endpoint(&config).await?;
    assert!(endpoint.client.local_addr()?.port() != 0);
    Ok(())
}

#[tokio::test]
async fn missing_and_empty_pki_inputs_are_rejected() -> anyhow::Result<()> {
    let pki = TestPki::generate()?;
    let missing = pki.directory().join("absent.pem");

    let mut config = client_config(&pki, &pki.gateway_cert_a, &pki.gateway_key_a)?;
    config.tls_root = missing.clone();
    assert_reason(&config, MtlsFailureReason::MissingRoot).await;
    config = client_config(&pki, &pki.gateway_cert_a, &pki.gateway_key_a)?;
    config.tls_client_cert = missing.clone();
    assert_reason(&config, MtlsFailureReason::MissingClientCertificate).await;
    config = client_config(&pki, &pki.gateway_cert_a, &pki.gateway_key_a)?;
    config.tls_client_key = missing;
    assert_reason(&config, MtlsFailureReason::MissingClientKey).await;

    let empty_root = write_test_file(pki.directory(), "empty-root.pem", "", false)?;
    config = client_config(&pki, &pki.gateway_cert_a, &pki.gateway_key_a)?;
    config.tls_root = empty_root;
    assert_reason(&config, MtlsFailureReason::EmptyTrustStore).await;
    let empty_cert = write_test_file(pki.directory(), "empty-cert.pem", "", false)?;
    config = client_config(&pki, &pki.gateway_cert_a, &pki.gateway_key_a)?;
    config.tls_client_cert = empty_cert;
    assert_reason(&config, MtlsFailureReason::EmptyClientCertificateChain).await;
    let empty_key = write_test_file(pki.directory(), "empty-key.pem", "", true)?;
    config = client_config(&pki, &pki.gateway_cert_a, &pki.gateway_key_a)?;
    config.tls_client_key = empty_key;
    assert_reason(&config, MtlsFailureReason::InvalidPrivateKeyCount).await;
    Ok(())
}

#[tokio::test]
async fn corrupt_multiple_and_mismatched_material_is_rejected() -> anyhow::Result<()> {
    let pki = TestPki::generate()?;
    let corrupt = write_test_file(
        pki.directory(),
        "corrupt.pem",
        "-----BEGIN CERTIFICATE-----\nnot-base64\n-----END CERTIFICATE-----\n",
        false,
    )?;
    let mut config = client_config(&pki, &pki.gateway_cert_a, &pki.gateway_key_a)?;
    config.tls_root = corrupt;
    assert_reason(&config, MtlsFailureReason::InvalidPem).await;

    let key_pem = fs::read_to_string(&pki.gateway_key_a)?;
    let multiple = write_test_file(
        pki.directory(),
        "multiple-keys.pem",
        &format!("{key_pem}{key_pem}"),
        true,
    )?;
    config = client_config(&pki, &pki.gateway_cert_a, &multiple)?;
    assert_reason(&config, MtlsFailureReason::InvalidPrivateKeyCount).await;

    config = client_config(&pki, &pki.gateway_cert_a, &pki.gateway_wrong_eku_key)?;
    assert_reason(&config, MtlsFailureReason::IdentityKeyMismatch).await;
    Ok(())
}

#[cfg(unix)]
#[tokio::test]
async fn key_symlink_and_group_readable_mode_are_rejected() -> anyhow::Result<()> {
    use std::os::unix::fs::{PermissionsExt, symlink};

    let pki = TestPki::generate()?;
    let symlink_path = pki.directory().join("gateway-key-link.pem");
    symlink(&pki.gateway_key_a, &symlink_path)?;
    let config = client_config(&pki, &pki.gateway_cert_a, &symlink_path)?;
    assert_reason(&config, MtlsFailureReason::InvalidClientKeyFile).await;

    let permissive = pki.directory().join("gateway-key-0644.pem");
    fs::copy(&pki.gateway_key_a, &permissive)?;
    fs::set_permissions(&permissive, fs::Permissions::from_mode(0o644))?;
    let config = client_config(&pki, &pki.gateway_cert_a, &permissive)?;
    assert_reason(&config, MtlsFailureReason::InsecureKeyPermissions).await;

    fs::set_permissions(&permissive, fs::Permissions::from_mode(0o600))?;
    let config = client_config(&pki, &pki.gateway_cert_a, &permissive)?;
    prepare_endpoint(&config).await?;
    Ok(())
}

#[test]
fn deprecated_disable_verify_true_fails_closed() -> anyhow::Result<()> {
    let pki = TestPki::generate()?;
    let output = Command::new(env!("CARGO_BIN_EXE_gateway-rs"))
        .env("TEREMOQ_MOQ_TLS_ROOT", &pki.root_a)
        .env("TEREMOQ_MOQ_TLS_CLIENT_CERT", &pki.gateway_cert_a)
        .env("TEREMOQ_MOQ_TLS_CLIENT_KEY", &pki.gateway_key_a)
        .env("TEREMOQ_MOQ_TLS_DISABLE_VERIFY", "true")
        .output()?;
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("tls_verification_disabled_forbidden"));
    Ok(())
}

#[test]
fn required_pki_environment_variables_fail_closed() -> anyhow::Result<()> {
    let pki = TestPki::generate()?;
    for (missing, reason) in [
        ("TEREMOQ_MOQ_TLS_ROOT", "missing_root"),
        ("TEREMOQ_MOQ_TLS_CLIENT_CERT", "missing_client_certificate"),
        ("TEREMOQ_MOQ_TLS_CLIENT_KEY", "missing_client_key"),
    ] {
        let output = Command::new(env!("CARGO_BIN_EXE_gateway-rs"))
            .env("TEREMOQ_MOQ_TLS_ROOT", &pki.root_a)
            .env("TEREMOQ_MOQ_TLS_CLIENT_CERT", &pki.gateway_cert_a)
            .env("TEREMOQ_MOQ_TLS_CLIENT_KEY", &pki.gateway_key_a)
            .env_remove(missing)
            .env_remove("TEREMOQ_MOQ_TLS_DISABLE_VERIFY")
            .output()?;
        assert!(!output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stdout.contains(reason) || stderr.contains(reason),
            "missing environment variable did not preserve reason {reason}"
        );
    }
    Ok(())
}

#[test]
fn deprecated_disable_verify_false_has_no_bypass_effect() -> anyhow::Result<()> {
    let pki = TestPki::generate()?;
    let missing_root = pki.directory().join("missing-root.pem");
    let output = Command::new(env!("CARGO_BIN_EXE_gateway-rs"))
        .env("TEREMOQ_MOQ_TLS_ROOT", missing_root)
        .env("TEREMOQ_MOQ_TLS_CLIENT_CERT", &pki.gateway_cert_a)
        .env("TEREMOQ_MOQ_TLS_CLIENT_KEY", &pki.gateway_key_a)
        .env("TEREMOQ_MOQ_TLS_DISABLE_VERIFY", "false")
        .output()?;
    assert!(!output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stdout.contains("missing_root") || stderr.contains("missing_root"));
    assert!(!stdout.contains("tls_verification_disabled_forbidden"));
    assert!(!stderr.contains("tls_verification_disabled_forbidden"));
    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn valid_clients_progress_while_invalid_transport_connects_and_delayed_moqt_setup_are_isolated()
-> anyhow::Result<()> {
    tokio::time::timeout(TEST_TIMEOUT, async {
        let pki = TestPki::generate()?;
        let relay_addr = available_udp_addr()?;
        let tls = pki.relay_tls()?;
        let endpoint = quic::Endpoint::new(quic::Config::new(relay_addr, None, tls)?)?;
        let mut server = endpoint
            .server
            .ok_or_else(|| anyhow::anyhow!("test mTLS server is unavailable"))?;

        let server_task = tokio::spawn(async move {
            let mut sessions = JoinSet::new();
            for _accepted in 0..4 {
                let (connection, info) = server
                    .accept()
                    .await
                    .ok_or_else(|| anyhow::anyhow!("mTLS server stopped accepting"))?;
                sessions.spawn(async move {
                    let (session, _publisher, _subscriber) =
                        Session::accept(connection, None, info.transport).await?;
                    let _result = session.run().await;
                    Ok::<(), anyhow::Error>(())
                });
            }
            while let Some(result) = sessions.join_next().await {
                result??;
            }
            Ok::<(), anyhow::Error>(())
        });

        let url = Url::parse(&format!("https://127.0.0.1:{}/publish", relay_addr.port()))?;
        let mut invalid = JoinSet::new();
        invalid.spawn(connect_expect_rejected(
            anonymous_endpoint(&pki.root_a)?,
            url.clone(),
            relay_addr,
        ));
        invalid.spawn(connect_identity_expect_rejected(
            client_config(&pki, &pki.gateway_cert_b, &pki.gateway_key_b)?,
            url.clone(),
            relay_addr,
        ));
        invalid.spawn(connect_identity_expect_rejected(
            client_config(
                &pki,
                &pki.gateway_wrong_eku_cert,
                &pki.gateway_wrong_eku_key,
            )?,
            url.clone(),
            relay_addr,
        ));
        invalid.spawn(connect_identity_expect_rejected(
            client_config(&pki, &pki.gateway_expired_cert, &pki.gateway_expired_key)?,
            url.clone(),
            relay_addr,
        ));

        let mismatch_url =
            Url::parse(&format!("https://wrong.test:{}/publish", relay_addr.port()))?;
        invalid.spawn(connect_identity_expect_rejected(
            client_config(&pki, &pki.gateway_cert_a, &pki.gateway_key_a)?,
            mismatch_url,
            relay_addr,
        ));

        let (release_delayed, delayed_released) = oneshot::channel();
        let delayed_config = client_config(&pki, &pki.gateway_cert_a, &pki.gateway_key_a)?;
        let delayed_task = tokio::spawn(connect_and_complete_moq(
            delayed_config,
            url.clone(),
            relay_addr,
            Some(delayed_released),
        ));
        let mut valid = JoinSet::new();
        for _client_index in 0..3_u8 {
            let config = client_config(&pki, &pki.gateway_cert_a, &pki.gateway_key_a)?;
            valid.spawn(connect_and_complete_moq(
                config,
                url.clone(),
                relay_addr,
                None,
            ));
        }
        while let Some(result) = valid.join_next().await {
            result??;
        }
        assert!(
            !delayed_task.is_finished(),
            "the intentionally blocked client advanced before its observable release"
        );
        release_delayed
            .send(())
            .map_err(|()| anyhow::anyhow!("delayed MoQT client stopped before release"))?;
        delayed_task.await??;
        while let Some(result) = invalid.join_next().await {
            result??;
        }
        server_task.await??;
        Ok::<(), anyhow::Error>(())
    })
    .await??;
    Ok(())
}

async fn connect_and_complete_moq(
    config: MoqConfig,
    url: Url,
    relay_addr: SocketAddr,
    release: Option<oneshot::Receiver<()>>,
) -> anyhow::Result<()> {
    let endpoint = prepare_endpoint(&config).await?;
    let (connection, _connection_id, transport) =
        endpoint.client.connect(&url, Some(relay_addr)).await?;
    if let Some(release) = release {
        release.await?;
    }
    let (session, _publisher) = Publisher::connect(connection, transport).await?;
    drop(session);
    Ok(())
}

async fn connect_identity_expect_rejected(
    config: MoqConfig,
    url: Url,
    relay_addr: SocketAddr,
) -> anyhow::Result<()> {
    let endpoint = prepare_endpoint(&config).await?;
    connect_expect_rejected(endpoint, url, relay_addr).await
}

async fn connect_expect_rejected(
    endpoint: quic::Endpoint,
    url: Url,
    relay_addr: SocketAddr,
) -> anyhow::Result<()> {
    let result = endpoint.client.connect(&url, Some(relay_addr)).await;
    anyhow::ensure!(
        result.is_err(),
        "invalid mTLS client completed WebTransport"
    );
    Ok(())
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
    let mut config = GatewayConfig::new("mtls-quic-test", "info", 1_000)
        .map_err(|source| anyhow::anyhow!(source.to_string()))?
        .moq;
    config.bind_addr = "127.0.0.1:0".parse()?;
    config.tls_root.clone_from(&pki.root_a);
    config.tls_client_cert = cert.to_path_buf();
    config.tls_client_key = key.to_path_buf();
    config.connect_timeout = Duration::from_secs(2);
    Ok(config)
}

async fn assert_reason(config: &MoqConfig, expected: MtlsFailureReason) {
    let result = prepare_endpoint(config).await;
    assert!(
        result.is_err(),
        "expected mTLS configuration failure: {expected}"
    );
    let Some(error) = result.err() else {
        return;
    };
    assert_eq!(error.reason(), expected);
    let public = error.to_string();
    assert!(!public.contains('/'));
    assert!(!public.contains("BEGIN"));
}

fn available_udp_addr() -> anyhow::Result<SocketAddr> {
    let socket = UdpSocket::bind("127.0.0.1:0")?;
    Ok(socket.local_addr()?)
}

fn write_test_file(
    directory: &Path,
    name: &str,
    contents: &str,
    private: bool,
) -> anyhow::Result<PathBuf> {
    let path = directory.join(name);
    fs::write(&path, contents)?;
    set_test_permissions(&path, private)?;
    Ok(path)
}

#[cfg(unix)]
fn set_test_permissions(path: &Path, private: bool) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;

    fs::set_permissions(
        path,
        fs::Permissions::from_mode(if private { 0o600 } else { 0o644 }),
    )
}

#[cfg(not(unix))]
fn set_test_permissions(_path: &Path, _private: bool) -> std::io::Result<()> {
    Ok(())
}
