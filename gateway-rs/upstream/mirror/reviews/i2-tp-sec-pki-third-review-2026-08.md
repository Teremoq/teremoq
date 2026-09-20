# I2 third formal security review — TP-SEC-PKI

- Fecha: 2026-08-27
- Revisor: `TP-SEC-PKI`
- Owner del código: Task 05 / `TP-RUST-DIST`
- Clon revisado en sólo lectura: `/home/jimbomilk/moq-rs-teremoq-work`
- Branch local sin tracking: `teremoq/i2-required-auth-bf87128`
- Base I1 / `HEAD`: `05b41127ecbd48de4c59fe1626c43b1e423c33a9`
- Árbol I1: `eca64a72e148482fb82b963edc2f2c9af28803f2`
- Alcance: tercera revisión adversarial del snapshot I2 con aceptación inbound en dos fases; sin ownership del código

## Hallazgos

No hay hallazgos HIGH, MEDIUM o LOW accionables en el snapshot exacto revisado.
El HIGH del segundo dictamen queda cerrado: el modo required ya no acepta la
sesión MoQT, no envía `SERVER_SETUP`, no crea mlog ni materializa handles antes
de que el recurso path sea autorizado.

### Cierre del HIGH anterior: boundary pending mínimo y sin efectos

`PendingSession` es un guard owned, no implementa `Clone` y todos sus campos son
privados (`moq-transport/src/session/mod.rs:150-165`). Retiene exclusivamente la
sesión de transporte, los dos extremos del control stream, el `CLIENT_SETUP`
decodificado, el tipo de transporte, el path canónico y `SessionConfig`. El único
acceso al recurso es prestado como `Option<&str>`
(`session/mod.rs:167-171`). `finish(self, ...)` consume el guard
(`session/mod.rs:173-182`), por lo que el type system impide una segunda
finalización. La prueba pública confirma que el tipo es `Send` y que las cuatro
APIs son accesibles sin exponer campos (`moq-transport/tests/pending_accept.rs:4-14`).

`Session::accept_pending_with_config` hace solamente lo necesario para el
boundary: acepta un control bidi, crea wrappers de reader/writer, decodifica un
`CLIENT_SETUP`, emite un trace fijo de tipo de mensaje y deriva el path canónico
(`session/mod.rs:786-815`). Antes de `finish` no llama a mlog, no serializa KVP,
no registra el path, no llama a `log_peer_max_request_id`, no construye ni envía
`SERVER_SETUP`, y no crea Queue, `PendingRequests`, Publisher, Subscriber,
Session ni tasks. Esos objetos aparecen sólo en `finish_inner` y `Session::new`
(`session/mod.rs:191-249,596-643`).

Para raw QUIC, abrir y decodificar `CLIENT_SETUP` es inevitable porque PATH está
en su parámetro. Para WebTransport, CONNECT ya contiene el path, pero decodificar
el `CLIENT_SETUP` antes del gate común sólo valida el framing inbound: no confirma
la sesión, no responde y no crea estado de aplicación. Por tanto,
`accept_pending_with_config`, no `accept_with_config`, es el mínimo aceptable para
el contrato requerido. No se observó ordering imposible.

La cancelación antes de obtener el guard o el drop del guard descarta por
ownership la sesión y el control stream; no hay task detached ni app state que
limpiar. Una cancelación de `finish` sólo puede ocurrir después de autorización;
descarta el transporte aunque `SERVER_SETUP` se hubiera empezado a escribir. No
abre un efecto pre-gate. La ausencia de `Clone`, los campos privados y el consumo
de `self` impiden finish múltiple o bifurcar el guard. `Relay::new_required` no
expone el guard y no contiene otro call site de `finish`.

`Session::accept` y `Session::accept_with_config` conservan sus firmas y se
implementan como pending seguido del `finish_legacy` privado
(`session/mod.rs:748-816`). En sesiones legacy que decodifican correctamente se
conservan el log de path, el evento mlog de CLIENT_SETUP, el log de
MAX_REQUEST_ID, `SERVER_SETUP` y los handles (`session/mod.rs:184-249`). Hay una
diferencia operacional no bloqueante: la creación del fichero mlog queda
aplazada hasta después de decodificar un CLIENT_SETUP válido; una conexión
legacy que falla o queda cancelada antes de ese punto ya no deja un fichero mlog
vacío. No cambia firma, wire, sesión aceptada ni decisión de autorización, y no
existe contrato público que garantice ese artefacto vacío.

### Ordering required exacto en raw QUIC y WebTransport

El orden observado por lectura es:

1. `PeerEvidenceServer` entrega evidencia ligada a la conexión I1; errores de
   conversión nunca producen `InboundConnection` (`moq-relay-ietf/src/relay.rs:56-79,381-423`).
2. `PeerEvidence::Rustls` se presta a `authenticate`; `Absent`, evidencia no
   soportada y error del authorizer cierran fail-closed. La evidencia se descarta
   antes de construir `RequiredAuthorization` (`relay.rs:456-505`).
3. Se decodifica únicamente el pending CLIENT_SETUP y se deriva el path
   (`relay.rs:511-531`).
4. La ausencia de path cierra; en caso contrario `resolve_scope` recibe juntos
   contexto autenticado y recurso solicitado (`relay.rs:532-553`).
5. Sólo un resultado permitido llama a `pending.finish` y puede enviar
   `SERVER_SETUP` o crear handles (`relay.rs:554-563`).
6. Sólo después se crean `SessionContext`, Producer, Consumer y `Session`, y se
   inicia su ejecución (`relay.rs:607-735`).

Denegación o ausencia no llega a mlog, `SessionContext`, Producer/Consumer,
watchers, Coordinator/tagger, lookup, registro, cache, forwarding, respuesta ni
namespace. El path es un recurso tipado separado de identidad
(`moq-relay-ietf/src/authorization.rs:29-54,285-297`). CONNECT no vacío tiene
precedencia y, si CONNECT es root/ausente, se usa PATH de CLIENT_SETUP
(`moq-transport/src/session/mod.rs:321-354`). La normalización compartida limita
a 1024 bytes y rechaza paths relativos, segmentos vacíos, dot-segments,
percent-encoding y PATH no UTF-8 (`session/mod.rs:264-343`).

El branch required extrae IP, SNI y `ConnInfo` sólo como metadata del transporte;
no los pasa al authorizer. `ConnectionTagger`, `ConnectionMeta` y el Coordinator
legacy aparecen exclusivamente en el branch `None`
(`moq-relay-ietf/src/relay.rs:610-628`). `RelayPeer` sólo puede proceder del
contexto que devuelve el embedder mediante `AuthenticatedSession::new_relay_peer`
y pasa el gate base seguido del gate relay-peer exacto
(`authorization.rs:73-120,332-345`). No hay fallback a socket, SNI, path, CID,
tagger o Coordinator.

### Evidencia de tests y ausencia de oráculos circulares

La prueba integrada con certificado cliente válido usa rustls 0.23.31 oficial,
provider `ring` explícito, TLS 1.3 y fixtures DER sintéticos
(`moq-relay-ietf/src/i2_tests.rs:39-43,100-151`). En raw QUIC y WebTransport
atraviesa `Relay::new_required`, obtiene handshake mTLS válido y deniega en
`authenticate`: exactamente una llamada a authenticate, cero scope,
operaciones, Coordinator y estado MoQT/relay
(`i2_tests.rs:702-754`). No hay composición inferida entre tests I1 e I2: el
escenario certificado válido → relay required → authorizer deniega es único e
integrado.

La prueba de path bloqueado es determinista. `resolve_scope` primero registra el
path, emite `scope_seen` y después espera `scope_release`
(`i2_tests.rs:437-470`). El test espera esa señal antes de consultar
`JoinHandle::is_finished`; el future cliente ya envió CLIENT_SETUP y se encuentra
esperando SERVER_SETUP (`i2_tests.rs:756-813`; cliente en
`moq-transport/src/session/mod.rs:678-730`). Mientras el resolver está bloqueado,
el setup no ha terminado, el directorio mlog aislado está vacío, y Coordinator y
probes de relay siguen a cero. El mlog en filesystem es un efecto independiente
de los atomics; una llamada anticipada a `finish` lo habría creado antes del
await de envío. Tras liberar el resolver, allow completa y crea exactamente un
Producer/Consumer; deny falla setup y conserva mlog y efectos vacíos
(`i2_tests.rs:798-838`). Missing path prueba el mismo cierre sin llamar a scope
(`i2_tests.rs:841-890`). No se usan sleeps; los timeouts son sólo watchdogs.

Las pruebas operativas siguen midiendo efectos reales además del registro del
authorizer:

- PUBLISH_NAMESPACE: gate antes de métricas, registry, Coordinator, respuesta y
  forwarding (`moq-relay-ietf/src/consumer.rs:171-240`), con Coordinator y
  `Locals` independientes vacíos (`i2_tests.rs:1029-1069`).
- PUBLISH: gate antes de métrica, permiso, reader extraction, registros y
  respuesta (`consumer.rs:411-505`), con error de protocolo y estado real vacío
  (`i2_tests.rs:1071-1128`).
- SUBSCRIBE existente: gate antes de métrica, lookup, cache o serve
  (`moq-relay-ietf/src/producer.rs:221-350`); una fixture registrada por separado
  permanece intacta (`i2_tests.rs:1130-1169`).
- SUBSCRIBE_NAMESPACE: gate antes de watchers, lease, snapshot y REQUEST_OK
  (`producer.rs:371-455`), con cero lease/snapshot/respuesta/Coordinator
  (`i2_tests.rs:1171-1217`).
- NAMESPACE y NAMESPACE_DONE: segundo gate exacto antes de emitir evento y de
  mutar `known` (`producer.rs:512-631`); las pruebas comprueban el stream y estado
  independiente (`i2_tests.rs:1219-1309`).
- Discovery Publish: segundo gate Subscribe exacto antes de output, publish o
  cache (`producer.rs:634-751`), con track fixture y cero output
  (`i2_tests.rs:1311-1346`).
- TRACK_STATUS: gate antes de lookup y respuesta (`producer.rs:769-843`), con
  track existente y ambos efectos a cero (`i2_tests.rs:1348-1379`).
- Relay peer: gate base y segundo gate `RelayPeer` antes de cualquier efecto;
  la prueba observa dos operaciones, respuesta cero, Coordinator vacío y ningún
  namespace (`i2_tests.rs:1381-1412`).

No se encontraron bypasses en PUBLISH, PUBLISH_NAMESPACE, SUBSCRIBE,
SUBSCRIBE_NAMESPACE, NAMESPACE/NAMESPACE_DONE, discovery Publish, TRACK_STATUS
o forwarding.

## Controles de seguridad repetidos

1. **Encapsulación y redacción.** `AuthenticatedSession` encapsula un
   `Arc<dyn Any + Send + Sync + 'static>` y una clasificación privada. El
   downcast devuelve `Option<&T>` y no usa `type_name`, `TypeId` ni `Debug`
   (`authorization.rs:56-127`). Sus formatos, los de path/operaciones y todos los
   errores son fijos y redactados (`authorization.rs:50-54,123-127,209-270`).
2. **Object safety/fail-closed.** `SessionAuthorizer` no tiene métodos genéricos,
   defaults permisivos ni retornos `Self`; `async_trait` y
   `Send + Sync + 'static` permiten `Arc<dyn SessionAuthorizer>`. Errores de
   authenticate, resolve y authorize cierran o se propagan antes del efecto
   (`authorization.rs:272-305`).
3. **Evidencia prestada.** `authenticate` recibe `&VerifiedPeerEvidence`; el
   owner de evidencia se descarta en `relay.rs:500`. Upstream no parsea X.509 ni
   define SPIFFE, principal, roles, ACL o policy. El contrato prohíbe que el
   embedder copie DER al contexto (`authorization.rs:272-276`).
4. **Concurrencia/lifetimes.** Sólo el contexto derivado y el authorizer se
   retienen por `Arc`; no existe mapa global por IP/CID ni thread-local. Dos
   sesiones simultáneas demuestran los pares contexto/namespace y los cruces
   negativos (`i2_tests.rs:1488-1539`).
5. **Observabilidad.** Antes del path gate required sólo se registra un tipo de
   mensaje fijo (`moq-transport/src/session/mod.rs:795-801`). Auth, missing y deny
   usan textos/labels fijos (`relay.rs:476-499,536-550`). Required `finish` no
   registra path ni CLIENT_SETUP (`session/mod.rs:202-235`). No hay DER, PEM,
   subject, SAN, serial, fingerprint, principal, rol, contexto ni nombre de tipo
   en Debug/Display, tracing, anyhow, métricas, qlog o mlog del delta.
6. **Legacy y API.** Los constructors y firmas legacy permanecen; required es
   opt-in y nunca degrada a legacy. Las dos rutas legacy pasan en raw QUIC y
   WebTransport (`i2_tests.rs:939-983`). La API pending es estrictamente aditiva.
7. **Frontera upstream.** No hay `unsafe`, parser X.509, criptografía, política
   Teremoq, segundo transporte, cambio de Objects, wire, draft o ALPN. La prueba
   conserva `moqt-16`, draft-16 y Objects (`i2_tests.rs:1574-1583`). El único
   cambio de dependencia es `rustls = "=0.23.31"` bajo `[dev-dependencies]`, con
   `ring`; no añade dependencia/feature runtime
   (`moq-relay-ietf/Cargo.toml:73-77`). Su licencia declarada es
   `Apache-2.0 OR ISC OR MIT`.
8. **Fixtures.** Los cinco DER bajo `moq-relay-ietf/tests/data/i2` son copias
   byte por byte de las fixtures públicas I1. README las marca explícitamente
   como sintéticas, test-only y no aptas para despliegue; cada binario tiene
   sidecar SPDX y `SHA256SUMS`. No se generan certificados ni se imprimen claves,
   DER o identidad en tests/aserts.

## Snapshot exacto y estabilidad

Estado inicial y final idéntico:

- branch `teremoq/i2-required-auth-bf87128`, sin upstream/tracking;
- `HEAD` `05b41127ecbd48de4c59fe1626c43b1e423c33a9`;
- tree `eca64a72e148482fb82b963edc2f2c9af28803f2`;
- hash de `git status --porcelain=v1`:
  `6d32127a0624086c2ca145b077253ab3ea1f7872dc9f73c0934ab8a7478c9379`;
- stage vacío;
- ningún checkout, add, commit, reset, clean, config, fetch, push ni mutación
  Git/remota.

| Anchor | SHA-256 final |
|---|---|
| `Cargo.lock` | `13b9f1c54ccbe644dcf4f07542f610950cd013b291c928b6b3ad39ac1751ce80` |
| `moq-relay-ietf/Cargo.toml` | `83185ddb3f1523a6d7d9c577abbf29010eb34d6043538c1b28ff1057bb888b11` |
| `moq-relay-ietf/src/authorization.rs` | `101fc1a0a8c1fc8d61453f43617cbfef1913a7db91767f29c9e59b9970d148c2` |
| `moq-relay-ietf/src/consumer.rs` | `06f601e1f4efdb3c7f4bca99114d275db0abcdca436fece01c352f3fb13a256d` |
| `moq-relay-ietf/src/i2_tests.rs` | `595ac7f27b545c9370b22b8fbf483ac0c4de91e779413f93fc42643d6dca0e6f` |
| `moq-relay-ietf/src/lib.rs` | `c3ccba4a249469e3926a5a6e8f92912694808c13e2fe9cd42e74c08dc9c34990` |
| `moq-relay-ietf/src/producer.rs` | `8b9c723341ad93c77f94a57fc833323c695d45078edd541c0a42a80ea51e966e` |
| `moq-relay-ietf/src/relay.rs` | `d224efb6055d10cfd853ac660df93dabda34e2d65424f84d5ecb3a1da29b9bbe` |
| `moq-transport/src/session/mod.rs` | `5fa5a8a1c8d68faf86553146eb7b0d39a7ee9aea6a41b97e4abf261500115b00` |
| `moq-transport/tests/pending_accept.rs` | `7165d0bb033e8e0ffe180b384879b8d738235f9e021da57d4a8505567e6f2de1` |
| `moq-relay-ietf/tests/data/i2/README.md` | `3f6ffc3096c54975fb75b795a06a7b5083c6bd3388a03c3a9023bc3a3ef54862` |
| `moq-relay-ietf/tests/data/i2/SHA256SUMS` | `97ed99bcd8d4144652bc729dd6f7e80a4e258f397f3b620a274d9c8b08e2bee9` |

Los hashes de las cinco fixtures copiadas son, respectivamente: CA cert
`ea33add88bed4676c51baa4f8da9df33d04e99cecf7d0846a756e23b0f66461b`,
client cert `e75cc0d4f020259b4b86d5b722762cbd7aba9b219a8d3234a8b5c5af3e214eb2`,
client key `416263df93ab7f326f2d82f198fcdf9da850a55e5564ca964c3eceb7976bd288`,
server cert `053a80b61f971f0601d83305ec6139fbcd7ed2f78c541078ac6e68a7e6da16bc`
y server key `1d02d7ec66886fc2bb2cc3104851e1c182d7980e946d8df2e8f0f3ae33c30436`.
`cmp` confirmó igualdad byte por byte con `moq-native-ietf/tests/data`.

## Validaciones reejecutadas

El clon se montó `readonly`; Cargo home/registry se usó sólo como cache fijada y
el target estuvo en `tmpfs`. No se instaló nada globalmente ni se modificaron
dependencias. La imagen oficial
`rust:1.93.0-slim-bookworm@sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57`
resolvió al image ID exacto y reportó rustc 1.93.0, commit
`254b59607d4417e9dffbc307138ae5c86280fe4c`. Los builds usaron la imagen local
de tooling previamente auditada y también fijada
`teremoq-step7-lab:rust-1.93-full@sha256:ba076cf0a26aa41efdd2f0f80687ef97009d1526680751456c19cc944dff1d0b`,
con el mismo rustc. Clippy y rustfmt se añadieron sólo dentro de un contenedor
desechable.

| Comando/gate | Resultado exacto |
|---|---|
| `cargo test --locked --offline -p moq-relay-ietf` | PASS: 143/143 lib; 16/16 bin; doctests 1 passed, 1 ignored. Incluye los 20 tests I2 y las rutas raw QUIC/WebTransport de auth deny, path pending allow/deny/missing y legacy. |
| `cargo test --locked --offline -p moq-native-ietf --test peer_evidence` | PASS: 6/6. |
| `cargo test --locked --offline -p moq-transport --test pending_accept` | PASS: 1/1. |
| `cargo clippy --locked --offline --no-deps -p moq-relay-ietf --tests -- -D warnings` | PASS. |
| `cargo clippy --locked --offline --no-deps -p moq-transport --test pending_accept -- -D warnings` | PASS. |
| rustfmt 1.93 `--check` sobre los ocho Rust I2 | PASS, sin salida. |
| `cargo test --locked --offline -p moq-transport --lib` | FAIL esperado y reproducido: E0308 en `moq-transport/src/serve/tracks.rs:501`, `TrackName` vs `&str`. Ese fichero tiene hash `a8303c94925707a0a257923725bf84e4ec730b07d6bb2330fda5329b632fe0b7`, idéntico a I1; `git diff` confirma cero delta. No afecta a los ficheros I2 ni al integration target `pending_accept`, pero impide ejecutar el unit test privado de precedencia dentro del lib target. |
| `git diff --check` | PASS, exit 0. |
| `git diff --cached --check` | PASS, exit 0; stage vacío. |
| `git diff --no-index --check /dev/null` sobre los cinco textos nuevos | PASS: exit 1 esperado por contenido, cero diagnóstico whitespace. |
| REUSE 5.1.1 `fsfe/reuse@sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da` sobre el source snapshot sin `.git`/`target` | PASS: 209/209, MIT y Apache-2.0, cero missing/bad/read errors. |
| Gitleaks 8.30.1 `zricethezav/gitleaks@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f` con `--redact` sobre los diez ficheros de source/manifest/lock y el directorio fixture I2 | PASS: cero leaks en los once scans. |
| Gitleaks sobre `moq-relay-ietf/src` completo | Nonzero baseline: una coincidencia `private-key` en el comentario PEM preexistente `moq-relay-ietf/src/tls.rs:115`; el fichero no tiene delta I2. |
| `cargo package --locked --offline -p moq-relay-ietf --allow-dirty --list` | PASS: lista 38 paths e incluye los cinco DER, cinco sidecars, README y SHA256SUMS bajo `tests/data/i2`. |
| Revalidación de HEAD/tree/branch/upstream/stage/status hash y doce anchors | PASS: idénticos al snapshot esperado. |

Incidencias de ejecución no ocultadas: una primera invocación de REUSE incluyó
por error el directorio ignorado y preexistente `/src/target`, por lo que reportó
licencias faltantes de artefactos generados; se corrigió escaneando el source
snapshot efímero sin `.git` ni `target`, que dio 209/209. Un primer wrapper de
Gitleaks olvidó sustituir el entrypoint de la imagen y terminó con `unknown
command "sh"`; la repetición corregida ejecutó los once scans y pasó. Ninguna
incidencia modificó el clon.

## Riesgos residuales y gates separados

- Un embedder deliberadamente incorrecto puede copiar DER desde la evidencia
  prestada a su propio contexto. Upstream impone borrow y contrato, pero la
  implementación Teremoq debe demostrar que su contexto contiene sólo principal
  mínimo/roles derivados y nunca evidencia X.509.
- El `Arc` retiene legítimamente contexto derivado y authorizer hasta que
  terminan todos los handles/tasks de la sesión. Ese contexto downstream no debe
  contener secretos ni certificados.
- El unit test privado de CONNECT-over-PATH no puede ejecutarse mientras exista
  el E0308 baseline. La precedencia queda demostrada por lectura directa
  (`moq-transport/src/session/mod.rs:345-354`) y los tests relay ejercitan por
  separado el path canónico raw y WebTransport, pero la reparación del baseline
  debe mantener ese unit test.
- SPIFFE/X.509 parsing, principal, roles, policy, reload y revocación permanecen
  fuera de upstream I2. Este dictamen no demuestra PKI productiva ni enforcement
  de revocación.
- El gate OSS es independiente. El informe
  `gateway-rs/upstream/mirror/reviews/i2-final-tp-oss-sc-rereview-2026-08.md`
  aprueba la retención/commit local del mismo inventario, pero declara
  publicación no preparada: 19 lock entries vulnerables correspondientes a 15
  advisory IDs baseline, `cargo deny` rojo sin policy aprobada y releases de
  registry aún sin las APIs apiladas I1/pending. Deben secuenciarse releases de
  `moq-native-ietf`, `moq-transport` y después `moq-relay-ietf`, repetir package
  verification, licencias, SBOM, checksums y provenance. Este dictamen de
  seguridad no convierte esos gates en verdes.

## Veredicto

**APPROVE FOR LOCAL COMMIT**

El approval autoriza únicamente al Master a considerar un commit local del
snapshot exacto; queda invalidado si cambia cualquiera de sus hashes. No
autoriza staging por este revisor, push, PR, tag, release, publicación ni otra
mutación remota.

**READ-ONLY SECURITY REVIEW / NO COMMIT / NO PUSH / NO REMOTE MUTATION**
