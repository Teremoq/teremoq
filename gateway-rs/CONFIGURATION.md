# Configuración del Gateway y supervisor local

El proceso valida toda la configuración y prepara la identidad mTLS/endpoint QUIC antes de abrir el listener SRT. La ingesta usa modo Listener en UDP/9000 y el publisher MoQT se conecta por WebTransport al relay privado configurado.

## Proceso

| Variable | Predeterminado | Validación | Propósito |
| --- | --- | --- | --- |
| `TEREMOQ_INSTANCE_ID` | `gateway-dev-1` | 1–64 caracteres ASCII alfanuméricos, `.`, `_` o `-` | Identidad de baja cardinalidad incluida en todos los eventos |
| `TEREMOQ_LOG` | `info` | 1–256 bytes y directiva válida de `EnvFilter` | Nivel y filtros de logs |
| `TEREMOQ_SHUTDOWN_TIMEOUT_MS` | `3000` | 100–30000 ms | Deadline monotónico del cierre de tasks críticas |
| `TEREMOQ_SUPERVISOR_BIND_ADDR` | `127.0.0.1:9080` | `SocketAddr` loopback con puerto distinto de cero | Dashboard y API de snapshots de solo lectura |
| `TEREMOQ_SUPERVISOR_INPUT_PREVIEW_URL` | `http://127.0.0.1:8889/input?autoplay=true&muted=true&controls=true` | URL HTTP(S) loopback, sin credenciales ni fragmento; vacío deshabilita | Página WebRTC del observador SRT externo |
| `TEREMOQ_SUPERVISOR_MOQ_FINGERPRINT_PATH` | `.teremoq-dev/tls/relay-cert.sha256` | Ruta o vacío | SHA-256 DER del certificado WebTransport del relay |

## Ingesta SRT

| Variable | Predeterminado | Validación | Propósito |
| --- | --- | --- | --- |
| `TEREMOQ_SRT_BIND_ADDR` | `0.0.0.0:9000` | `SocketAddr` IP con puerto distinto de cero | Listener SRT sobre UDP |
| `TEREMOQ_SRT_PASSPHRASE` | sin cifrado | 10–79 bytes cuando existe | Passphrase SRT; nunca se registra ni aparece en `Debug` |
| `TEREMOQ_SRT_MAX_SESSIONS` | `32` | 1–256 | Límite de peers simultáneos |
| `TEREMOQ_SRT_INGRESS_QUEUE_CAPACITY` | `1024` | 1–65536 mensajes | Canal acotado SRT → pipeline; al saturarse se expulsa solo la sesión causante |
| `TEREMOQ_SRT_EGRESS_QUEUE_CAPACITY` | `512` | 1–65536 datagramas | Canal acotado para ACK, NAK y control UDP |
| `TEREMOQ_SRT_TSBPD_DELAY_MS` | `120` | 20–65535 ms | Latencia TSBPD anunciada al backend |
| `TEREMOQ_SRT_STATS_INTERVAL_SECS` | `5` | 1–300 s | Cadencia de estadísticas mientras existan sesiones o rechazos |
| `TEREMOQ_ROUTES_JSON` | tabla mostrada abajo | JSON de hasta 65536 bytes | Autorización de Stream ID y routing MPEG-TS exacto |

La clave SRT es AES-128 en esta PoC. Todos los Stream IDs deben figurar en la tabla de routing; los desconocidos o ausentes se desconectan tras el handshake.

## Contrato de routing

`TEREMOQ_ROUTES_JSON` es un array de exactamente cuatro reglas, una por Track:

```json
[
  {"source":"main","stream_id":"teremoq-main","program_number":1,"pid":256,"track":0},
  {"source":"fallback","stream_id":"teremoq-lq","program_number":1,"pid":256,"track":1},
  {"source":"main","stream_id":"teremoq-main","program_number":1,"pid":257,"track":2},
  {"source":"telemetry","stream_id":"teremoq-telemetry","program_number":1,"pid":300,"track":3}
]
```

Cada regla admite solo `source`, `stream_id`, `program_number`, `pid` y `track`. La validación rechaza:

- Tracks ausentes, fuera de `0..=3` o reclamados más de una vez.
- Claves `Stream ID + program_number + PID` duplicadas.
- Una etiqueta `source` asociada a varios Stream IDs, o un Stream ID asociado a varias etiquetas.
- `program_number = 0`, PIDs fuera del rango elemental `32..=8190`, Stream IDs vacíos o de más de 512 bytes y campos desconocidos.

`source` es la etiqueta segura para logs; el Stream ID real se usa para autorizar y resolver rutas, pero no se registra. El demultiplexor `GStreamer` del Paso 4 aplica esta resolución exacta sobre los pads elementales producidos por `tsdemux`.

## Pipeline multimedia

| Variable | Predeterminado | Validación | Propósito |
| --- | --- | --- | --- |
| `TEREMOQ_MEDIA_INPUT_QUEUE_BYTES` | `4194304` | 188–67108864 bytes | Máximo pendiente en cada `appsrc` aislado por conexión/programa |
| `TEREMOQ_MEDIA_OUTPUT_QUEUE_OBJECTS` | `256` | 1–65536 Objects | Capacidad independiente de salida para cada Track |
| `TEREMOQ_MEDIA_MAX_OBJECT_BYTES` | `8388608` | 188–33554432 bytes | Límite de una access unit codificada |
| `TEREMOQ_MEDIA_SESSION_IDLE_TIMEOUT_MS` | `30000` | 1000–300000 ms | Libera pipelines de conexiones sin tráfico |

Una cola de entrada llena o un error nativo cierra únicamente el pipeline de esa conexión. Una cola crítica llena no convierte audio o telemetría en un descarte normal: fuerza error controlado y aislamiento de la sesión.

## Scheduler por suscriptor

| Variable | Predeterminado | Validación | Propósito |
| --- | --- | --- | --- |
| `TEREMOQ_SCHEDULER_MAX_SUBSCRIBERS` | `32` | 1–256 | Máximo de colas de distribución independientes |
| `TEREMOQ_SCHEDULER_QUEUE_OBJECTS` | `256` | 1–65536 Objects | Límite de Objects por suscriptor |
| `TEREMOQ_SCHEDULER_QUEUE_BYTES` | `16777216` | 188–268435456 bytes | Límite de memoria por suscriptor |
| `TEREMOQ_SCHEDULER_DELTA_DEADLINE_MS` | `150` | 1–60000 ms | TTL de vídeo dependiente, Prioridad 2 |
| `TEREMOQ_SCHEDULER_RANDOM_ACCESS_DEADLINE_MS` | `1000` | 1–60000 ms | Deadline de puntos de acceso, Prioridad 1 |
| `TEREMOQ_SCHEDULER_CRITICAL_DEADLINE_MS` | `2000` | 1–60000 ms | Deadline operativo antes de expulsar una sesión bloqueada |

Los deadlines deben cumplir `delta <= random_access <= critical`. Los límites se aplican simultáneamente por Objects y bytes. El publisher registra una cola `moq-relay-N` únicamente mientras existe una sesión MoQT: durante una desconexión no acumula vídeo antiguo y reintenta sin detener la ingesta.

## Publicación MoQT

| Variable | Predeterminado | Validación | Propósito |
| --- | --- | --- | --- |
| `TEREMOQ_MOQ_RELAY_URL` | `https://127.0.0.1:4443/publish` | URL `https://` o `moqt://`, con host y sin usuario, query ni fragmento | Endpoint del relay federado privado; la ruta no sustituye autorización por identidad |
| `TEREMOQ_MOQ_BIND_ADDR` | `[::]:0` | `SocketAddr` IP | Socket UDP cliente QUIC; puerto efímero por defecto |
| `TEREMOQ_MOQ_NAMESPACE` | `teremoq/live` | Path ASCII de hasta 256 bytes, sin segmentos vacíos, `.` o `..` | Namespace anunciado mediante `PUBLISH_NAMESPACE` |
| `TEREMOQ_MOQ_TLS_ROOT` | obligatorio | Path no vacío a fichero regular con uno o más certificados | Trust store explícito del relay; nunca se usan raíces del sistema |
| `TEREMOQ_MOQ_TLS_CLIENT_CERT` | obligatorio | Path no vacío a fichero regular | Cadena cliente completa en orden leaf → intermediate |
| `TEREMOQ_MOQ_TLS_CLIENT_KEY` | obligatorio | Path no vacío a fichero regular, no symlink; en Unix `mode & 077 == 0` | Única clave privada de la identidad Gateway |
| `TEREMOQ_MOQ_TLS_DISABLE_VERIFY` | deprecada, ausente | `true`/`1` se rechaza; `false`/`0` se acepta temporalmente sin efecto | Compatibilidad fail-closed; reason `tls_verification_disabled_forbidden` al intentar el bypass |
| `TEREMOQ_MOQ_RECONNECT_DELAY_MS` | `1000` | 100–30000 ms | Backoff exponencial inicial entre sesiones, sin afectar SRT/media |
| `TEREMOQ_MOQ_RECONNECT_MAX_DELAY_MS` | `30000` | 100–30000 ms y no menor que el inicial | Techo efectivo del backoff exponencial, incluido el jitter |
| `TEREMOQ_MOQ_RETRY_MAX_ATTEMPTS` | `30` | 1–1000 | Presupuesto máximo de intentos dentro de la ventana móvil |
| `TEREMOQ_MOQ_RETRY_WINDOW_MS` | `60000` | 1000–3600000 ms | Ventana monotónica del presupuesto de reintentos |
| `TEREMOQ_MOQ_CONNECT_TIMEOUT_MS` | `5000` | 100–30000 ms | Timeout de conexión QUIC y setup MoQT |

Las tres variables mTLS son obligatorias para el proceso. Trust store, cadena o clave vacíos se rechazan; no existe conexión anónima, fallback ni bypass. Certificado/clave incompatibles y errores de PKI local son fatales antes de `gateway_started`, GStreamer, SRT y tasks críticas, por lo que nunca se convierten en reintentos de red. La identidad se carga una sola vez y el mismo endpoint se reutiliza en todas las reconexiones.

La espera remota usa el crecimiento exponencial acotado y jitter uniforme del 80–120 % existentes. Al agotar el presupuesto dentro de la ventana, el siguiente intento se aplaza hasta que expire el intento más antiguo; no se crea un bucle agresivo y la ingesta SRT/media continúa. `Debug` de `MoqConfig` no muestra paths PKI, certificados, clave ni SAN; sólo indica `tls_root_configured=true` y `mtls_identity_configured=true`. Los logs registran únicamente el origen seguro del relay.

## Laboratorios MoQT separados

- UDP/4433: `cargo run --locked --example dev_moq_relay`, laboratorio browser/playback existente. Sin configuración adicional conserva bind `127.0.0.1:4433`, SAN `localhost`/`127.0.0.1` y el perfil persistente v1.
- UDP/4443: `cargo run --locked --example dev_mtls_moq_relay`, laboratorio de federación privada mTLS, limitado a loopback y sólo `/publish`.

### SAN LAN opt-in para el laboratorio browser

`TEREMOQ_DEV_RELAY_LAN_IP_SAN` admite una única IPv4 RFC1918 canónica y
no-loopback. No admite nombres DNS, IPv6, CIDR, puerto, ruta, espacios ni una
dirección pública, link-local, multicast o unspecified. El relay no conoce la
máscara de la interfaz: la detección de dirección de red o broadcast corresponde
al preflight de plataforma, que dispone de `prefix_length`; aquí no se inventa
semántica `/24`. La opción
añade esa IP al certificado WebTransport temporal junto a `localhost` y
`127.0.0.1`; no cambia `TEREMOQ_DEV_RELAY_BIND`, que continúa rechazando toda
dirección no-loopback. Para alcanzar el socket desde otra máquina hace falta un
proxy UDP explícito y separado.

El marker del modo LAN está versionado y ligado mediante SHA-256 a la IP
canónica, sin almacenar la IP en claro en el marker. Certificado, clave,
fingerprint y marker se suministran con las variables `TEREMOQ_DEV_RELAY_TLS_*`
y deben ubicarse bajo un directorio runtime ignorado, como `.teremoq-dev/`.
Cualquier mezcla parcial, marker antiguo o cambio de IP falla cerrado y exige
rotar coordinadamente los cuatro ficheros; el relay nunca sobrescribe material
existente. El log sólo indica si el SAN LAN está configurado y no publica su
valor.

El fingerprint es SHA-256 del DER para `serverCertificateHashes` del browser.
Este certificado autofirmado no es la identidad mTLS de los nodos, no autoriza
publish/subscribe y no sustituye la PKI federada. La allowlist de origen del
proxy UDP y Windows Firewall son fronteras operativas independientes que deben
mantenerse acotadas; esta opción no abre puertos ni configura ninguna de ellas.

El relay mTLS exige estas variables y no genera certificados:

| Variable | Predeterminado | Contrato |
| --- | --- | --- |
| `TEREMOQ_DEV_MTLS_RELAY_BIND` | `127.0.0.1:4443` | `SocketAddr` loopback |
| `TEREMOQ_DEV_MTLS_RELAY_TLS_CERT` | obligatorio | Cadena servidor leaf → intermediate |
| `TEREMOQ_DEV_MTLS_RELAY_TLS_KEY` | obligatorio | Clave privada servidor |
| `TEREMOQ_DEV_MTLS_RELAY_CLIENT_CA` | obligatorio | CA(s) que autentican Gateways |

Contrato de artefactos de Task 01:

```bash
set -a
source ../infra/pki/runtime/env/relay-dev-1.env
set +a
cargo run --locked --example dev_mtls_moq_relay

set -a
source ../infra/pki/runtime/env/gateway-dev-1.env
set +a
cargo run --locked --bin gateway-rs
```

`set -a` es necesario cuando el fichero de Task 01 contiene asignaciones sin `export`; no modifica los artefactos y limita la exportación al bloque de carga.

El artefacto actual configura el relay en `127.0.0.1:4443` y la URL del Gateway como `https://localhost:4443/publish`. Si el runtime resuelve `localhost` primero a `::1`, la ejecución exacta termina por timeout porque el laboratorio no escucha IPv6. Para ese runtime se debe exportar después del `source` `TEREMOQ_MOQ_RELAY_URL=https://127.0.0.1:4443/publish`; la identidad de Task 01 incluye ese IP SAN. No es un bypass TLS.

No se modifican esos artefactos desde `gateway-rs`. El relay mTLS de ejemplo es un laboratorio de integración, no el servicio federado productivo final. mTLS autentica el nodo, pero la autorización por identidad y namespace queda fuera de Task 02.

## Estado de autorización federada

La autorización SPIFFE por rol, operación y namespace no está disponible en la
revisión fijada de `moq-rs`. La identidad cliente validada por rustls no forma
parte de `ConnInfo`, `ConnectionMeta`, `Coordinator::resolve_scope` ni
`CoordinatorContext`; consulta `ADR-0005-FEDERATED-AUTHORIZATION.md`.

Por ello no existe todavía `TEREMOQ_FEDERATION_POLICY_PATH` ni un fichero de
política aceptado por el proceso. Añadir esa variable antes de disponer del
punto de enforcement upstream produciría una falsa garantía. `/publish` y
`/watch` siguen siendo rutas de conexión, nunca prueba de identidad ni permiso.
IP, puerto, SNI, path, cabeceras, query strings y valores MoQT tampoco son un
principal federado.

El laboratorio UDP/4443 sólo demuestra autenticación mTLS. No debe exponerse ni
considerarse un relay federado Zero-Trust hasta que la Ruta A de ADR-0005 pueda
aplicar denegación por defecto antes de cada operación de namespace.

## Supervisor web

El panel queda deliberadamente limitado a loopback. No existe una opción de configuración para publicarlo en todas las interfaces durante la PoC. Las URLs y disponibilidades de playback se exponen en `/api/v1/playback`, nunca las rutas locales. La salida se reproduce exclusivamente con el player propio WebTransport/WebCodecs del `supervisor-web`; el Gateway no carga ni sirve librerías de reproducción de terceros. Consulta `SUPERVISOR.md` para las rutas, estados y procedimiento de evaluación.

## Cierre

El proceso escucha `Ctrl-C` y, en Unix, `SIGTERM`. Una señal deja de aceptar datagramas, desconecta las sesiones, drena el canal UDP de control y espera las tasks hasta el deadline. Solo aborta las tasks que no cooperen.
