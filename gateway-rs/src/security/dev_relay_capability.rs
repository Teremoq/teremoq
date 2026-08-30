//! Capacidad efímera para publicar en el relay browser durante el laboratorio LAN.
//!
//! El proxy UDP conserva QUIC, pero oculta al relay el origen de red real. Este
//! módulo carga una capacidad run-scoped desde un fichero privado y permite
//! convertir el path local `/publish` en un path no adivinable. No sustituye
//! autenticación mTLS ni debe reutilizarse fuera del laboratorio explícito.

use std::{
    fmt::{Debug, Display, Formatter},
    fs::{self, File},
    io::Read,
    path::Path,
};

use url::Url;

/// Variable compartida por el Gateway local y `dev_moq_relay` en el laboratorio LAN.
pub const DEV_RELAY_PUBLISH_CAPABILITY_ENV: &str = "TEREMOQ_DEV_RELAY_PUBLISH_CAPABILITY_FILE";

const CAPABILITY_HEX_BYTES: usize = 64;
const MAX_CAPABILITY_FILE_BYTES: u64 = 65;
const PUBLISH_PATH: &str = "/publish";
const PUBLISH_PATH_PREFIX: &str = "/publish/";

/// Capacidad opaca cargada desde el runtime privado del laboratorio.
///
/// Su representación `Debug` está completamente redactada. El fichero debe
/// contener 32 bytes de entropía codificados como 64 caracteres hexadecimales
/// minúsculos, con un único LF final opcional.
pub struct DevRelayPublishCapability {
    encoded: Box<str>,
}

impl DevRelayPublishCapability {
    /// Carga y valida una capacidad desde un fichero absoluto, regular, no
    /// symlink y con permisos Unix exactamente `0600`.
    ///
    /// # Errors
    ///
    /// Devuelve un error redactado si el path, metadatos, permisos o contenido
    /// no cumplen el contrato fail-closed.
    pub fn load(path: &Path) -> Result<Self, DevRelayPublishCapabilityError> {
        if !path.is_absolute() {
            return Err(DevRelayPublishCapabilityError::NotAbsolute);
        }

        let path_metadata =
            fs::symlink_metadata(path).map_err(|_| DevRelayPublishCapabilityError::Unavailable)?;
        if path_metadata.file_type().is_symlink() || !path_metadata.is_file() {
            return Err(DevRelayPublishCapabilityError::NotRegular);
        }

        let file = File::open(path).map_err(|_| DevRelayPublishCapabilityError::Unavailable)?;
        let opened_metadata = file
            .metadata()
            .map_err(|_| DevRelayPublishCapabilityError::Unavailable)?;
        validate_opened_file(path, &path_metadata, &opened_metadata)?;

        let mut contents = Vec::with_capacity(CAPABILITY_HEX_BYTES + 1);
        file.take(MAX_CAPABILITY_FILE_BYTES + 1)
            .read_to_end(&mut contents)
            .map_err(|_| DevRelayPublishCapabilityError::Unavailable)?;
        if contents.last() == Some(&b'\n') {
            contents.pop();
        }
        if contents.len() != CAPABILITY_HEX_BYTES
            || !contents
                .iter()
                .all(|byte| byte.is_ascii_digit() || matches!(*byte, b'a'..=b'f'))
        {
            return Err(DevRelayPublishCapabilityError::InvalidContents);
        }

        let encoded = String::from_utf8(contents)
            .map_err(|_| DevRelayPublishCapabilityError::InvalidContents)?;
        Ok(Self {
            encoded: encoded.into_boxed_str(),
        })
    }

    /// Comprueba el path solicitado sin copiar ni exponer la capacidad.
    #[must_use]
    pub fn authorizes_connection_path(&self, connection_path: Option<&str>) -> bool {
        let Some(candidate) =
            connection_path.and_then(|path| path.strip_prefix(PUBLISH_PATH_PREFIX))
        else {
            return false;
        };
        fixed_length_eq(candidate.as_bytes(), self.encoded.as_bytes())
    }

    /// Añade la capacidad a una URL local `/publish` ya validada.
    ///
    /// # Errors
    ///
    /// Rechaza cualquier URL que no sea el endpoint WebTransport loopback
    /// exacto del laboratorio browser.
    pub fn apply_to_local_publish_url(
        &self,
        relay_url: &mut Url,
    ) -> Result<(), DevRelayPublishCapabilityError> {
        let loopback_host = relay_url.host_str().is_some_and(|host| {
            host == "localhost"
                || host
                    .parse::<std::net::IpAddr>()
                    .is_ok_and(|address| address.is_loopback())
        });
        if relay_url.scheme() != "https"
            || !loopback_host
            || relay_url.port_or_known_default() != Some(4433)
            || relay_url.path() != PUBLISH_PATH
            || relay_url.query().is_some()
            || relay_url.fragment().is_some()
            || !relay_url.username().is_empty()
            || relay_url.password().is_some()
        {
            return Err(DevRelayPublishCapabilityError::InvalidRelayUrl);
        }
        relay_url.set_path(&format!("{PUBLISH_PATH_PREFIX}{}", self.encoded));
        Ok(())
    }
}

/// Reconoce únicamente la forma canónica del path con capacidad para que el
/// adaptador pueda omitir errores upstream potencialmente verbosos.
#[must_use]
pub(crate) fn is_capability_publish_path(connection_path: &str) -> bool {
    connection_path
        .strip_prefix(PUBLISH_PATH_PREFIX)
        .is_some_and(|candidate| {
            candidate.len() == CAPABILITY_HEX_BYTES
                && candidate
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
        })
}

impl Debug for DevRelayPublishCapability {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("DevRelayPublishCapability")
            .field("configured", &true)
            .finish_non_exhaustive()
    }
}

/// Fallos redactados al cargar o aplicar la capacidad LAN.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DevRelayPublishCapabilityError {
    /// El path de configuración no es absoluto.
    NotAbsolute,
    /// El fichero no está disponible.
    Unavailable,
    /// El path no identifica un fichero regular estable y no-symlink.
    NotRegular,
    /// Los permisos no son exactamente `0600`.
    InsecurePermissions,
    /// El path cambió mientras se cargaba.
    ChangedDuringRead,
    /// El contenido no es una capacidad hexadecimal canónica de 256 bits.
    InvalidContents,
    /// La URL no es el endpoint loopback `/publish` del laboratorio.
    InvalidRelayUrl,
    /// La plataforma no permite comprobar el contrato `0600` requerido.
    UnsupportedPlatform,
}

impl Display for DevRelayPublishCapabilityError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        let reason = match self {
            Self::NotAbsolute => "publish capability path must be absolute",
            Self::Unavailable => "publish capability file is unavailable",
            Self::NotRegular => "publish capability must be a stable regular non-symlink file",
            Self::InsecurePermissions => "publish capability file must have mode 0600",
            Self::ChangedDuringRead => "publish capability file changed while being loaded",
            Self::InvalidContents => "publish capability file has an invalid canonical format",
            Self::InvalidRelayUrl => {
                "publish capability requires the local WebTransport /publish endpoint"
            }
            Self::UnsupportedPlatform => {
                "publish capability permission checks require an Unix platform"
            }
        };
        formatter.write_str(reason)
    }
}

impl std::error::Error for DevRelayPublishCapabilityError {}

#[cfg(unix)]
fn validate_opened_file(
    path: &Path,
    path_metadata: &fs::Metadata,
    opened_metadata: &fs::Metadata,
) -> Result<(), DevRelayPublishCapabilityError> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    if !opened_metadata.is_file() {
        return Err(DevRelayPublishCapabilityError::NotRegular);
    }
    if opened_metadata.permissions().mode() & 0o7777 != 0o600 {
        return Err(DevRelayPublishCapabilityError::InsecurePermissions);
    }
    let after_metadata = fs::symlink_metadata(path)
        .map_err(|_| DevRelayPublishCapabilityError::ChangedDuringRead)?;
    if after_metadata.file_type().is_symlink()
        || !after_metadata.is_file()
        || path_metadata.dev() != opened_metadata.dev()
        || path_metadata.ino() != opened_metadata.ino()
        || after_metadata.dev() != opened_metadata.dev()
        || after_metadata.ino() != opened_metadata.ino()
    {
        return Err(DevRelayPublishCapabilityError::ChangedDuringRead);
    }
    Ok(())
}

#[cfg(not(unix))]
fn validate_opened_file(
    _path: &Path,
    _path_metadata: &fs::Metadata,
    _opened_metadata: &fs::Metadata,
) -> Result<(), DevRelayPublishCapabilityError> {
    Err(DevRelayPublishCapabilityError::UnsupportedPlatform)
}

fn fixed_length_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != CAPABILITY_HEX_BYTES || right.len() != CAPABILITY_HEX_BYTES {
        return false;
    }
    left.iter()
        .zip(right)
        .fold(0_u8, |difference, (left, right)| {
            difference | (left ^ right)
        })
        == 0
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        path::{Path, PathBuf},
        sync::atomic::{AtomicU64, Ordering},
    };

    use url::Url;

    use super::{
        DevRelayPublishCapability, DevRelayPublishCapabilityError, is_capability_publish_path,
    };

    const TEST_CAPABILITY: &str =
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    static TEST_SEQUENCE: AtomicU64 = AtomicU64::new(0);

    struct TestFile(PathBuf);

    impl TestFile {
        #[cfg(unix)]
        fn capability(label: &str, contents: &[u8], mode: u32) -> anyhow::Result<Self> {
            use std::os::unix::fs::PermissionsExt;

            let sequence = TEST_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let root = std::env::temp_dir().join(format!(
                "teremoq-dev-capability-{label}-{}-{sequence}",
                std::process::id()
            ));
            fs::create_dir(&root)?;
            let path = root.join("publish-capability");
            fs::write(&path, contents)?;
            fs::set_permissions(&path, fs::Permissions::from_mode(mode))?;
            Ok(Self(path))
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TestFile {
        fn drop(&mut self) {
            if let Some(root) = self.0.parent()
                && root.exists()
            {
                let _result = fs::remove_dir_all(root);
            }
        }
    }

    #[cfg(unix)]
    #[test]
    fn loads_private_canonical_capability_and_redacts_debug() -> anyhow::Result<()> {
        let file = TestFile::capability("valid", format!("{TEST_CAPABILITY}\n").as_bytes(), 0o600)?;
        let capability = DevRelayPublishCapability::load(file.path())?;

        assert!(
            capability.authorizes_connection_path(Some(&format!("/publish/{TEST_CAPABILITY}")))
        );
        assert!(!capability.authorizes_connection_path(Some("/publish")));
        assert!(!capability.authorizes_connection_path(Some(
            "/publish/ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        )));
        let debug = format!("{capability:?}");
        assert!(debug.contains("configured"));
        assert!(!debug.contains(TEST_CAPABILITY));
        assert!(is_capability_publish_path(&format!(
            "/publish/{TEST_CAPABILITY}"
        )));
        assert!(!is_capability_publish_path("/publish"));
        assert!(!is_capability_publish_path(
            "/publish/ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        ));
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn rejects_permissions_format_and_symlinks() -> anyhow::Result<()> {
        use std::os::unix::fs::symlink;

        let permissive = TestFile::capability("mode", TEST_CAPABILITY.as_bytes(), 0o640)?;
        assert_eq!(
            DevRelayPublishCapability::load(permissive.path()).err(),
            Some(DevRelayPublishCapabilityError::InsecurePermissions)
        );

        for (label, contents) in [
            ("short", b"0123".as_slice()),
            (
                "uppercase",
                b"0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef".as_slice(),
            ),
            (
                "extra-newline",
                b"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n\n".as_slice(),
            ),
        ] {
            let invalid = TestFile::capability(label, contents, 0o600)?;
            assert_eq!(
                DevRelayPublishCapability::load(invalid.path()).err(),
                Some(DevRelayPublishCapabilityError::InvalidContents)
            );
        }

        let target = TestFile::capability("target", TEST_CAPABILITY.as_bytes(), 0o600)?;
        let link = target.path().with_file_name("publish-capability-link");
        symlink(target.path(), &link)?;
        assert_eq!(
            DevRelayPublishCapability::load(&link).err(),
            Some(DevRelayPublishCapabilityError::NotRegular)
        );
        fs::remove_file(link)?;
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn applies_only_to_exact_loopback_browser_publish_url() -> anyhow::Result<()> {
        let file = TestFile::capability("url", TEST_CAPABILITY.as_bytes(), 0o600)?;
        let capability = DevRelayPublishCapability::load(file.path())?;
        for raw in [
            "https://192.168.1.10:4433/publish",
            "https://127.0.0.1:4443/publish",
            "moqt://127.0.0.1:4433/publish",
            "https://127.0.0.1:4433/watch",
        ] {
            let mut url = Url::parse(raw)?;
            assert_eq!(
                capability.apply_to_local_publish_url(&mut url),
                Err(DevRelayPublishCapabilityError::InvalidRelayUrl)
            );
        }

        let mut url = Url::parse("https://127.0.0.1:4433/publish")?;
        capability.apply_to_local_publish_url(&mut url)?;
        assert_eq!(url.scheme(), "https");
        assert_eq!(url.host_str(), Some("127.0.0.1"));
        assert_eq!(url.port(), Some(4433));
        assert!(capability.authorizes_connection_path(Some(url.path())));
        Ok(())
    }
}
