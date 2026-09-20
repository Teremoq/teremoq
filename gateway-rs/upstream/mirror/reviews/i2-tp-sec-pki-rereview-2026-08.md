# I2 second formal security review — TP-SEC-PKI

- Fecha: 2026-08-27
- Revisor: `TP-SEC-PKI`
- Owner del código: Task 05 / `TP-RUST-DIST`
- Clon revisado en sólo lectura: `/home/jimbomilk/moq-rs-teremoq-work`
- Branch local sin tracking: `teremoq/i2-required-auth-bf87128`
- Base I1 / `HEAD`: `05b41127ecbd48de4c59fe1626c43b1e423c33a9`
- Árbol I1: `eca64a72e148482fb82b963edc2f2c9af28803f2`
- Alcance: segunda revisión adversarial del snapshot I2 corregido; sin ownership del código

## Hallazgos

### [HIGH] La autorización del connection path ocurre después de aceptar la sesión MoQT y de registrar el recurso solicitado

El branch required autentica correctamente la evidencia I1 antes de MoQT
(`moq-relay-ietf/src/relay.rs:456-505`), pero después llama a
`Session::accept_with_config` y sólo al retornar construye
`RequestedConnectionPath` y ejecuta `resolve_scope`
(`moq-relay-ietf/src/relay.rs:507-555`). La afirmación del comentario de que esa
llamada hace únicamente el trabajo mínimo necesario para exponer el path
(`relay.rs:526-531`) no coincide con la implementación real.

Para raw QUIC es inevitable recibir el control stream, decodificar
`CLIENT_SETUP` y extraer/normalizar PATH. Para WebTransport el path ya está en la
URL CONNECT. Sin embargo, `Session::accept_with_config` hace además, antes de que
el authorizer vea el recurso:

1. crea el fichero mlog cuando está configurado
   (`moq-transport/src/session/mod.rs:655-659`);
2. registra en `tracing` el path canónico en claro
   (`moq-transport/src/session/mod.rs:673-690`);
3. serializa los parámetros de `CLIENT_SETUP` en mlog
   (`moq-transport/src/session/mod.rs:693-695`), incluidos para raw QUIC los
   primeros bytes del PATH mediante el `Debug` de cada KVP
   (`moq-transport/src/mlog/events.rs:175-178,213-222`);
4. construye y envía `SERVER_SETUP` (`moq-transport/src/session/mod.rs:698-723`);
5. construye queues, `PendingRequests`, `Publisher`, `Subscriber` y el handle
   `Session` (`moq-transport/src/session/mod.rs:483-529,725-735`).

Por tanto, `accept_with_config` es la API pública mínima disponible hoy, pero no
es el intercambio mínimo inevitable para conocer el recurso. El cliente puede
completar con éxito el setup MoQT antes de que el relay deniegue el path y cierre
QUIC en `relay.rs:546-553`. Aunque esos handles sean inertes y se descarten sin
ejecutar `Session::run`, ya hubo respuesta positiva de setup, creación de estado
MoQT y observabilidad del recurso no autorizado. Esto viola el ordering
fail-closed requerido para la admisión por connection path.

La propia prueba deja el hueco visible. En el caso de path denegado obtiene el
resultado de `Session::connect_with_config`, espera la llamada a scope, pero no
exige que el setup haya fallado; sólo comprueba probes posteriores del relay
(`moq-relay-ietf/src/i2_tests.rs:707-773`). En el caso de path ausente acepta
explícitamente un resultado `Ok((Session, Publisher, Subscriber))` y espera el
cierre al ejecutar después el handle (`i2_tests.rs:780-835`). Los probes de
`RequiredEffectProbe` empiezan en la creación de los Producer/Consumer del relay
y no observan `SERVER_SETUP`, mlog ni el estado creado dentro de
`moq-transport::Session` (`i2_tests.rs:634-650`). La prueba, por tanto, no es un
oráculo independiente para este boundary.

Cambios comprobables requeridos para Task 05:

1. Proponer y obtener autorización del Master para una extensión aditiva y
   conservadora de `moq-transport`; el relay no debe duplicar el parser de
   CLIENT_SETUP ni implementar wire/protocolo propio.
2. Reutilizar el decode y la normalización existentes en una API de aceptación
   en dos fases: una fase pending que reciba/valide CLIENT_SETUP y exponga sólo
   el path canónico, y una fase de finalización que envíe SERVER_SETUP y construya
   `Session`/`Publisher`/`Subscriber`.
3. Mantener `Session::accept_with_config` source-compatible implementándolo sobre
   ambas fases para legacy. En required, ejecutar en orden: evidencia I1,
   `authenticate`, fase pending mínima, `resolve_scope(session, path)`, y sólo si
   se permite, finalización de setup.
4. No crear mlog ni registrar el path solicitado antes del gate. Si se conserva
   observabilidad de path, debe ocurrir sólo tras autorización y respetar la
   política de redacción; una denegación debe emitir únicamente evento/label fijo
   de baja cardinalidad.
5. Añadir pruebas integradas raw QUIC y WebTransport en las que el resolver se
   bloquee con sincronización determinista: mientras el gate está pendiente, el
   future cliente no puede haber recibido SERVER_SETUP; tras denegación, el setup
   cliente debe fallar y no deben existir handles, mlog, Producer/Consumer,
   Coordinator, lookup, registro, forwarding ni namespace. Debe probarse también
   el path ausente.
6. Mantener intactos draft-16, ALPN, wire encoding y el comportamiento legacy.
   El cambio de crate boundary y su nuevo snapshot requieren otra revisión
   formal; no autorizan copiar el código de setup dentro de `moq-relay-ietf`.

## Cierre de los hallazgos anteriores

### Recurso solicitado y separación identidad/recurso

El input tipado nuevo es correcto: `RequestedConnectionPath` tiene campo
privado, `Debug` fijo y acceso prestado (`authorization.rs:29-54`).
`resolve_scope` recibe por separado contexto autenticado y path canónico
(`authorization.rs:285-297`). El path es recurso y no principal. La
normalización compartida rechaza ausencia/root, segmentos vacíos, dot-segments,
percent encoding, paths relativos y exceso de longitud
(`moq-transport/src/session/mod.rs:150-240`). Raw QUIC toma PATH de CLIENT_SETUP y
WebTransport da precedencia al CONNECT URL (`session/mod.rs:673-684`).

El branch required no llama a `Coordinator::resolve_scope`, `ConnectionTagger`
ni `ConnectionMeta`; esos hooks quedan sólo en `None`, el branch legacy
(`moq-relay-ietf/src/relay.rs:532-604`). IP, SNI, `ConnInfo`, path y tags no se
convierten en principal ni relay-peer. La corrección semántica identidad/recurso
queda cerrada, pero su ordering de admisión sigue abierto por el hallazgo HIGH.

### Composición certificado válido → authorizer deniega

El gap de cobertura dividida I1+I2 queda cerrado. El test único
`verified_client_certificate_authentication_denial_is_pre_moq_and_effect_free`
arranca `Relay::new_required`, presenta un certificado cliente que rustls
verifica y ejecuta raw QUIC y WebTransport
(`moq-relay-ietf/src/i2_tests.rs:652-704`). Prueba exactamente una llamada a
`authenticate`, cero scope/operaciones, cero Coordinator y cero efectos del
relay; el setup cliente falla.

La configuración usa rustls oficial 0.23.31 como dev-dependency directa y exacta,
provider `ring` explícito y sólo TLS 1.3 (`i2_tests.rs:79-115`), con fixtures
sintéticos estáticos ya existentes (`i2_tests.rs:32-36`). No imprime DER, key,
PEM, subject, SAN, serial, fingerprint, principal, rol ni contexto. El manifest
añade únicamente
`rustls = { version = "=0.23.31", default-features = false, features = ["ring"] }`
bajo `[dev-dependencies]` (`moq-relay-ietf/Cargo.toml:73-77`); `Cargo.lock` sólo
añade esa dependencia a la lista del package relay. La licencia declarada de
rustls 0.23.31 es `Apache-2.0 OR ISC OR MIT`; no cambia el runtime.

### Pruebas adversariales de efectos y ordering por operación

El tercer hallazgo anterior queda cerrado para los handlers de aplicación. Los
probes son `cfg(test)`, por sesión e inyectados; no son globales ni thread-local
(`authorization.rs:12-27`). Están colocados inmediatamente antes del efecto real
y se contrastan con handles/protocolo, `Locals` y un Coordinator instrumentado
independiente:

- PUBLISH_NAMESPACE autoriza antes de métricas, registro, respuesta y forwarding
  (`consumer.rs:171-243`); la prueba comprueba error, Coordinator y Locals vacíos
  (`i2_tests.rs:975-1015`).
- PUBLISH autoriza antes de métricas, permiso, extracción, registros y respuesta
  (`consumer.rs:411-505`); la prueba comprueba el error de protocolo y cero
  efectos reales (`i2_tests.rs:1017-1074`).
- SUBSCRIBE contra track existente autoriza antes de métrica, lookup, cache o
  serve (`producer.rs:222-350`); la fixture independiente permanece intacta
  (`i2_tests.rs:1076-1115`).
- SUBSCRIBE_NAMESPACE autoriza antes de watchers, lease, snapshot y REQUEST_OK
  (`producer.rs:372-445`); la prueba observa cero efectos y cero Coordinator
  (`i2_tests.rs:1117-1163`).
- NAMESPACE y NAMESPACE_DONE vuelven a autorizar cada namespace exacto antes del
  evento y de mutar `known` (`producer.rs:512-630`); las pruebas comprueban estado
  independiente y ausencia del evento denegado (`i2_tests.rs:1165-1255`).
- discovery Publish vuelve a pasar `Operation::Subscribe` sobre el namespace
  exacto antes de output, publish y cache (`producer.rs:705-751`); su prueba
  mantiene un track fixture y observa cero output (`i2_tests.rs:1257-1292`).
- TRACK_STATUS autoriza antes de lookup y respuesta (`producer.rs:769-843`); la
  prueba usa un track existente y observa cero lookup/respuesta
  (`i2_tests.rs:1294-1325`).
- el relay-peer autenticado pasa primero el gate base y luego el gate
  `RelayPeer` exacto (`authorization.rs:332-345`); la denegación del segundo gate
  precede registro, Coordinator, respuesta y mutación
  (`i2_tests.rs:1327-1358`).

No se observaron bypasses adicionales en PUBLISH, PUBLISH_NAMESPACE, SUBSCRIBE,
SUBSCRIBE_NAMESPACE, NAMESPACE/NAMESPACE_DONE, discovery Publish, TRACK_STATUS o
forwarding. No hay sleeps. Los timeouts son watchdogs y las señales se realizan
mediante respuesta de protocolo o semáforos; los atomics/probes no son el único
oráculo. Ningún assert imprime material criptográfico o de identidad.

## Controles de seguridad repetidos

1. **Encapsulación y redacción.** `AuthenticatedSession` mantiene privados tanto
   el `Arc<dyn Any + Send + Sync + 'static>` como la clasificación de peer; el
   downcast devuelve `Option<&T>` y no usa `type_name`, `TypeId` ni bound `Debug`
   (`authorization.rs:56-127`). `AuthenticatedSession`,
   `RequestedConnectionPath`, `Operation`, `RelayPeerOperation` y errores tienen
   formatos fijos/redactados (`authorization.rs:50-54,123-127,209-268`). No hay
   fugas de DER/PEM/subject/SAN/serial/fingerprint/principal/rol/contexto/nombre
   de tipo en el delta I2. La excepción de path pre-gate en transporte/observabilidad
   está descrita en el hallazgo.
2. **Object safety y fail-closed.** `SessionAuthorizer` no tiene métodos
   genéricos ni retornos `Self`, usa `async_trait`, exige `Send + Sync + 'static`
   y se consume como `Arc<dyn SessionAuthorizer>` (`authorization.rs:272-306`).
   No hay defaults permisivos. Errores de authenticate, resolve y authorize se
   propagan como denegación/cierre.
3. **I1 antes de MoQ.** Required convierte todos los servers a
   `PeerEvidenceServer` antes de aceptar (`relay.rs:378-400`). Errores I1,
   `PeerEvidence::Absent` y evidencia no soportada cierran antes de authenticate
   o MoQT, sin fallback ni session handle (`relay.rs:405-421,456-505`).
4. **Evidencia prestada y descartada.** `authenticate` recibe
   `&VerifiedPeerEvidence`; el owner de evidencia se descarta explícitamente
   antes de construir `RequiredAuthorization` (`relay.rs:471-503`). Principal,
   roles, SPIFFE parsing y policy permanecen en el embedder
   (`authorization.rs:272-276`).
5. **Relay-peer.** Sólo `AuthenticatedSession::new_relay_peer` puede clasificar
   el peer y su contrato excluye socket, SNI, path, `ConnInfo` y tagger
   (`authorization.rs:85-97`). No existe inferencia por transporte ni degradación
   si falla el segundo gate.
6. **Concurrencia/lifetimes.** Se retiene mediante `Arc` únicamente el contexto
   derivado y el authorizer, clonados por sesión/tarea; no hay mapas globales por
   IP/CID ni estado thread-local. La prueba concurrente comprueba ambos pares
   contexto/namespace y sus cruces negativos (`i2_tests.rs:1434-1485`).
7. **Legacy.** `Relay::new`, builders y constructors existentes conservan su
   forma; required es opt-in y no tiene fallback. El test legacy pasa en ambos
   transportes (`i2_tests.rs:885-929`).
8. **Frontera upstream.** No hay `unsafe`, parser X.509, política Teremoq,
   segundo transporte, cambio de Objects, draft, wire o ALPN. `moqt-16` y
   draft-16 se comprueban en `i2_tests.rs:1520-1529`. Workspace manifest,
   `moq-native-ietf` y `moq-transport` permanecen byte-identical a I1. La única
   dependencia nueva es rustls test-only; no se habilita feature de runtime.

## Snapshot exacto y estabilidad

Estado inicial y final idéntico:

- branch `teremoq/i2-required-auth-bf87128`, sin upstream/tracking;
- `HEAD` `05b41127ecbd48de4c59fe1626c43b1e423c33a9`;
- tree `eca64a72e148482fb82b963edc2f2c9af28803f2`;
- stage vacío;
- seis ficheros modificados y dos nuevos, todos unstaged;
- no commit, checkout, reset, fetch, push ni otra mutación Git/remota.

| Objeto I2 | SHA-256 final |
|---|---|
| `Cargo.lock` | `13b9f1c54ccbe644dcf4f07542f610950cd013b291c928b6b3ad39ac1751ce80` |
| `moq-relay-ietf/Cargo.toml` | `83185ddb3f1523a6d7d9c577abbf29010eb34d6043538c1b28ff1057bb888b11` |
| `authorization.rs` | `101fc1a0a8c1fc8d61453f43617cbfef1913a7db91767f29c9e59b9970d148c2` |
| `consumer.rs` | `06f601e1f4efdb3c7f4bca99114d275db0abcdca436fece01c352f3fb13a256d` |
| `i2_tests.rs` | `607fc9e7d2f9bbcfcfc16314f7375c5e580d93be4038f24fe6d8568a173523c4` |
| `lib.rs` | `c3ccba4a249469e3926a5a6e8f92912694808c13e2fe9cd42e74c08dc9c34990` |
| `producer.rs` | `8b9c723341ad93c77f94a57fc833323c695d45078edd541c0a42a80ea51e966e` |
| `relay.rs` | `0879a9a01d84cbf6a41f02f0ac3bb72280c838f67948e871a17ee1a463095a66` |

Hashes protegidos confirmados: workspace `Cargo.toml`
`6665802c9ad7192d61521a62877454e25bde7072c611e617780a932f583aa48f`,
`moq-native-ietf/Cargo.toml`
`3180121a89c58071718236a408f36c1c87757d6f9ff81e899fb3b5814c8d4c8e`,
`moq-transport/Cargo.toml`
`78f582c201082f7badece64f7fa65d215a6694412b7a7699332fa3bc9a4f3743`,
setup/ALPN `c49d71dcacd5e3f5eef7a673e11b9058d3fd701e1fb83331a737098894a2d750`,
version/draft `384772b32812a0761fa55d16a9fd29e30595323ece1b3fca013ec3720eaec4ad`
y `REUSE.toml`
`afc7fd86e591a56078b11982ee4d039ea1dfe3f9d56a90e3e7fa9f84fbddb6cc`.

## Validaciones reejecutadas

El clon se montó `readonly`; `CARGO_HOME` y `CARGO_TARGET_DIR` estuvieron en
`tmpfs`. No se instaló nada en el host ni se modificaron dependencias.

| Comando/gate | Resultado |
|---|---|
| Imagen oficial `rust:1.93.0@sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57` | PASS: image ID exacto; rustc `1.93.0`, commit `254b59607d4417e9dffbc307138ae5c86280fe4c` |
| `cargo test --locked -p moq-relay-ietf` | PASS: 143/143 lib; 16/16 bin; doctest 1 passed y 1 ignored |
| `cargo test --locked -p moq-native-ietf --test peer_evidence` | PASS: 6/6 |
| `cargo clippy --locked --no-deps -p moq-relay-ietf --tests -- -D warnings` | PASS |
| rustfmt 1.8.0/Rust 1.93 `--check` sobre los seis Rust I2 | PASS |
| `git diff --check` | PASS |
| `git diff --cached --check` | PASS; index vacío |
| `git diff --no-index --check /dev/null` para los dos Rust nuevos | PASS; exit 1 esperado por contenido, sin diagnóstico whitespace |
| Gitleaks `v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f` sobre los ocho ficheros, `--no-git --redact` | PASS: cero leaks en cada fichero |
| hashes/HEAD/tree/branch/stage al final | PASS: idénticos al snapshot esperado |

Incidencias no ocultadas: una primera invocación usó `bash -lc`, cuyo PATH de
login no encontró `rustc`; se repitió sin login sobre la misma imagen exacta. La
imagen local previamente descrita como “full”
`sha256:ba076cf0a26aa41efdd2f0f80687ef97009d1526680751456c19cc944dff1d0b`
no contenía Clippy ni rustfmt. No se la aceptó como evidencia: ambos componentes
se instalaron sólo dentro de un contenedor desechable creado desde la imagen
oficial Rust fijada, y allí pasaron los gates. Una primera repetición final de
`sha256sum` se invocó desde la raíz Teremoq y no encontró los paths relativos del
clon; se repitió desde `/home/jimbomilk/moq-rs-teremoq-work` y confirmó los ocho
hashes, HEAD, tree, branch, stage y ambos diff checks sin cambios.

## Riesgos residuales

- Un embedder desobediente todavía puede copiar DER desde la evidencia prestada
  hacia su contexto propio. Upstream impone borrow y contrato, pero la
  implementación downstream y su review deben asegurar un contexto mínimo sin
  credenciales ni material X.509.
- `Arc` retiene legítimamente ese contexto derivado hasta que terminen los
  handles/tareas de sesión; no debe contener secretos ni evidencia.
- SPIFFE parsing, principal, roles, ACL/policy, reload y revocación quedan fuera
  de upstream I2 y no están demostrados por este snapshot.
- La prueba integrada usa TLS/rustls real y fixtures sintéticos, pero no es una
  prueba de interoperabilidad PKI productiva ni de enforcement de revocación.
- Los fallos baseline conocidos de full-workspace y dos diffs rustfmt ajenos a
  I2 no se modificaron ni ocultaron; los gates focalizados exigidos sí pasan.

## Veredicto

**CHANGES REQUIRED**

No se autoriza commit local. Task 05 debe cerrar el gate de path previo a
SERVER_SETUP/estado/observabilidad y entregar un nuevo snapshot estable para
revisión. Este dictamen no autoriza push, PR, publicación ni mutación remota.

**READ-ONLY SECURITY REVIEW / NO COMMIT / NO PUSH / NO REMOTE MUTATION**
