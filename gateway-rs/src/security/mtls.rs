//! Construcción fail-closed del cliente mTLS que consume `moq-native-ietf`.

use std::{fmt::Display, path::Path, sync::Arc};

use moq_native_ietf::quic;
use rustls::{ClientConfig, RootCertStore};
use rustls_pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};

use crate::config::MoqConfig;

/// Razones estables de rechazo de la configuración mTLS local.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MtlsFailureReason {
    /// El trust store configurado no existe.
    MissingRoot,
    /// El certificado cliente configurado no existe.
    MissingClientCertificate,
    /// La clave cliente configurada no existe.
    MissingClientKey,
    /// Un fichero no contiene PEM válido del tipo esperado.
    InvalidPem,
    /// La clave no es un fichero regular o es un symlink.
    InvalidClientKeyFile,
    /// Los permisos Unix de la clave permiten acceso a grupo u otros.
    InsecureKeyPermissions,
    /// Certificado y clave no forman una identidad válida.
    IdentityKeyMismatch,
    /// El trust store no contiene certificados.
    EmptyTrustStore,
    /// La cadena cliente no contiene certificados.
    EmptyClientCertificateChain,
    /// No existe una única clave privada en el fichero.
    InvalidPrivateKeyCount,
    /// Un path configurado no es un fichero regular.
    NotRegularFile,
    /// No se pudo crear el socket o endpoint QUIC upstream.
    EndpointInitializationFailed,
}

impl MtlsFailureReason {
    /// Contrato textual estable para observabilidad y tests.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::MissingRoot => "missing_root",
            Self::MissingClientCertificate => "missing_client_certificate",
            Self::MissingClientKey => "missing_client_key",
            Self::InvalidPem => "invalid_pem",
            Self::InvalidClientKeyFile => "invalid_client_key_file",
            Self::InsecureKeyPermissions => "insecure_key_permissions",
            Self::IdentityKeyMismatch => "identity_key_mismatch",
            Self::EmptyTrustStore => "empty_trust_store",
            Self::EmptyClientCertificateChain => "empty_client_certificate_chain",
            Self::InvalidPrivateKeyCount => "invalid_private_key_count",
            Self::NotRegularFile => "not_regular_file",
            Self::EndpointInitializationFailed => "endpoint_initialization_failed",
        }
    }
}

impl Display for MtlsFailureReason {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.as_str())
    }
}

/// Error local sin paths ni material PKI en su representación pública.
#[derive(Debug)]
pub struct MtlsError {
    reason: MtlsFailureReason,
    source: Option<Box<dyn std::error::Error + Send + Sync + 'static>>,
}

impl MtlsError {
    fn new(reason: MtlsFailureReason) -> Self {
        Self {
            reason,
            source: None,
        }
    }

    fn with_source(
        reason: MtlsFailureReason,
        source: impl std::error::Error + Send + Sync + 'static,
    ) -> Self {
        Self {
            reason,
            source: Some(Box::new(source)),
        }
    }

    fn with_boxed_source(
        reason: MtlsFailureReason,
        source: Box<dyn std::error::Error + Send + Sync + 'static>,
    ) -> Self {
        Self {
            reason,
            source: Some(source),
        }
    }

    /// Razón enumerable apta para observabilidad.
    #[must_use]
    pub const fn reason(&self) -> MtlsFailureReason {
        self.reason
    }
}

impl Display for MtlsError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "federated mTLS configuration failed: {}",
            self.reason
        )
    }
}

impl std::error::Error for MtlsError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        self.source
            .as_deref()
            .map(|source| source as &(dyn std::error::Error + 'static))
    }
}

/// Carga una vez la identidad local, crea TLS 1.3 mTLS y construye el endpoint
/// QUIC oficial que el publisher reutiliza durante todas sus reconexiones.
///
/// # Errors
///
/// Devuelve una razón estable si la PKI local o el socket no son válidos.
pub async fn prepare_endpoint(config: &MoqConfig) -> Result<quic::Endpoint, MtlsError> {
    validate_regular_file(&config.tls_root, MtlsFailureReason::MissingRoot).await?;
    validate_regular_file(
        &config.tls_client_cert,
        MtlsFailureReason::MissingClientCertificate,
    )
    .await?;
    validate_private_key_file(&config.tls_client_key).await?;

    let root_pem = read_file(&config.tls_root, MtlsFailureReason::MissingRoot).await?;
    let cert_pem = read_file(
        &config.tls_client_cert,
        MtlsFailureReason::MissingClientCertificate,
    )
    .await?;
    let mut key_pem =
        read_file(&config.tls_client_key, MtlsFailureReason::MissingClientKey).await?;

    let roots = parse_certificates(&root_pem, MtlsFailureReason::EmptyTrustStore)?;
    let chain = parse_certificates(&cert_pem, MtlsFailureReason::EmptyClientCertificateChain)?;
    let key = parse_single_private_key(&key_pem);
    key_pem.fill(0);
    let key = key?;

    let mut root_store = RootCertStore::empty();
    for root in roots {
        root_store
            .add(root)
            .map_err(|source| MtlsError::with_source(MtlsFailureReason::InvalidPem, source))?;
    }

    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let client = ClientConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .map_err(|source| MtlsError::with_source(MtlsFailureReason::InvalidPem, source))?
        .with_root_certificates(root_store)
        .with_client_auth_cert(chain, key)
        .map_err(|source| MtlsError::with_source(MtlsFailureReason::IdentityKeyMismatch, source))?;

    let tls = moq_native_ietf::tls::Config {
        client,
        server: None,
        fingerprints: Vec::new(),
    };
    let quic_config = quic::Config::new(config.bind_addr, None, tls).map_err(|source| {
        MtlsError::with_boxed_source(
            MtlsFailureReason::EndpointInitializationFailed,
            source.into_boxed_dyn_error(),
        )
    })?;
    quic::Endpoint::new(quic_config).map_err(|source| {
        MtlsError::with_boxed_source(
            MtlsFailureReason::EndpointInitializationFailed,
            source.into_boxed_dyn_error(),
        )
    })
}

async fn validate_regular_file(
    path: &Path,
    missing_reason: MtlsFailureReason,
) -> Result<(), MtlsError> {
    let metadata = tokio::fs::metadata(path)
        .await
        .map_err(|source| map_metadata_error(source, missing_reason))?;
    if !metadata.is_file() {
        return Err(MtlsError::new(MtlsFailureReason::NotRegularFile));
    }
    Ok(())
}

async fn validate_private_key_file(path: &Path) -> Result<(), MtlsError> {
    let metadata = tokio::fs::symlink_metadata(path)
        .await
        .map_err(|source| map_metadata_error(source, MtlsFailureReason::MissingClientKey))?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(MtlsError::new(MtlsFailureReason::InvalidClientKeyFile));
    }
    validate_private_permissions(&metadata)
}

#[cfg(unix)]
fn validate_private_permissions(metadata: &std::fs::Metadata) -> Result<(), MtlsError> {
    use std::os::unix::fs::PermissionsExt;

    if metadata.permissions().mode() & 0o077 != 0 {
        return Err(MtlsError::new(MtlsFailureReason::InsecureKeyPermissions));
    }
    Ok(())
}

#[cfg(not(unix))]
fn validate_private_permissions(_metadata: &std::fs::Metadata) -> Result<(), MtlsError> {
    Ok(())
}

async fn read_file(path: &Path, missing_reason: MtlsFailureReason) -> Result<Vec<u8>, MtlsError> {
    tokio::fs::read(path)
        .await
        .map_err(|source| map_metadata_error(source, missing_reason))
}

fn map_metadata_error(source: std::io::Error, missing_reason: MtlsFailureReason) -> MtlsError {
    if source.kind() == std::io::ErrorKind::NotFound {
        MtlsError::with_source(missing_reason, source)
    } else {
        MtlsError::with_source(MtlsFailureReason::NotRegularFile, source)
    }
}

fn parse_certificates(
    pem: &[u8],
    empty_reason: MtlsFailureReason,
) -> Result<Vec<CertificateDer<'static>>, MtlsError> {
    let certificates = CertificateDer::pem_slice_iter(pem)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|source| MtlsError::with_source(MtlsFailureReason::InvalidPem, source))?;
    if certificates.is_empty() {
        return Err(MtlsError::new(empty_reason));
    }
    Ok(certificates)
}

fn parse_single_private_key(pem: &[u8]) -> Result<PrivateKeyDer<'static>, MtlsError> {
    let mut keys = PrivateKeyDer::pem_slice_iter(pem);
    let Some(first) = keys.next() else {
        return Err(MtlsError::new(MtlsFailureReason::InvalidPrivateKeyCount));
    };
    let first =
        first.map_err(|source| MtlsError::with_source(MtlsFailureReason::InvalidPem, source))?;
    if let Some(second) = keys.next() {
        second.map_err(|source| MtlsError::with_source(MtlsFailureReason::InvalidPem, source))?;
        return Err(MtlsError::new(MtlsFailureReason::InvalidPrivateKeyCount));
    }
    Ok(first)
}
