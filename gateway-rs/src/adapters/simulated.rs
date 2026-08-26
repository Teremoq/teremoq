//! Ingesta inerte para probar el lifecycle sin fingir protocolos reales.

use tokio::sync::mpsc;

use crate::{
    BoxFuture,
    error::GatewayResult,
    ingest::{IngestPacket, SrtIngress},
};

const SIMULATED_INGRESS_CAPACITY: usize = 1;

/// Ingesta inerte respaldada por un canal acotado que permanece abierto.
pub struct SimulatedSrtIngress {
    _sender_guard: mpsc::Sender<IngestPacket>,
    receiver: mpsc::Receiver<IngestPacket>,
}

impl SimulatedSrtIngress {
    /// Crea una ingesta que no produce tráfico y solo termina por cancelación.
    #[must_use]
    pub fn idle() -> Self {
        let (sender, receiver) = mpsc::channel(SIMULATED_INGRESS_CAPACITY);
        Self {
            _sender_guard: sender,
            receiver,
        }
    }
}

impl SrtIngress for SimulatedSrtIngress {
    fn receive(&mut self) -> BoxFuture<'_, GatewayResult<Option<IngestPacket>>> {
        Box::pin(async { Ok(self.receiver.recv().await) })
    }
}
