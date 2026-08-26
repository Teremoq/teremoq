# ADR-0006: admisión y concurrencia de la federación privada

- Estado: **Blocked by upstream API**
- Fecha: 2026-08-26
- Owner: Distribución y Resiliencia del Gateway
- Revisión upstream auditada: `bf87128affd316463e5dcc7599a45001f222b6de`
- Seguimiento: `upstream/moq-rs-concurrency-limits-proposal.md`

## Decisión

No se declara acotada la concurrencia del relay federado. La revisión fijada de
`moq-rs` no ofrece una frontera pública donde Teremoq pueda limitar y rechazar
de forma inmediata handshakes pendientes ni sesiones autenticadas. Tampoco
ofrece un admission controller de relay. No se añade un knob que no pueda
aplicarse, un segundo endpoint QUIC, un proxy WebTransport, una copia de los
accept loops, vendor, patch ni fork silencioso.

El laboratorio mTLS UDP/4443 continúa siendo exclusivamente un laboratorio.
Ahora anuncia explícitamente `handshake_deadline_enforced=false`,
`handshake_capacity_enforced=false` y `session_capacity_enforced=false`. La
autorización SPIFFE/namespace sigue bloqueada independientemente por ADR-0005.

## Evidencia del source exacto

Se leyó el checkout oficial completo necesario para esta decisión en el commit
fijado. El commit observado en `origin/main` el 2026-08-26 es el mismo commit;
las releases compatibles más recientes continúan siendo
`moq-native-ietf 0.10.0`, `moq-transport 0.16.1` y
`moq-relay-ietf 0.7.25`.

### Handshakes QUIC/WebTransport

`moq-native-ietf/src/quic.rs` define:

```text
Server.accept: FuturesUnordered<BoxFuture<accept_session>>
```

Cada resultado de `quinn::Endpoint::accept()` se introduce con `push()` sin
comprobar longitud ni adquirir capacidad. La colección es privada y
`Server::accept` sólo devuelve una sesión después de QUIC, TLS y, para h3, el
CONNECT WebTransport. El embedder no ve el `quinn::Incoming` y por ello no puede
usar `Incoming::retry`, `refuse`, `ignore`, `remote_address_validated` ni medir
el estado pendiente antes de que upstream lo acepte.

La API pública de cliente tampoco separa esas fases:
`moq_native_ietf::quic::Client::connect` engloba QUIC, TLS y WebTransport
CONNECT. El wrapper de socket configurable tiene tipos QUINN en su contrato;
usarlo desde Teremoq exigiría la dependencia directa prohibida. Por tanto un
handshake QUIC/TLS realmente pendiente es
`untestable_with_pinned_public_api`. Un `sleep` después de que `connect`
retorne sólo representa setup MoQT retrasado y ya no se etiqueta como
handshake.

`build_transport_config()` fija `max_idle_timeout=10s`. Es un timeout por
inactividad de la conexión QUIC, no un deadline monotónico absoluto de
handshake. No existe un timeout público separado para TLS, H3 SETTINGS o CONNECT.

### Sesiones y tasks del relay

`moq-relay-ietf/src/relay.rs::Relay::run` mantiene otro `FuturesUnordered` para
el runner interno, el forwarder opcional y cada conexión aceptada. Cada sesión
se añade con `tasks.push(...)` sin máximo ni `try_acquire`. La métrica
`moq_relay_active_connections` observa después de la aceptación, pero no aplica
admisión y no existe contador enumerable de rechazo por capacidad.

Dentro de cada sesión existen defensas upstream parciales:

- `SessionConfig::max_request_id=100` limita el espacio de requests anunciado;
- `MAX_CONCURRENT_SUBSCRIBE_NAMESPACE_STREAMS=256` y un header timeout de 10 s;
- `MAX_INBOUND_PUBLISH_TRACKS_PER_SESSION=1024` mediante `Semaphore`;
- colas salientes concretas usan canales acotados y QUINN tiene ventanas/buffers
  de transporte.

Estos límites internos no limitan handshakes, conexiones o sesiones globales.
Además varios `FuturesUnordered` de Producer/Consumer son internos y sus límites
no son configurables por Teremoq. Una multiplicación por un número ilimitado de
sesiones sigue siendo ilimitada.

## Puerta de reutilización upstream

Se buscaron en source, changelogs, releases y en issues/PRs oficiales, abiertos
y cerrados, combinaciones de `handshake limit`, `max connections`, `session
limit`, `admission`, `overload`, `retry` y `address validation`. No apareció una
API o trabajo oficial que cierre el gap.

QUINN 0.11.11 sí expone los primitivos adecuados en `Endpoint::accept` e
`Incoming`, además de `Endpoint::open_connections`. Rustls 0.23.43 no gestiona
la admisión global. Esos primitivos quedan detrás del `Server` privado de
`moq-native-ietf`; usarlos directamente exigiría reconstruir la integración
que esta tarea prohíbe. Por ello no se realiza actualización atómica: el main
oficial y el commit fijado coinciden y no existe release compatible superior.

## Límites efectivos existentes

| Frontera | Límite efectivo | Configurable | Resultado de saturación |
| --- | ---: | --- | --- |
| Sesiones SRT | 32 por defecto, 1..=256 | Sí | inducción N+1 rechazada sin crear sesión |
| Canal SRT hacia media | 1024 mensajes, 1..=65536 | Sí | se expulsa sólo esa sesión |
| Canal SRT de control | 512 datagramas, 1..=65536 | Sí | se expulsa sólo esa sesión |
| Pipeline media | ligado a `SRT_MAX_SESSIONS` | Sí, indirecto | sesión/pipeline aislado |
| Cola media de entrada | 4 MiB por defecto, 188 B..=64 MiB | Sí | backpressure/aislamiento local |
| Cola media de salida | 256 Objects por Track, 1..=65536 | Sí | rechazo local observable |
| Scheduler | 32 subscribers, 1..=256 | Sí | registro N+1 rechazado |
| Cola scheduler | 256 Objects y 16 MiB por subscriber | Sí | delta drop; crítico expulsa subscriber |
| Publisher Gateway→relay | exactamente una generación activa | Estructural | reconexión serial después del cierre |
| Presupuesto de reconexión | 30 intentos/60 s por defecto | Sí | espera cancelable hasta liberar ventana |
| Conexión/setup publisher | 5 s por fase por defecto | Sí | fallo recuperable y backoff |
| Requests MoQT por sesión | `max_request_id=100` upstream | No en el publisher actual | error de protocolo upstream |
| Handshakes entrantes relay | **sin límite efectivo demostrado** | No | gap |
| Sesiones relay | **sin límite efectivo demostrado** | No | gap |
| Publishers/subscribers globales relay | **sin límite efectivo demostrado** | No | gap |

Los límites de Docker, cgroup, PID y firewall son defensa adicional y no cambian
las tres últimas filas.

## Pruebas y alcance de la evidencia

`tests/federation_concurrency.rs` cubre herméticamente lo que sí puede afirmarse:

1. clientes reales de la API upstream con certificado ausente, CA errónea, EKU
   errónea y certificado expirado fallan durante `transport_connect` (QUIC,
   TLS y WebTransport CONNECT no son separables) mientras peers válidos
   progresan;
2. una conexión que ya completó `transport_connect` y demora
   `Publisher::connect` no impide que otra sesión complete setup MoQT;
3. el límite real del scheduler rechaza N+1, recupera capacidad al hacer `Drop`
   y mantiene aisladas las colas rápida y lenta;
4. cierre y cancelación recuperan registros y tasks del harness.

La prueba usa una carga finita. Deliberadamente no afirma que el
`FuturesUnordered` upstream esté acotado. Un peer “no autorizado” por SPIFFE no
se puede distinguir de un certificado mTLS válido hasta resolver ADR-0005.

El harness `chaos/federation` ejecuta smoke sin capacidades y hostile dentro de
una bridge exclusiva; sólo los casos hostile con netem reciben `NET_ADMIN`.
Captura
RSS, tasks/hilos, sockets y timings separados por fase con número de muestras.
No mezcla rechazos de transporte con setup MoQT en percentiles. Cuando la API no expone
pending handshakes o tasks Tokio, el reporte escribe `unobservable`, nunca cero.

Antes de corregir el reader, el perfil hostile mínimo ejecutado el 2026-08-26
(`60 s`, `20 Hz`, Objects de `8192 B`, delay `35 +/- 15 ms`, pérdida `1%`,
reorder `10%`, rate `20 Mbit`) dio `42/1201` tanto al peer rápido como al lento.
La **primera** aserción que falló fue `slow consumer did not demonstrate
isolated lag`; el umbral de progreso del 95% también habría fallado después.
La causa raíz era local al test: tras obtener un `Subgroup`, el reader llamaba
una sola vez a `subgroup.next()` y avanzaba al Group siguiente. Con GOP de 30
Objects, 1201 Objects producen aproximadamente 41–42 Groups, que explica el
resultado. Esas muestras no constituyen evidencia de colapso de QUIC, MoQT o
`netem`.

El reader corregido drena cada Object del Subgroup en orden, permite cancelación
mientras espera Track mode, Groups, Objects y chunks, y descarta el payload tras
leer su cabecera acotada de correlación. La matriz post-fix de 60 s produjo:

| Caso | Fast / 1201 | Slow / 1201 | Fast p95 ms (n) | Recovery publisher ms (n) | RSS delta KiB | Tasks inicio→fin |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| baseline | 1201 | 480 | 20 (1201) | 577 (1) | 2232 | 3→2 |
| delay/jitter | 1201 | 480 | 114 (1201) | 999 (1) | 2384 | 3→2 |
| loss | 1201 | 480 | 22 (1201) | 1666 (1) | 2096 | 3→2 |
| reorder | 1201 | 481 | 18 (1201) | 561 (1) | 2232 | 4→2 |
| bandwidth | 1201 | 481 | 22 (1201) | 582 (1) | 2148 | 3→2 |
| combined | 1201 | 469 | 147 (1201) | 1048 (1) | 2560 | 3→2 |

Todos pasaron los criterios preexistentes, terminaron con colas del publisher a
cero, `publisher_dropped=0`, cleanup verificado y exit code cero. Cada fila es
una única muestra finita: no prueba ausencia de leak, capacidad productiva ni
concurrencia acotada del relay.

El transporte hostile publica únicamente `TrackId::VideoHq` y en las muestras
anteriores `publisher_dropped=0`. Por tanto no demuestra Object Dropping
multitrack ni prioridad de audio/telemetría. Esa prioridad sí está cubierta por
pruebas herméticas del scheduler; la integración MoQT multitrack continúa
pendiente.

`tc`/iproute2 6.1 de la imagen no ofrece la opción `netem seed`. El seed del
perfil identifica la carga y el reporte, pero el RNG de pérdida/reorder del
kernel no es reproducible bit a bit. Los parámetros, imagen y resultados sí se
registran; una imagen futura con una API oficial de seed es necesaria para
repetición determinista del patrón exacto.

## Observabilidad

El ejemplo 4443 emite una vez `federation_capacity_unenforced` con reason
enumerable `upstream_api_missing`. No se añaden direcciones, certificados,
SPIFFE, namespaces ni errores crudos como labels. Los eventos de rechazo y
transición de capacidad solicitados sólo pueden añadirse cuando exista una
decisión de admisión real donde medirlos.

## Riesgos residuales y condición productiva

- Un flood puede hacer crecer handshakes pendientes y sesiones/tasks del relay.
- El idle timeout no evita crecimiento durante la ventana ni es un deadline
  absoluto si existe actividad parcial.
- Un límite de memoria o PIDs del contenedor puede convertir el crecimiento en
  caída del proceso, no en rechazo limpio por peer.
- La autorización sigue basada en path en el laboratorio y no en SPIFFE.
- No existe evidencia de soak estable ni pendiente de RSS bajo flood hasta
  disponer de admisión real y métricas de estado interno.
- La matriz hostile finita conserva progreso del peer rápido en este hardware,
  pero no sustituye un soak con ventanas estables ni los límites upstream;
  cualquier réplica futura que falle debe permanecer visible.

El relay federado no es productivo hasta que upstream exponga y Teremoq conecte
límites separados de handshake y sesión, cierre temprano por sobrecarga,
identidad autenticada para autorización y tests de soak sobre hardware/perfil
documentados.

## Estrategia de salida

1. Presentar las dos propuestas de `gateway-rs/upstream/` con autorización del
   usuario.
2. Fijar atómicamente una release/commit oficial draft-16 que incluya ambos
   contratos.
3. Conectar configuración fail-closed con defaults, mínimo y máximo, y usar
   `try_acquire_owned`: nunca esperar capacidad remota en una cola.
4. Repetir regresión ALPN/draft-16/Objects, Smallstep y chaos; medir ventanas de
   RSS estables antes de cambiar el estado de este ADR.

## Dependencias y licencias

No se añaden dependencias al proyecto. Se reutilizan Tokio, QUINN/rustls sólo a
través de `moq-rs` y `rcgen` de test. La imagen de laboratorio se reconstruyó
desde el Dockerfile existente para incluir los plugins GStreamer ya declarados
y los perfiles fijan el digest resultante. Las licencias permanecen sin cambios.
