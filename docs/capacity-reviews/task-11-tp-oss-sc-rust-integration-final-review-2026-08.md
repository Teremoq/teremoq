<!--
SPDX-FileCopyrightText: 2026 Teremoq contributors
SPDX-License-Identifier: Apache-2.0
-->

# TP-OSS-SC: revisión final diferencial de la integración Rust local

Fecha de revisión: 2026-08-28

Rol: `TP-OSS-SC: Open Source & Software Supply Chain Engineer`

Rama: `codex/master-integration-v2`

Base de la revisión anterior: `718c8ed0cdb72ad7d95c9d6d78a3273680bf6d57`

HEAD Rust congelado: `aa9269aff6857ce9e9a1b8d91ea8e46293c44c4b`

Esta es una revisión técnica, no asesoramiento jurídico. No autoriza push,
publicación, release, despliegue ni uso productivo.

## Hallazgos primero

### Alta — el pin del derivado no está publicado y bloquea el build público limpio

`gateway-rs/Cargo.toml:15-16,36` fija los tres crates MoQ al commit completo
`4b50958c121edfa2d6778c0586b30a78ee3e6f83` del repositorio
`Teremoq/moq-rs-teremoq`. La referencia no es flotante y los tres crates se
resuelven atómicamente al mismo objeto, pero el objeto sólo existe en el clon
local revisado. Una consulta read-only a la API oficial de GitHub devolvió
`HTTP 422: No commit found` para ese SHA. No se creó ni modificó ningún recurso
remoto.

Un checkout limpio archivado de este HEAD pasó `cargo metadata --locked
--offline` y `cargo check --locked --offline --all-targets --all-features`
únicamente al proporcionar un bare local efímero con el objeto exacto mediante
una reescritura Git confinada al laboratorio. Sin ese objeto local,
`cargo metadata --locked --offline` termina con código 101 porque no puede
obtener el pin. Esa reescritura demuestra coherencia del objeto y del lock; no
demuestra que un consumidor público pueda reproducir el build.

Antes de un build limpio o distribución pública se requiere una publicación
separada y expresamente autorizada del commit exacto, comprobar que la URL
canónica lo resuelve sin reescritura y repetir metadata, check, tests, deny,
audit y SBOM desde una caché vacía o entorno controlado. Esta revisión no
autoriza esa publicación.

### Alta para distribución — el checkout integrado no supera aún REUSE/licencia de proyecto

El análisis focal REUSE 5.1.1 de las diez rutas Rust finales obtuvo 0/10 con
información de copyright y 0/10 con información de licencia. El checkout no
contiene todavía el bootstrap `LICENSES/REUSE` aprobado para el repositorio
principal, y `gateway-rs/Cargo.toml:1-6` conserva `publish = false` pero no
declara `license = "Apache-2.0"`.

Esto no relicencia dependencias ni invalida el resultado local de Cargo:
`cargo deny` acepta las licencias del grafo y los nuevos crates son compatibles.
Sí impide afirmar que el árbol integrado está preparado para redistribución o
que cumple REUSE. El bootstrap open-source aprobado debe reconciliarse antes
de cualquier publicación, preservando las licencias `MIT OR Apache-2.0` del
derivado y las atribuciones de terceros.

### Media — la evidencia de dependencias es aceptable localmente, no cierra producción

`cargo deny 0.20.2 check licenses advisories sources` pasó con el lock
congelado. `cargo audit 0.22.2`, sin fetch y con la base oficial RustSec en el
commit `a7bfe16948bf6f3ee25bdee4822209f87da21b80`, no encontró vulnerabilidades.
Mantiene dos warnings `unmaintained` conocidos y acotados en
`gateway-rs/deny.toml:6-9`:

- `RUSTSEC-2024-0436`, `paste` transitivo de `moq-transport`;
- `RUSTSEC-2025-0134`, `rustls-pemfile` transitivo de `moq-native-ietf`.

No se ocultaron: tienen advisory exacto, justificación y owner documental. La
comprobación local de yanked mediante `cargo audit` fue incompleta por el índice
offline disponible y no se declara como pase; `cargo deny` sí aplicó
`yanked = "deny"` sobre sus datos locales. Antes de producción se requieren
revalidación con índices oficiales completos, resolución de los warnings cuando
upstream ofrezca migración, SBOM del artefacto final, checksums y procedencia.

### Baja — no hay Git flotante nuevo; persisten rangos SemVer preexistentes

Los tres crates MoQ usan commit Git completo y `web-transport`/`x509-parser`
usan versiones exactas. No hay branch, tag o SHA abreviado en el delta. El
manifest conserva rangos preexistentes como `bytes = "1"`, `serde = "1"` y
`tokio = "~1.51.0"` (`gateway-rs/Cargo.toml:11,21,24,41`). Por ello no se
afirma que cada declaración sea un pin exacto: la reproducción depende de
`Cargo.lock` y `--locked`. Los cinco commits no ampliaron esos rangos.

### Informativa — no se añadió coste ni evidencia de cien espectadores reales

El delta agregado modifica sólo diez rutas de `gateway-rs`; no toca
`infra/virtual-nodes`, `chaos/autoscaling`, `control-plane` ni el informe de
capacidad. La búsqueda del diff no encontró claims de coste, billing,
benchmark, espectadores o readiness productiva.

Se conserva la interpretación ya aprobada para el harness de autoescalado:
10/25/50/100 son contadores y asignaciones simulados, no vídeo ni espectadores
reales; la ejecución local midió coste remoto 0, no coste local total ni coste
real por espectador. Estos commits Rust no convierten esa evidencia en un claim
productivo y no habilitan el hito 1.000.

## Inventario y DCO de los cinco commits

Los cinco commits forman una cadena lineal exacta desde la revisión anterior.
Cada uno tiene un único `Signed-off-by: Jose María
<12586102+jimbomilk@users.noreply.github.com>` y el mismo autor/committer
autorizado.

| Commit | Padre | Rutas | SHA-256 del pathset ordenado |
| --- | --- | ---: | --- |
| `82b189b914476c8ea239b08accf10f8c3701d2cd` | `718c8ed0cdb72ad7d95c9d6d78a3273680bf6d57` | 10 | `7e69faeca6d139125112db3a4cd2366ae2e0584405a3f6a1143633a887dd4383` |
| `e825c402e16e21db294d59033cdf61b73ff60226` | `82b189b914476c8ea239b08accf10f8c3701d2cd` | 3 | `90f25cf9163cfd239356608b68b85323071cfb827977a6b30f1837e623f9ff2d` |
| `c83573ae1c24580642b9d7ccfbec8dabcfdabfb8` | `e825c402e16e21db294d59033cdf61b73ff60226` | 1 | `452d9cad7bc3dd2c8bad51f6d8526d3ed3b1b63dde32d3f26cdbc4e3be9bd798` |
| `4e33d4771e869e830ca7dab90794d869c35e351a` | `c83573ae1c24580642b9d7ccfbec8dabcfdabfb8` | 3 | `6a6ae43028a6697dd7eb3e755aac94d76b1892e79094a35d56b51d2c02a10334` |
| `aa9269aff6857ce9e9a1b8d91ea8e46293c44c4b` | `4e33d4771e869e830ca7dab90794d869c35e351a` | 1 | `452d9cad7bc3dd2c8bad51f6d8526d3ed3b1b63dde32d3f26cdbc4e3be9bd798` |

El delta agregado tiene 2.061 inserciones, 60 borrados y exactamente estas diez
rutas, con pathset SHA-256
`7e69faeca6d139125112db3a4cd2366ae2e0584405a3f6a1143633a887dd4383`:

```text
gateway-rs/Cargo.lock
gateway-rs/Cargo.toml
gateway-rs/DEPENDENCIES.md
gateway-rs/deny.toml
gateway-rs/examples/dev_mtls_moq_relay.rs
gateway-rs/src/security/federated_identity.rs
gateway-rs/src/security/mod.rs
gateway-rs/tests/federation_concurrency.rs
gateway-rs/tests/moq_derivative_contracts.rs
gateway-rs/tests/support/pki.rs
```

Inventario final de contenido, SHA-256:

```text
acdd91046b9a8156303923c876d3041e38ab78d058a101b42d9912636ea51a76  gateway-rs/Cargo.lock
b91958ee2e4811b35b548c84c17a5f10321c7037eb0a25310bc911c710edbcfa  gateway-rs/Cargo.toml
f8908e80a581fdcfedde0402daca84ba0abf7cce51d1cfae0fea69f6f78322c9  gateway-rs/DEPENDENCIES.md
ef51f8041d90d6d375ec5d65a5723886acbe22c930a34c9fed6ab28b88dc1f53  gateway-rs/deny.toml
ea239813bb3312540e8af5949571bc200325afcee97811e928e5cfef1499ea1b  gateway-rs/examples/dev_mtls_moq_relay.rs
34217ca11cbad69fcb805cdc40a9d3d14f2035966836cf134509e1a0cebfac05  gateway-rs/src/security/federated_identity.rs
b0f7b4f3084efd2f4dcd870b198edb93e3380be7ef6b04b2a80af3d1020bb6f3  gateway-rs/src/security/mod.rs
58f8cc3e550fea00468e282ce2347a55213a7fa54335dc168377aec2357e2b1b  gateway-rs/tests/federation_concurrency.rs
47c57ff35b1a4e20e91a713c994b3462fa34335ca0ee5f1edad37a4ad5c52cc4  gateway-rs/tests/moq_derivative_contracts.rs
4daf0518ce73358fb663facc43b0bebcaa15273a8db495c06451542e5d158bc2  gateway-rs/tests/support/pki.rs
```

El SHA-256 del inventario anterior, ordenado como se muestra, es
`916a7bd53e889e50f77a9e0228bb427ed32859cd8c1e14bff2716009302bae48`.
No hay symlinks, submodules, rutas `target/`, caches, binarios, unmerged ni
cambios fuera de ese inventario en los cinco commits.

## Lock, fuentes y licencias

El parser TOML comparó 375 records antes y después. El número de records no
cambia. Cuatro records MoQ cambian únicamente desde la fuente Cloudflare en
`bf87128affd316463e5dcc7599a45001f222b6de` a la fuente Teremoq en el commit
completo `4b50958c121edfa2d6778c0586b30a78ee3e6f83`. El record raíz añade las aristas
directas `web-transport` y `x509-parser`; no aparece otra versión, checksum o
paquete nuevo.

- `web-transport 0.10.9` ya existía transitivamente en el lock; conserva
  checksum `9664fb2fc7debb5de0d92110982e6758c9e4089e87e13a81452999af6f59e6c4`
  y licencia `MIT OR Apache-2.0`. La nueva arista directa es dev-only, aunque el
  paquete también sigue presente en el grafo normal a través de MoQ.
- `x509-parser 0.18.1` ya existía en el lock; conserva checksum
  `d43b0f71ce057da06bc0851b23ee24f3f86190b07203dd8f567d0b706a185202`,
  licencia `MIT OR Apache-2.0`, defaults deshabilitados y MSRV upstream 1.67.1.
- `deny.toml:41-47` mantiene `unknown-git = "deny"` y permite sólo la URL exacta
  del derivado. No autoriza el batch criptográfico T ni otra fuente Git.

El objeto local del derivado tiene tree
`c0668647d8d2d6836320bc9662fe8ae717192795`, padre
`89cb1798644c32aef06cc625f097cd9acb203417` y lock SHA-256
`d6196fd8f31ea3b2cabbdb0e57546810643f344567f3e358ee3c000b3e2b59f5`.
Sus diez commits sobre la base upstream tienen DCO; los crates consumidos
declaran `MIT OR Apache-2.0`. No hay tag ni rama remota que haga publicable ese
objeto en el momento de esta revisión.

## Evidencia reproducible

Entorno sin red, sin instalación y con fuentes read-only:

- `.cursorrules`: SHA-256
  `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2`,
  leída completamente;
- Rust/Cargo 1.93; imagen local de compilación
  `sha256:ba076cf0a26aa41efdd2f0f80687ef97009d1526680751456c19cc944dff1d0b`;
- imagen local de componentes/rustfmt
  `sha256:f522c28d5beb21591f46e8c165030f70b32dd5b51107577ad196910e7147a007`;
- cargo-deny 0.20.2; cargo-audit 0.22.2;
- REUSE 5.1.1, imagen oficial fijada
  `sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da`;
- Gitleaks 8.30.1/MIT, imagen fijada
  `sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f`.

Resultados:

```text
git archive HEAD gateway-rs + inventario contra Git         PASS; idéntico
cargo metadata --locked, objeto local exacto                 PASS
cargo metadata --locked --offline, objeto local exacto       PASS
SHA-256 metadata de ambas ejecuciones                        3a9da24f2c51a505309a482cf12e5b498f1f444aff9ed802b62475a24ec1fc45
cargo check --locked --offline --all-targets --all-features  PASS; target limpio 726514509 bytes
cargo fmt --all -- --check                                   PASS
cargo deny check licenses advisories sources                 PASS
cargo audit --no-fetch --no-yanked                           0 vulnerabilidades; 2 warnings unmaintained
cargo metadata --locked --offline, sin objeto local           FAIL 101 esperado; pin no disponible
REUSE 5.1.1 focal, diez rutas                                FAIL; 0/10 licencia, 0/10 copyright
Gitleaks 8.30.1 focal, redactado 100 %                       PASS; 0 findings
búsqueda complementaria por categorías sensibles             PASS; 0 rutas locales, claves, URL autenticadas o asignaciones de secreto
git diff 718c8ed..aa9269a --check                             PASS
marcadores de conflicto o texto provisional añadido           0
```

El escaneo no imprime valores sensibles y no sustituye a secret scanning de
historial. No se generó un SBOM ni un binario distribuible durante esta
revisión. La consulta API fue read-only; todas las demás pruebas se ejecutaron
sin red.

## Estado separado por frontera

- **Integración local:** aceptable. La cadena, DCO, inventario, lock, licencias
  de dependencias, source policy, formato, compilación all-targets y escaneo
  focal son coherentes. La reproducción requiere el objeto derivado local
  exacto y no constituye un build público.
- **Distribución pública/build limpio estándar:** bloqueados. El pin sigue sin
  publicarse; REUSE/licencia de proyecto no están integrados; faltan SBOM,
  checksums y procedencia del artefacto final.
- **Producción:** no preparada. Además de los gates anteriores, continúan los
  dos warnings unmaintained, la comprobación yanked offline incompleta y las
  limitaciones funcionales/PKI/plataforma documentadas por sus owners. No se
  infiere capacidad real, coste por espectador ni readiness comercial.

## Veredicto

**APROBADO CON LIMITACIONES**

El veredicto cubre únicamente la integración local de los cinco commits sobre
la rama Master congelada. No autoriza publicación del pin, distribución,
release, push, hito 1.000 ni producción.

**LOCAL INTEGRATION ONLY / PIN NOT PUBLISHED / PUBLIC DISTRIBUTION BLOCKED /
NO REMOTE MUTATION**
