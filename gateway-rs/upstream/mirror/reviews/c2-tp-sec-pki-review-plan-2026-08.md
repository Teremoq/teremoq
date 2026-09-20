<!-- SPDX-License-Identifier: Apache-2.0 -->

# Plan formal de revisión de seguridad C2 — TP-SEC-PKI

Fecha: 2026-08-28  
Estado: plan de revisión; no es un dictamen sobre una implementación C2  
Rol: TP-SEC-PKI  
Modo: `READ-ONLY SECURITY REVIEW / NO COMMIT / NO PUSH / NO REMOTE MUTATION`

## Hallazgos de preparación, por severidad

### HIGH — El límite C2 no protege trabajo criptográfico previo a `Server::accept`

La ruta actual recibe conexiones establecidas en `moq-relay-ietf/src/relay.rs:298-322`. Por tanto, un límite implementado únicamente en `moq-relay-ietf` puede rechazar antes del setup MoQT, de tareas de sesión y del estado de aplicación, pero no antes del handshake QUIC/TLS o WebTransport. Ese límite de confianza previo pertenece a C1.

La revisión final exigirá una composición explícita:

- C1 limita los handshakes pendientes por endpoint.
- C2 limita globalmente las sesiones entrantes ya aceptadas, compartiendo una sola capacidad entre todos los endpoints del relay.
- C2 no podrá describirse como defensa pre-handshake ni como protección completa contra DDoS de red.

### HIGH — El shutdown actual no es globalmente acotado

`Relay::run` mezcla el runner upstream, `--announce`, accepts y sesiones en `moq-relay-ietf/src/relay.rs:192-471`, y sólo después ejecuta `RemoteManager::shutdown` en `relay.rs:477`. A su vez, `RemoteManager` mantiene tareas outbound sin un join completo en `moq-relay-ietf/src/remote.rs:404-515,624-766`.

La cuota de C2 debe excluir `--announce`, `RemoteManager`, pulls y forwarding outbound. Sin embargo, una API que afirme shutdown acotado del `Relay` completo deberá supervisar y drenar también el trabajo outbound propiedad del relay bajo el mismo deadline monotónico. Una API sólo inbound deberá nombrar y documentar ese alcance de forma inequívoca y no se aceptará como prueba de shutdown completo.

### MEDIUM — Admisión y liberación no pueden invocar código arbitrario

`ConnectionTagger`, `Coordinator`, el recorder de métricas y varios `Drop` pueden ejecutar código externo o trabajo no acotado. Las rutas relevantes empiezan en `moq-relay-ietf/src/relay.rs:361-448`, `session.rs:145-250` y `metrics.rs:175-196`.

La adquisición, el rechazo, la transición terminal y `Drop` del permiso C2 deberán limitarse a operaciones locales no bloqueantes sobre semáforo/atómicos. No se admitirán callbacks, colas, tareas, waits, logging ni macros de métricas en ese camino crítico.

### MEDIUM — El baseline mezcla señales de red con clasificación legacy

El baseline puede pasar IP local/remota, SNI y path a `ConnectionTagger` (`relay.rs:389-411`) y resolver scope desde path mediante `Coordinator` (`relay.rs:361-384`). Además, la configuración TLS actual no solicita certificado cliente (`moq-native-ietf/src/tls.rs:107-113`).

C2 no corrige autorización ni mTLS. La capacidad deberá ser completamente independiente de certificado, identidad, IP, CID, SNI, path, scope, namespace, rol y clase de conexión. Un permiso de capacidad nunca será evidencia de autenticación o autorización. La aprobación futura será delta-local y no aprobará por sí sola el modelo de identidad para producción.

## Binding y procedencia

Base C1 local aprobada:

- Commit: `ee22a1079783e374371e0705775978790ddd6471`
- Tree: `232e449945e877b024f2fc4223f0d2eea124b39b`
- Parent: `bf87128affd316463e5dcc7599a45001f222b6de`
- Subtree `moq-relay-ietf`: `a5ba97856468908be23de7aa78e3e4446c89626a`
- El subtree relay no tiene delta entre el parent y C1.

Fuentes normativas leídas íntegramente:

| Fuente | SHA-256 |
|---|---|
| `.cursorrules` | `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2` |
| `ADR-0007-concurrency-admission-and-bounded-shutdown.md` | `0085bdaa37cd3645a4a2c5a3163b0b096453b84f66635514fce6015d6bed25d8` |
| `PATCH-SERIES.md` | `b0fe298fa0b4c37c7562c6fc0ea541ceca26fbf0cd40a04016645277a34b642e` |
| `moq-rs-concurrency-limits-proposal.md` | `2d99636e633325c731b3767d502e722f23427148b3bb84631ae87136c00d13ad` |
| `concurrency-admission-issue-draft.md` | `c6ff42d70d6a67272a030e4677cb4e908f9d5f99bfe153c211ed9cae6db5a202` |
| `task-04-concurrency-isolation.md` | `d78ecc8e8e3692413574cdece9c7982ab51fef266ed85ac2530e086bc5c6f355` |
| `c1-tp-sec-pki-final-review-2026-08.md` | `d613817d9ea2da9b7698caf8b934512515c3a6ca0ca76d77d8d2faa223d12d1e` |
| `c1-tp-platform-chaos-final-review-2026-08.md` | `78d1c3da31b0f3f46482c56e89d62842ffcc04b933aec522fc3e55aa52f04af5` |
| `c1-tp-oss-sc-rereview-2026-08.md` | `90bf9725e4e8f4eaf4e0c0829136e285be42d63e86b9f834513da9027b129544` |
| `c1-local-rereview-2026-08.md` | `a7cca70bc0d926739ca109cacdef1648e200255ad9c82cb33e2b521e0d2b7626` |

Anchors principales del source relay exacto:

| Ruta | SHA-256 |
|---|---|
| `moq-relay-ietf/Cargo.toml` | `c88726b7739c35c4fcb42fd511bfe608e478b5d2489729081821fc84cd1b318d` |
| `moq-relay-ietf/src/relay.rs` | `e0dd6c18b0d5c80dd73dafe4e7366495f4c9fbe2efee9138f210392c48604b9b` |
| `moq-relay-ietf/src/session.rs` | `62f162dc54808d6859629862dd22a33c41312466f6d7a0bdf1b9e0a4f2ce5fb2` |
| `moq-relay-ietf/src/remote.rs` | `79a4c54811b0dbafb05f12578ccc210bcebafbcc1e1cebcbe067307f7fa7a63a` |
| `moq-relay-ietf/src/metrics.rs` | `03e7baedb147226277488ab81411bb25acaeb68e1e8e879701752636494a00314` |

El snapshot C2 final deberá declarar base, HEAD/tree, status, hashes de todas las rutas cambiadas y diff completo. Si cualquiera cambia durante la revisión, el dictamen se detendrá como snapshot inestable.

## Mapa del límite de confianza actual

El orden actual relevante es:

1. Se crea un accept futuro por endpoint en `relay.rs:278-296`.
2. Un accept termina en `relay.rs:298-322`; el transporte ya ha realizado su handshake.
3. Se incrementan métricas, se crea contexto mlog y se clonan handles en `relay.rs:324-335`.
4. Se crea el futuro de sesión en `relay.rs:337-469`.
5. `Session::accept_with_config` realiza setup MoQT en `relay.rs:342-356`.
6. Se invocan resolución de scope y tagger en `relay.rs:361-411`.
7. Se crean `Producer`, `Consumer` y ejecución de aplicación en `relay.rs:422-466`.

La inserción C2 aceptable será inmediatamente después del resultado exitoso de accept y antes de reencolar el siguiente accept, desestructurar datos observables, incrementar métricas, crear mlog, clonar handles o construir cualquier futuro/tarea de sesión. La reencolación actual de un único accept futuro por endpoint no es un waiter de capacidad, pero la disposición de N+1 deberá ocurrir primero para que el ordering sea demostrable y estable.

## Modelo de amenazas

La revisión supondrá adversarios capaces de:

- abrir transportes válidos o inválidos simultáneamente por uno o varios endpoints;
- elegir IP, CID, SNI, path, certificados, timings y frames de setup;
- mantener sesiones vivas, cancelar en cualquier await, provocar errores de decode/setup y cerrar en carreras;
- ocupar N permisos y presentar N+1 o muchas más conexiones a la vez;
- provocar panic/unwind en código de test alrededor del ownership del permiso;
- bloquear o hacer panic en callbacks/coordinator/metrics si éstos fueran alcanzables;
- iniciar shutdown mientras accept, admisión, setup, sesión y cierre compiten;
- intentar forzar reinicios del timeout para alargar indefinidamente el shutdown;
- observar códigos de cierre, razones, latencia, contadores, tracing y mlog para extraer datos sensibles;
- explotar límites extremos (`0`, `MAX`, `MAX+1`) o conversiones entre tipos;
- explotar una API legacy o un fallback para eludir el límite bounded.

Fuera del alcance de C2:

- SYN/UDP floods, coste de handshake previo a `Server::accept` y límites de C1;
- autenticación, autorización, PKI, revocación o clasificación de relay-peer;
- cuotas por tenant, IP, SNI, path, certificado o identidad;
- cgroups, límites de proceso, observabilidad del host o mitigación DDoS externa;
- garantías hard real-time frente a un runtime bloqueado, OOM/abort o `Drop` síncrono arbitrario externo;
- rediseño de wire format, draft, ALPN, transporte, `Objects`, TLS o política Teremoq upstream.

## Invariantes obligatorios

### C2-I01 — Capacidad global y no bloqueante

Habrá un único controlador de capacidad inbound propiedad de `Relay`, compartido por todos sus endpoints. Cada conexión aceptada intentará exactamente una adquisición mediante `try_acquire_owned` o una primitiva oficial equivalente con semántica inmediata.

Quedan prohibidos:

- `acquire`, `acquire_owned`, `select!` sobre adquisición o cualquier waiter;
- `available_permits()` seguido de adquisición;
- contador `load` seguido de incremento como check-then-act;
- un semáforo por endpoint, task, protocolo o identidad;
- reintentos, backoff, colas o spawn previo a la decisión.

### C2-I02 — Rechazo N+1 antes de efectos

Si no hay capacidad, N+1 se cierra inmediatamente con un código y una razón constantes, públicos y de cardinalidad acotada. No se usarán campos del peer ni ocupación interna en la razón.

Antes de ese cierre no podrá ocurrir ninguno de estos efectos C2/post-accept:

- SERVER_SETUP, setup MoQT o creación de `Session`;
- spawn, inserción en `FuturesUnordered` o cola de trabajo de sesión;
- métrica/gauge de sesión aceptada, mlog o path tracing;
- `ConnectionTagger`, `Coordinator`, `resolve_scope` o callbacks;
- lookup, registro, watcher, namespace, cache, forwarding o respuesta de aplicación;
- construcción de `Producer`, `Consumer`, `SessionContext` o handles de aplicación.

El cierre de transporte inevitable no contará como efecto prohibido si usa exclusivamente la constante revisada y no ejecuta callbacks.

### C2-I03 — Permiso RAII privado, no clonable y terminal único

El guard deberá:

- poseer un `OwnedSemaphorePermit` concreto y privado;
- no implementar `Clone` ni exponer el permit, el semáforo o métodos para añadir capacidad;
- no almacenarse en `Arc`, globales, closures detached o estructuras fuera del lifetime de la sesión;
- impedir `mem::forget`, `ManuallyDrop`, fugas intencionales o rutas de escape en código C2;
- representar un solo terminal mediante `Option::take`, estado equivalente o consumo por valor;
- liberar exactamente una vez en éxito, error, rechazo posterior, cancelación, unwind y drop.

No se aceptará `unsafe` para implementar el ciclo de vida.

### C2-I04 — Ordering observable

Si existe un contador activo separado del semáforo, cada terminal seguirá este orden:

1. marcar internamente el terminal para impedir reentrada;
2. decrementar el contador activo;
3. tomar y soltar el `OwnedSemaphorePermit`;
4. publicar el contador terminal con `Ordering::Release`.

Los snapshots cargarán primero los contadores terminales con `Ordering::Acquire` antes de leer activo/capacidad. Debe quedar demostrado que observar un terminal implica observar tanto el activo decrementado como la capacidad recuperada, y que un nuevo admitido no puede coexistir con un gauge activo obsoleto de la sesión anterior.

Se preferirá derivar el activo desde el ownership del semáforo o desde atómicos internos, sin depender del backend global de métricas.

### C2-I05 — Panic, cancelación y drop

El guard no realizará await, callback, logging, métricas externas, cierre complejo ni trabajo asignable en `Drop`. Debe liberar mediante operaciones locales y no panicar.

La revisión cubrirá:

- error inmediato después de adquirir;
- error durante setup y durante sesión;
- future creado pero nunca polleado;
- cancelación en cada await relevante;
- abort/drop del future de sesión y de `Relay`;
- panic/unwind capturable en tests;
- carrera entre terminación natural y shutdown forzado.

No se afirmará seguridad ante `panic=abort`, `process::abort`, OOM o bloqueo permanente del executor.

### C2-I06 — Configuración extrema sin panic

Todos los constructores públicos bounded validarán antes de `Semaphore::new`:

- cero, timeout cero y valores incompatibles con el contrato;
- `MAX` aceptable si cabe en el tipo y en la primitiva subyacente;
- `MAX+1` o cualquier conversión desbordada como error tipado, nunca clamp, wrap ni panic.

La validación será idéntica en todos los caminos públicos. No habrá constructor alternativo que omita la validación.

### C2-I07 — Shutdown con un único deadline monotónico

La API bounded calculará un solo `tokio::time::Instant` al iniciar shutdown. Después:

1. dejará de aceptar/reencolar nuevas conexiones;
2. cancelará cooperativamente las sesiones/tareas bajo ownership;
3. drenará hasta el deadline restante, sin crear deadlines sucesivos;
4. forzará el drop local de los handles restantes bajo el mismo presupuesto;
5. retornará con permisos y gauges C2 inbound en cero.

No se aceptarán timeouts por tarea, resets del plazo, sleeps, awaits no acotados después del timeout ni nuevas tareas detached. Si la API se denomina shutdown del relay completo, el runner y trabajo outbound propiedad del relay también deberán quedar supervisados y drenados bajo ese mismo deadline; de lo contrario, el alcance deberá ser explícitamente inbound y no satisfará el gate de shutdown global de ADR-0007.

El contrato será cooperativo respecto al runtime. No prometerá límite de pared ante callbacks o destructores externos que bloqueen el executor.

### C2-I08 — Observabilidad agregada y redactada

El snapshot mínimo podrá exponer sólo contadores agregados de baja cardinalidad, por ejemplo activo, admitido, overload y terminales por una enumeración cerrada. No incluirá:

- IP, puerto, CID, SNI, path o endpoint derivado del peer;
- certificado, DER/PEM, subject, SAN, serial, fingerprint o identidad;
- principal, rol, scope, namespace, track, URL o payload;
- error, Display/Debug o razón controlada por el peer;
- ocupación exacta en el código/razón de cierre.

Admisión, terminal y `Drop` no llamarán a `metrics!`, tracing, mlog ni recorder/callback externo. La exportación, si existe, leerá un snapshot atómico fuera del camino crítico.

### C2-I09 — Independencia entre capacidad e identidad

El resultado de admisión dependerá únicamente de capacidad global y estado de shutdown. Será idéntico para raw QUIC y WebTransport y no leerá IP, CID, SNI, path, certificado, handshake metadata, scope, namespace, rol ni resultado de autorización.

El permit no se propagará como principal, rol, relay-peer, evidencia mTLS ni autorización. La aceptación por capacidad no adelanta ni omite ninguna autenticación/autorización futura.

### C2-I10 — API bounded fail-closed y legacy separado

La API bounded será aditiva y nombrada/configurada de forma que un error de configuración no pueda caer a legacy. Una solicitud bounded inválida fallará al construir o arrancar, sin usar un default unbounded.

El API legacy podrá conservar compatibilidad source y comportamiento, pero deberá estar claramente separado y no será evidencia del límite. No habrá fallback silencioso de bounded a legacy ni constructor ambiguo cuyo default cambie el modelo de seguridad.

### C2-I11 — Alcance upstream mínimo

El delta C2 permanecerá exclusivamente en `moq-relay-ietf`. No añadirá dependencias runtime, features, `unsafe`, cambios de lockfile, wire/draft/ALPN, TLS/mTLS, segundo transporte, `Objects` ni política específica de Teremoq.

### C2-I12 — Outbound delimitado honestamente

`--announce`, `RemoteManager`, pulls, fanout y forwarding outbound no consumirán permisos inbound y no podrán bloquear la admisión N+1. Las métricas inbound tampoco los contarán.

Separar la capacidad no autoriza a omitir el lifecycle outbound de una afirmación de shutdown del relay completo. La revisión final comprobará supervisión y join/cancelación reales o exigirá que la API y documentación declaren el alcance residual. Un `RemoteManager::shutdown` que sólo cancele o limpie mapas sin esperar las tareas no prueba gauge cero ni shutdown global.

## Matriz de pruebas de revisión

Las pruebas deberán usar barreras, channels, hooks internos test-only o tiempo pausado. No se aceptarán sleeps como sincronización, contadores producidos exclusivamente por el mismo branch bajo prueba ni asserts que impriman material sensible.

| ID | Prueba exigida | Evidencia independiente esperada |
|---|---|---|
| C2-T01 | Construcción con 0, 1, `MAX` y `MAX+1` | Error tipado antes del semáforo; `catch_unwind` confirma ausencia de panic |
| C2-T02 | N sesiones bloqueadas y N+1 por un endpoint | Exactamente N alcanzan la barrera post-admisión; N+1 recibe cierre constante sin espera |
| C2-T03 | N distribuidas entre raw/WebTransport o varios endpoints y N+1 | El total global, no cada endpoint, es N |
| C2-T04 | Carrera de muchos contenders | Nunca más de N post-admisión; suma de admitidos y overload coincide con intentos |
| C2-T05 | Cliente N+1 esperando SERVER_SETUP | Cierre antes de SERVER_SETUP; el future cliente estaba realmente bloqueado en setup |
| C2-T06 | Efectos previos al gate | Probes independientes muestran cero tagger/coordinator, cero estado `Locals`, cero mlog, cero task/session handles y cero mutaciones namespace |
| C2-T07 | Cierre overload en raw y WebTransport | Mismo código/razón constante, sin campos del peer ni ocupación |
| C2-T08 | Liberación normal y error de setup | Reacquire inmediato; activo vuelve a cero; terminal exacto una vez |
| C2-T09 | Error de scope/coordinator y error de ejecución | Reacquire y terminal exacto; sin doble decremento |
| C2-T10 | Cancel/drop antes y después del primer poll | Capacidad recuperada en ambos casos, sin task detached |
| C2-T11 | Panic/unwind alrededor del guard | El permit se recupera; `Drop` no panica ni llama código arbitrario |
| C2-T12 | Carrera natural vs cancel/shutdown | Un terminal total por sesión y capacidad íntegra |
| C2-T13 | Ordering cross-thread | Una lectura Acquire que observa terminal ve activo cero y permiso disponible; reacquire no ve estado obsoleto |
| C2-T14 | Variar IP/SNI/path/certificado/endpoint | Decisión de capacidad idéntica; ninguna señal se consulta en admisión |
| C2-T15 | Shutdown cooperativo con tiempo pausado | Se deja de aceptar, se drena antes del único deadline y todos los gauges inbound son cero al retorno |
| C2-T16 | Sesión no cooperativa | Se alcanza el mismo deadline una vez, se fuerza drop local y no queda await ilimitado |
| C2-T17 | Carreras accept/admit/shutdown | Ninguna sesión admitida tras cerrar admisión; cero permits/gauges al retorno |
| C2-T18 | Recorder de métricas hostil | Estructura demuestra que admisión/terminal/Drop no lo invocan; el snapshot sigue siendo legible |
| C2-T19 | Outbound activo durante saturación inbound | Outbound no consume capacidad ni altera N+1; no se confunde con métricas inbound |
| C2-T20 | Shutdown declarado completo con outbound activo | Todos los futures propiedad del relay son supervisados/drenados bajo el mismo deadline, o la prueba falla |
| C2-T21 | Composición con C1 | Con C2 saturado no crecen sin límite los handshakes pendientes; al retorno bounded el gauge C1 aplicable es cero |
| C2-T22 | API legacy vs bounded | Legacy conserva source compatibility; bounded inválido/saturado nunca hace fallback legacy |
| C2-T23 | Regresión raw/WebTransport | Sesiones admitidas conservan el flujo baseline; overload no inicia MoQT en ninguno |
| C2-T24 | Redacción | Captura de logs, tracing, métricas, Debug/Display y cierres no contiene los datos prohibidos |
| C2-T25 | Superficie upstream | Diff confirma sólo `moq-relay-ietf`, sin dependencia/feature/lock/wire/TLS/unsafe |

## Método de revisión del snapshot final

### Inspección estática

1. Fijar y volver a comprobar HEAD/tree, branch sin tracking, stage, status y SHA-256 de cada ruta al inicio y al final.
2. Comparar el diff completo contra `ee22a1079783e374371e0705775978790ddd6471` y verificar el allowlist de rutas.
3. Trazar por línea cada constructor bounded, accept, adquisición, rechazo, spawn/inserción, terminal, cancelación, drop y retorno de shutdown.
4. Buscar `acquire`, `available_permits`, `try_acquire_owned`, `Semaphore::new`, `Clone`, `Arc`, `forget`, `ManuallyDrop`, `add_permits`, `spawn`, `timeout`, `sleep`, `Instant`, metrics, tracing, mlog, `unsafe` y nuevos `Display/Debug`.
5. Auditar que las pruebas observan efectos independientes y no los contadores internos que pretenden validar.
6. Confirmar que manifests, lockfile, wire, TLS, draft, ALPN y `Objects` no cambian.

### Gates focalizados futuros

Se ejecutarán únicamente sobre el snapshot final y con las imágenes/versiones fijadas por el inventario del proyecto:

```text
git status --short --branch
git diff --cached --check
git diff --check ee22a1079783e374371e0705775978790ddd6471 --
git diff --name-only ee22a1079783e374371e0705775978790ddd6471 --
sha256sum <cada ruta C2 y cada informe vinculante>

cargo test -p moq-relay-ietf --all-targets
cargo test -p moq-relay-ietf c2_
cargo clippy -p moq-relay-ietf --all-targets -- -D warnings
cargo fmt --all -- --check
cargo check -p moq-relay-ietf --all-targets
```

Rust se ejecutará con 1.93.0 por digest fijado, sin instalación global ni cambio de dependencias. REUSE y Gitleaks usarán también las imágenes/digests aprobados. Los comandos exactos, digests, exit codes y cualquier limitación de recursos se registrarán en el dictamen.

El E0308 heredado de `moq-transport` identificado como WR-03 seguirá siendo un bloqueo baseline explícito: no se marcará como gate superado ni se atribuirá a C2 sin evidencia. Un gate focal de relay que pase no ocultará fallos workspace.

No se harán fetch, commit, push, publicación, cambio de refs, actualización de dependencias ni ejecución contra servicios remotos.

## Criterios del dictamen futuro

### `APPROVE FOR LOCAL COMMIT`

Sólo se emitirá si, sobre un snapshot estable:

- todas las invariantes C2-I01 a C2-I12 quedan demostradas por source y pruebas;
- todas las pruebas aplicables C2-T01 a C2-T25 pasan y prueban efectos reales;
- el delta queda limitado a `moq-relay-ietf` y no altera manifests/lock/dependencias/wire/TLS salvo una excepción previamente aprobada y documentada;
- no existen findings HIGH o MEDIUM abiertos;
- los bloqueos baseline y límites de composición C1/I2/outbound se declaran sin sobreafirmar garantías;
- diff checks, redacción, REUSE y Gitleaks focales no presentan fallos atribuibles al delta.

Ese veredicto sólo autorizará al Master a considerar un commit local de C2. No autorizará C3, push, publicación, release OSS ni uso productivo.

### `CHANGES REQUIRED`

Se emitirá si aparece cualquiera de estas condiciones:

- waiter, retry o check-then-act en admisión; capacidad separada por endpoint;
- decisión después de setup, task, coordinator, namespace, mlog o cualquier efecto prohibido;
- código/razón de overload dinámico o fuga de datos sensibles;
- guard clonable, escapable, retenido, olvidable o con liberación doble/ausente;
- callback, await, cola, task, logging o backend de métricas en admisión, terminal o `Drop`;
- ordering insuficiente o imposibilidad de demostrar que terminal implica capacidad recuperada;
- panic, wrap, clamp o fallback legacy en límites extremos;
- más de un deadline, reinicio de timeout, accepts tras shutdown o gauges/permits inbound vivos al retorno;
- capacidad dependiente de identidad, IP, SNI, path, certificado, scope o autorización;
- claim de shutdown global sin supervisión/drain del outbound propiedad del relay;
- breaking API no justificada, dependencia/feature runtime, cambio de lock/wire/TLS/draft/ALPN/`Objects` o `unsafe`;
- tests con sleeps, oráculos circulares, fixtures sensibles, asserts que vuelquen datos o cobertura que no demuestre ordering/efectos;
- snapshot inestable o imposibilidad de reproducir los gates focalizados.

## Limitaciones residuales que deberán constar en cualquier aprobación

- C2 comienza después del handshake; C1 sigue siendo obligatorio.
- C2 es capacidad, no autenticación ni autorización. La composición con I2/mTLS sigue separada.
- El baseline legacy aún permite clasificación por IP/SNI/path; C2 no la legitima ni la amplía.
- Un deadline Tokio es cooperativo y no garantiza pared dura si el executor o un destructor externo se bloquea.
- La cuota inbound no limita outbound; la garantía de shutdown dependerá del alcance y supervisión reales de la API final.
- Los límites del relay no sustituyen cgroups, límites de Docker/systemd, rate limiting de red ni observabilidad del host.

## Declaración final del plan

Este documento define el método y los gates de una revisión futura. No revisa todavía un snapshot C2 y no emite `APPROVE FOR LOCAL COMMIT` ni `CHANGES REQUIRED` sobre código inexistente.

Confirmación: `READ-ONLY SECURITY REVIEW PLAN / NO COMMIT / NO PUSH / NO PUBLICATION / NO REMOTE MUTATION`.
