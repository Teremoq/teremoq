<!--
SPDX-FileCopyrightText: 2026 Teremoq contributors
SPDX-License-Identifier: Apache-2.0
-->

# TP-SEC-PKI: puerta de seguridad para la futura integración local

- Fecha: `2026-08-28`.
- Perfil: `TP-SEC-PKI`.
- Owner futuro de la composición: Master / Task 05 / `TP-RUST-DIST`.
- Alcance: plan de revisión de seguridad y readiness; no implementación.
- Baseline oficial: `bf87128affd316463e5dcc7599a45001f222b6de`.
- Árbol baseline: `d76319009e815fb8923e21fc8319e17a0aaf8174`.
- C2: deliberadamente no inspeccionado ni dictaminado en este informe.

Este documento define la puerta que se aplicará a una composición local futura.
No aprueba C2, no aprueba una rama de integración, no autoriza un product pin y
no autoriza commit, push, tag, release, publicación ni mutación remota.

## Findings de readiness

### BLOCKING PRECONDITION — aún no existe una entrada C2 admisible para este gate

El contrato de `PATCH-SERIES.md` exige un C2 aprobado sobre C1, pero este informe
no usa el source C2 mutable, no lee su worktree y no emite un veredicto C2. La
revisión de composición no puede comenzar hasta recibir, como un único paquete
inmutable:

1. un commit C2 completo de 40 hex y su árbol;
2. padre exacto C1
   `ee22a1079783e374371e0705775978790ddd6471`;
3. inventario ordenado de paths y SHA-256 del inventario;
4. SHA-256 de cada fichero C2 y del patch binario padre→C2;
5. stage limpio y ausencia de tracking como evidencia local;
6. dictámenes independientes finales de seguridad, plataforma/chaos y
   supply-chain ligados a esos hashes; y
7. delimitación explícita de cualquier gate bloqueado por baseline.

Una rama, un worktree, un informe de owner o un `HEAD` móvil no sustituyen este
paquete. Hasta entonces no existe candidato de integración que pueda recibir
`APPROVE` ni `CHANGES REQUIRED`.

### HIGH — I1/C1 y I2/Q no son deltas que puedan concatenarse a ciegas

La inspección read-only de los objetos Git cerrados confirma dos colisiones:

- I1 y C1 parten ambos del baseline y modifican
  `moq-native-ietf/src/quic.rs`;
- I2 y Q modifican `Cargo.lock` desde historias diferentes.

`git merge-tree` marca `moq-native-ietf/src/quic.rs` como `changed in both` para
I2+C1 y `Cargo.lock` como `changed in both` para I2+Q. Elegir `ours`, `theirs`,
resolver sólo marcadores o afirmar que cinco approvals individuales implican un
approval compuesto sería inseguro.

La futura resolución de `quic.rs` debe conservar simultáneamente la captura I1
ligada a la misma conexión y la admisión C1 antes del trabajo costoso. La futura
resolución de `Cargo.lock` debe conservar la dev-dependency I2 y aplicar sólo las
dos sustituciones Q/U1. Ambos ficheros recibirán hashes nuevos, se tratarán como
source nuevo de integración y necesitarán revisión adversarial completa.

La misma regla se aplicará a cualquier solapamiento entre el C2 inmutable futuro
y I2. No se presume ahora qué paths C2 tocará.

### HIGH — upstream deliberadamente no implementa principal, roles ni policy Teremoq

I1 termina en evidencia rustls prestada y ligada a la conexión. I2 entrega esa
evidencia a un `SessionAuthorizer` y conserva un contexto opaco y redactado.
SPIFFE/X.509 parsing, principal, roles, ACL, tenant y policy siguen fuera de
`moq-rs`, como exigen ADR-0005 y los dictámenes I1/I2.

Por tanto, la composición del derivative sólo puede demostrar la frontera
genérica. Una afirmación de autorización federada Teremoq exige además un
embedder privado revisado que realice:

```text
certificado validado por rustls
  -> evidencia DER de esa misma conexión
  -> URI SAN aceptado por parser X.509 mantenido
  -> principal mínimo
  -> roles
  -> operación + namespace/prefix exacto
  -> allow/deny fail-closed
```

No se autoriza escribir un parser X.509 propio, usar CN, fingerprint, serial,
IP, SNI, CID, path o `ConnectionTagger` como principal, ni introducir policy
Teremoq en el derivative. Si falta un parser mantenido ya aprobado, la selección
de dependencia, versión, licencia y threat model es una decisión separada antes
de implementar ese embedder.

### HIGH — el gate Objects continúa bloqueado por el E0308 baseline

Los dictámenes finales I2 y C1 conservan explícitamente el E0308 de
`moq-transport/src/serve/tracks.rs:501`, `TrackName` frente a `&str`. C1-WR-03
es `BLOCKED_BY_BASELINE_E0308`, no PASS. Q/U1 no modifican source y no corrigen
ese fallo.

La revisión de composición exigirá que el test completo de `moq-transport`
compile y ejecute sus regresiones de Objects. Si el E0308 permanece, el
dictamen de integración será `CHANGES REQUIRED`. Su corrección deberá ser un
commit mínimo separado, con owner y reviews propios; no puede ocultarse dentro
de una resolución I1/C1, C2/I2 o de lockfile.

### HIGH — Q/U1 reducen riesgo, pero la publicación sigue bloqueada

Q elimina las dos entradas `quinn-proto 0.11.13` de la base congelada y U1
elimina la entrada `bytes 1.6.0`. Después de U1 siguen registrados 16 findings
vulnerables, 12 advisory IDs y seis warnings. No existe todavía una policy
`deny.toml` revisada ni un gate SBOM/release completo.

Esto no impide por sí solo revisar una composición estrictamente local y no
consumida, siempre que el conjunto residual no crezca ni se suprima. Sí impide
product pin, release, publicación y cualquier claim de supply-chain verde. El
informe futuro deberá separar expresamente ambos veredictos.

### MEDIUM — Batch T es una decisión criptográfica separada y no autorizada

T sustituiría código C/assembly de AWS-LC, movería `rustls-webpki` y podría
cambiar build tooling y provider reachability. No es una continuación mecánica
de Q/U1. El candidato de esta puerta debe conservar el grafo U1 en esas líneas;
cualquier movimiento de `aws-lc-rs`, `aws-lc-sys`, `rustls-webpki`, Ring,
Rustls, QUINN, WebTransport, feature `fips` o provider es `CHANGES REQUIRED` y
se devuelve a la decisión T separada.

Este gate no autoriza ring-only, AWS-LC-only, FIPS, `aws-lc-fips-sys`, Bindgen,
un nuevo backend criptográfico ni una actualización amplia de Rustls/QUINN.

### LOW — los DER incluidos son fixtures públicos, no trust material

I1, I2 y C1 incluyen copias de fixtures sintéticos y claves de test
deliberadamente públicas. Son aceptables únicamente dentro de `tests/data`, con
README, SHA256SUMS, sidecars REUSE y advertencia de no despliegue. Su presencia
no demuestra PKI productiva, rotación ni revocación. No deben entrar en un
trust store, imagen, configuración, ejemplo productivo o identidad de cliente.

## Fuentes vinculantes leídas

### Reglas y arquitectura

| Documento | SHA-256 |
| --- | --- |
| `.cursorrules` | `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2` |
| `ADR-0004-FEDERATED-MTLS.md` | `6bbf8b43e8227e09673cca8e7f832a0c4b5d1e9f8df7dc2c9f2abc697b600689` |
| `ADR-0005-FEDERATED-AUTHORIZATION.md` | `8b4b9bb58f399e0a999343af78d61fdd85ea59a95cfa7d42dc96047882257a53` |
| `ADR-0007-CONTROLLED-MOQ-MIRROR.md` | `0085bdaa37cd3645a4a2c5a3163b0b096453b84f66635514fce6015d6bed25d8` |
| `PATCH-SERIES.md` | `b0fe298fa0b4c37c7562c6fc0ea541ceca26fbf0cd40a04016645277a34b642e` |

### Informes finales utilizados

| Unidad | Informe | SHA-256 |
| --- | --- | --- |
| I1 | `i1-local-review-2026-08.md` | `a49ff41ea6836d005884ddb900d31060f718357fdbe2c7bd563c799bb260e8a1` |
| I1 | `i1-tp-sec-pki-review-2026-08.md` | `142860f7cdc408095e806acbf41bd2e32b2137307f44425d6e25e6ab8b1583ee` |
| I1 | `i1-tp-oss-sc-publication-boundary-review-2026-08.md` | `6b0f1aaa0606eae264997907d31b0d442a4275f99f0d7550570a3895c65bacc3` |
| I2 | `i2-local-review-2026-08.md` | `e3477a01f2669efe868a1b6facb12205c7d8b32e9ec73946c5bb114ca8cb4f07` |
| I2 | `i2-tp-sec-pki-third-review-2026-08.md` | `73170aa2a26d048067acdd189e09fec590e226e7e5c1432569d9439873ac0a61` |
| I2 | `i2-final-tp-oss-sc-rereview-2026-08.md` | `1d0e80b5d1128989eb6413cb07fe932a835bc19d800ed262be4122fa6d27aecb` |
| C1 | `c1-local-rereview-2026-08.md` | `a7cca70bc0d926739ca109cacdef1648e200255ad9c82cb33e2b521e0d2b7626` |
| C1 | `c1-tp-sec-pki-final-review-2026-08.md` | `d613817d9ea2da9b7698caf8b934512515c3a6ca0ca76d77d8d2faa223d12d1e` |
| C1 | `c1-tp-platform-chaos-final-review-2026-08.md` | `78d1c3da31b0f3f46482c56e89d62842ffcc04b933aec522fc3e55aa52f04af5` |
| C1 | `c1-tp-oss-sc-rereview-2026-08.md` | `90bf9725e4e8f4eaf4e0c0829136e285be42d63e86b9f834513da9027b129544` |
| Q | `rustsec-q-local-review-2026-08.md` | `24ae0d3d537df1b4aa70a13c0afcdee22af9162d64dba877c7b96a362e9c1033` |
| Q | `rustsec-q-tp-oss-sc-review-2026-08.md` | `bc3f3d9f020b1da7116510843e1de330331140e0affde164ac6b69cf6ecc702c` |
| U1 | `rustsec-u1-local-review-2026-08.md` | `358a31f643e93f9efb9eca29624c9ee6a4931e56264d29ee519824cd1ff2c8fb` |
| U1 | `rustsec-u1-tp-oss-sc-review-2026-08.md` | `48c053d703d4f07b4ce1bf52f5e4bcd2745812d613433d43bd1bc5d80b681ede` |
| T, sólo delimitación | `rustsec-t-decision-brief-2026-08.md` | `3ba24d7069ef4982effa766501836690e5cbf4073c243ffff88b82c9b7935cab` |

No se usó un informe ni el source mutable C2 como evidencia.

## Commits cerrados e inputs inmutables

Los cinco objetos siguientes se reprodujeron desde la base de objetos local
mediante operaciones Git read-only. Todos tienen un padre, un trailer DCO y
`git diff --check` limpio.

| Unidad | Commit | Padre | Árbol | Paths | SHA-256 pathset | SHA-256 patch binario |
| --- | --- | --- | --- | ---: | --- | --- |
| I1 | `05b41127ecbd48de4c59fe1626c43b1e423c33a9` | `bf87128affd316463e5dcc7599a45001f222b6de` | `eca64a72e148482fb82b963edc2f2c9af28803f2` | 17 | `9f81fe7853d13bf3ad93446e9815862a914747106afb4953de7abb6f9abdec77` | `ad88296d0f13e958ff3add0da793391ca1ef023feafb0badf09407a7cabad8d3` |
| I2 | `59d9a8601885ef934cae29d89876abb7c7f73e89` | `05b41127ecbd48de4c59fe1626c43b1e423c33a9` | `d108208bfb5792767881a932480da01769844148` | 22 | `973a0d8b4519cc67c65e54c07b508bea8964133928f3ea63b27c07c7627b979c` | `46b480891bd2e6d926a33e97674175971f8f45c33281aa82acb6d4edb3ad28fc` |
| C1 | `ee22a1079783e374371e0705775978790ddd6471` | `bf87128affd316463e5dcc7599a45001f222b6de` | `232e449945e877b024f2fc4223f0d2eea124b39b` | 10 | `ecbd7dec9829c972da4592187a2fc9856d888bc0985aaba5d39736a2ec961952` | `4839a26f8d58f893c832cd8ea806ba26045292d1420ac1a4a372d0ca2911a123` |
| Q | `1e9d1ee62bde97145a0914e5992ab7f54fc909c4` | `bf87128affd316463e5dcc7599a45001f222b6de` | `4cf25aeea2eacd02394608c80c9677eaa001ef87` | 1 | `3e503ffd2d2f0c135bc5d8c97cba5aff82676478d90cb002333ed9583b92c5a0` | `5637498d49666bbfce72b6362fdb0a946c77d6aaf280d5b18138e6471dfe1f6b` |
| U1 | `4547800088881cb4782c544ebfec0a1904ed1fab` | `1e9d1ee62bde97145a0914e5992ab7f54fc909c4` | `cc9b037c81ace8a9490693a6ccb1c294cd0e3886` | 1 | `3e503ffd2d2f0c135bc5d8c97cba5aff82676478d90cb002333ed9583b92c5a0` | `9b6740f91a2896eb267e89f962206a4eeaf633a0406d7a588428c6d7646d29ee` |

## Superficie protegida

### Anchors semánticos que deben sobrevivir

| Contrato | Path y input | SHA-256 input |
| --- | --- | --- |
| I1 evidence/acceptor | I1 `moq-native-ietf/src/quic.rs` | `fddf415fd4e9e7b6ddf8c2b8d3cfbf7b916309428e932601b7a1bad4aa07f73b` |
| C1 handshake admission | C1 `moq-native-ietf/src/quic.rs` | `b0c8dfb3e4963365a3a27f52a84d2fc54292cfc5a056a817a5a0d0a4f38b3723` |
| C1 adversarial tests | C1 `moq-native-ietf/src/quic_c1_tests.rs` | `610d8430315460db1652d99067002231d7ca4f2eaa48e8de2221966fa2cee8a9` |
| I2 opaque auth API | I2 `moq-relay-ietf/src/authorization.rs` | `101fc1a0a8c1fc8d61453f43617cbfef1913a7db91767f29c9e59b9970d148c2` |
| I2 inbound orchestration | I2 `moq-relay-ietf/src/relay.rs` | `d224efb6055d10cfd853ac660df93dabda34e2d65424f84d5ecb3a1da29b9bbe` |
| I2 operation gates | I2 `moq-relay-ietf/src/producer.rs` | `8b9c723341ad93c77f94a57fc833323c695d45078edd541c0a42a80ea51e966e` |
| I2 operation gates | I2 `moq-relay-ietf/src/consumer.rs` | `06f601e1f4efdb3c7f4bca99114d275db0abcdca436fece01c352f3fb13a256d` |
| I2 tests | I2 `moq-relay-ietf/src/i2_tests.rs` | `595ac7f27b545c9370b22b8fbf483ac0c4de91e779413f93fc42643d6dca0e6f` |
| I2 public relay surface | I2 `moq-relay-ietf/src/lib.rs` | `c3ccba4a249469e3926a5a6e8f92912694808c13e2fe9cd42e74c08dc9c34990` |
| I2 two-phase setup | I2 `moq-transport/src/session/mod.rs` | `5fa5a8a1c8d68faf86553146eb7b0d39a7ee9aea6a41b97e4abf261500115b00` |
| I2 pending API test | I2 `moq-transport/tests/pending_accept.rs` | `7165d0bb033e8e0ffe180b384879b8d738235f9e021da57d4a8505567e6f2de1` |
| I2 test-only rustls edge | I2 `moq-relay-ietf/Cargo.toml` | `83185ddb3f1523a6d7d9c577abbf29010eb34d6043538c1b28ff1057bb888b11` |
| I2 fixture inventory | I2 `moq-relay-ietf/tests/data/i2/SHA256SUMS` | `97ed99bcd8d4144652bc729dd6f7e80a4e258f397f3b620a274d9c8b08e2bee9` |
| C1 fixture inventory | C1 `moq-native-ietf/tests/data/c1/SHA256SUMS` | `ba0f134515bdca4413dc9658d4016343a2180fd6c8f624e7e1b779f013696d64` |

El `quic.rs` final no puede coincidir con I1 ni con C1: debe contener ambos
contratos y recibir un hash nuevo. El `relay.rs`/`lib.rs` final puede cambiar al
componer C2. Esos hashes nuevos se fijarán antes de ejecutar tests, y un cambio
durante review implica snapshot inestable y `CHANGES REQUIRED`.

### Objetos que deben permanecer byte-identical

Salvo un commit mínimo separado que corrija el E0308 y reciba sus propios
reviews, la composición no puede modificar:

| Path | SHA-256 baseline requerido |
| --- | --- |
| root `Cargo.toml` | `6665802c9ad7192d61521a62877454e25bde7072c611e617780a932f583aa48f` |
| `moq-native-ietf/Cargo.toml` | `3180121a89c58071718236a408f36c1c87757d6f9ff81e899fb3b5814c8d4c8e` |
| `moq-transport/Cargo.toml` | `78f582c201082f7badece64f7fa65d215a6694412b7a7699332fa3bc9a4f3743` |
| `moq-transport/src/setup/mod.rs` | `c49d71dcacd5e3f5eef7a673e11b9058d3fd701e1fb83331a737098894a2d750` |
| `moq-transport/src/setup/version.rs` | `384772b32812a0761fa55d16a9fd29e30595323ece1b3fca013ec3720eaec4ad` |
| `moq-transport/src/message/mod.rs` | `e5760f5ce2927b2437511b3e616fea2615d82e916d4b6036b7f5450ae0973352` |
| `REUSE.toml` | `afc7fd86e591a56078b11982ee4d039ea1dfe3f9d56a90e3e7fa9f84fbddb6cc` |
| `LICENSES/MIT.txt` | `c7d191b5901a741f2e39c74bd7a7594014a81fbe2bc7d533d4c29ad4cfe4e057` |
| `LICENSES/Apache-2.0.txt` | `1248f876e0140942002b476a19c95d5b5b44c625e69c96611d23119ee87fa04e` |

No se permite cambio de draft-16, ALPN `moqt-16`, setup, wire IDs, Tracks,
Groups, Objects, segundo transporte, parser X.509, crypto propia o `unsafe`.

### `Cargo.lock` compuesto esperado para I2 + Q + U1

I2 deja `Cargo.lock` en SHA-256
`13b9f1c54ccbe644dcf4f07542f610950cd013b291c928b6b3ad39ac1751ce80`
y añade exclusivamente la edge dev `moq-relay-ietf -> rustls 0.23.31`. Sobre
ese lock deben aplicarse sólo estas sustituciones de records:

| Paquete | Desde | Hasta | Checksum final |
| --- | --- | --- | --- |
| `quinn-proto` | `0.11.13` | `0.11.15` | `4fcb935c5bec503c2f0e306bdd3e58bb9029dcb14fa8d9ac76e3a5256ac0763e` |
| `bytes` | `1.6.0` | `1.11.1` | `1e748733b7cbc798e1434b6ac524f0c1ff2ab456fe201501e6497c8417a4fc33` |

La transformación textual acotada sobre el lock I2 produce SHA-256 esperado
`d6196fd8f31ea3b2cabbdb0e57546810643f344567f3e358ee3c000b3e2b59f5`
y conserva 336 package records. Ese hash es vinculante sólo si el C2 aprobado y
la corrección E0308 no tocan el lock. Un delta C2 de dependencia contradice su
contrato actual y detiene esta puerta.

No se aceptará un `cargo update` amplio. La comparación debe hacerse por record
completo: name, version, source, checksum y dependency list.

## Invariantes de composición

### IC-01 — certificado verificado y evidencia pertenecen a la misma conexión

I1 sólo puede consultar `quinn::Connection::peer_identity()` después de que el
handshake de esa misma conexión termine. La evidencia nunca se obtiene de una
IP, CID, SNI, path, socket map, global, task-local o thread-local. Error de tipo,
chain vacía o conversión fallida no produce session handle.

### IC-02 — C1 protege el trabajo costoso sin convertirse en identidad

`Incoming` se obtiene primero; después se usa un único
`try_acquire_owned` inmediato y, sólo si hay permiso, comienza QUIC/TLS/
WebTransport. Saturación no crea waiter, task ni trabajo criptográfico. El
permit C1 se libera exactamente una vez en success, error, timeout, cancel,
panic/unwind y drop, no más tarde de entregar la conexión establecida. Ningún
limit, permit, contador ni disposition contribuye a principal o policy.

### IC-03 — admisión C2 es ortogonal y anterior al estado relay

El C2 futuro debe aplicar capacidad global de sesiones establecidas de forma
inmediata antes de setup/task/coordinator/namespace. Rechazo por capacidad puede
ocurrir sin construir principal; eso es overload, no fallo de autenticación.
Un slot admitido se conserva por RAII durante authenticate, path gate, setup y
vida de sesión, y se libera una vez en todos los terminales.

### IC-04 — evidencia prestada se reduce a contexto mínimo

`SessionAuthorizer::authenticate` recibe `&VerifiedPeerEvidence`. El embedder
deriva principal/roles durante ese borrow y devuelve sólo contexto mínimo. No
retiene DER/PEM, subject, SAN bruto, serial, fingerprint, chain length ni una
referencia al evidence wrapper. Upstream descarta evidencia antes de continuar.

### IC-05 — URI SAN autentica; path sólo selecciona recurso

Para Teremoq, el futuro principal procede del URI SAN autorizado y validado;
el CN es informativo. Raw QUIC conoce PATH al decodificar CLIENT_SETUP.
WebTransport conoce CONNECT y éste tiene precedencia canónica. Path se pasa a
`resolve_scope` junto al contexto autenticado, pero nunca se convierte en
principal, rol o relay-peer.

### IC-06 — required es fail-closed antes de `SERVER_SETUP`

El orden requerido para una sesión admitida es:

1. verificación TLS;
2. I1 evidence ligado a la conexión;
3. `authenticate` y descarte de evidence;
4. `accept_pending` mínimo y path canónico;
5. missing-path/`resolve_scope`;
6. `finish` y sólo entonces `SERVER_SETUP`;
7. `SessionContext`, Producer, Consumer, watchers y tasks.

Ausencia de evidencia, tipo inesperado, authenticate deny, missing path o scope
deny cierra sin fallback legacy, mlog, `SERVER_SETUP`, handle, tagger,
Coordinator, lookup, registro, cache, forwarding, respuesta o mutación.

### IC-07 — cada operación se autoriza antes del primer efecto

PUBLISH, PUBLISH_NAMESPACE, SUBSCRIBE, SUBSCRIBE_NAMESPACE, NAMESPACE,
NAMESPACE_DONE, discovery Publish, TRACK_STATUS y forwarding usan el namespace
o prefix exacto. La autorización precede métricas, extracción de reader,
lookup, lease, watcher, cache, registro, forwarding, respuesta y mutación.

### IC-08 — `RelayPeer` sólo procede del contexto autenticado

Ni IP, SNI, CID, path, `ConnInfo`, `ConnectionMeta`, tagger ni topología local
clasifican relay-peer. El contexto autenticado debe marcarlo explícitamente y
cada operación pasa el gate base y un segundo gate `RelayPeer` antes de efectos.

### IC-09 — capacidad, autenticación y autorización son tres dominios

Los contadores de C1/C2 no contienen resultados de auth. Los errores auth no
incrementan rejected-capacity. Una identidad válida no evita capacity. Un slot
no concede scope. El orden y los nombres de métricas deben permitir distinguir
overload, TLS, authentication, authorization, setup y shutdown sin incluir
identidad en labels.

### IC-10 — shutdown cierra admisión antes de cancelar

Los controllers C1/C2 pasan a stopping/closed antes de cancel/drain. Toda nueva
admisión recibe disposition constante sin waiter, dial, task, callback, log ni
estado. Un único deadline monotónico absoluto cubre cierre de accepts,
cancelación, drain y forced drop. Al retorno, pending/active gauges son cero.

### IC-11 — aislamiento concurrente y lifetimes

Dos certificados, contexts, roles, namespaces y capacities concurrentes no se
mezclan. Un `Arc` sólo puede retener authorizer y contexto mínimo durante la
vida real de la sesión. Cancel/drop no deja slot, evidence, task o context
huérfano; generación antigua no puede retirar un slot reutilizado.

### IC-12 — redacción completa

No aparecen DER, PEM, subject, SAN, URI completo, serial, fingerprint,
principal, rol, context, type name, namespace, prefix ni path en `Debug`,
`Display`, `anyhow`, tracing, labels métricos, qlog o mlog añadidos por la
serie. Los errores/dispositions son constantes. IP/SNI/CID de transporte nunca
se copian a labels de auth ni se interpretan como identidad.

### IC-13 — legacy sigue explícito; required nunca cae a legacy

La API legacy conserva source compatibility y sus tests, pero el wiring
federado selecciona de forma explícita required + C1 + C2. Error de authorizer,
ausencia de config, overload o shutdown no llama al Coordinator/tagger legacy.
No se acepta un default permisivo para “mantener disponibilidad”.

### IC-14 — raw QUIC y WebTransport conservan el mismo trust contract

Ambos transportes usan el endpoint QUINN/rustls existente, TLS 1.3 donde lo
requiere el harness mTLS, ALPNs existentes y MoQT draft-16. Las diferencias de
obtención del path no cambian evidencia, principal, roles ni gates.

### IC-15 — Q/U1 sobreviven sin ampliar el grafo

El candidate contiene exactamente `quinn-proto 0.11.15` y `bytes 1.11.1`, con
los checksums fijados, misma topología y features aprobadas. Q no desactiva C1,
Retry, timeout ni peer evidence. U1 no relaja límites de decode/reserva ni
introduce allocaciones no acotadas.

### IC-16 — fixtures y PKI permanecen fuera de producción

Los DER históricos coinciden con sus inventarios y sidecars. Los tests de
composición productiva cargan certificados desde un fixture/harness privado
efímero aprobado; nunca copian `infra/pki/runtime`, passwords, tokens o PEM al
derivative, logs o reportes. Revocación, CRL/OCSP y rotación sin reinicio no se
declaran implementadas sin evidencia adicional.

### IC-17 — T y cualquier cambio criptográfico permanecen fuera

El grafo final conserva la línea U1 de AWS-LC/webpki/Rustls/Ring. Una futura T
requiere autorización, lock propio, revisión de archives/notices/build C/asm,
features/provider, mTLS y una nueva repetición completa de esta puerta.

## Matriz de pruebas adversariales futura

| ID | Escenario | Oráculo independiente y resultado obligatorio |
| --- | --- | --- |
| A01 | Raw y WebTransport sin certificado cliente | TLS/evidence cierra; cero authenticate, scope, C2 session state, Coordinator y MoQT app state. |
| A02 | Evidence empty/unexpected type | Error redactado; cero session handle y cero fallback. |
| A03 | Certificado válido, `authenticate` deniega | Exactamente un authenticate; cero scope, setup, mlog, task, Coordinator y namespace; slot C2 vuelve a cero. |
| A04 | Certificado válido, contexto válido, path ausente | Cierra antes de resolve/finish; cliente no recibe `SERVER_SETUP`. |
| A05 | Path raw y CONNECT WebTransport denegados | Path canónico exacto observado por resolver; mientras bloquea no hay mlog/handles/efectos; deny conserva cero. |
| A06 | URI SAN ausente, malformado o rol desconocido en embedder privado | Fail-closed antes de scope; CN/fingerprint/IP/SNI/path no sirven de fallback. |
| A07 | Certificado válido pero no autorizado | No alcanza scope/namespace; demuestra que mTLS no equivale a autorización. |
| A08 | PUBLISH y PUBLISH_NAMESPACE denegados | Locals/Coordinator/reader/respuesta/métricas operativas permanecen sin efecto. |
| A09 | SUBSCRIBE existente y SUBSCRIBE_NAMESPACE denegados | Fixture independiente sigue presente; cero lookup/cache/serve/lease/watcher/snapshot/REQUEST_OK. |
| A10 | NAMESPACE y NAMESPACE_DONE denegados | Stream y known-state independientes no emiten ni mutan. |
| A11 | Discovery Publish y TRACK_STATUS denegados | Cero outbound Publish, lookup, cache y response sobre fixture existente. |
| A12 | Relay peer | Sólo contexto autenticado; gate base + segundo gate exacto; cero efecto si el segundo deniega. |
| A13 | Dos peers/roles/namespaces concurrentes | Todas las combinaciones correctas y cruces negativos; no contaminación por Arc, socket o slot reutilizado. |
| A14 | C1 N/N+1 raw y WebTransport | N+1 rechazado antes de crypto sin waiter; capacity se recupera en TLS error, timeout, cancel y drop. |
| A15 | C2 N/N+1 sobre endpoints mixtos | N+1 recibe code/reason constantes antes de setup/task/auth/coordinator; la identidad no aparece en disposition. |
| A16 | Auth deny/cancel/panic con slot C2 | RAII libera exactamente una vez; terminal se publica después de release; cero underflow. |
| A17 | Shutdown con authenticate o resolve bloqueado | Controller cerrado primero; future cliente espera setup; deadline único; forced drop y gauges cero. |
| A18 | Admit-before-stop y stop-before-admit | Orden linealizable; Closed no incrementa admitted/rejected-capacity ni crea side effect. |
| A19 | Principal/context con canary sensible en `Debug` propio | Capture de tracing/error/metrics/qlog/mlog no contiene canary, type name, principal, rol, URI, namespace o path. |
| A20 | Legacy raw/WebTransport | Compila y funciona sólo por constructor legacy explícito; required nunca lo invoca ante error. |
| A21 | Q transport parameters/reassembly | Tests upstream y real-QUINN pasan sin endpoint panic ni crecimiento no acotado; C1 burst mantiene cap. |
| A22 | U1 `BytesMut` overflow y inputs máximos | Regresión upstream pasa; inputs de red inválidos se rechazan antes de reserva no acotada. |
| A23 | Draft/ALPN/Objects | `moqt-16`, draft-16, setup y Objects pasan en raw/WT; C1-WR-03 debe ser PASS real. |
| A24 | Fixtures | Hashes, pairings y REUSE pasan; sólo SANs/nombres sintéticos públicos; ningún secret operativo. |
| A25 | Redacción estática y dinámica | Scans focal/broad redactados; asserts no imprimen DER/PEM/key/cert/context; no sleeps ni oráculos circulares. |

Los atomics del authorizer no bastan como único oráculo. Cada test de ordering
debe observar al menos un efecto independiente: client future esperando
`SERVER_SETUP`, mlog aislado, Locals/Coordinator real, handles, watcher/stream,
lookup/cache o gauges del controller. Los timeouts son watchdogs absolutos, no
señales de éxito; no se permiten `sleep` ni asserts que formateen material
sensible.

## Matriz de composición por fase

| Fase | Gate | Estado permitido antes de la siguiente fase |
| --- | --- | --- |
| QUINN inbound | C1 `try_acquire_owned` | Permit owned o disposition inmediata; nunca waiter. |
| QUIC/TLS/WT establishment | C1 deadline + rustls | Certificado verificado o cierre; sin principal todavía. |
| Connection evidence | I1 | Evidence borrowed/owned por esa sesión; error sin handle. |
| Relay capacity | C2 futuro | Slot RAII o rechazo de overload; no auth implícita. |
| Authentication | I2 hook + embedder | Contexto mínimo o cierre; evidence descartado. |
| Requested resource | I2 PendingSession | Path canónico como recurso, nunca identidad. |
| Scope gate | I2 authorizer | Allow exacto antes de `finish`; deny sin `SERVER_SETUP`. |
| Session materialization | I2 + C2 | Handles/tasks sólo después de gates; slot sigue owned. |
| Namespace operations | I2 | Gate base y relay-peer exactos antes de cada efecto. |
| Shutdown | C1/C2 | Accept cerrado, cancel/drain deadline único, gauges cero. |

## Procedimiento futuro de revisión

### 1. Congelar el candidato antes de compilar

El Master debe proporcionar commit, árbol, padres, branch sin tracking, stage
vacío, status hash, pathset hash y patch hash. El revisor vuelve a calcularlos
desde objetos Git, no desde el informe owner. Después congela SHA-256 de cada
path de la unión I1/I2/C1/C2/Q/U1 y de cada fichero de resolución.

Comandos read-only equivalentes:

```bash
GIT_OPTIONAL_LOCKS=0 git rev-parse HEAD HEAD^{tree}
GIT_OPTIONAL_LOCKS=0 git show -s --format='%H %T %P%n%B' HEAD
GIT_OPTIONAL_LOCKS=0 git status --porcelain=v1 -uall
GIT_OPTIONAL_LOCKS=0 git diff --cached --quiet
GIT_OPTIONAL_LOCKS=0 git diff-tree --no-commit-id --name-only -r HEAD
GIT_OPTIONAL_LOCKS=0 git diff --check bf87128affd316463e5dcc7599a45001f222b6de HEAD
GIT_OPTIONAL_LOCKS=0 git diff bf87128affd316463e5dcc7599a45001f222b6de HEAD --binary | sha256sum
```

Se rechazan merge commits o resoluciones no explicadas, commits extra,
conflict markers, path fuera del inventario aprobado, DCO ausente, un ref móvil
como input o cambio del snapshot durante review.

### 2. Demostrar la resolución I1+C1

Por source y tests se debe comprobar que:

- el constructor bounded y la conversión a `PeerEvidenceServer` preservan el
  mismo controller/deadline/disposition;
- legacy no llama `peer_identity()`;
- required nunca usa el acceptor legacy;
- el permit C1 cubre el trabajo costoso y se libera antes de session lifetime;
- evidence se toma de la misma `quinn::Connection` establecida;
- no hay dos pending queues capaces de mezclar modos; y
- cancel/drop libera permit y evidence de esa generación.

Una prueba integrada debe recorrer explícitamente `new_bounded` →
`with_peer_evidence` → `Relay::new_required` sobre raw y WebTransport. Ejecutar
por separado los tests I1 y C1 no satisface este gate.

### 3. Demostrar la resolución I2+C2

El API final debe ofrecer una composición pública y no ambigua de required +
bounded sessions + bounded shutdown. No se acepta que el caller tenga que
elegir entre auth y capacity, ni una ruta required que accidentalmente use el
constructor C2 legacy.

La lectura y A15–A18 deben probar: admission antes de task/setup, slot owned a
través de todos los awaits, stop linealizable, un único terminal y cero gauges.
No se permite callback arbitrario, logging o await dentro de admission/Drop.

### 4. Reproducir Q/U1 sobre el lock compuesto

```bash
cargo metadata --locked --offline --format-version 1
cargo tree --locked --offline -i quinn-proto@0.11.15 -e normal,build,dev
cargo tree --locked --offline -i bytes@1.11.1 -e normal,build,dev
cargo tree --locked --offline -e features -i rustls@0.23.31
```

Se comparan los 336 records contra I2 con la sustitución exacta Q/U1. Deben
estar ausentes `quinn-proto 0.11.13` y `bytes 1.6.0`. Rustls 0.23.31 mantiene la
edge dev I2 `default-features = false`, feature `ring`; normal/build no gana esa
edge. No se permite otro movimiento ni una coordenada T.

### 5. Ejecutar gates Rust focales y completos

Usar Rust 1.93.0 desde la imagen oficial inmutable:

```text
rust:1.93.0-slim-bookworm@sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57
```

El source se monta read-only; `CARGO_HOME` y `CARGO_TARGET_DIR` son temporales,
sin instalación global. Gates mínimos:

```bash
cargo test --locked --offline -p moq-native-ietf --test peer_evidence
cargo test --locked --offline -p moq-native-ietf c1_
cargo test --locked --offline -p moq-native-ietf
cargo test --locked --offline -p moq-transport --test pending_accept
cargo test --locked --offline -p moq-transport
cargo test --locked --offline -p moq-relay-ietf
cargo check --locked --offline --workspace --all-targets --all-features
cargo test --locked --offline --workspace --all-targets --all-features
cargo clippy --locked --offline --workspace --all-targets --all-features -- -D warnings
cargo fmt --all -- --check
```

Los tests de composición A01–A25 se ejecutan además de los históricos. Un
baseline failure se reporta con su owner; no se convierte en PASS. El E0308 de
WR-03 impide approval de integración mientras bloquee Objects.

### 6. Supply-chain, licencias, fixtures y secrets

Herramientas ya aprobadas:

- REUSE 5.1.1:
  `fsfe/reuse:5.1.1@sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da`;
- Gitleaks 8.30.1:
  `zricethezav/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f`;
- cargo-audit 0.22.2, binario SHA-256
  `66f9c8f530950d106c1869ce27ef5a4008bcea53c7716c3ed8117586337ee7d8`;
- DB RustSec congelada commit
  `6420e39260b3d771b049954cf5d52b57e2118da4`, tree
  `01794d45488a521b322b760b6bfdcd6e9f28932b`.

Ejecutar REUSE sobre source sin `.git`/`target`; Gitleaks focal y broad con
`--redact=100`, sin suppressions; SHA256SUMS de fixtures; `cargo package --list`
para crates tocadas; cargo-audit congelado y una DB actual fijada cuando esté
autorizada; cargo-deny bajo policy revisada; SBOM normal/build/all-features.

El conocido match broad del comentario PEM en
`moq-relay-ietf/src/tls.rs:115` se documenta como baseline, no se suprime. Un
scanner que detecte un DER público sólo puede recibir una excepción por blobs
exactos revisados, nunca por glob de keys.

### 7. Capturar y revisar observabilidad

Ejecutar los casos deny, overload, cancel, panic y shutdown con directorios
qlog/mlog temporales aislados y un subscriber de tracing capturado. Buscar los
canaries de certificado/context/principal y los nombres de tipos. Verificar
que métricas tienen cardinalidad acotada y sólo labels enumerados. No mostrar
ningún PEM, DER, key, token, password o identidad real en output o informe.

## Criterios binarios del dictamen futuro

### `APPROVE`

Sólo se puede emitir si se cumplen simultáneamente todos estos puntos:

1. C2 llega como commit inmutable aprobado y reproduce todos sus hashes.
2. El candidato queda congelado, limpio y contiene sólo inputs aprobados y
   resoluciones explicadas/revisadas.
3. IC-01–IC-17 y A01–A25 pasan con efectos independientes.
4. Existe un test único raw y otro WebTransport que demuestran certificado
   válido → evidence connection-bound → principal/context → path/scope → gate
   exacto; valid cert + deny no alcanza scope/app state.
5. Required + C1 + C2 usa una única ruta pública sin fallback legacy.
6. Todas las autorizaciones ocurren antes del primer efecto.
7. Admission y shutdown son linealizables, RAII exactamente una vez y gauges
   cero.
8. Redacción y cardinalidad pasan; identidad nunca aparece en labels/errors.
9. El lock coincide con I2+Q+U1 exacto; T y movimientos extra están ausentes.
10. Draft-16/ALPN/raw/WebTransport/Objects pasan; WR-03 ya no está bloqueado.
11. Fixtures, REUSE, Gitleaks, packages, licencias y provenance pasan.
12. Audit residual no crece ni se suprime y se declara como blocker de
    product pin/publicación.

El alcance exacto del resultado sería **seguridad de composición local**. No
autoriza producto, PKI productiva, revocación, push, publicación, release ni T.

### `CHANGES REQUIRED`

Se emite ante cualquiera de estas condiciones:

- C2 no está aprobado/inmutable o cambia durante review;
- conflicto resuelto con `ours`/`theirs`, lógica perdida o commit extra;
- capacity puede saltarse auth o auth puede saltarse capacity;
- evidence no pertenece a la misma conexión o se retiene en context;
- IP/SNI/CID/path/fingerprint/CN se usa como principal o relay-peer;
- missing/deny/fallo cae a legacy o llega a setup/scope/namespace/efecto;
- operación no usa namespace/prefix exacto o relay-peer omite el segundo gate;
- waiter/check-then-act, callback/await en admission/Drop, doble terminal,
  underflow, task detached o gauge no cero;
- identity/cert/context aparece en error, label, log, qlog o mlog añadido;
- raw y WebTransport divergen en trust contract;
- E0308/Objects, tests de composición o cualquier gate obligatorio falla;
- lock distinto del record-set I2+Q+U1, advisory nuevo/suprimido o T infiltrado;
- dependencia, feature, provider, `unsafe`, wire, draft, ALPN, segundo
  transporte, parser/crypto propios, licencia incompatible o secret; o
- snapshot/path/hash cambia después de iniciar la revisión.

No se utilizará `PARTIAL`, waiver implícito, aprobación por suma de informes ni
una frase ambigua equivalente.

## Riesgos residuales que un eventual APPROVE no cerraría

- La PKI de desarrollo no es PKI productiva.
- Revocación/CRL/OCSP y recarga/rotación sin reinicio no están demostradas.
- Un embedder autorizado a leer DER todavía puede copiarlo deliberadamente;
  debe pasar review propio.
- Los advisories fuera de Q/U1, cargo-deny, SBOM, packages secuenciales y
  publicación continúan separados.
- La disponibilidad ante DoS volumétrico previo a QUINN no queda resuelta por
  C1/C2.
- Interoperabilidad mTLS/MoQT contra peer independiente, soak y Chaos siguen
  siendo gates posteriores.
- Un futuro Batch T invalida la evidencia crypto/mTLS y exige repetir esta
  revisión sobre el nuevo grafo.

## Actividad de esta preparación

Se leyeron reglas, ADR, patch series, informes cerrados y objetos Git de los
cinco commits indicados. Sólo se usaron comandos read-only de Git, `sed`, `rg`,
`sha256sum` y transformación streaming del lock I2. No se ejecutaron builds,
tests grandes, Cargo resolver, contenedores, red ni scanners. No se leyó source
C2 mutable.

No se editó ningún worktree `moq-rs`, source, manifest, lockfile, fixture, ADR,
informe existente, ref, index o metadata Git. No hubo fetch, commit, push, tag,
release, publicación, mensaje externo ni mutación remota. El único artefacto
creado es este plan en el workspace de gobernanza Teremoq.

**READINESS PLAN ONLY / NO C2 VERDICT / NO INTEGRATION APPROVAL / NO COMMIT / NO PUSH / NO PUBLICATION / NO REMOTE MUTATION**
