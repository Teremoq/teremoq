<!--
SPDX-FileCopyrightText: 2026 Teremoq contributors
SPDX-License-Identifier: Apache-2.0
-->

# Tercera rerevisión formal TP-OSS-SC de C2

- Fecha: `2026-08-28`
- Perfil: `TP-OSS-SC`
- Alcance: supply chain y frontera de publicación del snapshot C2 local
- Worktree revisado: `/home/jimbomilk/moq-rs-teremoq-c2-work`
- Modo: read-only, offline y sin autoridad de publicación

Esta es una revisión técnica, no asesoramiento jurídico. No sustituye la
revisión funcional Rust, de resiliencia de plataforma o de seguridad PKI.
Tampoco usa el plan de integración local como evidencia o veredicto C2.

## Findings

### High — la publicación continúa bloqueada por gates globales ajenos a C2

El `Cargo.lock` permanece byte-idéntico a C1, SHA-256
`b518a2fa4a6d7a0ffe0bdfe4b530f05196ac0f5e6f7ef51da9e5a83c0b0561c0`.
C2 no añade ni mueve paquetes, versiones, features o providers, pero tampoco
integra los lotes RustSec Q/U1 ni remedia el inventario baseline ya documentado
de 19 entradas vulnerables y seis warnings. Esta rerevisión no ejecutó
`cargo audit`: la igualdad exacta del lock demuestra ausencia de movimiento
del grafo, no ausencia de advisories.

El futuro lote T (`aws-lc-rs`, `aws-lc-sys`, `rustls-webpki` y auxiliares)
sigue siendo una decisión criptográfica separada y no autorizada. También
siguen pendientes `deny.toml`, SBOM reconciliado, gates de release, inventario
y verificador de refs, y una integración local autorizada y reproducible.

### Medium — las nuevas rerevisiones de plataforma y PKI siguen pendientes

Las revisiones `TP-PLATFORM-CHAOS` y `TP-SEC-PKI` leídas tienen los SHA-256
vinculantes pedidos, pero emitieron `CHANGES REQUIRED` sobre el snapshot
anterior. El owner report actual afirma correcciones y cambia tres hashes de
código. Esta revisión confirma su frontera supply-chain, no la corrección de
las carreras, lifecycle o semántica de seguridad. Nuevas rerevisiones de esos
perfiles son condición para integración y publicación.

Esto no crea un finding bloqueante dentro del gate local TP-OSS-SC, pero este
dictamen no debe presentarse como aprobación funcional global de C2.

### Medium — la clave privada sintética seguirá activando secret scanners

`moq-relay-ietf/tests/data/c2/server.key.pem` es una clave privada real en
sentido criptográfico y Gitleaks la detecta correctamente. Su igualdad binaria
con el fixture público C1, los metadatos loopback, el README y el sidecar
demuestran que es material sintético público de test y no trust material
operativo.

El riesgo residual es su reutilización accidental fuera de tests o que un gate
automático falle si no trata de forma focal este fixture esperado. No se
autoriza una supresión global ni se rebaja la regla `private-key`.

### Low — `SHA256SUMS` mezcla checks locales y procedencia externa al directorio

Las tres entradas PEM locales pasan. Las tres entradas DER finales registran
la procedencia C1 y sus ficheros no están duplicados en el directorio C2. Un
`sha256sum -c SHA256SUMS` ejecutado sin separar ambos grupos informa por ello
DER ausentes. La comparación correcta pasa: cada PEM decodifica exactamente al
DER C1 indicado. Un gate futuro debe verificar por separado payload local y
paths de procedencia.

### Low — los logs Remote no son el nuevo seam redactado

El componente conserva logs de lifecycle que etiquetan `remote_url` después
de una admisión válida. No contienen un endpoint embebido en el artefacto y no
forman parte de los nuevos errores fijos ni de los snapshots públicos de baja
cardinalidad. Esta revisión no amplía esa observabilidad ni afirma que una URL
de runtime sea un dato no sensible en todo despliegue privado.

La corrección revisada sí cumple la frontera solicitada: el nuevo error de
invariante es privado y fijo; los nuevos probes sólo transportan contadores y
señales de test; ninguno incorpora URL, peer, path, namespace o identidad.

### Closed — cleanup local y antiguo incidente BusyBox

El source C2 no contiene `target/`, `.cache`, `__pycache__`, bytecode, objetos,
bibliotecas ni ejecutables generados. El antiguo `target/` preexistente sigue
fuera del worktree, sin borrado, en:

```text
/home/jimbomilk/.cache/moq-rs-teremoq-c2-source-target-preexisting-20260828
```

Es un directorio local recuperable, no symlink ni mount del source, de
4.046.644.182 bytes, con `.rustc_info.json`, `debug` y `tmp`. No aparece en
status ni package.

La imagen accidental `busybox:latest` y el digest
`sha256:dc2d74b28e4cf8984fa52af1f39bc7c3d9c73760b41a74d629f5d11b1ab28616`
siguen ausentes. No hay imagen, contenedor, ruta, string o entrada package C2
coincidente. El incidente permanece cerrado y no se oculta.

### No finding bloqueante TP-OSS-SC en los quince paths congelados

Los quince hashes coinciden con el owner report actual. El delta no añade una
ruta fuera de `moq-relay-ietf`, manifest, lock, dependencia, feature, provider,
native, transport, wire, ALPN, draft-16, Objects, licencia o product pin.
REUSE, procedencia, secret scan redactado y package boundary pasan con las
limitaciones anteriores.

## Veredictos separados

**APPROVE FOR LOCAL COMMIT**

La aprobación se limita al gate supply-chain de este inventario exacto. Un
commit futuro debe contener únicamente estos quince paths con estos hashes,
conservar `MIT OR Apache-2.0` y llevar DCO 1.1 mediante `Signed-off-by`. El
snapshot sigue sin commit y con stage vacío; DCO todavía no es aplicable ni
demostrable. La aprobación tampoco reemplaza las rerevisiones nuevas de
plataforma/PKI ni la autorización del Master.

**PUBLICATION: NOT READY**

Este informe no autoriza commit por sí solo, integración, push, fetch, rama
remota, tag, PR, issue, release, publicación, despliegue o cambio de product
pin.

## Evidencia documental vinculante

Se leyó completamente `.cursorrules`, incluida la autonomía y la frontera
open-source, antes de inspeccionar el snapshot. No se usó el plan de
integración como veredicto C2.

| Evidencia | SHA-256 verificado |
|---|---|
| `.cursorrules` | `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2` |
| Owner report actual | `a15dd8989f3cffa234daf70bec33cc92e8d4e1243871ed41e0ca986d41d480bd` |
| Rereview TP-OSS-SC previa | `c1c5b3a5f9e2b8a81265d1df131753b6bda458e0a984fbe8c504bb7245ef8f4d` |
| Rereview TP-PLATFORM-CHAOS previa | `3796be533ad5090c4fcdc8419610148caaf16b0ff81fd2996c4acb56fec0f477` |
| Rereview TP-SEC-PKI previa | `cfbb03d91e406ca139696ed01c09307f6b94378258313915c4f14199ee61c47a` |

## Binding Git e inventario

| Propiedad | Valor reproducido |
|---|---|
| Rama | `teremoq/c2-session-shutdown-ee22a10` |
| `HEAD` / base C1 | `ee22a1079783e374371e0705775978790ddd6471` |
| Tree | `232e449945e877b024f2fc4223f0d2eea124b39b` |
| Tracking | ninguno |
| Stage | vacío, cero bytes de nombres staged |
| Inventario status | 15 paths |
| SHA-256 status porcelain v1/short | `41969b3ff7d7ebcaaf891137a17519a2097319642b6753db144a0b5a000db614` |
| Tracked diff | 4 paths; 2.438 inserciones y 100 borrados |
| Untracked | 11 paths |
| `git diff --check` / cached check | pass / pass |

No existe ninguna ruta adicional. Los tres ficheros que cambiaron desde la
rereview TP-OSS-SC anterior son:

| Path | SHA anterior | SHA actual |
|---|---|---|
| `moq-relay-ietf/src/relay.rs` | `67dad064d0b13d39bb6bd8ef9b81557ce291f48db76cda98ff476f1b270735e4` | `903be07defdbdcfd5a6ef02e192520bd793d6ef7cb8a238ee3b697262c7273be` |
| `moq-relay-ietf/src/remote.rs` | `f462286d1c8b9fc0b5eb3b478400c97ffc064d90270f899fea9bf80235114fdc` | `5a5a30536280fe946db0df969b1ae81099186838ec69904128a15e0ff15cf8a4` |
| `moq-relay-ietf/src/relay_c2_tests.rs` | `713ac2151be6233ff3bc6b7a1cf68242f85d8812198c511f2fa3c64df1a403a5` | `5ebccdf289a5b4183b28e78ee56dfad7f991a2c4c58eda27327c5e88f8033237` |

Los otros doce hashes permanecen iguales a la rereview previa.

## Quince hashes exactos

| Path | SHA-256 reproducido |
|---|---|
| `moq-relay-ietf/src/lib.rs` | `af994bc136fafa97b0a6faa15645811fc1f04b8d03851702f3fa48d38fbb0253` |
| `moq-relay-ietf/src/relay.rs` | `903be07defdbdcfd5a6ef02e192520bd793d6ef7cb8a238ee3b697262c7273be` |
| `moq-relay-ietf/src/remote.rs` | `5a5a30536280fe946db0df969b1ae81099186838ec69904128a15e0ff15cf8a4` |
| `moq-relay-ietf/src/upstream_namespaces.rs` | `7033823b66d5e3e82c0e6afdf2e4062080b908ed11c0aedb4550bd2f7cd775b9` |
| `moq-relay-ietf/src/relay_c2_tests.rs` | `5ebccdf289a5b4183b28e78ee56dfad7f991a2c4c58eda27327c5e88f8033237` |
| `moq-relay-ietf/src/session_admission.rs` | `cc5c56db172f7fb13e1f5a1a8bea3957c096d869dd97ac3f9d9f753820f0c7ef` |
| `moq-relay-ietf/tests/c2_session_admission.rs` | `1b528da9ccd852d81085bad190e01ae9a5a84ca6724574ed6a7cd2904e7e0a0a` |
| `moq-relay-ietf/tests/data/c2/README.md` | `285e4e178ecd6a7c5cffe5409107bc11bdf096bba9ebc014e805c0b991c1ae72` |
| `moq-relay-ietf/tests/data/c2/SHA256SUMS` | `ccc4d9cbcc23c31cfd12e2ef5d0a57e6d0901c243f7a732fc6eba20a7c82c8fd` |
| `moq-relay-ietf/tests/data/c2/ca.cert.pem` | `c439d7428d418762e090e1ce0fdda1524473daa66f052da251e120d78555dfbb` |
| `moq-relay-ietf/tests/data/c2/ca.cert.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-relay-ietf/tests/data/c2/server.cert.pem` | `76fe11a03423308533516c61c8e06f994746293313ef8961091de0e87cbd2b09` |
| `moq-relay-ietf/tests/data/c2/server.cert.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-relay-ietf/tests/data/c2/server.key.pem` | `607642c80b7ec6e365ef877e24c526ca546542fb5c330ae191891a212b67aa35` |
| `moq-relay-ietf/tests/data/c2/server.key.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |

## Frontera protegida de dependencias, protocolo y licencias

Los siguientes inputs son byte-idénticos a `HEAD`:

| Input | SHA-256 |
|---|---|
| Workspace `Cargo.toml` | `6665802c9ad7192d61521a62877454e25bde7072c611e617780a932f583aa48f` |
| `Cargo.lock` | `b518a2fa4a6d7a0ffe0bdfe4b530f05196ac0f5e6f7ef51da9e5a83c0b0561c0` |
| Relay manifest | `c88726b7739c35c4fcb42fd511bfe608e478b5d2489729081821fc84cd1b318d` |
| Native manifest | `3180121a89c58071718236a408f36c1c87757d6f9ff81e899fb3b5814c8d4c8e` |
| Transport manifest | `78f582c201082f7badece64f7fa65d215a6694412b7a7699332fa3bc9a4f3743` |
| Native QUIC | `b0c8dfb3e4963365a3a27f52a84d2fc54292cfc5a056a817a5a0d0a4f38b3723` |
| Setup/ALPN | `c49d71dcacd5e3f5eef7a673e11b9058d3fd701e1fb83331a737098894a2d750` |
| Setup version | `384772b32812a0761fa55d16a9fd29e30595323ece1b3fca013ec3720eaec4ad` |
| Transport session | `8e8992e1bb75d77c2475499014509a9362b965162d86156bdf6068a16b3cd2ea` |
| Object status | `514dbd41d9b8c078a20054664ee9ee087d471bf6853aa3ec59b556f6670bd27e` |
| Coding decode | `aa5e16f9d2370a18402005ef0cf3792f462bebb096917fe549441b2c46fc2a5a` |
| Coding encode | `1e5e58e7cca367d04f147dcad31c14aa27f2e3e261b613202cee24e7b5d659c2` |
| Coding location | `9478bb0efb1f1ed8838b594900a037f1f88a905937a2202eb634a1b92988b276` |
| Coding varint | `0073333bb43bd1681e74ab95a8f53af61303efad307966a89fcbc5d9fcc1f4eb` |
| `REUSE.toml` | `afc7fd86e591a56078b11982ee4d039ea1dfe3f9d56a90e3e7fa9f84fbddb6cc` |
| Apache-2.0 | `1248f876e0140942002b476a19c95d5b5b44c625e69c96611d23119ee87fa04e` |
| MIT | `c7d191b5901a741f2e39c74bd7a7594014a81fbe2bc7d533d4c29ad4cfe4e057` |

No existe diff en esos paths ni en ningún path fuera de `moq-relay-ietf`.
No hay cambio de dependency, feature, checksum de crate, provider, QUINN,
Rustls, native, transport, wire, ALPN, draft-16, Objects o product pin. La
búsqueda del delta no encuentra adición de `unsafe`, FFI, build tooling o
provider criptográfico.

`cargo metadata --locked --offline --no-deps` pasa: nueve packages, todos con
`MIT OR Apache-2.0`; `moq-relay-ietf 0.7.25` conserva 24 registros de
dependencia y sólo las features `default` y `metrics-prometheus`.

## Licencias y REUSE

Los ficheros upstream modificados conservan sus titulares y
`MIT OR Apache-2.0`. Los tres nuevos Rust/test usan copyright Teremoq y la
misma expresión dual. README e inventario usan la misma licencia. Los PEM no
se alteran con comentarios: cada uno tiene sidecar idéntico y válido, SHA-256
`5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0`.

REUSE 5.1.1, desde la imagen oficial local fijada
`fsfe/reuse@sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da`,
con red deshabilitada y source read-only, produce:

- 204/204 ficheros con copyright;
- 204/204 con licencia;
- cero bad, deprecated, missing, unused o read errors; y
- sólo MIT y Apache-2.0.

El resultado corresponde a REUSE Specification 3.3; no es una opinión legal.

## Error strings, probes y hooks

La inspección específica del nuevo snapshot demuestra:

- `RemoteCacheSlotInvariantError` es un tipo privado con texto fijo
  `remote cache slot invariant failed`; no concatena error upstream ni contexto
  de URL, peer, path, namespace, certificado o identidad;
- `RelayOutboundAdmissionClosedError` también es privado y fijo;
- `C2TestHooks`, `C2TestAcceptGate`, `C2TestStartupGate` y
  `C2TestRootProbeGuard` son structs privados bajo `#[cfg(test)]`;
- los campos de probe de `RemoteManager` llevan cada uno `#[cfg(test)]`;
- los seams auxiliares Remote son `pub(crate)` y `#[cfg(test)]`;
- `relay_c2_tests.rs` sólo entra mediante un módulo privado `#[cfg(test)]`; y
- los probes sólo contienen atomics, channels, notificaciones, contadores y
  guards sin strings ni payload de conexión.

Los snapshots públicos exponen únicamente versión de schema, límites,
contadores, gauges, deadline booleano y estado de shutdown. No contienen URL,
IP, CID, SNI, peer, path, namespace, certificado, principal o error remoto.
La superficie pública C2 registrada no añade callbacks ni un backend de
telemetría.

## Procedencia de fixtures

| C2 PEM | SHA-256 PEM | SHA-256 DER decodificado | Comparación C1 |
|---|---|---|---|
| `ca.cert.pem` | `c439d7428d418762e090e1ce0fdda1524473daa66f052da251e120d78555dfbb` | `ea33add88bed4676c51baa4f8da9df33d04e99cecf7d0846a756e23b0f66461b` | byte-idéntico |
| `server.cert.pem` | `76fe11a03423308533516c61c8e06f994746293313ef8961091de0e87cbd2b09` | `053a80b61f971f0601d83305ec6139fbcd7ed2f78c541078ac6e68a7e6da16bc` | byte-idéntico |
| `server.key.pem` | `607642c80b7ec6e365ef877e24c526ca546542fb5c330ae191891a212b67aa35` | `1d02d7ec66886fc2bb2cc3104851e1c182d7980e946d8df2e8f0f3ae33c30436` | PKCS#8 byte-idéntico |

La clave pública derivada del certificado y de la key coincide, SHA-256
`6c4c590db18e4f3f73fc7deb40ee6f0c2ca0b31a41a968bead99a7d8af82cb1c`.
No se imprimió material de clave.

Los subjects son genéricos de test (`moq-native-ietf-test-ca` y
`moq-native-ietf-server`), el SAN contiene sólo `localhost` y `127.0.0.1`, la
validez es 2026-08-26 a 2036-08-23 y los seriales no codifican identidad
Teremoq o de cliente. El README declara el material público, sintético,
loopback y no productivo.

## Secret scan y datos publicables

Gitleaks 8.30.1/MIT se ejecutó sin red ni suppressions desde la imagen local
fijada:

```text
zricethezav/gitleaks@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f
```

| Alcance | Bytes | Exit | Findings |
|---|---:|---:|---|
| siete Rust, README, inventario y sidecars | 281.097 | 0 | cero |
| directorio fixture C2 | 3.079 | 1 esperado | exactamente uno |

El finding esperado se registró sin valor sensible:

- fichero: `tests/data/c2/server.key.pem`;
- línea: 1;
- tipo: `private-key`;
- estado: fixture público sintético documentado;
- match y secret: `REDACTED` al 100 %.

La clasificación complementaria de todos los paths textuales no-PEM obtuvo
cero rutas locales de usuario, rutas Windows de usuario, emails, SPIFFE IDs,
URLs autenticadas, asignaciones de credenciales o literales productivos. Las
29 URLs observadas son 24 loopback/unspecified y cinco bajo el dominio
reservado `example.com`; las cinco IPv4 son loopback. El ejemplo documental
heredado `/path/to/coordination/file` es un ejemplo genérico, no una ruta
local o dato personal. No hay endpoint de cliente, namespace productivo,
principal, dato operativo, token, cookie, password o trust material real.

## Package boundary

Se ejecutó offline y sobre source read-only:

```text
/usr/local/cargo/bin/cargo package --list --allow-dirty --locked --offline \
  -p moq-relay-ietf
```

La imagen local fijada fue
`teremoq-step7-lab@sha256:ba076cf0a26aa41efdd2f0f80687ef97009d1526680751456c19cc944dff1d0b`,
con caches Cargo/Git preexistentes read-only, red deshabilitada y target/tmpfs
efímero. Resultado: exit 0, 34 entradas.

El package incluye los siete Rust/test C2 y los ocho artefactos de fixtures:
README, `SHA256SUMS`, tres PEM y tres sidecars. Contiene cero `target/`, cache,
`__pycache__`, bytecode, objeto, biblioteca, ejecutable, BusyBox o path que
escape del crate. Los tests referencian los PEM mediante
`CARGO_MANIFEST_DIR/tests/data/c2`; no usan `include_bytes!` fuera del package.

## Comandos, herramientas y limitaciones

| Herramienta | Versión/digest | Uso y licencia |
|---|---|---|
| Git | 2.53.0 | inventario/diff local; GPL-2.0-only |
| Python | 3.14.4 | clasificación redactada; PSF-2.0 |
| Docker | 28.3.3 | aislamiento offline local; Apache-2.0 |
| OpenSSL | 3.5.5 | X.509/DER, sin mostrar key; Apache-2.0 |
| REUSE | 5.1.1 / digest anterior | lint; GPL-3.0-or-later |
| Gitleaks | 8.30.1 / digest anterior | scan redactado; MIT |
| Cargo | 1.93.0 / imagen package anterior | metadata/package; MIT OR Apache-2.0 |

Comprobaciones ejecutadas independientemente:

- binding Git, stage, status SHA y los quince hashes: pass;
- diff scope y protected-path comparison a `HEAD`: pass;
- `git diff --check`, cached check y checks sin diagnósticos sobre cada nuevo
  fichero: pass;
- una primera envoltura de `git diff --no-index --check` confundió el exit 1
  normal de “hay diferencias frente a `/dev/null`” con un fallo; se descartó y
  se repitió usando los diagnósticos reales, con resultado pass;
- REUSE 5.1.1: pass 204/204;
- Gitleaks focal y fixture: cero inesperados, uno esperado y redactado;
- metadata locked/offline: pass;
- package list locked/offline: pass, 34 entradas;
- hashes PEM/DER/PKCS#8, sidecars y clave pública: pass;
- ausencia de cache/binario/BusyBox y cleanup recuperable: pass; y
- conflict markers: cero.

No se repitieron builds grandes, pruebas de concurrencia ni matriz de
plataforma. El owner report vinculado registra sus resultados, pero no se
presentan aquí como ejecución independiente TP-OSS-SC. Tampoco se ejecutó
RustSec: el lock byte-idéntico prueba no regresión de coordenadas, mientras los
advisories siguen siendo un gate global explícitamente abierto.

## Confirmación final de actividad

Al finalizar se volvieron a comprobar HEAD, tree, rama, stage, status SHA y los
quince hashes. El worktree C2 no fue editado y no se modificaron source,
manifests, lock, tests, refs, configuración Git, remotes o caches. Todos los
contenedores propios fueron efímeros, `--rm`, sin red y con source read-only.

No hubo checkout, branch, add, commit, clean, config, fetch, push, tag, PR,
issue, release, publicación, comunicación externa, descarga, instalación ni
mutación remota. Sólo se creó este informe en el repositorio Teremoq.

**LOCAL SUPPLY-CHAIN THIRD REREVIEW ONLY / NOT PUBLISHED / NO REMOTE MUTATION**
