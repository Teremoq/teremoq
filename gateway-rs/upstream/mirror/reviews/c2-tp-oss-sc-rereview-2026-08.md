<!--
SPDX-FileCopyrightText: 2026 Teremoq contributors
SPDX-License-Identifier: Apache-2.0
-->

# Rerevisión independiente TP-OSS-SC de C2

- Fecha: 2026-08-28
- Perfil: `TP-OSS-SC`
- Alcance: supply chain y frontera de publicación del snapshot C2 local
- Worktree revisado: `/home/jimbomilk/moq-rs-teremoq-c2-work`
- Modo: read-only, offline y sin autoridad de publicación

Esta es una revisión técnica; no constituye asesoramiento jurídico. No revisa
la corrección funcional Rust, la resistencia de plataforma ni la validez de
una arquitectura PKI productiva. Esas responsabilidades siguen en
`TP-RUST-DIST`, `TP-PLATFORM-CHAOS` y `TP-SEC-PKI`.

## Findings

### High — la publicación continúa bloqueada fuera del delta C2

El snapshot conserva byte a byte el `Cargo.lock` C1, SHA-256
`b518a2fa4a6d7a0ffe0bdfe4b530f05196ac0f5e6f7ef51da9e5a83c0b0561c0`.
Por tanto C2 no introduce un paquete o versión, pero tampoco integra los lotes
RustSec posteriores ni remedia el inventario baseline ya documentado de 19
entradas vulnerables y seis warnings. Esta rerevisión no volvió a ejecutar
`cargo audit`; la igualdad del lock demuestra ausencia de movimiento del
grafo, no ausencia de advisories.

También siguen pendientes la policy `deny.toml`, SBOM reconciliado, gates de
release, inventario/ref verifier, rulesets y la secuencia autorizada de
integración. No hay base para publicar, cambiar pins, crear una rama remota,
tag o release.

### Medium — las revisiones formales plataforma y PKI deben repetirse

Las revisiones previas leídas y congeladas concluyen `CHANGES REQUIRED` sobre
el snapshot anterior:

- `TP-PLATFORM-CHAOS`, SHA-256
  `f3d5bdf6eba57d67b8839e29072f36638c347ccbb4d67dc2762b4b3ad97b2f79`,
  identificó una reserva de cache no segura ante cancelación, watchdogs/races
  incompletos y fallos focales de formato/Clippy.
- `TP-SEC-PKI`, SHA-256
  `c188c80b64fbfd65652ba6ec0f042f2deaf42d65e7dfe06f5e060547f89393ab`,
  identificó admisión posterior a `Stopping` y gaps de prueba de cierre wire y
  orden terminal.

El nuevo owner report afirma correcciones y aporta nuevos hashes, que esta
rerevisión reproduce. `TP-OSS-SC` no convierte esa afirmación en cierre
funcional o de seguridad. Se requieren nuevas rerevisiones de ambos perfiles.
Esto no bloquea el dictamen local de supply chain, pero sí integración y
publicación.

### Medium — la clave privada sintética seguirá activando secret scanners

`moq-relay-ietf/tests/data/c2/server.key.pem` es una clave privada en sentido
criptográfico y Gitleaks la detecta correctamente. La igualdad binaria con el
fixture C1, los metadatos loopback, el README y su sidecar demuestran que es
material sintético público de test, no un secreto operativo.

El riesgo residual es su reutilización accidental fuera de tests o el fallo de
un gate automático que no aplique la excepción de fixture de forma focal. No
se autoriza una supresión global ni se rebaja la regla `private-key`.

### Low — `SHA256SUMS` requiere verificación consciente de procedencia

Las tres primeras entradas son PEM locales y pasan `sha256sum -c`. Las tres
entradas finales registran los hashes DER de procedencia C1, cuyos ficheros no
están duplicados en el directorio C2. Por ello ejecutar sin más
`sha256sum -c SHA256SUMS` informa tres ficheros DER ausentes.

No hay divergencia de contenido: los seis valores se verificaron y cada PEM
decodifica byte a byte al DER C1 correspondiente. El fichero y README explican
la distinción. Un futuro gate automatizado deberá comprobar por separado el
subconjunto PEM y los paths C1, o separar checksum local y provenance, en vez de
interpretar el inventario completo como autocontenido.

### Closed — cleanup local de `target/` y antiguo incidente BusyBox

El `target/` preexistente ya no está dentro del worktree. Se conserva, sin
borrado, en:

```text
/home/jimbomilk/.cache/moq-rs-teremoq-c2-source-target-preexisting-20260828
```

La ruta es un directorio local root-owned, legible, de 4.046.644.182 bytes,
en el mismo filesystem ext4 que el source. Contiene la estructura esperable de
un Cargo target (`debug`, `tmp` y `.rustc_info.json`); no es un symlink ni un
mount del worktree. El source no contiene `target`, `.cache` o `__pycache__`,
su status sigue limitado a 15 rutas y el package contiene cero entradas del
cache. El movimiento es local y recuperable; no contaminó source ni package.

La imagen accidental `busybox:latest` y el ID/digest
`sha256:dc2d74b28e4cf8984fa52af1f39bc7c3d9c73760b41a74d629f5d11b1ab28616`
siguen ausentes. No existen imagen o contenedor coincidentes y ninguna ruta,
string o entrada de package C2 contiene BusyBox. El incidente permanece
registrado y cerrado.

Durante esta rerevisión existía un contenedor ajeno activo,
`teremoq-c2-rereview-wr03-20260828`, basado en la imagen local de tooling C2.
No es BusyBox, no usa el cache movido como source y no fue inspeccionado más
allá de su inventario local ni detenido o modificado por `TP-OSS-SC`.

### No finding bloqueante TP-OSS-SC en el delta C2

Los quince hashes coinciden exactamente con el nuevo owner report. El delta no
añade rutas, manifests, lock, dependencias, features, provider criptográfico,
código native/transport/wire, ALPN/draft-16/Objects, licencia ni pin. REUSE,
procedencia, escaneo redactado y package list pasan con las limitaciones
anteriores.

## Veredictos separados

**APPROVE FOR LOCAL COMMIT**

La aprobación se limita a la frontera supply-chain de este inventario exacto.
Un commit futuro deberá contener únicamente estas quince rutas, preservar sus
hashes y llevar DCO 1.1 mediante `Signed-off-by`. El snapshot sigue sin commit,
por lo que DCO todavía no es aplicable ni demostrable; stage vacío no prueba un
sign-off futuro. Este dictamen no reemplaza las nuevas revisiones de plataforma
y PKI ni la autorización de integración del Master.

**PUBLICATION: NOT READY**

No se autoriza commit por este informe por sí solo, push, fetch, branch remota,
tag, PR, issue, release, publicación, despliegue ni cambio de product pin.

## Entradas documentales

| Evidencia | SHA-256 verificado |
|---|---|
| Revisión TP-OSS-SC previa | `208cf3e23da919358c329cc26d5f7b2add4fe306a7af778e1d4bcfbc4f35c15a` |
| Revisión TP-PLATFORM-CHAOS previa | `f3d5bdf6eba57d67b8839e29072f36638c347ccbb4d67dc2762b4b3ad97b2f79` |
| Revisión TP-SEC-PKI previa | `c188c80b64fbfd65652ba6ec0f042f2deaf42d65e7dfe06f5e060547f89393ab` |
| Nuevo owner report | `1fdc354f8dc8818e853b17dd59318d1d2c90fe85e371cfda37f80a04bd1da0e2` |

Se leyó completamente `.cursorrules`, incluida la autonomía y la frontera
open-source, antes de inspeccionar o crear el informe.

## Binding Git e inventario

| Propiedad | Valor reproducido |
|---|---|
| Rama | `teremoq/c2-session-shutdown-ee22a10` |
| `HEAD` / base C1 | `ee22a1079783e374371e0705775978790ddd6471` |
| Tree | `232e449945e877b024f2fc4223f0d2eea124b39b` |
| Tracking branch | ninguna |
| Stage | vacío |
| Status entries | 15 |
| SHA-256 de status short/porcelain v1 | `41969b3ff7d7ebcaaf891137a17519a2097319642b6753db144a0b5a000db614` |
| Tracked diff | 4 paths; 1.925 inserciones y 91 borrados |
| Untracked | 11 paths |
| `git diff --check` / cached check | pass / pass |

No se observó ninguna ruta fuera de `moq-relay-ietf`. El status está compuesto
por cuatro ficheros tracked modificados y once ficheros nuevos; nada está
staged.

## Quince hashes exactos

| Ruta | SHA-256 |
|---|---|
| `moq-relay-ietf/src/lib.rs` | `af994bc136fafa97b0a6faa15645811fc1f04b8d03851702f3fa48d38fbb0253` |
| `moq-relay-ietf/src/relay.rs` | `67dad064d0b13d39bb6bd8ef9b81557ce291f48db76cda98ff476f1b270735e4` |
| `moq-relay-ietf/src/relay_c2_tests.rs` | `713ac2151be6233ff3bc6b7a1cf68242f85d8812198c511f2fa3c64df1a403a5` |
| `moq-relay-ietf/src/remote.rs` | `f462286d1c8b9fc0b5eb3b478400c97ffc064d90270f899fea9bf80235114fdc` |
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

No hay divergencia respecto al inventario owner.

## Frontera de dependencias, protocolo y licencias

Inputs protegidos current/base byte-idénticos:

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
| Object status | `514dbd41d9b8c078a20054664ee9ee087d471bf6853aa3ec59b556f6670bd27e` |
| Coding decode | `aa5e16f9d2370a18402005ef0cf3792f462bebb096917fe549441b2c46fc2a5a` |
| Coding encode | `1e5e58e7cca367d04f147dcad31c14aa27f2e3e261b613202cee24e7b5d659c2` |
| Coding location | `9478bb0efb1f1ed8838b594900a037f1f88a905937a2202eb634a1b92988b276` |
| Coding varint | `0073333bb43bd1681e74ab95a8f53af61303efad307966a89fcbc5d9fcc1f4eb` |
| Transport session | `8e8992e1bb75d77c2475499014509a9362b965162d86156bdf6068a16b3cd2ea` |
| `REUSE.toml` | `afc7fd86e591a56078b11982ee4d039ea1dfe3f9d56a90e3e7fa9f84fbddb6cc` |
| Apache-2.0 | `1248f876e0140942002b476a19c95d5b5b44c625e69c96611d23119ee87fa04e` |
| MIT | `c7d191b5901a741f2e39c74bd7a7594014a81fbe2bc7d533d4c29ad4cfe4e057` |

No hay cambio en `moq-native-ietf`, `moq-transport`, draft-16, `moqt-16`,
ALPN, WebTransport, Objects, codec wire, QUINN, Rustls o provider. Tampoco hay
manifest, feature, source, checksum de crate o product pin adicional.

`cargo metadata --locked --offline --no-deps` pasa con nueve packages; todos
declaran `MIT OR Apache-2.0`. `moq-relay-ietf 0.7.25` conserva 24 registros de
dependencia y las features `default` y `metrics-prometheus`.

Los ficheros Teremoq nuevos usan `MIT OR Apache-2.0`; los ficheros upstream
modificados conservan copyright y la misma expresión dual. Los PEM usan
sidecars válidos, idénticos y sintácticamente separados del contenido PEM:

```text
SPDX-FileCopyrightText: 2026 Teremoq contributors
SPDX-License-Identifier: MIT OR Apache-2.0
```

REUSE 5.1.1, desde la imagen oficial local fijada
`fsfe/reuse@sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da`,
con red deshabilitada y source read-only, produce:

- 204/204 ficheros con copyright;
- 204/204 con licencia;
- cero bad, deprecated, missing, unused o read errors; y
- únicamente MIT y Apache-2.0.

El resultado corresponde a REUSE Specification 3.3; no es una conclusión
jurídica de distribución comercial.

## Procedencia de fixtures

| C2 PEM | SHA-256 PEM | SHA-256 DER decodificado | Resultado C1 |
|---|---|---|---|
| `ca.cert.pem` | `c439d7428d418762e090e1ce0fdda1524473daa66f052da251e120d78555dfbb` | `ea33add88bed4676c51baa4f8da9df33d04e99cecf7d0846a756e23b0f66461b` | byte-identical a `ca.cert.der` |
| `server.cert.pem` | `76fe11a03423308533516c61c8e06f994746293313ef8961091de0e87cbd2b09` | `053a80b61f971f0601d83305ec6139fbcd7ed2f78c541078ac6e68a7e6da16bc` | byte-identical a `server.cert.der` |
| `server.key.pem` | `607642c80b7ec6e365ef877e24c526ca546542fb5c330ae191891a212b67aa35` | `1d02d7ec66886fc2bb2cc3104851e1c182d7980e946d8df2e8f0f3ae33c30436` | PKCS#8 byte-identical a `server.key.der` |

OpenSSL 3.5.5 confirmó que la clave pública derivada de la key y la del
certificado comparten SHA-256
`6c4c590db18e4f3f73fc7deb40ee6f0c2ca0b31a41a968bead99a7d8af82cb1c`.
No se imprimió material de clave.

Metadatos seguros observados:

- CA subject/issuer: `CN=moq-native-ietf-test-ca`;
- servidor subject: `CN=moq-native-ietf-server`;
- SAN: `localhost` y `127.0.0.1`;
- validez: 2026-08-26 a 2036-08-23; y
- seriales genéricos, sin identidad Teremoq o de cliente.

El README declara que los PEM son encodings deterministas de fixtures C1
públicos, sólo para tests loopback, y que la clave nunca debe desplegarse.

## Secret scan y datos publicables

Gitleaks 8.30.1, licencia MIT, se ejecutó sin red ni suppressions desde:

```text
zricethezav/gitleaks@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f
```

Todas las mounts fueron read-only; el staging del scan vivió sólo en tmpfs.

| Alcance | Bytes aproximados | Exit | Findings |
|---|---:|---:|---|
| siete Rust, README, inventario y sidecars | 247.111 | 0 | cero |
| directorio fixture C2 | 3.079 | 1 esperado | exactamente uno |

El único finding es:

- rule: `private-key`;
- path: `/fixtures/server.key.pem`;
- líneas: 1-5;
- match y secret: `REDACTED` al 100 %.

La revisión complementaria, sin imprimir valores, obtuvo cero rutas locales,
SPIFFE IDs, emails, URLs autenticadas o marcadores de customer/tenant/production.
Las siete líneas con URL son dos loopback y cinco dominios reservados de test;
las cinco líneas IPv4 usan sólo loopback o unspecified. No hay endpoint público
o de cliente, namespace productivo, principal, dato operativo, log, payload,
token, cookie, password o trust material real.

## Package boundary

Comando corregido y finalmente ejecutado:

```text
/usr/local/cargo/bin/cargo package --list --allow-dirty --locked --offline \
  -p moq-relay-ietf
```

Se usó la imagen local fijada
`teremoq-step7-lab@sha256:ba076cf0a26aa41efdd2f0f80687ef97009d1526680751456c19cc944dff1d0b`,
source read-only, red deshabilitada, caches Cargo/Git preexistentes montadas
read-only y scratch/target en tmpfs. Resultado: exit 0, 34 rutas:

```text
CHANGELOG.md
Cargo.lock
Cargo.toml
Cargo.toml.orig
README.md
src/api.rs
src/bin/moq-relay-ietf/api_coordinator.rs
src/bin/moq-relay-ietf/file_coordinator.rs
src/bin/moq-relay-ietf/main.rs
src/consumer.rs
src/coordinator.rs
src/covering_prefix_set.rs
src/interest.rs
src/lib.rs
src/local.rs
src/metrics.rs
src/producer.rs
src/relay.rs
src/relay_c2_tests.rs
src/remote.rs
src/session.rs
src/session_admission.rs
src/tls.rs
src/upstream_namespaces.rs
src/web.rs
tests/c2_session_admission.rs
tests/data/c2/README.md
tests/data/c2/SHA256SUMS
tests/data/c2/ca.cert.pem
tests/data/c2/ca.cert.pem.license
tests/data/c2/server.cert.pem
tests/data/c2/server.cert.pem.license
tests/data/c2/server.key.pem
tests/data/c2/server.key.pem.license
```

Incluye exactamente los ocho artefactos del directorio fixture: README,
inventario, tres PEM y tres sidecars. Contiene cero `target/`, cache,
`__pycache__`, bytecode, objeto, biblioteca, ejecutable, BusyBox o ruta que
escape del crate.

## Herramientas, correcciones de invocación y límites

| Herramienta | Versión/digest | Uso/licencia |
|---|---|---|
| Git | 2.53.0 | inspección local; GPL-2.0-only |
| Python | 3.14.4 | clasificación redactada; PSF-2.0 |
| Docker | 28.3.3 | aislamiento offline local |
| OpenSSL | 3.5.5 | procedencia X.509/DER; Apache-2.0 |
| REUSE | 5.1.1 / digest anterior | lint; GPL-3.0-or-later |
| Gitleaks | 8.30.1 / digest anterior | scan redactado; MIT |
| Cargo/Rust | 1.93.0 / imagen anterior | metadata/package; MIT OR Apache-2.0 |

Se conservan estas incidencias de ejecución para no presentar una cadena más
limpia de lo ocurrido:

1. El primer `sha256sum -c` completo intentó abrir los tres DER de procedencia
   que no viven en C2. Se repitió separando PEM local y comparación C1; ambas
   comprobaciones correctas pasan.
2. Un primer wrapper Gitleaks de code terminó con error de quoting después de
   que Gitleaks ya informara cero findings. Se descartó esa evidencia y el scan
   limpio se repitió: exit 0 y cero findings.
3. El primer package probe usó un login shell que ocultó Cargo; el segundo ya
   encontró Cargo pero demostró que la imagen sola carecía del índice offline
   de `web-transport`. El gate válido se repitió con ruta absoluta y caches
   preexistentes read-only: exit 0 y 34 rutas. No hubo descarga ni red.

No se repitieron builds grandes, pruebas de concurrencia o matriz de
plataforma. El contenedor activo de rerevisión WR-03 pertenece a otro control y
no fue detenido ni reutilizado.

## Confirmación final de actividad

Al finalizar se volvieron a comprobar HEAD, tree, branch, stage, status SHA y
los quince hashes. El worktree C2 no fue editado y no se modificaron source,
manifest, lock, test, configuración Git, refs, remotes o caches. Todas las
imágenes usadas ya existían localmente; cada contenedor propio fue efímero,
`--rm` y `--network none`.

No hubo checkout, branch, add, commit, clean, config, fetch, push, tag, PR,
issue, release, publicación, comunicación externa, instalación ni mutación
remota. Sólo se creó este informe en el repositorio Teremoq.

**LOCAL SUPPLY-CHAIN REREVIEW ONLY / NOT PUBLISHED / NO REMOTE MUTATION**
