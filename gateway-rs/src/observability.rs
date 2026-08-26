//! Contrato inicial de observabilidad JSON.

use std::{net::SocketAddr, sync::Arc};

use shiguredo_srt::ReceiverStats;
use tracing_subscriber::EnvFilter;

use crate::{
    error::{GatewayError, GatewayResult},
    scheduler::ScheduledObject,
};

/// Versión estable del esquema de eventos del Gateway.
pub const SCHEMA_VERSION: u8 = 1;
/// Nombre estable del servicio en observabilidad.
pub const SERVICE_NAME: &str = "gateway-rs";

/// Campos estables de un descarte de Object por suscriptor.
pub struct ObjectDropEvent<'a> {
    /// Conexión SRT de origen.
    pub connection_id: &'a str,
    /// Sesión de distribución afectada.
    pub subscriber_id: &'a str,
    /// Track lógico.
    pub track: u8,
    /// Prioridad estable `0..=2`.
    pub priority: u8,
    /// Group propietario.
    pub group_id: u64,
    /// Object dentro del Group.
    pub object_id: u64,
    /// Residencia monotónica observada.
    pub age_ms: u64,
    /// Deadline aplicable.
    pub deadline_ms: u64,
    /// Objects restantes en la cola aislada.
    pub queue_objects: usize,
    /// Bytes restantes en la cola aislada.
    pub queue_bytes: usize,
    /// Razón enumerable del descarte.
    pub reason: &'static str,
}

/// Campos de una expulsión causada por contenido crítico sin progreso.
pub struct CriticalEvictionEvent<'a> {
    /// Conexión SRT de origen.
    pub connection_id: &'a str,
    /// Sesión de distribución expulsada.
    pub subscriber_id: &'a str,
    /// Track crítico afectado.
    pub track: u8,
    /// Group propietario.
    pub group_id: u64,
    /// Object que dispara la decisión.
    pub object_id: u64,
    /// Residencia monotónica observada.
    pub age_ms: u64,
    /// Deadline operativo.
    pub deadline_ms: u64,
    /// Objects restantes al cerrar la cola.
    pub queue_objects: usize,
    /// Bytes restantes al cerrar la cola.
    pub queue_bytes: usize,
    /// Razón enumerable de expulsión.
    pub reason: &'static str,
}

/// Contexto común que garantiza los campos obligatorios de cada evento.
#[derive(Clone, Debug)]
pub struct EventLogger {
    instance_id: Arc<str>,
}

impl EventLogger {
    /// Crea un logger para una instancia ya validada.
    #[must_use]
    pub fn new(instance_id: String) -> Self {
        Self {
            instance_id: Arc::from(instance_id),
        }
    }

    /// Registra el inicio del proceso y su deadline de apagado.
    pub fn gateway_started(&self, shutdown_timeout_ms: u64) {
        tracing::info!(
            schema_version = SCHEMA_VERSION,
            event = "gateway_started",
            service = SERVICE_NAME,
            instance_id = %self.instance_id,
            shutdown_timeout_ms
        );
    }

    /// Registra el inicio de una task crítica.
    pub fn task_started(&self, task: &'static str) {
        tracing::info!(
            schema_version = SCHEMA_VERSION,
            event = "critical_task_started",
            service = SERVICE_NAME,
            instance_id = %self.instance_id,
            task
        );
    }

    /// Registra la solicitud que inicia el cierre ordenado.
    pub fn shutdown_requested(&self, reason: &'static str) {
        tracing::info!(
            schema_version = SCHEMA_VERSION,
            event = "shutdown_requested",
            service = SERVICE_NAME,
            instance_id = %self.instance_id,
            reason
        );
    }

    /// Registra la parada ordenada de una task.
    pub fn task_stopped(&self, task: &'static str) {
        tracing::info!(
            schema_version = SCHEMA_VERSION,
            event = "critical_task_stopped",
            service = SERVICE_NAME,
            instance_id = %self.instance_id,
            task
        );
    }

    /// Registra un fallo que obliga a cancelar el proceso completo.
    pub fn critical_task_failed(&self, task: &'static str, error: &dyn std::error::Error) {
        tracing::error!(
            schema_version = SCHEMA_VERSION,
            event = "critical_task_failed",
            service = SERVICE_NAME,
            instance_id = %self.instance_id,
            task,
            error = %error
        );
    }

    /// Registra que una task no respetó el deadline de apagado.
    pub fn shutdown_deadline_exceeded(&self, pending_tasks: usize, deadline_ms: u64) {
        tracing::error!(
            schema_version = SCHEMA_VERSION,
            event = "shutdown_deadline_exceeded",
            service = SERVICE_NAME,
            instance_id = %self.instance_id,
            pending_tasks,
            deadline_ms
        );
    }

    /// Registra que todos los recursos supervisados terminaron.
    pub fn gateway_stopped(&self) {
        tracing::info!(
            schema_version = SCHEMA_VERSION,
            event = "gateway_stopped",
            service = SERVICE_NAME,
            instance_id = %self.instance_id
        );
    }

    /// Registra el socket SRT real sin exponer secretos.
    pub fn srt_listener_bound(
        &self,
        bind_addr: SocketAddr,
        max_sessions: usize,
        encryption_enabled: bool,
    ) {
        tracing::info!(
            schema_version = SCHEMA_VERSION,
            event = "srt_listener_bound",
            service = SERVICE_NAME,
            instance_id = %self.instance_id,
            bind_addr = %bind_addr,
            max_sessions,
            encryption_enabled
        );
    }

    /// Registra una conexión autorizada usando una etiqueta segura.
    pub fn srt_connection_opened(
        &self,
        connection_id: &str,
        peer: SocketAddr,
        source: &str,
        stream_id_length: usize,
        encryption_enabled: bool,
    ) {
        tracing::info!(
            schema_version = SCHEMA_VERSION,
            event = "srt_connection_opened",
            service = SERVICE_NAME,
            instance_id = %self.instance_id,
            connection_id,
            peer = %peer,
            source,
            stream_id_length,
            encryption_enabled
        );
    }

    /// Registra un intento previo al handshake que no se admite.
    pub fn srt_connection_rejected(
        &self,
        peer: SocketAddr,
        reason: &'static str,
        datagram_bytes: usize,
    ) {
        tracing::warn!(
            schema_version = SCHEMA_VERSION,
            event = "srt_connection_rejected",
            service = SERVICE_NAME,
            instance_id = %self.instance_id,
            peer = %peer,
            reason,
            datagram_bytes
        );
    }

    /// Registra una autorización fallida sin revelar el Stream ID recibido.
    pub fn srt_stream_id_rejected(
        &self,
        connection_id: &str,
        peer: SocketAddr,
        reason: &'static str,
        stream_id_length: usize,
    ) {
        tracing::warn!(
            schema_version = SCHEMA_VERSION,
            event = "srt_stream_id_rejected",
            service = SERVICE_NAME,
            instance_id = %self.instance_id,
            connection_id,
            peer = %peer,
            reason,
            stream_id_length
        );
    }

    /// Registra el cierre aislado de una sesión.
    pub fn srt_connection_closed(
        &self,
        connection_id: &str,
        peer: SocketAddr,
        source: Option<&str>,
        reason: &str,
    ) {
        let source = source.map_or("unknown", std::convert::identity);
        tracing::info!(
            schema_version = SCHEMA_VERSION,
            event = "srt_connection_closed",
            service = SERVICE_NAME,
            instance_id = %self.instance_id,
            connection_id,
            peer = %peer,
            source,
            reason
        );
    }

    /// Registra un error de protocolo limitado a una sesión.
    pub fn srt_session_error(
        &self,
        connection_id: &str,
        peer: SocketAddr,
        reason: &'static str,
        error: &dyn std::error::Error,
    ) {
        tracing::warn!(
            schema_version = SCHEMA_VERSION,
            event = "srt_session_error",
            service = SERVICE_NAME,
            instance_id = %self.instance_id,
            connection_id,
            peer = %peer,
            reason,
            error = %error
        );
    }

    /// Registra expulsión por límites o backpressure internos.
    pub fn srt_session_evicted(&self, connection_id: &str, peer: SocketAddr, reason: &'static str) {
        tracing::warn!(
            schema_version = SCHEMA_VERSION,
            event = "srt_session_evicted",
            service = SERVICE_NAME,
            instance_id = %self.instance_id,
            connection_id,
            peer = %peer,
            reason
        );
    }

    /// Registra estadísticas agregadas por el backend SRT.
    pub fn srt_receiver_stats(
        &self,
        connection_id: &str,
        peer: SocketAddr,
        source: &str,
        stats: ReceiverStats,
    ) {
        tracing::info!(
            schema_version = SCHEMA_VERSION,
            event = "srt_receiver_stats",
            service = SERVICE_NAME,
            instance_id = %self.instance_id,
            connection_id,
            peer = %peer,
            source,
            packets_in_buffer = stats.packets_in_buffer,
            packets_in_loss_list = stats.packets_in_loss_list,
            total_received = stats.total_received,
            total_lost = stats.total_lost,
            total_duplicates = stats.total_duplicates,
            total_bytes_received = stats.total_bytes_received,
            loss_rate_percent_x100 = stats.loss_rate_percent_x100,
            rtt_us = stats.rtt,
            rtt_var_us = stats.rtt_var,
            jitter_us = stats.jitter
        );
    }

    /// Registra contadores del listener limitando la frecuencia.
    pub fn srt_listener_stats(&self, active_sessions: usize, rejected_datagrams: u64) {
        tracing::info!(
            schema_version = SCHEMA_VERSION,
            event = "srt_listener_stats",
            service = SERVICE_NAME,
            instance_id = %self.instance_id,
            active_sessions,
            rejected_datagrams
        );
    }

    /// Registra solicitud de rotación de clave sin material secreto.
    pub fn srt_key_refresh_needed(&self, connection_id: &str, peer: SocketAddr, key_length: usize) {
        tracing::info!(
            schema_version = SCHEMA_VERSION,
            event = "srt_key_refresh_needed",
            service = SERVICE_NAME,
            instance_id = %self.instance_id,
            connection_id,
            peer = %peer,
            key_length
        );
    }

    /// Registra el primer fallo UDP de un peer hasta que se recupere.
    pub fn srt_udp_send_error(
        &self,
        connection_id: &str,
        peer: SocketAddr,
        error: &dyn std::error::Error,
    ) {
        tracing::warn!(
            schema_version = SCHEMA_VERSION,
            event = "srt_udp_send_failed",
            service = SERVICE_NAME,
            instance_id = %self.instance_id,
            connection_id,
            peer = %peer,
            reason = "io_error",
            error = %error
        );
    }

    /// Registra un fallo UDP sin objeto de error del sistema.
    pub fn srt_udp_send_failed(&self, connection_id: &str, peer: SocketAddr, reason: &'static str) {
        tracing::warn!(
            schema_version = SCHEMA_VERSION,
            event = "srt_udp_send_failed",
            service = SERVICE_NAME,
            instance_id = %self.instance_id,
            connection_id,
            peer = %peer,
            reason
        );
    }

    /// Registra la recuperación posterior al primer fallo UDP.
    pub fn srt_udp_send_recovered(&self, connection_id: &str, peer: SocketAddr) {
        tracing::info!(
            schema_version = SCHEMA_VERSION,
            event = "srt_udp_send_recovered",
            service = SERVICE_NAME,
            instance_id = %self.instance_id,
            connection_id,
            peer = %peer
        );
    }

    /// Registra la versión y los elementos `GStreamer` auditados al inicio.
    pub fn media_runtime_ready(&self, version: &str, factories: &[&str]) {
        tracing::info!(schema_version = SCHEMA_VERSION, event = "media_runtime_ready",
            service = SERVICE_NAME, instance_id = %self.instance_id, gstreamer_version = version,
            factories = ?factories, zero_transcoding = true);
    }

    /// Registra un pipeline aislado por conexión y programa.
    pub fn media_pipeline_opened(
        &self,
        connection_id: &str,
        peer: SocketAddr,
        source: &str,
        programs: usize,
    ) {
        tracing::info!(schema_version = SCHEMA_VERSION, event = "media_pipeline_opened",
            service = SERVICE_NAME, instance_id = %self.instance_id, connection_id, peer = %peer,
            source, programs);
    }

    /// Registra un pipeline que no pudo crearse sin terminar el proceso.
    pub fn media_pipeline_rejected(
        &self,
        connection_id: &str,
        peer: SocketAddr,
        error: &dyn std::error::Error,
    ) {
        tracing::warn!(schema_version = SCHEMA_VERSION, event = "media_pipeline_rejected",
            service = SERVICE_NAME, instance_id = %self.instance_id, connection_id, peer = %peer,
            error = %error);
    }

    /// Registra fallo controlado de una conexión multimedia.
    pub fn media_pipeline_failed(
        &self,
        connection_id: &str,
        peer: SocketAddr,
        error: &dyn std::error::Error,
    ) {
        tracing::warn!(schema_version = SCHEMA_VERSION, event = "media_pipeline_failed",
            service = SERVICE_NAME, instance_id = %self.instance_id, connection_id, peer = %peer,
            error = %error);
    }

    /// Variante para errores ya convertidos a texto por el bus nativo.
    pub fn media_pipeline_failed_message(
        &self,
        connection_id: &str,
        peer: SocketAddr,
        error: &str,
    ) {
        tracing::warn!(schema_version = SCHEMA_VERSION, event = "media_pipeline_failed",
            service = SERVICE_NAME, instance_id = %self.instance_id, connection_id, peer = %peer, error);
    }

    /// Registra warnings `GStreamer` sin payloads ni Stream IDs.
    pub fn media_pipeline_warning(&self, connection_id: &str, program_number: u16, warning: &str) {
        tracing::warn!(schema_version = SCHEMA_VERSION, event = "media_pipeline_warning",
            service = SERVICE_NAME, instance_id = %self.instance_id, connection_id,
            program_number, warning);
    }

    /// Registra liberación del pipeline aislado.
    pub fn media_pipeline_closed(
        &self,
        connection_id: &str,
        peer: SocketAddr,
        program_number: u16,
        reason: &'static str,
    ) {
        tracing::info!(schema_version = SCHEMA_VERSION, event = "media_pipeline_closed",
            service = SERVICE_NAME, instance_id = %self.instance_id, connection_id, peer = %peer,
            program_number, reason);
    }

    /// Registra una nueva corriente elemental resuelta a Track.
    pub fn mpegts_stream_discovered(
        &self,
        connection_id: &str,
        program_number: u16,
        pid: u16,
        track: u8,
        codec: &str,
    ) {
        tracing::info!(schema_version = SCHEMA_VERSION, event = "mpegts_stream_discovered",
            service = SERVICE_NAME, instance_id = %self.instance_id, connection_id,
            program_number, pid, track, codec);
    }

    /// Registra PID no configurado, caps incompatibles o códec no soportado.
    pub fn media_stream_rejected(
        &self,
        connection_id: &str,
        program_number: u16,
        pid: Option<u16>,
        error: &dyn std::error::Error,
    ) {
        tracing::warn!(schema_version = SCHEMA_VERSION, event = "media_stream_rejected",
            service = SERVICE_NAME, instance_id = %self.instance_id, connection_id,
            program_number, pid, error = %error);
    }

    /// Registra cambios observados a través de pads dinámicos de `tsdemux`.
    pub fn mpegts_program_changed(
        &self,
        connection_id: &str,
        program_number: u16,
        pid: u16,
        reason: &'static str,
    ) {
        tracing::info!(schema_version = SCHEMA_VERSION, event = "mpegts_program_changed",
            service = SERVICE_NAME, instance_id = %self.instance_id, connection_id,
            program_number, pid, reason);
    }

    /// Registra discontinuidad MPEG-TS propagada en flags `GStreamer`.
    pub fn mpegts_discontinuity(
        &self,
        connection_id: &str,
        program_number: u16,
        pid: u16,
        track: u8,
    ) {
        tracing::warn!(schema_version = SCHEMA_VERSION, event = "mpegts_discontinuity",
            service = SERVICE_NAME, instance_id = %self.instance_id, connection_id,
            program_number, pid, track);
    }

    /// Registra saturación o un objeto fuera de límites; nunca el contenido.
    pub fn media_output_backpressure(&self, connection_id: &str, track: u8, reason: &'static str) {
        tracing::warn!(schema_version = SCHEMA_VERSION, event = "media_output_backpressure",
            service = SERVICE_NAME, instance_id = %self.instance_id, connection_id, track, reason);
    }

    /// Registra telemetría rechazada antes de convertirla en Object.
    pub fn telemetry_invalid_json(
        &self,
        connection_id: &str,
        program_number: u16,
        pid: u16,
        payload_bytes: usize,
    ) {
        tracing::warn!(schema_version = SCHEMA_VERSION, event = "telemetry_invalid_json",
            service = SERVICE_NAME, instance_id = %self.instance_id, connection_id,
            program_number, pid, payload_bytes);
    }

    /// Registra una cola aislada recién creada.
    pub fn scheduler_subscriber_opened(
        &self,
        subscriber_id: &str,
        queue_objects_limit: usize,
        queue_bytes_limit: usize,
    ) {
        tracing::info!(schema_version = SCHEMA_VERSION, event = "scheduler_subscriber_opened",
            service = SERVICE_NAME, instance_id = %self.instance_id, subscriber_id,
            queue_objects_limit, queue_bytes_limit);
    }

    /// Registra la liberación de una cola de suscriptor.
    pub fn scheduler_subscriber_closed(&self, subscriber_id: &str) {
        tracing::info!(schema_version = SCHEMA_VERSION, event = "scheduler_subscriber_closed",
            service = SERVICE_NAME, instance_id = %self.instance_id, subscriber_id);
    }

    /// Registra el fallo aislado de un consumidor o de su publisher.
    pub fn scheduler_subscriber_failed(&self, subscriber_id: &str, error: &dyn std::error::Error) {
        tracing::warn!(schema_version = SCHEMA_VERSION, event = "scheduler_subscriber_failed",
            service = SERVICE_NAME, instance_id = %self.instance_id, subscriber_id,
            error = %error);
    }

    /// Registra un descarte esperado sin convertirlo en fallo del proceso.
    pub fn object_dropped(&self, event: &ObjectDropEvent<'_>) {
        tracing::info!(schema_version = SCHEMA_VERSION, event = "object_dropped",
            service = SERVICE_NAME, instance_id = %self.instance_id,
            connection_id = event.connection_id, subscriber_id = event.subscriber_id,
            track = event.track, priority = event.priority, group_id = event.group_id,
            object_id = event.object_id, age_ms = event.age_ms, deadline_ms = event.deadline_ms,
            queue_objects = event.queue_objects, queue_bytes = event.queue_bytes,
            reason = event.reason);
    }

    /// Registra que una cola crítica cerró solo su sesión consumidora.
    pub fn subscriber_evicted_critical_backpressure(&self, event: &CriticalEvictionEvent<'_>) {
        tracing::warn!(schema_version = SCHEMA_VERSION,
            event = "subscriber_evicted_critical_backpressure", service = SERVICE_NAME,
            instance_id = %self.instance_id, connection_id = event.connection_id,
            subscriber_id = event.subscriber_id, track = event.track,
            priority = 0_u8, group_id = event.group_id, object_id = event.object_id,
            age_ms = event.age_ms, deadline_ms = event.deadline_ms,
            queue_objects = event.queue_objects, queue_bytes = event.queue_bytes,
            reason = event.reason);
    }

    /// Registra que la identidad local y el trust store se cargaron antes de listeners.
    pub fn moq_mtls_ready(&self, protocol: &'static str, provider: &'static str) {
        tracing::info!(schema_version = SCHEMA_VERSION, event = "moq_mtls_ready",
            service = SERVICE_NAME, instance_id = %self.instance_id, protocol, provider,
            peer_verification = true, client_identity = true);
    }

    /// Registra un rechazo local fail-closed sin paths ni material PKI.
    pub fn moq_mtls_configuration_failed(&self, reason: &'static str) {
        tracing::error!(schema_version = SCHEMA_VERSION,
            event = "moq_mtls_configuration_failed", service = SERVICE_NAME,
            instance_id = %self.instance_id, reason);
    }

    /// Registra un handshake remoto fallido usando una razón enumerable.
    pub fn moq_mtls_handshake_failed(&self, reason: &'static str) {
        tracing::warn!(schema_version = SCHEMA_VERSION, event = "moq_mtls_handshake_failed",
            service = SERVICE_NAME, instance_id = %self.instance_id, reason);
    }

    /// Registra el socket cliente y la versión `MoQT` sin exponer la ruta del relay.
    pub fn moq_publisher_ready(
        &self,
        local_addr: SocketAddr,
        draft: &'static str,
        alpn: &'static str,
    ) {
        tracing::info!(schema_version = SCHEMA_VERSION, event = "moq_publisher_ready",
            service = SERVICE_NAME, instance_id = %self.instance_id, local_addr = %local_addr,
            draft, alpn);
    }

    /// Registra un intento acotado usando solo el origen seguro del relay.
    pub fn moq_connection_attempt(&self, relay: &str, generation: u64) {
        tracing::info!(schema_version = SCHEMA_VERSION, event = "moq_connection_attempt",
            service = SERVICE_NAME, instance_id = %self.instance_id, relay, generation);
    }

    /// Registra un fallo recuperable de conexión o setup.
    pub fn moq_connection_failed(
        &self,
        relay: &str,
        generation: u64,
        error: &dyn std::fmt::Display,
    ) {
        tracing::warn!(schema_version = SCHEMA_VERSION, event = "moq_connection_failed",
            service = SERVICE_NAME, instance_id = %self.instance_id, relay, generation,
            error = %error);
    }

    /// Registra el backoff exponencial de una reconexión recuperable.
    pub fn moq_reconnect_scheduled(
        &self,
        relay: &str,
        generation: u64,
        consecutive_failures: u32,
        delay_ms: u64,
    ) {
        tracing::info!(schema_version = SCHEMA_VERSION, event = "moq_reconnect_scheduled",
            service = SERVICE_NAME, instance_id = %self.instance_id, relay, generation,
            consecutive_failures, delay_ms);
    }

    /// Registra que el publisher pausa nuevos handshakes para respetar su presupuesto.
    pub fn moq_retry_budget_exhausted(
        &self,
        relay: &str,
        maximum_attempts: usize,
        window_ms: u64,
        resume_after_ms: u64,
    ) {
        tracing::warn!(schema_version = SCHEMA_VERSION, event = "moq_retry_budget_exhausted",
            service = SERVICE_NAME, instance_id = %self.instance_id, relay,
            maximum_attempts, window_ms, resume_after_ms);
    }

    /// Registra una sesión `MoQT` establecida.
    pub fn moq_connected(&self, connection_id: &str, relay: &str, generation: u64) {
        tracing::info!(schema_version = SCHEMA_VERSION, event = "moq_connected",
            service = SERVICE_NAME, instance_id = %self.instance_id, connection_id,
            relay, generation);
    }

    /// Registra el comienzo de `PUBLISH_NAMESPACE`.
    pub fn moq_namespace_publish_started(&self, namespace: &str) {
        tracing::info!(schema_version = SCHEMA_VERSION, event = "moq_namespace_publish_started",
            service = SERVICE_NAME, instance_id = %self.instance_id, namespace);
    }

    /// Registra cada Object entregado a la API upstream, sin copiar su payload.
    pub fn moq_object_published(&self, object: &ScheduledObject) {
        let ingest_to_publish_ms = u64::try_from(
            tokio::time::Instant::now()
                .saturating_duration_since(object.received_at)
                .as_millis(),
        )
        .map_or(u64::MAX, std::convert::identity);
        tracing::debug!(schema_version = SCHEMA_VERSION, event = "moq_object_published",
            service = SERVICE_NAME, instance_id = %self.instance_id,
            connection_id = %object.connection_id, track = object.track.value(),
            priority = object.priority.value(), group_id = object.group.id,
            object_id = object.object_id, bytes = object.payload.len(),
            pts_ns = object.pts_ns, dts_ns = object.dts_ns, ingest_to_publish_ms);
    }

    /// Registra un cierre normal o reinicio remoto.
    pub fn moq_disconnected(&self, connection_id: &str, reason: &'static str) {
        tracing::info!(schema_version = SCHEMA_VERSION, event = "moq_disconnected",
            service = SERVICE_NAME, instance_id = %self.instance_id, connection_id, reason);
    }

    /// Registra un fallo aislado de una sesión `MoQT` antes de reconectar.
    pub fn moq_session_failed(&self, connection_id: &str, error: &dyn std::fmt::Display) {
        tracing::warn!(schema_version = SCHEMA_VERSION, event = "moq_session_failed",
            service = SERVICE_NAME, instance_id = %self.instance_id, connection_id,
            error = %error);
    }

    /// Registra la dirección local del supervisor de señal.
    pub fn supervisor_web_bound(&self, bind_addr: SocketAddr) {
        tracing::info!(schema_version = SCHEMA_VERSION, event = "supervisor_web_bound",
            service = SERVICE_NAME, instance_id = %self.instance_id, bind_addr = %bind_addr);
    }

    /// Registra un fallo recuperable del panel; el directo continúa y reintenta.
    pub fn supervisor_web_unavailable(&self, bind_addr: SocketAddr, error: &dyn std::error::Error) {
        tracing::warn!(schema_version = SCHEMA_VERSION, event = "supervisor_web_unavailable",
            service = SERVICE_NAME, instance_id = %self.instance_id, bind_addr = %bind_addr,
            error = %error, retry_delay_ms = 5_000_u64);
    }
}

/// Instala el subscriber global JSON de una línea sobre `stdout`.
///
/// # Errors
///
/// Devuelve error si el filtro es inválido o ya existe un subscriber global.
pub fn init_json_logging(filter: &str) -> GatewayResult<()> {
    let env_filter = EnvFilter::try_new(filter).map_err(|source| {
        GatewayError::with_source("invalid TEREMOQ_LOG directive", Box::new(source)).boxed()
    })?;

    tracing_subscriber::fmt()
        .json()
        .flatten_event(true)
        .with_env_filter(env_filter)
        .with_target(false)
        .with_current_span(false)
        .with_span_list(false)
        .with_writer(std::io::stdout)
        .try_init()
        .map_err(|source| {
            GatewayError::with_source("failed to initialize JSON logging", source).boxed()
        })
}
