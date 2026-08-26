//! Adaptador Tokio para la máquina de estados Sans-I/O de Shiguredo SRT.

use std::{
    collections::{HashMap, HashSet},
    net::SocketAddr,
    sync::Arc,
    time::Duration,
};

use bytes::Bytes;
use shiguredo_srt::{
    ConnectionEvent, ConnectionOptions, ConnectionOutput, ConnectionState, ControlType,
    HandshakePacket, HandshakeType, KeyLength, SrtConnection, SrtPacket, TimerId, Timestamp,
};
use tokio::{
    net::UdpSocket,
    sync::mpsc,
    time::{self, Instant, MissedTickBehavior},
};
use tokio_util::sync::CancellationToken;

use crate::{
    BoxFuture,
    config::SrtConfig,
    error::{GatewayError, GatewayResult},
    ingest::{IngestPacket, SrtIngress},
    observability::EventLogger,
};

const MAX_UDP_DATAGRAM_BYTES: usize = 2_048;
const IDLE_TIMER_POLL: Duration = Duration::from_secs(60);

/// Extremo de lectura que satisface el puerto `SrtIngress`.
pub struct ShiguredoSrtIngress {
    receiver: mpsc::Receiver<IngestPacket>,
}

/// Driver que posee el socket de recepción y las sesiones SRT por peer.
pub struct SrtListenerDriver {
    socket: Arc<UdpSocket>,
    config: SrtConfig,
    logger: EventLogger,
    packet_sender: mpsc::Sender<IngestPacket>,
    egress_sender: mpsc::Sender<OutboundDatagram>,
    egress_shutdown: CancellationToken,
    sessions: HashMap<SocketAddr, Session>,
    base_time: Instant,
    next_connection_id: u64,
    rejected_datagrams: u64,
}

/// Task independiente que serializa los datagramas UDP de control.
pub struct SrtEgress {
    socket: Arc<UdpSocket>,
    receiver: mpsc::Receiver<OutboundDatagram>,
    orderly_shutdown: CancellationToken,
    logger: EventLogger,
}

struct Session {
    connection: SrtConnection,
    connection_id: Arc<str>,
    peer: SocketAddr,
    stream_id: Option<Arc<str>>,
    source: Option<Arc<str>>,
    timers: HashMap<TimerId, Instant>,
    close_logged: bool,
}

struct OutboundDatagram {
    connection_id: Arc<str>,
    peer: SocketAddr,
    payload: Vec<u8>,
}

impl ShiguredoSrtIngress {
    /// Vincula UDP y construye los tres componentes aislados del adaptador.
    ///
    /// # Errors
    ///
    /// Devuelve error si el listener UDP no puede vincularse o consultarse.
    pub async fn bind(
        config: SrtConfig,
        logger: EventLogger,
    ) -> GatewayResult<(Self, SrtListenerDriver, SrtEgress)> {
        let socket = UdpSocket::bind(config.bind_addr).await.map_err(|source| {
            GatewayError::with_source(
                format!("failed to bind SRT listener at {}", config.bind_addr),
                Box::new(source),
            )
            .boxed()
        })?;
        let local_addr = socket.local_addr().map_err(|source| {
            GatewayError::with_source("failed to read SRT listener address", Box::new(source))
                .boxed()
        })?;
        let socket = Arc::new(socket);
        let (packet_sender, receiver) = mpsc::channel(config.ingress_queue_capacity);
        let (egress_sender, egress_receiver) = mpsc::channel(config.egress_queue_capacity);
        let egress_shutdown = CancellationToken::new();

        logger.srt_listener_bound(local_addr, config.max_sessions, config.passphrase.is_some());

        let listener = SrtListenerDriver {
            socket: Arc::clone(&socket),
            config,
            logger: logger.clone(),
            packet_sender,
            egress_sender,
            egress_shutdown: egress_shutdown.clone(),
            sessions: HashMap::new(),
            base_time: Instant::now(),
            next_connection_id: 0,
            rejected_datagrams: 0,
        };
        let egress = SrtEgress {
            socket,
            receiver: egress_receiver,
            orderly_shutdown: egress_shutdown,
            logger,
        };

        Ok((Self { receiver }, listener, egress))
    }
}

impl SrtIngress for ShiguredoSrtIngress {
    fn receive(&mut self) -> BoxFuture<'_, GatewayResult<Option<IngestPacket>>> {
        Box::pin(async { Ok(self.receiver.recv().await) })
    }
}

impl SrtListenerDriver {
    /// Procesa UDP, timers y estadísticas hasta recibir cancelación.
    ///
    /// # Errors
    ///
    /// Devuelve error ante un fallo del socket, del generador aleatorio o de
    /// los canales internos que implique la caída de una task crítica.
    pub async fn run(mut self, cancellation: CancellationToken) -> GatewayResult<()> {
        let first_stats = Instant::now() + self.config.stats_interval;
        let mut stats_interval = time::interval_at(first_stats, self.config.stats_interval);
        stats_interval.set_missed_tick_behavior(MissedTickBehavior::Skip);
        let mut receive_buffer = vec![0_u8; MAX_UDP_DATAGRAM_BYTES];

        loop {
            let next_timer = self.next_timer();
            let timer_wait = next_timer.map_or(IDLE_TIMER_POLL, |(_, _, deadline)| {
                deadline
                    .checked_duration_since(Instant::now())
                    .map_or(Duration::ZERO, std::convert::identity)
            });

            tokio::select! {
                biased;
                () = cancellation.cancelled() => {
                    self.shutdown_all_sessions();
                    self.egress_shutdown.cancel();
                    return Ok(());
                }
                received = self.socket.recv_from(&mut receive_buffer) => {
                    let (length, peer) = received.map_err(|source| {
                        GatewayError::with_source("SRT UDP receive failed", Box::new(source)).boxed()
                    })?;
                    let received_at = Instant::now();
                    self.handle_datagram(peer, &receive_buffer[..length], received_at)?;
                }
                () = time::sleep(timer_wait) => {
                    if let Some((peer, timer_id, _)) = next_timer {
                        self.handle_timer(peer, timer_id)?;
                    }
                }
                _ = stats_interval.tick() => self.emit_stats(),
            }
        }
    }

    fn handle_datagram(
        &mut self,
        peer: SocketAddr,
        datagram: &[u8],
        received_at: Instant,
    ) -> GatewayResult<()> {
        if datagram.len() == MAX_UDP_DATAGRAM_BYTES {
            self.rejected_datagrams = self.rejected_datagrams.saturating_add(1);
            self.remove_session(peer, "oversized_datagram");
            return Ok(());
        }

        if !self.sessions.contains_key(&peer) {
            if !is_induction(datagram) {
                self.rejected_datagrams = self.rejected_datagrams.saturating_add(1);
                return Ok(());
            }
            if self.sessions.len() >= self.config.max_sessions {
                self.rejected_datagrams = self.rejected_datagrams.saturating_add(1);
                self.logger
                    .srt_connection_rejected(peer, "session_limit", datagram.len());
                return Ok(());
            }
            let session = self.new_session(peer)?;
            self.sessions.insert(peer, session);
        }

        let Some(mut session) = self.sessions.remove(&peer) else {
            return Ok(());
        };
        let now = self.now_timestamp();
        if let Err(source) = session.connection.feed_recv_buf(datagram, now) {
            self.logger.srt_session_error(
                session.connection_id.as_ref(),
                peer,
                "protocol_error",
                &source,
            );
            self.log_close(&mut session, "protocol_error");
            return Ok(());
        }

        if self.process_session(&mut session, received_at, now)? {
            self.sessions.insert(peer, session);
        }
        Ok(())
    }

    fn handle_timer(&mut self, peer: SocketAddr, timer_id: TimerId) -> GatewayResult<()> {
        let Some(mut session) = self.sessions.remove(&peer) else {
            return Ok(());
        };
        session.timers.remove(&timer_id);
        let now = self.now_timestamp();
        if let Err(source) = session.connection.handle_timer(timer_id, now) {
            self.logger.srt_session_error(
                session.connection_id.as_ref(),
                peer,
                "timer_error",
                &source,
            );
            self.log_close(&mut session, "timer_error");
            return Ok(());
        }

        if self.process_session(&mut session, Instant::now(), now)? {
            self.sessions.insert(peer, session);
        }
        Ok(())
    }

    fn process_session(
        &mut self,
        session: &mut Session,
        received_at: Instant,
        now: Timestamp,
    ) -> GatewayResult<bool> {
        let mut keep_session = true;

        while let Some(event) = session.connection.poll_event() {
            if !self.process_event(session, event, received_at, now)? {
                keep_session = false;
            }
        }

        if !self.process_outputs(session)? {
            keep_session = false;
        }

        if !keep_session {
            self.log_close(session, "session_evicted");
        }
        Ok(keep_session)
    }

    fn process_event(
        &mut self,
        session: &mut Session,
        event: ConnectionEvent,
        received_at: Instant,
        now: Timestamp,
    ) -> GatewayResult<bool> {
        match event {
            ConnectionEvent::Connected => Ok(self.authorize_session(session, now)),
            ConnectionEvent::DataReceived {
                payload,
                message_number,
                timestamp,
            } => self.deliver_payload(session, payload, message_number, timestamp, received_at),
            ConnectionEvent::StateChanged(ConnectionState::Disconnected) => {
                self.log_close(session, "state_disconnected");
                Ok(false)
            }
            ConnectionEvent::StateChanged(_) => Ok(true),
            ConnectionEvent::Error(message) => {
                let source = GatewayError::new(message);
                self.logger.srt_session_error(
                    session.connection_id.as_ref(),
                    session.peer,
                    "backend_event",
                    &source,
                );
                Ok(true)
            }
            ConnectionEvent::Disconnected { reason } => {
                self.log_close(session, &reason);
                Ok(false)
            }
            ConnectionEvent::KeyRefreshNeeded { key_length } => {
                self.logger.srt_key_refresh_needed(
                    session.connection_id.as_ref(),
                    session.peer,
                    key_length,
                );
                Ok(true)
            }
        }
    }

    fn authorize_session(&self, session: &mut Session, now: Timestamp) -> bool {
        let Some(stream_id) = session.connection.peer_stream_id().map(Arc::<str>::from) else {
            self.logger.srt_stream_id_rejected(
                session.connection_id.as_ref(),
                session.peer,
                "missing_stream_id",
                0,
            );
            session.connection.disconnect(now);
            return false;
        };

        let Some(source) = self.config.routes.source_for_stream(&stream_id) else {
            self.logger.srt_stream_id_rejected(
                session.connection_id.as_ref(),
                session.peer,
                "unauthorized_stream_id",
                stream_id.len(),
            );
            session.connection.disconnect(now);
            return false;
        };

        let source: Arc<str> = Arc::from(source);
        self.logger.srt_connection_opened(
            session.connection_id.as_ref(),
            session.peer,
            source.as_ref(),
            stream_id.len(),
            self.config.passphrase.is_some(),
        );
        session.stream_id = Some(stream_id);
        session.source = Some(source);
        true
    }

    fn deliver_payload(
        &self,
        session: &Session,
        payload: Vec<u8>,
        message_number: u32,
        timestamp: u32,
        received_at: Instant,
    ) -> GatewayResult<bool> {
        let Some(stream_id) = session.stream_id.clone() else {
            self.logger.srt_session_evicted(
                session.connection_id.as_ref(),
                session.peer,
                "payload_before_authorization",
            );
            return Ok(false);
        };
        let packet = IngestPacket {
            payload: Bytes::from(payload),
            connection_id: Arc::clone(&session.connection_id),
            peer: session.peer,
            stream_id,
            message_number,
            srt_timestamp: timestamp,
            received_at,
        };
        match self.packet_sender.try_send(packet) {
            Ok(()) => Ok(true),
            Err(mpsc::error::TrySendError::Full(_)) => {
                self.logger.srt_session_evicted(
                    session.connection_id.as_ref(),
                    session.peer,
                    "ingress_queue_backpressure",
                );
                Ok(false)
            }
            Err(mpsc::error::TrySendError::Closed(_)) => {
                Err(GatewayError::new("SRT ingress consumer channel closed unexpectedly").boxed())
            }
        }
    }

    fn process_outputs(&self, session: &mut Session) -> GatewayResult<bool> {
        let mut keep_session = true;
        while let Some(output) = session.connection.poll_output() {
            match output {
                ConnectionOutput::SendPacket(payload) => {
                    let datagram = OutboundDatagram {
                        connection_id: Arc::clone(&session.connection_id),
                        peer: session.peer,
                        payload,
                    };
                    match self.egress_sender.try_send(datagram) {
                        Ok(()) => {}
                        Err(mpsc::error::TrySendError::Full(_)) => {
                            self.logger.srt_session_evicted(
                                session.connection_id.as_ref(),
                                session.peer,
                                "control_queue_backpressure",
                            );
                            keep_session = false;
                        }
                        Err(mpsc::error::TrySendError::Closed(_)) => {
                            return Err(GatewayError::new(
                                "SRT UDP egress channel closed unexpectedly",
                            )
                            .boxed());
                        }
                    }
                }
                ConnectionOutput::SetTimer {
                    id,
                    duration_micros,
                } => {
                    session
                        .timers
                        .insert(id, Instant::now() + Duration::from_micros(duration_micros));
                }
                ConnectionOutput::ClearTimer { id } => {
                    session.timers.remove(&id);
                }
            }
        }
        Ok(keep_session)
    }

    fn new_session(&mut self, peer: SocketAddr) -> GatewayResult<Session> {
        self.next_connection_id = self
            .next_connection_id
            .checked_add(1)
            .ok_or_else(|| GatewayError::new("SRT connection ID space exhausted").boxed())?;
        let connection_id: Arc<str> = Arc::from(format!("srt-{}", self.next_connection_id));
        let options = ConnectionOptions {
            socket_id: secure_random_u32()? & 0x7FFF_FFFF,
            initial_seq: Some(secure_random_u32()? & 0x7FFF_FFFF),
            syn_cookie: Some(secure_random_u32()?),
            passphrase: self.config.passphrase.clone(),
            key_length: KeyLength::Aes128,
            tsbpd_delay: self.config.tsbpd_delay_ms,
            ..ConnectionOptions::default()
        };
        Ok(Session {
            connection: SrtConnection::new_listener(options),
            connection_id,
            peer,
            stream_id: None,
            source: None,
            timers: HashMap::new(),
            close_logged: false,
        })
    }

    fn next_timer(&self) -> Option<(SocketAddr, TimerId, Instant)> {
        self.sessions
            .iter()
            .flat_map(|(peer, session)| {
                session
                    .timers
                    .iter()
                    .map(move |(timer_id, deadline)| (*peer, *timer_id, *deadline))
            })
            .min_by_key(|(_, _, deadline)| *deadline)
    }

    fn now_timestamp(&self) -> Timestamp {
        let micros = u64::try_from(self.base_time.elapsed().as_micros())
            .map_or(u64::MAX, std::convert::identity);
        Timestamp::from_micros(micros)
    }

    fn emit_stats(&mut self) {
        for session in self.sessions.values() {
            if let (Some(source), Some(stats)) = (
                session.source.as_deref(),
                session.connection.receiver_stats(),
            ) {
                self.logger.srt_receiver_stats(
                    session.connection_id.as_ref(),
                    session.peer,
                    source,
                    stats,
                );
            }
        }
        if !self.sessions.is_empty() || self.rejected_datagrams > 0 {
            self.logger
                .srt_listener_stats(self.sessions.len(), self.rejected_datagrams);
        }
        self.rejected_datagrams = 0;
    }

    fn remove_session(&mut self, peer: SocketAddr, reason: &'static str) {
        if let Some(mut session) = self.sessions.remove(&peer) {
            self.log_close(&mut session, reason);
        }
    }

    fn log_close(&self, session: &mut Session, reason: &str) {
        if !session.close_logged {
            self.logger.srt_connection_closed(
                session.connection_id.as_ref(),
                session.peer,
                session.source.as_deref(),
                reason,
            );
            session.close_logged = true;
        }
    }

    fn shutdown_all_sessions(&mut self) {
        let now = self.now_timestamp();
        let peers: Vec<_> = self.sessions.keys().copied().collect();
        for peer in peers {
            let Some(mut session) = self.sessions.remove(&peer) else {
                continue;
            };
            session.connection.disconnect(now);
            if let Err(source) = self.process_session(&mut session, Instant::now(), now) {
                self.logger.srt_session_error(
                    session.connection_id.as_ref(),
                    session.peer,
                    "shutdown_error",
                    source.as_ref(),
                );
            }
            self.log_close(&mut session, "gateway_shutdown");
        }
    }
}

impl SrtEgress {
    /// Drena datagramas hasta que el listener cierre el canal.
    ///
    /// # Errors
    ///
    /// Devuelve error si el canal termina sin una señal de cierre coordinado.
    pub async fn run(mut self) -> GatewayResult<()> {
        let mut peers_with_send_error = HashSet::new();
        while let Some(datagram) = self.receiver.recv().await {
            match self.socket.send_to(&datagram.payload, datagram.peer).await {
                Ok(length) if length == datagram.payload.len() => {
                    if peers_with_send_error.remove(&datagram.peer) {
                        self.logger
                            .srt_udp_send_recovered(datagram.connection_id.as_ref(), datagram.peer);
                    }
                }
                Ok(_) => {
                    if peers_with_send_error.insert(datagram.peer) {
                        self.logger.srt_udp_send_failed(
                            datagram.connection_id.as_ref(),
                            datagram.peer,
                            "partial_datagram",
                        );
                    }
                }
                Err(source) => {
                    if peers_with_send_error.insert(datagram.peer) {
                        self.logger.srt_udp_send_error(
                            datagram.connection_id.as_ref(),
                            datagram.peer,
                            &source,
                        );
                    }
                }
            }
        }

        if self.orderly_shutdown.is_cancelled() {
            Ok(())
        } else {
            Err(GatewayError::new("SRT UDP egress channel closed unexpectedly").boxed())
        }
    }
}

fn is_induction(datagram: &[u8]) -> bool {
    let Ok(SrtPacket::Control(control)) = SrtPacket::decode(datagram) else {
        return false;
    };
    if control.control_type != ControlType::Handshake {
        return false;
    }
    HandshakePacket::decode(&control)
        .is_ok_and(|handshake| handshake.handshake_type == HandshakeType::Induction)
}

fn secure_random_u32() -> GatewayResult<u32> {
    let mut bytes = [0_u8; 4];
    getrandom::fill(&mut bytes).map_err(|source| {
        GatewayError::with_source(
            "failed to generate SRT connection entropy",
            Box::new(source),
        )
        .boxed()
    })?;
    Ok(u32::from_le_bytes(bytes))
}
