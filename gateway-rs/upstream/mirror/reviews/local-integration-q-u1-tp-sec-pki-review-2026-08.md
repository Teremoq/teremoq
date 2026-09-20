<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# TP-SEC-PKI — revisión formal de la integración local Q+U1

- Fecha: 2026-08-28
- Rol: `TP-SEC-PKI`, revisor independiente de seguridad
- Snapshot: `/home/jimbomilk/moq-rs-teremoq-integration-work`
- Alcance: únicamente el límite de seguridad del merge staged Q+U1 sobre el
  source merge I1/I2+C1/C2 ya cerrado
- Autoridad remota, de publicación o de despliegue: ninguna

`READ-ONLY SECURITY REVIEW / NO COMMIT / NO PUSH / NO FETCH / NO PUBLICATION / NO REMOTE MUTATION`

## Hallazgos primero

### HIGH heredado — el audit global sigue rojo

Q+U1 reduce el resultado RustSec de 19 a 16 entradas vulnerables, pero no deja
la cadena de dependencias saneada. Permanecen 16 entradas correspondientes a
12 advisory IDs y seis warnings. Entre ellas están cuatro findings de
`aws-lc-sys 0.30.0` y ocho entradas sobre las dos líneas de
`rustls-webpki`. Este riesgo impide atribuir readiness productiva, comercial o
de publicación al snapshot.

No es una regresión Q/U1: el conjunto residual es exactamente el conjunto del
baseline menos las tres entradas que Q/U1 pretendían cerrar, sin allowlist,
ignore ni supresión. El lote criptográfico T continúa separado y **no está
autorizado** por este dictamen. No se ha resuelto, aplicado ni recomendado como
si ya formara parte del snapshot.

### LOW de reproducibilidad — la DB histórica ya no es reejecutable por objeto Git

Los informes Q/U1 usaron la DB congelada en commit
`6420e39260b3d771b049954cf5d52b57e2118da4`, tree
`01794d45488a521b322b760b6bfdcd6e9f28932b`. Ese objeto ya no existe en los
checkouts locales; no se afirma falsamente una nueva ejecución contra él.

Sí existe un checkout completo, limpio y sólo lectura del repositorio oficial
RustSec en commit `a7bfe16948bf6f3ee25bdee4822209f87da21b80`, tree
`1152ddcadf432f7bf97746e51fb7f2d9e5968c49`, con fecha de commit
`2026-08-24T22:42:17-04:00`. La comparación independiente `HEAD`/staged se
ejecutó sin red contra ese snapshot y produjo exactamente el mismo cierre
19→16 y warnings 6→6 registrado por la DB histórica. Sigue siendo necesario
un audit autorizado contra una DB actual antes de publicación.

El ejecutable local usado fue `cargo-audit 0.22.2`, SHA-256
`507532dd1ec54506ba6c3839b55a5ab0b47470c9667e9134926be35b10e231a3`.
Los informes previos usaron otro build de la misma versión, SHA-256
`66f9c8f530950d106c1869ce27ef5a4008bcea53c7716c3ed8117586337ee7d8`.
La diferencia se declara; el resultado fue corroborado con los records exactos
del lock y los metadatos primarios de los tres advisories cerrados.

### Informativo — no se encontró defecto específico de integración Q+U1

El índice contiene un solo path, `Cargo.lock`, con cuatro adiciones y cuatro
eliminaciones. La comparación TOML de los 336 records encuentra exactamente
dos sustituciones de versión/checksum y ninguna otra coordenada, dependencia o
feature declarada. No hay diff en source, manifests, fixtures, protocolo,
identidad, autenticación, autorización, redacción ni configuración TLS/mTLS.

## Veredicto

APPROVE

El veredicto se limita a conservar este lock staged exacto como integración
local. No autoriza commit por este revisor, push, publicación, release,
despliegue, product pin ni lote T.

## Binding congelado reproducido

| Propiedad | Valor observado |
| --- | --- |
| `.cursorrules` | SHA-256 `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2`; lectura completa de 488 líneas |
| `HEAD` | `1fc0d5b7d145863c96c25560190669a4c13d026b` |
| tree de `HEAD` | `d7f0c67f4c134adc4250885f6bc031aa2efcead6` |
| padres de `HEAD` | `59d9a8601885ef934cae29d89876abb7c7f73e89` y `b4ee3b68df58bbb6e7b865c2898d3f46ffbb7fd1` |
| `MERGE_HEAD` | U1 `4547800088881cb4782c544ebfec0a1904ed1fab` |
| Q incluido por U1 | `1e9d1ee62bde97145a0914e5992ab7f54fc909c4`; `git merge-base --is-ancestor` = 0 |
| tree staged | coincide exactamente con `4696ae59a07ec1b3930a654e03e412221f9a8a5d` mediante `git diff-index --cached --quiet` |
| paths staged | uno: `Cargo.lock` |
| pathset SHA-256 | `3e503ffd2d2f0c135bc5d8c97cba5aff82676478d90cb002333ed9583b92c5a0` sobre `git diff --cached --name-only` |
| status-z SHA-256 | `ce44e624498f3a799669efe577d41fb1e715ff857867d6f87cc84c94cfaf54da` |
| lock combinado/oráculo | SHA-256 `d6196fd8f31ea3b2cabbdb0e57546810643f344567f3e358ee3c000b3e2b59f5` |
| unmerged / unstaged | `0 / 0` |
| branch / tracking | `teremoq/integration-draft16-bf87128-local` / ninguno |

Q es hijo directo de `bf87128affd316463e5dcc7599a45001f222b6de` y
su tree es `4cf25aeea2eacd02394608c80c9677eaa001ef87`. U1 es hijo directo de Q y su
tree es `cc9b037c81ace8a9490693a6ccb1c294cd0e3886`. Ambos commits modifican sólo
`Cargo.lock` y contienen un trailer DCO `Signed-off-by`.

Los bindings se reprodujeron al inicio, antes del informe y después de crear el
informe. El worktree revisado permaneció inalterado.

## Inputs previos revisados

| Documento | SHA-256 |
| --- | --- |
| Owner Q, `rustsec-q-local-review-2026-08.md` | `24ae0d3d537df1b4aa70a13c0afcdee22af9162d64dba877c7b96a362e9c1033` |
| TP-OSS-SC Q | `bc3f3d9f020b1da7116510843e1de330331140e0affde164ac6b69cf6ecc702c` |
| Owner U1, `rustsec-u1-local-review-2026-08.md` | `358a31f643e93f9efb9eca29624c9ee6a4931e56264d29ee519824cd1ff2c8fb` |
| TP-OSS-SC U1 | `48c053d703d4f07b4ce1bf52f5e4bcd2745812d613433d43bd1bc5d80b681ede` |
| TP-SEC-PKI final del source merge | `eb930f04d546bcc71a810f2566eb4ad44b94833b4255918d98222accec6907b7` |
| Brief separado T | `3ba24d7069ef4982effa766501836690e5cbf4073c243ffff88b82c9b7935cab` |

Los cuatro informes Q/U1 se leyeron completos. Sus resultados se trataron
como evidencia de contraste, no como sustituto del diff, lock, audit y tests
independientes de este snapshot.

## Delta exacto del lock

El lock de `HEAD` tiene SHA-256
`13b9f1c54ccbe644dcf4f07542f610950cd013b291c928b6b3ad39ac1751ce80`;
el lock staged tiene el hash oráculo indicado arriba. Ambos contienen 336
records. La comparación completa de nombre, versión, source, checksum y lista
de dependencias produjo:

| Dirección | Paquete | Versión | Checksum registry | Dependencias del record |
| --- | --- | ---: | --- | ---: |
| eliminada | `bytes` | `1.6.0` | `514de17de45fdb8dc022b1a7975556c53c86f9f0aa5f534b98977b171857c2c9` | 0 |
| añadida | `bytes` | `1.11.1` | `1e748733b7cbc798e1434b6ac524f0c1ff2ab456fe201501e6497c8417a4fc33` | 0 |
| eliminada | `quinn-proto` | `0.11.13` | `f1906b49b0c3bc04b5fe5d86a77925ae6524a19b816ae38ce1e426255f1d8a31` | 17 |
| añadida | `quinn-proto` | `0.11.15` | `4fcb935c5bec503c2f0e306bdd3e58bb9029dcb14fa8d9ac76e3a5256ac0763e` | 17 |

Los hunks están en `Cargo.lock:293-296` y `Cargo.lock:1684-1687`. La lista de
dependencias de `quinn-proto` no cambia. `git diff --cached --check` pasa;
`git diff --cached --quiet -- . ':(exclude)Cargo.lock'` y la comparación
específica de todos los `Cargo.toml` salen 0.

### Coordenadas TLS/QUIC preservadas

| Componente | `HEAD` | staged |
| --- | ---: | ---: |
| `rustls` principal | `0.23.31` | `0.23.31` |
| `rustls` heredado HTTP | `0.22.4` | `0.22.4` |
| `aws-lc-rs` | `1.13.3` | `1.13.3` |
| `aws-lc-sys` | `0.30.0` | `0.30.0` |
| `ring` | `0.17.14` | `0.17.14` |
| `rustls-webpki` | `0.102.4`, `0.103.4` | `0.102.4`, `0.103.4` |
| `quinn` / `quinn-udp` | `0.11.9` / `0.5.14` | `0.11.9` / `0.5.14` |
| `web-transport-quinn` | `0.11.8` | `0.11.8` |

El manifest relay mantiene su dev-dependency exacta
`rustls = "=0.23.31"`, `default-features = false`, feature `ring` en
`moq-relay-ietf/Cargo.toml:73-78`. El código TLS native sigue construyendo
explícitamente el provider ring y TLS 1.3 en
`moq-native-ietf/src/tls.rs:54-56,93-97,107-114,152-154`.

El árbol de features actual sigue compilando la topología heredada con features
AWS-LC y ring debido a defaults de otros consumidores; Q/U1 no añade ni cambia
esa selección. No se afirma que AWS-LC sea inalcanzable en todo el workspace:
solamente que las coordenadas, manifests, feature edges y configuración
explícita revisada son idénticas a `HEAD`.

## Límite de seguridad preservado

El `HEAD` actual tiene exactamente el tree `d7f0c67...` aprobado en la
rerevisión final del source merge. Los anchors relevantes siguen siendo:

| Path | SHA-256 |
| --- | --- |
| `moq-native-ietf/src/quic.rs` | `92e94e527dce998543b050e1d4af0012b6c18df2b4e32c068ad9ebb46594934d` |
| `moq-relay-ietf/src/authorization.rs` | `101fc1a0a8c1fc8d61453f43617cbfef1913a7db91767f29c9e59b9970d148c2` |
| `moq-relay-ietf/src/relay.rs` | `8c0df50c59ca86c132272b573604e6a10657cd6781bb70f9ed384e1262c1b3e4` |
| `moq-relay-ietf/src/i2_tests.rs` | `c69ffa190430cd8662f249c461be94fd74e10d9ceabe188b028c91e1f37413ec` |
| `moq-transport/src/session/mod.rs` | `5fa5a8a1c8d68faf86553146eb7b0d39a7ee9aea6a41b97e4abf261500115b00` |

Por ausencia total de source/manifest diff:

- la evidencia I1 continúa derivándose después del handshake y de la misma
  `quinn::Connection` aceptada;
- C1/C2 siguen siendo límites de capacidad, nunca principal ni autorización;
- required continúa fail-closed, sin fallback a legacy, y consume evidencia
  prestada antes de resolver path/scope y antes de `SERVER_SETUP` o estado MoQT;
- autorización por operación/namespace y el segundo gate relay-peer conservan
  su ordering anterior a efectos;
- IP, SNI, path y `ConnectionTagger` no pasan a ser identidad;
- tracing, errores, métricas y mlog no ganan campos de certificado, contexto,
  principal, path, namespace, prefix, track o URL.

`quinn-proto` sí es código ejecutable en la frontera de conexión, no un cambio
meramente documental. La actualización elimina un panic por parámetros QUIC
inválidos y acota el overhead de fragmentos fuera de orden. La API pública
consumida sigue en `quinn 0.11.9`, y los tests raw QUIC/WebTransport del
snapshot combinado pasan con la versión nueva. `bytes 1.11.1` corrige el
overflow de `BytesMut::reserve`; no cambia manifests ni añade un límite de
identidad/autorización.

## RustSec independiente

Comandos conceptualmente equivalentes, sin red y sin allow/ignore:

```text
git show HEAD:Cargo.lock | cargo audit --json --no-fetch --db <db-a7bfe169> --file -
cargo audit --json --no-fetch --db <db-a7bfe169> --file Cargo.lock
```

| Snapshot | Exit | Entradas vulnerables | Warnings | JSON SHA-256 |
| --- | ---: | ---: | ---: | --- |
| `HEAD` | 1 | 19 | 6 | `9acb15382523f9a97bdbcd806e54f70d32f115b03bab3f9a2e44e33861968b1a` |
| staged Q+U1 | 1 | 16 | 6 | `9fd2fe4ed24c7885cb266fb654491af01034cdbea1f98e39e98fb14701d80ec3` |

El exit 1 no se oculta: corresponde al conjunto residual. La diferencia de
sets cierra exactamente:

| Lote | Advisory | Paquete vulnerable eliminado | Condición corregida en DB local |
| --- | --- | --- | --- |
| Q | `RUSTSEC-2026-0037` | `quinn-proto 0.11.13` | `>=0.11.14` |
| Q | `RUSTSEC-2026-0185` | `quinn-proto 0.11.13` | `>=0.11.15` |
| U1 | `RUSTSEC-2026-0007` | `bytes 1.6.0` | `>=1.11.1` |

Los ficheros primarios de esos advisories en la DB local tienen SHA-256
`23c4f8c202b1fb4b7ba239be728fb170635d31fe287dfa8f796b27b4082c4ba4`,
`4fbf203d415103793a22e88be9d32f81cc9e7b81e7869ae29df55f0675ea0378`
y `0fd14057008709641488380f5ef1ad5ab7876d90777ad01b229c2444f5d52174`,
respectivamente.

### 16 entradas vulnerables restantes

| Advisory | Paquete/version | Entrada(s) |
| --- | --- | ---: |
| `RUSTSEC-2024-0421` | `idna 0.5.0` | 1 |
| `RUSTSEC-2025-0055` | `tracing-subscriber 0.3.18` | 1 |
| `RUSTSEC-2026-0045` | `aws-lc-sys 0.30.0` | 1 |
| `RUSTSEC-2026-0046` | `aws-lc-sys 0.30.0` | 1 |
| `RUSTSEC-2026-0047` | `aws-lc-sys 0.30.0` | 1 |
| `RUSTSEC-2026-0048` | `aws-lc-sys 0.30.0` | 1 |
| `RUSTSEC-2026-0049` | `rustls-webpki 0.102.4` y `0.103.4` | 2 |
| `RUSTSEC-2026-0098` | `rustls-webpki 0.102.4` y `0.103.4` | 2 |
| `RUSTSEC-2026-0099` | `rustls-webpki 0.102.4` y `0.103.4` | 2 |
| `RUSTSEC-2026-0104` | `rustls-webpki 0.102.4` y `0.103.4` | 2 |
| `RUSTSEC-2026-0204` | `crossbeam-epoch 0.9.18` | 1 |
| `RUSTSEC-2026-0258` | `h2 0.4.5` | 1 |

### Seis warnings restantes

| Advisory | Clase | Paquete/version |
| --- | --- | --- |
| `RUSTSEC-2024-0436` | unmaintained | `paste 1.0.15` |
| `RUSTSEC-2025-0056` | unmaintained | `adler 1.0.2` |
| `RUSTSEC-2025-0134` | unmaintained | `rustls-pemfile 2.1.2` |
| `RUSTSEC-2026-0097` | unsound | `rand 0.8.5` |
| `RUSTSEC-2026-0097` | unsound | `rand 0.9.2` |
| `RUSTSEC-2026-0190` | unsound | `anyhow 1.0.85` |

## Validaciones ejecutadas

| Gate | Resultado |
| --- | --- |
| Lectura completa de `.cursorrules`; SHA-256 | PASS; 488 líneas, hash exacto |
| HEAD, padres, `MERGE_HEAD`, tree staged, pathset/status, stage/unstaged/tracking | PASS al inicio y al cierre |
| `git diff --cached --check` | PASS |
| Comparación TOML completa `HEAD:Cargo.lock` / staged | PASS; 336/336, sólo dos records sustituidos |
| `cargo metadata --locked --offline --format-version 1 --no-deps` | PASS; 9 packages/members |
| Rust/Cargo | `rustc 1.93.0`, `cargo 1.93.0`; imagen oficial `sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57` para metadata |
| `cargo tree --locked --offline -i quinn-proto@0.11.15` | PASS; único `quinn-proto`, vía `quinn 0.11.9`; raw/WebTransport conservados |
| árbol de features `rustls@0.23.31` y coordenadas provider | PASS; topología AWS-LC/ring heredada, sin movimiento |
| `cargo test --locked --offline -p moq-native-ietf` | PASS; 32 unit + 6 `peer_evidence`, cero fallos |
| `cargo test --locked --offline -p moq-relay-ietf` | PASS; 175 lib + 16 bin + 10 integración + 1 doctest; 202 pasados, 1 doctest ignorado, cero fallos |
| Cargo audit comparativo, DB y tool fijados | Resultado global rojo declarado; exactamente 3 entradas cerradas, ninguna añadida/suprimida |

Los tests se reejecutaron con red deshabilitada, source montado sólo lectura y
artefactos locales externos, usando Rust 1.93.0 en la imagen local inmutable
`sha256:ba076cf0a26aa41efdd2f0f80687ef97009d1526680751456c19cc944dff1d0b`.
La suite relay incluye las pruebas positivas required bounded raw QUIC y
WebTransport, certificado verificado con denegación pre-MoQ, evidencia/path
fail-closed, redacción, segundo gate y N+1 antes de una segunda autenticación.

El E0308 heredado en `moq-transport/src/serve/tracks.rs:501` continúa
`BLOCKED_BY_BASELINE_E0308`. No fue corregido, ocultado ni utilizado para
aprobar o rechazar este delta lock-only.

## Límites y estado final

- El lock revisado pertenece al workspace derivado. No sustituye el audit del
  lock consumidor de `gateway-rs` tras un futuro product pin.
- Este review no demuestra interoperabilidad externa, soak, resistencia DoS
  total, readiness productiva/comercial ni publicación.
- C1 y C2 continúan siendo controles de capacidad, no autenticación,
  autorización ni mTLS.
- La PKI/principal/policy Teremoq sigue fuera de upstream; Q/U1 no la añade.
- T es una decisión criptográfica independiente y permanece fuera del scope.
- Las 16 vulnerabilidades y seis warnings restantes siguen siendo gates
  explícitos; no existe excepción implícita en este informe.
- El SHA-256 de este informe se entrega externamente después de fijar sus bytes;
  no se auto-incrusta porque alteraría el propio digest.

No se modificó el worktree, index, merge metadata, refs, source, manifests,
lock, servicios o remotos. No se ejecutó checkout, stage, commit, fetch, push,
issue, PR, tag, release, instalación ni acceso de red. El único archivo creado
por este revisor es este informe.
