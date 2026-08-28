<!-- SPDX-License-Identifier: Apache-2.0 -->

# Revisión final TP-SEC-PKI del product pin

Fecha: 2026-08-28

Revisor: `TP-SEC-PKI`

Modo: **REVISIÓN INDEPENDIENTE READ-ONLY / SIN IMPLEMENTACIÓN / SIN PUSH / SIN PUBLICACIÓN**

## Hallazgos

### HIGH — F-01: la URI SAN se interpreta con un parser propio, contra el contrato autorizado

`gateway-rs/src/security/federated_identity.rs:237-281` implementa la sintaxis
de la URI con `is_ascii`, búsquedas de bytes, `strip_prefix`, `split_once` y una
reconstrucción manual. No invoca `url 2.5.8`, aunque esa dependencia mantenida ya
está resuelta en `gateway-rs/Cargo.toml:28`.

Esto incumple tanto la regla vinculante de reutilización como el contrato
TP-SEC-PKI autorizado, que exige parsear la URI con `url 2.5.8` y aplicar después
la comparación byte a byte de la forma canónica. La allowlist manual observada es
estricta y no encontré un bypass concreto en sus casos cubiertos, pero sigue
siendo un parser de protocolo propio en una frontera de identidad. No puede
aprobarse por equivalencia aparente.

Cambio comprobable para `TP-RUST-DIST`: sustituir exclusivamente esa
interpretación por la API pública mantenida `url::Url`, sin dependencia nueva;
rechazar scheme/authority ajenos, userinfo/password, port, query, fragment,
segmentos extra, percent-encoding, Unicode/IDNA y cualquier forma cuyo texto no
sea idéntico a la reconstrucción Teremoq. Conservar la allowlist de `node-id` y
los límites previos al parser.

### HIGH — F-02: la composición E2E no demuestra toda la autorización aceptada ni sus denegaciones

La única operación positiva real iniciada por
`gateway-rs/tests/moq_derivative_contracts.rs:232-235` es
`publisher.publish_namespace(...)`. El `match` de policy contempla
`Operation::Publish` y `Operation::PublishNamespace` en
`gateway-rs/tests/moq_derivative_contracts.rs:560-569`, pero no existe una
petición MoQT `PUBLISH` real del producto que atraviese ese branch. El test de
identidad denegada, en `gateway-rs/tests/moq_derivative_contracts.rs:92-161`,
sólo usa `gateway-dev-2`; no ejerce URI ausente, rol relay, namespace ajeno ni
las operaciones Subscribe, SubscribeNamespace, DiscoverNamespace, TrackStatus o
RelayPeer.

La lectura del derivado confirma que los gates existen antes de los efectos:
`moq-relay-ietf/src/consumer.rs:169-176` para `PUBLISH_NAMESPACE`,
`moq-relay-ietf/src/consumer.rs:441-448` para `PUBLISH`, y
`moq-relay-ietf/src/producer.rs:211-218`, `377-387`, `520-546`, `571-594` y
`780-808` para las operaciones consumidoras. Esa evidencia upstream no sustituye
una prueba de composición con el authorizer y el principal concretos del
producto. El gate de aceptación previo exigía ambas operaciones positivas y los
negativos antes del primer efecto en raw QUIC y WebTransport.

Cambio comprobable para `TP-RUST-DIST`: ampliar el test público de composición
en ambos transportes para producir un `PUBLISH` real y un
`PUBLISH_NAMESPACE` real sobre `teremoq/live`; denegar el namespace distinto y
cada operación no permitida, midiendo estado independiente antes/después. Añadir
certificados válidos de la misma CA sin URI, con URI relay y con gateway no
allowlisted. Ninguna denegación puede alcanzar scope, `SERVER_SETUP`, lookup,
registro, cache, forwarding, respuesta o mutación.

### MEDIUM — F-03: faltan negativos obligatorios del parser, retención y redacción

Los seis tests agrupados de
`gateway-rs/src/security/federated_identity.rs:311-463` prueban el happy path,
tres excesos de límite, DER inválido, SAN ausente, dos URI iguales, DNS junto a
gateway, dos principals denegados y una muestra de gramática. No prueban los
casos obligatorios siguientes:

- límites exactos y `+1` de cadena, leaf y total, ni trailing DER;
- dos extensiones SAN, `GeneralName::Invalid`, cero URI con otro SAN, dos URI
  distintas o URI presente sólo en el intermediate;
- backslash, CR/LF y NUL, ni la matriz completa de SAN permitidos/prohibidos por
  rol;
- lifecycle que demuestre que DER, el objeto X.509 y la URI completa no quedan
  retenidos;
- canarios independientes para DER, subject, URI, node-id, path, namespace,
  prefix y URL en `Debug`, `Display`, `tracing`, `anyhow`, mlog/qlog y métricas;
- aislamiento concurrente de dos identidades.

La implementación leída sí consume DER completo
(`gateway-rs/src/security/federated_identity.rs:196-205`), recorre todos los
`GeneralName` (`:207-234`) y retiene sólo rol/node-id (`:49-89`), pero el gate
formal exigía pruebas adversariales y de lifecycle, no sólo inspección.

### MEDIUM — F-04: la nueva dependencia directa de test no está inventariada

El commit `0976b52578aebd5c0e9226dcdb7545d6bfdff04c` añade
`web-transport = "=0.10.9"` como dev-dependency en
`gateway-rs/Cargo.toml:31-42`. El inventario de dependencias de desarrollo en
`gateway-rs/DEPENDENCIES.md:29` no la registra. El paquete ya existía
transitivamente en el lock y el edge directo es test-only, pero la regla de
inventario aplica también a herramientas/dependencias de test.

Cambio comprobable para `TP-RUST-DIST`: registrar repositorio oficial, versión
exacta, licencia SPDX, propósito de inspección del cierre público, owner y política
de actualización. No se requiere cambiar la versión ni el lock para cerrar este
hallazgo.

## Evidencia favorable confirmada por lectura independiente

1. **Evidencia ligada a la misma conexión:**
   `moq-native-ietf/src/quic.rs:1154-1179` extrae `peer_identity()` del
   `quinn::Connection` que acaba de producir la sesión; la conversión exige el
   tipo rustls esperado y cadena no vacía en `:779-797`. No se acepta IP, SNI,
   path, `ConnInfo` o tagger como principal.
2. **Límites previos al parser:**
   `gateway-rs/src/security/federated_identity.rs:163-193` comprueba primero
   8 certificados, 16 KiB de leaf y 64 KiB total con `checked_add`; sólo después
   parsea `certificates[0]`.
3. **DER/SAN completos y contexto mínimo:** el remainder DER debe ser vacío, la
   API `subject_alternative_name()` de `x509-parser` exige extensión única y se
   recorren todos los nombres. El principal contiene sólo `FederatedRole` y
   `String node_id`; su `Debug` omite ambos valores. No se retienen DER, PEM,
   subject, SAN, serial o fingerprint.
4. **Certificado válido no equivale a acceso:**
   `gateway-rs/src/security/federated_identity.rs:163-171` rechaza todo principal
   distinto de `gateway-dev-1`; la policy del ejemplo sólo acepta path
   `/publish` (`gateway-rs/examples/dev_mtls_moq_relay.rs:219-231`) y sólo
   `Publish`/`PublishNamespace` sobre el namespace exacto (`:234-253`). Relay y
   el wildcard de operaciones permanecen default-deny.
5. **Orden fail-closed:** C2 usa `try_admit` antes de crear la tarea de sesión
   (`moq-relay-ietf/src/relay.rs:1572-1619`); autenticación con evidencia I1
   ocurre en `:1943-1999`; el path se decodifica y autoriza en `:2012-2050`
   antes de `pending.finish(None)`/`SERVER_SETUP` (`:2056-2067`). Required no
   recibe writer mlog y no llama a `Coordinator::resolve_scope` ni a
   `ConnectionTagger`.
6. **Capacidad independiente de identidad:** los tests recorren raw QUIC y
   WebTransport (`gateway-rs/tests/moq_derivative_contracts.rs:75-89`), observan
   el cierre público exacto `0x3`/`relay session capacity reached`
   (`:281-310`, `:361-395`), mantienen una sola autenticación/efecto para N+1,
   recuperan el permit (`:314-358`) y exigen gauges cero al shutdown
   (`:260-265`). No encontré una conversión de capacidad en principal o permiso.
7. **Parser X.509 no criptográfico:** `x509-parser = 0.18.1` está fijado con
   `default-features = false`; metadata Cargo declara cero features directas. El
   source oficial cacheado declara `default = []`, `verify = ["ring"]` y
   `verify-aws = ["aws-lc-rs"]`; ninguno está solicitado. El código sólo usa
   `FromDer` y extensiones, y no revalida cadena, firma, EKU o vigencia. No hay
   cambio del provider rustls.
8. **Redacción operativa:** los fallos del parser se reducen a
   `AuthorizationError::AuthenticationRejected`; los eventos required y sus
   labels son constantes y de baja cardinalidad. `qlog_dir`/`mlog_dir` son
   `None` en el producto. No encontré en el delta un log de certificado,
   principal, URI, node-id, namespace o error derivado del peer.

## Snapshots y procedencia

### Producto

- Worktree: `/home/jimbomilk/teremoq-product-pin-owner-work`.
- Branch: `codex/product-pin-auth-cache-local`, sin tracking.
- HEAD: `0976b52578aebd5c0e9226dcdb7545d6bfdff04c`.
- Tree HEAD: `c9551772c790535988c5e6ad67288859c8bba95e`.
- Commit de policy: `c719b84a11f3cdb185012d2a98633891a2d651d3`;
  tree `d0dd60264853b4308c5c74bd8ccae12041a00bb1`; parent
  `0faee5dec127e47649a08b82bade8f3faf69c8ab`.
- `0976b525...` tiene como parent exacto `c719b84a...`.
- Ambos commits tienen author/committer y `Signed-off-by` exactos:
  `Jose María <12586102+jimbomilk@users.noreply.github.com>`.
- Patch SHA-256 de `c719b84a...`:
  `aaf4a9dd8e25b21a44bbd881f6580c9a460d4b69de19d0f6dc2e4e6abfcf26bf`.
- Patch SHA-256 de `0976b525...`:
  `0f4e707ea71da25d0e20df8df29bf0b24f83e208e69e30aa9e29aeee6c2ea84e`.
- Pathset combinado ordenado SHA-256:
  `7e69faeca6d139125112db3a4cd2366ae2e0584405a3f6a1143633a887dd4383`.
- Worktree/stage limpios; status-z SHA-256 de vacío:
  `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.

Hashes de los diez paths finales revisados:

| Path | SHA-256 |
|---|---|
| `gateway-rs/Cargo.lock` | `acdd91046b9a8156303923c876d3041e38ab78d058a101b42d9912636ea51a76` |
| `gateway-rs/Cargo.toml` | `b91958ee2e4811b35b548c84c17a5f10321c7037eb0a25310bc911c710edbcfa` |
| `gateway-rs/DEPENDENCIES.md` | `1d3178180f73481f5b8d3efdb69a2ab50dd03e577ef49ac1d2f433a3f72cd980` |
| `gateway-rs/deny.toml` | `ef51f8041d90d6d375ec5d65a5723886acbe22c930a34c9fed6ab28b88dc1f53` |
| `gateway-rs/examples/dev_mtls_moq_relay.rs` | `ea239813bb3312540e8af5949571bc200325afcee97811e928e5cfef1499ea1b` |
| `gateway-rs/src/security/federated_identity.rs` | `dc983ba2ecbfdc46ab4a9e3c4e36f529f58b2c9742398e7a288a3c692da3eee9` |
| `gateway-rs/src/security/mod.rs` | `b0f7b4f3084efd2f4dcd870b198edb93e3380be7ef6b04b2a80af3d1020bb6f3` |
| `gateway-rs/tests/federation_concurrency.rs` | `58f8cc3e550fea00468e282ce2347a55213a7fa54335dc168377aec2357e2b1b` |
| `gateway-rs/tests/moq_derivative_contracts.rs` | `35cbb4414bd6b084d87b879563e6f9d1256990c99583de2ea5aec7a16634c20f` |
| `gateway-rs/tests/support/pki.rs` | `16b3dd7aaaddfcd230439d49e2a5dec8ed8a0b84f6973396dad5e0abceb775f4` |

### Derivado

- Worktree: `/home/jimbomilk/moq-rs-teremoq-cache-work`.
- Branch: `codex/required-cache-ttl-89cb179`, sin tracking.
- Commit/HEAD: `4b50958c121edfa2d6778c0586b30a78ee3e6f83`.
- Tree: `c0668647d8d2d6836320bc9662fe8ae717192795`.
- Parent: `89cb1798644c32aef06cc625f097cd9acb203417`.
- Patch SHA-256:
  `59103cbb2d49f1bc008845a00a3a2ae924f703e475bcf42d015476e2339702e9`.
- Pathset de cuatro rutas SHA-256:
  `294653155f735af9a9b2ef0a7bcf99f54c2d884d8f3bde44048deb9f3f8006ff`.
- DCO exacto con la identidad indicada; worktree/stage limpios y sin tracking.
- El delta sólo propaga el cache idle timeout a `Relay`, `Locals` y
  `RemoteManager` y añade su test focal. No cambia I1/I2, mTLS, C1/C2, wire,
  draft, ALPN, provider, identidad o policy.

### Inputs vinculantes

| Input | SHA-256 |
|---|---|
| `.cursorrules` | `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2` |
| `gateway-rs/ADR-0004-FEDERATED-MTLS.md` | `6bbf8b43e8227e09673cca8e7f832a0c4b5d1e9f8df7dc2c9f2abc697b600689` |
| `gateway-rs/ADR-0005-FEDERATED-AUTHORIZATION.md` | `8b4b9bb58f399e0a999343af78d61fdd85ea59a95cfa7d42dc96047882257a53` |
| `gateway-rs/ADR-0006-FEDERATION-CONCURRENCY.md` | `ca08d106e10b3e903cecd45292ce8b75d80e77c06c1c451d97d021306623baf3` |
| `gateway-rs/ADR-0007-CONTROLLED-MOQ-MIRROR.md` | `0085bdaa37cd3645a4a2c5a3163b0b096453b84f66635514fce6015d6bed25d8` |
| `infra/pki/config/identity-policy.json` | `d4005d735653854a2cb15346859203eacacd818cb4e452da9cd172e72895fa1f` |
| decision brief TP-SEC-PKI | `6cd115983ec128213e4dcdb717af1c6c3035a00924d55605d05e5767afec9979` |
| owner implementation report | `4551a89900841fe500fdcb98170ef14e4583d7b8faab6eb039885269ac136e30` |

El owner report precede al commit `0976b525...`: su hash de lock y su pathset no
describen el HEAD final. Esta revisión fija el snapshot real anterior y no usa ese
informe como sustituto de inspección independiente.

## Comandos y resultados read-only

| Comprobación | Resultado |
|---|---|
| `git rev-parse`, `git status --porcelain=v1 -z`, parent/tree/pathset y `sha256sum` en ambos worktrees | PASS; snapshots limpios, estables y sin tracking |
| `git diff-tree --check c719b84a...`, `0976b525...` y `4b50958c...` | PASS |
| inspección completa de ambos patches y source alcanzable de I1/I2/C1/C2 | PASS con F-01..F-04 |
| Rust/rustfmt 1.93.0, imagen local `teremoq-local-rust193-components:c2-review-20260828@sha256:f522c28d5beb21591f46e8c165030f70b32dd5b51107577ad196910e7147a007`; `cargo fmt --all -- --check` con source montado read-only y `--network none` | PASS |
| Rust/Cargo 1.93.0, imagen local `teremoq-step7-lab:rust-1.93-full@sha256:ba076cf0a26aa41efdd2f0f80687ef97009d1526680751456c19cc944dff1d0b`; `cargo metadata --locked --offline --no-deps` | PASS; pins exactos y `x509-parser` sin defaults/features |
| `gitleaks dir`, versión 8.30.1, imagen `zricethezav/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f`, `--network none --redact` | PASS; 766.68 KiB, cero leaks |
| `cargo test --locked --offline --test moq_derivative_contracts` sobre el pin Git final, source read-only y target externo | `BLOCKED_EXPECTED_UNPUBLISHED_PIN`: Cargo no puede obtener `4b50958...` de Git offline |
| intento de resolver el mismo snapshot mediante `[patch]` CLI read-only hacia el checkout local | No produjo test independiente: el cache local conservado no contiene `sha2 0.10.9`; el owner documenta que eliminó su Cargo home/targets efímeros. No se descargó ni instaló nada y no se repitió una reconstrucción grande. |

El owner report afirma PASS de los tests de identidad, composición raw/WT,
relay, Clippy, rustfmt, cargo-deny, cargo-audit y Gitleaks en un laboratorio que
ya fue eliminado. Se registra como evidencia de owner, no como reproducción
independiente de este dictamen. Los gaps F-01..F-04 son visibles en el snapshot
aunque esos tests existentes hayan pasado.

## Limitaciones y gates residuales

- El commit `4b50958c121edfa2d6778c0586b30a78ee3e6f83` no está publicado. Por tanto,
  el pin Git del producto **no es consumible por un builder limpio**. Este
  dictamen no autoriza publicar el derivado, el producto, una release, PR o tag.
- El batch criptográfico T sigue fuera de alcance y no queda autorizado por esta
  revisión. No se afirma que toda la cadena criptográfica esté saneada.
- La policy revisada es inicial/de desarrollo. No constituye una declaración de
  readiness comercial o productiva, ni sustituye renovación/revocación runtime,
  HSM/KMS, allowlists administrables o aprobación jurídica.
- No se editó ninguno de los dos worktrees, source, tests, manifests, lockfiles,
  refs o remotos. No hubo fetch, push, issue, PR, release, mensaje ni mutación
  remota.

## Veredicto

**CHANGES REQUIRED**

El flujo base es fail-closed y la capacidad N+1 no concede identidad, pero el
parser URI propio viola una decisión de seguridad vinculante y faltan las pruebas
de composición/adversariales obligatorias. F-01..F-04 deben cerrarse en un nuevo
snapshot owner y someterse a rerevisión TP-SEC-PKI. Este veredicto no autoriza
publicación.
