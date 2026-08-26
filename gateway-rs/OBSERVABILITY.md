# Eventos de los Pasos 2 a 7 y supervisor local

Los eventos se emiten en JSON de una sola línea por `stdout`. El formatter añade `timestamp` UTC y `level`; cada evento añade `schema_version`, `event`, `service` e `instance_id`.

## Ciclo de vida

| Evento | Nivel | Campos específicos | Significado |
| --- | --- | --- | --- |
| `gateway_started` | INFO | `shutdown_timeout_ms` | Configuración validada y tasks a punto de supervisarse |
| `critical_task_started` | INFO | `task` | Task crítica registrada en el `JoinSet` |
| `shutdown_requested` | INFO | `reason` | Inicio de cancelación coordinada |
| `critical_task_stopped` | INFO | `task` | Task terminada dentro del deadline |
| `critical_task_failed` | ERROR | `task`, `error` | Fallo o terminación inesperada que cancela dependientes |
| `shutdown_deadline_exceeded` | ERROR | `pending_tasks`, `deadline_ms` | Tasks restantes abortadas al expirar el cierre |
| `gateway_stopped` | INFO | — | Supervisor drenado; no implica por sí solo que el resultado sea exitoso |

Valores estables actuales de `reason` para cierre de proceso: `ctrl_c`, `terminate` e `internal`. Los nombres de task son valores de baja cardinalidad definidos por el proceso.

## SRT

| Evento | Nivel | Campos específicos | Significado |
| --- | --- | --- | --- |
| `srt_listener_bound` | INFO | `bind_addr`, `max_sessions`, `encryption_enabled` | UDP enlazado y listo para handshakes SRT |
| `srt_connection_opened` | INFO | `connection_id`, `peer`, `source`, `stream_id_length`, `encryption_enabled` | Handshake completado y Stream ID autorizado |
| `srt_connection_rejected` | WARN | `peer`, `reason`, `datagram_bytes` | Datagrama de un peer nuevo rechazado antes de crear sesión |
| `srt_stream_id_rejected` | WARN | `connection_id`, `peer`, `reason`, `stream_id_length` | Stream ID ausente o no autorizado |
| `srt_connection_closed` | INFO | `connection_id`, `peer`, `source`, `reason` | Sesión cerrada dentro de su propio dominio de fallo |
| `srt_session_error` | WARN | `connection_id`, `peer`, `reason`, `error` | Error de backend o protocolo limitado a la sesión |
| `srt_session_evicted` | WARN | `connection_id`, `peer`, `reason` | Expulsión aislada por backpressure o límite interno |
| `srt_receiver_stats` | INFO | IDs, buffer, loss list, totales, pérdida, RTT, variación RTT y jitter | Estadísticas periódicas de recepción por sesión autorizada |
| `srt_listener_stats` | INFO | `active_sessions`, `rejected_datagrams` | Resumen periódico; no se emite cuando ambos valores son cero |
| `srt_key_refresh_needed` | INFO | `connection_id`, `peer`, `key_length` | El backend solicita material nuevo para rotación de clave |
| `srt_udp_send_failed` | WARN | `connection_id`, `peer`, `reason`, `error` opcional | Primer fallo UDP de un peer; se suprimen repeticiones hasta recuperar |
| `srt_udp_send_recovered` | INFO | `connection_id`, `peer` | Primer envío correcto tras un fallo UDP |

`srt_receiver_stats` usa `loss_rate_percent_x100`: `125` representa `1,25 %`. RTT, variación y jitter se expresan en microsegundos. Los contadores son acumulados por la conexión actual; una reconexión obtiene otro `connection_id`.

Razones estables implementadas:

- `srt_connection_rejected`: `session_limit`.
- `srt_stream_id_rejected`: `missing_stream_id`, `unauthorized_stream_id`.
- `srt_session_evicted`: `payload_before_authorization`, `ingress_queue_backpressure`, `control_queue_backpressure`.
- `srt_session_error`: `protocol_error`, `timer_error`, `backend_event`, `shutdown_error`.
- `srt_udp_send_failed`: `io_error`, `partial_datagram`.

El cierre de sesión puede reflejar razones emitidas por el backend además de `state_disconnected`, `session_evicted`, `protocol_error`, `timer_error`, `oversized_datagram` o `gateway_shutdown`; por ello `reason` no debe analizarse como texto libre para decisiones automáticas hasta ampliar el enum estable.

## MPEG-TS y media

| Evento | Nivel | Campos específicos | Significado |
| --- | --- | --- | --- |
| `media_runtime_ready` | INFO | `gstreamer_version`, `factories`, `zero_transcoding` | Runtime nativo y topología auditados antes de aceptar tráfico |
| `media_pipeline_opened` | INFO | `connection_id`, `peer`, `source`, `programs` | Pipelines por programa creados para una sesión autorizada |
| `mpegts_stream_discovered` | INFO | `connection_id`, `program_number`, `pid`, `track`, `codec` | PMT/PID resuelto y parser codificado conectado |
| `mpegts_program_changed` | INFO | IDs MPEG-TS, `reason` | Un pad desapareció tras un cambio de programa/PMT |
| `mpegts_discontinuity` | WARN | IDs MPEG-TS y `track` | `tsdemux` propagó una discontinuidad de continuidad/PES |
| `media_stream_rejected` | WARN | `connection_id`, `program_number`, `pid`, `error` | PID no configurado, caps incompatibles o códec no admitido; se deriva a `fakesink` |
| `telemetry_invalid_json` | WARN | IDs MPEG-TS, `payload_bytes` | Muestra privada no publicada por JSON inválido |
| `media_output_backpressure` | WARN | `connection_id`, `track`, `reason` | Object excesivo o cola de Track llena; la sesión entra en fallo controlado |
| `media_pipeline_warning` | WARN | `connection_id`, `program_number`, `warning` | Warning del bus nativo sin payload |
| `media_pipeline_failed` | WARN | `connection_id`, `peer`, `error` | Corrupción, negociación o backpressure aislados a una conexión |
| `media_pipeline_closed` | INFO | IDs, `program_number`, `reason` | Recursos nativos liberados |

`reason` estable de cierre incluye `pipeline_error`, `idle_or_bus_error` y `gateway_shutdown`. Los errores nativos son diagnóstico y no deben usarse como contrato de automatización.

## Scheduler y Object Dropping

| Evento | Nivel | Campos específicos | Significado |
| --- | --- | --- | --- |
| `scheduler_subscriber_opened` | INFO | `subscriber_id`, límites de Objects y bytes | Cola aislada registrada |
| `scheduler_subscriber_closed` | INFO | `subscriber_id` | Cola y memoria liberadas |
| `scheduler_subscriber_failed` | WARN | `subscriber_id`, `error` | Fallo limitado al consumidor o publisher |
| `object_dropped` | INFO | IDs, Track, Priority, edad, deadline, cola y `reason` | Descarte esperado y local; no es un fallo del proceso |
| `subscriber_evicted_critical_backpressure` | WARN | IDs, cola, deadline y `reason` | Audio/telemetría no progresan; se cierra solo la sesión |

Razones estables de `object_dropped`: `queue_backpressure`, `queue_deadline_expired`, `dependency_not_decodable` y `group_superseded`. Razones estables de expulsión: `critical_queue_backpressure` y `critical_queue_deadline_expired`.

## MoQT draft-16

| Evento | Nivel | Campos específicos | Significado |
| --- | --- | --- | --- |
| `moq_publisher_ready` | INFO | `local_addr`, `draft`, `alpn` | Endpoint cliente QUIC creado |
| `moq_connection_attempt` | INFO | `relay`, `generation` | Inicio de conexión; `relay` no contiene path ni query |
| `moq_connection_failed` | WARN | `relay`, `generation`, `error` | Fallo recuperable antes de publicar |
| `moq_reconnect_scheduled` | INFO | `relay`, `generation`, `consecutive_failures`, `delay_ms` | Backoff exponencial acotado con jitter antes de reintentar |
| `moq_retry_budget_exhausted` | WARN | `relay`, `maximum_attempts`, `window_ms`, `resume_after_ms` | Presupuesto móvil agotado; el publisher espera sin detener la ingesta |
| `moq_connected` | INFO | `connection_id`, `relay`, `generation` | WebTransport y setup MoQT completados |
| `moq_namespace_publish_started` | INFO | `namespace` | `PUBLISH_NAMESPACE` entregado a la API upstream |
| `moq_object_published` | DEBUG | IDs, Track, Priority, Group, Object, bytes, PTS/DTS, `ingest_to_publish_ms` | Object codificado escrito mediante `serve::Subgroups`; no incluye payload |
| `moq_disconnected` | INFO | `connection_id`, `reason` | Cierre normal antes de reconexión |
| `moq_session_failed` | WARN | `connection_id`, `error` | Fallo aislado de sesión antes de reconexión |

## Privacidad y cardinalidad

- Nunca se registran passphrases, payloads ni el valor del Stream ID.
- `source` procede exclusivamente de configuración validada y sustituye al Stream ID en observabilidad.
- `connection_id` identifica un intento de conexión, no una fuente lógica; una reconexión crea uno nuevo.
- Las métricas repetitivas se agregan al intervalo configurado y los errores de envío UDP se registran solo en cambios de estado.

## Supervisor web

| Evento | Nivel | Campos específicos | Significado |
| --- | --- | --- | --- |
| `supervisor_web_bound` | INFO | `bind_addr` | Dashboard local y API de snapshots disponibles |
| `supervisor_web_unavailable` | WARN | `bind_addr`, `error`, `retry_delay_ms` | Fallo aislado; el servidor reintenta sin cancelar el camino de señal |

Los snapshots no son un segundo contrato de ingestión: exponen contadores acumulados, edad monotónica, la última cabecera observada por fase y una ventana acotada a 4096 muestras de `ingest_to_publish`. El monitor no retiene payloads ni Stream IDs. Una contención interna omite la actualización de observabilidad antes que bloquear el directo. `network_and_subscriber`, `presentation` y `glass_to_glass` permanecen nulos hasta disponer de medición y calibración extremo a extremo.
