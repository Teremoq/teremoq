# Dependencias directas de `gateway-rs`

Este inventario registra las decisiones del Paso 1. `Cargo.lock` conserva la resolución exacta, mientras que este documento explica por qué existe cada dependencia y cómo debe actualizarse.

| Dependencia | Fuente fijada | Licencia | Propósito | Owner | Política de actualización |
| --- | --- | --- | --- | --- | --- |
| `axum` | crates.io exacta `0.8.9`; upstream oficial `tokio-rs/axum` | MIT | Servidor HTTP embebido del supervisor local | Observabilidad | Parches solo tras CI, revisión de cabeceras y auditoría de dependencias |
| `tokio` | crates.io, línea LTS `~1.51` | MIT | Runtime, red, señales, tiempo, sincronización y supervisión async | Gateway | Parches LTS automáticos tras CI; cambio de minor mediante ADR ligero |
| `tokio-util` | crates.io `0.7` | MIT | Cancelación coordinada | Gateway | SemVer y CI completa |
| `bytes` | crates.io `1` | MIT | Payloads inmutables compartidos | Media pipeline | SemVer y CI completa |
| `getrandom` | crates.io `0.4` | MIT OR Apache-2.0 | Entropía criptográfica para socket ID, secuencia y cookie SRT | Ingesta | SemVer y pruebas de handshake/cifrado |
| `serde` | crates.io `1`, feature `derive` | MIT OR Apache-2.0 | Deserialización tipada de rutas | Configuración | SemVer y tests de validación |
| `serde_json` | crates.io `1` | MIT OR Apache-2.0 | Lectura estricta de `TEREMOQ_ROUTES_JSON` | Configuración | SemVer y tests de validación |
| `gstreamer` | crates.io exacta `0.25.3`, feature `v1_22` | MIT OR Apache-2.0 | Bindings oficiales del pipeline MPEG-TS | Media pipeline | Actualización coordinada con los crates `gstreamer-*` y pruebas con runtime nativo |
| `gstreamer-app` | crates.io exacta `0.25.2`, feature `v1_22` | MIT OR Apache-2.0 | Fronteras acotadas `appsrc`/`appsink` | Media pipeline | Actualización coordinada con `gstreamer` y fixture end-to-end |
| `mp4` | crates.io exacta `0.14.0` | MIT | Lectura defensiva de cajas `moov`, `moof`, `tfhd` y `trun`; nunca serializa MoQT | Media pipeline | Versión exacta y pruebas con output real de `cmafmux` |
| `rfc6381-codec` | crates.io exacta `0.2.0` | MIT OR Apache-2.0 | Identificador AVC RFC 6381 del catálogo MSF | Media pipeline | Versión exacta y validación con cliente independiente |
| `rustls` | crates.io exacta `0.23.43`, `default-features = false`, features `ring`, `std`; upstream `rustls/rustls` | Apache-2.0 OR ISC OR MIT | Construcción TLS 1.3 mTLS cliente y servidor del laboratorio mediante APIs oficiales | Seguridad/Distribución | Versión exacta; actualizar junto con `moq-native-ietf` y ejecutar matriz PKI/QUIC completa |
| `rustls-pki-types` | crates.io exacta `1.15.1`, `default-features = false`, feature `std`; upstream `rustls/pki-types` | MIT OR Apache-2.0 | Tipos DER e iteradores `PemObject`; evita parser PEM propio | Seguridad/Distribución | Versión exacta; revisar API PEM y compatibilidad rustls en cada cambio |
| `base64` | crates.io exacta `0.22.1` | MIT OR Apache-2.0 | `initData` CMAF del catálogo MSF | Distribución | Versión exacta y test de catálogo |
| `tracing` | crates.io `0.1` | MIT | Eventos estructurados | Observabilidad | SemVer y validación del esquema de eventos |
| `tracing-subscriber` | crates.io `0.3` | MIT | Logs JSON y filtros | Observabilidad | SemVer y validación de salida JSON |
| `moq-transport` | Cloudflare `moq-rs` rev `bf87128affd316463e5dcc7599a45001f222b6de`, crate `0.16.1` | MIT OR Apache-2.0 | Protocolo MoQT draft-16 | Distribución | Solo revisión exacta probada con interop; nunca rama flotante |
| `moq-native-ietf` | Misma revisión Cloudflare, crate `0.10.0` | MIT OR Apache-2.0 | QUIC, TLS y WebTransport nativo para MoQT | Distribución | Se actualiza atómicamente con `moq-transport` |
| `url` | crates.io exacta `2.5.8` | MIT OR Apache-2.0 | Parseo y validación de la URL del relay sin manipulación manual | Distribución | Parches tras CI e interop |
| `shiguredo_srt` | crates.io, versión exacta `2026.1.0-canary.1` | Apache-2.0 | Backend SRT Rust experimental de la PoC | Ingesta | Requiere bake-off e interoperabilidad con Haivision antes de cada cambio |

Las dependencias de desarrollo `moq-relay-ietf 0.7.25` (misma revisión Cloudflare), `rcgen 0.14.9`, `pem 3.0.6`, `sha2 0.10.9`, `time 0.3.55`, `async-trait 0.1.89` y `anyhow 1.0.104` existen para los relays locales, la PKI efímera de tests, el certificado WebTransport de vigencia acotada, su fingerprint DER y la prueba de interoperabilidad. Todas son MIT o MIT/Apache-2.0. `hyper 1.4.1` y `hyper-util 0.1.3` reproducen el lockfile de la revisión upstream: versiones posteriores rompen la compilación de `hyper-serve 0.6.2`. No entran en el binario `gateway-rs`. La feature `test-util` de Tokio controla el reloj monotónico en tests.

## Evaluación de dependencias para autorización federada

No se añadió ninguna dependencia en esta Task y no se modificaron `Cargo.toml` ni
`Cargo.lock`.

- `quinn 0.11.11` (MIT OR Apache-2.0, publicado 2026-06-22, upstream
  `quinn-rs/quinn`) ya es transitivo de `moq-native-ietf` y ofrece
  `Connection::peer_identity()`. Se rechazó declararlo directo porque obligaría
  a reconstruir el accept loop que `moq-native-ietf` no expone.
- Las releases compatibles más recientes de Cloudflare siguen siendo
  `moq-native-ietf 0.10.0` (2026-07-20), `moq-relay-ietf 0.7.25` y
  `moq-transport 0.16.1` (ambas 2026-07-31), MIT OR Apache-2.0. Ninguna expone
  identidad cliente al punto de autorización. El commit fijado de 2026-08-18
  tampoco lo hace.
- No se evaluó ni añadió parser X.509: parsear SPIFFE antes de disponer de una
  ruta de enforcement produciría código muerto o una garantía falsa.
- No se añadió `wtransport`, un segundo stack QUIC/TLS, un fork, patch o
  dependencia Git adicional. La salida requerida es una API upstream, descrita
  en `upstream/moq-rs-peer-identity-proposal.md`.

## Herramientas externas del Paso 7

| Herramienta | Versión fijada o evidencia | Licencia | Uso |
| --- | --- | --- | --- |
| `englishm/moq-interop-runner` | commit `956129f28e323902c7d46068a5ceef54aa98b9ac` | MIT OR Apache-2.0 | Matriz externa MoQT; se ejecuta fuera del artefacto |
| Cliente oficial del runner `moq-rs` | imagen `ghcr.io/englishm/moq-interop-runner-moq-test-client@sha256:80b062f753f7d28add68bd3f1c0ccdbeff5b244a41d7432f6afc44ff77a3f087` | MIT OR Apache-2.0 | Cliente de contraste draft-16 |
| `facebookexperimental/moxygen` | relay público mantenido por upstream; experimental | Apache-2.0 | Peer externo del runner; no se enlaza ni distribuye |
| `tc netem` / `iproute2` | Debian `6.1.0-3` | GPL-2.0-or-later | Emulación de red solo en contenedor de test |
| Imagen Rust del banco | `rust@sha256:d0a4aa3ca2e1088ac0c81690914a0d810f2eee188197034edf366ed010a2b382` | conjunto de toolchain/contenedor upstream | Compilación reproducible del test; no es imagen de entrega |

Las herramientas GPL del banco no se incorporan al binario ni a la imagen de entrega. `moxygen` no sustituye a `moq-rs`: actúa únicamente como implementación independiente de contraste. La ejecución externa actual es parcial (7/8), por lo que no habilita una afirmación de conformidad completa.

## Componentes seleccionados para reproducción y comparación

| Componente | Versión/revisión fijada | Licencia | Decisión |
| --- | --- | --- | --- |
| Player propio de `supervisor-web` | Código local TypeScript/React; sin SDK multimedia de terceros | Licencia del proyecto | Cliente activo WebTransport/WebCodecs/canvas, limitado a Track 0/H.264 y al contrato MoQT draft-16 fijado |
| MediaMTX | release `v1.20.0`, commit `1b943637a4b5778bb929a7af7687b048fecaa03f`; índice OCI `sha256:86e63af28616d5e5a18540d7b031b6510bd4cbf1a3c7d224f9e2976f02aefbfb` | MIT | Observador SRT→WebRTC aislado para la vista de entrada; solo laboratorio |
| `gst-plugin-fmp4` / `cmafmux` | tag `gstreamer-1.22.12`, commit `a84bbc66f30573b62871db163c48afef75adf6ec`, plugin `0.9.13` | MPL-2.0 | Empaquetador CMAF preferido, cargado dinámicamente y sin codecs |
| MOQtail | tag `moqtail@0.12.1`, commit `8afe20d696c6a4990474f7bcaa52eda91582b5ba` | Apache-2.0 | Peer CMSF draft-16 de contraste; no forma parte del binario |
| `video-dev/moq-js` | release `0.4.3` | MIT OR Apache-2.0 | Solo contraste draft-14; no es compatible con el transporte draft-16 fijado |

La decisión completa, alternativas y criterios de aceptación se documentan en `ADR-0002-BROWSER-PLAYBACK-AND-CMAF.md`. Ninguno de estos componentes autoriza transcodificación dentro del Gateway.

## Decisiones y límites conocidos

- `moq-native-ietf 0.10.0` activa `tokio/full` en su manifiesto upstream. Teremoq declara únicamente sus features directas necesarias; retirar la activación transitiva requeriría un cambio upstream o una nueva release, no un fork local silencioso.
- `moq-native-ietf 0.10.0` activa las features por defecto de su dependencia rustls además de `ring`; la declaración directa de Teremoq desactiva defaults y pide sólo `ring`/`std`, pero la unificación Cargo conserva lo exigido transitivamente por upstream. No se parchea ni bifurca el crate para alterar esa resolución.
- `rustls` y `rustls-pki-types` ya estaban fijadas transitivamente en el lockfile; Task 02 las declara directas sólo porque `security::mtls` usa sus APIs públicas. `rustls-pemfile` permanece exclusivamente transitiva.
- `shiguredo_srt` exige Rust 1.93 y todavía no es un backend aprobado para producción.
- El workspace Git de Shiguredo en la revisión `29d785f4dca1dead9ce384a8ced6b492453010a0` contiene manifiestos TOML inválidos en dos ejemplos. Se usa la release publicada exacta, cuyo paquete excluye esos miembros defectuosos; no se mantiene un parche o fork local.
- `wtransport` no es dependencia directa: MoQT y su transporte se obtienen del mismo checkout de Cloudflare para evitar dos stacks QUIC.
- `axum` reutiliza Tokio/Hyper y se compila únicamente con `http1`, `json` y `tokio`; el supervisor no necesita HTTP/2, WebSockets, plantillas ni un toolchain JavaScript.
- `gstreamer 0.25.2` no era combinable con `gstreamer-base 0.25.3` por una macro interna ausente; se fija `gstreamer 0.25.3` y `gstreamer-app 0.25.2`, combinación compilada y probada. No deben actualizarse por separado.
- Haivision SRT sigue siendo la implementación de referencia. Su eventual integración nativa necesita un ADR específico de FFI y MPL-2.0.
- La alternativa evaluada en `ADR-0002` divergía de la revisión fijada de `moq-rs` al codificar `GROUP_ORDER=PUBLISHER`. La excepción terminó y esa alternativa no es configuración, dependencia ni asset servido por el sistema. La evidencia reproducible permanece solo en la ADR histórica.

## Runtime y plugins multimedia nativos

El artefacto requiere `GStreamer >= 1.22` enlazado dinámicamente (LGPL-2.1-or-later) y `cmafmux` 0.9.13 cargado dinámicamente (MPL-2.0). Se auditan al inicio únicamente estas factorías: `appsrc`, `tsdemux`, `queue`, `capsfilter`, `appsink`, `fakesink`, `h264parse`, `h265parse`, `mpegvideoparse`, `aacparse`, `opusparse`, `ac3parse`, `identity` y `cmafmux`. `tsdemux` procede de `gst-plugins-bad`; `cmafmux`, del checkout oficial y fijado de `gst-plugins-rs`; el resto se resuelve desde los módulos oficiales correspondientes de GStreamer. El proceso falla antes de escuchar SRT si falta una factoría o si su clase declara `Decoder` o `Encoder`.

La imagen de entrega no debe instalar colecciones completas de plugins por conveniencia. El empaquetado final debe incluir solo bibliotecas/factorías auditadas, conservar enlace dinámico y publicar los avisos LGPL. La fixture sintética de integración es CC0-1.0 y su procedencia está en `tests/fixtures/README.md`.

`target-lexicon`, dependencia de build de `system-deps`/`gstreamer-rs`, usa `Apache-2.0 WITH LLVM-exception`. Es una licencia permisiva aprobada explícitamente en `deny.toml`; no se enlaza como lógica multimedia del Gateway.

## Excepciones temporales de auditoría

- `RUSTSEC-2024-0436` afecta a `paste 1.0.15`, dependencia transitiva de `moq-transport`. El aviso declara el crate sin mantenimiento, no una vulnerabilidad conocida, y no ofrece una versión corregida. Owner: Distribución.
- `RUSTSEC-2025-0134` afecta a `rustls-pemfile 2.2.0`, dependencia transitiva de `moq-native-ietf`. El aviso declara el crate sin mantenimiento, no una vulnerabilidad conocida, y no ofrece una versión corregida. Owner: Distribución.
- Ambas excepciones están acotadas por identificador en `deny.toml`. Deben revisarse en cada actualización de `moq-rs` y eliminarse antes de producción en cuanto upstream publique una ruta de migración.
- `webpki 0.22.4` omite el campo `license` de su manifiesto. `deny.toml` aclara su licencia ISC y verifica el hash exacto de su fichero `LICENSE`.
- `webpki-root-certs` distribuye datos de certificados bajo `CDLA-Permissive-2.0`; la licencia se permite exclusivamente por su carácter permisivo y su uso como dataset de raíces de confianza.
