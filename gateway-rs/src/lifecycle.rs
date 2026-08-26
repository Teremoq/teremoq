//! Supervisión de tasks críticas y apagado coordinado.

use std::{future::Future, time::Duration};

use tokio::{signal, task::JoinSet, time};
use tokio_util::sync::CancellationToken;

use crate::{
    BoxFuture,
    error::{GatewayError, GatewayResult},
    observability::EventLogger,
};

/// Origen estable de una solicitud de apagado.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ShutdownReason {
    /// Interrupción del terminal.
    CtrlC,
    /// Señal POSIX de terminación.
    Terminate,
    /// Origen interno usado por tests o un supervisor futuro.
    Internal,
}

impl ShutdownReason {
    const fn as_str(self) -> &'static str {
        match self {
            Self::CtrlC => "ctrl_c",
            Self::Terminate => "terminate",
            Self::Internal => "internal",
        }
    }
}

/// Task crítica con nombre de baja cardinalidad.
pub(crate) struct CriticalTask {
    name: &'static str,
    future: BoxFuture<'static, GatewayResult<()>>,
}

impl CriticalTask {
    pub(crate) fn new(name: &'static str, future: BoxFuture<'static, GatewayResult<()>>) -> Self {
        Self { name, future }
    }
}

/// Ejecuta tasks críticas hasta una señal o hasta el primer fallo.
pub(crate) async fn supervise<S>(
    tasks: Vec<CriticalTask>,
    cancellation: CancellationToken,
    shutdown_timeout: Duration,
    logger: EventLogger,
    shutdown: S,
) -> GatewayResult<()>
where
    S: Future<Output = GatewayResult<ShutdownReason>> + Send,
{
    if tasks.is_empty() {
        return Err(GatewayError::new("supervisor requires at least one critical task").boxed());
    }

    let mut join_set = JoinSet::new();
    for task in tasks {
        logger.task_started(task.name);
        join_set.spawn(async move { (task.name, task.future.await) });
    }

    tokio::pin!(shutdown);
    let primary_error = tokio::select! {
        signal_result = &mut shutdown => match signal_result {
            Ok(reason) => {
                logger.shutdown_requested(reason.as_str());
                None
            }
            Err(source) => {
                logger.critical_task_failed("signal_handler", source.as_ref());
                Some(GatewayError::with_source("shutdown signal handler failed", source).boxed())
            }
        },
        task_result = join_set.join_next() => {
            Some(unexpected_task_exit(task_result, &logger))
        }
    };

    cancellation.cancel();
    let cleanup_result = drain_tasks(&mut join_set, shutdown_timeout, &logger).await;
    logger.gateway_stopped();

    match (primary_error, cleanup_result) {
        (Some(error), _) | (None, Err(error)) => Err(error),
        (None, Ok(())) => Ok(()),
    }
}

fn unexpected_task_exit(
    result: Option<Result<(&'static str, GatewayResult<()>), tokio::task::JoinError>>,
    logger: &EventLogger,
) -> crate::error::BoxError {
    match result {
        Some(Ok((name, Ok(())))) => {
            let error = GatewayError::new(format!("critical task '{name}' stopped unexpectedly"));
            logger.critical_task_failed(name, &error);
            error.boxed()
        }
        Some(Ok((name, Err(source)))) => {
            logger.critical_task_failed(name, source.as_ref());
            GatewayError::with_source(format!("critical task '{name}' failed"), source).boxed()
        }
        Some(Err(source)) => {
            logger.critical_task_failed("unknown", &source);
            GatewayError::with_source("critical task could not be joined", Box::new(source)).boxed()
        }
        None => GatewayError::new("critical task set became empty unexpectedly").boxed(),
    }
}

async fn drain_tasks(
    join_set: &mut JoinSet<(&'static str, GatewayResult<()>)>,
    shutdown_timeout: Duration,
    logger: &EventLogger,
) -> GatewayResult<()> {
    let deadline = time::sleep(shutdown_timeout);
    tokio::pin!(deadline);
    let mut cleanup_error = None;

    while !join_set.is_empty() {
        tokio::select! {
            joined = join_set.join_next() => {
                match joined {
                    Some(Ok((name, Ok(())))) => logger.task_stopped(name),
                    Some(Ok((name, Err(source)))) => {
                        logger.critical_task_failed(name, source.as_ref());
                        if cleanup_error.is_none() {
                            cleanup_error = Some(GatewayError::with_source(
                                format!("critical task '{name}' failed during shutdown"),
                                source,
                            ).boxed());
                        }
                    }
                    Some(Err(source)) => {
                        logger.critical_task_failed("unknown", &source);
                        if cleanup_error.is_none() {
                            cleanup_error = Some(GatewayError::with_source(
                                "critical task could not be joined during shutdown",
                                Box::new(source),
                            ).boxed());
                        }
                    }
                    None => break,
                }
            }
            () = &mut deadline => {
                let pending_tasks = join_set.len();
                join_set.abort_all();
                logger.shutdown_deadline_exceeded(
                    pending_tasks,
                    duration_millis_u64(shutdown_timeout),
                );
                return Err(GatewayError::new("critical tasks exceeded shutdown deadline").boxed());
            }
        }
    }

    match cleanup_error {
        Some(error) => Err(error),
        None => Ok(()),
    }
}

fn duration_millis_u64(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).map_or(u64::MAX, std::convert::identity)
}

/// Espera Ctrl-C o SIGTERM sin ocultar errores de registro de señales.
///
/// # Errors
///
/// Devuelve error si el sistema operativo rechaza el registro del manejador o
/// cierra inesperadamente el stream de señales.
pub async fn shutdown_signal() -> GatewayResult<ShutdownReason> {
    #[cfg(unix)]
    {
        let mut terminate =
            signal::unix::signal(signal::unix::SignalKind::terminate()).map_err(|source| {
                GatewayError::with_source("failed to register SIGTERM handler", Box::new(source))
                    .boxed()
            })?;

        tokio::select! {
            result = signal::ctrl_c() => result
                .map(|()| ShutdownReason::CtrlC)
                .map_err(|source| GatewayError::with_source(
                    "failed to listen for Ctrl-C",
                    Box::new(source),
                ).boxed()),
            signal = terminate.recv() => signal
                .map(|()| ShutdownReason::Terminate)
                .ok_or_else(|| GatewayError::new("SIGTERM stream closed unexpectedly").boxed()),
        }
    }

    #[cfg(not(unix))]
    {
        signal::ctrl_c()
            .await
            .map(|()| ShutdownReason::CtrlC)
            .map_err(|source| {
                GatewayError::with_source("failed to listen for Ctrl-C", Box::new(source)).boxed()
            })
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    };

    use tokio_util::sync::CancellationToken;

    use super::{CriticalTask, ShutdownReason, supervise};
    use crate::{
        error::{GatewayError, GatewayResult},
        observability::EventLogger,
    };

    fn logger() -> EventLogger {
        EventLogger::new("test-instance".to_owned())
    }

    #[tokio::test(start_paused = true)]
    async fn shutdown_signal_propagates_cancellation() {
        let cancellation = CancellationToken::new();
        let task_token = cancellation.child_token();
        let stopped = Arc::new(AtomicBool::new(false));
        let task_stopped = Arc::clone(&stopped);
        let task = CriticalTask::new(
            "test_task",
            Box::pin(async move {
                task_token.cancelled().await;
                task_stopped.store(true, Ordering::SeqCst);
                Ok(())
            }),
        );

        let result = supervise(
            vec![task],
            cancellation,
            std::time::Duration::from_secs(1),
            logger(),
            async { Ok(ShutdownReason::Internal) },
        )
        .await;

        assert!(result.is_ok());
        assert!(stopped.load(Ordering::SeqCst));
    }

    #[tokio::test(start_paused = true)]
    async fn critical_failure_cancels_sibling_and_is_propagated() {
        let cancellation = CancellationToken::new();
        let sibling_token = cancellation.child_token();
        let sibling_stopped = Arc::new(AtomicBool::new(false));
        let observed_stop = Arc::clone(&sibling_stopped);

        let failing = CriticalTask::new(
            "failing_task",
            Box::pin(async {
                Err::<(), _>(GatewayError::new("injected critical failure").boxed())
            }),
        );
        let sibling = CriticalTask::new(
            "sibling_task",
            Box::pin(async move {
                sibling_token.cancelled().await;
                observed_stop.store(true, Ordering::SeqCst);
                Ok(())
            }),
        );
        let pending_signal = std::future::pending::<GatewayResult<ShutdownReason>>();

        let result = supervise(
            vec![failing, sibling],
            cancellation,
            std::time::Duration::from_secs(1),
            logger(),
            pending_signal,
        )
        .await;

        assert!(result.is_err());
        assert!(sibling_stopped.load(Ordering::SeqCst));
    }

    #[tokio::test(start_paused = true)]
    async fn unexpected_clean_exit_is_a_critical_failure() {
        let cancellation = CancellationToken::new();
        let task = CriticalTask::new("early_exit", Box::pin(async { Ok(()) }));
        let pending_signal = std::future::pending::<GatewayResult<ShutdownReason>>();

        let result = supervise(
            vec![task],
            cancellation,
            std::time::Duration::from_secs(1),
            logger(),
            pending_signal,
        )
        .await;

        assert!(result.is_err());
    }

    #[tokio::test(start_paused = true)]
    async fn non_cooperative_task_exceeds_shutdown_deadline() {
        let cancellation = CancellationToken::new();
        let task = CriticalTask::new("stuck_task", Box::pin(std::future::pending()));

        let result = supervise(
            vec![task],
            cancellation,
            std::time::Duration::from_millis(100),
            logger(),
            async { Ok(ShutdownReason::Internal) },
        )
        .await;

        assert!(result.is_err());
    }
}
