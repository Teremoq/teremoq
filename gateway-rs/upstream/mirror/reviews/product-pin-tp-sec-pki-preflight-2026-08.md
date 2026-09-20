<!--
SPDX-FileCopyrightText: 2026 Teremoq contributors
SPDX-License-Identifier: Apache-2.0
-->

# TP-SEC-PKI — preflight de seguridad del pin de producto

Fecha de revisión: 2026-08-28  
Rol: TP-SEC-PKI  
Objeto: simulación local del pin de gateway-rs al derivado integrado de moq-rs  
Naturaleza: revisión independiente, local y no productiva; sin commit, push, fetch, publicación ni mutación remota

## Hallazgos

### HIGH — H1: el producto compila con el derivado, pero no activa I1/I2/C1/C2

El pin por sí solo no cambia la frontera de seguridad ejecutada. El relay privado actual sigue construyéndose por el camino legacy:

- gateway-rs/examples/dev_mtls_moq_relay.rs:35-49 usa bind: Some, endpoints vacío y build_with_cache_idle_timeout.
- gateway-rs/examples/dev_mtls_moq_relay.rs:59-68 declara explícitamente que los límites de handshake y sesión no se aplican.
- gateway-rs/examples/dev_mtls_moq_relay.rs:70-76 ejecuta Relay::run, no BoundedRelay::run_until.
- gateway-rs/examples/dev_mtls_moq_relay.rs:126-166 sólo concede un scope por path y registra namespaces; no autentica un principal ni autoriza una operación exacta.

En el derivado, Endpoint::new sigue siendo deliberadamente legacy y no acotado
(moq-native-ietf/src/quic.rs:586-612). El constructor seguro exige endpoints
C1 explícitos y compartidos, bind ausente y un SessionAuthorizer
(moq-relay-ietf/src/relay.rs:199-215 y 478-531). Por tanto, sustituir las tres
dependencias y conservar el código actual produciría un binario compilable pero
sin las garantías que motivan el pin.

Cambio exigido a TP-RUST-DIST: cablear el relay 4443 con un único
HandshakeAdmission compartido, Endpoint::new_bounded_with_admission,
RelayConfig.bind = None, endpoints explícitos, mlog_dir = None,
build_required_bounded y BoundedRelay::run_until. Los límites C1/C2 deben ser
configurables, validados como no cero e independientes de identidad, IP, SNI y
path. El shutdown debe comprobar retorno acotado y gauges/inflight en cero.

Hay además una diferencia funcional que debe decidirse de forma explícita: el
producto usa un cache idle timeout de 5 s, mientras build_required_bounded usa
DEFAULT_CACHE_IDLE_TIMEOUT = 30 s
(moq-relay-ietf/src/local.rs:38; moq-relay-ietf/src/relay.rs:166-175 y
199-215). Se debe aceptar y documentar ese cambio o solicitar upstream una API
aditiva; no se debe volver al constructor legacy para conservar los 5 s.

### HIGH — H2: falta la política de identidad y autorización propiedad de Teremoq

No existe en gateway-rs ningún uso de SessionAuthorizer,
AuthenticatedSession, Operation, build_required ni una identidad URI
spiffe://. La verificación rustls actual comprueba cadena y EKU de cliente
(gateway-rs/examples/dev_mtls_moq_relay.rs:79-123), pero un certificado válido
recibe después acceso ReadWrite a /publish por la lógica de path
(líneas 126-149). Certificado válido no equivale a autorización.

El derivado ofrece la frontera adecuada:

- evidencia rustls ligada a la conexión y prestada al authenticate;
- AuthenticatedSession opaco y Debug redactado
  (moq-relay-ietf/src/authorization.rs:56-127);
- path tratado sólo como recurso solicitado
  (authorization.rs:272-305);
- operaciones exactas sobre namespace/prefix y segundo gate RelayPeer
  (authorization.rs:129-236 y 325-345);
- autenticación antes de MoQT, descarte de evidencia, autorización de path
  antes de SERVER_SETUP y mlog desactivado en required
  (relay.rs:861-970).

Cambio exigido a TP-RUST-DIST: implementar en gateway-rs una política
fail-closed propiedad del producto con este contrato:

1. Parsear únicamente el leaf verificado mientras se toma prestada
   VerifiedPeerEvidence. No copiar ni retener DER/PEM, subject, SAN, serial o
   fingerprint.
2. Aceptar exactamente una identidad Teremoq URI. Para gateway:
   spiffe://teremoq.local/gateway/<node-id>. Para relay: sólo la URI relay y una
   asignación de rol explícitamente aprobada.
3. Rechazar SAN ausente, malformado, de trust domain ajeno, ambiguo o múltiple,
   y cualquier incoherencia rol/operación.
4. Guardar en AuthenticatedSession sólo principal y rol mínimos.
   AuthenticatedSession::new_relay_peer sólo puede derivarse de la política
   autenticada; nunca de IP, SNI, ConnInfo, path o ConnectionTagger.
5. resolve_scope debe validar el tipo concreto de contexto, tratar el path
   canónico sólo como recurso y autorizar exactamente /publish. En required,
   Coordinator::resolve_scope y ConnectionTagger deben permanecer
   inalcanzables.
6. authorize debe comprobar cada namespace/prefix exacto antes de lookup,
   registro, cache, forwarding, respuesta o mutación. Un gateway puede
   publicar sólo su espacio autorizado y nunca recibe RelayPeer. Un relay dual
   debe pasar tanto el gate de operación normal como el segundo gate
   Operation::RelayPeer.
7. Los errores, tracing y labels deben ser constantes y de baja cardinalidad:
   sin principal, rol, certificado, path, namespace, prefix, track, URL ni
   Debug de requests.

No se autoriza un parser X.509 propio. Si rustls no expone el URI SAN requerido,
el owner debe seleccionar una biblioteca mantenida, fijar versión, revisar
licencia y procedencia, actualizar THIRD_PARTY/deny/lock según las reglas del
repositorio y someter ese delta a revisión independiente. Esta decisión no está
implementada ni aprobada por este preflight.

### HIGH — H3: las pruebas actuales no demuestran la composición requerida

Las pruebas del consumidor pasan, pero prueban la API legacy:

- gateway-rs/tests/mtls_quic.rs:184 y 192-199 usa Endpoint::new,
  server.accept y Session::accept.
- gateway-rs/tests/federation_concurrency.rs:41 y 52-58 usa el mismo camino;
  líneas 226-229 declaran handshake/session capacity unenforced y SPIFFE
  untestable.
- gateway-rs/tests/moq_relay_interop.rs:1006-1023 usa
  build_with_cache_idle_timeout y el coordinador legacy.
- gateway-rs/tests/support/pki.rs:46-93 y 203-227 genera EKU/SAN DNS/IP, pero
  no URI SAN de identidad.

Cambio exigido: añadir pruebas de producto, no sólo pruebas internas de
moq-rs, que atraviesen Relay::new_required_bounded para raw QUIC y
WebTransport. Deben demostrar con efectos independientes:

- C1 admission antes del trabajo criptográfico;
- evidencia I1 de la misma Connection;
- C2 admission antes de authenticate o estado MoQT;
- certificado válido seguido de denegación de authenticate con cero scope,
  coordinator, tagger, mlog y efecto;
- path canónico autorizado sólo como recurso y antes de SERVER_SETUP;
- publish autorizado sobre namespace exacto y segundo gate RelayPeer;
- N+1 en ambos transportes con código público 0x3 y razón fija
  relay session capacity reached, sin segunda autenticación ni efecto;
- ausencia, SAN adversarial, rol equivocado y namespace/prefix equivocado
  fail-closed;
- cancelación, error, panic/drop y shutdown recuperan permisos y dejan gauges
  en cero;
- identidades concurrentes no comparten contexto;
- canarios de certificado/contexto/path/namespace/prefix/track/URL no aparecen
  en tracing, mlog, errores ni labels.

Los tests legacy de 4433 pueden conservarse, pero deben quedar nombrados y
separados del relay privado 4443. No pueden presentarse como prueba del modo
required.

### MEDIUM — H4: el rev exacto aún no es consumible como pin Git reproducible

El derivado está en:

- commit 89cb1798644c32aef06cc625f097cd9acb203417;
- tree cccd0d60c9ebfe191dca9d73e7ab8b27ae4d4ea5;
- branch local teremoq/integration-draft16-bf87128-local;
- sin upstream/tracking y sin tag en el tip.

La simulación por path es válida para preflight local, pero no prueba que Cargo
pueda obtener el rev desde el remoto. No se usó red por mandato. El pin futuro
queda bloqueado hasta una publicación autorizada y una verificación posterior
de que el remoto resuelve exactamente el commit y tree anteriores.

Después de esa verificación, el cambio de Cargo.toml debe ser atómico en
gateway-rs/Cargo.toml:16, :17 y :36, conservando las restricciones de versión y
apuntando las tres dependencias a
https://github.com/Teremoq/moq-rs-teremoq con rev completo
89cb1798644c32aef06cc625f097cd9acb203417. Cargo.lock debe resolver los cuatro
paquetes del workspace MoQ —incluido moq-api transitivo— al mismo origen y
commit. No se acepta branch, tag móvil, rev abreviado ni mezcla con bf87128.

### MEDIUM — H5: el resultado RustSec no autoriza el batch criptográfico T

Con la base local fijada de RustSec, tanto el lock actual del producto como el
lock simulado informan cero vulnerabilidades y las mismas dos advertencias de
mantenimiento:

- RUSTSEC-2024-0436, paste 1.0.15;
- RUSTSEC-2025-0134, rustls-pemfile 2.2.0.

El grafo consumidor simulado conserva, entre otros, aws-lc-rs 1.18.0,
aws-lc-sys 0.44.0, bytes 1.12.1, quinn 0.11.11, quinn-proto 0.11.17,
quinn-udp 0.5.15, ring 0.17.14, rustls 0.23.43,
rustls-webpki 0.103.15 y web-transport-quinn 0.11.12. El pin por path no añadió
ni cambió transitivas en el lock consumidor; sólo eliminó cuatro campos source
Git al convertirlos en paquetes path.

El resultado está limitado al snapshot offline de la DB. T continúa siendo una
decisión criptográfica separada y no autorizada; no se declara la cadena
criptográfica totalmente saneada.

### INFO — H6: secretos y fixtures están delimitados, con dos detecciones explicadas

Gitleaks 8.30.1 por digest local inmutable no encontró leaks en el source,
examples o tests de gateway-rs del laboratorio, ni en source/tests de
moq-native-ietf y moq-transport.

Hubo dos matches redactados y explicables:

- moq-relay-ietf/src/tls.rs:115 contiene sólo el delimitador
  BEGIN PRIVATE KEY dentro de un comentario del parser; el archivo no cambió
  respecto a bf87128.
- moq-relay-ietf/tests/data/c2/server.key.pem:1 es una clave sintética pública
  test-only. README.md la prohíbe para despliegue, SHA256SUMS fija su
  procedencia y tiene sidecar REUSE. El match es correcto para material con
  forma de clave, pero no es un secreto operativo.

Los fixtures I1/I2/C1/C2 están documentados como públicos y sintéticos,
separados bajo tests/data, con inventarios SHA-256 y sidecars. La comprobación
de checksums pasó para I2, C1 y los tres PEM C2. El laboratorio excluyó
.teremoq-dev, target, caches, pyc y __pycache__, por lo que no copió claves
runtime del producto.

No se debe añadir una exclusión global de private-key para silenciar el
fixture. Una eventual allowlist debe estar limitada al fingerprint y path
exactos del fixture público y conservar la detección para código y runtime.

## Binding e integridad

### Fuentes de gobierno leídas

- /home/jimbomilk/teremoq/.cursorrules:
  88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2
- ADR-0004:
  6bbf8b43e8227e09673cca8e7f832a0c4b5d1e9f8df7dc2c9f2abc697b600689
- ADR-0005:
  8b4b9bb58f399e0a999343af78d61fdd85ea59a95cfa7d42dc96047882257a53
- ADR-0006:
  ca08d106e10b3e903cecd45292ce8b75d80e77c06c1c451d97d021306623baf3
- ADR-0007:
  0085bdaa37cd3645a4a2c5a3163b0b096453b84f66635514fce6015d6bed25d8

### Producto

- gateway-rs/Cargo.toml:
  1caa40574d12ebb4aa9cd03cc30d32f75edd8e9572e6d4876238f491c6e3f3de
- gateway-rs/Cargo.lock:
  dd6ee5615630d788a351c4e3b395de0851fee41b34177823393d35d23a894316

Ambos hashes se verificaron de nuevo tras las pruebas. El producto no fue
editado por esta revisión.

### Derivado

- commit:
  89cb1798644c32aef06cc625f097cd9acb203417
- tree:
  cccd0d60c9ebfe191dca9d73e7ab8b27ae4d4ea5
- Cargo.lock:
  d6196fd8f31ea3b2cabbdb0e57546810643f344567f3e358ee3c000b3e2b59f5
- status-z:
  e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
  (vacío)

bf87128affd316463e5dcc7599a45001f222b6de es ancestro del tip. El diff
bf87128..89cb contiene 66 paths; el listado ordenado por Git tiene SHA-256
a2f08f463e5dcb90181e9944a6dd8799dbfdcc552c00b36dda62681197037cfb.
git diff --check pasó. El único manifest modificado es
moq-relay-ietf/Cargo.toml, donde rustls 0.23.31 se añade sólo como
dev-dependency para pruebas. Los metadatos LICENSE/LICENSES/REUSE/.reuse no
cambian. El tip 89cb modifica exclusivamente dos assertions de tests:
moq-transport/src/serve/subgroup.rs y tracks.rs.

### Laboratorio

Se creó /home/jimbomilk/teremoq-gateway-pin-security-lab con modo 0700 a partir
del producto, excluyendo runtime y caches. Sólo se sustituyeron por path las
tres dependencias MoQ:

- Cargo.toml simulado:
  f44fafb4d4c9101c67440af73780e07076c9a50bba4ea6ad0d9e7b4b5a759384
- Cargo.lock simulado:
  857889695a109c4315a3f1ea42ab530a3bd6b39e7d6920299c825579c60e4f9b

El diff de lock frente al producto elimina exactamente cuatro campos source de
los paquetes MoQ y no cambia versiones, checksums ni dependencias transitivas.
Un rsync dry-run, excluyendo Cargo.toml/Cargo.lock y los mismos artefactos
runtime/cache, no encontró divergencias entre copia y producto.

## Modelo de amenazas y resultado de los gates

1. Agotamiento pre-handshake: la API C1 existe y es fail-closed, pero el
   producto no la construye. Gate de producto: FAIL.
2. Certificado válido sin autorización: I2 permite denegar antes de estado MoQT,
   pero no hay authorizer Teremoq. Gate de producto: FAIL.
3. Confusión identidad/recurso: la API mantiene path fuera de identidad; el
   producto actual decide sólo por path. Gate de producto: FAIL.
4. Agotamiento de sesiones: C2 existe y compone con required, pero el producto
   usa Relay::run. Gate de producto: FAIL.
5. Relay-peer: la API exige contexto autenticado y segundo gate; el producto no
   clasifica ni autoriza roles. Gate de producto: FAIL.
6. Raw QUIC/WebTransport: el derivado contiene soporte y pruebas internas; no
   existe prueba positiva de consumidor que atraviese la composición completa.
   Gate de producto: FAIL.
7. Redacción: el derivado protege evidencia/contexto y desactiva mlog en
   required; el producto no activa required. Los scans no encontraron secretos
   operativos. Gate estático: PASS; gate runtime de producto: pendiente.
8. Procedencia: commit/tree y DCO son verificables localmente; resolución desde
   remoto no es verificable sin publicación. Gate de pin Git: BLOCKED por
   procedencia externa, sin realizar red.

La capacidad no concede identidad ni autorización. C1 y C2 son controles de
recursos; mTLS/I1 autentica evidencia de conexión; la política I2 decide
principal, rol, operación y namespace. El owner debe mantener esas fronteras
separadas.

## Validaciones ejecutadas

Entorno de compilación:

- imagen:
  teremoq-step7-lab:rust-1.93@sha256:315ab1185640250a0bc5143796e5098f90e5ece1041cdf4fabf99a80ff1e2c30
- rustc 1.93.0 (254b59607 2026-01-19);
- cargo 1.93.0 (083ac5135 2025-12-15);
- network none, fuentes y derivado montados read-only, target efímero.

Resultados:

- cargo check --locked --offline --all-targets:
  PASS sobre el consumidor con el pin por path.
- cargo test --locked --offline --test mtls_quic --test
  federation_concurrency --test moq_relay_interop:
  PASS; 8 mTLS + 2 concurrency + 2 interop activos, 0 fallos; 1 hostile-network
  ignorado porque exige harness aislado.
- cargo fmt --all -- --check:
  PASS.
- cargo-deny 0.20.2, SHA-256
  d76b21d48f26ee6a1b29e72a72b698140ad8ee2a553f5a2613bce9e7f43b6fae,
  con cargo-deny --frozen check licenses bans sources:
  PASS. La allow de la fuente Cloudflare queda sin match en la simulación path,
  como era esperable; no hubo fallo de licencia/source.
- cargo-audit 0.22.2, SHA-256
  507532dd1ec54506ba6c3839b55a5ab0b47470c9667e9134926be35b10e231a3:
  PASS con cero vulnerabilidades y las dos advertencias informativas H5.
- DB RustSec local:
  commit a7bfe16948bf6f3ee25bdee4822209f87da21b80,
  tree 1152ddcadf432f7bf97746e51fb7f2d9e5968c49, limpia.
  Los JSON de producto y laboratorio fueron byte-idénticos en la misma
  ejecución, SHA-256
  174d03c737fb6f5232bec9704408c6c8375e3532f5b6b2e52f671f975d31d7a1.
- Gitleaks v8.30.1:
  zricethezav/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f,
  network none, source read-only, redacción 100 %. Resultado detallado en H6.
- sha256sum -c:
  PASS para inventarios C1 e I2 y para los tres archivos PEM C2. Las tres
  líneas adicionales C2 son hashes de DER de procedencia, no nombres de
  archivos que deban existir en ese directorio.
- git merge-base --is-ancestor, git diff --check, pathset, refs locales,
  manifest/lock diff y trailers:
  PASS con las limitaciones de publicación descritas.

Intento focal del lock propio del derivado:

    cargo test --locked --offline -p moq-relay-ietf --lib i2_tests::<caso> -- --exact

No llegó a compilar porque los caches locales no contienen
quinn-proto 0.11.15 y --offline rechazó descargarlo. Se probaron caches
efímeros aislados; los primeros intentos tampoco alcanzaron código por una
ruta temporal inexistente y por PATH reemplazado por bash login. Esos defectos
de preparación se corrigieron antes de identificar el bloqueo real. No se
repitió con red ni se alteró Cargo.lock. Esto no invalida el cargo check y los
12 tests activos del consumidor, que resuelven quinn-proto 0.11.17, pero impide
presentar esta ejecución como reproducción independiente de los tests internos
I2 contra el lock exacto del derivado.

## Procedencia y DCO

La serie desde bf87128 hasta 89cb contiene nueve commits: I1, I2, Q, C1, U1,
C2, merge de source, merge Q/U1 y corrección E0308. En los nueve:

- autor: Jose María <12586102+jimbomilk@users.noreply.github.com>;
- trailer Signed-off-by idéntico al autor;
- DCO local: PASS.

git log informa GPG status N para los nueve commits. La firma criptográfica de
commit es una propiedad distinta del DCO; no se infiere una firma inexistente.
El reporte queda sin commit por mandato, de modo que todavía no le corresponde
un trailer de commit. Quien lo integre deberá firmar su commit con
Signed-off-by conforme a .cursorrules.

## Condiciones comprobables para una nueva revisión

TP-RUST-DIST debe entregar, sin mezclar cambios no relacionados:

1. publicación autorizada y pin Git atómico de los tres crates al rev completo,
   con lock coherente y verificación post-publicación del tree;
2. authorizer Teremoq fail-closed e inventario de cualquier parser reutilizado;
3. relay 4443 construido exclusivamente por new_required_bounded con endpoints
   C1 compartidos y shutdown C2 acotado;
4. separación explícita del servicio browser/legacy 4433;
5. tests reales raw QUIC/WebTransport y N+1 con los efectos independientes
   enumerados en H3;
6. canarios de redacción y ausencia de identidad en labels/errores;
7. decisión documentada del cambio de cache idle timeout;
8. cargo check/test/fmt, cargo-deny, cargo-audit offline reproducible, REUSE y
   Gitleaks sin fallos no explicados;
9. nueva revisión independiente del diff de producto y del lock final.

No se autoriza implementación, integración, publicación, C2 adicional ni batch
T mediante este documento.

## Estado

OWNER_CHANGES_REQUIRED

