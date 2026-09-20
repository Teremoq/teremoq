<!--
SPDX-FileCopyrightText: 2026 Teremoq contributors
SPDX-License-Identifier: Apache-2.0
-->

# TP-SEC-PKI decision brief: identidad URI SAN para el product pin

Fecha de revisión: 2026-08-28  
Rol: `TP-SEC-PKI`  
Modalidad: revisión independiente, read-only; sin implementación, cambios de
dependencias, commit, push o publicación.

## Decisión ejecutiva

**El patch owner no puede considerarse autorización de identidad Teremoq.** Su
`authenticate` sólo comprueba que la cadena verificada no esté vacía y convierte
cualquier certificado cliente aceptado por la CA en el mismo marcador
`VerifiedFederatedPublisher`
(`product-pin-owner-candidate-2026-08.patch:255-268`). Eso conserva el orden I1/I2,
pero no implementa `certificado verificado -> principal -> rol -> operación ->
namespace exacto`.

No existe hoy una API pública directa de las dependencias declaradas por
`gateway-rs` que entregue el URI SAN. `rustls 0.23.43` sólo expone el leaf como
`CertificateDer`; su `ParsedCertificate` público encapsula el parser interno y
expone únicamente SPKI, no SAN. El wrapper interno es deliberadamente privado,
por lo que hacer downcast, acceder a campos privados o depender de su layout no
es aceptable. Esto se confirma en el
[source oficial fijado de rustls 0.23.43](https://raw.githubusercontent.com/rustls/rustls/v/0.23.43/rustls/src/webpki/verify.rs).

`rustls-webpki 0.103.15` ya está resuelto y activo por `rustls`, y sí ofrece las
APIs públicas `EndEntityCert::try_from` y `valid_uri_names`. Sin embargo,
`valid_uri_names` usa un `filter_map`: omite errores al recorrer `GeneralName` y
omite URI no UTF-8. Por ello, un leaf con un URI válido y otra entrada URI
malformada resulta indistinguible de un leaf con un único URI válido. Aunque el
parser rechaza extensiones SAN duplicadas, esa pérdida de errores impide probar
el requisito fail-closed de SAN íntegro/no ambiguo. La conducta está en el
[source oficial de `Cert::valid_uri_names`](https://raw.githubusercontent.com/rustls/webpki/v/0.103.15/src/cert.rs).

**Recomendación:** previa autorización expresa del usuario, declarar como
dependencia directa de producción:

```toml
x509-parser = { version = "=0.18.1", default-features = false }
```

La coordenada y su checksum ya están fijados en el lock actual, pero el crate no
está activo en el grafo alcanzable. Convertirlo en dependencia directa sigue
siendo un cambio material de supply chain y de superficie de parsing; este
informe no lo autoriza ni lo implementa.

La recomendación exige usar sólo parsing estructural público, sin `verify`,
`verify-aws` ni `validate`; rustls continúa siendo el único responsable de
cadena, firma, vigencia, EKU y posesión de clave. El parser se invoca una sola
vez, sobre el leaf ya verificado de la misma conexión, después de C2 admission y
antes de scope, `SERVER_SETUP`, Producer/Consumer y cualquier efecto MoQT.

## Hallazgos que bloquean al owner

### HIGH — identidad ausente en el patch candidato

En `product-pin-owner-candidate-2026-08.patch:260-268`, cualquier cadena no vacía
produce el mismo contexto opaco. No se comprueban:

- URI SAN;
- trust domain `teremoq.local`;
- rol `gateway` o `relay`;
- `node-id`;
- asociación principal/namespace;
- ambigüedad o malformación de SAN.

Además, `patch:292-297` permite `DiscoverNamespace` y `TrackStatus` al marcador
publisher sin evidencia en el patch de que esas operaciones sean necesarias
para el publisher Teremoq. La política mínima recomendada las deniega. Si una
prueba de protocolo demuestra que alguna es imprescindible, deberá aprobarse y
documentarse como permiso independiente sobre el mismo namespace exacto; no se
debe ampliar por conveniencia.

### HIGH — `rustls-webpki::valid_uri_names` no permite rechazo integral

La API es mantenida, pública y con mínima variación del grafo, pero no devuelve
`Result` por entrada. Una entrada inválida se descarta silenciosamente. Contar
los valores producidos no detecta el caso `URI válido + URI inválido`. Esto no
satisface el contrato de rechazar SAN múltiple, ambiguo o malformado.

La versión `0.103.15` es exacta, tiene MSRV 1.71, licencia ISC y no contiene
`unsafe` en su source local. La release fijada está publicada en el
[repositorio oficial](https://github.com/rustls/webpki/releases/tag/v%2F0.103.15),
y la vulnerabilidad CRL publicada como GHSA-82j2-j2ch-gfr8 quedó corregida desde
`0.103.13`, por lo que `0.103.15` no está afectada
([advisory oficial](https://github.com/rustls/webpki/security/advisories/GHSA-82j2-j2ch-gfr8)).
Nada de ello corrige la insuficiencia semántica del iterador para esta política.

### MEDIUM — promover `x509-parser` requiere límites y disciplina de redacción

`x509-parser 0.18.1` ofrece las piezas públicas necesarias:

- parsing DER zero-copy con remainder, que debe quedar vacío;
- `subject_alternative_name()`, que usa búsqueda única y devuelve error ante
  extensiones duplicadas;
- `GeneralName::URI(&str)` y `GeneralName::Invalid`, de modo que el caller puede
  rechazar toda entrada no parseable.

Estas propiedades se observan en el
[source oficial de `X509Certificate`](https://raw.githubusercontent.com/rusticata/x509-parser/33b15d2db5a19b15c17bb15fa57b08691316ee95/src/certificate.rs)
y de
[`GeneralName`](https://raw.githubusercontent.com/rusticata/x509-parser/33b15d2db5a19b15c17bb15fa57b08691316ee95/src/extensions/generalname.rs).
La propia documentación advierte que el formato del URI no se valida: Teremoq
debe aplicar después su gramática de identidad con el `url 2.5.8` ya directo.

El crate deriva `Debug`/`Display` para estructuras que contienen subject,
serial, SAN y bytes inválidos. En particular, `GeneralName::Invalid` puede
formatear bytes. Por tanto, quedan prohibidos `?` con contexto que preserve el
error, `{:?}`, `{}`, `anyhow!(error)`, tracing del resultado, métricas por error
y asserts que impriman el valor. Todo fallo se reduce inmediatamente a un error
Teremoq fijo y de baja cardinalidad.

El parser y sus dependencias principales `asn1-rs` y `der-parser` declaran
`forbid(unsafe_code)` y el source local revisado contiene cero menciones de
`unsafe`. Su defensa interna no sustituye límites del producto: `der-parser
10.0.0` admite objetos de hasta `2^32-1` bytes y una recursión máxima de 50. El
owner debe imponer límites menores antes de parsear.

## Inventario del snapshot y alcanzabilidad

| Elemento | Estado exacto | Evaluación |
|---|---|---|
| `rustls 0.23.43` | directo; checksum Cargo `0283386ce02abc0151e1761d08802dfe86c173b0b494af5cbc086574e453da06` | verifica TLS; no expone URI SAN |
| `rustls-pki-types 1.15.1` | directo; checksum `2f4925028c7eb5d1fcdaf196971378ed9d2c1c4efc7dc5d011256f76c99c0a96` | `CertificateDer` es contenedor de bytes; no parser |
| `rustls-webpki 0.103.15` | transitivo activo; checksum `f3c3cf1d8b1e7d4927e2d154c3fcb02979afb9939629c62cd9048d4f07b60ac2` | URI pública, pero errores filtrados; no apto solo |
| `webpki 0.22.4` | resuelto histórico | validación de nombres, no enumeración pública mantenida de URI; no usar |
| `rcgen 0.14.9` | dev-dependency | generador de certificados/fixtures; no parser de leaf productivo |
| `x509-parser 0.18.1` | en lock, no alcanzable; checksum `d43b0f71ce057da06bc0851b23ee24f3f86190b07203dd8f567d0b706a185202` | opción recomendada tras autorización |
| `url 2.5.8` | directo; checksum `ff67a8a4397373c3ef660812acab3268222035010ab8680ec4215f38ba3d0eed` | validación URI posterior; comparar forma canónica exacta |

La inspección `cargo tree --locked --offline -i` con Rust/Cargo 1.93.0 mostró
`warning: nothing to print` para `x509-parser@0.18.1`, y mostró
`rustls-webpki@0.103.15 <- rustls@0.23.43 <- gateway-rs`. Un crate transitivo no
puede nombrarse desde `gateway-rs` sin declararlo directamente; tampoco es
aceptable aprovechar una reexportación privada.

## Comparación mínima de alternativas mantenidas

| Opción | API y fail-closed | Parsing/DoS | `unsafe`, MSRV y pin | Decisión |
|---|---|---|---|---|
| `rustls-webpki =0.103.15` directo | API pública mínima, duplicate SAN extension se rechaza; `valid_uri_names` oculta entradas erróneas/no UTF-8 | parser acotado internamente en varias secuencias, pero la ambigüedad no es observable | cero `unsafe` observado; MSRV 1.71; ISC; exact pin + checksum | **No seleccionar** mientras el iterador no sea fallible |
| `x509-parser =0.18.1`, defaults off | API pública, remainder, extensión única, URI visible y `Invalid` visible; permite rechazo total | zero-copy y recursión limitada, pero requiere límites Teremoq previos y nunca formatear objetos/errores | `forbid(unsafe_code)`; MSRV 1.67.1; MIT OR Apache-2.0; exact pin, checksum y VCS `33b15d2db5a19b15c17bb15fa57b08691316ee95` | **Recomendado, sujeto a autorización e inventario** |
| RustCrypto `x509-cert 0.3.0` | API pública DER/GeneralName, mantenida | parser nuevo no presente en lock; requiere auditoría propia y de nuevos crates | MSRV 1.85; MIT OR Apache-2.0; fijable | **No seleccionar ahora:** añade coordenadas sin ventaja necesaria |

La metadata exacta de `x509-parser 0.18.1` fija versión, licencia, MSRV y features
en el
[commit de procedencia oficial](https://github.com/rusticata/x509-parser/commit/33b15d2db5a19b15c17bb15fa57b08691316ee95).
El README oficial documenta diseño defensivo, fuzzing y objetivo panic-free
([source](https://raw.githubusercontent.com/rusticata/x509-parser/33b15d2db5a19b15c17bb15fa57b08691316ee95/README.md));
es evidencia favorable, no una garantía. El repositorio no contiene una
`SECURITY.md` en el paquete publicado revisado, lo que queda como riesgo de
mantenimiento a vigilar.

`x509-cert 0.3.0` es mantenido por RustCrypto y declara MSRV 1.85 y licencia
MIT/Apache en su
[manifest oficial](https://raw.githubusercontent.com/RustCrypto/formats/master/x509-cert/Cargo.toml),
pero no está en el lock del producto y su adopción abriría una revisión de
procedencia/transitivas nueva. La política del proyecto RustCrypto sólo soporta
la release más reciente
([SECURITY.md oficial](https://raw.githubusercontent.com/RustCrypto/formats/master/SECURITY.md)).

## Contrato de extracción recomendado

El owner debe cumplir todos estos pasos; cualquier fallo devuelve únicamente
`AuthenticationRejected` o un equivalente fijo y redactado:

1. Recibir `VerifiedPeerEvidence` prestado de I1, ya ligado a esa misma
   `quinn::Connection`. `Absent`, cadena vacía o error I1 se rechaza.
2. Antes de tocar el parser, comprobar con aritmética checked:
   `chain.len() <= 8`, leaf DER `<= 16 KiB` y suma de la cadena `<= 64 KiB`.
   Son límites iniciales conservadores para las identidades Smallstep de
   Teremoq; deben ser configurables sólo a través de valores máximos validados,
   nunca por el peer.
3. Parsear únicamente `certificates()[0]`; nunca buscar identidad en un
   intermediate. Exigir remainder vacío.
4. Exigir exactamente una extensión SAN. La ausencia, duplicación o
   `ParsedExtension` inválida se rechaza.
5. Recorrer todas las `GeneralName`. Cualquier `Invalid` se rechaza. Exigir
   exactamente una `URI`; cero o dos o más se rechazan incluso si son iguales.
6. Para rol gateway, rechazar SAN distintos de URI. Para rol relay, permitir
   además sólo DNS e IP porque el perfil servidor de Task 01 los necesita;
   esos valores se ignoran para identidad. Rechazar `otherName`, RFC822,
   directoryName, X400, EDI y registeredID.
7. Parsear la única URI con `url 2.5.8`, pero aceptar sólo si el texto original
   coincide byte a byte con la reconstrucción canónica Teremoq. No aceptar
   normalización, equivalencias de mayúsculas, IDNA ni percent-decoding.
8. Derivar y conservar sólo `Principal { role, node_id }`. No clonar ni retener
   DER, PEM, subject, issuer, SAN completo, serial o fingerprint; no retener el
   objeto `X509Certificate` ni errores del parser más allá del stack de
   `authenticate`.
9. Construir `AuthenticatedSession::new` sólo para gateway y
   `AuthenticatedSession::new_relay_peer` sólo para relay habilitado por policy.
   El path, IP, SNI, `ConnInfo` y `ConnectionTagger` no participan.
10. Resolver el path canónico exacto `/publish` como recurso, después de
    autenticar, y autorizar cada operación/namespace antes del primer efecto.

El parser auxiliar no debe volver a verificar firmas ni cadenas. Activar
`verify` o `verify-aws` duplicaría responsabilidad criptográfica y podría
cambiar `ring`/AWS-LC; queda expresamente fuera de esta decisión. El batch T
continúa separado y no autorizado.

## Gramática de identidad Teremoq

Se aceptan exactamente estas formas ASCII:

```text
spiffe://teremoq.local/gateway/<node-id>
spiffe://teremoq.local/relay/<node-id>
```

Reglas:

- scheme literal minúsculo `spiffe`;
- authority literal minúscula `teremoq.local`;
- sin userinfo, password, port, query o fragment;
- path con exactamente dos segmentos no vacíos: rol y node-id;
- sin trailing slash, `.`/`..`, `%`, escapes, Unicode ni controles;
- `node-id` ASCII `[A-Za-z0-9._-]{1,64}`;
- el input debe ser idéntico a la forma reconstruida; no alias ni
  canonicalización permisiva.

Estas reglas son compatibles con las restricciones del
[SPIFFE ID standard](https://github.com/spiffe/spiffe/blob/main/standards/SPIFFE-ID.md),
pero son deliberadamente más estrictas y específicas de Teremoq. La
especificación X509-SVID exige exactamente un URI SAN y rechaza múltiples URI
SAN, aunque permite otros tipos SAN
([X509-SVID oficial](https://github.com/spiffe/spiffe/blob/main/standards/X509-SVID.md)).
Teremoq usa por ahora URI SAN **estilo SPIFFE** con Smallstep; este cambio no
despliega SPIRE, Workload API, bundles SPIFFE ni federation SPIFFE, y no debe
presentarse como conformidad X509-SVID completa.

## Política Teremoq recomendada

### Gateway publisher

- Principal: `Gateway(node_id)` únicamente desde
  `spiffe://teremoq.local/gateway/<node-id>`.
- Perfil TLS: leaf `gateway-client`, ya validado por rustls para `clientAuth`.
- Scope de conexión: sólo path exacto `/publish`.
- Tabla inicial explícita: `gateway-dev-1 -> teremoq/live`.
- Operaciones permitidas: `Publish` y `PublishNamespace`, sólo cuando el
  `TrackNamespace` sea exactamente `teremoq/live`.
- Operaciones denegadas: `Subscribe`, `SubscribeNamespace`,
  `DiscoverNamespace`, `TrackStatus` y todo `RelayPeer`.
- Futuro: usar una allowlist de configuración `principal -> conjunto acotado de
  namespaces exactos`. No derivar permisos automáticamente del node-id y no
  usar `starts_with`, wildcard o comparación textual de prefix.

La tabla inicial conserva el namespace operativo actual del producto sin
concederlo a todo certificado de la CA. Si varios gateways deben compartirlo,
esa compartición debe ser una decisión explícita en la allowlist, no una
consecuencia de pertenecer al trust domain.

### Relay y relay-to-relay

- Principal: `Relay(node_id)` únicamente desde
  `spiffe://teremoq.local/relay/<node-id>`.
- Un cert `relay-server` con sólo `serverAuth` no puede autenticar como cliente
  relay-peer. El futuro cert `relay-peer` es dual `serverAuth + clientAuth`
  porque la misma entidad puede aceptar y originar conexiones relay-to-relay.
- Estado inicial recomendado para product pin: rol relay **denegado por
  defecto** hasta que exista credential `relay-peer`, mapping y prueba E2E
  aprobados.
- Al habilitarlo, la configuración debe mapear cada relay a operaciones y
  namespaces/prefixes tipados y exactos. No existe permiso genérico de relay.
- Cada acción necesita dos decisiones positivas: su gate normal y el segundo
  gate `RelayPeer { operation }`, sobre la misma operación y recurso. Sólo
  entonces puede ocurrir lookup, registro, cache, forwarding o respuesta.
- DNS/IP SAN pueden existir para la función servidor, pero nunca conceden
  principal, rol, routing interno o permiso.

Capacidad C1/C2, identidad y autorización son controles ortogonales. Un slot
disponible no autentica; un certificado válido no autoriza; un rol relay no
concede una operación; una operación no concede otro namespace.

## Pruebas adversariales obligatorias para el owner

### Parser y gramática

- evidencia ausente, cadena vacía, más de 8 certificados, leaf de 16 KiB + 1 y
  suma de 64 KiB + 1;
- DER truncado, trailing DER, extensión SAN ausente, dos extensiones SAN y SAN
  con contenido inválido;
- cero URI, dos URI diferentes, dos URI iguales y URI válido junto con
  `GeneralName::Invalid`;
- URI sólo en intermediate;
- scheme/trust domain/rol ajenos o con mayúsculas;
- userinfo, port, query, fragment, `%` encoding, Unicode/IDNA, slash extra,
  trailing slash, segmento vacío, `.`/`..`;
- node-id vacío, de 65 bytes, con slash, backslash, espacio, CR/LF, NUL o
  caracteres fuera de `[A-Za-z0-9._-]`;
- gateway con DNS/IP/otherName y relay con un SAN no URI/DNS/IP;
- certificado parseable pero no validado por rustls nunca alcanza el parser de
  identidad en el flujo required.

Los fixtures serán sintéticos, públicos y test-only, creados con `rcgen 0.14.9`
ya fijado o con Smallstep Task 01. Deben incluir README de procedencia y no
parecer secretos productivos. Para duplicados/malformaciones se permiten
extensiones custom de `rcgen` o mutaciones test-only acotadas; no un parser ni
una CA de producción propios.

### Autorización y composición

- gateway válido `gateway-dev-1` + `/publish` + `Publish(teremoq/live)` y
  `PublishNamespace(teremoq/live)` pasan en raw QUIC y WebTransport;
- mismo cert con namespace distinto falla antes de métricas, lookup, registro,
  forwarding, respuesta o mutación;
- cert válido de la misma CA sin URI, con URI relay o con otro gateway no
  allowlisted falla antes de scope/`SERVER_SETUP`/app state;
- gateway no puede subscribir, descubrir, emitir `TrackStatus` ni convertirse
  en relay-peer;
- `relay-server` presentado como cliente falla en TLS por EKU; `relay-peer`
  sólo pasa cuando su mapping y ambos gates lo autorizan;
- dos identidades concurrentes con namespaces distintos no comparten
  `AuthenticatedSession`, principal ni policy;
- N+1 raw/WT sigue rechazándose por C1/C2 antes de una segunda autenticación y
  sin convertir capacidad en identidad;
- fallos de parser y policy producen un código/razón pública fija, sin valores
  derivados del peer.

### Redacción y retención

Usar canarios independientes en DER, subject, URI, node-id, path, namespace,
prefix y URL. Exigir cero canarios y cero nombres de tipos protegidos en
`Debug`, `Display`, `tracing`, `anyhow`, mlog/qlog, métricas y respuestas. Las
pruebas no deben usar asserts que impriman los objetos del parser o el contexto.
Después de `authenticate`, sólo puede permanecer el principal mínimo; una prueba
de lifecycle debe demostrar que no existe `Arc`, cache o task que retenga el
leaf o el objeto parseado.

## Gates de aceptación para Task 05 / owner

1. Autorización explícita del usuario para el dependency edge productivo y su
   licencia.
2. `x509-parser =0.18.1`, `default-features = false`, sin features de
   verificación y sin otra modificación de provider TLS.
3. Lock actualizado de forma reproducible; versión/checksum esperados sin
   coordenadas no explicadas; `DEPENDENCIES.md`/inventario/license gate
   actualizados.
4. Límites de chain/DER previos al parser; `cargo test`, clippy, rustfmt,
   cargo-deny y cargo-audit con Rust 1.93.0 fijado y offline.
5. Todos los negativos de parser, policy, redacción, raw/WT y concurrencia
   anteriores PASS.
6. El authorizer usa exclusivamente evidencia verificada de la misma conexión,
   no path/IP/SNI/tagger, y no existe fallback required -> legacy.
7. DCO/procedencia del commit derivado y publicación del pin siguen siendo
   gates separados; este brief no autoriza commit, push ni publicación.

## Preguntas concretas para decisión del usuario

1. ¿Autoriza añadir a las dependencias productivas
   `x509-parser = { version = "=0.18.1", default-features = false }`, licencia
   `MIT OR Apache-2.0`, con inventario legal y sin features criptográficas?
2. ¿Confirma la política inicial exacta
   `gateway-dev-1 -> Publish + PublishNamespace -> teremoq/live`, denegando
   `DiscoverNamespace` y `TrackStatus` mientras no exista una prueba de
   necesidad protocolaria?
3. ¿Confirma que todo rol `relay` permanezca default-deny en el product pin y se
   habilite sólo en un cambio posterior con certificado `relay-peer`, allowlist
   exacta y segundo gate E2E?
4. ¿Aprueba como límites iniciales máximos 8 certificados por cadena, 16 KiB
   para el leaf y 64 KiB para la cadena total, con rechazo fijo antes del
   parser?
5. Para múltiples gateways productivos, ¿la policy se administrará mediante
   una allowlist explícita principal -> namespace exacto, o se pretende que
   compartan deliberadamente `teremoq/live`? La segunda opción amplía el radio
   de compromiso y debe constar como decisión de riesgo.

## Evidencia y reproducibilidad

Inputs leídos íntegramente:

| Input | SHA-256 |
|---|---|
| `.cursorrules` | `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2` |
| `product-pin-owner-preflight-2026-08.md` | `80e4a31b5fa298a38bc040fcf513e019a20e5943f1824f71632711d253e8c017` |
| `product-pin-tp-oss-sc-preflight-2026-08.md` | `6316de0f9d8a7c5f399528b9de84af228f756e1c35851e49ae1749214429a1bb` |
| `product-pin-tp-platform-chaos-preflight-2026-08.md` | `ccf93bc472a846f207a72cf3d48fffbb232b7a9f757b8c7cfa1f08b90c849c09` |
| `product-pin-tp-sec-pki-preflight-2026-08.md` | `24daf315d0ec3e0d81cb5da699883dbca62a4b9c4ff5fe7ffb987bc5cfb7d43c` |
| `product-pin-owner-candidate-2026-08.patch` | `03efa820f025ce378e2870d90d8af6e6c8a7384548f3b14fc7dd42d2471e3bab` |
| producto `Cargo.toml` | `1caa40574d12ebb4aa9cd03cc30d32f75edd8e9572e6d4876238f491c6e3f3de` |
| producto `Cargo.lock` | `dd6ee5615630d788a351c4e3b395de0851fee41b34177823393d35d23a894316` |

Sources locales exactos revisados, procedentes del cache Cargo ya existente:

| Source | SHA-256 |
|---|---|
| `x509-parser-0.18.1/Cargo.toml` | `59b5f4f148244b4a7ad53750338abbc2c065ebfc4410b6931e62ced3eac57823` |
| `x509-parser-0.18.1/README.md` | `574a542f0f3b6870fb6f9baf938f57cfbbcc3e21a1675c7430c19a5b6fc25a68` |
| `x509-parser-0.18.1/src/certificate.rs` | `6ce97ba7fd06246115d5bab8c8f0b1f82d8cb8e7eb4b9d4ce01b5e5b7b02d649` |
| `x509-parser-0.18.1/src/extensions/generalname.rs` | `cfc234edae3b01692380c870e02cc6020fba347df8160645b9a78612a93d0d68` |
| `x509-parser-0.18.1/.cargo_vcs_info.json` | `5e30301b4f41fd52acf506e4d4ace92277a17e166771b55a75a7dbb558f4e95f` |
| `rustls-webpki-0.103.15/Cargo.toml` | `828ab5e8a7973ba0eef93956128a41ac135479367ed10ddaeaec44616d395355` |
| `rustls-webpki-0.103.15/src/cert.rs` | `1a4da3c745a72f61e8e95f222fc5847cb4779a4de524f4d6d09ae1d25b27c001` |
| `rustls-webpki-0.103.15/src/end_entity.rs` | `dcd6176df075627bbd38881bb1b729462721ecb53e7968d56b116a8532043c42` |

Comandos read-only relevantes:

```text
sha256sum .cursorrules gateway-rs/upstream/mirror/reviews/product-pin-*preflight-2026-08.md
sha256sum gateway-rs/upstream/mirror/reviews/product-pin-owner-candidate-2026-08.patch
rg -n '^rustls|^rustls-pki-types|^url|^rcgen|^pem' gateway-rs/Cargo.toml
rg -n 'rustls-webpki|x509-parser|webpki' gateway-rs/Cargo.lock
rg -n '\bunsafe\b' <cached-crate>/src
cargo tree --locked --offline -i x509-parser@0.18.1
cargo tree --locked --offline -i rustls-webpki@0.103.15
```

Los dos últimos se ejecutaron con source y derivado montados read-only,
`--network none`, cache Cargo local read-only y la imagen local fijada
`teremoq-step7-lab:rust-1.93@sha256:315ab1185640250a0bc5143796e5098f90e5ece1041cdf4fabf99a80ff1e2c30`.
Herramientas observadas: `rustc 1.93.0 (254b59607 2026-01-19)` y
`cargo 1.93.0 (083ac5135 2025-12-15)`.

No se descargó ni instaló software. No se editó producto, laboratorio, patch,
manifest, lock, PKI, Git ni remoto. El único write de esta revisión es este
informe.

## Riesgos residuales y estado

- La recomendación selecciona un parser estructural mantenido, no una política
  productiva ya implementada o validada.
- `x509-parser` amplía la superficie runtime aunque sus coordenadas estén en el
  lock; requiere aprobación legal/supply-chain y gates completos tras activarlo.
- Los límites propuestos necesitan confirmación del usuario y test con las
  identidades Smallstep reales.
- Revocación sigue registrada por la PKI pero su enforcement runtime no queda
  resuelto por este parser.
- URI SAN estilo SPIFFE no equivale a desplegar SPIRE ni a disponer de
  Workload API, bundles o rotación automática.
- La publicación del derivado y el pin Git continúan bloqueados por gates de
  procedencia separados.

**Estado del decision brief:** recomendación técnica cerrada; implementación
bloqueada hasta responder las preguntas anteriores. Este documento no declara
readiness comercial/productiva ni autoriza integración, commit, push o
publicación.
