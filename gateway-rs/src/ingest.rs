//! Frontera de ingesta SRT.

use std::{net::SocketAddr, sync::Arc};

use bytes::Bytes;

use crate::{BoxFuture, error::GatewayResult};

/// Payload entregado por un backend SRT después de procesar el protocolo.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct IngestPacket {
    /// Bytes del payload SRT; normalmente contiene paquetes MPEG-TS.
    pub payload: Bytes,
    /// Identidad opaca de la conexión que produjo el payload.
    pub connection_id: Arc<str>,
    /// Dirección UDP del Caller que produjo el payload.
    pub peer: SocketAddr,
    /// Stream ID negociado por SRT, cuando exista.
    pub stream_id: Arc<str>,
    /// Número de mensaje preservado por SRT.
    pub message_number: u32,
    /// Timestamp relativo transportado por SRT.
    pub srt_timestamp: u32,
    /// Instante monotónico de recepción dentro del Gateway.
    pub received_at: tokio::time::Instant,
}

/// Adaptador sustituible de una implementación SRT real.
pub trait SrtIngress: Send {
    /// Espera el siguiente payload ya procesado por SRT.
    ///
    /// `Ok(None)` representa un cierre ordenado del adaptador.
    fn receive(&mut self) -> BoxFuture<'_, GatewayResult<Option<IngestPacket>>>;
}
