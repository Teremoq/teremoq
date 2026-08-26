//! Error compartido por las fronteras de componentes.

use std::fmt::{Display, Formatter};

/// Error dinámico, thread-safe y con causa preservada.
pub type BoxError = Box<dyn std::error::Error + Send + Sync + 'static>;

/// Resultado común de los puertos del Gateway.
pub type GatewayResult<T> = Result<T, BoxError>;

/// Error con contexto y causa opcional que puede cruzar fronteras async.
#[derive(Debug)]
pub struct GatewayError {
    message: String,
    source: Option<BoxError>,
}

impl GatewayError {
    /// Construye un error sin causa subyacente.
    #[must_use]
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            source: None,
        }
    }

    /// Añade contexto conservando la causa original.
    #[must_use]
    pub fn with_source(message: impl Into<String>, source: BoxError) -> Self {
        Self {
            message: message.into(),
            source: Some(source),
        }
    }

    /// Convierte el error al tipo dinámico compartido.
    #[must_use]
    pub fn boxed(self) -> BoxError {
        Box::new(self)
    }
}

impl Display for GatewayError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for GatewayError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        self.source
            .as_deref()
            .map(|source| source as &(dyn std::error::Error + 'static))
    }
}
