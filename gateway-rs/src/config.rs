//! Configuración del proceso y validación de límites operativos.

use std::{
    env,
    fmt::{Debug, Formatter},
    net::SocketAddr,
    path::PathBuf,
    time::Duration,
};

use tracing_subscriber::EnvFilter;
use url::Url;

use crate::{
    error::{GatewayError, GatewayResult},
    routing::RouteTable,
    security::dev_relay_capability::{DEV_RELAY_PUBLISH_CAPABILITY_ENV, DevRelayPublishCapability},
};

const DEFAULT_INSTANCE_ID: &str = "gateway-dev-1";
const DEFAULT_LOG_FILTER: &str = "info";
const DEFAULT_SHUTDOWN_TIMEOUT_MS: u64 = 3_000;
const MIN_SHUTDOWN_TIMEOUT_MS: u64 = 100;
const MAX_SHUTDOWN_TIMEOUT_MS: u64 = 30_000;
const MAX_INSTANCE_ID_LEN: usize = 64;
const MAX_LOG_FILTER_LEN: usize = 256;
const DEFAULT_SRT_BIND_ADDR: &str = "0.0.0.0:9000";
const DEFAULT_SRT_MAX_SESSIONS: u64 = 32;
const DEFAULT_SRT_INGRESS_QUEUE: u64 = 1_024;
const DEFAULT_SRT_EGRESS_QUEUE: u64 = 512;
const DEFAULT_SRT_TSBPD_DELAY_MS: u64 = 120;
const DEFAULT_SRT_STATS_INTERVAL_SECS: u64 = 5;
const MAX_SRT_SESSIONS: u64 = 256;
const MAX_SRT_QUEUE_CAPACITY: u64 = 65_536;
const MAX_ROUTES_JSON_BYTES: usize = 65_536;
const MIN_SRT_PASSPHRASE_BYTES: usize = 10;
const MAX_SRT_PASSPHRASE_BYTES: usize = 79;
const DEFAULT_MEDIA_INPUT_QUEUE_BYTES: u64 = 4 * 1024 * 1024;
const DEFAULT_MEDIA_OUTPUT_QUEUE_OBJECTS: u64 = 256;
const DEFAULT_MEDIA_MAX_OBJECT_BYTES: u64 = 8 * 1024 * 1024;
const DEFAULT_MEDIA_SESSION_IDLE_TIMEOUT_MS: u64 = 30_000;
const MAX_MEDIA_QUEUE_BYTES: u64 = 64 * 1024 * 1024;
const MAX_MEDIA_OUTPUT_QUEUE_OBJECTS: u64 = 65_536;
const MAX_MEDIA_OBJECT_BYTES: u64 = 32 * 1024 * 1024;
const DEFAULT_SUPERVISOR_BIND_ADDR: &str = "127.0.0.1:9080";
const DEFAULT_SUPERVISOR_INPUT_PREVIEW_URL: &str =
    "http://127.0.0.1:8889/input?autoplay=true&muted=true&controls=true";
const DEFAULT_SUPERVISOR_MOQ_FINGERPRINT_PATH: &str = ".teremoq-dev/tls/relay-cert.sha256";
const DEFAULT_SCHEDULER_MAX_SUBSCRIBERS: u64 = 32;
const DEFAULT_SCHEDULER_QUEUE_OBJECTS: u64 = 256;
const DEFAULT_SCHEDULER_QUEUE_BYTES: u64 = 16 * 1024 * 1024;
const DEFAULT_SCHEDULER_DELTA_DEADLINE_MS: u64 = 150;
const DEFAULT_SCHEDULER_RANDOM_ACCESS_DEADLINE_MS: u64 = 1_000;
const DEFAULT_SCHEDULER_CRITICAL_DEADLINE_MS: u64 = 2_000;
const MAX_SCHEDULER_SUBSCRIBERS: u64 = 256;
const MAX_SCHEDULER_QUEUE_OBJECTS: u64 = 65_536;
const MAX_SCHEDULER_QUEUE_BYTES: u64 = 256 * 1024 * 1024;
const MAX_SCHEDULER_DEADLINE_MS: u64 = 60_000;
const DEFAULT_MOQ_RELAY_URL: &str = "https://127.0.0.1:4443/publish";
const DEFAULT_MOQ_BIND_ADDR: &str = "[::]:0";
const DEFAULT_MOQ_NAMESPACE: &str = "teremoq/live";
const DEFAULT_MOQ_RECONNECT_DELAY_MS: u64 = 1_000;
const DEFAULT_MOQ_RECONNECT_MAX_DELAY_MS: u64 = 30_000;
const DEFAULT_MOQ_RETRY_MAX_ATTEMPTS: u64 = 30;
const DEFAULT_MOQ_RETRY_WINDOW_MS: u64 = 60_000;
const DEFAULT_MOQ_CONNECT_TIMEOUT_MS: u64 = 5_000;
const DEFAULT_MOQ_TLS_ROOT: &str = ".teremoq-dev/mtls/root.pem";
const DEFAULT_MOQ_TLS_CLIENT_CERT: &str = ".teremoq-dev/mtls/gateway-cert.pem";
const DEFAULT_MOQ_TLS_CLIENT_KEY: &str = ".teremoq-dev/mtls/gateway-key.pem";
const MAX_MOQ_NAMESPACE_BYTES: usize = 256;
const MAX_MOQ_RECONNECT_DELAY_MS: u64 = 30_000;
const MAX_MOQ_RETRY_ATTEMPTS: u64 = 1_000;
const MAX_MOQ_RETRY_WINDOW_MS: u64 = 3_600_000;
const MAX_MOQ_CONNECT_TIMEOUT_MS: u64 = 30_000;

const DEFAULT_ROUTES_JSON: &str = r#"[
    {"source":"main","stream_id":"teremoq-main","program_number":1,"pid":256,"track":0},
    {"source":"fallback","stream_id":"teremoq-lq","program_number":1,"pid":256,"track":1},
    {"source":"main","stream_id":"teremoq-main","program_number":1,"pid":257,"track":2},
    {"source":"telemetry","stream_id":"teremoq-telemetry","program_number":1,"pid":300,"track":3}
]"#;

/// Configuración validada necesaria para iniciar el esqueleto del Gateway.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GatewayConfig {
    /// Identidad de baja cardinalidad incluida en cada evento.
    pub instance_id: String,
    /// Directiva de filtrado compatible con `tracing-subscriber`.
    pub log_filter: String,
    /// Plazo máximo para el cierre coordinado de tasks.
    pub shutdown_timeout: Duration,
    /// Listener y autorización de ingesta SRT.
    pub srt: SrtConfig,
    /// Límites del demultiplexor MPEG-TS sin transcodificación.
    pub media: MediaConfig,
    /// Colas, deadlines y aislamiento del scheduler por suscriptor.
    pub scheduler: SchedulerConfig,
    /// Publisher `MoQT` draft-16 y conexión al relay reutilizado.
    pub moq: MoqConfig,
    /// Panel web local de observabilidad de la señal.
    pub supervisor: SupervisorConfig,
}

/// Configuración del publisher `MoQT` saliente.
#[derive(Clone, Eq, PartialEq)]
pub struct MoqConfig {
    /// URL WebTransport del relay; se considera sensible y no se imprime completa.
    pub relay_url: Url,
    /// Socket UDP local del cliente QUIC.
    pub bind_addr: SocketAddr,
    /// Namespace lógico anunciado mediante `PUBLISH_NAMESPACE`.
    pub namespace: String,
    /// CA explícita para validar la identidad persistente del relay.
    pub tls_root: PathBuf,
    /// Cadena cliente leaf -> intermediate presentada al relay privado.
    pub tls_client_cert: PathBuf,
    /// Clave privada de la identidad cliente; nunca se imprime en `Debug`.
    pub tls_client_key: PathBuf,
    /// Espera inicial entre intentos de conexión independientes de la ingesta.
    pub reconnect_delay: Duration,
    /// Techo efectivo del backoff exponencial, incluido el jitter.
    pub reconnect_max_delay: Duration,
    /// Máximo de intentos permitidos durante la ventana deslizante.
    pub retry_max_attempts: usize,
    /// Ventana monotónica del presupuesto de reintentos.
    pub retry_window: Duration,
    /// Límite para conexión QUIC y setup `MoQT`.
    pub connect_timeout: Duration,
}

impl Debug for MoqConfig {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("MoqConfig")
            .field("relay_origin", &relay_origin(&self.relay_url))
            .field("bind_addr", &self.bind_addr)
            .field("namespace", &self.namespace)
            .field("tls_root_configured", &true)
            .field("mtls_identity_configured", &true)
            .field("reconnect_delay", &self.reconnect_delay)
            .field("reconnect_max_delay", &self.reconnect_max_delay)
            .field("retry_max_attempts", &self.retry_max_attempts)
            .field("retry_window", &self.retry_window)
            .field("connect_timeout", &self.connect_timeout)
            .finish_non_exhaustive()
    }
}

/// Configuración de seguridad del supervisor web de solo lectura.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SupervisorConfig {
    /// Dirección TCP local; se restringe a loopback en esta `PoC`.
    pub bind_addr: SocketAddr,
    /// Página WebRTC del observador SRT externo; nunca forma parte del data plane.
    pub input_preview_url: Option<Url>,
    /// Fingerprint SHA-256 DER publicado por el relay local para WebTransport.
    pub moq_fingerprint_path: Option<PathBuf>,
}

/// Límites del scheduler, aplicados de forma independiente por suscriptor.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SchedulerConfig {
    /// Máximo de sesiones consumidoras registradas.
    pub max_subscribers: usize,
    /// Máximo de Objects pendientes por suscriptor.
    pub queue_objects: usize,
    /// Máximo de bytes pendientes por suscriptor.
    pub queue_bytes: usize,
    /// Residencia máxima del vídeo delta.
    pub delta_deadline: Duration,
    /// Residencia máxima de un punto de acceso aleatorio.
    pub random_access_deadline: Duration,
    /// Deadline operativo que provoca expulsión si expira contenido crítico.
    pub critical_deadline: Duration,
}

/// Límites de memoria y ciclo de vida del pipeline `GStreamer`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MediaConfig {
    /// Máximo de bytes MPEG-TS pendientes por programa.
    pub input_queue_bytes: usize,
    /// Máximo de Objects pendientes por Track.
    pub output_queue_objects: usize,
    /// Tamaño máximo de una access unit codificada.
    pub max_object_bytes: usize,
    /// Tiempo sin tráfico tras el que se libera una sesión multimedia.
    pub session_idle_timeout: Duration,
}

/// Configuración validada del adaptador SRT.
#[derive(Clone, Eq, PartialEq)]
pub struct SrtConfig {
    /// Dirección UDP del listener real.
    pub bind_addr: SocketAddr,
    /// Passphrase opcional, mantenida fuera de logs y de `Debug`.
    pub passphrase: Option<String>,
    /// Número máximo de peers SRT simultáneos.
    pub max_sessions: usize,
    /// Capacidad en mensajes del canal hacia el pipeline.
    pub ingress_queue_capacity: usize,
    /// Capacidad en datagramas del canal de control SRT.
    pub egress_queue_capacity: usize,
    /// Latencia TSBPD solicitada al backend.
    pub tsbpd_delay_ms: u16,
    /// Frecuencia acotada de estadísticas por conexión.
    pub stats_interval: Duration,
    /// Routing y allowlist exacta de Stream IDs.
    pub routes: RouteTable,
}

impl Debug for SrtConfig {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SrtConfig")
            .field("bind_addr", &self.bind_addr)
            .field(
                "passphrase",
                &self.passphrase.as_ref().map(|_| "[REDACTED]"),
            )
            .field("max_sessions", &self.max_sessions)
            .field("ingress_queue_capacity", &self.ingress_queue_capacity)
            .field("egress_queue_capacity", &self.egress_queue_capacity)
            .field("tsbpd_delay_ms", &self.tsbpd_delay_ms)
            .field("stats_interval", &self.stats_interval)
            .field("routes", &self.routes)
            .finish()
    }
}

impl GatewayConfig {
    /// Lee la configuración desde variables de entorno y valida sus límites.
    ///
    /// # Errors
    ///
    /// Devuelve error si una variable no es Unicode, no puede convertirse o
    /// queda fuera de los límites documentados.
    pub fn from_env() -> GatewayResult<Self> {
        let instance_id = read_string_env("TEREMOQ_INSTANCE_ID", DEFAULT_INSTANCE_ID)?;
        let mut log_filter = read_string_env("TEREMOQ_LOG", DEFAULT_LOG_FILTER)?;
        if env::var_os(DEV_RELAY_PUBLISH_CAPABILITY_ENV).is_some() {
            // El setup cliente upstream incluye el path en DEBUG. La capacidad
            // LAN no puede aparecer aunque el operador active debug global.
            log_filter.push_str(",moq_transport::control=info");
        }
        let shutdown_timeout_ms =
            parse_u64_env("TEREMOQ_SHUTDOWN_TIMEOUT_MS", DEFAULT_SHUTDOWN_TIMEOUT_MS)?;

        let mut config = Self::new(instance_id, log_filter, shutdown_timeout_ms)?;
        config.srt = SrtConfig::from_env()?;
        config.media = MediaConfig::from_env()?;
        config.scheduler = SchedulerConfig::from_env()?;
        config.moq = MoqConfig::from_env()?;
        config.supervisor = SupervisorConfig::from_env()?;
        Ok(config)
    }

    /// Construye configuración explícita; se usa también en tests.
    ///
    /// # Errors
    ///
    /// Devuelve error si la identidad, el filtro o el deadline no son válidos.
    pub fn new(
        instance_id: impl Into<String>,
        log_filter: impl Into<String>,
        shutdown_timeout_ms: u64,
    ) -> GatewayResult<Self> {
        let config = Self {
            instance_id: instance_id.into(),
            log_filter: log_filter.into(),
            shutdown_timeout: Duration::from_millis(shutdown_timeout_ms),
            srt: SrtConfig::development()?,
            media: MediaConfig::development()?,
            scheduler: SchedulerConfig::development()?,
            moq: MoqConfig::development()?,
            supervisor: SupervisorConfig::development()?,
        };
        config.validate()?;
        Ok(config)
    }

    fn validate(&self) -> GatewayResult<()> {
        validate_label(
            "TEREMOQ_INSTANCE_ID",
            &self.instance_id,
            MAX_INSTANCE_ID_LEN,
        )?;

        if self.log_filter.is_empty() || self.log_filter.len() > MAX_LOG_FILTER_LEN {
            return Err(GatewayError::new(format!(
                "TEREMOQ_LOG must contain between 1 and {MAX_LOG_FILTER_LEN} bytes"
            ))
            .boxed());
        }
        EnvFilter::try_new(&self.log_filter).map_err(|source| {
            GatewayError::with_source(
                "TEREMOQ_LOG contains an invalid directive",
                Box::new(source),
            )
            .boxed()
        })?;

        let shutdown_ms = duration_millis_u64(self.shutdown_timeout);
        if !(MIN_SHUTDOWN_TIMEOUT_MS..=MAX_SHUTDOWN_TIMEOUT_MS).contains(&shutdown_ms) {
            return Err(GatewayError::new(format!(
                "TEREMOQ_SHUTDOWN_TIMEOUT_MS must be between {MIN_SHUTDOWN_TIMEOUT_MS} and {MAX_SHUTDOWN_TIMEOUT_MS}"
            ))
            .boxed());
        }

        Ok(())
    }
}

impl MoqConfig {
    fn from_env() -> GatewayResult<Self> {
        let mut relay_url = parse_moq_url(&read_string_env(
            "TEREMOQ_MOQ_RELAY_URL",
            DEFAULT_MOQ_RELAY_URL,
        )?)?;
        if let Some(capability_path) = env::var_os(DEV_RELAY_PUBLISH_CAPABILITY_ENV) {
            let capability = DevRelayPublishCapability::load(&PathBuf::from(capability_path))
                .map_err(|source| {
                    GatewayError::with_source(
                        "development relay publish capability is invalid",
                        Box::new(source),
                    )
                    .boxed()
                })?;
            capability
                .apply_to_local_publish_url(&mut relay_url)
                .map_err(|source| {
                    GatewayError::with_source(
                        "development relay publish capability cannot be applied",
                        Box::new(source),
                    )
                    .boxed()
                })?;
        }
        let bind_addr = read_string_env("TEREMOQ_MOQ_BIND_ADDR", DEFAULT_MOQ_BIND_ADDR)?
            .parse::<SocketAddr>()
            .map_err(|source| {
                GatewayError::with_source(
                    "TEREMOQ_MOQ_BIND_ADDR must be an IP socket address",
                    Box::new(source),
                )
                .boxed()
            })?;
        let namespace = read_string_env("TEREMOQ_MOQ_NAMESPACE", DEFAULT_MOQ_NAMESPACE)?;
        validate_moq_namespace(&namespace)?;
        let tls_root = read_required_path_env("TEREMOQ_MOQ_TLS_ROOT", "missing_root")?;
        let tls_client_cert =
            read_required_path_env("TEREMOQ_MOQ_TLS_CLIENT_CERT", "missing_client_certificate")?;
        let tls_client_key =
            read_required_path_env("TEREMOQ_MOQ_TLS_CLIENT_KEY", "missing_client_key")?;
        if parse_bool_env("TEREMOQ_MOQ_TLS_DISABLE_VERIFY", false)? {
            return Err(GatewayError::new("tls_verification_disabled_forbidden").boxed());
        }
        let reconnect_delay = Duration::from_millis(bounded_u64_env(
            "TEREMOQ_MOQ_RECONNECT_DELAY_MS",
            DEFAULT_MOQ_RECONNECT_DELAY_MS,
            100,
            MAX_MOQ_RECONNECT_DELAY_MS,
        )?);
        let reconnect_max_delay = Duration::from_millis(bounded_u64_env(
            "TEREMOQ_MOQ_RECONNECT_MAX_DELAY_MS",
            DEFAULT_MOQ_RECONNECT_MAX_DELAY_MS,
            100,
            MAX_MOQ_RECONNECT_DELAY_MS,
        )?);
        if reconnect_delay > reconnect_max_delay {
            return Err(GatewayError::new(
                "TEREMOQ_MOQ_RECONNECT_DELAY_MS must not exceed TEREMOQ_MOQ_RECONNECT_MAX_DELAY_MS",
            )
            .boxed());
        }
        let retry_max_attempts = bounded_usize_env(
            "TEREMOQ_MOQ_RETRY_MAX_ATTEMPTS",
            DEFAULT_MOQ_RETRY_MAX_ATTEMPTS,
            1,
            MAX_MOQ_RETRY_ATTEMPTS,
        )?;
        let retry_window = Duration::from_millis(bounded_u64_env(
            "TEREMOQ_MOQ_RETRY_WINDOW_MS",
            DEFAULT_MOQ_RETRY_WINDOW_MS,
            1_000,
            MAX_MOQ_RETRY_WINDOW_MS,
        )?);
        let connect_timeout = Duration::from_millis(bounded_u64_env(
            "TEREMOQ_MOQ_CONNECT_TIMEOUT_MS",
            DEFAULT_MOQ_CONNECT_TIMEOUT_MS,
            100,
            MAX_MOQ_CONNECT_TIMEOUT_MS,
        )?);
        Ok(Self {
            relay_url,
            bind_addr,
            namespace,
            tls_root,
            tls_client_cert,
            tls_client_key,
            reconnect_delay,
            reconnect_max_delay,
            retry_max_attempts,
            retry_window,
            connect_timeout,
        })
    }

    fn development() -> GatewayResult<Self> {
        Ok(Self {
            relay_url: parse_moq_url(DEFAULT_MOQ_RELAY_URL)?,
            bind_addr: DEFAULT_MOQ_BIND_ADDR
                .parse::<SocketAddr>()
                .map_err(|source| {
                    GatewayError::with_source(
                        "invalid built-in MoQT bind address",
                        Box::new(source),
                    )
                    .boxed()
                })?,
            namespace: DEFAULT_MOQ_NAMESPACE.to_owned(),
            tls_root: PathBuf::from(DEFAULT_MOQ_TLS_ROOT),
            tls_client_cert: PathBuf::from(DEFAULT_MOQ_TLS_CLIENT_CERT),
            tls_client_key: PathBuf::from(DEFAULT_MOQ_TLS_CLIENT_KEY),
            reconnect_delay: Duration::from_millis(DEFAULT_MOQ_RECONNECT_DELAY_MS),
            reconnect_max_delay: Duration::from_millis(DEFAULT_MOQ_RECONNECT_MAX_DELAY_MS),
            retry_max_attempts: usize::try_from(DEFAULT_MOQ_RETRY_MAX_ATTEMPTS).map_err(
                |source| {
                    GatewayError::with_source(
                        "invalid built-in MoQT retry attempt limit",
                        Box::new(source),
                    )
                    .boxed()
                },
            )?,
            retry_window: Duration::from_millis(DEFAULT_MOQ_RETRY_WINDOW_MS),
            connect_timeout: Duration::from_millis(DEFAULT_MOQ_CONNECT_TIMEOUT_MS),
        })
    }
}

impl SchedulerConfig {
    fn from_env() -> GatewayResult<Self> {
        Self::new(
            bounded_usize_env(
                "TEREMOQ_SCHEDULER_MAX_SUBSCRIBERS",
                DEFAULT_SCHEDULER_MAX_SUBSCRIBERS,
                1,
                MAX_SCHEDULER_SUBSCRIBERS,
            )?,
            bounded_usize_env(
                "TEREMOQ_SCHEDULER_QUEUE_OBJECTS",
                DEFAULT_SCHEDULER_QUEUE_OBJECTS,
                1,
                MAX_SCHEDULER_QUEUE_OBJECTS,
            )?,
            bounded_usize_env(
                "TEREMOQ_SCHEDULER_QUEUE_BYTES",
                DEFAULT_SCHEDULER_QUEUE_BYTES,
                188,
                MAX_SCHEDULER_QUEUE_BYTES,
            )?,
            bounded_u64_env(
                "TEREMOQ_SCHEDULER_DELTA_DEADLINE_MS",
                DEFAULT_SCHEDULER_DELTA_DEADLINE_MS,
                1,
                MAX_SCHEDULER_DEADLINE_MS,
            )?,
            bounded_u64_env(
                "TEREMOQ_SCHEDULER_RANDOM_ACCESS_DEADLINE_MS",
                DEFAULT_SCHEDULER_RANDOM_ACCESS_DEADLINE_MS,
                1,
                MAX_SCHEDULER_DEADLINE_MS,
            )?,
            bounded_u64_env(
                "TEREMOQ_SCHEDULER_CRITICAL_DEADLINE_MS",
                DEFAULT_SCHEDULER_CRITICAL_DEADLINE_MS,
                1,
                MAX_SCHEDULER_DEADLINE_MS,
            )?,
        )
    }

    fn development() -> GatewayResult<Self> {
        Self::new(
            usize::try_from(DEFAULT_SCHEDULER_MAX_SUBSCRIBERS).map_err(|source| {
                GatewayError::with_source(
                    "invalid built-in scheduler subscriber limit",
                    Box::new(source),
                )
                .boxed()
            })?,
            usize::try_from(DEFAULT_SCHEDULER_QUEUE_OBJECTS).map_err(|source| {
                GatewayError::with_source(
                    "invalid built-in scheduler object limit",
                    Box::new(source),
                )
                .boxed()
            })?,
            usize::try_from(DEFAULT_SCHEDULER_QUEUE_BYTES).map_err(|source| {
                GatewayError::with_source("invalid built-in scheduler byte limit", Box::new(source))
                    .boxed()
            })?,
            DEFAULT_SCHEDULER_DELTA_DEADLINE_MS,
            DEFAULT_SCHEDULER_RANDOM_ACCESS_DEADLINE_MS,
            DEFAULT_SCHEDULER_CRITICAL_DEADLINE_MS,
        )
    }

    fn new(
        max_subscribers: usize,
        queue_objects: usize,
        queue_bytes: usize,
        delta_deadline_ms: u64,
        random_access_deadline_ms: u64,
        critical_deadline_ms: u64,
    ) -> GatewayResult<Self> {
        if delta_deadline_ms > random_access_deadline_ms
            || random_access_deadline_ms > critical_deadline_ms
        {
            return Err(GatewayError::new(
                "scheduler deadlines must satisfy delta <= random_access <= critical",
            )
            .boxed());
        }
        Ok(Self {
            max_subscribers,
            queue_objects,
            queue_bytes,
            delta_deadline: Duration::from_millis(delta_deadline_ms),
            random_access_deadline: Duration::from_millis(random_access_deadline_ms),
            critical_deadline: Duration::from_millis(critical_deadline_ms),
        })
    }
}

impl SupervisorConfig {
    fn from_env() -> GatewayResult<Self> {
        let bind_addr =
            read_string_env("TEREMOQ_SUPERVISOR_BIND_ADDR", DEFAULT_SUPERVISOR_BIND_ADDR)?
                .parse::<SocketAddr>()
                .map_err(|source| {
                    GatewayError::with_source(
                        "TEREMOQ_SUPERVISOR_BIND_ADDR must be an IP socket address",
                        Box::new(source),
                    )
                    .boxed()
                })?;
        let input_preview_url = optional_url_env(
            "TEREMOQ_SUPERVISOR_INPUT_PREVIEW_URL",
            DEFAULT_SUPERVISOR_INPUT_PREVIEW_URL,
        )?;
        let moq_fingerprint_path = optional_path_env(
            "TEREMOQ_SUPERVISOR_MOQ_FINGERPRINT_PATH",
            DEFAULT_SUPERVISOR_MOQ_FINGERPRINT_PATH,
        )?;
        Self::validate(bind_addr, input_preview_url, moq_fingerprint_path)
    }

    fn development() -> GatewayResult<Self> {
        let bind_addr = DEFAULT_SUPERVISOR_BIND_ADDR
            .parse::<SocketAddr>()
            .map_err(|source| {
                GatewayError::with_source(
                    "invalid built-in supervisor bind address",
                    Box::new(source),
                )
                .boxed()
            })?;
        let input_preview_url = Some(Url::parse(DEFAULT_SUPERVISOR_INPUT_PREVIEW_URL).map_err(
            |source| {
                GatewayError::with_source(
                    "invalid built-in supervisor input preview URL",
                    Box::new(source),
                )
                .boxed()
            },
        )?);
        Self::validate(
            bind_addr,
            input_preview_url,
            Some(PathBuf::from(DEFAULT_SUPERVISOR_MOQ_FINGERPRINT_PATH)),
        )
    }

    fn validate(
        bind_addr: SocketAddr,
        input_preview_url: Option<Url>,
        moq_fingerprint_path: Option<PathBuf>,
    ) -> GatewayResult<Self> {
        if !bind_addr.ip().is_loopback() {
            return Err(GatewayError::new(
                "TEREMOQ_SUPERVISOR_BIND_ADDR must use loopback in the PoC",
            )
            .boxed());
        }
        if bind_addr.port() == 0 {
            return Err(
                GatewayError::new("TEREMOQ_SUPERVISOR_BIND_ADDR port must not be zero").boxed(),
            );
        }
        if let Some(url) = input_preview_url.as_ref() {
            validate_local_preview_url(url)?;
        }
        if moq_fingerprint_path
            .as_ref()
            .is_some_and(|path| path.as_os_str().is_empty())
        {
            return Err(GatewayError::new(
                "TEREMOQ_SUPERVISOR_MOQ_FINGERPRINT_PATH must not be empty when enabled",
            )
            .boxed());
        }
        Ok(Self {
            bind_addr,
            input_preview_url,
            moq_fingerprint_path,
        })
    }
}

impl MediaConfig {
    fn from_env() -> GatewayResult<Self> {
        Ok(Self {
            input_queue_bytes: bounded_usize_env(
                "TEREMOQ_MEDIA_INPUT_QUEUE_BYTES",
                DEFAULT_MEDIA_INPUT_QUEUE_BYTES,
                188,
                MAX_MEDIA_QUEUE_BYTES,
            )?,
            output_queue_objects: bounded_usize_env(
                "TEREMOQ_MEDIA_OUTPUT_QUEUE_OBJECTS",
                DEFAULT_MEDIA_OUTPUT_QUEUE_OBJECTS,
                1,
                MAX_MEDIA_OUTPUT_QUEUE_OBJECTS,
            )?,
            max_object_bytes: bounded_usize_env(
                "TEREMOQ_MEDIA_MAX_OBJECT_BYTES",
                DEFAULT_MEDIA_MAX_OBJECT_BYTES,
                188,
                MAX_MEDIA_OBJECT_BYTES,
            )?,
            session_idle_timeout: Duration::from_millis(bounded_u64_env(
                "TEREMOQ_MEDIA_SESSION_IDLE_TIMEOUT_MS",
                DEFAULT_MEDIA_SESSION_IDLE_TIMEOUT_MS,
                1_000,
                300_000,
            )?),
        })
    }

    fn development() -> GatewayResult<Self> {
        Ok(Self {
            input_queue_bytes: usize::try_from(DEFAULT_MEDIA_INPUT_QUEUE_BYTES).map_err(
                |source| {
                    GatewayError::with_source(
                        "invalid built-in media input queue limit",
                        Box::new(source),
                    )
                    .boxed()
                },
            )?,
            output_queue_objects: usize::try_from(DEFAULT_MEDIA_OUTPUT_QUEUE_OBJECTS).map_err(
                |source| {
                    GatewayError::with_source(
                        "invalid built-in media output queue limit",
                        Box::new(source),
                    )
                    .boxed()
                },
            )?,
            max_object_bytes: usize::try_from(DEFAULT_MEDIA_MAX_OBJECT_BYTES).map_err(
                |source| {
                    GatewayError::with_source(
                        "invalid built-in media object limit",
                        Box::new(source),
                    )
                    .boxed()
                },
            )?,
            session_idle_timeout: Duration::from_millis(DEFAULT_MEDIA_SESSION_IDLE_TIMEOUT_MS),
        })
    }
}

impl SrtConfig {
    fn from_env() -> GatewayResult<Self> {
        let bind_addr = read_string_env("TEREMOQ_SRT_BIND_ADDR", DEFAULT_SRT_BIND_ADDR)?
            .parse::<SocketAddr>()
            .map_err(|source| {
                GatewayError::with_source(
                    "TEREMOQ_SRT_BIND_ADDR must be an IP socket address",
                    Box::new(source),
                )
                .boxed()
            })?;
        if bind_addr.port() == 0 {
            return Err(GatewayError::new("TEREMOQ_SRT_BIND_ADDR port must not be zero").boxed());
        }

        let passphrase = read_optional_env("TEREMOQ_SRT_PASSPHRASE")?;
        validate_passphrase(passphrase.as_deref())?;

        let max_sessions = bounded_usize_env(
            "TEREMOQ_SRT_MAX_SESSIONS",
            DEFAULT_SRT_MAX_SESSIONS,
            1,
            MAX_SRT_SESSIONS,
        )?;
        let ingress_queue_capacity = bounded_usize_env(
            "TEREMOQ_SRT_INGRESS_QUEUE_CAPACITY",
            DEFAULT_SRT_INGRESS_QUEUE,
            1,
            MAX_SRT_QUEUE_CAPACITY,
        )?;
        let egress_queue_capacity = bounded_usize_env(
            "TEREMOQ_SRT_EGRESS_QUEUE_CAPACITY",
            DEFAULT_SRT_EGRESS_QUEUE,
            1,
            MAX_SRT_QUEUE_CAPACITY,
        )?;
        let tsbpd_delay_raw = bounded_u64_env(
            "TEREMOQ_SRT_TSBPD_DELAY_MS",
            DEFAULT_SRT_TSBPD_DELAY_MS,
            20,
            u64::from(u16::MAX),
        )?;
        let tsbpd_delay_ms = u16::try_from(tsbpd_delay_raw).map_err(|source| {
            GatewayError::with_source("SRT TSBPD delay cannot fit u16", Box::new(source)).boxed()
        })?;
        let stats_interval_secs = bounded_u64_env(
            "TEREMOQ_SRT_STATS_INTERVAL_SECS",
            DEFAULT_SRT_STATS_INTERVAL_SECS,
            1,
            300,
        )?;
        let routes_json = read_string_env("TEREMOQ_ROUTES_JSON", DEFAULT_ROUTES_JSON)?;
        if routes_json.len() > MAX_ROUTES_JSON_BYTES {
            return Err(GatewayError::new(format!(
                "TEREMOQ_ROUTES_JSON exceeds {MAX_ROUTES_JSON_BYTES} bytes"
            ))
            .boxed());
        }

        Ok(Self {
            bind_addr,
            passphrase,
            max_sessions,
            ingress_queue_capacity,
            egress_queue_capacity,
            tsbpd_delay_ms,
            stats_interval: Duration::from_secs(stats_interval_secs),
            routes: RouteTable::from_json(&routes_json)?,
        })
    }

    fn development() -> GatewayResult<Self> {
        Ok(Self {
            bind_addr: DEFAULT_SRT_BIND_ADDR
                .parse::<SocketAddr>()
                .map_err(|source| {
                    GatewayError::with_source("invalid built-in SRT bind address", Box::new(source))
                        .boxed()
                })?,
            passphrase: None,
            max_sessions: usize::try_from(DEFAULT_SRT_MAX_SESSIONS).map_err(|source| {
                GatewayError::with_source("invalid built-in SRT session limit", Box::new(source))
                    .boxed()
            })?,
            ingress_queue_capacity: usize::try_from(DEFAULT_SRT_INGRESS_QUEUE).map_err(
                |source| {
                    GatewayError::with_source(
                        "invalid built-in SRT ingress capacity",
                        Box::new(source),
                    )
                    .boxed()
                },
            )?,
            egress_queue_capacity: usize::try_from(DEFAULT_SRT_EGRESS_QUEUE).map_err(|source| {
                GatewayError::with_source("invalid built-in SRT egress capacity", Box::new(source))
                    .boxed()
            })?,
            tsbpd_delay_ms: u16::try_from(DEFAULT_SRT_TSBPD_DELAY_MS).map_err(|source| {
                GatewayError::with_source("invalid built-in SRT TSBPD delay", Box::new(source))
                    .boxed()
            })?,
            stats_interval: Duration::from_secs(DEFAULT_SRT_STATS_INTERVAL_SECS),
            routes: RouteTable::from_json(DEFAULT_ROUTES_JSON)?,
        })
    }
}

fn read_string_env(name: &str, default: &str) -> GatewayResult<String> {
    match env::var(name) {
        Ok(value) => Ok(value),
        Err(env::VarError::NotPresent) => Ok(default.to_owned()),
        Err(source) => Err(GatewayError::with_source(
            format!("{name} is not valid Unicode"),
            Box::new(source),
        )
        .boxed()),
    }
}

fn read_optional_env(name: &str) -> GatewayResult<Option<String>> {
    match env::var(name) {
        Ok(value) => Ok(Some(value)),
        Err(env::VarError::NotPresent) => Ok(None),
        Err(source) => Err(GatewayError::with_source(
            format!("{name} is not valid Unicode"),
            Box::new(source),
        )
        .boxed()),
    }
}

fn read_required_path_env(name: &str, missing_reason: &'static str) -> GatewayResult<PathBuf> {
    match read_optional_env(name)? {
        Some(value) if !value.is_empty() => Ok(PathBuf::from(value)),
        Some(_) | None => Err(GatewayError::new(missing_reason).boxed()),
    }
}

fn optional_url_env(name: &str, default: &str) -> GatewayResult<Option<Url>> {
    let raw = read_string_env(name, default)?;
    if raw.is_empty() {
        return Ok(None);
    }
    Url::parse(&raw).map(Some).map_err(|source| {
        GatewayError::with_source(format!("{name} must be a valid URL"), Box::new(source)).boxed()
    })
}

fn optional_path_env(name: &str, default: &str) -> GatewayResult<Option<PathBuf>> {
    let raw = read_string_env(name, default)?;
    Ok((!raw.is_empty()).then(|| PathBuf::from(raw)))
}

fn validate_local_preview_url(url: &Url) -> GatewayResult<()> {
    if !matches!(url.scheme(), "http" | "https")
        || url.host_str().is_none()
        || url.fragment().is_some()
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Err(GatewayError::new(
            "TEREMOQ_SUPERVISOR_INPUT_PREVIEW_URL must be an HTTP(S) URL without credentials or fragment",
        )
        .boxed());
    }
    let host = url.host_str().unwrap_or_default();
    let loopback = host.eq_ignore_ascii_case("localhost")
        || host
            .parse::<std::net::IpAddr>()
            .is_ok_and(|address| address.is_loopback());
    if !loopback {
        return Err(GatewayError::new(
            "TEREMOQ_SUPERVISOR_INPUT_PREVIEW_URL must use a loopback host in the PoC",
        )
        .boxed());
    }
    Ok(())
}

fn validate_passphrase(passphrase: Option<&str>) -> GatewayResult<()> {
    if let Some(passphrase) = passphrase
        && !(MIN_SRT_PASSPHRASE_BYTES..=MAX_SRT_PASSPHRASE_BYTES).contains(&passphrase.len())
    {
        return Err(GatewayError::new(format!(
            "TEREMOQ_SRT_PASSPHRASE must contain {MIN_SRT_PASSPHRASE_BYTES}..={MAX_SRT_PASSPHRASE_BYTES} bytes"
        ))
        .boxed());
    }
    Ok(())
}

fn parse_moq_url(raw: &str) -> GatewayResult<Url> {
    let url = Url::parse(raw).map_err(|source| {
        GatewayError::with_source(
            "TEREMOQ_MOQ_RELAY_URL must be a valid URL",
            Box::new(source),
        )
        .boxed()
    })?;
    if !matches!(url.scheme(), "https" | "moqt") {
        return Err(GatewayError::new(
            "TEREMOQ_MOQ_RELAY_URL must use https:// (WebTransport) or moqt:// (raw QUIC)",
        )
        .boxed());
    }
    if url.host().is_none() || url.fragment().is_some() {
        return Err(GatewayError::new(
            "TEREMOQ_MOQ_RELAY_URL requires a host and must not contain a fragment",
        )
        .boxed());
    }
    if url.username() != "" || url.password().is_some() || url.query().is_some() {
        return Err(GatewayError::new(
            "TEREMOQ_MOQ_RELAY_URL must not embed credentials or query parameters",
        )
        .boxed());
    }
    Ok(url)
}

fn validate_moq_namespace(namespace: &str) -> GatewayResult<()> {
    let valid = !namespace.is_empty()
        && namespace.len() <= MAX_MOQ_NAMESPACE_BYTES
        && namespace.split('/').all(|segment| {
            !segment.is_empty()
                && segment != "."
                && segment != ".."
                && segment
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
        });
    if valid {
        Ok(())
    } else {
        Err(GatewayError::new(
            "TEREMOQ_MOQ_NAMESPACE must be a non-empty ASCII path without empty or dot segments",
        )
        .boxed())
    }
}

fn parse_bool_env(name: &str, default: bool) -> GatewayResult<bool> {
    match env::var(name) {
        Ok(value) if value.eq_ignore_ascii_case("true") || value == "1" => Ok(true),
        Ok(value) if value.eq_ignore_ascii_case("false") || value == "0" => Ok(false),
        Ok(_) => Err(GatewayError::new(format!("{name} must be true, false, 1 or 0")).boxed()),
        Err(env::VarError::NotPresent) => Ok(default),
        Err(source) => Err(GatewayError::with_source(
            format!("{name} is not valid Unicode"),
            Box::new(source),
        )
        .boxed()),
    }
}

fn relay_origin(url: &Url) -> String {
    let host = url.host_str().unwrap_or("invalid-host");
    let port = url
        .port()
        .map_or_else(String::new, |port| format!(":{port}"));
    format!("{}://{host}{port}", url.scheme())
}

fn bounded_usize_env(name: &str, default: u64, min: u64, max: u64) -> GatewayResult<usize> {
    let value = bounded_u64_env(name, default, min, max)?;
    usize::try_from(value).map_err(|source| {
        GatewayError::with_source(format!("{name} does not fit usize"), Box::new(source)).boxed()
    })
}

fn bounded_u64_env(name: &str, default: u64, min: u64, max: u64) -> GatewayResult<u64> {
    let value = parse_u64_env(name, default)?;
    if (min..=max).contains(&value) {
        Ok(value)
    } else {
        Err(GatewayError::new(format!("{name} must be between {min} and {max}")).boxed())
    }
}

fn parse_u64_env(name: &str, default: u64) -> GatewayResult<u64> {
    match env::var(name) {
        Ok(raw) => raw.parse::<u64>().map_err(|source| {
            GatewayError::with_source(
                format!("{name} must be an unsigned integer"),
                Box::new(source),
            )
            .boxed()
        }),
        Err(env::VarError::NotPresent) => Ok(default),
        Err(source) => Err(GatewayError::with_source(
            format!("{name} is not valid Unicode"),
            Box::new(source),
        )
        .boxed()),
    }
}

fn validate_label(name: &str, value: &str, max_len: usize) -> GatewayResult<()> {
    let valid = !value.is_empty()
        && value.len() <= max_len
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'));

    if valid {
        Ok(())
    } else {
        Err(GatewayError::new(format!(
            "{name} must contain 1..={max_len} ASCII letters, digits, '.', '_' or '-'"
        ))
        .boxed())
    }
}

fn duration_millis_u64(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).map_or(u64::MAX, std::convert::identity)
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::{GatewayConfig, SchedulerConfig, SupervisorConfig};
    use url::Url;

    #[test]
    fn accepts_bounded_configuration() {
        let result = GatewayConfig::new("edge-madrid-1", "gateway_rs=debug,info", 2_000);
        assert!(result.is_ok());
    }

    #[test]
    fn rejects_invalid_instance_id() {
        let result = GatewayConfig::new("edge madrid", "info", 2_000);
        assert!(result.is_err());
    }

    #[test]
    fn rejects_unbounded_shutdown_timeout() {
        let result = GatewayConfig::new("edge-1", "info", 30_001);
        assert!(result.is_err());
    }

    #[test]
    fn rejects_invalid_log_filter() {
        let result = GatewayConfig::new("edge-1", "gateway_rs=[", 2_000);
        assert!(result.is_err());
    }

    #[test]
    fn supervisor_accepts_only_loopback_with_a_nonzero_port() {
        let loopback = "127.0.0.1:9080".parse();
        let remote = "0.0.0.0:9080".parse();
        let zero_port = "127.0.0.1:0".parse();

        let validate = |address| {
            SupervisorConfig::validate(
                address,
                Url::parse("http://127.0.0.1:8889/input").ok(),
                Some(PathBuf::from("fingerprint")),
            )
        };

        assert!(loopback.is_ok_and(|address| validate(address).is_ok()));
        assert!(remote.is_ok_and(|address| validate(address).is_err()));
        assert!(zero_port.is_ok_and(|address| validate(address).is_err()));
    }

    #[test]
    fn supervisor_rejects_remote_preview_observers() {
        let preview = Url::parse("https://example.com/input");
        let bind = "127.0.0.1:9080".parse();
        assert!(preview.is_ok_and(|preview| {
            bind.is_ok_and(|bind| SupervisorConfig::validate(bind, Some(preview), None).is_err())
        }));
    }

    #[test]
    fn scheduler_rejects_inverted_deadlines() {
        assert!(SchedulerConfig::new(1, 16, 188, 200, 100, 500).is_err());
        assert!(SchedulerConfig::new(1, 16, 188, 100, 200, 500).is_ok());
    }

    #[test]
    fn moq_debug_redacts_all_private_paths() -> crate::error::GatewayResult<()> {
        let mut config = GatewayConfig::new("debug-test", "info", 1_000)?.moq;
        config.tls_root = PathBuf::from("/private/pki/root-secret-name.pem");
        config.tls_client_cert = PathBuf::from("/private/pki/gateway-secret-name.pem");
        config.tls_client_key = PathBuf::from("/private/pki/key-secret-name.pem");

        let debug = format!("{config:?}");
        assert!(debug.contains("tls_root_configured: true"));
        assert!(debug.contains("mtls_identity_configured: true"));
        assert!(!debug.contains("/private"));
        assert!(!debug.contains("secret-name"));
        Ok(())
    }
}
