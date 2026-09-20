<!--
SPDX-FileCopyrightText: 2026 Teremoq contributors
SPDX-License-Identifier: Apache-2.0
-->

# Revisión TP-OSS-SC del source merge local I1/I2 + C1/C2

- Fecha: `2026-08-28`
- Perfil: `TP-OSS-SC`
- Worktree: `/home/jimbomilk/moq-rs-teremoq-integration-work`
- Alcance: supply chain, licencias y frontera de publicación del árbol staged
- Modo: read-only, offline y sin autoridad de publicación

Esta es una revisión técnica y no constituye asesoramiento jurídico. No
sustituye los dictámenes funcionales, de concurrencia o de seguridad PKI. El
plan de readiness se usó como contrato de comprobación, no como aprobación del
snapshot actual.

## Findings

### High — el source merge local no cierra los gates de integración o publicación

El staged source merge conserva exactamente el `Cargo.lock` de I2, SHA-256
`13b9f1c54ccbe644dcf4f07542f610950cd013b291c928b6b3ad39ac1751ce80`.
No incorpora Q/U1 y, por tanto, mantiene `quinn-proto 0.11.13` y `bytes 1.6.0`.
El informe final I2 registra para ese mismo lock 19 entradas vulnerables, 15
advisory IDs únicos y seis warnings contra la DB RustSec congelada. Esta
revisión no volvió a ejecutar `cargo audit`; la igualdad del lock demuestra que
el source merge no movió el grafo, no que el grafo esté libre de advisories.

El lote T también permanece fuera y sin decisión: `aws-lc-rs 1.13.3`,
`aws-lc-sys 0.30.0` y las dos líneas `rustls-webpki 0.102.4/0.103.4` no se
mueven. No existen todavía `deny.toml` revisado, SBOM reconciliado, packages
verificados desde un commit limpio ni release gates completos.

Además, `moq-transport/src/serve/tracks.rs` conserva SHA-256
`a8303c94925707a0a257923725bf84e4ec730b07d6bb2330fda5329b632fe0b7` y
el E0308 heredado de la línea 501. Sigue clasificado exclusivamente como
`BLOCKED_BY_BASELINE_E0308`, no como PASS. Bloquea la integración completa,
Objects, product pin y publicación, pero no es un cambio introducido por este
source merge.

### Medium — DCO del futuro merge commit aún no es demostrable

I2 y C2 contienen cada uno exactamente un `Signed-off-by` que coincide con su
author y tienen parentage aprobado. El commit de merge todavía no existe. El
estado actual propone, en este orden, I2 como primer parent y C2 como segundo:

```text
59d9a8601885ef934cae29d89876abb7c7f73e89
b4ee3b68df58bbb6e7b865c2898d3f46ffbb7fd1
```

La aprobación del tree exige que el futuro commit se cree sin cambiar el
índice, tenga exactamente esos dos parents y una única firma DCO 1.1 que
coincida con su author. Después del commit deben verificarse commit, tree,
parents y trailer. Una divergencia invalida este dictamen y requiere nueva
revisión; no se autoriza `--amend`, rebase o parent adicional.

### Medium — las claves privadas sintéticas siguen siendo material reutilizable

El árbol contiene claves privadas DER históricas I1/I2/C1 y el PEM C2. Son
bytes públicos, sintéticos y test-only con nombres genéricos, inventarios,
sidecars y warnings de no despliegue. No son secretos operativos, pero un
operador podría reutilizarlos indebidamente y los scanners seguirán
detectándolos o no interpretarán DER.

No se autoriza una supresión global de `private-key`, DER, PEM o `tests/data`.
Cualquier excepción futura debe ligarse a paths y hashes exactos y expirar
cuando cambie el fixture.

### Informational — el scan broad conserva un match heredado fuera del merge

El árbol completo produce, además del PEM C2 esperado, un match redactado en
`moq-relay-ietf/src/tls.rs:115`. Es sólo un delimitador PEM dentro de un
comentario, su blob es heredado de I2 y el path no está staged. No se suprimió
ni se presentó como secret del source merge.

### Informational — un marker broad es un subrayado Markdown heredado

El scan completo de líneas tipo conflicto encuentra
`moq-test-client/README.md:79`, una línea de `=` usada como subrayado Markdown.
El blob coincide con I2 y el path no está staged. Los 26 paths staged tienen
cero `<<<<<<<`, `=======` o `>>>>>>>` en inicio de línea.

### No finding bloqueante TP-OSS-SC en el staged tree exacto

El índice coincide con el tree congelado, sus 26 paths y todos sus hashes. Los
61 paths distintos del baseline son exactamente la unión de I2 y C2, sin path
extra o ausente. Veintidós blobs staged son byte-idénticos a C2 y sólo cuatro
son resoluciones nuevas de source/tests. No hay cambio de manifest, lock,
dependency, feature, provider, T, wire, licencia o product pin.

## Veredictos separados

**APPROVE FOR LOCAL MERGE COMMIT**

El veredicto aprueba únicamente la creación local de un merge commit sobre el
tree exacto `985f7f4ab4bad35c742f6c7028b1b8e6aec97e2b`, sujeto al gate de parents y
DCO anterior. No autoriza una segunda resolución, movimiento del índice,
integración de Q/U1, corrección E0308, product pin ni consumo por Teremoq.

**PUBLICATION: NOT READY**

No se autoriza fetch, push, branch remota, tag, PR, issue, release,
publicación, despliegue, modificación del verificador o cambio de product pin.

## Fuentes vinculantes

Se leyó `.cursorrules` completa, incluida la autonomía y el modelo
open-source. También se leyeron completamente las readiness de OSS,
plataforma/chaos y seguridad, el owner report, las revisiones finales
TP-OSS-SC I1/I2/C1/C2 y las aprobaciones finales C2 de plataforma y PKI.

| Evidencia | SHA-256 verificado |
|---|---|
| `.cursorrules` | `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2` |
| Readiness TP-OSS-SC | `7abcd8739c599aef8e2559cb0fd3375d93a6f5cea4102f30128a436e7785a92f` |
| Readiness TP-PLATFORM-CHAOS | `2bc3b73be58c01eb1831ea583c4fe6043c0bc0c6a30ace46fa9f3e842c816083` |
| Readiness TP-SEC-PKI | `e6807e5a64267fc01b7f5b9ceeee2d6f18bc922ed9ecdd100d740131aa5a06c6` |
| Owner report del source merge | `9c4c4c5bee4debaffda8aea10ef5653db9d29f6987119d83c83a02f9b22c21a7` |
| I1 final TP-OSS-SC | `6b0f1aaa0606eae264997907d31b0d442a4275f99f0d7550570a3895c65bacc3` |
| I2 final TP-OSS-SC | `1d0e80b5d1128989eb6413cb07fe932a835bc19d800ed262be4122fa6d27aecb` |
| C1 final TP-OSS-SC | `90bf9725e4e8f4eaf4e0c0829136e285be42d63e86b9f834513da9027b129544` |
| C2 final TP-OSS-SC | `365f21cdd754b82f90ef864c2961d5812b795fc3f48888b3974dcbc95150bea4` |
| C2 final TP-PLATFORM-CHAOS | `318f22a97e720608c45123ecd1e79829b96eb3f1da7979cdfdab81882e463c98` |
| C2 final TP-SEC-PKI | `d4a27e0333528b4f238875aed0e8423fa06c5dd425eef9f1944b8674cdcf96f9` |

Los informes fueron contraste, no sustituto de la inspección del índice y los
objetos Git.

## Binding Git y estado de merge

Todas las lecturas Git usaron `GIT_OPTIONAL_LOCKS=0`. No se ejecutó
`git write-tree`: se comprobó read-only que el índice no tiene diferencia
respecto del objeto tree esperado.

| Propiedad | Valor reproducido |
|---|---|
| Rama local | `teremoq/integration-draft16-bf87128-local` |
| Tracking | ninguno |
| `HEAD` / primer parent | `59d9a8601885ef934cae29d89876abb7c7f73e89` |
| Tree de `HEAD` | `d108208bfb5792767881a932480da01769844148` |
| `MERGE_HEAD` / segundo parent | `b4ee3b68df58bbb6e7b865c2898d3f46ffbb7fd1` |
| Tree de C2 | `1a4411f859d74d8ec93c30aac356c1b60f12ef92` |
| Merge base | `bf87128affd316463e5dcc7599a45001f222b6de` |
| Staged tree | `985f7f4ab4bad35c742f6c7028b1b8e6aec97e2b` |
| Índice versus staged tree | byte/object-equivalent, sin diff |
| Staged paths | 26 |
| Pathset SHA-256 | `c16063d311bc42b1baf16f314d11e3604cecc640be6542af826b09be20023470` |
| Status-z SHA-256 | `085eec09a457ee974eb9a7260c278516631ca4d7941262f197e675b87506933a` |
| Staged binary patch SHA-256 | `790b5f7a0618f3f4202f4b9196b3221a76528c9fab24b9639daa23f65c72016a` |
| Unmerged entries | cero |
| Unstaged paths | cero |
| `MERGE_HEAD` entries | una |
| Cached/worktree diff checks | pass/pass |

I2 tiene parent exacto I1
`05b41127ecbd48de4c59fe1626c43b1e423c33a9`. C2 tiene parent exacto C1
`ee22a1079783e374371e0705775978790ddd6471`, un delta de 15 paths y DCO
válido. El merge en curso conserva por diseño los objetos originales mediante
dos parents; no los reescribe por cherry-pick.

## Procedencia del source merge

Frente al baseline:

- I2 contiene 39 paths modificados;
- C2 contiene 25 paths modificados;
- su unión contiene 61 paths;
- el staged tree final contiene exactamente los mismos 61 paths;
- unión menos staged tree: cero; y
- staged tree menos unión: cero.

Frente a I2, el staged set contiene los 25 paths aportados por C2 más
`moq-relay-ietf/src/i2_tests.rs`, modificado para probar la composición. La
comparación blob por blob clasifica los 26 paths así:

- 22 blobs byte-idénticos a C2;
- 4 blobs nuevos de resolución; y
- cero blob ajeno a ambas series.

Las cuatro resoluciones nuevas son:

| Path | SHA-256 staged | Blob Git staged |
|---|---|---|
| `moq-native-ietf/src/quic.rs` | `92e94e527dce998543b050e1d4af0012b6c18df2b4e32c068ad9ebb46594934d` | `53d15423e0cea877377caf0ae589841845419823` |
| `moq-relay-ietf/src/i2_tests.rs` | `0917f6715ffba69c4b681679f17eeadffb46453b215fcff33e4e64c4d953e571` | `5e577a65ebf0d74b0d91b55ec78ea91166efcbae` |
| `moq-relay-ietf/src/lib.rs` | `833b732c738650c0ed6297c7094bdb8309da5953b9c51f950f58f1079f68b03c` | `2df427cf4c3a50501d18892cc105c6e05235a7d0` |
| `moq-relay-ietf/src/relay.rs` | `062bc828c7494e672cf8dbcd850e6b2a045792c2cf24256f702fccfdcf47d733` | `ef6f4decb985e51c7d015f4e6a780fa58371ba92` |

Cada una conserva el header upstream o Teremoq aplicable y declara
`MIT OR Apache-2.0`. Las otras 22 entradas staged reproducen exactamente los
blobs C1/C2 aprobados. No se usó una resolución whole-file `ours`/`theirs`.

## Inventario staged exacto

| Path | SHA-256 staged |
|---|---|
| `moq-native-ietf/src/quic.rs` | `92e94e527dce998543b050e1d4af0012b6c18df2b4e32c068ad9ebb46594934d` |
| `moq-native-ietf/src/quic_c1_tests.rs` | `610d8430315460db1652d99067002231d7ca4f2eaa48e8de2221966fa2cee8a9` |
| `moq-native-ietf/tests/data/c1/README.md` | `717d3219aa203034fde416b6e17f291e21ab9344a15e258a92aaaf3812a14e10` |
| `moq-native-ietf/tests/data/c1/SHA256SUMS` | `ba0f134515bdca4413dc9658d4016343a2180fd6c8f624e7e1b779f013696d64` |
| `moq-native-ietf/tests/data/c1/ca.cert.der` | `ea33add88bed4676c51baa4f8da9df33d04e99cecf7d0846a756e23b0f66461b` |
| `moq-native-ietf/tests/data/c1/ca.cert.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-native-ietf/tests/data/c1/server.cert.der` | `053a80b61f971f0601d83305ec6139fbcd7ed2f78c541078ac6e68a7e6da16bc` |
| `moq-native-ietf/tests/data/c1/server.cert.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-native-ietf/tests/data/c1/server.key.der` | `1d02d7ec66886fc2bb2cc3104851e1c182d7980e946d8df2e8f0f3ae33c30436` |
| `moq-native-ietf/tests/data/c1/server.key.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-relay-ietf/src/i2_tests.rs` | `0917f6715ffba69c4b681679f17eeadffb46453b215fcff33e4e64c4d953e571` |
| `moq-relay-ietf/src/lib.rs` | `833b732c738650c0ed6297c7094bdb8309da5953b9c51f950f58f1079f68b03c` |
| `moq-relay-ietf/src/relay.rs` | `062bc828c7494e672cf8dbcd850e6b2a045792c2cf24256f702fccfdcf47d733` |
| `moq-relay-ietf/src/relay_c2_tests.rs` | `5ebccdf289a5b4183b28e78ee56dfad7f991a2c4c58eda27327c5e88f8033237` |
| `moq-relay-ietf/src/remote.rs` | `5a5a30536280fe946db0df969b1ae81099186838ec69904128a15e0ff15cf8a4` |
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

Todos usan modo final `100644`. No hay symlink (`120000`), submodule/gitlink
(`160000`) o cambio de modo en el staged set ni en el staged tree completo.

## Frontera de manifests, lock, protocolo y producto

Los diez `Cargo.toml` son byte-idénticos a I2. También lo son los siguientes
inputs protegidos:

| Input | SHA-256 staged |
|---|---|
| Root `Cargo.toml` | `6665802c9ad7192d61521a62877454e25bde7072c611e617780a932f583aa48f` |
| `moq-native-ietf/Cargo.toml` | `3180121a89c58071718236a408f36c1c87757d6f9ff81e899fb3b5814c8d4c8e` |
| `moq-relay-ietf/Cargo.toml` | `83185ddb3f1523a6d7d9c577abbf29010eb34d6043538c1b28ff1057bb888b11` |
| `moq-transport/Cargo.toml` | `78f582c201082f7badece64f7fa65d215a6694412b7a7699332fa3bc9a4f3743` |
| `Cargo.lock` | `13b9f1c54ccbe644dcf4f07542f610950cd013b291c928b6b3ad39ac1751ce80` |
| Setup/ALPN | `c49d71dcacd5e3f5eef7a673e11b9058d3fd701e1fb83331a737098894a2d750` |
| Setup version | `384772b32812a0761fa55d16a9fd29e30595323ece1b3fca013ec3720eaec4ad` |
| Message/wire module | `e5760f5ce2927b2437511b3e616fea2615d82e916d4b6036b7f5450ae0973352` |
| Transport session | `5fa5a8a1c8d68faf86553146eb7b0d39a7ee9aea6a41b97e4abf261500115b00` |
| Transport tracks | `a8303c94925707a0a257923725bf84e4ec730b07d6bb2330fda5329b632fe0b7` |
| `REUSE.toml` | `afc7fd86e591a56078b11982ee4d039ea1dfe3f9d56a90e3e7fa9f84fbddb6cc` |
| MIT text | `c7d191b5901a741f2e39c74bd7a7594014a81fbe2bc7d533d4c29ad4cfe4e057` |
| Apache-2.0 text | `1248f876e0140942002b476a19c95d5b5b44c625e69c96611d23119ee87fa04e` |

El lock contiene 336 records, conserva sólo la edge dev I2 directa
`moq-relay-ietf -> rustls =0.23.31`, `default-features = false`, feature
`ring`, y mantiene `bytes 1.6.0`, `quinn-proto 0.11.13`,
`aws-lc-rs 1.13.3`, `aws-lc-sys 0.30.0` y `rustls-webpki
0.102.4/0.103.4`. No se incorporó Q, U1 o T.

`cargo metadata --locked --offline --no-deps` pasa con nueve packages, todos
`MIT OR Apache-2.0`; relay conserva 25 registros de dependencia, una única
edge dev Rustls exacta y sólo las features `default` y
`metrics-prometheus`.

No hay path de `gateway-rs`, Docker, workflow, release, mirror governance o
pin de producto dentro del staged set.

## Licencias y REUSE

Las cuatro resoluciones conservan los copyrights upstream/Teremoq aplicables y
declaran `MIT OR Apache-2.0`. Los tests y documentos nuevos usan la misma
expresión dual. Los binarios no se alteran con comentarios: tienen sidecars
individuales.

REUSE 5.1.1, GPL-3.0-or-later, se ejecutó desde la imagen oficial local:

```text
fsfe/reuse@sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da
```

Con red deshabilitada y source read-only obtuvo:

- 223/223 ficheros con copyright;
- 223/223 con licencia;
- cero bad, deprecated, missing, unused o read errors; y
- sólo MIT y Apache-2.0.

El resultado corresponde a REUSE Specification 3.3; no es una opinión legal.

## Fixtures y procedencia

El árbol contiene 18 payloads DER/PEM y exactamente 18 sidecars. Todos los
sidecars son byte-idénticos, SHA-256
`5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0`,
y declaran `MIT OR Apache-2.0`.

- los cinco DER I2 comparan byte a byte con sus fuentes I1;
- los tres DER C1 comparan byte a byte con sus fuentes I1;
- los inventarios I2 y C1 pasan completos;
- los tres PEM C2 pasan sus checks locales;
- CA, certificado y PKCS#8 C2 decodifican byte a byte a los DER C1; y
- las claves públicas derivadas de certificado y key C2 coinciden.

Los metadatos X.509 ya ligados a estos hashes usan nombres genéricos de test,
SAN loopback y no codifican una identidad Teremoq o de cliente. Los README
declaran el material público, sintético, test-only y no desplegable. No se
imprimió contenido de clave.

## Secret scan y frontera de datos

Gitleaks 8.30.1/MIT se ejecutó sin red, custom config, allowlist o suppression,
con `--redact=100`, desde:

```text
zricethezav/gitleaks@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f
```

| Alcance | Resultado |
|---|---|
| Cuatro resoluciones nuevas, 226.976 bytes | exit 0, cero findings |
| 26 paths staged, 494.010 bytes | exit 1, exactamente un finding esperado |
| Árbol completo, 1.966.269 bytes | exit 1, exactamente dos findings esperados |

El finding del staged set es:

- path: `moq-relay-ietf/tests/data/c2/server.key.pem`;
- línea: 1;
- rule: `private-key`;
- match y secret: `REDACTED` al 100 %;
- estado: fixture sintético público documentado.

El segundo finding broad es el comentario heredado de `tls.rs:115` descrito
en Findings. Los DER se validaron por hash y parseo; la ausencia de un finding
binario no se trató como ausencia de claves privadas.

La clasificación complementaria de los 20 paths staged textuales no-PEM
obtuvo cero rutas locales de usuario, rutas Windows de usuario, emails, SPIFFE
IDs, URLs autenticadas o asignaciones de credenciales. Las 34 URLs son 29
loopback y cinco reservadas bajo `example.com`; las 16 IPv4 son 14 loopback y
dos unspecified. No hay endpoint de cliente, namespace productivo, identidad
de despliegue, dato operativo, token, cookie, password o trust material real.

## Package boundaries

Con Cargo 1.93.0, source read-only, caches preexistentes read-only, target en
tmpfs, `--network none`, `--locked --offline` y `--allow-dirty`, se ejecutó
`cargo package --list` para los tres crates:

| Crate | Entradas | Evidencia de frontera |
|---|---:|---|
| `moq-native-ietf` | 32 | siete fixtures I1, C1 completo, `peer_evidence.rs` y `quic_c1_tests.rs` |
| `moq-transport` | 97 | `pending_accept.rs`, sin cambio wire/manifest |
| `moq-relay-ietf` | 48 | I2 completo, C2 completo, tests I2/C2 |

Cada lista contiene cero `target/`, cache, bytecode, objeto, biblioteca,
ejecutable, BusyBox o path absoluto/`..` que escape del crate. Todos los
`include_bytes!` e `include_str!` resuelven dentro de su package. La repetición
sin `--allow-dirty` y la verificación de tarballs quedan para después del
commit; este informe no declara release readiness.

## Generated artifacts, BusyBox y cleanup

El worktree no contiene `target/`, `.cache`, `__pycache__`, bytecode, objetos,
bibliotecas o ejecutables generados. El inventario Docker local contiene cero
imagen o contenedor BusyBox y cero coincidencia con el antiguo digest
`sha256:dc2d74b28e4cf8984fa52af1f39bc7c3d9c73760b41a74d629f5d11b1ab28616`.

Todos los contenedores propios fueron efímeros, `--rm`, sin red y con source
read-only. Los targets y staging de scanners existieron sólo en tmpfs. No se
tocó ningún contenedor o cache ajeno.

## Herramientas y límites

| Herramienta | Versión/digest | Licencia / uso |
|---|---|---|
| Git | 2.53.0 | GPL-2.0-only; objetos, index y diff read-only |
| Python | 3.14.4 | PSF-2.0; comparación de sets/lock y clasificación redactada |
| Docker | 28.3.3 | Apache-2.0; aislamiento local offline |
| OpenSSL | 3.5.5 | Apache-2.0; DER/PEM y pairing sin mostrar keys |
| REUSE | 5.1.1 / digest anterior | GPL-3.0-or-later; SPDX/REUSE |
| Gitleaks | 8.30.1 / digest anterior | MIT; scans redactados |
| Cargo | 1.93.0 / `teremoq-step7-lab@sha256:ba076cf0a26aa41efdd2f0f80687ef97009d1526680751456c19cc944dff1d0b` | MIT OR Apache-2.0; metadata/package list |

No se repitieron builds o tests grandes. El owner report liga al mismo staged
tree los resultados funcionales; esta revisión no los representa como
ejecución propia. Tampoco se ejecutaron cargo-audit, cargo-deny o SBOM. Sus
gates permanecen abiertos y no se afirma cumplimiento.

## Gate exacto posterior al commit

Antes de considerar cerrado el merge local, el owner debe comprobar sobre el
commit recién creado:

1. tree exacto `985f7f4ab4bad35c742f6c7028b1b8e6aec97e2b`;
2. exactamente dos parents y en orden I2, C2;
3. exactamente un `Signed-off-by` igual al author;
4. branch sin tracking y status vacío;
5. cero commit extra o path adicional; y
6. los mismos 26 hashes y los mismos gates de diff/markers.

El commit resultante requiere freeze por SHA antes de que otra operación lo
consuma. Q/U1 se integran sólo en un merge posterior separado y revisado; T no
se integra sin decisión expresa del usuario.

## Confirmación final de actividad

Al finalizar se reprodujeron de nuevo HEAD, MERGE_HEAD, staged tree, pathset,
status-z, cero unmerged/unstaged y los 26 hashes. No se editó source, index,
estado de merge, manifest, lock, test, fixture, ref, configuración Git, remote
o informe existente.

No hubo checkout, add, commit, merge abort, fetch, push, tag, PR, issue,
release, publicación, descarga, instalación, comunicación externa ni mutación
remota. Sólo se creó este informe en el repositorio Teremoq.

**LOCAL SOURCE-MERGE SUPPLY-CHAIN REVIEW ONLY / NOT PUBLISHED / NO REMOTE MUTATION**
