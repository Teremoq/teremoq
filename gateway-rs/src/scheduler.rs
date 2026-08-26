//! Scheduler acotado e independiente por suscriptor.

use std::{
    collections::{HashMap, VecDeque},
    sync::{
        Arc, Mutex, RwLock,
        atomic::{AtomicU64, AtomicUsize, Ordering},
    },
    time::Duration,
};

use bytes::Bytes;
use tokio::sync::Notify;

use crate::{
    BoxFuture,
    config::SchedulerConfig,
    error::{GatewayError, GatewayResult},
    media::{AccessUnitKind, Codec, Group, MediaObject},
    observability::{CriticalEvictionEvent, EventLogger, ObjectDropEvent},
    routing::TrackId,
};

const MAX_SUBSCRIBER_ID_BYTES: usize = 64;

/// Identidad opaca y estable de una sesión suscriptora.
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct SubscriberId(String);

impl SubscriberId {
    /// Construye una identidad de baja cardinalidad apta para logs.
    ///
    /// # Errors
    ///
    /// Devuelve error si queda vacía, excede 64 bytes o contiene caracteres no
    /// permitidos.
    pub fn new(value: impl Into<String>) -> GatewayResult<Self> {
        let value = value.into();
        let valid = !value.is_empty()
            && value.len() <= MAX_SUBSCRIBER_ID_BYTES
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'));
        if valid {
            Ok(Self(value))
        } else {
            Err(GatewayError::new(
                "subscriber ID must contain 1..=64 ASCII letters, digits, '.', '_' or '-'",
            )
            .boxed())
        }
    }

    /// Devuelve la representación validada.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Prioridad estable aplicada al envío de Objects.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum Priority {
    /// Audio y telemetría; su saturación expulsa al suscriptor.
    Critical = 0,
    /// Punto de acceso aleatorio de vídeo.
    RandomAccess = 1,
    /// Vídeo dependiente y descartable.
    Delta = 2,
}

impl Priority {
    const fn index(self) -> usize {
        self as usize
    }

    /// Devuelve el valor estable usado en observabilidad.
    #[must_use]
    pub const fn value(self) -> u8 {
        self as u8
    }
}

/// Razón estable de descarte local para un suscriptor.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DropReason {
    /// La cola no admite el Object sin superar sus límites.
    QueueBackpressure,
    /// El deadline monotónico expiró antes del envío.
    QueueDeadlineExpired,
    /// Falta el punto de acceso que hace decodificable al Object.
    DependencyNotDecodable,
    /// Un Group más nuevo vuelve obsoleto al pendiente.
    GroupSuperseded,
}

impl DropReason {
    /// Etiqueta estable del contrato JSON.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::QueueBackpressure => "queue_backpressure",
            Self::QueueDeadlineExpired => "queue_deadline_expired",
            Self::DependencyNotDecodable => "dependency_not_decodable",
            Self::GroupSuperseded => "group_superseded",
        }
    }
}

/// Object codificado y clasificado para el futuro publisher `MoQT`.
#[derive(Clone, Debug)]
pub struct ScheduledObject {
    /// Payload inmutable; clonarlo comparte la misma asignación.
    pub payload: Bytes,
    /// Inicialización CMAF compartida para publicación de catálogo MSF.
    pub cmaf_init: Option<Bytes>,
    /// Identidad opaca de la conexión SRT de origen.
    pub connection_id: Arc<str>,
    /// Track lógico.
    pub track: TrackId,
    /// Programa MPEG-TS de origen.
    pub program_number: u16,
    /// PID elemental de origen.
    pub pid: u16,
    /// Códec que permanece comprimido.
    pub codec: Codec,
    /// Group propietario.
    pub group: Group,
    /// Secuencia dentro del Group.
    pub object_id: u64,
    /// Prioridad derivada del Track y del tipo de access unit.
    pub priority: Priority,
    /// PTS conservado para publicación y correlación.
    pub pts_ns: Option<u64>,
    /// DTS conservado para publicación y correlación.
    pub dts_ns: Option<u64>,
    /// Instante monotónico de ingesta conservado para latencia interna.
    pub received_at: tokio::time::Instant,
}

impl TryFrom<MediaObject> for ScheduledObject {
    type Error = crate::error::BoxError;

    fn try_from(object: MediaObject) -> Result<Self, Self::Error> {
        let priority = classify(object.group.track.id, object.kind)?;
        Ok(Self {
            payload: object.payload,
            cmaf_init: object.cmaf_init,
            connection_id: object.connection_id,
            track: object.group.track.id,
            program_number: object.program_number,
            pid: object.pid,
            codec: object.codec,
            group: object.group,
            object_id: object.object_id,
            priority,
            pts_ns: object.pts_ns,
            dts_ns: object.dts_ns,
            received_at: object.received_at,
        })
    }
}

/// Resultado explícito de intentar encolar un Object.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EnqueueOutcome {
    /// El Object quedó aceptado para envío.
    Accepted,
    /// El Object se descartó mediante una política local controlada.
    Dropped,
    /// La sesión debe cerrarse sin afectar a otros suscriptores.
    EvictSubscriber,
}

/// Resultado agregado de distribuir un Object entre suscriptores independientes.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct FanoutReport {
    /// Suscriptores que aceptaron el Object.
    pub accepted: usize,
    /// Suscriptores para los que se descartó el Object entrante.
    pub dropped: usize,
    /// Suscriptores expulsados por presión crítica.
    pub evicted: usize,
}

/// Snapshot lock-free de contadores del scheduler.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct SchedulerSnapshot {
    /// Sesiones actualmente registradas.
    pub subscribers: usize,
    /// Objects pendientes sumados entre sesiones.
    pub queued_objects: usize,
    /// Bytes pendientes sumados entre sesiones.
    pub queued_bytes: usize,
    /// Admisiones acumuladas.
    pub accepted: u64,
    /// Bytes admitidos acumulados.
    pub accepted_bytes: u64,
    /// Descartes acumulados, incluidos Objects antiguos reclamados.
    pub dropped: u64,
    /// Expulsiones acumuladas.
    pub evicted: u64,
    /// Objects entregados al publisher acumulados.
    pub dequeued: u64,
}

/// Resultado no bloqueante de intentar obtener el siguiente Object.
#[derive(Debug)]
pub enum ReceiveOutcome {
    /// Object seleccionado respetando prioridad.
    Object(ScheduledObject),
    /// La cola está vacía y puede esperarse una notificación.
    Pending,
    /// La sesión fue expulsada y debe cerrarse.
    Evicted,
}

/// Scheduler aislado por sesión de distribución.
pub trait ObjectScheduler: Send + Sync {
    /// Intenta encolar un Object para un suscriptor concreto.
    fn enqueue(
        &self,
        subscriber: &SubscriberId,
        object: ScheduledObject,
    ) -> BoxFuture<'_, GatewayResult<EnqueueOutcome>>;
}

/// Implementación con límites de Objects y bytes independientes por sesión.
pub struct SubscriberScheduler {
    config: SchedulerConfig,
    subscribers: RwLock<HashMap<SubscriberId, Arc<SubscriberQueue>>>,
    metrics: SchedulerMetrics,
    logger: EventLogger,
}

impl SubscriberScheduler {
    /// Construye el scheduler con configuración validada.
    #[must_use]
    pub fn new(config: SchedulerConfig, logger: EventLogger) -> Self {
        Self {
            config,
            subscribers: RwLock::new(HashMap::new()),
            metrics: SchedulerMetrics::default(),
            logger,
        }
    }

    /// Registra una cola aislada y devuelve su único consumidor.
    ///
    /// # Errors
    ///
    /// Devuelve error si el ID ya existe, se alcanzó el límite o el registro
    /// quedó envenenado.
    pub fn register(self: &Arc<Self>, id: SubscriberId) -> GatewayResult<SubscriberReceiver> {
        let mut subscribers = self.subscribers.write().map_err(|source| {
            GatewayError::new(format!("scheduler subscriber registry poisoned: {source}")).boxed()
        })?;
        if subscribers.contains_key(&id) {
            return Err(GatewayError::new(format!(
                "subscriber '{}' is already registered",
                id.as_str()
            ))
            .boxed());
        }
        if subscribers.len() >= self.config.max_subscribers {
            return Err(GatewayError::new("scheduler subscriber limit reached").boxed());
        }
        let queue = Arc::new(SubscriberQueue::new());
        subscribers.insert(id.clone(), Arc::clone(&queue));
        self.metrics.add_subscriber();
        self.logger.scheduler_subscriber_opened(
            id.as_str(),
            self.config.queue_objects,
            self.config.queue_bytes,
        );
        Ok(SubscriberReceiver {
            id,
            queue,
            scheduler: Arc::clone(self),
            registered: true,
        })
    }

    /// Encola un Object para todos los suscriptores sin compartir estado de cola.
    ///
    /// # Errors
    ///
    /// Devuelve error si el Object contradice su Track o si el registro quedó
    /// envenenado.
    pub fn fanout(
        &self,
        object: MediaObject,
        now: tokio::time::Instant,
    ) -> GatewayResult<FanoutReport> {
        let object = ScheduledObject::try_from(object)?;
        let subscribers: Vec<_> = self
            .subscribers
            .read()
            .map_err(|source| {
                GatewayError::new(format!("scheduler subscriber registry poisoned: {source}"))
                    .boxed()
            })?
            .iter()
            .map(|(id, queue)| (id.clone(), Arc::clone(queue)))
            .collect();
        let mut report = FanoutReport::default();
        for (id, queue) in subscribers {
            match self.enqueue_queue(&id, &queue, object.clone(), now)? {
                EnqueueOutcome::Accepted => report.accepted = report.accepted.saturating_add(1),
                EnqueueOutcome::Dropped => report.dropped = report.dropped.saturating_add(1),
                EnqueueOutcome::EvictSubscriber => {
                    report.evicted = report.evicted.saturating_add(1);
                }
            }
        }
        Ok(report)
    }

    /// Devuelve contadores sin adquirir las colas de los suscriptores.
    #[must_use]
    pub fn snapshot(&self) -> SchedulerSnapshot {
        self.metrics.snapshot()
    }

    fn enqueue_for(
        &self,
        id: &SubscriberId,
        object: ScheduledObject,
        now: tokio::time::Instant,
    ) -> GatewayResult<EnqueueOutcome> {
        let queue = self
            .subscribers
            .read()
            .map_err(|source| {
                GatewayError::new(format!("scheduler subscriber registry poisoned: {source}"))
                    .boxed()
            })?
            .get(id)
            .cloned()
            .ok_or_else(|| {
                GatewayError::new(format!("subscriber '{}' is not registered", id.as_str())).boxed()
            })?;
        self.enqueue_queue(id, &queue, object, now)
    }

    fn enqueue_queue(
        &self,
        id: &SubscriberId,
        queue: &SubscriberQueue,
        object: ScheduledObject,
        now: tokio::time::Instant,
    ) -> GatewayResult<EnqueueOutcome> {
        let mut state = queue.state.lock().map_err(|source| {
            GatewayError::new(format!(
                "scheduler queue for '{}' poisoned: {source}",
                id.as_str()
            ))
            .boxed()
        })?;
        if state.evicted {
            return Ok(EnqueueOutcome::EvictSubscriber);
        }
        let before = state.size();
        let mut mutation = state.expire(now);
        if mutation.eviction.is_none() {
            mutation.merge(state.enqueue(object, now, &self.config));
        }
        let after = state.size();
        drop(state);
        self.metrics.apply_queue_change(before, after);
        self.record_mutation(id, &mutation, now, after);
        if mutation.accepted_bytes > 0 {
            self.metrics.accept(mutation.accepted_bytes);
            queue.notify.notify_one();
        }
        if !mutation.drops.is_empty() {
            self.metrics.drop_objects(mutation.drops.len());
        }
        if mutation.eviction.is_some() {
            self.metrics.evict();
            queue.notify.notify_waiters();
            return Ok(EnqueueOutcome::EvictSubscriber);
        }
        Ok(mutation.outcome.unwrap_or(EnqueueOutcome::Dropped))
    }

    fn dequeue(
        &self,
        id: &SubscriberId,
        queue: &SubscriberQueue,
        now: tokio::time::Instant,
    ) -> GatewayResult<ReceiveOutcome> {
        let mut state = queue.state.lock().map_err(|source| {
            GatewayError::new(format!(
                "scheduler queue for '{}' poisoned: {source}",
                id.as_str()
            ))
            .boxed()
        })?;
        if state.evicted {
            return Ok(ReceiveOutcome::Evicted);
        }
        let before = state.size();
        let mutation = state.expire(now);
        let outcome = if mutation.eviction.is_some() {
            ReceiveOutcome::Evicted
        } else if let Some(entry) = state.pop_next() {
            self.metrics.dequeue();
            ReceiveOutcome::Object(entry.object)
        } else {
            ReceiveOutcome::Pending
        };
        let after = state.size();
        drop(state);
        self.metrics.apply_queue_change(before, after);
        self.record_mutation(id, &mutation, now, after);
        if !mutation.drops.is_empty() {
            self.metrics.drop_objects(mutation.drops.len());
        }
        if mutation.eviction.is_some() {
            self.metrics.evict();
        }
        Ok(outcome)
    }

    fn record_mutation(
        &self,
        id: &SubscriberId,
        mutation: &QueueMutation,
        now: tokio::time::Instant,
        queue_size: QueueSize,
    ) {
        for dropped in &mutation.drops {
            self.logger.object_dropped(&ObjectDropEvent {
                connection_id: dropped.entry.object.connection_id.as_ref(),
                subscriber_id: id.as_str(),
                track: dropped.entry.object.track.value(),
                priority: dropped.entry.object.priority.value(),
                group_id: dropped.entry.object.group.id,
                object_id: dropped.entry.object.object_id,
                age_ms: duration_millis(now.saturating_duration_since(dropped.entry.enqueued_at)),
                deadline_ms: duration_millis(dropped.entry.deadline),
                queue_objects: queue_size.objects,
                queue_bytes: queue_size.bytes,
                reason: dropped.reason.as_str(),
            });
        }
        if let Some(eviction) = &mutation.eviction {
            self.logger
                .subscriber_evicted_critical_backpressure(&CriticalEvictionEvent {
                    connection_id: eviction.entry.object.connection_id.as_ref(),
                    subscriber_id: id.as_str(),
                    track: eviction.entry.object.track.value(),
                    group_id: eviction.entry.object.group.id,
                    object_id: eviction.entry.object.object_id,
                    age_ms: duration_millis(
                        now.saturating_duration_since(eviction.entry.enqueued_at),
                    ),
                    deadline_ms: duration_millis(eviction.entry.deadline),
                    queue_objects: queue_size.objects,
                    queue_bytes: queue_size.bytes,
                    reason: eviction.reason,
                });
        }
    }

    fn unregister(&self, id: &SubscriberId, queue: &Arc<SubscriberQueue>) {
        let removed = match self.subscribers.write() {
            Ok(mut subscribers) => subscribers
                .get(id)
                .is_some_and(|registered| Arc::ptr_eq(registered, queue))
                .then(|| subscribers.remove(id))
                .flatten(),
            Err(_) => None,
        };
        let Some(removed) = removed else {
            return;
        };
        let remaining = match removed.state.lock() {
            Ok(mut state) => {
                let size = state.size();
                state.clear();
                size
            }
            Err(_) => QueueSize::default(),
        };
        self.metrics.remove_queue(remaining);
        self.metrics.remove_subscriber();
        self.logger.scheduler_subscriber_closed(id.as_str());
    }
}

impl ObjectScheduler for SubscriberScheduler {
    fn enqueue(
        &self,
        subscriber: &SubscriberId,
        object: ScheduledObject,
    ) -> BoxFuture<'_, GatewayResult<EnqueueOutcome>> {
        let result = self.enqueue_for(subscriber, object, tokio::time::Instant::now());
        Box::pin(async move { result })
    }
}

/// Consumidor exclusivo de la cola de un suscriptor.
pub struct SubscriberReceiver {
    id: SubscriberId,
    queue: Arc<SubscriberQueue>,
    scheduler: Arc<SubscriberScheduler>,
    registered: bool,
}

impl SubscriberReceiver {
    /// Espera el siguiente Object o la expulsión de esta sesión.
    ///
    /// # Errors
    ///
    /// Devuelve error si el estado interno de la cola quedó envenenado.
    pub async fn receive(&self) -> GatewayResult<Option<ScheduledObject>> {
        loop {
            let notified = self.queue.notify.notified();
            match self.try_receive_at(tokio::time::Instant::now())? {
                ReceiveOutcome::Object(object) => return Ok(Some(object)),
                ReceiveOutcome::Evicted => return Ok(None),
                ReceiveOutcome::Pending => notified.await,
            }
        }
    }

    /// Intenta extraer un Object usando un instante explícito para tests.
    ///
    /// # Errors
    ///
    /// Devuelve error si el estado interno de la cola quedó envenenado.
    pub fn try_receive_at(&self, now: tokio::time::Instant) -> GatewayResult<ReceiveOutcome> {
        self.scheduler.dequeue(&self.id, &self.queue, now)
    }

    /// Identidad del consumidor.
    #[must_use]
    pub fn id(&self) -> &SubscriberId {
        &self.id
    }
}

impl Drop for SubscriberReceiver {
    fn drop(&mut self) {
        if self.registered {
            self.scheduler.unregister(&self.id, &self.queue);
            self.registered = false;
        }
    }
}

struct SubscriberQueue {
    state: Mutex<QueueState>,
    notify: Notify,
}

impl SubscriberQueue {
    fn new() -> Self {
        Self {
            state: Mutex::new(QueueState::new()),
            notify: Notify::new(),
        }
    }
}

struct QueueState {
    queues: [VecDeque<QueueEntry>; 3],
    size: QueueSize,
    decodable_groups: [Option<u64>; 2],
    evicted: bool,
}

impl QueueState {
    fn new() -> Self {
        Self {
            queues: [VecDeque::new(), VecDeque::new(), VecDeque::new()],
            size: QueueSize::default(),
            decodable_groups: [None, None],
            evicted: false,
        }
    }

    const fn size(&self) -> QueueSize {
        self.size
    }

    fn enqueue(
        &mut self,
        object: ScheduledObject,
        now: tokio::time::Instant,
        config: &SchedulerConfig,
    ) -> QueueMutation {
        let deadline = deadline_for(object.priority, config);
        let entry = QueueEntry {
            object,
            enqueued_at: now,
            deadline,
        };
        let mut mutation = QueueMutation::default();

        if let Some(video_index) = video_index(entry.object.track) {
            match entry.object.priority {
                Priority::RandomAccess => {
                    mutation
                        .drops
                        .extend(self.supersede_group(entry.object.track, entry.object.group.id));
                    self.decodable_groups[video_index] = Some(entry.object.group.id);
                }
                Priority::Delta
                    if !entry.object.group.random_access
                        || self.decodable_groups[video_index] != Some(entry.object.group.id) =>
                {
                    mutation.drops.push(DroppedEntry {
                        entry,
                        reason: DropReason::DependencyNotDecodable,
                    });
                    mutation.outcome = Some(EnqueueOutcome::Dropped);
                    return mutation;
                }
                Priority::Delta => {}
                Priority::Critical => {
                    mutation.eviction = Some(Eviction {
                        entry,
                        reason: "invalid_critical_track_state",
                    });
                    self.evict();
                    return mutation;
                }
            }
        }

        match entry.object.priority {
            Priority::Delta => self.enqueue_delta(entry, config, mutation),
            Priority::RandomAccess => self.enqueue_random_access(entry, config, mutation),
            Priority::Critical => self.enqueue_critical(entry, config, mutation),
        }
    }

    fn enqueue_delta(
        &mut self,
        entry: QueueEntry,
        config: &SchedulerConfig,
        mut mutation: QueueMutation,
    ) -> QueueMutation {
        if self.has_capacity(entry.object.payload.len(), config) {
            mutation.accepted_bytes = entry.object.payload.len();
            mutation.outcome = Some(EnqueueOutcome::Accepted);
            self.push(entry);
        } else {
            mutation.drops.push(DroppedEntry {
                entry,
                reason: DropReason::QueueBackpressure,
            });
            mutation.outcome = Some(EnqueueOutcome::Dropped);
        }
        mutation
    }

    fn enqueue_random_access(
        &mut self,
        entry: QueueEntry,
        config: &SchedulerConfig,
        mut mutation: QueueMutation,
    ) -> QueueMutation {
        while !self.has_capacity(entry.object.payload.len(), config) {
            let Some(dropped) = self.pop_oldest(Priority::Delta) else {
                break;
            };
            mutation.drops.push(DroppedEntry {
                entry: dropped,
                reason: DropReason::QueueBackpressure,
            });
        }
        if self.has_capacity(entry.object.payload.len(), config) {
            mutation.accepted_bytes = entry.object.payload.len();
            mutation.outcome = Some(EnqueueOutcome::Accepted);
            self.push(entry);
        } else {
            self.invalidate_group(entry.object.track, entry.object.group.id, &mut mutation);
            mutation.drops.push(DroppedEntry {
                entry,
                reason: DropReason::QueueBackpressure,
            });
            mutation.outcome = Some(EnqueueOutcome::Dropped);
        }
        mutation
    }

    fn enqueue_critical(
        &mut self,
        entry: QueueEntry,
        config: &SchedulerConfig,
        mut mutation: QueueMutation,
    ) -> QueueMutation {
        while !self.has_capacity(entry.object.payload.len(), config) {
            if let Some(dropped) = self.pop_oldest(Priority::Delta) {
                mutation.drops.push(DroppedEntry {
                    entry: dropped,
                    reason: DropReason::QueueBackpressure,
                });
                continue;
            }
            let Some(dropped) = self.pop_oldest(Priority::RandomAccess) else {
                break;
            };
            let track = dropped.object.track;
            let group_id = dropped.object.group.id;
            mutation.drops.push(DroppedEntry {
                entry: dropped,
                reason: DropReason::QueueBackpressure,
            });
            self.invalidate_group(track, group_id, &mut mutation);
        }
        if self.has_capacity(entry.object.payload.len(), config) {
            mutation.accepted_bytes = entry.object.payload.len();
            mutation.outcome = Some(EnqueueOutcome::Accepted);
            self.push(entry);
        } else {
            mutation.eviction = Some(Eviction {
                entry,
                reason: "critical_queue_backpressure",
            });
            self.evict();
            mutation.outcome = Some(EnqueueOutcome::EvictSubscriber);
        }
        mutation
    }

    fn expire(&mut self, now: tokio::time::Instant) -> QueueMutation {
        let mut mutation = QueueMutation::default();
        if let Some(entry) = self.queues[Priority::Critical.index()]
            .iter()
            .find(|entry| entry.expired(now))
            .cloned()
        {
            mutation.eviction = Some(Eviction {
                entry,
                reason: "critical_queue_deadline_expired",
            });
            self.evict();
            return mutation;
        }

        let expired_random = self.extract(Priority::RandomAccess, |entry| entry.expired(now));
        for entry in expired_random {
            let track = entry.object.track;
            let group_id = entry.object.group.id;
            mutation.drops.push(DroppedEntry {
                entry,
                reason: DropReason::QueueDeadlineExpired,
            });
            self.invalidate_group(track, group_id, &mut mutation);
        }
        let expired_delta = self.extract(Priority::Delta, |entry| entry.expired(now));
        mutation
            .drops
            .extend(expired_delta.into_iter().map(|entry| DroppedEntry {
                entry,
                reason: DropReason::QueueDeadlineExpired,
            }));
        mutation
    }

    fn supersede_group(&mut self, track: TrackId, group_id: u64) -> Vec<DroppedEntry> {
        let mut dropped = Vec::new();
        for priority in [Priority::RandomAccess, Priority::Delta] {
            dropped.extend(
                self.extract(priority, |entry| {
                    entry.object.track == track && entry.object.group.id != group_id
                })
                .into_iter()
                .map(|entry| DroppedEntry {
                    entry,
                    reason: DropReason::GroupSuperseded,
                }),
            );
        }
        dropped
    }

    fn invalidate_group(&mut self, track: TrackId, group_id: u64, mutation: &mut QueueMutation) {
        if let Some(index) = video_index(track)
            && self.decodable_groups[index] == Some(group_id)
        {
            self.decodable_groups[index] = None;
        }
        let dependents = self.extract(Priority::Delta, |entry| {
            entry.object.track == track && entry.object.group.id == group_id
        });
        mutation
            .drops
            .extend(dependents.into_iter().map(|entry| DroppedEntry {
                entry,
                reason: DropReason::DependencyNotDecodable,
            }));
    }

    fn extract(
        &mut self,
        priority: Priority,
        mut predicate: impl FnMut(&QueueEntry) -> bool,
    ) -> Vec<QueueEntry> {
        let queue = &mut self.queues[priority.index()];
        let length = queue.len();
        let mut extracted = Vec::new();
        for _ in 0..length {
            let Some(entry) = queue.pop_front() else {
                break;
            };
            if predicate(&entry) {
                self.size.remove(&entry.object);
                extracted.push(entry);
            } else {
                queue.push_back(entry);
            }
        }
        extracted
    }

    fn has_capacity(&self, object_bytes: usize, config: &SchedulerConfig) -> bool {
        self.size.objects < config.queue_objects
            && self.size.bytes.saturating_add(object_bytes) <= config.queue_bytes
    }

    fn push(&mut self, entry: QueueEntry) {
        self.size.add(&entry.object);
        self.queues[entry.object.priority.index()].push_back(entry);
    }

    fn pop_oldest(&mut self, priority: Priority) -> Option<QueueEntry> {
        let entry = self.queues[priority.index()].pop_front()?;
        self.size.remove(&entry.object);
        Some(entry)
    }

    fn pop_next(&mut self) -> Option<QueueEntry> {
        for priority in [Priority::Critical, Priority::RandomAccess, Priority::Delta] {
            if let Some(entry) = self.pop_oldest(priority) {
                return Some(entry);
            }
        }
        None
    }

    fn evict(&mut self) {
        self.evicted = true;
        self.clear_queues();
    }

    fn clear(&mut self) {
        self.clear_queues();
        self.evicted = true;
    }

    fn clear_queues(&mut self) {
        for queue in &mut self.queues {
            queue.clear();
        }
        self.size = QueueSize::default();
        self.decodable_groups = [None, None];
    }
}

#[derive(Clone)]
struct QueueEntry {
    object: ScheduledObject,
    enqueued_at: tokio::time::Instant,
    deadline: Duration,
}

impl QueueEntry {
    fn expired(&self, now: tokio::time::Instant) -> bool {
        now.saturating_duration_since(self.enqueued_at) > self.deadline
    }
}

#[derive(Clone, Copy, Debug, Default)]
struct QueueSize {
    objects: usize,
    bytes: usize,
}

impl QueueSize {
    fn add(&mut self, object: &ScheduledObject) {
        self.objects = self.objects.saturating_add(1);
        self.bytes = self.bytes.saturating_add(object.payload.len());
    }

    fn remove(&mut self, object: &ScheduledObject) {
        self.objects = self.objects.saturating_sub(1);
        self.bytes = self.bytes.saturating_sub(object.payload.len());
    }
}

#[derive(Default)]
struct QueueMutation {
    outcome: Option<EnqueueOutcome>,
    accepted_bytes: usize,
    drops: Vec<DroppedEntry>,
    eviction: Option<Eviction>,
}

impl QueueMutation {
    fn merge(&mut self, other: Self) {
        self.outcome = other.outcome.or(self.outcome);
        self.accepted_bytes = self.accepted_bytes.saturating_add(other.accepted_bytes);
        self.drops.extend(other.drops);
        if self.eviction.is_none() {
            self.eviction = other.eviction;
        }
    }
}

struct DroppedEntry {
    entry: QueueEntry,
    reason: DropReason,
}

struct Eviction {
    entry: QueueEntry,
    reason: &'static str,
}

#[derive(Default)]
struct SchedulerMetrics {
    subscribers: AtomicUsize,
    queued_objects: AtomicUsize,
    queued_bytes: AtomicUsize,
    accepted: AtomicU64,
    accepted_bytes: AtomicU64,
    dropped: AtomicU64,
    evicted: AtomicU64,
    dequeued: AtomicU64,
}

impl SchedulerMetrics {
    fn add_subscriber(&self) {
        atomic_saturating_add_usize(&self.subscribers, 1);
    }

    fn remove_subscriber(&self) {
        atomic_saturating_sub_usize(&self.subscribers, 1);
    }

    fn accept(&self, bytes: usize) {
        atomic_saturating_add_u64(&self.accepted, 1);
        atomic_saturating_add_u64(&self.accepted_bytes, usize_to_u64(bytes));
    }

    fn drop_objects(&self, objects: usize) {
        atomic_saturating_add_u64(&self.dropped, usize_to_u64(objects));
    }

    fn evict(&self) {
        atomic_saturating_add_u64(&self.evicted, 1);
    }

    fn dequeue(&self) {
        atomic_saturating_add_u64(&self.dequeued, 1);
    }

    fn apply_queue_change(&self, before: QueueSize, after: QueueSize) {
        apply_usize_delta(&self.queued_objects, before.objects, after.objects);
        apply_usize_delta(&self.queued_bytes, before.bytes, after.bytes);
    }

    fn remove_queue(&self, size: QueueSize) {
        atomic_saturating_sub_usize(&self.queued_objects, size.objects);
        atomic_saturating_sub_usize(&self.queued_bytes, size.bytes);
    }

    fn snapshot(&self) -> SchedulerSnapshot {
        SchedulerSnapshot {
            subscribers: self.subscribers.load(Ordering::Relaxed),
            queued_objects: self.queued_objects.load(Ordering::Relaxed),
            queued_bytes: self.queued_bytes.load(Ordering::Relaxed),
            accepted: self.accepted.load(Ordering::Relaxed),
            accepted_bytes: self.accepted_bytes.load(Ordering::Relaxed),
            dropped: self.dropped.load(Ordering::Relaxed),
            evicted: self.evicted.load(Ordering::Relaxed),
            dequeued: self.dequeued.load(Ordering::Relaxed),
        }
    }
}

fn classify(track: TrackId, kind: AccessUnitKind) -> GatewayResult<Priority> {
    match (track, kind) {
        (TrackId::CriticalAudio | TrackId::Telemetry, _) => Ok(Priority::Critical),
        (TrackId::VideoHq | TrackId::VideoLq, AccessUnitKind::RandomAccess) => {
            Ok(Priority::RandomAccess)
        }
        (TrackId::VideoHq | TrackId::VideoLq, AccessUnitKind::Delta) => Ok(Priority::Delta),
        (TrackId::VideoHq | TrackId::VideoLq, _) => {
            Err(GatewayError::new("video Track received a non-video access unit kind").boxed())
        }
    }
}

const fn video_index(track: TrackId) -> Option<usize> {
    match track {
        TrackId::VideoHq => Some(0),
        TrackId::VideoLq => Some(1),
        TrackId::CriticalAudio | TrackId::Telemetry => None,
    }
}

const fn deadline_for(priority: Priority, config: &SchedulerConfig) -> Duration {
    match priority {
        Priority::Critical => config.critical_deadline,
        Priority::RandomAccess => config.random_access_deadline,
        Priority::Delta => config.delta_deadline,
    }
}

fn apply_usize_delta(atomic: &AtomicUsize, before: usize, after: usize) {
    if after >= before {
        atomic_saturating_add_usize(atomic, after - before);
    } else {
        atomic_saturating_sub_usize(atomic, before - after);
    }
}

fn atomic_saturating_add_usize(atomic: &AtomicUsize, value: usize) {
    let _ = atomic.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |current| {
        Some(current.saturating_add(value))
    });
}

fn atomic_saturating_sub_usize(atomic: &AtomicUsize, value: usize) {
    let _ = atomic.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |current| {
        Some(current.saturating_sub(value))
    });
}

fn atomic_saturating_add_u64(atomic: &AtomicU64, value: u64) {
    let _ = atomic.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |current| {
        Some(current.saturating_add(value))
    });
}

fn duration_millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).map_or(u64::MAX, std::convert::identity)
}

fn usize_to_u64(value: usize) -> u64 {
    u64::try_from(value).map_or(u64::MAX, std::convert::identity)
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use bytes::Bytes;

    use super::{Priority, ReceiveOutcome, SubscriberId, SubscriberScheduler};
    use crate::{
        config::SchedulerConfig,
        error::GatewayResult,
        media::{AccessUnitKind, Codec, Group, MediaObject, Track},
        observability::EventLogger,
        routing::TrackId,
    };

    fn scheduler(queue_objects: usize, queue_bytes: usize) -> Arc<SubscriberScheduler> {
        Arc::new(SubscriberScheduler::new(
            SchedulerConfig {
                max_subscribers: 8,
                queue_objects,
                queue_bytes,
                delta_deadline: std::time::Duration::from_millis(50),
                random_access_deadline: std::time::Duration::from_millis(200),
                critical_deadline: std::time::Duration::from_millis(500),
            },
            EventLogger::new("scheduler-test".to_owned()),
        ))
    }

    fn object(
        track: TrackId,
        kind: AccessUnitKind,
        group_id: u64,
        object_id: u64,
        bytes: usize,
        now: tokio::time::Instant,
    ) -> GatewayResult<MediaObject> {
        Ok(MediaObject {
            group: Group {
                id: group_id,
                track: Track { id: track },
                random_access: matches!(kind, AccessUnitKind::RandomAccess)
                    || !matches!(track, TrackId::VideoHq | TrackId::VideoLq),
            },
            object_id,
            program_number: 1,
            pid: 256,
            codec: match track {
                TrackId::CriticalAudio => Codec::Aac,
                TrackId::Telemetry => Codec::Json,
                TrackId::VideoHq | TrackId::VideoLq => Codec::H264,
            },
            kind,
            pts_ns: Some(object_id),
            dts_ns: Some(object_id),
            payload: Bytes::from(vec![0_u8; bytes]),
            cmaf_init: None,
            connection_id: Arc::from("srt-test"),
            peer: "127.0.0.1:9000".parse()?,
            received_at: now,
        })
    }

    #[test]
    fn rejects_unstable_subscriber_ids() {
        assert!(SubscriberId::new("subscriber-1").is_ok());
        assert!(SubscriberId::new("subscriber with spaces").is_err());
    }

    #[test]
    fn prioritizes_critical_then_random_access_then_delta() -> GatewayResult<()> {
        let scheduler = scheduler(8, 8_000);
        let receiver = scheduler.register(SubscriberId::new("subscriber-1")?)?;
        let now = tokio::time::Instant::now();
        scheduler.fanout(
            object(
                TrackId::VideoHq,
                AccessUnitKind::RandomAccess,
                1,
                0,
                100,
                now,
            )?,
            now,
        )?;
        let mut delta = object(TrackId::VideoHq, AccessUnitKind::Delta, 1, 1, 100, now)?;
        delta.group.random_access = true;
        scheduler.fanout(delta, now)?;
        scheduler.fanout(
            object(
                TrackId::CriticalAudio,
                AccessUnitKind::Audio,
                2,
                0,
                100,
                now,
            )?,
            now,
        )?;

        assert!(matches!(
            receiver.try_receive_at(now)?,
            ReceiveOutcome::Object(object) if object.priority == Priority::Critical
        ));
        assert!(matches!(
            receiver.try_receive_at(now)?,
            ReceiveOutcome::Object(object) if object.priority == Priority::RandomAccess
        ));
        assert!(matches!(
            receiver.try_receive_at(now)?,
            ReceiveOutcome::Object(object) if object.priority == Priority::Delta
        ));
        Ok(())
    }

    #[test]
    fn drops_delta_immediately_when_queue_is_full() -> GatewayResult<()> {
        let scheduler = scheduler(2, 8_000);
        let _receiver = scheduler.register(SubscriberId::new("slow")?)?;
        let now = tokio::time::Instant::now();
        scheduler.fanout(
            object(
                TrackId::VideoHq,
                AccessUnitKind::RandomAccess,
                1,
                0,
                100,
                now,
            )?,
            now,
        )?;
        for object_id in 1..=2 {
            let mut delta = object(
                TrackId::VideoHq,
                AccessUnitKind::Delta,
                1,
                object_id,
                100,
                now,
            )?;
            delta.group.random_access = true;
            let report = scheduler.fanout(delta, now)?;
            if object_id == 2 {
                assert_eq!(report.dropped, 1);
            }
        }
        let snapshot = scheduler.snapshot();
        assert_eq!(snapshot.queued_objects, 2);
        assert_eq!(snapshot.dropped, 1);
        Ok(())
    }

    #[tokio::test(start_paused = true)]
    async fn expired_delta_is_never_delivered_late() -> GatewayResult<()> {
        let scheduler = scheduler(4, 8_000);
        let receiver = scheduler.register(SubscriberId::new("slow")?)?;
        let now = tokio::time::Instant::now();
        scheduler.fanout(
            object(
                TrackId::VideoHq,
                AccessUnitKind::RandomAccess,
                1,
                0,
                100,
                now,
            )?,
            now,
        )?;
        let mut delta = object(TrackId::VideoHq, AccessUnitKind::Delta, 1, 1, 100, now)?;
        delta.group.random_access = true;
        scheduler.fanout(delta, now)?;

        tokio::time::advance(std::time::Duration::from_millis(51)).await;
        let later = tokio::time::Instant::now();
        assert!(matches!(
            receiver.try_receive_at(later)?,
            ReceiveOutcome::Object(object) if object.priority == Priority::RandomAccess
        ));
        assert!(matches!(
            receiver.try_receive_at(later)?,
            ReceiveOutcome::Pending
        ));
        assert_eq!(scheduler.snapshot().dropped, 1);
        Ok(())
    }

    #[test]
    fn enforces_the_byte_limit_independently_of_object_count() -> GatewayResult<()> {
        let scheduler = scheduler(8, 188);
        let _receiver = scheduler.register(SubscriberId::new("byte-limited")?)?;
        let now = tokio::time::Instant::now();
        scheduler.fanout(
            object(
                TrackId::VideoHq,
                AccessUnitKind::RandomAccess,
                1,
                0,
                100,
                now,
            )?,
            now,
        )?;
        let mut delta = object(TrackId::VideoHq, AccessUnitKind::Delta, 1, 1, 100, now)?;
        delta.group.random_access = true;
        let report = scheduler.fanout(delta, now)?;

        assert_eq!(report.dropped, 1);
        assert_eq!(scheduler.snapshot().queued_objects, 1);
        assert_eq!(scheduler.snapshot().queued_bytes, 100);
        Ok(())
    }

    #[tokio::test(start_paused = true)]
    async fn lost_random_access_invalidates_dependent_objects() -> GatewayResult<()> {
        let scheduler = scheduler(8, 8_000);
        let receiver = scheduler.register(SubscriberId::new("late")?)?;
        let now = tokio::time::Instant::now();
        scheduler.fanout(
            object(
                TrackId::VideoHq,
                AccessUnitKind::RandomAccess,
                1,
                0,
                100,
                now,
            )?,
            now,
        )?;
        let mut delta = object(TrackId::VideoHq, AccessUnitKind::Delta, 1, 1, 100, now)?;
        delta.group.random_access = true;
        scheduler.fanout(delta, now)?;

        tokio::time::advance(std::time::Duration::from_millis(201)).await;
        let later = tokio::time::Instant::now();
        assert!(matches!(
            receiver.try_receive_at(later)?,
            ReceiveOutcome::Pending
        ));
        let mut dependent = object(TrackId::VideoHq, AccessUnitKind::Delta, 1, 2, 100, later)?;
        dependent.group.random_access = true;
        assert_eq!(scheduler.fanout(dependent, later)?.dropped, 1);
        assert_eq!(scheduler.snapshot().dropped, 3);
        Ok(())
    }

    #[test]
    fn shares_encoded_payload_between_subscribers() -> GatewayResult<()> {
        let scheduler = scheduler(4, 8_000);
        let left = scheduler.register(SubscriberId::new("left")?)?;
        let right = scheduler.register(SubscriberId::new("right")?)?;
        let now = tokio::time::Instant::now();
        scheduler.fanout(
            object(
                TrackId::VideoHq,
                AccessUnitKind::RandomAccess,
                1,
                0,
                100,
                now,
            )?,
            now,
        )?;
        let left_object = match left.try_receive_at(now)? {
            ReceiveOutcome::Object(object) => object,
            ReceiveOutcome::Pending | ReceiveOutcome::Evicted => {
                return Err(crate::error::GatewayError::new(
                    "left subscriber did not receive the shared Object",
                )
                .boxed());
            }
        };
        let right_object = match right.try_receive_at(now)? {
            ReceiveOutcome::Object(object) => object,
            ReceiveOutcome::Pending | ReceiveOutcome::Evicted => {
                return Err(crate::error::GatewayError::new(
                    "right subscriber did not receive the shared Object",
                )
                .boxed());
            }
        };

        assert_eq!(left_object.payload.as_ptr(), right_object.payload.as_ptr());
        assert_eq!(left_object.payload.len(), right_object.payload.len());
        Ok(())
    }

    #[tokio::test(start_paused = true)]
    async fn critical_deadline_evicts_the_stalled_subscriber() -> GatewayResult<()> {
        let scheduler = scheduler(4, 8_000);
        let receiver = scheduler.register(SubscriberId::new("stalled")?)?;
        let now = tokio::time::Instant::now();
        scheduler.fanout(
            object(
                TrackId::CriticalAudio,
                AccessUnitKind::Audio,
                1,
                0,
                100,
                now,
            )?,
            now,
        )?;
        tokio::time::advance(std::time::Duration::from_millis(501)).await;

        assert!(matches!(
            receiver.try_receive_at(tokio::time::Instant::now())?,
            ReceiveOutcome::Evicted
        ));
        assert_eq!(scheduler.snapshot().evicted, 1);
        Ok(())
    }

    #[test]
    fn newer_random_access_supersedes_old_group() -> GatewayResult<()> {
        let scheduler = scheduler(8, 8_000);
        let receiver = scheduler.register(SubscriberId::new("slow")?)?;
        let now = tokio::time::Instant::now();
        scheduler.fanout(
            object(
                TrackId::VideoHq,
                AccessUnitKind::RandomAccess,
                1,
                0,
                100,
                now,
            )?,
            now,
        )?;
        let mut delta = object(TrackId::VideoHq, AccessUnitKind::Delta, 1, 1, 100, now)?;
        delta.group.random_access = true;
        scheduler.fanout(delta, now)?;
        scheduler.fanout(
            object(
                TrackId::VideoHq,
                AccessUnitKind::RandomAccess,
                2,
                0,
                100,
                now,
            )?,
            now,
        )?;

        assert!(matches!(
            receiver.try_receive_at(now)?,
            ReceiveOutcome::Object(object) if object.group.id == 2
        ));
        assert_eq!(scheduler.snapshot().dropped, 2);
        Ok(())
    }

    #[test]
    fn critical_backpressure_evicts_only_the_slow_subscriber() -> GatewayResult<()> {
        let scheduler = scheduler(1, 1_000);
        let fast = scheduler.register(SubscriberId::new("fast")?)?;
        let slow = scheduler.register(SubscriberId::new("slow")?)?;
        let now = tokio::time::Instant::now();
        scheduler.fanout(
            object(
                TrackId::CriticalAudio,
                AccessUnitKind::Audio,
                1,
                0,
                100,
                now,
            )?,
            now,
        )?;
        assert!(matches!(
            fast.try_receive_at(now)?,
            ReceiveOutcome::Object(_)
        ));
        let report = scheduler.fanout(
            object(
                TrackId::CriticalAudio,
                AccessUnitKind::Audio,
                1,
                1,
                100,
                now,
            )?,
            now,
        )?;
        assert_eq!(report.accepted, 1);
        assert_eq!(report.evicted, 1);
        assert!(matches!(
            fast.try_receive_at(now)?,
            ReceiveOutcome::Object(_)
        ));
        assert!(matches!(slow.try_receive_at(now)?, ReceiveOutcome::Evicted));
        Ok(())
    }

    #[test]
    fn multitrack_congestion_discards_video_before_critical_data() -> GatewayResult<()> {
        let scheduler = scheduler(4, 8_000);
        let receiver = scheduler.register(SubscriberId::new("multitrack-slow")?)?;
        let now = tokio::time::Instant::now();

        for (track, group_id) in [(TrackId::VideoHq, 1), (TrackId::VideoLq, 2)] {
            scheduler.fanout(
                object(track, AccessUnitKind::RandomAccess, group_id, 0, 100, now)?,
                now,
            )?;
            let mut delta = object(track, AccessUnitKind::Delta, group_id, 1, 100, now)?;
            delta.group.random_access = true;
            scheduler.fanout(delta, now)?;
        }

        let audio = scheduler.fanout(
            object(
                TrackId::CriticalAudio,
                AccessUnitKind::Audio,
                3,
                0,
                100,
                now,
            )?,
            now,
        )?;
        let after_audio = scheduler.snapshot();
        let telemetry = scheduler.fanout(
            object(
                TrackId::Telemetry,
                AccessUnitKind::Telemetry,
                4,
                0,
                100,
                now,
            )?,
            now,
        )?;

        assert_eq!(audio.accepted, 1);
        assert_eq!(audio.dropped, 0);
        assert_eq!(audio.evicted, 0);
        assert_eq!(after_audio.dropped, 1);
        assert_eq!(telemetry.accepted, 1);
        assert_eq!(telemetry.dropped, 0);
        assert_eq!(telemetry.evicted, 0);
        assert!(matches!(
            receiver.try_receive_at(now)?,
            ReceiveOutcome::Object(object)
                if object.track == TrackId::CriticalAudio && object.priority == Priority::Critical
        ));
        assert!(matches!(
            receiver.try_receive_at(now)?,
            ReceiveOutcome::Object(object)
                if object.track == TrackId::Telemetry && object.priority == Priority::Critical
        ));
        assert_eq!(scheduler.snapshot().dropped, 2);
        assert_eq!(scheduler.snapshot().evicted, 0);
        Ok(())
    }
}
