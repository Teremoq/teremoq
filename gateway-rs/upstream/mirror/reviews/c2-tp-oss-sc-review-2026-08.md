<!--
SPDX-FileCopyrightText: 2026 Teremoq contributors
SPDX-License-Identifier: Apache-2.0
-->

# Revisión independiente TP-OSS-SC de C2

- Fecha: 2026-08-28
- Perfil: `TP-OSS-SC`
- Alcance: supply chain y frontera de publicación del snapshot C2 local
- Worktree revisado: `/home/jimbomilk/moq-rs-teremoq-c2-work`
- Autoridad remota o de publicación: ninguna

Esta revisión es técnica y no constituye asesoramiento jurídico. Tampoco
sustituye la revisión funcional de `TP-RUST-DIST`, las pruebas de
`TP-PLATFORM-CHAOS` ni la revisión de identidad de `TP-SEC-PKI`.

## Findings

### High — publicación bloqueada por gates heredados, no por el delta C2

C2 parte del lock baseline SHA-256
`b518a2fa4a6d7a0ffe0bdfe4b530f05196ac0f5e6f7ef51da9e5a83c0b0561c0`.
No incorpora los lotes RustSec Q/U1 ni el resto del plan de remediación. La
auditoría congelada ya documentada para ese lock contiene 19 entradas
vulnerables y seis warnings. C2 no añade dependencia o versión, pero tampoco
cierra esos findings.

La publicación también sigue bloqueada por la ausencia de un `deny.toml`
revisado, SBOM final reconciliado, release gates completos, rulesets activos y
la secuencia autorizada de integración/publicación.

### Medium — Clippy y rustfmt siguen sin evidencia en la imagen exigida

El informe owner, SHA-256
`33e3fb8949f5107a0c8044a0169d8bc72628e91fa5677a3200a187b139308ffa`,
registra que la imagen Rust 1.93 exigida no contiene los componentes Clippy y
rustfmt. El owner mantiene por ello estado `CHANGES REQUIRED` y también conserva
el E0308 heredado de `moq-transport/src/serve/tracks.rs:501`.

Esta revisión no duplicó la matriz de plataforma ni convierte esos gates en
pass. El veredicto TP-OSS-SC posterior sólo cubre el delta publicable y no
revoca el estado del owner ni autoriza integración global.

### Medium — la clave privada pública de test seguirá activando scanners

`moq-relay-ietf/tests/data/c2/server.key.pem` es material privado en sentido
criptográfico, pero no es secreto operativo: es una codificación determinista
de la clave sintética pública ya versionada en C1. El README la marca
explícitamente como pública/no productiva y prohíbe su uso en despliegues.

Gitleaks la detecta correctamente. El finding no debe suprimirse globalmente ni
reinterpretarse como credencial productiva. El riesgo residual es que alguien
reutilice el fixture fuera de tests o que un control automático no distinga la
excepción documentada; el package y SBOM deben conservar la advertencia y
procedencia.

### Closed — incidente operativo BusyBox

El informe owner registra que una inspección ejecutó accidentalmente
`busybox:latest`, provocó un pull y después eliminó exactamente la imagen
obtenida. La imagen tenía ID/digest
`sha256:dc2d74b28e4cf8984fa52af1f39bc7c3d9c73760b41a74d629f5d11b1ab28616`.

La comprobación independiente actual confirma:

- `busybox:latest` no existe localmente;
- el ID/digest exacto no existe localmente;
- no hay contenedores con ese tag o ancestor;
- ninguna ruta del delta menciona BusyBox; y
- el inventario de package contiene cero artefactos BusyBox.

El incidente queda cerrado, pero se conserva en la evidencia; no se oculta ni
se presenta como si nunca hubiera ocurrido.

### No finding bloqueante TP-OSS-SC en C2

El delta está acotado a 15 rutas de `moq-relay-ietf`, conserva la licencia dual
upstream, pasa REUSE 204/204 y no modifica manifests, lock, dependencias,
features, proveedores, código nativo, transporte ni wire. Los únicos
artefactos con apariencia de credencial son los fixtures sintéticos públicos
documentados.

## Veredictos

**APPROVE FOR LOCAL COMMIT**

Este veredicto se limita a la frontera supply-chain de las 15 rutas y exige:

1. que el futuro commit contenga exactamente el inventario y hashes revisados;
2. que lleve DCO 1.1 mediante `Signed-off-by`;
3. que no absorba I1, I2, Q, U1, manifests, lock ni otro worktree; y
4. que el Master trate por separado los gates del owner, plataforma y PKI.

C2 está sin commit, por lo que DCO todavía no es aplicable ni demostrable. El
stage vacío no equivale a un sign-off futuro.

**PUBLICATION: NOT READY**

No se autoriza push, branch remota, tag, release, PR, issue, publicación ni
cambio de product pin.

## Binding Git e inventario exacto

La inspección read-only produjo:

| Propiedad | Valor |
|---|---|
| Rama | `teremoq/c2-session-shutdown-ee22a10` |
| `HEAD` / base | `ee22a1079783e374371e0705775978790ddd6471` |
| Tree | `232e449945e877b024f2fc4223f0d2eea124b39b` |
| Tracking branch | ninguna |
| Stage | vacío |
| Entradas de status | 15 |
| SHA-256 de `git status --short --untracked-files=all` | `41969b3ff7d7ebcaaf891137a17519a2097319642b6753db144a0b5a000db614` |
| `git diff --check` | pass |
| `git diff --cached --check` | pass, sin delta cached |

Las 15 rutas son exactamente:

1. `moq-relay-ietf/src/lib.rs`
2. `moq-relay-ietf/src/relay.rs`
3. `moq-relay-ietf/src/relay_c2_tests.rs`
4. `moq-relay-ietf/src/remote.rs`
5. `moq-relay-ietf/src/session_admission.rs`
6. `moq-relay-ietf/src/upstream_namespaces.rs`
7. `moq-relay-ietf/tests/c2_session_admission.rs`
8. `moq-relay-ietf/tests/data/c2/README.md`
9. `moq-relay-ietf/tests/data/c2/SHA256SUMS`
10. `moq-relay-ietf/tests/data/c2/ca.cert.pem`
11. `moq-relay-ietf/tests/data/c2/ca.cert.pem.license`
12. `moq-relay-ietf/tests/data/c2/server.cert.pem`
13. `moq-relay-ietf/tests/data/c2/server.cert.pem.license`
14. `moq-relay-ietf/tests/data/c2/server.key.pem`
15. `moq-relay-ietf/tests/data/c2/server.key.pem.license`

Todas están bajo el crate permitido. Hay cuatro ficheros tracked modificados y
11 nuevos; ninguna ruta está staged.

## Hashes del delta

| Ruta | SHA-256 |
|---|---|
| `src/lib.rs` | `7221542f360df88d2eb552198ce1c9ca37f7380c5229d2ccc76a22041eb0f0bf` |
| `src/relay.rs` | `07b48b84ca57bab60ca8e0cce9096eac5bde6aa94a544cc4a96f9e4317356e6c` |
| `src/relay_c2_tests.rs` | `f76ea25d9be4379ddf04fa063bb3d0ed1d91f738ede76c45d3a4bec7c10f2238` |
| `src/remote.rs` | `9a012fc2e698864f3e5286d97461010840f236fc25c4373f4efffd1b4727b7d8` |
| `src/session_admission.rs` | `1bb5f79e24d52ada9fd402d14eca6bd6bb8a50276d90931b04f7d1e1959cfd3d` |
| `src/upstream_namespaces.rs` | `7033823b66d5e3e82c0e6afdf2e4062080b908ed11c0aedb4550bd2f7cd775b9` |
| `tests/c2_session_admission.rs` | `eab3296eed7b97ec3987259298d20cacafabd96c7c633f07b46f7f40ced760bc` |
| `tests/data/c2/README.md` | `285e4e178ecd6a7c5cffe5409107bc11bdf096bba9ebc014e805c0b991c1ae72` |
| `tests/data/c2/SHA256SUMS` | `ccc4d9cbcc23c31cfd12e2ef5d0a57e6d0901c243f7a732fc6eba20a7c82c8fd` |
| `tests/data/c2/ca.cert.pem` | `c439d7428d418762e090e1ce0fdda1524473daa66f052da251e120d78555dfbb` |
| `tests/data/c2/ca.cert.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `tests/data/c2/server.cert.pem` | `76fe11a03423308533516c61c8e06f994746293313ef8961091de0e87cbd2b09` |
| `tests/data/c2/server.cert.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `tests/data/c2/server.key.pem` | `607642c80b7ec6e365ef877e24c526ca546542fb5c330ae191891a212b67aa35` |
| `tests/data/c2/server.key.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |

El diff tracked suma 1.579 inserciones y 74 borrados. Los siete ficheros Rust
del inventario fueron revisados como contribution boundary; la revisión no
afirma corrección funcional más allá de la evidencia del owner.

## Ausencia de cambios de dependencias, providers y protocolo

La comparación current/base no encuentra ningún path en:

- `Cargo.toml`, `Cargo.lock` o cualquier manifest del workspace;
- `moq-native-ietf`;
- `moq-transport`;
- `LICENSES/` o `REUSE.toml`.

Hashes current/base byte-idénticos:

| Input protegido | SHA-256 |
|---|---|
| workspace `Cargo.toml` | `6665802c9ad7192d61521a62877454e25bde7072c611e617780a932f583aa48f` |
| `Cargo.lock` | `b518a2fa4a6d7a0ffe0bdfe4b530f05196ac0f5e6f7ef51da9e5a83c0b0561c0` |
| relay `Cargo.toml` | `c88726b7739c35c4fcb42fd511bfe608e478b5d2489729081821fc84cd1b318d` |
| native `Cargo.toml` | `3180121a89c58071718236a408f36c1c87757d6f9ff81e899fb3b5814c8d4c8e` |
| transport `Cargo.toml` | `78f582c201082f7badece64f7fa65d215a6694412b7a7699332fa3bc9a4f3743` |
| native QUIC | `b0c8dfb3e4963365a3a27f52a84d2fc54292cfc5a056a817a5a0d0a4f38b3723` |
| setup/ALPN | `c49d71dcacd5e3f5eef7a673e11b9058d3fd701e1fb83331a737098894a2d750` |
| setup version | `384772b32812a0761fa55d16a9fd29e30595323ece1b3fca013ec3720eaec4ad` |
| transport session | `8e8992e1bb75d77c2475499014509a9362b965162d86156bdf6068a16b3cd2ea` |
| Apache-2.0 | `1248f876e0140942002b476a19c95d5b5b44c625e69c96611d23119ee87fa04e` |
| MIT | `c7d191b5901a741f2e39c74bd7a7594014a81fbe2bc7d533d4c29ad4cfe4e057` |
| `REUSE.toml` | `afc7fd86e591a56078b11982ee4d039ea1dfe3f9d56a90e3e7fa9f84fbddb6cc` |

No hay addition que seleccione AWS-LC, ring, FIPS u otro crypto provider. No
se modifica crate nativa, transporte, QUINN, Rustls, WebTransport, ALPN
`moqt-16`, draft-16, varints, frames, Objects, features o pins.

`cargo metadata --locked --offline --no-deps` pasa: nueve packages del
workspace, todos `MIT OR Apache-2.0`; `moq-relay-ietf 0.7.25` conserva 24
dependency records.

## Licencia de contribución y REUSE

Los ficheros nuevos de Teremoq declaran `MIT OR Apache-2.0`, la misma expresión
del componente upstream. Los ficheros existentes conservan sus cabeceras
upstream duales; no se elimina copyright ni notice.

Los PEM no admiten cabecera sin romper sintaxis y usan sidecars `.license` con:

```text
SPDX-FileCopyrightText: 2026 Teremoq contributors
SPDX-License-Identifier: MIT OR Apache-2.0
```

REUSE 5.1.1 se repitió desde la imagen oficial local fijada:

```text
fsfe/reuse@sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da
```

Tool license: GPL-3.0-or-later, fuera del artefacto Teremoq. Resultado con red
deshabilitada, worktree read-only y `target/` oculto mediante tmpfs:

- 204/204 con copyright;
- 204/204 con licencia;
- cero bad/deprecated/missing/unused/read errors; y
- únicas licencias usadas: MIT y Apache-2.0.

La declaración de cumplimiento es sobre REUSE Specification 3.3 y este source
snapshot; no es una conclusión jurídica sobre distribución comercial.

## Procedencia de fixtures

Los tres PEM son representaciones deterministas de los fixtures DER públicos
de C1:

| Artefacto C2 | SHA-256 PEM | SHA-256 DER decodificado | Fuente C1 |
|---|---|---|---|
| `ca.cert.pem` | `c439d7428d418762e090e1ce0fdda1524473daa66f052da251e120d78555dfbb` | `ea33add88bed4676c51baa4f8da9df33d04e99cecf7d0846a756e23b0f66461b` | `ca.cert.der` exacto |
| `server.cert.pem` | `76fe11a03423308533516c61c8e06f994746293313ef8961091de0e87cbd2b09` | `053a80b61f971f0601d83305ec6139fbcd7ed2f78c541078ac6e68a7e6da16bc` | `server.cert.der` exacto |
| `server.key.pem` | `607642c80b7ec6e365ef877e24c526ca546542fb5c330ae191891a212b67aa35` | `1d02d7ec66886fc2bb2cc3104851e1c182d7980e946d8df2e8f0f3ae33c30436` | PKCS#8 `server.key.der` exacto |

OpenSSL 3.5.5 confirmó que la clave corresponde al certificado sin imprimir su
valor. Los metadatos son sintéticos y no productivos:

- CA subject/issuer: `CN=moq-native-ietf-test-ca`;
- servidor subject: `CN=moq-native-ietf-server`;
- SAN: sólo `localhost` y `127.0.0.1`;
- validez: 2026-08-26 a 2036-08-23; y
- seriales genéricos, sin identificador de cliente o Teremoq productivo.

No se encontró SPIFFE ID, identidad productiva, endpoint externo, namespace
concreto de cliente, dato operativo ni trust material real. Las únicas URLs
introducidas por C2 son loopback `localhost`; los ejemplos reservados
`example.com` de ficheros modificados ya eran material de test/documentación,
no configuración cliente.

## Escaneo redactado de secretos

Gitleaks 8.30.1, licencia MIT, se ejecutó desde la imagen local fijada:

```text
zricethezav/gitleaks@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f
```

Ambas ejecuciones usaron `--network none`, mounts read-only,
`--redact=100`, sin ignore ni suppression.

### Code y documentación focal

- alcance: los siete paths Rust cambiados, README y SHA256SUMS;
- volumen: aproximadamente 216.046 bytes;
- exit: 0;
- findings: cero.

### Fixtures C2

- alcance: directorio completo `tests/data/c2`;
- volumen: aproximadamente 3.079 bytes;
- exit: 1 esperado;
- findings: exactamente uno;
- rule: `private-key`;
- fichero: `server.key.pem`;
- líneas: 1-5;
- match y secret: totalmente redactados.

La clasificación como fixture público se sostiene además en la igualdad DER,
README, sidecar, SAN loopback y ausencia de material operativo. No se basa sólo
en que Gitleaks encuentre una única coincidencia.

## Packaging y exclusión de artefactos generados

`cargo package --list --allow-dirty --locked --offline -p moq-relay-ietf` se
repitió con:

- imagen Rust fijada
  `teremoq-step7-lab@sha256:ba076cf0a26aa41efdd2f0f80687ef97009d1526680751456c19cc944dff1d0b`;
- red deshabilitada;
- source read-only;
- registry cache read-only; y
- target y Cargo scratch en tmpfs.

Resultado: pass, 34 rutas. Incluye los nuevos source/tests y los ocho
artefactos `tests/data/c2` — README, SHA256SUMS, tres PEM y tres sidecars.

No incluye `target/`, BusyBox, imagen OCI, binary, cache, directorio local ni
path exterior al crate. Comprobaciones complementarias:

- cero paths tracked bajo `target/`;
- cero entradas C2 de status bajo `target/`;
- `.gitignore:6` mantiene `target/` ignorado; y
- package list: cero `target/` y cero `busybox`.

El tmpfs evita que la validación cree un artefacto source-side. No se editó el
worktree para ocultar `target/`.

## Datos sensibles y frontera pública

Además de Gitleaks se revisaron contenido, metadata X.509 y strings añadidos.
El delta no contiene:

- tokens, cookies, passwords, API keys o URLs autenticadas;
- rutas locales de usuario;
- emails o datos personales;
- IP externa, endpoint o URL de cliente;
- SPIFFE IDs, principals, roles o namespaces productivos;
- certificados/trust roots productivos; ni
- logs, payloads o datos operativos.

Los términos `CancellationToken`, namespace types/counters y certificados de
fixture no son credenciales. Los snapshots públicos nuevos contienen sólo
contadores y estados de baja cardinalidad; la ausencia de identidad en ellos
también está cubierta por tests del owner, pero este informe no sustituye la
revisión formal TP-SEC-PKI.

## Gates residuales y límites

Esta revisión no repitió builds grandes ni pruebas de concurrencia/plataforma.
Se limitó a metadata, package, REUSE, secret scan, hashes, provenance y
frontera de publicación, como fue solicitado.

Antes de publicación siguen pendientes:

- resolver el gate de Clippy/rustfmt de la imagen exigida;
- mantener visible el E0308 heredado de Objects;
- completar revisión TP-PLATFORM-CHAOS y TP-SEC-PKI;
- integrar secuencialmente los lotes RustSec y obtener audit limpio;
- policy cargo-deny, SBOMs y release evidence finales;
- revisión del commit DCO real; y
- inventario/ref verifier/rulesets de la rama que eventualmente se autorice.

`APPROVE FOR LOCAL COMMIT` no afirma DoS resistance productiva, límite total de
memoria, mTLS productivo, interoperabilidad cerrada ni readiness comercial.

## Herramientas y actividad

Herramientas usadas sin instalación:

| Herramienta | Versión/digest | Licencia/uso |
|---|---|---|
| Git | 2.53.0 | inspección local |
| Python | 3.14.4 | inventario/hash auxiliar |
| Docker | 28.3.3 | ejecutar herramientas fijadas sin red |
| OpenSSL | 3.5.5 | Apache-2.0; DER/X.509/key match |
| REUSE | 5.1.1 / digest anterior | GPL-3.0-or-later; lint source |
| Gitleaks | 8.30.1 / digest anterior | MIT; scan redactado |
| Cargo/Rust | 1.93.0 / imagen anterior | metadata/package únicamente |

Al finalizar, branch, HEAD, tree, inventario, stage vacío y hash de status C2
seguían iguales. No hubo checkout, branch, add, commit, config, clean, fetch,
push, tag, release, PR, issue, mensaje, publicación ni mutación remota. No se
instaló herramienta ni se usó red.

Sólo se creó este informe en el repositorio Teremoq.

**LOCAL SUPPLY-CHAIN REVIEW ONLY / NOT PUBLISHED / NO REMOTE MUTATION**
