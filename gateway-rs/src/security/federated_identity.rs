//! Derivación local y redactada de identidad federada desde evidencia TLS verificada.
//!
//! Este módulo no vuelve a verificar la cadena: consume exclusivamente el leaf de
//! [`VerifiedPeerEvidence`] que QUINN/rustls ya ligó a la conexión establecida.
//! La evidencia sólo se toma prestada durante la derivación y nunca se conserva en
//! el principal, logs, métricas ni contexto de autorización.

use std::{error::Error, fmt};

use moq_native_ietf::quic::VerifiedPeerEvidence;
use moq_transport::coding::TrackNamespace;
use rustls_pki_types::CertificateDer;
use x509_parser::{
    extensions::GeneralName,
    prelude::{FromDer, X509Certificate},
};

/// Máximo de certificados aceptados en la evidencia verificada de una conexión.
pub const MAX_VERIFIED_CERTIFICATES: usize = 8;
/// Máximo de bytes DER del certificado leaf verificado.
pub const MAX_VERIFIED_LEAF_BYTES: usize = 16 * 1024;
/// Máximo de bytes DER de toda la cadena verificada.
pub const MAX_VERIFIED_CHAIN_BYTES: usize = 64 * 1024;
/// Identificador inicialmente autorizado para publicar desde un gateway.
pub const INITIAL_GATEWAY_NODE_ID: &str = "gateway-dev-1";
/// Namespace exacto inicialmente autorizado para publicar.
pub const INITIAL_PUBLISH_NAMESPACE: &str = "teremoq/live";

const SPIFFE_PREFIX: &str = "spiffe://teremoq.local/";

/// Rol autenticado derivado de la URI SAN, sin política de permisos implícita.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FederatedRole {
    /// Gateway de publicación federado.
    Gateway,
    /// Relay peer federado. La política inicial lo mantiene denegado.
    Relay,
}

/// Únicas operaciones admitidas por la política inicial de publicación.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InitialPublishOperation {
    /// Publicación de un namespace ya solicitado.
    Publish,
    /// Anuncio/registro de un namespace de publicación.
    PublishNamespace,
}

/// Principal mínimo derivado del certificado verificado.
///
/// Su `Debug` no expone el rol ni el identificador completo.
pub struct FederatedPrincipal {
    role: FederatedRole,
    node_id: String,
}

impl FederatedPrincipal {
    /// Rol autenticado derivado de la URI SAN canónica.
    #[must_use]
    pub const fn role(&self) -> FederatedRole {
        self.role
    }

    /// Identificador autenticado. No debe usarse como label ni registrarse completo.
    #[must_use]
    pub fn node_id(&self) -> &str {
        &self.node_id
    }

    /// Aplica la política inicial exacta para `Publish`/`PublishNamespace`.
    #[must_use]
    pub fn authorizes_initial_publish(
        &self,
        _operation: InitialPublishOperation,
        namespace: &TrackNamespace,
    ) -> bool {
        self.role == FederatedRole::Gateway
            && self.node_id == INITIAL_GATEWAY_NODE_ID
            && namespace == &TrackNamespace::from_utf8_path(INITIAL_PUBLISH_NAMESPACE)
    }
}

impl fmt::Debug for FederatedPrincipal {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("FederatedPrincipal")
            .field("identity", &"<redacted>")
            .finish()
    }
}

/// Error tipado y sin material procedente del certificado.
#[derive(Clone, Copy, Eq, PartialEq)]
pub enum FederatedIdentityError {
    /// No se recibió certificado verificado.
    MissingCertificate,
    /// La cadena supera el número de certificados permitido.
    CertificateChainTooLong,
    /// El leaf supera el límite de bytes.
    LeafCertificateTooLarge,
    /// La cadena completa supera el límite de bytes.
    CertificateChainTooLarge,
    /// El leaf no es un certificado DER completo y válido para extracción.
    InvalidCertificate,
    /// No hay una extensión SAN única.
    MissingSubjectAlternativeName,
    /// La extensión SAN contiene una forma no permitida o inválida.
    InvalidSubjectAlternativeName,
    /// La extensión SAN no contiene exactamente una URI de identidad.
    AmbiguousUriIdentity,
    /// La URI de identidad no es canónica o no cumple la gramática autorizada.
    InvalidIdentityUri,
    /// El principal es válido, pero la política inicial lo deniega.
    IdentityNotAuthorized,
}

impl FederatedIdentityError {
    const fn code(self) -> &'static str {
        match self {
            Self::MissingCertificate => "missing_certificate",
            Self::CertificateChainTooLong => "certificate_chain_too_long",
            Self::LeafCertificateTooLarge => "leaf_certificate_too_large",
            Self::CertificateChainTooLarge => "certificate_chain_too_large",
            Self::InvalidCertificate => "invalid_certificate",
            Self::MissingSubjectAlternativeName => "missing_subject_alternative_name",
            Self::InvalidSubjectAlternativeName => "invalid_subject_alternative_name",
            Self::AmbiguousUriIdentity => "ambiguous_uri_identity",
            Self::InvalidIdentityUri => "invalid_identity_uri",
            Self::IdentityNotAuthorized => "identity_not_authorized",
        }
    }
}

impl fmt::Debug for FederatedIdentityError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.code())
    }
}

impl fmt::Display for FederatedIdentityError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.code())
    }
}

impl Error for FederatedIdentityError {}

/// Deriva el principal inicial autorizado desde evidencia ligada a la conexión.
///
/// Los límites se comprueban antes de parsear. Sólo se parsea el leaf ya
/// verificado y el resultado no conserva ningún byte DER.
///
/// # Errors
///
/// Devuelve un error redactado si faltan certificados, se excede un límite, el
/// leaf/SAN/URI no es canónico o la política inicial deniega el principal.
pub fn authenticate_verified_peer(
    peer: &VerifiedPeerEvidence,
) -> Result<FederatedPrincipal, FederatedIdentityError> {
    authenticate_verified_chain(peer.certificates())
}

fn authenticate_verified_chain(
    certificates: &[CertificateDer<'_>],
) -> Result<FederatedPrincipal, FederatedIdentityError> {
    validate_chain_limits(certificates)?;
    let principal = parse_leaf_identity(certificates[0].as_ref())?;
    if principal.role != FederatedRole::Gateway || principal.node_id != INITIAL_GATEWAY_NODE_ID {
        return Err(FederatedIdentityError::IdentityNotAuthorized);
    }
    Ok(principal)
}

fn validate_chain_limits(
    certificates: &[CertificateDer<'_>],
) -> Result<(), FederatedIdentityError> {
    let Some(leaf) = certificates.first() else {
        return Err(FederatedIdentityError::MissingCertificate);
    };
    if certificates.len() > MAX_VERIFIED_CERTIFICATES {
        return Err(FederatedIdentityError::CertificateChainTooLong);
    }
    if leaf.as_ref().len() > MAX_VERIFIED_LEAF_BYTES {
        return Err(FederatedIdentityError::LeafCertificateTooLarge);
    }

    let total = certificates.iter().try_fold(0_usize, |total, certificate| {
        total.checked_add(certificate.as_ref().len())
    });
    if total.is_none_or(|total| total > MAX_VERIFIED_CHAIN_BYTES) {
        return Err(FederatedIdentityError::CertificateChainTooLarge);
    }
    Ok(())
}

fn parse_leaf_identity(der: &[u8]) -> Result<FederatedPrincipal, FederatedIdentityError> {
    let (remainder, certificate) =
        X509Certificate::from_der(der).map_err(|_| FederatedIdentityError::InvalidCertificate)?;
    if !remainder.is_empty() {
        return Err(FederatedIdentityError::InvalidCertificate);
    }
    let san = certificate
        .subject_alternative_name()
        .map_err(|_| FederatedIdentityError::InvalidSubjectAlternativeName)?
        .ok_or(FederatedIdentityError::MissingSubjectAlternativeName)?;

    let mut uri = None;
    let mut other_names = Vec::new();
    for name in &san.value.general_names {
        match name {
            GeneralName::URI(value) => {
                if uri.replace(*value).is_some() {
                    return Err(FederatedIdentityError::AmbiguousUriIdentity);
                }
            }
            GeneralName::Invalid(_, _) => {
                return Err(FederatedIdentityError::InvalidSubjectAlternativeName);
            }
            other => other_names.push(other),
        }
    }
    let uri = uri.ok_or(FederatedIdentityError::AmbiguousUriIdentity)?;
    let principal = parse_identity_uri(uri)?;

    let additional_names_allowed = match principal.role {
        FederatedRole::Gateway => other_names.is_empty(),
        FederatedRole::Relay => other_names
            .iter()
            .all(|name| matches!(name, GeneralName::DNSName(_) | GeneralName::IPAddress(_))),
    };
    if !additional_names_allowed {
        return Err(FederatedIdentityError::InvalidSubjectAlternativeName);
    }
    Ok(principal)
}

fn parse_identity_uri(uri: &str) -> Result<FederatedPrincipal, FederatedIdentityError> {
    if !uri.is_ascii()
        || uri.bytes().any(|byte| byte.is_ascii_control())
        || uri
            .bytes()
            .any(|byte| matches!(byte, b'%' | b'?' | b'#' | b'@'))
    {
        return Err(FederatedIdentityError::InvalidIdentityUri);
    }
    let path = uri
        .strip_prefix(SPIFFE_PREFIX)
        .ok_or(FederatedIdentityError::InvalidIdentityUri)?;
    let (role, node_id) = path
        .split_once('/')
        .ok_or(FederatedIdentityError::InvalidIdentityUri)?;
    if node_id.contains('/')
        || node_id.is_empty()
        || node_id.len() > 64
        || matches!(node_id, "." | "..")
        || !node_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        return Err(FederatedIdentityError::InvalidIdentityUri);
    }
    let role = match role {
        "gateway" => FederatedRole::Gateway,
        "relay" => FederatedRole::Relay,
        _ => return Err(FederatedIdentityError::InvalidIdentityUri),
    };
    let reconstructed = format!(
        "{SPIFFE_PREFIX}{}/{}",
        match role {
            FederatedRole::Gateway => "gateway",
            FederatedRole::Relay => "relay",
        },
        node_id
    );
    if reconstructed != uri {
        return Err(FederatedIdentityError::InvalidIdentityUri);
    }
    Ok(FederatedPrincipal {
        role,
        node_id: node_id.to_owned(),
    })
}

#[cfg(test)]
mod tests {
    use rcgen::{CertificateParams, KeyPair, SanType, string::Ia5String};

    use super::*;

    const GATEWAY_URI: &str = "spiffe://teremoq.local/gateway/gateway-dev-1";

    fn certificate(sans: Vec<SanType>) -> anyhow::Result<CertificateDer<'static>> {
        let key = KeyPair::generate()?;
        let mut params = CertificateParams::default();
        params.subject_alt_names = sans;
        Ok(params.self_signed(&key)?.der().clone())
    }

    fn uri(value: &str) -> anyhow::Result<SanType> {
        Ok(SanType::URI(Ia5String::try_from(value)?))
    }

    fn rejection(
        result: Result<FederatedPrincipal, FederatedIdentityError>,
    ) -> anyhow::Result<FederatedIdentityError> {
        result
            .err()
            .ok_or_else(|| anyhow::anyhow!("identity was unexpectedly accepted"))
    }

    #[test]
    fn valid_gateway_is_minimal_and_redacted() -> anyhow::Result<()> {
        let leaf = certificate(vec![uri(GATEWAY_URI)?])?;
        let principal = authenticate_verified_chain(&[leaf])?;
        assert_eq!(principal.role(), FederatedRole::Gateway);
        assert_eq!(principal.node_id(), INITIAL_GATEWAY_NODE_ID);
        assert!(principal.authorizes_initial_publish(
            InitialPublishOperation::Publish,
            &TrackNamespace::from_utf8_path(INITIAL_PUBLISH_NAMESPACE)
        ));
        assert!(principal.authorizes_initial_publish(
            InitialPublishOperation::PublishNamespace,
            &TrackNamespace::from_utf8_path(INITIAL_PUBLISH_NAMESPACE)
        ));
        assert!(!principal.authorizes_initial_publish(
            InitialPublishOperation::Publish,
            &TrackNamespace::from_utf8_path("teremoq/other")
        ));
        assert_eq!(
            format!("{principal:?}"),
            "FederatedPrincipal { identity: \"<redacted>\" }"
        );
        Ok(())
    }

    #[test]
    fn chain_limits_fail_before_certificate_parsing() -> anyhow::Result<()> {
        let valid = certificate(vec![uri(GATEWAY_URI)?])?;
        let nine = vec![valid.clone(); MAX_VERIFIED_CERTIFICATES + 1];
        assert_eq!(
            rejection(authenticate_verified_chain(&nine))?,
            FederatedIdentityError::CertificateChainTooLong
        );
        assert_eq!(
            rejection(authenticate_verified_chain(&[CertificateDer::from(vec![
                0_u8;
                MAX_VERIFIED_LEAF_BYTES + 1
            ])]))?,
            FederatedIdentityError::LeafCertificateTooLarge
        );
        let mut oversized_total = vec![valid];
        oversized_total.extend(
            (0..MAX_VERIFIED_CERTIFICATES - 1).map(|_| CertificateDer::from(vec![0_u8; 10 * 1024])),
        );
        assert_eq!(
            rejection(authenticate_verified_chain(&oversized_total))?,
            FederatedIdentityError::CertificateChainTooLarge
        );
        Ok(())
    }

    #[test]
    fn invalid_or_ambiguous_san_is_denied() -> anyhow::Result<()> {
        assert_eq!(
            rejection(authenticate_verified_chain(&[]))?,
            FederatedIdentityError::MissingCertificate
        );
        assert_eq!(
            rejection(authenticate_verified_chain(&[CertificateDer::from(
                vec![0_u8; 8]
            )]))?,
            FederatedIdentityError::InvalidCertificate
        );
        assert_eq!(
            rejection(authenticate_verified_chain(&[certificate(Vec::new())?]))?,
            FederatedIdentityError::MissingSubjectAlternativeName
        );
        assert_eq!(
            rejection(authenticate_verified_chain(&[certificate(vec![
                uri(GATEWAY_URI)?,
                uri(GATEWAY_URI)?
            ])?]))?,
            FederatedIdentityError::AmbiguousUriIdentity
        );
        let dns = SanType::DnsName(Ia5String::try_from("gateway.test")?);
        assert_eq!(
            rejection(authenticate_verified_chain(&[certificate(vec![
                uri(GATEWAY_URI)?,
                dns
            ])?]))?,
            FederatedIdentityError::InvalidSubjectAlternativeName
        );
        Ok(())
    }

    #[test]
    fn initial_policy_is_default_deny() -> anyhow::Result<()> {
        for identity in [
            "spiffe://teremoq.local/gateway/gateway-dev-2",
            "spiffe://teremoq.local/relay/relay-dev-1",
        ] {
            let leaf = certificate(vec![uri(identity)?])?;
            assert_eq!(
                rejection(authenticate_verified_chain(&[leaf]))?,
                FederatedIdentityError::IdentityNotAuthorized
            );
        }
        Ok(())
    }

    #[test]
    fn uri_grammar_is_exact_and_canonical() {
        let invalid = [
            "SPIFFE://teremoq.local/gateway/gateway-dev-1",
            "spiffe://TEREMOQ.local/gateway/gateway-dev-1",
            "spiffe://teremoq.local:443/gateway/gateway-dev-1",
            "spiffe://teremoq.local/gateway/gateway-dev-1?role=publisher",
            "spiffe://teremoq.local/gateway/gateway-dev-1#fragment",
            "spiffe://teremoq.local/gateway/gateway%2Ddev%2D1",
            "spiffe://user@teremoq.local/gateway/gateway-dev-1",
            "spiffe://teremoq.local/gateway/.",
            "spiffe://teremoq.local/gateway/..",
            "spiffe://teremoq.local/gateway/trailing/segment",
            "spiffe://teremoq.local/gateway/gateway dev 1",
            "spiffe://teremoq.local/gateway/gatéway",
            "spiffe://teremoq.local/admin/gateway-dev-1",
            "spiffe://other.local/gateway/gateway-dev-1",
        ];
        for identity in invalid {
            assert!(
                matches!(
                    parse_identity_uri(identity),
                    Err(FederatedIdentityError::InvalidIdentityUri)
                ),
                "invalid identity URI was accepted"
            );
        }
        let oversized = format!("{SPIFFE_PREFIX}gateway/{}", "a".repeat(65));
        assert!(matches!(
            parse_identity_uri(&oversized),
            Err(FederatedIdentityError::InvalidIdentityUri)
        ));
    }

    #[test]
    fn errors_never_include_parser_or_identity_material() {
        let canary = "gateway-dev-1";
        for error in [
            FederatedIdentityError::MissingCertificate,
            FederatedIdentityError::CertificateChainTooLong,
            FederatedIdentityError::LeafCertificateTooLarge,
            FederatedIdentityError::CertificateChainTooLarge,
            FederatedIdentityError::InvalidCertificate,
            FederatedIdentityError::MissingSubjectAlternativeName,
            FederatedIdentityError::InvalidSubjectAlternativeName,
            FederatedIdentityError::AmbiguousUriIdentity,
            FederatedIdentityError::InvalidIdentityUri,
            FederatedIdentityError::IdentityNotAuthorized,
        ] {
            assert!(!format!("{error:?}").contains(canary));
            assert!(!error.to_string().contains(canary));
        }
    }
}
