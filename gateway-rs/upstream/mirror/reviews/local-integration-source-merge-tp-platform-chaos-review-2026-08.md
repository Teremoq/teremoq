<!-- SPDX-License-Identifier: Apache-2.0 -->

# Revisión TP-PLATFORM-CHAOS del source merge local I1/I2 + C1/C2

Fecha de evidencia: 2026-08-28

Rol: TP-PLATFORM-CHAOS, revisor independiente read-only

Source revisado: `/home/jimbomilk/moq-rs-teremoq-integration-work`

Alcance: merge staged local de source I1/I2 + C1/C2; no incluye el lote posterior Q/U1 ni el product pin

## Findings, por severidad

### HIGH — WR-03 sigue bloqueado por un error protegido del baseline

`cargo test --locked --offline -p moq-transport` falla con un único
`error[E0308]` en `moq-transport/src/serve/tracks.rs:501`: el test compara
`TrackName` con `&str`. La ruta no está staged y conserva SHA-256
`a8303c94925707a0a257923725bf84e4ec730b07d6bb2330fda5329b632fe0b7`.
La regresión pública construible
`cargo test --locked --offline -p moq-transport --test pending_accept` sí
pasa 1/1.

Clasificación vinculante: `BLOCKED_BY_BASELINE_E0308`.

Este bloqueo impide declarar verde el workspace completo, actualizar el product
pin o aprobar integración de producto. No es una regresión del merge staged y,
por tanto, no impide por sí solo crear el commit de merge local de source.

### LOW — el formato global conserva dos diferencias heredadas fuera del stage

`cargo fmt --all -- --check` devuelve 1 por diferencias ya presentes en rutas
protegidas no staged:

- `moq-transport/src/serve/subgroup.rs:934`;
- `moq-transport/src/serve/tracks.rs:304`.

El chequeo focal read-only de las cuatro resoluciones nuevas pasa. No se aplicó
formato ni se editó ninguna ruta protegida.

### Sin finding bloqueante atribuible al source merge

No encontré pérdida de los invariantes I1, I2, C1 o C2 en el diff combinado ni
en las cuatro resoluciones manuales. El índice coincide byte a byte con el staged
tree vinculante, no hay conflictos, cambios unstaged ni rutas fuera del conjunto
de 26 autorizado. Las suites completas de los dos crates afectados y los filtros
focales pasan.

La evidencia permite aprobar exclusivamente el commit de merge local. No prueba
un límite de memoria del proceso, resistencia DoS productiva, capacidad de
hardware, autorización SPIFFE/Zero-Trust completa ni aptitud productiva del relay.

## Veredicto vinculante

**APPROVE FOR LOCAL MERGE COMMIT**

Este veredicto no autoriza product pin, merge de Q/U1, publicación, push, PR,
release, despliegue ni claims productivos. WR-03 debe repararse y revisarse en su
lote propietario antes de cualquier gate de producto.

## Binding reproducido independientemente

| Evidencia | Valor observado | Resultado |
|---|---|---|
| Rama | `teremoq/integration-draft16-bf87128-local` | PASS |
| Upstream tracking | ninguno | PASS |
| `HEAD` / I2 | `59d9a8601885ef934cae29d89876abb7c7f73e89` | PASS |
| Tree de `HEAD` | `d108208bfb5792767881a932480da01769844148` | PASS |
| `MERGE_HEAD` / C2 | `b4ee3b68df58bbb6e7b865c2898d3f46ffbb7fd1` | PASS |
| Padre de C2 / C1 | `ee22a1079783e374371e0705775978790ddd6471` | PASS |
| Tree de C2 | `1a4411f859d74d8ec93c30aac356c1b60f12ef92` | PASS |
| Merge-base I1/I2 frente a C1/C2 | `bf87128affd316463e5dcc7599a45001f222b6de` | PASS |
| Staged tree (`git write-tree`) | `985f7f4ab4bad35c742f6c7028b1b8e6aec97e2b` | PASS |
| Rutas staged | 26 | PASS |
| SHA-256 del pathset staged | `c16063d311bc42b1baf16f314d11e3604cecc640be6542af826b09be20023470` | PASS |
| SHA-256 de `status --porcelain=v1 -z` | `085eec09a457ee974eb9a7260c278516631ca4d7941262f197e675b87506933a` | PASS |
| Unmerged | 0 | PASS |
| Unstaged | 0 | PASS |
| Conflict markers | 0 | PASS |
| `git diff --cached --check` | exit 0 | PASS |
| `git diff --check` | exit 0 | PASS |

Se comparó además `git ls-tree -r 985f7f...` con
`git ls-files --stage`; modos, blobs y paths coinciden. El delta propio del commit
C2 sobre C1 contiene 15 rutas. No hay manifests, lockfiles ni source protegido de
`moq-transport` en el stage.

## Inventario SHA-256 de las 26 rutas staged

| Ruta | SHA-256 |
|---|---|
| `moq-native-ietf/src/quic.rs` | `92e94e527dce998543b050e1d4af0012b6c18df2b4e32c068ad9ebb46594934d` |
| `moq-native-ietf/src/quic_c1_tests.rs` | `610d8430315460db1652d99067002231d7ca4f2eaa48e8de2221966fa2cee8a9` |
| `moq-native-ietf/tests/data/c1/README.md` | `717d3219aa203034fde416b6e17f291e21ab9344a15e258a92aaaf3812a14e10` |
| `moq-native-ietf/tests/data/c1/SHA256SUMS` | `ba0f134515bdca4413dc9658d4016343a2180fd6c8f624e7e1b779f013696d64` |
| `moq-native-ietf/tests/data/c1/ca.cert.der` | `ea33add88bed4676c51baa4f8da9df33d04e99cecf7d0846a756e23b0f66461b` |
| `moq-native-ietf/tests/data/c1/ca.cert.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-native-ietf/tests/data/c1/server.cert.der` | `053a80b61f971f0601d83305ec6139fbcd7ed2f78c541078ac6e68a7e6da16bc` |
| `moq-native-ietf/tests/data/c1/server.cert.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-native-ietf/tests/data/c1/server.key.der` | `1d02d7ec66886fc2bb2cc3104851e1c182d7980e946d8df2e8f0f3ae33c30436` |
| `moq-native-ietf/tests/data/c1/server.key.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-relay-ietf/src/i2_tests.rs` | `0917f6715ffba69c4b681679f17eeadffb46453b215fcff33e4e64c4d953e571` |
| `moq-relay-ietf/src/lib.rs` | `833b732c738650c0ed6297c7094bdb8309da5953b9c51f950f58f1079f68b03c` |
| `moq-relay-ietf/src/relay.rs` | `062bc828c7494e672cf8dbcd850e6b2a045792c2cf24256f702fccfdcf47d733` |
| `moq-relay-ietf/src/relay_c2_tests.rs` | `5ebccdf289a5b4183b28e78ee56dfad7f991a2c4c58eda27327c5e88f8033237` |
| `moq-relay-ietf/src/remote.rs` | `5a5a30536280fe946db0df969b1ae81099186838ec69904128a15e0ff15cf8a4` |
| `moq-relay-ietf/src/session_admission.rs` | `cc5c56db172f7fb13e1f5a1a8bea3957c096d869dd97ac3f9d9f753820f0c7ef` |
| `moq-relay-ietf/src/upstream_namespaces.rs` | `7033823b66d5e3e82c0e6afdf2e4062080b908ed11c0aedb4550bd2f7cd775b9` |
| `moq-relay-ietf/tests/c2_session_admission.rs` | `1b528da9ccd852d81085bad190e01ae9a5a84ca6724574ed6a7cd2904e7e0a0a` |
| `moq-relay-ietf/tests/data/c2/README.md` | `285e4e178ecd6a7c5cffe5409107bc11bdf096bba9ebc014e805c0b991c1ae72` |
| `moq-relay-ietf/tests/data/c2/SHA256SUMS` | `ccc4d9cbcc23c31cfd12e2ef5d0a57e6d0901c243f7a732fc6eba20a7c82c8fd` |
| `moq-relay-ietf/tests/data/c2/ca.cert.pem` | `c439d7428d418762e090e1ce0fdda1524473daa66f052da251e120d78555dfbb` |
| `moq-relay-ietf/tests/data/c2/ca.cert.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-relay-ietf/tests/data/c2/server.cert.pem` | `76fe11a03423308533516c61c8e06f994746293313ef8961091de0e87cbd2b09` |
| `moq-relay-ietf/tests/data/c2/server.cert.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-relay-ietf/tests/data/c2/server.key.pem` | `607642c80b7ec6e365ef877e24c526ca546542fb5c330ae191891a212b67aa35` |
| `moq-relay-ietf/tests/data/c2/server.key.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |

## Revisión de las cuatro resoluciones de merge

| Resolución | Resultado y evidencia |
|---|---|
| `moq-native-ietf/src/quic.rs` | PASS. Conserva C1 y añade I1 sobre la misma conexión. `Endpoint::accept()` entrega `Incoming`; `try_admit()` ocurre en `quic.rs:1247-1257` y `1433-1443`; overload usa `refuse`/`retry` sin await; `accept`/`accept_with` se ejecuta después. Un único `timeout_at` cubre transporte, TLS/ALPN y WebTransport CONNECT (`quic.rs:1193`). La evidencia I1 se extrae de la conexión aceptada y se devuelve junto a esa sesión. |
| `moq-relay-ietf/src/relay.rs` | PASS. El constructor required bounded exige endpoints explícitos, TLS, C1 bounded y un controlador C1 compartido (`relay.rs:478-525`). En `run_until`, la admisión C2 inmediata (`relay.rs:1500-1529`) precede autenticación, pending setup, path/scope y `finish`; el estado Producer/Consumer aparece sólo después (`relay.rs:860-1120`). El shutdown calcula un solo deadline absoluto, detiene accepts, cancela, drena y fuerza drop (`relay.rs:1579-1661`). |
| `moq-relay-ietf/src/i2_tests.rs` | PASS. Incorpora tres pruebas de composición con raw QUIC y WebTransport: orden C1→I1→C2→I2, N+1 pre-auth y constructor multi-endpoint con C1 compartido (`i2_tests.rs:788-1000`). Cada ruta usa un deadline absoluto y `timeout_at`; no usa sleeps como sincronización. |
| `moq-relay-ietf/src/lib.rs` | PASS. Expone la API compuesta necesaria sin alterar manifests ni wire constants. |

## Orden de seguridad y concurrencia verificado

El camino required bounded observado es:

1. C1 recibe un `quinn::Incoming`.
2. C1 intenta capacidad sin espera; N+1 se rechaza o reintenta sólo cuando
   QUINN lo permite.
3. El único futuro aceptado completa QUIC/TLS/ALPN y, para WebTransport,
   SETTINGS/CONNECT bajo el mismo deadline absoluto.
4. I1 liga la evidencia de peer a esa misma conexión aceptada; el modo legacy
   permanece separado.
5. C2 intenta capacidad de sesión inmediatamente, antes de autenticación y de
   cualquier task/state MoQT. N+1 se cierra sin waiter queue.
6. I2 autentica la evidencia, decodifica pending setup, canonicaliza el path y
   resuelve/autoriza scope antes de `finish`/`SERVER_SETUP`.
7. Sólo tras esos gates se crean contexto, Producer, Consumer, coordinator/root
   y task de sesión.

La prueba de composición pre-auth mantiene el primer cliente en un gate
determinista, presenta N+1 y verifica que el contador de autenticación no crece.
La prueba de denial I2 verifica ausencia de efectos coordinator/session. La
prueba de constructor verifica unbounded=error, dos endpoints con el mismo C1
controller=ok y controllers distintos=error.

## Matriz formal

| Gate | Mecanismo observado | Resultado |
|---|---|---|
| C1 Incoming→permit→accept | Inspección de `quic.rs` + C1 25/25 | PASS |
| C1 N/N+1 sin await/spawn waiter | `try_admit`, Refuse/Retry y tests burst/N+1 | PASS |
| C1 deadline absoluto | Transporte y WebTransport CONNECT bajo un `timeout_at` | PASS |
| C1 multi-endpoint | Constructor required bounded exige `shares_capacity_with` | PASS |
| I1 connection-bound | Suite `peer_evidence` 6/6, raw y WebTransport | PASS |
| C2 pre-MoQT | `try_admit` antes de auth/setup/state/task | PASS |
| C2 N/N+1 y M=32 | C2 focal 38/38, incluidos integration tests | PASS |
| C2 inbound/outbound separados | Controllers separados y ownership de announce/Remote | PASS |
| C2 RAII y terminal equation | Error, close, cancel, panic y forced drop en focal C2 | PASS |
| Shutdown coordinado | Un deadline monotónico, stop accepts, cancel, drain, force drop, gauges finales | PASS |
| I2 fail-closed | Auth, path, scope y operation gates antes de efectos | PASS |
| Required sin evidencia | Rechazo antes de auth/MoQT | PASS |
| Raw QUIC + WebTransport | I1, C1, C2 e integración ejercitan ambas rutas reales | PASS |
| draft-16, ALPN y Objects | Wire constants/tests conservados; suites native/relay verdes | PASS |
| Composición I1/I2/C1/C2 | 3/3 pruebas focales y dentro de suite relay completa | PASS |
| Scope del stage | 26 rutas exactas; sin manifest/lock/transport | PASS |
| Workspace completo | Falla exclusivamente en protected `tracks.rs:501` | `BLOCKED_BY_BASELINE_E0308` |

## Toolchain y aislamiento

Imagen local usada exclusivamente:

`teremoq-local-rust193-components:c2-review-20260828`

Image ID:
`sha256:f522c28d5beb21591f46e8c165030f70b32dd5b51107577ad196910e7147a007`

Versiones observadas:

- `rustc 1.93.0`;
- `cargo 1.93.0`;
- `rustfmt 1.8.0-stable`;
- `clippy 0.1.93`.

Todos los comandos Rust se ejecutaron con `--network none`, source montado
`/src:ro`, registry y git cache montados read-only, `--locked --offline` y target
en el volumen externo
`teremoq-integration-platform-review-target-20260828`. No hubo descarga,
instalación, escritura en source ni build paralelo.

Plantilla efectiva de ejecución:

```bash
docker run --rm --network none \
  -v /home/jimbomilk/moq-rs-teremoq-integration-work:/src:ro \
  -v teremoq-step7-cargo:/usr/local/cargo/registry:ro \
  -v teremoq-step7-git:/usr/local/cargo/git:ro \
  -v teremoq-integration-platform-review-target-20260828:/target \
  -w /src -e CARGO_TARGET_DIR=/target \
  teremoq-local-rust193-components:c2-review-20260828 \
  sh -c '<comando>'
```

## Comandos y resultados

| Comando dentro del contenedor | Resultado |
|---|---|
| `rustfmt --edition 2021 --check moq-native-ietf/src/quic.rs moq-relay-ietf/src/relay.rs moq-relay-ietf/src/i2_tests.rs moq-relay-ietf/src/lib.rs` | PASS |
| `cargo fmt --all -- --check` | exit 1; sólo dos diferencias heredadas no staged descritas arriba |
| `cargo check --locked --offline -p moq-native-ietf --tests` | PASS |
| `cargo check --locked --offline -p moq-relay-ietf --tests` | PASS |
| `cargo clippy --locked --offline --no-deps -p moq-native-ietf --tests -- -D warnings` | PASS |
| `cargo clippy --locked --offline --no-deps -p moq-relay-ietf --tests -- -D warnings` | PASS |
| `cargo test --locked --offline -p moq-native-ietf` | PASS: 32 unit + 6 integration = 38; 0 failed |
| `cargo test --locked --offline -p moq-relay-ietf` | PASS: 173 library + 16 binary + 10 integration + 1 doctest ejecutado = 200; 0 failed; 1 doctest ignored |
| `cargo test --locked --offline -p moq-native-ietf --test peer_evidence` | PASS 6/6 |
| `cargo test --locked --offline -p moq-native-ietf c1_` | PASS 25/25 |
| `cargo test --locked --offline -p moq-relay-ietf i2_tests::` | PASS 23/23 |
| `cargo test --locked --offline -p moq-relay-ietf c2_` | PASS 38/38 (28 unit + 10 integration) |
| `cargo test --locked --offline -p moq-relay-ietf bounded_required` | PASS 2/2 |
| `cargo test --locked --offline -p moq-relay-ietf required_bounded_constructor` | PASS 1/1 |
| `cargo test --locked --offline -p moq-transport --test pending_accept` | PASS 1/1 |
| `cargo test --locked --offline -p moq-transport` | exit 101, único `E0308` heredado en `tracks.rs:501` |

Controles host ejecutados:

```bash
git rev-parse HEAD MERGE_HEAD MERGE_HEAD^1
git merge-base HEAD MERGE_HEAD
git write-tree
git ls-tree -r 985f7f4ab4bad35c742f6c7028b1b8e6aec97e2b
git ls-files --stage
git diff --cached --name-only
git status --porcelain=v1 -z
git ls-files -u
git diff --cached --check
git diff --check
sha256sum <cada ruta staged>
```

Todos los bindings solicitados coinciden. Un intento inicial de filtros con
`bash -lc` no encontró `cargo` porque el login shell sustituyó el `PATH`; terminó
antes de compilar. Se repitió con `sh -c` y el toolchain absoluto de la imagen,
con los resultados registrados arriba. Un chequeo preliminar de espacio sobre
`/var/lib/docker` terminó antes de crear recursos porque esa ruta no estaba
montada en el host; no ejecutó build ni alteró el snapshot.

## Cleanup y no mutación

- Contenedores de revisión antes del cleanup: 0.
- Se eliminó el volumen exacto
  `teremoq-integration-platform-review-target-20260828`.
- Contenedores de revisión después del cleanup: 0.
- El volumen target ya no existe.
- `/home/jimbomilk/moq-rs-teremoq-integration-work/target`: ausente.
- El staged tree, el status-z, los 26 paths y sus hashes permanecieron idénticos
  tras las pruebas.
- No se editó source, index, estado de merge, manifests, lockfiles, tests ni
  informes existentes.
- No se hizo commit, merge, abort, fetch, push, publicación ni mutación remota.

## Evidencia documental vinculante leída

| Documento | SHA-256 |
|---|---|
| Readiness TP-PLATFORM-CHAOS | `2bc3b73be58c01eb1831ea583c4fe6043c0bc0c6a30ace46fa9f3e842c816083` |
| Readiness seguridad | `e6807e5a64267fc01b7f5b9ceeee2d6f18bc922ed9ecdd100d740131aa5a06c6` |
| Readiness OSS | `7abcd8739c599aef8e2559cb0fd3375d93a6f5cea4102f30128a436e7785a92f` |
| Owner review del source merge | `9c4c4c5bee4debaffda8aea10ef5653db9d29f6987119d83c83a02f9b22c21a7` |
| I1 owner final | `a49ff41ea6836d005884ddb900d31060f718357fdbe2c7bd563c799bb260e8a1` |
| I1 seguridad final | `142860f7cdc408095e806acbf41bd2e32b2137307f44425d6e25e6ab8b1583ee` |
| I1 OSS final | `6b0f1aaa0606eae264997907d31b0d442a4275f99f0d7550570a3895c65bacc3` |
| I2 owner final | `e3477a01f2669efe868a1b6facb12205c7d8b32e9ec73946c5bb114ca8cb4f07` |
| I2 seguridad final | `73170aa2a26d048067acdd189e09fec590e226e7e5c1432569d9439873ac0a61` |
| I2 OSS final | `1d0e80b5d1128989eb6413cb07fe932a835bc19d800ed262be4122fa6d27aecb` |
| C1 owner final | `a7cca70bc0d926739ca109cacdef1648e200255ad9c82cb33e2b521e0d2b7626` |
| C1 TP-PLATFORM-CHAOS final | `78d1c3da31b0f3f46482c56e89d62842ffcc04b933aec522fc3e55aa52f04af5` |
| C1 seguridad final | `d613817d9ea2da9b7698caf8b934512515c3a6ca0ca76d77d8d2faa223d12d1e` |
| C1 OSS final | `90bf9725e4e8f4eaf4e0c0829136e285be42d63e86b9f834513da9027b129544` |
| C2 owner final | `a15dd8989f3cffa234daf70bec33cc92e8d4e1243871ed41e0ca986d41d480bd` |
| C2 TP-PLATFORM-CHAOS final | `318f22a97e720608c45123ecd1e79829b96eb3f1da7979cdfdab81882e463c98` |
| C2 seguridad final | `d4a27e0333528b4f238875aed0e8423fa06c5dd425eef9f1944b8674cdcf96f9` |
| C2 OSS final | `365f21cdd754b82f90ef864c2961d5812b795fc3f48888b3974dcbc95150bea4` |

También se leyó completamente `/home/jimbomilk/teremoq/.cursorrules`.
Los hashes anteriores son cadena de custodia documental; el SHA-256 de este
informe se calcula después de su validación final y se entrega junto al veredicto.
