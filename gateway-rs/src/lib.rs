//! Gateway Edge de Teremoq y sus contratos arquitectónicos.
//!
//! El crate contiene ingesta SRT real detrás de una frontera sustituible. El
//! demultiplexado, scheduling y publicación `MoQT` draft-16 ya son reales.

pub mod adapters;
pub mod cmsf;
pub mod config;
pub mod error;
pub mod gateway;
pub mod ingest;
pub mod lifecycle;
pub mod media;
pub mod observability;
pub mod routing;
pub mod scheduler;
pub mod security;
pub mod supervisor;

/// Future con ownership dinámico utilizada en los puertos asíncronos.
///
/// Mantener este alias en el núcleo evita acoplar los contratos a una macro de
/// traits async o al runtime concreto empleado por un adaptador.
pub type BoxFuture<'a, T> = std::pin::Pin<Box<dyn std::future::Future<Output = T> + Send + 'a>>;
