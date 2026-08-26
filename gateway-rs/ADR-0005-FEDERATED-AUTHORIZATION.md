# ADR-0005: autorización federada ligada a la identidad mTLS

- Estado: **Blocked by upstream API**
- Ruta: B
- Fecha de decisión: 2026-08-25
- Owner: Seguridad y Distribución del Gateway
- Seguimiento: `upstream/moq-rs-peer-identity-proposal.md`

## Contexto y conclusión

Teremoq necesita aplicar, antes de aceptar una operación de namespace, el
contrato `identidad SPIFFE autenticada -> rol -> operación -> namespace`. La
autenticación mTLS de `ADR-0004` verifica cadena, vigencia, EKU y posesión de la
clave, pero la identidad verificada no llega a la API pública donde
`moq-relay-ietf` decide permisos, registro, publicación, suscripción o condición
de relay peer.

Se elige la Ruta B. No se implementa una política que parezca autorizar usando
IP, puerto, SNI, path, cabeceras, query string o datos MoQT declarados por el
peer. Tampoco se añade un segundo stack QUIC/TLS, un accept loop propio, un fork
silencioso ni correlación global desde `ClientCertVerifier`.

La autorización federada completa y la afirmación de Zero-Trust permanecen
bloqueadas. Hasta que exista el contrato upstream descrito abajo, el laboratorio
UDP/4443 autentica certificados pero no es un relay federado autorizado para
producción.

## Evidencia upstream reproducible

Se inspeccionó el repositorio oficial Cloudflare `moq-rs`, licencia
MIT OR Apache-2.0, el 2026-08-25. El checkout fijado y el `HEAD` oficial observado
coinciden en `bf87128affd316463e5dcc7599a45001f222b6de`, commit de 2026-08-18.

| Componente | Revisión/release y fecha | Ruta/símbolo | Conclusión |
| --- | --- | --- | --- |
| QUINN | `quinn 0.11.11`, publicada 2026-06-22, MIT OR Apache-2.0 | [`Connection::peer_identity()`](https://docs.rs/quinn/0.11.11/quinn/struct.Connection.html#method.peer_identity) | Después del handshake devuelve la identidad criptográfica; con rustls puede convertirse en `Vec<CertificateDer>`. La API necesaria existe en el transporte subyacente. |
| `moq-native-ietf` | `0.10.0`, tag de 2026-07-20; commit fijado de 2026-08-18 | [`moq-native-ietf/src/quic.rs`, `ConnInfo` y `Server::accept_session`](https://github.com/cloudflare/moq-rs/blob/bf87128affd316463e5dcc7599a45001f222b6de/moq-native-ietf/src/quic.rs) | `accept_session` conserva temporalmente `quinn::Connection`, pero sólo extrae dirección remota, IP local y SNI. `ConnInfo` expone CID, transporte, direcciones y SNI. No llama `peer_identity()` ni expone certificados. |
| `moq-relay-ietf` | `0.7.25`, tag de 2026-07-31; commit fijado de 2026-08-18 | [`ConnectionMeta` y `SessionContext`](https://github.com/cloudflare/moq-rs/blob/bf87128affd316463e5dcc7599a45001f222b6de/moq-relay-ietf/src/session.rs) | `ConnectionMeta` contiene dirección remota, IP local, SNI y path. `SessionContext` deriva el peer interno del socket. No existe principal autenticado. |
| `moq-relay-ietf` | misma revisión | [`Coordinator`, `CoordinatorContext` y `resolve_scope`](https://github.com/cloudflare/moq-rs/blob/bf87128affd316463e5dcc7599a45001f222b6de/moq-relay-ietf/src/coordinator.rs) | `resolve_scope` sólo recibe el path. Su default concede `ReadWrite` a cualquier path y deja sin scope, también con publish/subscribe, una conexión sin path. `CoordinatorContext::source` se deriva explícitamente del socket. |
| `moq-relay-ietf` | misma revisión | [`Relay::run` / aceptación de sesión](https://github.com/cloudflare/moq-rs/blob/bf87128affd316463e5dcc7599a45001f222b6de/moq-relay-ietf/src/relay.rs) | Resuelve permisos desde el path y después clasifica interfaz mediante socket, IP local, SNI y path. Ninguna de esas señales está ligada a la identidad X.509 validada. |
| `moq-transport` | `0.16.1`, tag de 2026-07-31 | [`moq-transport`](https://github.com/cloudflare/moq-rs/tree/moq-transport-v0.16.1/moq-transport) | Conserva MoQT draft-16/ALPN, pero no define un principal TLS para el relay. |

Los tags publicados compatibles más recientes son
`moq-native-ietf-v0.10.0`, `moq-relay-ietf-v0.7.25` y
`moq-transport-v0.16.1`. No hay una release compatible posterior que cierre el
gap; el commit fijado contiene cambios posteriores a esos tags y tampoco lo
cierra. Por tanto no se actualizan `Cargo.toml` ni `Cargo.lock`.

## Búsqueda de issues y PRs

El 2026-08-25 se buscaron, en issues y PRs abiertos y cerrados del repositorio
oficial, `peer_identity`, `client certificate`, `mTLS`, `authenticated
principal` y `peer identity`. No apareció una propuesta que transporte el
certificado cliente al punto de autorización. La única coincidencia de
`client certificate` fue el issue
[#172](https://github.com/cloudflare/moq-rs/issues/172), sobre un certificado
servidor expirado y no sobre identidad cliente.

El PR [#145](https://github.com/cloudflare/moq-rs/pull/145) es adyacente: llevó
el path hasta `Coordinator::resolve_scope` y añadió permisos por scope. No llevó
identidad TLS; su default conserva `ReadWrite` basado en path. La propuesta
local no se ha publicado como issue o PR.

## Riesgos si se declarase completa hoy

1. Cualquier certificado cliente válido para la CA configurada podría recibir
   permisos decididos sólo por `/publish`, `/watch` u otro path.
2. Un peer podría clasificarse como relay interno por socket, IP local, SNI o
   path sin demostrar la identidad SPIFFE `relay/<node-id>`.
3. Una allowlist implementada sobre datos declarados dentro de MoQT no estaría
   ligada al handshake TLS y permitiría suplantación.
4. Correlacionar callbacks de `ClientCertVerifier` mediante estado global o
   thread-local mezclaría handshakes concurrentes y podría aplicar el principal
   de una conexión a otra.
5. Parsear SPIFFE o cargar una política sin poder aplicarla antes del registro o
   lookup produciría una defensa aparente y una ruta anónima efectiva.

## Alternativas rechazadas

1. **IP, puerto, SNI, path, cabecera o query como principal.** No son identidad
   autenticada del cliente y pueden cambiar o ser controlados por el peer.
2. **Usar `ConnectionTagger`.** Sólo ve `ConnectionMeta`; está diseñado para
   clasificar interfaz con atributos de transporte, no para autorizar.
3. **Añadir `quinn`, `wtransport` u otro transporte directo.** Obliga a
   reconstruir el accept loop y duplica QUIC/TLS/WebTransport.
4. **Copiar `Relay::run` o vendorizar `moq-rs`.** Diverge del relay mantenido y
   aumenta el riesgo de cambiar ALPN, draft-16 o semántica de Objects.
5. **Fork silencioso o patch local.** El coste de sincronización y la falta de
   trazabilidad contradicen la política de upstream del proyecto.
6. **Estado global/thread-local en `ClientCertVerifier`.** No existe una clave
   pública robusta que correlacione el callback con la sesión; no es seguro con
   handshakes concurrentes.
7. **Parsear ahora certificados y política en Teremoq.** Sin un punto de
   enforcement autenticado sólo crearía código muerto o una falsa garantía.

## Contrato mínimo requerido de upstream

La extensión debe ser mínima, retrocompatible y mantener el mismo endpoint
QUINN, WebTransport/raw QUIC, MoQT draft-16 y ALPN:

1. Después de completar el handshake, llamar a
   `quinn::Connection::peer_identity()` y convertir únicamente el tipo rustls
   documentado en una cadena de `CertificateDer` propia de esa conexión.
2. Transportar esa evidencia en memoria hasta el relay, con `Debug` redactado,
   sin logs, serialización, métricas, qlog/mlog ni campos MoQT.
3. Hacerla disponible a un hook de autorización antes de
   `Coordinator::resolve_scope` y antes de habilitar Producer/Consumer.
4. Permitir que el hook rechace sólo esa conexión y devuelva un contexto de
   sesión autenticado con principal y roles derivados por el embedder.
5. Llevar ese contexto a todas las operaciones de namespace iniciadas por el
   peer y permitir una decisión explícita para `publish`, `subscribe` y
   `relay-peer` antes de registrar, publicar, buscar o suscribir.
6. Mantener el comportamiento actual para embedders existentes mediante un
   modo legacy explícito o defaults, y ofrecer un builder/modo `required` donde
   ausencia de identidad, hook o decisión sea error sin fallback legacy.
7. Mantener cada principal ligado a su objeto de sesión; no usar mapas globales
   por IP/CID ni thread-local.
8. Añadir tests de certificado ausente, SPIFFE inválido, identidad no
   autorizada y dos peers concurrentes sin contaminación cruzada. Deben incluir
   rechazo previo a namespace y conservación de Objects/ALPN draft-16.

El diseño propuesto con más detalle está en
`upstream/moq-rs-peer-identity-proposal.md`.

## Estrategia de salida

1. Presentar la propuesta al upstream sólo con autorización del usuario.
2. Cuando exista una release o commit oficial aceptado, revisar licencia y API,
   y fijar atómicamente `moq-native-ietf`, `moq-transport` y
   `moq-relay-ietf` a esa release exacta o commit completo.
3. Ejecutar primero la matriz existente draft-16/ALPN/Objects para demostrar
   que no cambió el wire protocol ni Zero-Transcoding.
4. Implementar entonces identidad SPIFFE, política fail-closed, observabilidad
   acotada y las pruebas de autorización/Smallstep de la Ruta A.
5. Eliminar cualquier adaptación temporal cuando la API publicada cubra el
   contrato; no mantener un fork privado.

## Alcance que permanece fuera

Autorización no equivale a revocación. CRL, OCSP, recarga de certificados y de
política, rotación sin reinicio y compromiso de CA siguen fuera de esta Task.
La verificación rustls contra rustls tampoco demuestra interoperabilidad mTLS
universal.

## Dependencias y trazabilidad

No se añade ninguna dependencia directa ni transitiva y no se modifican las
revisiones fijadas. El workspace entregado no contiene metadata Git; por ello no
se puede producir diff, commit o atribución fiable de cambios preexistentes.

