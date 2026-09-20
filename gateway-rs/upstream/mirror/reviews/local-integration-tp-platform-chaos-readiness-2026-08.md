<!-- SPDX-License-Identifier: Apache-2.0 -->

# TP-PLATFORM-CHAOS — readiness de integración local posterior a C2

Fecha de revisión: 2026-08-28

Alcance: plan y puerta local reversible; no es aprobación de C2, integración,
pin de producto ni publicación.

## Hallazgos, por severidad

### [BLOCKER] INT-R01 — todavía no existe una entrada C2 inmutable admisible

La integración sólo puede consumir un commit C2 completo cuya revisión local,
de seguridad, de compatibilidad y de concurrencia esté cerrada. Este informe no
usa el source mutable de C2 como evidencia, no conoce su SHA final y no emite un
veredicto C2. Mientras `C2_SHA` no designe un objeto local inmutable cuyo único
parent sea C1, la creación de la rama integrada y cualquier cambio del pin de
producto quedan `BLOCKED`.

### [HIGH] INT-R02 — Q/U1 no aseguran el grafo del consumidor `gateway-rs`

Q y U1 modifican únicamente el `Cargo.lock` del workspace derivado. Ese lock no
gobierna la resolución de crates cuando `gateway-rs` consume los tres crates
como dependencias Git. El lock de producto debe auditarse de forma independiente
después del pin. En el estado leído, `gateway-rs/Cargo.lock` resuelve `bytes
1.12.1` y `quinn-proto 0.11.17`, mientras Q/U1 fijan para las pruebas del
workspace derivado `bytes 1.11.1` y `quinn-proto 0.11.15`. Esto no es una
regresión ni una decisión T: prueba que no se puede inferir el grafo consumidor
desde el lock del proveedor.

### [HIGH] INT-R03 — I1 y C1 colisionan realmente en el seam QUIC

I1 y C1 modifican `moq-native-ietf/src/quic.rs`. El `merge-tree` de los commits
cerrados produce cuatro regiones con conflicto. La resolución debe conservar a
la vez evidencia de identidad opt-in, redacción, admisión posterior a
`quinn::Incoming`, deadline absoluto, RAII y compatibilidad raw/WebTransport.
Está prohibido resolver el fichero completo con `ours` o `theirs`. La resolución
es source nuevo de integración y necesita diff y revisión propios.

### [HIGH] INT-R04 — la integración completa sigue expuesta al E0308 heredado

El baseline, I2 y C1 conservan sin cambios
`moq-transport/src/serve/tracks.rs`, SHA-256
`a8303c94925707a0a257923725bf84e4ec730b07d6bb2330fda5329b632fe0b7`.
El fallo conocido está en la línea 501 y debe clasificarse únicamente como
`BLOCKED_BY_BASELINE_E0308` cuando coincidan fichero, hash, código y diagnóstico.
No cuenta como PASS. Cualquier segundo diagnóstico, cambio del fichero/hash o
aparición del error en una ruta modificada por la integración es `FAIL`.
Mientras este bloqueo impida la matriz completa de los tres crates y Objects,
el pin de producto permanece `BLOCKED`, aunque se permita ensamblar localmente
una rama para obtener evidencia.

### [MEDIUM] INT-R05 — I2 y Q/U1 comparten lock, no decisión de dependencia

I2, Q y U1 tocan `Cargo.lock`, pero los hunks cerrados son independientes:

- I2 conserva 336 paquetes y añade `rustls 0.23.31` a las dependencias del
  registro local de `moq-relay-ietf`;
- Q conserva 336 paquetes y cambia sólo `quinn-proto 0.11.13` por `0.11.15`,
  incluido su checksum;
- U1 es hijo de Q, conserva 336 paquetes y cambia sólo `bytes 1.6.0` por
  `1.11.1`, incluido su checksum.

`git merge-tree` no produce marcadores para I2+U1, pero la ausencia de conflicto
textual no valida el grafo. El lock integrado debe satisfacer simultáneamente
esas tres invariantes, sin `cargo update` amplio, sin regeneración online y sin
adoptar o descartar ninguna decisión del lote T.

### [MEDIUM] INT-R06 — el pin local no equivale a disponibilidad reproducible

Un SHA sólo local no puede resolver desde la URL Git pública en una build limpia.
Antes de editar el pin, el Master debe elegir una de dos rutas separadas:

1. prueba local con reemplazo de URL hacia un mirror efímero, fuera de los
   manifests y sin persistir `file://` ni paths privados; o
2. publicación posteriormente autorizada y verificada, fuera del alcance de
   este plan.

Un pin que sólo funciona por objetos residuales en `CARGO_HOME` es `FAIL`. Este
informe no autoriza publicar ni cambiar remotos.

## Evidencia vinculante leída

### Política y diseño

- `.cursorrules`, completa, incluida la autonomía local y la prohibición de
  mutaciones remotas no autorizadas.
- `gateway-rs/ADR-0007-CONTROLLED-MOQ-MIRROR.md`.
- `gateway-rs/upstream/mirror/PATCH-SERIES.md`.
- `gateway-rs/upstream/mirror/SYNC-RUNBOOK.md`, usado sólo para confirmar la
  separación entre integración, pin y publicación.

### Informes finales cerrados

| Lote | Informe owner | Revisiones vinculantes | SHA-256 del fichero leído |
|---|---|---|---|
| I1 | `i1-local-review-2026-08.md` | SEC y OSS/SC | owner `a49ff41ea6836d005884ddb900d31060f718357fdbe2c7bd563c799bb260e8a1`; SEC `142860f7cdc408095e806acbf41bd2e32b2137307f44425d6e25e6ab8b1583ee`; OSS `6b0f1aaa0606eae264997907d31b0d442a4275f99f0d7550570a3895c65bacc3` |
| I2 | `i2-local-review-2026-08.md` | SEC-third y OSS-final | owner `e3477a01f2669efe868a1b6facb12205c7d8b32e9ec73946c5bb114ca8cb4f07`; SEC `73170aa2a26d048067acdd189e09fec590e226e7e5c1432569d9439873ac0a61`; OSS `1d0e80b5d1128989eb6413cb07fe932a835bc19d800ed262be4122fa6d27aecb` |
| C1 | `c1-local-rereview-2026-08.md` | CHAOS-final, SEC-final y OSS-rereview | owner `a7cca70bc0d926739ca109cacdef1648e200255ad9c82cb33e2b521e0d2b7626`; CHAOS `78d1c3da31b0f3f46482c56e89d62842ffcc04b933aec522fc3e55aa52f04af5`; SEC `d613817d9ea2da9b7698caf8b934512515c3a6ca0ca76d77d8d2faa223d12d1e`; OSS `90bf9725e4e8f4eaf4e0c0829136e285be42d63e86b9f834513da9027b129544` |
| Q | `rustsec-q-local-review-2026-08.md` | OSS/SC | owner `24ae0d3d537df1b4aa70a13c0afcdee22af9162d64dba877c7b96a362e9c1033`; OSS `bc3f3d9f020b1da7116510843e1de330331140e0affde164ac6b69cf6ecc702c` |
| U1 | `rustsec-u1-local-review-2026-08.md` | OSS/SC | owner `358a31f643e93f9efb9eca29624c9ee6a4931e56264d29ee519824cd1ff2c8fb`; OSS `48c053d703d4f07b4ce1bf52f5e4bcd2745812d613433d43bd1bc5d80b681ede` |

Los informes Q/U1 y algunos informes de autor describen el snapshot previo al
commit. Por ello, parentage, tree y alcance se verificaron directamente contra
los objetos Git cerrados; no se infirieron sólo del texto.

No se leyó ni se usó el source C2 mutable como evidencia de integración.

## Inventario de commits y DAG cerrado

| Lote | Commit | Tree | Parent exacto | Alcance relevante |
|---|---|---|---|---|
| baseline | `bf87128affd316463e5dcc7599a45001f222b6de` | `d76319009e815fb8923e21fc8319e17a0aaf8174` | baseline oficial | draft-16 fijado |
| I1 | `05b41127ecbd48de4c59fe1626c43b1e423c33a9` | `eca64a72e148482fb82b963edc2f2c9af28803f2` | baseline | identidad verificada, 17 rutas native |
| I2 | `59d9a8601885ef934cae29d89876abb7c7f73e89` | `d108208bfb5792767881a932480da01769844148` | I1 | autorización, pending accept, relay, manifest/lock; 22 rutas |
| C1 | `ee22a1079783e374371e0705775978790ddd6471` | `232e449945e877b024f2fc4223f0d2eea124b39b` | baseline | handshakes pendientes acotados; 10 rutas |
| Q | `1e9d1ee62bde97145a0914e5992ab7f54fc909c4` | `4cf25aeea2eacd02394608c80c9677eaa001ef87` | baseline | sólo `Cargo.lock`, `quinn-proto` |
| U1 | `4547800088881cb4782c544ebfec0a1904ed1fab` | `cc9b037c81ace8a9490693a6ccb1c294cd0e3886` | Q | sólo `Cargo.lock`, `bytes` |

Todos los commits anteriores existen en el object store local y sus commits
incluyen `Signed-off-by` consistente. El DAG futuro obligatorio es:

```text
                         I1 ── I2 ───────────────┐
                        /                         │ parent 1
baseline bf87128 ──────┼── C1 ── C2 aprobado ───┼── M_API ──┐
                        \                         │ parent 2   │ parent 1
                         Q ── U1 ─────────────────────────────┼── M_LOCK
                                                            │ parent 2
```

`M_API` y `M_LOCK` son commits de merge locales nuevos, no commits ya
aprobados. Sus resoluciones requieren revisión antes de que se consideren
inmutables. El resultado final debe contener como ancestros I1, I2, C1, el C2
aprobado, Q y U1. No se permite rebase, cherry-pick que duplique identidades,
`commit --amend` después de congelar evidencia ni force push.

## Secuencia exacta de ensamblado futuro

### 1. Cerrar entradas sin tocar ramas

Ejecutar en un checkout local limpio creado expresamente por el Master. No usar
ningún worktree de autor y no hacer fetch:

```bash
set -Eeuo pipefail
BASE=bf87128affd316463e5dcc7599a45001f222b6de
I1=05b41127ecbd48de4c59fe1626c43b1e423c33a9
I2=59d9a8601885ef934cae29d89876abb7c7f73e89
C1=ee22a1079783e374371e0705775978790ddd6471
Q=1e9d1ee62bde97145a0914e5992ab7f54fc909c4
U1=4547800088881cb4782c544ebfec0a1904ed1fab
: "${C2_SHA:?C2_SHA must be the fully reviewed immutable C2 commit}"

for rev in "$BASE" "$I1" "$I2" "$C1" "$C2_SHA" "$Q" "$U1"; do
  git cat-file -e "${rev}^{commit}"
  test "$(git rev-parse "${rev}^{commit}")" = "$rev"
done
test "$(git show -s --format=%P "$I1")" = "$BASE"
test "$(git show -s --format=%P "$I2")" = "$I1"
test "$(git show -s --format=%P "$C1")" = "$BASE"
test "$(git show -s --format=%P "$C2_SHA")" = "$C1"
test "$(git show -s --format=%P "$Q")" = "$BASE"
test "$(git show -s --format=%P "$U1")" = "$Q"
test -z "$(git status --porcelain=v1 --untracked-files=all)"
```

Además, comparar el SHA del informe final owner/review C2 autorizado con el
valor aprobado por el Master. Que el objeto sea hijo de C1 es necesario, pero
no suficiente.

### 2. Crear la rama local desde I2

Sólo tras cerrar el paso anterior:

```bash
git switch --detach "$I2"
git switch -c teremoq/integration-draft16-bf87128-local
```

Empezar en I2 conserva linealmente I1→I2. El nombre es local y no se publica.

### 3. Integrar C2 conservando C1

```bash
git merge --no-ff --no-commit "$C2_SHA"
```

Resolver el conflicto de `moq-native-ietf/src/quic.rs` por semántica y línea,
conservando ambas APIs y un único camino de `Incoming`. Revisar también cualquier
solapamiento I2/C2 de relay, lifecycle o exports. No usar `checkout --ours`,
`checkout --theirs` ni aceptar un fichero completo generado por una sola rama.
Capturar antes de editar la lista exacta de conflictos:

```bash
mapfile -d '' CONFLICT_PATHS < <(git diff --name-only -z --diff-filter=U)
test "${#CONFLICT_PATHS[@]}" -gt 0
printf '%s\n' "${CONFLICT_PATHS[@]}"
```

Antes de crear `M_API`:

```bash
git diff --check
git diff --cached --check
git diff --name-status "$I2"
git diff --name-status "$C2_SHA"
git diff -- moq-native-ietf/src/quic.rs
rg -n '^(<<<<<<<|=======|>>>>>>>)' .
```

Después de revisión humana focal de las resoluciones:

```bash
git add -- "${CONFLICT_PATHS[@]}"
test -z "$(git diff --name-only --diff-filter=U)"
git commit -s -m 'merge: integrate reviewed identity and admission series'
M_API=$(git rev-parse HEAD)
test "$(git show -s --format=%P "$M_API")" = "$I2 $C2_SHA"
```

No se permite `git add -A`. Se registra `M_API`, tree, paths y diff.

### 4. Integrar U1, que ya contiene Q

```bash
git merge --no-ff --no-commit "$U1"
```

Si Git combina el lock automáticamente, aun así se aplica el gate semántico de
la sección siguiente. Si hubiera conflicto, la reconstrucción mecánica es:

1. tomar exactamente `Cargo.lock` de I2/M_API;
2. aplicar únicamente el patch `BASE..Q` de `Cargo.lock`;
3. aplicar únicamente el patch `Q..U1` de `Cargo.lock`;
4. conservar el edge I2 `rustls 0.23.31` de `moq-relay-ietf`;
5. rechazar todo cambio adicional.

No ejecutar `cargo update`, no elegir el lock completo de un lado y no editar
versiones a mano. Después:

```bash
git diff --check
git diff -- Cargo.lock
git add -- Cargo.lock
git commit -s -m 'merge: compose reviewed lock-only remediations'
M_LOCK=$(git rev-parse HEAD)
test "$(git show -s --format=%P "$M_LOCK")" = "$M_API $U1"
```

### 5. Probar ancestry, alcance y ausencia de material ajeno

```bash
for rev in "$I1" "$I2" "$C1" "$C2_SHA" "$Q" "$U1"; do
  git merge-base --is-ancestor "$rev" "$M_LOCK"
done
test -z "$(git status --porcelain=v1 --untracked-files=all)"
git log --graph --decorate --oneline --parents "$BASE..$M_LOCK"
git diff --name-status "$BASE..$M_LOCK"
git diff --submodule=log "$BASE..$M_LOCK"
git diff --check "$BASE..$M_LOCK"
```

El inventario permitido es la unión de paths de los seis lotes más las rutas
que contengan resolución real de conflictos. Workflow, release, CI, wire draft,
ALPN, Object encoding, licencias y remotos fuera de esa unión producen `FAIL`.

## Gate determinista de `Cargo.lock`

Ejecutar con Python estándar (`tomllib`), sin instalar paquetes. El comparador
debe cargar los locks de I2, Q, U1 y `M_LOCK` y exigir:

| Propiedad | Valor exigido |
|---|---|
| paquetes integrados | 336 |
| `moq-relay-ietf` deps | contiene exactamente el edge nuevo `rustls 0.23.31` respecto del baseline |
| `quinn-proto` | `0.11.15`, checksum `4fcb935c5bec503c2f0e306bdd3e58bb9029dcb14fa8d9ac76e3a5256ac0763e` |
| `bytes` | `1.11.1`, checksum `1e748733b7cbc798e1434b6ac524f0c1ff2ab456fe201501e6497c8417a4fc33` |
| resto del multiset de paquetes | idéntico a I2 |
| sources Git | sin branch/tag flotante; sólo commits completos autorizados |

Luego, con Cargo 1.93.0 y cache ya poblada:

```bash
timeout --signal=TERM --kill-after=30s 300s \
  cargo metadata --locked --offline --format-version 1 --no-deps
timeout --signal=TERM --kill-after=30s 300s \
  cargo tree --locked --offline -i quinn-proto@0.11.15
timeout --signal=TERM --kill-after=30s 300s \
  cargo tree --locked --offline -i bytes@1.11.1
```

Cache ausente es `BLOCKED_OFFLINE_CACHE`, no licencia para descargar. Cambio de
cualquier paquete adicional es `FAIL` y vuelve al owner de supply chain; este
gate no decide T.

## Orden integrado que debe probarse

La resolución de source debe conservar este orden lógico, sin afirmar que C2
ya lo implementa:

```text
Endpoint::accept().await -> Incoming
  -> C1 try-acquire no bloqueante
     -> refuse/retry inmediato si N+1
     -> un único futuro QUIC/TLS/WebTransport bajo deadline absoluto si admite
        -> I1 extrae evidencia verificada/redactada o ausencia tipada
        -> C1 libera el permit de handshake al terminar transporte
        -> C2 intenta capacidad de sesión establecida, sin waiter queue
           -> I2 lee CLIENT_SETUP pendiente y autoriza antes de SERVER_SETUP,
              namespace, Producer, Consumer, coordinator o task de sesión
           -> run de sesión
```

La prueba combinada debe demostrar cada borde. En particular, el límite C1 no
puede mantenerse durante la vida MoQT, C2 no puede adquirir antes del transporte
establecido, e I2 no puede crear estado MoQT antes de autorización. Un N+1 en C1
y un N+1 en C2 son rechazos distintos y observables con motivos de baja
cardinalidad.

## Entorno y watchdog único por comando

Usar Rust/Cargo/rustfmt/Clippy 1.93.0 exactos, `cargo-deny 0.20.2` y
`cargo-audit 0.22.2`, modo `--locked --offline` y la imagen ya inventariada
`teremoq-step7-lab:rust-1.93-full@sha256:ba076cf0a26aa41efdd2f0f80687ef97009d1526680751456c19cc944dff1d0b`.
El runner debe:

- montar source read-only para gates que no generan fixtures;
- usar sólo el cache pre-poblado ligado al digest dentro de la imagen y un
  `CARGO_TARGET_DIR` externo exclusivo; no montar el `CARGO_HOME` del host;
- ejecutar `--network none` cuando se use contenedor;
- limitar a un build/test pesado a la vez;
- envolver cada proceso en un watchdog externo `timeout` y conservar el código;
- mantener dentro de cada test async un único `tokio::time::timeout_at` absoluto
  por espera lógica; nunca sleeps como sincronización;
- imprimir `rustc -Vv`, `cargo -V`, `rustfmt -V`, `cargo clippy -V`, digest de
  imagen, commit/tree, CPU/memoria y límites realmente aplicados;
- instalar nada y no crear imágenes nuevas durante el gate.

Plantilla de ejecución futura:

```bash
set -Eeuo pipefail
RUST_IMAGE_DIGEST=teremoq-step7-lab:rust-1.93-full@sha256:ba076cf0a26aa41efdd2f0f80687ef97009d1526680751456c19cc944dff1d0b
docker image inspect "$RUST_IMAGE_DIGEST" >/dev/null
RUN_ROOT=$(mktemp -d /tmp/teremoq-integration.XXXXXX)
RUN_CONTAINER="teremoq-integration-$RANDOM-$$"
mkdir -p -- "$RUN_ROOT/target"
cleanup() {
  rc=$?
  trap - EXIT INT TERM HUP
  docker rm -f "$RUN_CONTAINER" >/dev/null 2>&1 || true
  if docker inspect "$RUN_CONTAINER" >/dev/null 2>&1; then
    rc=1
  fi
  case "$RUN_ROOT" in
    /tmp/teremoq-integration.*) rm -rf -- "$RUN_ROOT" ;;
    *) rc=1 ;;
  esac
  exit "$rc"
}
trap cleanup EXIT INT TERM HUP

timeout --signal=TERM --kill-after=30s 1800s docker run --rm \
  --name "$RUN_CONTAINER" --network none --workdir /src \
  --mount type=bind,src="$PWD",dst=/src,readonly \
  --mount type=bind,src="$RUN_ROOT/target",dst=/target \
  --env CARGO_NET_OFFLINE=true --env CARGO_TARGET_DIR=/target \
  "$RUST_IMAGE_DIGEST" \
  cargo test --locked --offline -p moq-native-ietf
```

La referencia incluye digest y no es un tag flotante. Antes de usarla se
verifican dentro del contenedor las cinco versiones declaradas. El cleanup debe
verificar que el contenedor no existe y
que no quedan procesos, redes, qdisc ni target temporal; el cache interno se
elimina con el contenedor. Timeout,
señal o cleanup incompleto son `FAIL`, no `BLOCKED`.

## Matriz futura por fase

Todos los waits dentro de los tests deben estar bajo watchdog absoluto. Cada
fila registra comando, exit code, duración, tests pass/fail/ignored, timeout y
estado de cleanup. Los filtros primero deben enumerarse con `-- --list`; cero
tests seleccionados es `FAIL`.

Los comandos focales ya cerrados se repiten exactamente en la integración:

```bash
timeout --signal=TERM --kill-after=30s 900s cargo test --locked --offline -p moq-native-ietf --test peer_evidence
timeout --signal=TERM --kill-after=30s 1200s cargo test --locked --offline -p moq-native-ietf c1_
timeout --signal=TERM --kill-after=30s 900s cargo test --locked --offline -p moq-transport --test pending_accept
timeout --signal=TERM --kill-after=30s 1800s cargo test --locked --offline -p moq-relay-ietf
```

Los nombres focales C2 proceden exclusivamente del informe final aprobado de
C2. Se enumeran y se comparan con ese inventario antes de ejecutarlos; este plan
no los deduce del worktree mutable.

| Fase | Prueba focal | Evidencia exigida | Resultado admisible |
|---|---|---|---|
| estructura | ancestry, trees, path union, diff/check y marcadores | dos merge commits con parents exactos; seis lotes ancestros | PASS/FAIL |
| I1 native raw | tests `peer_evidence` raw QUIC reales | presente/ausente, cadena verificada, redacción y concurrencia | PASS/FAIL |
| I1 native WT | tests `peer_evidence` WebTransport reales | misma identidad sobre H3/CONNECT, sin derivación por IP/SNI/path | PASS/FAIL |
| C1 focal | enumerar y ejecutar todos los tests C1 | N/N+1, refuse/retry legal, deadline, cancel/drop, endpoints local/compartido, gauge cero | PASS/FAIL |
| composición I1+C1 | tests nuevos de resolución | `Incoming -> permit -> único future -> evidencia`; sin bypass ni doble accept | PASS/FAIL |
| transport pending | `pending_accept` | CLIENT_SETUP retenido sin crear SERVER_SETUP/estado | PASS/FAIL |
| I2 focal | autorización relay | deny/allow exactos, object safety, redacción, cero side effects antes de authorize | PASS/FAIL |
| C2 focal | sólo suite del commit C2 aprobado | N/N+1 global, M=32/MAX/MAX+1, endpoints, Remote/announce, panic/cancel/run error, shutdown | PASS/FAIL; no se anticipa resultado |
| composición I2+C2 | tests nuevos de resolución | slot de sesión antes de setup; deny/error/panic libera exactamente una vez; N+1 no crea estado | PASS/FAIL |
| raw QUIC end-to-end | cliente QUINN upstream real | ALPN existente, draft-16 setup, identidad, límites y cierre | PASS/FAIL |
| WebTransport end-to-end | H3/CONNECT upstream real | mismo contrato, SETTINGS/CONNECT bajo deadline, rechazo wire exacto | PASS/FAIL |
| Objects | publish/subscribe múltiples Objects por subgroup | bytes y orden intactos, sin transcoding, sin primer-Object-only | PASS o `BLOCKED_BY_BASELINE_E0308` exacto |
| shutdown | cierre cooperativo y forzado | un deadline absoluto; accepts detenidos; cancel/drain/drop; gauges cero; cero tasks | PASS/FAIL |
| multi-endpoint | límites local y compartido | aislamiento local y N/N+1 global real, sin waiter queue | PASS/FAIL |
| outbound | announce, RemoteManager, pulls | inventario y límites separados; gap explícito si no está cubierto | PASS/FAIL; gap no habilita claim productivo |
| Q/U1 | lock comparator, cargo metadata/tree, auditoría | sólo versiones/checksums aprobados; sin cambio T | PASS/BLOCKED_OFFLINE_CACHE/FAIL |

### Matriz completa por crate

Ejecutar de forma secuencial, con watchdog por comando:

```bash
timeout --signal=TERM --kill-after=30s 1200s cargo fmt --all -- --check
timeout --signal=TERM --kill-after=30s 1800s cargo check --locked --offline -p moq-native-ietf --all-targets --all-features
timeout --signal=TERM --kill-after=30s 1800s cargo clippy --locked --offline -p moq-native-ietf --all-targets --all-features -- -D warnings
timeout --signal=TERM --kill-after=30s 1800s cargo test --locked --offline -p moq-native-ietf --all-features

timeout --signal=TERM --kill-after=30s 1800s cargo check --locked --offline -p moq-transport --all-targets --all-features
timeout --signal=TERM --kill-after=30s 1800s cargo clippy --locked --offline -p moq-transport --all-targets --all-features -- -D warnings
timeout --signal=TERM --kill-after=30s 1800s cargo test --locked --offline -p moq-transport --all-features

timeout --signal=TERM --kill-after=30s 1800s cargo check --locked --offline -p moq-relay-ietf --all-targets --all-features
timeout --signal=TERM --kill-after=30s 1800s cargo clippy --locked --offline -p moq-relay-ietf --all-targets --all-features -- -D warnings
timeout --signal=TERM --kill-after=30s 1800s cargo test --locked --offline -p moq-relay-ietf --all-features
```

Después, sólo si las focales no producen `FAIL`:

```bash
timeout --signal=TERM --kill-after=30s 2400s cargo check --locked --offline --workspace --all-targets --all-features
timeout --signal=TERM --kill-after=30s 2400s cargo clippy --locked --offline --workspace --all-targets --all-features -- -D warnings
timeout --signal=TERM --kill-after=30s 2400s cargo test --locked --offline --workspace --all-features
```

Si el único impedimento es el E0308 exacto protegido, registrar
`BLOCKED_BY_BASELINE_E0308`, el comando y los tests que no llegaron a ejecutarse.
No omitirlos del denominador ni convertirlos en PASS. Los dos diffs rustfmt
heredados sólo se clasifican como baseline si rutas y contenido coinciden con
la evidencia cerrada; cualquier diff nuevo es `FAIL`.

## Regresiones de protocolo y concurrencia combinada

### Draft-16, ALPN y wire

El gate compara hashes/diffs de las constantes draft/ALPN y tipos de setup con
el baseline. Después usa clientes upstream reales para raw QUIC y
WebTransport; UDP arbitrario no cuenta. Debe observar:

- ALPN existente sin valor nuevo ni fallback;
- CLIENT_SETUP/SERVER_SETUP draft-16 sin cambio de encoding;
- H3 SETTINGS y CONNECT dentro del mismo deadline absoluto del transporte;
- Objects y payloads byte-for-byte, sin adaptación ni transcoding;
- códigos y reasons de rechazo enumerables y de baja cardinalidad.

Un test estático no sustituye la prueba wire, y una prueba wire que no llega a
MoQT no prueba Objects.

### Identidad, autorización y límites

Casos mínimos combinados:

1. C1 saturado rechaza N+1 antes de TLS/WebTransport y antes de I1/I2/C2.
2. Tras liberar C1, un peer válido entrega evidencia I1 y llega a admisión C2.
3. C2 saturado rechaza N+1 después del transporte, pero antes de CLIENT_SETUP
   state, Producer, Consumer, namespace, coordinator y task de sesión.
4. Admitido por C2 pero denegado por I2 libera exactamente un slot C2.
5. Ausencia, CA/EKU/expiración inválidas y autorización negativa siguen siendo
   motivos distintos sin labels de IP, SPIFFE completa o error crudo.
6. Error de setup, run, cancelación, panic/unwind y drop liberan exactamente una
   vez; todos los gauges terminan en cero.
7. Cierre detiene accepts, impide readmisión, cancela, drena y fuerza drop bajo
   un único deadline absoluto no reiniciado.
8. Dos endpoints locales y dos con controlador compartido prueban aislamiento
   y límite global sin tareas/waiter queues en N+1.
9. `announce`, `RemoteManager` y pulls salientes se contabilizan aparte; un gap
   queda visible y prohíbe declarar concurrencia completa/productiva.

Las carreras se coordinan con barriers, notifies o hooks acotados del propio
test. No usar sleeps, callbacks públicos bloqueantes, polling sin watchdog ni
orden basado en velocidad del host.

## Gate de producto `gateway-rs`, posterior y separado

No editar el producto hasta que `M_LOCK` esté congelado y revisado. Para una
prueba puramente local sin publicación, crear un bare mirror efímero desde
objetos locales y una configuración Git/Cargo efímera que reescriba la URL sólo
dentro del proceso. No persistir `file://`, `insteadOf`, credenciales ni paths.
La URL y el rev que quedarían en el producto deben seguir siendo la URL pública
canónica del derivado y el SHA completo de integración; si ese SHA no es
resoluble en un entorno limpio autorizado, el pin no se entrega.

El cambio de producto futuro es atómico y revisable:

- los tres entries Git de `gateway-rs/Cargo.toml` apuntan a la misma URL y al
  mismo SHA completo `M_LOCK`;
- `gateway-rs/Cargo.lock` resuelve los tres crates al mismo SHA;
- `gateway-rs/deny.toml` permite exactamente la URL canónica consumida y deja
  de permitir la anterior sólo cuando ninguna dependencia la usa;
- documentación de dependencias registra commit, tree, licencia, rollback y
  que Q/U1 no controlan el lock consumidor;
- no se cambian features, versiones declaradas ni otras dependencias como parte
  de esta integración.

Validaciones de producto, todas con Rust 1.93.0, `--locked --offline` y
watchdog:

```bash
cargo fmt --check
cargo check --locked --offline --all-targets --all-features
cargo clippy --locked --offline --all-targets --all-features -- -D warnings
cargo test --locked --offline --all-targets --all-features
cargo deny check
cargo audit --no-fetch
```

Más los tests producto focales:

- `mtls_quic`, `moq_relay_interop` y `federation_concurrency`;
- raw QUIC y WebTransport draft-16;
- autorización/identidad negativa y positiva sin claim SPIFFE completo;
- publisher único, backoff/jitter/presupuesto de reconexión;
- scheduler/Object Dropping unitario y reader multi-Object, separando el gap
  multitrack de transporte;
- smoke tres veces y hostile corto sólo en bridge aislada, con cleanup y reporte
  aun en fallo.

La red Docker de Chaos sigue siendo defensa/test adicional y no demuestra por
sí sola límites lógicos. Un hostile fallido permanece `FAIL` o blocker de
producto; no se reducen umbrales.

## Clasificación binaria

### PASS

Una fila es PASS sólo si:

- usa exactamente el commit/tree congelado;
- selecciona al menos un test cuando corresponda;
- termina dentro del watchdog con exit code esperado cero;
- satisface sus assertions de orden, counters, gauges y side effects;
- no cambia el source/lock durante el gate;
- deja cero procesos, contenedores, redes, qdisc, caches y temporales propios.

La puerta de creación de rama integrada sólo puede pasar cuando C2 tenga SHA y
revisiones finales, todos los commits/parents coincidan y el checkout esté
limpio. La puerta de pin de producto exige además matriz integrada completa y
producto completos, disponibilidad reproducible/rollback y cero blockers.

### BLOCKED

Sólo son bloqueos admitidos:

- `BLOCKED_C2_NOT_IMMUTABLE_OR_NOT_REVIEWED`;
- `BLOCKED_BY_BASELINE_E0308`, con path/línea/hash/diagnóstico exactos;
- `BLOCKED_OFFLINE_CACHE`, después de demostrar qué objeto autorizado falta;
- autorización separada de publicación/disponibilidad, sin intentar la acción.

BLOCKED no es PASS ni autorización para pin. Debe registrar qué filas quedaron
sin ejecutar.

### FAIL

Es FAIL cualquier:

- parent, tree, path, hash, signoff o alcance inesperado;
- conflicto resuelto perdiendo I1, I2, C1, C2, Q o U1;
- cambio de lock fuera de las tres invariantes o decisión implícita T;
- test cero-seleccionado, panic, timeout, hang, flake o cleanup incompleto;
- await de capacidad/waiter queue para una conexión recibida o task detached;
- reset de deadline, gauge no cero, underflow o side effect pre-admission;
- cambio draft-16, ALPN, setup, Object bytes o Zero-Transcoding;
- diagnóstico adicional junto al E0308 heredado;
- pin parcial, SHA/branch flotante, path privado o resolución dependiente de
  cache residual;
- claim de bounded concurrency, Zero-Trust, multitrack o producción más amplio
  que la evidencia.

## Decisión de readiness actual

| Puerta | Estado actual | Motivo |
|---|---|---|
| permitir al Master crear rama integrada | `BLOCKED` | falta un `C2_SHA` inmutable con revisiones cerradas; no es un veredicto sobre C2 mutable |
| ensamblado I1/I2/C1/Q/U1 | `READY AS PLAN` | commits, parentage, colisiones y resolución reproducible documentados; no ejecutado |
| permitir pin local de producto | `BLOCKED` | requiere integración probada, cierre del E0308 para matriz completa y resolución reproducible del SHA desde entorno limpio |
| publicación/remoto | `OUT OF SCOPE / NOT AUTHORIZED` | requiere continuación separada |

Este documento no autoriza integración, C2, pin, commit, branch remota, push,
release ni C2 posterior. No declara concurrencia productiva.

## Validación de este artefacto

Se debe ejecutar desde `/home/jimbomilk/teremoq`:

```bash
git diff --check -- gateway-rs/upstream/mirror/reviews/local-integration-tp-platform-chaos-readiness-2026-08.md
rg -n '[T]ODO|[T]BD|[P]LACEHOLDER' gateway-rs/upstream/mirror/reviews/local-integration-tp-platform-chaos-readiness-2026-08.md
sha256sum gateway-rs/upstream/mirror/reviews/local-integration-tp-platform-chaos-readiness-2026-08.md
```

El SHA-256 se comunica junto al artefacto después de cerrarlo; un fichero no
puede contener su propio digest estable.
