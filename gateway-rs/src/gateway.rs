//! Composición del proceso, la ingesta SRT real y los adaptadores pendientes.

use std::{future::Future, sync::Arc};

use tokio_util::sync::CancellationToken;

use crate::{
    adapters::{moq::run_moq_publisher, srt::ShiguredoSrtIngress},
    config::GatewayConfig,
    error::{GatewayError, GatewayResult},
    ingest::SrtIngress,
    lifecycle::{CriticalTask, ShutdownReason, supervise},
    media::{GstreamerMediaDemux, MediaDemux, maintenance_interval},
    observability::EventLogger,
    scheduler::SubscriberScheduler,
    security::mtls,
    supervisor::{SignalMonitor, run_web_supervisor},
};

/// Proceso Gateway compuesto con fronteras sustituibles.
pub struct Gateway {
    config: GatewayConfig,
    logger: EventLogger,
}

impl Gateway {
    /// Construye el proceso con configuración ya validada.
    #[must_use]
    pub fn new(config: GatewayConfig, logger: EventLogger) -> Self {
        Self { config, logger }
    }

    /// Ejecuta la ingesta SRT y la publicación `MoQT` reales hasta terminar.
    ///
    /// # Errors
    ///
    /// Devuelve error si falla una task crítica, el manejador de señales o el
    /// cierre coordinado excede su deadline.
    pub async fn run_until<S>(self, shutdown: S) -> GatewayResult<()>
    where
        S: Future<Output = GatewayResult<ShutdownReason>> + Send,
    {
        let cancellation = CancellationToken::new();
        let endpoint = match mtls::prepare_endpoint(&self.config.moq).await {
            Ok(endpoint) => endpoint,
            Err(source) => {
                self.logger
                    .moq_mtls_configuration_failed(source.reason().as_str());
                return Err(Box::new(source));
            }
        };
        self.logger.moq_mtls_ready("tls1.3", "ring");
        self.logger
            .gateway_started(duration_millis_u64(self.config.shutdown_timeout));
        let monitor = Arc::new(SignalMonitor::new(self.config.srt.max_sessions));
        let scheduler = Arc::new(SubscriberScheduler::new(
            self.config.scheduler.clone(),
            self.logger.clone(),
        ));
        monitor.record_scheduler(scheduler.snapshot(), None);
        let demux = GstreamerMediaDemux::new(
            self.config.media.clone(),
            self.config.srt.max_sessions,
            self.config.srt.routes.clone(),
            self.logger.clone(),
        )?;
        let binding = ShiguredoSrtIngress::bind(self.config.srt.clone(), self.logger.clone()).await;
        let (ingress, listener, egress) = match binding {
            Ok(parts) => parts,
            Err(source) => {
                self.logger
                    .critical_task_failed("srt_listener_bind", source.as_ref());
                return Err(source);
            }
        };
        let ingress: Box<dyn SrtIngress> = Box::new(ingress);
        let ingress_token = cancellation.child_token();
        let listener_token = cancellation.child_token();
        let distribution_token = cancellation.child_token();
        let supervisor_token = cancellation.child_token();
        let tasks = vec![
            CriticalTask::new(
                "media_pipeline",
                Box::pin(run_media_pipeline(
                    ingress,
                    Box::new(demux),
                    Arc::clone(&scheduler),
                    Arc::clone(&monitor),
                    ingress_token,
                )),
            ),
            CriticalTask::new("srt_listener", Box::pin(listener.run(listener_token))),
            CriticalTask::new("srt_udp_egress", Box::pin(egress.run())),
            CriticalTask::new(
                "moq_publisher",
                Box::pin(run_moq_publisher(
                    self.config.moq.clone(),
                    endpoint,
                    Arc::clone(&scheduler),
                    Arc::clone(&monitor),
                    distribution_token,
                    self.logger.clone(),
                )),
            ),
            CriticalTask::new(
                "web_supervisor",
                Box::pin(run_web_supervisor(
                    self.config.supervisor.clone(),
                    self.config.moq.clone(),
                    monitor,
                    supervisor_token,
                    self.logger.clone(),
                )),
            ),
        ];

        supervise(
            tasks,
            cancellation,
            self.config.shutdown_timeout,
            self.logger,
            shutdown,
        )
        .await
    }
}

async fn run_media_pipeline(
    mut ingress: Box<dyn SrtIngress>,
    mut demux: Box<dyn MediaDemux>,
    scheduler: Arc<SubscriberScheduler>,
    monitor: Arc<SignalMonitor>,
    cancellation: CancellationToken,
) -> GatewayResult<()> {
    let mut maintenance = tokio::time::interval(maintenance_interval());
    maintenance.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            biased;
            () = cancellation.cancelled() => return demux.shutdown(),
            packet = ingress.receive() => match packet {
                Ok(Some(packet)) => {
                    monitor.record_ingest(&packet);
                    demux.push(packet)?;
                },
                Ok(None) => {
                    return Err(GatewayError::new(
                        "SRT ingress closed before cancellation",
                    ).boxed());
                }
                Err(source) => {
                    return Err(GatewayError::with_source(
                        "SRT ingress failed",
                        source,
                    ).boxed());
                }
            },
            object = demux.receive() => match object? {
                Some(object) => {
                    monitor.record_object(&object);
                    let now = tokio::time::Instant::now();
                    let _report = scheduler.fanout(object, now)?;
                    monitor.record_scheduler(scheduler.snapshot(), Some(now));
                },
                None => return Err(GatewayError::new(
                    "media output closed before cancellation",
                ).boxed()),
            },
            now = maintenance.tick() => demux.maintain(now),
        }
    }
}

fn duration_millis_u64(duration: std::time::Duration) -> u64 {
    u64::try_from(duration.as_millis()).map_or(u64::MAX, std::convert::identity)
}

#[cfg(test)]
mod tests {
    use std::{fs, path::PathBuf};

    use rcgen::generate_simple_self_signed;

    use super::Gateway;
    use crate::{
        config::GatewayConfig, error::GatewayResult, lifecycle::ShutdownReason,
        observability::EventLogger,
    };

    #[tokio::test(start_paused = true)]
    async fn composed_adapters_stop_cleanly() -> GatewayResult<()> {
        let mut config = GatewayConfig::new("test-gateway", "info", 1_000)?;
        let identity = TestIdentity::generate()?;
        config.srt.bind_addr = "127.0.0.1:0".parse()?;
        config.moq.bind_addr = "127.0.0.1:0".parse()?;
        config.moq.tls_root = identity.cert.clone();
        config.moq.tls_client_cert = identity.cert.clone();
        config.moq.tls_client_key = identity.key.clone();
        config.supervisor.bind_addr = "127.0.0.1:0".parse()?;
        let logger = EventLogger::new(config.instance_id.clone());

        Gateway::new(config, logger)
            .run_until(async { Ok(ShutdownReason::Internal) })
            .await?;

        Ok(())
    }

    struct TestIdentity {
        directory: PathBuf,
        cert: PathBuf,
        key: PathBuf,
    }

    impl TestIdentity {
        fn generate() -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
            let mut random = [0_u8; 8];
            getrandom::fill(&mut random)?;
            let directory = std::env::temp_dir().join(format!(
                "teremoq-gateway-test-{}-{}",
                std::process::id(),
                u64::from_le_bytes(random)
            ));
            fs::create_dir(&directory)?;
            let identity = generate_simple_self_signed(vec!["gateway.test".to_owned()])?;
            let cert = directory.join("gateway-cert.pem");
            let key = directory.join("gateway-key.pem");
            fs::write(&cert, identity.cert.pem())?;
            fs::write(&key, identity.signing_key.serialize_pem())?;
            set_private_permissions(&key)?;
            Ok(Self {
                directory,
                cert,
                key,
            })
        }
    }

    impl Drop for TestIdentity {
        fn drop(&mut self) {
            let _result = fs::remove_dir_all(&self.directory);
        }
    }

    #[cfg(unix)]
    fn set_private_permissions(path: &std::path::Path) -> std::io::Result<()> {
        use std::os::unix::fs::PermissionsExt;

        fs::set_permissions(path, fs::Permissions::from_mode(0o600))
    }

    #[cfg(not(unix))]
    fn set_private_permissions(_path: &std::path::Path) -> std::io::Result<()> {
        Ok(())
    }
}
