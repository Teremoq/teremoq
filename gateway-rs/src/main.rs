//! Punto de entrada asíncrono del Gateway.

use gateway_rs::{
    config::GatewayConfig,
    error::GatewayResult,
    gateway::Gateway,
    lifecycle::shutdown_signal,
    observability::{EventLogger, init_json_logging},
};

#[tokio::main(flavor = "multi_thread")]
async fn main() -> GatewayResult<()> {
    let config = GatewayConfig::from_env()?;
    init_json_logging(&config.log_filter)?;

    let logger = EventLogger::new(config.instance_id.clone());
    let gateway = Gateway::new(config, logger);
    gateway.run_until(shutdown_signal()).await
}
