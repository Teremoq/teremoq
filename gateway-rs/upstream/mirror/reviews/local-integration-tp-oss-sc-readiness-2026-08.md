<!--
SPDX-FileCopyrightText: 2026 Teremoq contributors
SPDX-License-Identifier: Apache-2.0
-->

# TP-OSS-SC readiness para futura integración local de moq-rs

- Fecha: 2026-08-28
- Perfil: `TP-OSS-SC`
- Alcance: DAG, licencias, DCO, Cargo.lock y gates supply-chain
- Autoridad de integración o publicación: ninguna
- Evidencia C2: excluida; no se usó el worktree C2 mutable

Este documento es un plan técnico read-only. No constituye asesoramiento
jurídico, aprobación de integración, autorización de commit ni autorización de
publicación.

## Findings

### High — falta un commit C2 cerrado y revisado

`PATCH-SERIES.md` exige que la integración contenga I1, I2, C1 y C2. Los
commits cerrados disponibles cubren I1, I2 y C1, pero este paquete prohíbe usar
el source C2 mutable y no aporta un commit C2 final inmutable. Por tanto no es
posible construir ni aprobar todavía la integración prevista.

Este informe no inspecciona C2, no infiere su futuro SHA, no emite un veredicto
C2 y no reutiliza resultados de un worktree mutable como evidencia. Antes de
ensamblar nada deberá existir un commit C2 con parent C1, inventario, tree,
DCO, revisiones funcional/plataforma/PKI/supply-chain y aceptación del Master.

### High — las series cerradas forman tres ramas, no una historia lineal

El DAG verificado es:

```text
bf87128affd316463e5dcc7599a45001f222b6de  baseline
├── 05b41127ecbd48de4c59fe1626c43b1e423c33a9  I1
│   └── 59d9a8601885ef934cae29d89876abb7c7f73e89  I2
├── ee22a1079783e374371e0705775978790ddd6471  C1
│   └── C2 cerrado futuro
└── 1e9d1ee62bde97145a0914e5992ab7f54fc909c4  Q
    └── 4547800088881cb4782c544ebfec0a1904ed1fab  U1
```

Q y U1 son lineales y acumulativos: U1 contiene Q. No son alternativas. Sin
embargo, ni U1 ni C1 descienden de I2. No pueden hacerse fast-forward sobre una
única rama I2.

Una combinación read-only con `git merge-tree` demuestra un conflicto real en
`moq-native-ietf/src/quic.rs` entre el contenido acumulado I1/I2 y C1. I1 y C1
modifican esa misma ruta desde el baseline. I2 y U1 modifican ambos
`Cargo.lock`; el merge virtual no generó markers para el lock, pero el fichero
resultante debe reconciliarse y revisarse como un artefacto nuevo.

No se debe afirmar que un cherry-pick conserva el commit aprobado: al cambiar
el parent cambia el SHA. Tampoco se debe crear un merge y tratar su resolución
como aprobada implícitamente. Cada commit de integración nuevo requiere DCO,
inventario, tree y nuevas revisiones antes de entrar en la allowlist local.

### High — RustSec y release gates continúan rojos

Q elimina dos findings de `quinn-proto`; U1 elimina uno de `bytes`. El resultado
congelado posterior a U1 conserva 16 entradas vulnerables, 12 advisory IDs y
seis warnings. No existe todavía un `deny.toml` revisado, SBOM final
reconciliado ni reconstrucción/package/release completa.

Por tanto las mejoras Q/U1 son necesarias pero insuficientes. No se permite
ningún allow/ignore RustSec sin advisory exacto, owner, justificación y expiry.

### High — T queda expresamente fuera de la integración autorizable

El lote T afecta `aws-lc-rs`, `aws-lc-sys`, dos líneas
`rustls-webpki` y auxiliares del provider TLS. Es una decisión criptográfica de
alto impacto no autorizada. Ninguna estrategia, merge o regeneración de lock de
este plan puede mover sus versiones, checksums, features o provider.

Los cinco commits cerrados conservan exactamente las coordenadas baseline:

| Paquete | Versión | Checksum crates.io |
|---|---:|---|
| `aws-lc-rs` | `1.13.3` | `5c953fe1ba023e6b7730c0d4b031d06f267f23a46167dcbd40316644b10a17ba` |
| `aws-lc-sys` | `0.30.0` | `dbfd150b5dbdb988bcc8fb1fe787eb6b7ee6180ca24da683b61ea5405f3d43ff` |
| `rustls-webpki` | `0.102.4` | `ff448f7e92e913c4b7d4c6d8e4540a1724b319b4152b8aef6d4cf8339712b33e` |
| `rustls-webpki` | `0.103.4` | `0a17884ae0c1b773f1ccd2bd4a8c72f16da897310a98b0e84bf349ad5ead92fc` |

Cualquier movimiento de esas cuatro coordenadas es una condición de parada y
devolución al usuario para decisión expresa. El dev-edge I2 a `rustls 0.23.31`
con provider `ring` es una excepción test-only ya revisada; no autoriza T ni un
cambio del provider normal/runtime.

### Medium — `PATCH-SERIES.md` aún no incorpora Q/U1

La política de integración actual enumera I1/I2/C1/C2, pero no los commits
RustSec Q/U1. Antes de convertir una rama local en candidata a inventario
remoto, la documentación y el verificador deberán ampliarse mediante un cambio
separado y autorizado con los SHAs finales exactos. No debe relajarse el
inventario con prefijos, wildcards o conteos mínimos.

Este memo no modifica `PATCH-SERIES.md`, `baseline.env`, el verificador ni
ningún ADR.

### Medium — el hash de lock combinado es predictivo, no todavía vinculante

Aplicando en memoria únicamente los reemplazos Q y U1 sobre el lock I2 se
obtiene un candidato determinista SHA-256
`d6196fd8f31ea3b2cabbdb0e57546810643f344567f3e358ee3c000b3e2b59f5`.
Contiene 336 records, conserva el único edge dev I2 a `rustls 0.23.31` y cambia
exactamente dos records respecto de I2.

Ese hash es un oracle útil para detectar movimiento accidental, pero no es el
hash final aprobado: todavía no existe el commit C2 cerrado ni la resolución
del merge completo. Si el C2 final o Cargo justificadamente altera el lock, la
divergencia debe revisarse; nunca se ajustará el valor esperado después del
hecho sin explicar record por record el cambio.

### Low — fixtures privados sintéticos requieren excepciones focales

I1, I2 y C1 contienen claves privadas DER deliberadamente públicas y
sintéticas para tests. Sus sidecars, checksums, sujetos genéricos y warnings de
no despliegue fueron revisados. El árbol integrado debe conservarlos sin
transformación ni deduplicación opaca y el secret scan debe reportar o
clasificar los findings esperados por path/blob exacto, nunca mediante una
exclusión global de claves o DER.

### No defecto en los cinco commits cerrados dentro de este alcance

Parentage, trees, DCO, modos, límites de ruta y licencias de I1/I2/C1/Q/U1
coinciden con sus revisiones finales. Ninguno contiene T ni una dependencia no
explicada. Esto no constituye aprobación de la integración futura.

## Veredictos separados

**LOCAL INTEGRATION: NOT READY**

El plan está listo para revisión del Master, pero falta C2 cerrado, existen
resoluciones nuevas pendientes y no se han ejecutado los gates del árbol
combinado. No se autoriza crear la rama ni commits de merge mediante este memo.

**PUBLICATION: NOT READY**

No se autoriza push, fetch, tag, PR, issue, release, publicación, modificación
del verificador, cambio de product pin ni acción remota.

## Documentos vinculantes

| Documento | SHA-256 |
|---|---|
| `.cursorrules` | `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2` |
| `ADR-0007-CONTROLLED-MOQ-MIRROR.md` | `0085bdaa37cd3645a4a2c5a3163b0b096453b84f66635514fce6015d6bed25d8` |
| `PATCH-SERIES.md` | `b0fe298fa0b4c37c7562c6fc0ea541ceca26fbf0cd40a04016645277a34b642e` |
| I1 final TP-OSS-SC | `6b0f1aaa0606eae264997907d31b0d442a4275f99f0d7550570a3895c65bacc3` |
| I2 final TP-OSS-SC | `1d0e80b5d1128989eb6413cb07fe932a835bc19d800ed262be4122fa6d27aecb` |
| C1 final TP-OSS-SC | `90bf9725e4e8f4eaf4e0c0829136e285be42d63e86b9f834513da9027b129544` |
| Q final TP-OSS-SC | `bc3f3d9f020b1da7116510843e1de330331140e0affde164ac6b69cf6ecc702c` |
| U1 final TP-OSS-SC | `48c053d703d4f07b4ce1bf52f5e4bcd2745812d613433d43bd1bc5d80b681ede` |

Todos se leyeron completamente. Los informes fueron contraste, no sustituto
de la inspección directa de objetos Git.

## Inventario de commits cerrados

| Unidad | Commit | Parent | Tree | Paths | Pathset SHA-256 |
|---|---|---|---|---:|---|
| I1 | `05b41127ecbd48de4c59fe1626c43b1e423c33a9` | baseline | `eca64a72e148482fb82b963edc2f2c9af28803f2` | 17 | `9f81fe7853d13bf3ad93446e9815862a914747106afb4953de7abb6f9abdec77` |
| I2 | `59d9a8601885ef934cae29d89876abb7c7f73e89` | I1 | `d108208bfb5792767881a932480da01769844148` | 22 | `973a0d8b4519cc67c65e54c07b508bea8964133928f3ea63b27c07c7627b979c` |
| C1 | `ee22a1079783e374371e0705775978790ddd6471` | baseline | `232e449945e877b024f2fc4223f0d2eea124b39b` | 10 | `ecbd7dec9829c972da4592187a2fc9856d888bc0985aaba5d39736a2ec961952` |
| Q | `1e9d1ee62bde97145a0914e5992ab7f54fc909c4` | baseline | `4cf25aeea2eacd02394608c80c9677eaa001ef87` | 1 | `3e503ffd2d2f0c135bc5d8c97cba5aff82676478d90cb002333ed9583b92c5a0` |
| U1 | `4547800088881cb4782c544ebfec0a1904ed1fab` | Q | `cc9b037c81ace8a9490693a6ccb1c294cd0e3886` | 1 | `3e503ffd2d2f0c135bc5d8c97cba5aff82676478d90cb002333ed9583b92c5a0` |

Los cinco commits tienen exactamente un parent, modo `100644` en todas las
rutas modificadas, una única trailer DCO que coincide con el author y la misma
identidad de author/committer. Ninguno lleva firma criptográfica; la política
actual no la exige. Este informe no reproduce nombres o emails personales.

### Límites de ruta y licencia

- I1: 17 rutas `moq-native-ietf`; un source, un test, README, siete DER y siete
  sidecars.
- I2: 22 rutas; relay, un ajuste API acotado de `moq-transport`, cinco DER con
  sidecars, un manifest y lock.
- C1: 10 rutas `moq-native-ietf`; source/test y tres DER con sidecars.
- Q: sólo `Cargo.lock`, `quinn-proto`.
- U1: sólo `Cargo.lock`, `bytes`.

La comprobación directa obtuvo licencia `MIT OR Apache-2.0` en 10/10 artefactos
textuales I1 aplicables, 15/15 I2 y 7/7 C1. Todos los DER tienen sidecar; los
sidecars son byte-idénticos con SHA-256
`5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0`.
Q/U1 son cambios de lock cubiertos por la política REUSE existente. El package
relay conserva `license = "MIT OR Apache-2.0"` en cada commit.

## Reconciliación exacta de Cargo.lock

| Snapshot | SHA-256 Cargo.lock | `quinn-proto` | `bytes` | Edge relay→rustls |
|---|---|---|---|---|
| baseline / I1 / C1 | `b518a2fa4a6d7a0ffe0bdfe4b530f05196ac0f5e6f7ef51da9e5a83c0b0561c0` | `0.11.13` | `1.6.0` | no |
| I2 | `13b9f1c54ccbe644dcf4f07542f610950cd013b291c928b6b3ad39ac1751ce80` | `0.11.13` | `1.6.0` | dev-only `rustls 0.23.31` |
| Q | `a249c6296affe18cdd726324539e52e6783718fbd2c1e63ec7ab4bdd95b27e9b` | `0.11.15` | `1.6.0` | no |
| U1 | `0b8ebcce6495ea65cc0acb0a94852e0067f78b06aa956dc8a368195bce626e19` | `0.11.15` | `1.11.1` | no |
| oracle I2+Q+U1 | `d6196fd8f31ea3b2cabbdb0e57546810643f344567f3e358ee3c000b3e2b59f5` | `0.11.15` | `1.11.1` | dev-only `rustls 0.23.31` |

Coordenadas exactas autorizadas para el lock reconciliado:

| Paquete | Versión eliminada | Versión esperada | Checksum esperado |
|---|---:|---:|---|
| `quinn-proto` | `0.11.13` | `0.11.15` | `4fcb935c5bec503c2f0e306bdd3e58bb9029dcb14fa8d9ac76e3a5256ac0763e` |
| `bytes` | `1.6.0` | `1.11.1` | `1e748733b7cbc798e1434b6ac524f0c1ff2ab456fe201501e6497c8417a4fc33` |

El oracle se calculó sólo en memoria desde los bytes exactos I2. Su record-set
respecto de I2 elimina dos records (`quinn-proto 0.11.13`, `bytes 1.6.0`) y
añade dos (`quinn-proto 0.11.15`, `bytes 1.11.1`); conserva 336 records. No
cambia ningún dependency list aparte del edge dev I2 ya presente.

El único manifest delta cerrado es I2:

```toml
rustls = { version = "=0.23.31", default-features = false, features = ["ring"] }
```

Está bajo `[dev-dependencies]`; no añade paquete porque `rustls 0.23.31` ya
estaba locked. I1, C1, Q y U1 no cambian manifests. No hay otra dependencia o
feature autorizada.

## Estrategia local reversible recomendada

### Precondiciones

1. Obtener el commit C2 cerrado y todas sus aprobaciones sin usar el worktree
   mutable como sustituto.
2. Confirmar que I1/I2, C1/C2 y Q/U1 conservan exactamente su parentage.
3. Confirmar que el futuro C2 no cambia manifest, lock, dependencia, feature,
   provider, wire, licencia o pin; cualquier excepción vuelve al Master.
4. Crear la integración sólo tras una autorización separada del Master.

### Ensamblado recomendado

Preservar los SHAs cerrados mediante un DAG de merge explícito, en vez de
cherry-pick silencioso:

1. Crear un worktree local desechable desde I2 y una rama local
   `teremoq/integration-draft16-bf87128`, sin upstream.
2. Hacer merge `--no-ff --no-commit` del futuro head C2, que debe contener C1.
   Resolver `quic.rs` y cualquier solapamiento relay preservando ambos
   contratos. No usar resolución automática como evidencia.
3. Congelar el resultado source en un merge commit DCO nuevo. Someter ese
   commit a `TP-RUST-DIST`, `TP-SEC-PKI`, `TP-PLATFORM-CHAOS` y `TP-OSS-SC`.
4. Hacer merge `--no-ff --no-commit` de U1; éste ya contiene Q. No aplicar Q
   por segunda vez.
5. Reconciliar el lock desde los manifests combinados con sólo las versiones
   precisas Q/U1, verificar T sin movimiento y crear un merge commit DCO
   separado para el lock.
6. Someter el lock merge y el tree final a revisión. Sólo entonces congelar el
   head como candidato local exacto.

No se recomienda un octopus merge: oculta qué resolución pertenece a source y
cuál al lock. Tampoco se recomienda una rama lineal por cherry-pick salvo que
el Master exija historial lineal; en ese caso todos los SHAs reproducidos
cambiarán y cada commit regenerado deberá revisarse como nuevo. Los SHAs
originales seguirán siendo evidencia de procedencia, no ancestros aprobados de
la rama lineal.

### Reversibilidad

- Las ramas I1/I2, C1/C2 y Q/U1 permanecen inmutables.
- La integración se construye en un worktree y branch nuevos, sin tracking ni
  product pin.
- Antes de cada commit se conserva el head anterior exacto en el inventario
  local; no se crean tags.
- Ante conflicto o gate rojo se usa `git merge --abort` antes de commit o se
  abandona la rama local; no se ejecuta reset destructivo, rebase o force-push.
- La eliminación posterior del worktree/branch scratch requiere una decisión
  separada si contiene evidencia no integrada.
- El rollback de producto continúa siendo el pin atómico al baseline oficial;
  este plan no toca pins.

## Inventario fail-closed del candidato

El candidato no puede validarse por nombre de rama o por número mínimo de
commits. Debe existir una lista exacta que contenga:

- baseline;
- I1, I2, C1, futuro C2, Q y U1;
- cada merge commit source/lock nuevo ya revisado; y
- el head/tree final exactos.

Comprobaciones futuras, después de autorización:

```bash
repo=/home/jimbomilk/moq-rs-teremoq-integration-work
baseline=bf87128affd316463e5dcc7599a45001f222b6de
i1=05b41127ecbd48de4c59fe1626c43b1e423c33a9
i2=59d9a8601885ef934cae29d89876abb7c7f73e89
c1=ee22a1079783e374371e0705775978790ddd6471
q=1e9d1ee62bde97145a0914e5992ab7f54fc909c4
u1=4547800088881cb4782c544ebfec0a1904ed1fab

: "${c2_commit:?cargar el C2 exacto aprobado}"
: "${source_merge:?cargar el merge source aprobado}"
: "${lock_merge:?cargar el merge lock aprobado}"
: "${candidate:?cargar el head candidato aprobado}"

git -C "$repo" merge-base --is-ancestor "$baseline" "$candidate"
git -C "$repo" merge-base --is-ancestor "$i1" "$candidate"
git -C "$repo" merge-base --is-ancestor "$i2" "$candidate"
git -C "$repo" merge-base --is-ancestor "$c1" "$candidate"
git -C "$repo" merge-base --is-ancestor "$c2_commit" "$candidate"
git -C "$repo" merge-base --is-ancestor "$q" "$candidate"
git -C "$repo" merge-base --is-ancestor "$u1" "$candidate"

git -C "$repo" rev-list --reverse --topo-order "$baseline..$candidate"
git -C "$repo" rev-list --merges "$baseline..$candidate"
git -C "$repo" rev-parse "$candidate^{tree}"
git -C "$repo" diff --check "$baseline..$candidate"
git -C "$repo" status --porcelain=v1
```

La salida de `rev-list` se compara por igualdad de sets con la allowlist
cerrada; cualquier commit extra o ausente falla. Los únicos merges permitidos
son `source_merge` y `lock_merge`, con parents, tree y DCO exactos. El status
final debe estar vacío y la rama no debe tener upstream.

El validador DCO debe procesar cada commit alcanzable y emitir sólo
`SHA/pass|fail`, sin publicar identidades personales. Debe exigir exactamente
un `Signed-off-by` que coincida con el author del commit. También debe comprobar
parent count, modos, ausencia de submodules/symlinks y licencia del delta.

## Comandos futuros de lock y separación T

Los comandos precisos se ejecutarán únicamente en el worktree de integración
autorizado, offline, con Cargo 1.93.0 fijado y caches read-only verificadas:

```bash
cargo update --locked --offline \
  -p quinn-proto@0.11.13 --precise 0.11.15
cargo update --locked --offline \
  -p bytes@1.6.0 --precise 1.11.1

cargo metadata --locked --offline --format-version 1
cargo tree --locked --offline -p moq-relay-ietf -e normal,build
cargo tree --locked --offline -p moq-relay-ietf -e dev \
  --invert rustls@0.23.31
cargo tree --locked --offline -e features \
  --invert quinn-proto@0.11.15
cargo tree --locked --offline -e features --invert bytes@1.11.1
```

Después de cada `cargo update`, el record-set se compara con el input. Sólo se
aceptan las dos sustituciones exactas indicadas. Si cambia un manifest, una
dependency list no explicada, otra versión/checksum, un paquete T, provider o
feature normal/build, se detiene la integración.

El uso de `--locked` con `cargo update` puede ser rechazado por la versión de
Cargo al intentar modificar el lock; si ocurre, se ejecuta el update preciso
sin `--locked`, siempre offline, y se valida inmediatamente el diff exacto. No
se permite un `cargo update` general.

## Gates finales obligatorios

### Git, DCO y licencia

1. Igualdad exacta del inventario de commits/parents/trees/pathsets.
2. DCO válido en los cinco commits cerrados, C2 y cada merge nuevo.
3. `git diff --check`, stage/status limpios y cero submodules/symlinks nuevos.
4. Conservación byte-idéntica de `LICENSES/Apache-2.0.txt`,
   `LICENSES/MIT.txt`, `REUSE.toml` y copyrights upstream.
5. Todo source/test Teremoq nuevo bajo `MIT OR Apache-2.0`; cada binario con
   sidecar.
6. REUSE 5.1.1 sobre archive del tree exacto y sobre cada crate empaquetado,
   con herramienta oficial fijada por digest y fuera del artefacto.

### Advisory y policy

1. `cargo audit --no-fetch --db "$rustsec_db" --file Cargo.lock` contra la DB
   congelada `6420e39260b3d771b049954cf5d52b57e2118da4` para comparación atribuible.
2. Un segundo audit contra una DB actual autorizada antes de release; nunca se
   reutiliza el resultado congelado como afirmación actual.
3. `cargo deny check licenses advisories` con policy revisada, cero ignore por
   defecto y resultado explícito.
4. Comparación de findings baseline, I2, U1 y candidato. Q debe retirar sólo
   `RUSTSEC-2026-0037`/`0185`; U1 sólo `RUSTSEC-2026-0007`; el resto no puede
   ocultarse ni atribuirse a estos lotes.
5. T permanece rojo/pending hasta decisión expresa; este plan no permite
   resolverlo ni exceptuarlo.

### Metadata, package y SBOM

1. `cargo metadata --locked` completo y `cargo tree` normal/build/dev/features
   desde un cache reproducible autorizado.
2. `cargo package --locked --list` sin `--allow-dirty` para
   `moq-native-ietf`, `moq-transport` y `moq-relay-ietf`.
3. Generación de los tres packages con verificación habilitada, extracción en
   scratch y compilación/test del contenido empaquetado.
4. Confirmación de que todos los `include_bytes!` resuelven dentro de su crate,
   con fixtures, sidecars, README e inventarios presentes.
5. SBOM CycloneDX o SPDX generado por una herramienta oficial previamente
   aprobada, fijada por versión/digest y ejecutada fuera del runtime.
6. Reconciliar SBOM con los 336 records locked, sources, checksums, features y
   edges. Debe incluir el dev-edge `rustls 0.23.31`, `quinn-proto 0.11.15`,
   `bytes 1.11.1`, ambos `rustls-webpki`, paquetes nativos/build y fixtures.
7. Hash del SBOM, packages y checksums registrado junto al tree candidato; no
   se publica ningún artefacto durante la integración local.

### Secret y publication boundary

1. Gitleaks 8.30.1 por digest, `--redact=100`, sin suppressions, sobre:
   archive completo del tree; patch binario baseline-candidato; cada merge
   commit; y los packages extraídos.
2. Escaneo complementario de PEM/DER/P12/PFX, rutas locales, emails, SPIFFE,
   URLs autenticadas, namespaces productivos, identidades, endpoints, datos
   operativos y generated/cache artifacts.
3. Los fixtures sintéticos se validan por hash/provenance y warning. No se
   considera suficiente que Gitleaks no lea DER.
4. Cualquier secreto real detiene el proceso sin mostrar valor, limpiar
   historia o publicar el candidato.

### Build y comportamiento, propiedad de otros perfiles

La rama combinada necesita toolchain exacto, check/fmt/Clippy/tests de los tres
crates, raw QUIC/WebTransport, ambos ALPN, draft-16, Objects, identidad
fail-closed, redacción, handshake admission, shutdown, races y rollback. Los
owners funcional, PKI y plataforma ejecutan esos gates; `TP-OSS-SC` sólo los
consume como evidencia vinculada al tree final.

## Gates para una publicación futura, separados

Incluso una integración local aprobada no autoriza publicación. Antes de un
push futuro se requieren además:

- actualizar `PATCH-SERIES`, `baseline.env` y el verificador con el mapa exacto
  full-ref/full-SHA, después de autorizar esos cambios;
- probar negativos para branch/commit/tree extra, ausente o movido y mantener
  cero tags;
- resolver o aceptar explícitamente cada advisory restante, incluido T;
- releases registry secuenciales y verificadas para las APIs apiladas;
- SBOM, checksums y provenance finales;
- rulesets/controles aplicables demostrados, sin afirmar CodeQL/SBOM remoto
  mientras sus APIs sigan bloqueadas; y
- autorización explícita del Master para el non-force push y verificación
  post-push.

## Actividad y limitaciones de esta revisión

La auditoría usó únicamente Git 2.53.0, Python 3.14.4, SHA-256 y los objetos
locales existentes. No ejecutó build, Cargo, Docker, red o herramientas nuevas.
El lock combinado se modeló en memoria y no se escribió.

No se leyó ni usó `/home/jimbomilk/moq-rs-teremoq-c2-work`. No se editó ningún
worktree moq-rs, source, manifest, lock, ADR, informe previo, configuración Git,
ref, remote o artefacto Task 05. No hubo checkout, branch, merge, cherry-pick,
commit, fetch, push, tag, PR, issue, release, publicación, comunicación externa
ni mutación remota.

Sólo se creó este memo en el repositorio Teremoq.

**READINESS PLAN ONLY / NO LOCAL INTEGRATION / NO PUBLICATION / NO REMOTE MUTATION**
