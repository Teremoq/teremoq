<!--
SPDX-FileCopyrightText: 2026 Teremoq contributors
SPDX-License-Identifier: Apache-2.0
-->

# Rerevisión formal de seguridad C2 — TP-SEC-PKI

Fecha: `2026-08-28`  
Rol: `TP-SEC-PKI`  
Modo: `READ-ONLY SECURITY REVIEW / NO COMMIT / NO PUSH / NO PUBLICATION / NO REMOTE MUTATION`

## Hallazgos primero

### HIGH — La cancelación del creador puede retirar el slot que un waiter del mismo key ya está adoptando

`RemoteSlotReservation` conserva el mapa, el key y el `Arc` del slot, pero no
conserva el guard de su mutex (`moq-relay-ietf/src/remote.rs:186-216`). Su
`Drop` retira la entrada si el mapa aún contiene el mismo `Arc`
(`remote.rs:218-231`). El guard que impide adelantar al creador se obtiene y se
transporta por separado (`remote.rs:1064,1084-1099`) y se convierte después en
la variable local `cached` (`remote.rs:1103-1106`).

Al cancelar el future durante `Remote::connect(...).await`, la destrucción de
`cached` puede desbloquear el slot antes de que se ejecute el `Drop` de la
reserva. Otro worker que ya espera ese mismo slot puede entonces:

1. tomar el mutex del slot;
2. comprobar que el `Arc` todavía es la generación presente en el mapa
   (`remote.rs:1108-1117`);
3. continuar mientras el `Drop` original retira esa misma entrada; y
4. adquirir otro permiso y empezar `Remote::connect` sobre un slot ya huérfano
   (`remote.rs:1132-1176`).

Con capacidad mayor que uno, el nuevo dial no necesita esperar a que el permiso
original se libere. Un tercer caller puede insertar simultáneamente una nueva
generación para el mismo key. El límite global N sigue acotando permisos, pero
se pierde la unicidad del cache: pueden existir varias raíces para el mismo
destino, una no aparece en `RemoteManager::remotes`, y el shutdown no puede
cancelarla cooperativamente mediante el recorrido del mapa. Sigue retenida por
`OwnedRemoteTasks`, por lo que acabará forzada al deadline, pero esto no cumple
la reserva generation-safe ni el lifecycle outbound declarado.

La nueva regresión no detecta la carrera: cancela cuatro creadores de keys
distintos sin un waiter concurrente del mismo key
(`remote.rs:578-660`). La prueba same-key no cancela al creador
(`remote.rs:724-767`).

Cambio exigido a `TP-RUST-DIST`:

1. Hacer indivisible el retiro de la generación y la liberación del guard del
   slot. Una solución conservadora es que la reserva posea el
   `OwnedMutexGuard` y retire el mapa mientras todavía impide que un waiter
   observe/adopte esa generación; sólo después debe desbloquear el slot.
2. No resolverlo con task detached, waiter de capacidad, callback, log, retry
   temporal ni un check-then-act adicional.
3. Añadir una prueba determinista con capacidad `>= 2`, creador bloqueado en
   setup QUINN/MoQT y waiter del mismo key ya pendiente. Cancelar el creador y
   demostrar que el waiter observa la generación retirada antes de reintentar,
   que queda exactamente un slot/una conexión actual, ningún root huérfano,
   ningún dial duplicado, un terminal por permiso y capacidad recuperada.

### MEDIUM — La ruta de slot existente incumple el contrato zero-effect de `Closed` y contiene un panic de producción

La inserción de un slot nuevo usa
`try_lock_owned().expect("a newly created remote slot is unlocked")` dentro de
código de producción (`remote.rs:1088-1092`). Aunque la invariante pretenda
hacer imposible el error, `.cursorrules` prohíbe `expect()` en producción. El
fallo además ocurriría mientras el mutex del mapa está retenido, en una frontera
de recuperación y cancelación que debe ser fail-closed y no panicar.

Para un slot existente vacío o muerto, el código puede ejecutar
`remote.shutdown().await` y registra `remote_url` antes de pedir el nuevo
permiso (`remote.rs:1120-1137`). Si el controller ya está cerrado, sólo después
obtiene `SessionAdmissionDecision::Closed` (`remote.rs:1136-1146`). Por tanto,
esa disposición no garantiza cero estado/log previo. La prueba
`c2_out_stop_before_admit_has_no_remote_side_effects` usa exclusivamente un
mapa vacío y un key nuevo (`remote.rs:518-575`), de modo que no cubre el caso
real de slot in-flight/vacío o conexión muerta.

Cambio exigido:

1. Eliminar el `expect` de producción y devolver un error fijo, redactado y
   tipado si la invariante interna no se cumple, sin insertar ni envenenar
   estado compartido.
2. En el camino de reconexión, hacer que la decisión close-aware preceda a
   cualquier log derivado del destino, dial, mutación o tarea. Un simple
   `is_running` previo no es suficiente como linearización.
3. Probar stop-before-admit con un slot preexistente vacío y con uno muerto,
   usando probes de log, dial, mapa, task owner y contadores. `Closed` debe
   dejar `admitted_total`, `rejected_capacity_total` y `terminal_total` sin
   cambio.

### MEDIUM — El test wire libera el relay antes de demostrar que el cliente espera `SERVER_SETUP`

La prueba nueva sí usa el encoder oficial de `CLIENT_SETUP` y sí comprueba el
código `0x3` y la razón fija mediante los errores públicos de raw QUIC y
WebTransport (`moq-relay-ietf/src/relay_c2_tests.rs:175-253`). Sin embargo,
libera el gate del accept inmediatamente después de escribir CLIENT_SETUP
(`relay_c2_tests.rs:193-203`) y sólo después crea/polleará el future de lectura
de SERVER_SETUP (`relay_c2_tests.rs:204-221`). En un runtime multithread el
servidor puede cerrar antes de que ese read haya observado `Pending`. No queda
demostrado el ordering obligatorio “cliente realmente esperando SERVER_SETUP
→ rechazo”.

Además, N se ocupa mediante permisos privados sintéticos
(`relay_c2_tests.rs:438-451`). Los probes de mlog, coordinator/tagger y `Locals`
son independientes y valiosos (`relay_c2_tests.rs:468-477`), pero la ausencia
de un root N+1 se infiere sólo de los contadores de `SessionAdmission`
(`relay_c2_tests.rs:478-481`), el mismo branch bajo prueba. No existe un probe
independiente en el punto de inserción en `sessions` (`relay.rs:957-976`). Las
pruebas de integración conservan N transportes nativos reales, pero no inician
MoQT en N+1 ni inspeccionan el cierre (`tests/c2_session_admission.rs:275-317,
319-358,360-425`).

Cambio exigido:

1. Pollear el read oficial de SERVER_SETUP hasta `Pending`, señalar esa
   observación con channel/barrier y sólo entonces liberar el gate de accept.
2. Mantener la aserción exacta de code/reason sin `Debug` ni material TLS.
3. Añadir un probe `cfg(test)` independiente justo en la creación/inserción
   del root de sesión y demostrar cero para N+1; no usar sólo
   `admitted_total`/`inflight` como oráculo.

### MEDIUM — Sigue sin existir una prueba real de error de scope o `Session::run` que recupere capacidad

El finding previo C2-T09 no fue cerrado. La integración cubre error de setup y
cierre establecido (`tests/c2_session_admission.rs:639-691`), y los tests
inyectan panic de setup/run (`relay_c2_tests.rs:276-346`). No hay una ejecución
en la que `Coordinator::resolve_scope` devuelva error ni una en la que
`Session::run` retorne un error ordinario. Las únicas cuentas `RunError` en
tests son llamadas manuales a `permit.finish(SessionTerminal::RunError)`
(`session_admission.rs:586-589,840-883`), un oráculo del mismo código de
accounting.

Cambio exigido: añadir rutas reales y deterministas de error de
scope/coordinator y de error no-panic durante run, y demostrar con estado
independiente que cada una libera/reacquire capacidad, publica exactamente un
terminal y no deja task/root/namespace residual.

## Veredicto

CHANGES REQUIRED

Los fixes anteriores son comprobables y no requieren cambiar wire, TLS,
dependencias ni el límite global. El veredicto no autoriza commit local, C3,
integración, push, publicación, release ni uso productivo.

## Binding e integridad del snapshot

| Elemento | Valor reproducido |
| --- | --- |
| Worktree | `/home/jimbomilk/moq-rs-teremoq-c2-work` |
| Branch | `teremoq/c2-session-shutdown-ee22a10` |
| Tracking | ninguno |
| HEAD/base | `ee22a1079783e374371e0705775978790ddd6471` |
| Tree | `232e449945e877b024f2fc4223f0d2eea124b39b` |
| Stage | vacío |
| Inventario | 15 paths exactos |
| SHA-256 de `git status --porcelain=v1 --untracked-files=all` | `41969b3ff7d7ebcaaf891137a17519a2097319642b6753db144a0b5a000db614` |
| `.cursorrules` | `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2` |
| ADR-0007 | `0085bdaa37cd3645a4a2c5a3163b0b096453b84f66635514fce6015d6bed25d8` |
| Plan TP-SEC-PKI | `9d3ba88aa9d0299ef9efc99927e28dfa6d7d31fc8b09095eb0436be38f00aa18` |
| Revisión TP-SEC-PKI previa | `c188c80b64fbfd65652ba6ec0f042f2deaf42d65e7dfe06f5e060547f89393ab` |
| Revisión TP-PLATFORM-CHAOS previa | `f3d5bdf6eba57d67b8839e29072f36638c347ccbb4d67dc2762b4b3ad97b2f79` |
| Owner report nuevo | `1fdc354f8dc8818e853b17dd59318d1d2c90fe85e371cfda37f80a04bd1da0e2` |

Todos los hashes vinculantes anteriores coinciden. No hubo divergencia de
snapshot durante la inspección.

### Inventario C2 exacto

| Path | SHA-256 reproducido |
| --- | --- |
| `moq-relay-ietf/src/lib.rs` | `af994bc136fafa97b0a6faa15645811fc1f04b8d03851702f3fa48d38fbb0253` |
| `moq-relay-ietf/src/relay.rs` | `67dad064d0b13d39bb6bd8ef9b81557ce291f48db76cda98ff476f1b270735e4` |
| `moq-relay-ietf/src/relay_c2_tests.rs` | `713ac2151be6233ff3bc6b7a1cf68242f85d8812198c511f2fa3c64df1a403a5` |
| `moq-relay-ietf/src/remote.rs` | `f462286d1c8b9fc0b5eb3b478400c97ffc064d90270f899fea9bf80235114fdc` |
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

### Inputs protegidos reproducidos

| Input | SHA-256 |
| --- | --- |
| Workspace `Cargo.toml` | `6665802c9ad7192d61521a62877454e25bde7072c611e617780a932f583aa48f` |
| `Cargo.lock` | `b518a2fa4a6d7a0ffe0bdfe4b530f05196ac0f5e6f7ef51da9e5a83c0b0561c0` |
| Relay `Cargo.toml` | `c88726b7739c35c4fcb42fd511bfe608e478b5d2489729081821fc84cd1b318d` |
| Native `Cargo.toml` | `3180121a89c58071718236a408f36c1c87757d6f9ff81e899fb3b5814c8d4c8e` |
| Transport `Cargo.toml` | `78f582c201082f7badece64f7fa65d215a6694412b7a7699332fa3bc9a4f3743` |
| Native QUIC | `b0c8dfb3e4963365a3a27f52a84d2fc54292cfc5a056a817a5a0d0a4f38b3723` |
| Setup ALPN (`setup/mod.rs`) | `c49d71dcacd5e3f5eef7a673e11b9058d3fd701e1fb83331a737098894a2d750` |
| Setup version | `384772b32812a0761fa55d16a9fd29e30595323ece1b3fca013ec3720eaec4ad` |
| Transport session (`session/mod.rs`) | `8e8992e1bb75d77c2475499014509a9362b965162d86156bdf6068a16b3cd2ea` |
| `REUSE.toml` | `afc7fd86e591a56078b11982ee4d039ea1dfe3f9d56a90e3e7fa9f84fbddb6cc` |
| Apache-2.0 | `1248f876e0140942002b476a19c95d5b5b44c625e69c96611d23119ee87fa04e` |
| MIT | `c7d191b5901a741f2e39c74bd7a7594014a81fbe2bc7d533d4c29ad4cfe4e057` |

No cambiaron manifest, lock, dependencia, feature, TLS/mTLS, QUIC, draft,
ALPN, wire, `Objects`, licencia ni pin de producto. No se encontró `unsafe`,
`ManuallyDrop`, `mem::forget`, `add_permits` ni adquisición asíncrona de
permiso C2.

## Cierre de findings anteriores

| Finding previo | Resultado independiente |
| --- | --- |
| F1 cierre linealizable de admission | `Semaphore::close` y `TryAcquireError::Closed` corrigen la adquisición nueva; FAIL global por los efectos previos de slot existente descritos arriba. |
| F2 cancelación de slots Remote | FAIL; distinct-key queda limpio, pero la entrega al waiter same-key no es atómica. |
| F3 contrato wire N+1 | Exact code/reason: PASS. Espera SERVER_SETUP y root independiente: FAIL. |
| F4 watchdog absoluto de tests | PASS por inspección: helpers reciben el deadline del caller y no lo reinician. |
| F5 ordering/races | PASS: observer previo al terminal y dos interleavings controlados con tasks/channels. |
| F6 rustfmt/Clippy | Focused rustfmt independiente: PASS. Clippy Rust 1.93: PASS sólo como evidencia owner vinculada; no se reconstruyó. |

## Resultado C2-I01 a C2-I12

No se usa `PARTIAL`: cada fila es PASS o FAIL respecto del contrato obligatorio.

| Invariante | Resultado | Evidencia |
| --- | --- | --- |
| I01 capacidad global/no bloqueante | PASS | Un controller inbound compartido; `try_acquire_owned` es la única adquisición de permisos, sin waiter/check-then-act de capacidad. |
| I02 N+1 antes de efectos | FAIL | El source coloca el gate correctamente, pero T05/T06 no aportan la prueba ejecutable obligatoria de SERVER_SETUP pendiente/root independiente. |
| I03 guard privado/no clonable/terminal único | PASS | `SessionPermitGuard` posee un solo `Option<OwnedSemaphorePermit>` y `Option::take` evita doble terminal. |
| I04 ordering observable | PASS | Active/inflight y permit se liberan antes de `terminal_total.fetch_add(..., Release)`; snapshot carga terminal con Acquire. |
| I05 panic/cancel/drop | FAIL | El permit se libera, pero la reserva Remote no serializa unlock/retiro frente a waiter same-key y existe `expect` de producción. |
| I06 0/MAX/MAX+1 sin panic | PASS | Los dos límites y timeout se validan antes de `Semaphore::new`; MAX exacto se acepta y MAX+1 es error tipado. |
| I07 deadline y cierre de admission | FAIL | Hay un solo deadline y ambos semáforos se cierran antes de cancel/drain, pero un slot existente puede ejecutar estado/log antes de observar `Closed`. |
| I08 observabilidad redactada | FAIL | Snapshots y closures son fijos; la reconexión puede registrar `remote_url` antes de obtener `Closed`. |
| I09 independencia de identidad | PASS | Admission no lee IP/CID/SNI/path/certificado/identidad/scope/auth y el permit no se usa como principal/rol. |
| I10 bounded fail-closed/legacy separado | PASS | APIs aditivas y tipadas; no hay fallback bounded→legacy; las firmas legacy permanecen. |
| I11 superficie upstream mínima | PASS | 15 paths, todos bajo `moq-relay-ietf`; inputs protegidos byte-idénticos. |
| I12 outbound delimitado/owned | FAIL | La capacidad sigue separada, pero la carrera same-key puede producir un root no indexado por el mapa y sólo forzable por el owner al deadline. |

## Resultado C2-T01 a C2-T25

| Test | Resultado | Conclusión de rerevisión |
| --- | --- | --- |
| T01 extremos de configuración | PASS | 0/MAX/MAX+1/timeout, validación previa y `catch_unwind`. |
| T02 N/N+1 un endpoint | PASS | N transportes reales retienen raíces; N+1 se dispone sin liberar N. |
| T03 capacidad global multi-endpoint | PASS | Raw y WebTransport comparten el mismo monitor/límite. |
| T04 contenders | PASS | Burst M=32 termina bajo watchdog sin waiter de permiso y nunca supera N. |
| T05 cliente esperando SERVER_SETUP | FAIL | El gate se libera antes de crear/pollear el read de SERVER_SETUP. |
| T06 efectos independientes pre-gate | FAIL | Mlog, tagger/coordinator y Locals pasan; falta probe independiente de root/task N+1. |
| T07 cierre exacto raw/WT | PASS | API pública observa code `0x3` y razón fija en ambos transportes. |
| T08 recuperación normal/setup | PASS | Setup error y cierre establecido devuelven capacidad. |
| T09 errores scope/run | FAIL | No hay error real de coordinator/scope ni `Session::run` ordinario; sólo terminal manual/panic. |
| T10 cancel/drop | FAIL | Cancel distinct-key pasa; falta y falla por source el handoff concurrente same-key. |
| T11 panic/unwind | PASS | Panics de setup/run se capturan y terminalizan una vez. |
| T12 natural/cancel/shutdown | PASS | Interleavings controlados en tasks distintas y ecuación terminal exacta. |
| T13 ordering cross-thread | PASS | Observer arranca antes de terminal y valida Release/Acquire sin sincronización por thread creation posterior. |
| T14 variación identidad/red | PASS | Decisión de capacidad no recibe ni consulta esas señales. |
| T15 shutdown cooperativo | PASS | Controllers cierran, roots owned drenan bajo un `timeout_at` absoluto y gauges terminan en cero. |
| T16 sesión no cooperativa | PASS | El mismo deadline fuerza Drop local y no existe await post-deadline. |
| T17 accept/admit/shutdown | FAIL | Inbound y new-key pasan; falta el caso existing-slot/same-key y el source permite efectos antes de `Closed`. |
| T18 recorder hostil | PASS | Admission/terminal/permit Drop usan sólo semáforo/atómicos; no callback/backend externo. |
| T19 outbound durante saturación inbound | PASS | Controllers y gauges son separados; announce/Remote no consumen inbound. |
| T20 lifecycle owned completo | PASS | Sessions, controls, announce, Remote roots/cleanup y pulls están en colecciones owned; no task bounded detached. |
| T21 composición C1 | PASS | Monitores públicos C1 quedan quiescentes. `SD-07` exact mid-TLS sigue `UNTESTABLE_EXACT_MID_TLS_WITH_C1_PUBLIC_API`, no se presenta como pass. |
| T22 legacy vs bounded | PASS | Compatibilidad source y separación explícita. |
| T23 regresión raw/WT | FAIL | Flujos admitidos y cierre exacto pasan; falta demostrar el estado pendiente de SERVER_SETUP antes del rechazo. |
| T24 redacción | FAIL | Schema/closures/fixtures pasan; `remote_url` puede emitirse antes de `Closed` en reconexión. |
| T25 superficie upstream | PASS | Scope, manifests, lock, TLS, wire y licencias exactos. |

## Validaciones y comandos

Comprobaciones read-only ejecutadas independientemente:

```text
sha256sum .cursorrules ADR-0007 <plan/reviews/owner report>
git rev-parse HEAD^{commit} HEAD^{tree}
git branch --show-current
git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}'
git status --porcelain=v1 --untracked-files=all | sha256sum
git diff --cached --name-only
sha256sum <15 paths C2 y 12 inputs protegidos>
git diff --check ee22a1079783e374371e0705775978790ddd6471 --
git diff --cached --check
git diff --no-index --check /dev/null <cada path nuevo>
rg <admission, lifecycle, logging, identity, panic y primitivas prohibidas>
openssl x509/pkey <sólo metadata, DER hashes y correspondencia de clave pública>
```

Resultados:

- HEAD/tree/branch sin tracking/stage vacío/inventario de 15 paths: PASS.
- Todos los hashes actuales declarados por el owner: PASS.
- `git diff --check`, cached check, nuevos paths y conflict markers: PASS.
- No dependency/feature/lock/TLS/draft/ALPN/Objects/`unsafe`: PASS.

Rustfmt focal, sin build y con source read-only:

```text
docker run --rm --network none --read-only \
  -v /home/jimbomilk/moq-rs-teremoq-c2-work:/src:ro -w /src \
  teremoq-local-rust193-components:c2-review-20260828 \
  rustfmt --edition 2021 --check <siete paths Rust C2>
```

- Image ID: `sha256:f522c28d5beb21591f46e8c165030f70b32dd5b51107577ad196910e7147a007`.
- Rustfmt `1.8.0-stable (254b59607d 2026-01-19)`: PASS.
- Se verificó también la presencia de Rust/Cargo 1.93.0 y Clippy 0.1.93.
- No se repitió Clippy ni tests porque no existe un binario local corregido
  reutilizable y el mandato excluye reconstrucciones grandes. Los binarios
  preexistentes enumerados en cache contienen los nombres del snapshot anterior,
  no los tests corregidos. Se conserva como evidencia owner vinculada: 22+10
  focales, relay completo, C1 completo y Clippy focal PASS.

REUSE y Gitleaks, sin red y por digest:

```text
fsfe/reuse:5.1.1@sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da lint
zricethezav/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f dir <path> --redact
```

- REUSE: PASS, `204/204`, Apache-2.0 y MIT.
- Cada uno de los siete paths Rust C2: PASS, cero findings.
- Fixtures: exactamente un finding `private-key`, completamente redactado,
  correspondiente a la clave sintética pública documentada.
- Una primera invocación Gitleaks con dos paths posicionales fue inválida para
  este CLI y escaneó el root del contenedor; se descartó como gate, se registró
  el error y se repitió correctamente path por path. Un scan adicional de todo
  `src/` detectó sólo la clave de test heredada en el `tls.rs` no modificado.

## Fixtures y frontera de confianza

Los hashes del payload DER reproducidos son:

- CA: `ea33add88bed4676c51baa4f8da9df33d04e99cecf7d0846a756e23b0f66461b`;
- certificado servidor: `053a80b61f971f0601d83305ec6139fbcd7ed2f78c541078ac6e68a7e6da16bc`;
- clave servidor: `1d02d7ec66886fc2bb2cc3104851e1c182d7980e946d8df2e8f0f3ae33c30436`.

Coinciden byte a byte con C1. Certificado y clave tienen la misma clave pública
SHA-256 `6c4c590db18e4f3f73fc7deb40ee6f0c2ca0b31a41a968bead99a7d8af82cb1c`.
El certificado sólo identifica `localhost`/`127.0.0.1`, vence el
`2036-08-23T21:23:11Z`, y README/sidecars lo declaran material sintético,
público y test-only. No se mostró PEM ni contenido de clave.

C2 sigue siendo capacidad post-handshake. No autentica, autoriza ni establece
mTLS; no usa IP, SNI, path, certificado o identidad como principal y no
sustituye C1/I2. No se presenta como defensa DDoS total ni como límite completo
de memoria/proceso.

## Bloqueos y riesgos residuales

- `C2-WR-03` permanece exactamente `BLOCKED_BY_BASELINE_E0308` en el
  `moq-transport/src/serve/tracks.rs:501` no modificado, SHA-256
  `a8303c94925707a0a257923725bf84e4ec730b07d6bb2330fda5329b632fe0b7`.
  No es pass ni regresión C2.
- `SD-07` exact mid-TLS permanece
  `UNTESTABLE_EXACT_MID_TLS_WITH_C1_PUBLIC_API`; la evidencia C1 pública es
  conservadora y no se sobreafirma.
- Un deadline Tokio es cooperativo y no garantiza pared dura ante runtime
  bloqueado, OOM/abort o destructor externo síncrono arbitrario.
- Los root limits no acotan maps/colas child ni sustituyen cgroups, rate
  limiting de red u observabilidad del host.
- Advisory, package/release, publicación OSS y pin de producto son gates
  separados incluso después de corregir estos findings.

Confirmación final: `READ-ONLY SECURITY REVIEW / NO COMMIT / NO PUSH / NO PUBLICATION / NO REMOTE MUTATION`.

CHANGES REQUIRED
