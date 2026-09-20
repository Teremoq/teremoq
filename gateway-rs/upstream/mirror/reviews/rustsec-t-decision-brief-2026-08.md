<!--
SPDX-FileCopyrightText: 2026 Teremoq contributors
SPDX-License-Identifier: Apache-2.0
-->

# Memo de decisión TP-OSS-SC para RustSec Batch T

- Fecha: 2026-08-28
- Perfil: `TP-OSS-SC`
- Base local: U1 `4547800088881cb4782c544ebfec0a1904ed1fab`
- Padre Q: `1e9d1ee62bde97145a0914e5992ab7f54fc909c4`
- Alcance: decisión previa; sin resolución de dependencias
- Autoridad de publicación o remoto: ninguna

Este memo es una revisión técnica de seguridad y supply chain. No es
asesoramiento jurídico, aprobación de implementación, excepción de advisory,
declaración FIPS ni autorización de publicación.

## Resumen ejecutivo

Batch T no es una actualización Rust ordinaria. Sustituye código criptográfico
nativo C/assembly empaquetado por `aws-lc-sys`, aunque Cargo considere
compatibles las versiones nuevas. Por eso necesita una decisión explícita del
usuario antes de resolver el lock.

La opción más conservadora es mantener la topología actual y hacer una
actualización mínima, no-FIPS y sin manifests:

1. `aws-lc-rs 1.13.3 -> 1.16.2`;
2. `aws-lc-sys 0.30.0 -> 0.39.0`;
3. `rustls-webpki 0.103.4 -> 0.103.13`;
4. aceptar únicamente los movimientos transitivos mínimos demostrados de
   `zeroize`, `cmake` y `dunce`; y
5. verificar la probable eliminación de `bindgen` y su subgrafo, sin convertir
   esa poda en permiso para actualizar herramientas ajenas.

Esta opción conserva `ring` como proveedor construido explícitamente por el
código TLS de `moq-native-ietf`. También conserva AWS-LC en el grafo unificado
de features de Rustls/QUINN; no intenta corregir en este lote la duplicidad de
proveedores. Cambiar a ring-only puede reducir superficie nativa, pero exige
modificar y probar una frontera de features compartida por Rustls, QUINN,
WebTransport, Hyper y Redis. No es un sustituto seguro de una actualización
acotada y debe ser otra decisión.

La recomendación está condicionada. Las archives objetivo no están en la caché
local: sólo están sus registros oficiales del índice sparse. Antes de aceptar
un futuro commit será obligatorio verificar archive/checksum, licencia,
notices, procedencia, código nativo y build scripts de las tres versiones
objetivo. Este memo no inventa ese gate.

## Hallazgos de decisión

### Alto — actualizar AWS-LC cambia código nativo de seguridad crítica

`aws-lc-sys 0.30.0` contiene y compila AWS-LC mediante CMake/CC, con fuentes C,
assembly y material de terceros dentro de la crate. Pasar a `0.39.0` cambia esa
implementación nativa. Una compilación satisfactoria no demuestra por sí sola
equivalencia criptográfica, portabilidad ni comportamiento de validación.

### Alto — eliminar AWS-LC ahora sería un cambio de proveedor, no un lock fix

El código de `moq-native-ietf` crea explícitamente
`rustls::crypto::ring::default_provider()` y limita sus configuraciones a
TLS 1.3. Sin embargo, los defaults de Rustls y QUINN también activan AWS-LC en
el grafo. Q ya documentó features de ambos proveedores.

Por tanto, AWS-LC está compilado y alcanzable como dependencia, pero no se ha
demostrado que sea el proveedor usado por cada configuración TLS del producto.
Quitar sus defaults requiere cambios coordinados de manifests/features y
pruebas de todos los consumidores. No debe mezclarse con T.

### Alto — T no cierra la línea Rustls 0.22

El lock contiene `rustls 0.22.4` con `rustls-webpki 0.102.4`, además de la línea
0.23. Batch T sólo remedia AWS-LC y webpki 0.103. La línea 0.102 no tiene una
versión corregida según la DB congelada y pertenece a Batch H.

Si el delta futuro intenta actualizar Reqwest/Hyper-Rustls/Tokio-Rustls,
eliminar Rustls 0.22 o mover HTTP/URL, debe detenerse: estaría absorbiendo H.

### Medio — el delta probable es mayor que tres coordenadas

Las constraints objetivo obligan a mover al menos tres utilidades ya presentes:

- `zeroize 1.7.0` no satisface `aws-lc-rs 1.16.2`, que exige `^1.8.1`;
- `cmake 0.1.50` no satisface `aws-lc-sys 0.39.0`, que exige `^0.1.54`; y
- `dunce 1.0.4` no satisface `aws-lc-sys 0.39.0`, que exige `^1.0.5`.

`cc 1.2.40` ya satisface `^1.2.26`, `fs_extra 1.3.0` satisface `^1.3.0` y
`untrusted 0.9.0` satisface la línea existente. No necesitan moverse.

### Medio — la poda de Bindgen es probable, pero no está resuelta

La crate actual `aws-lc-sys 0.30.0` retiene `bindgen 0.69.5`. En el registro
objetivo, `aws-lc-sys 0.39.0` hace Bindgen opcional, y `aws-lc-rs 1.16.2`
depende de sys con defaults deshabilitados. Las features actuales activan sys y
`prebuilt-nasm`, no `bindgen`.

La expectativa conservadora es que `bindgen` y dependencias exclusivamente
suyas salgan del lock. Entre los candidatos están `cexpr`, `clang-sys`, `glob`,
`lazycell`, `prettyplease`, `which`, `home`, `rustc-hash 1.1`, `nom`,
`minimal-lexical` y quizá otras hojas. Algunas dependencias compartidas como
`regex`, `proc-macro2`, `quote`, `syn`, `shlex`, `bitflags`, `libc` y
`lazy_static` deben permanecer por otros consumidores.

Esto es una predicción del grafo, no un delta verificado. Si aparece
`bindgen 0.72.x` en lugar de desaparecer, significa que se activó una feature
de generación de bindings y el lote debe detenerse para revisar libclang,
portabilidad y tooling.

## Binding del snapshot

La inspección Git read-only confirmó:

| Propiedad | Valor |
|---|---|
| Rama local | `teremoq/rustsec-u1-1e9d1ee` |
| `HEAD` | `4547800088881cb4782c544ebfec0a1904ed1fab` |
| `HEAD^{tree}` | `cc9b037c81ace8a9490693a6ccb1c294cd0e3886` |
| Padre | `1e9d1ee62bde97145a0914e5992ab7f54fc909c4` |
| Tree del padre Q | `4cf25aeea2eacd02394608c80c9677eaa001ef87` |
| Estado | limpio; stage vacío; sin tracking branch |
| Paths del commit U1 | sólo `Cargo.lock`, 2 inserciones/2 borrados |
| DCO U1 | un trailer `Signed-off-by` |
| `Cargo.lock` SHA-256 | `0b8ebcce6495ea65cc0acb0a94852e0067f78b06aa956dc8a368195bce626e19` |

El memo usa los documentos siguientes como inputs, no como sustitutos de la
inspección del lock y los registros locales:

| Documento | SHA-256 |
|---|---|
| `.cursorrules` | `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2` |
| ADR-0007 | `0085bdaa37cd3645a4a2c5a3163b0b096453b84f66635514fce6015d6bed25d8` |
| Plan RustSec | `a36cf64bb336cd99fe8f0e2984e64a8eb20ec3a49da91fce6f3c146d4d7a4bf2` |
| Revisión local Q | `24ae0d3d537df1b4aa70a13c0afcdee22af9162d64dba877c7b96a362e9c1033` |
| Revisión TP-OSS-SC Q | `bc3f3d9f020b1da7116510843e1de330331140e0affde164ac6b69cf6ecc702c` |
| Revisión local U1 | `358a31f643e93f9efb9eca29624c9ee6a4931e56264d29ee519824cd1ff2c8fb` |
| Revisión TP-OSS-SC U1 | `48c053d703d4f07b4ce1bf52f5e4bcd2745812d613433d43bd1bc5d80b681ede` |

## Grafo actual verificado

El lock U1 contiene 336 paquetes y estas coordenadas relevantes:

```text
consumidores Rustls/QUINN/WebTransport/HTTP/Redis
├── rustls 0.23.31
│   ├── aws-lc-rs 1.13.3
│   │   └── aws-lc-sys 0.30.0
│   ├── rustls-webpki 0.103.4
│   │   └── aws-lc-rs 1.13.3
│   └── ring 0.17.14
├── quinn-proto 0.11.15
│   ├── aws-lc-rs 1.13.3
│   ├── rustls 0.23.31
│   └── ring 0.17.14
└── línea HTTP heredada
    └── rustls 0.22.4 -> rustls-webpki 0.102.4 -> ring 0.17.14
```

Introducen o usan Rustls 0.23.31 `quinn`, `quinn-proto`,
`web-transport-quinn`, `hyper-serve`, `hyper-rustls 0.27`,
`tokio-rustls 0.26`, Redis, `rustls-platform-verifier` y
`moq-native-ietf`.

Las constraints oficiales cacheadas son compatibles con el objetivo mínimo:

| Origen | Constraint actual | Objetivo compatible |
|---|---|---|
| `rustls 0.23.31` -> `aws-lc-rs` | `^1.12`, optional, sin defaults | `1.16.2` |
| `rustls 0.23.31` -> `rustls-webpki` | `^0.103.4` | `0.103.13` |
| `rustls-webpki 0.103.13` -> `aws-lc-rs` | `^1.14`, optional, sin defaults | `1.16.2` |
| `aws-lc-rs 1.16.2` -> `aws-lc-sys` | `^0.39.0`, optional, sin defaults | `0.39.0` |

No constraint obliga a mover `rustls 0.23.31`, `quinn 0.11.9`,
`quinn-proto 0.11.15`, `web-transport-quinn 0.11.8`, `ring 0.17.14` ni los
manifests. Si cualquiera se mueve, el resolver ha ampliado el alcance.

## Features y proveedor efectivo

`moq-native-ietf/Cargo.toml:20-25` declara:

- `web-transport-quinn` sin defaults y con `ring`;
- Rustls 0.23 con `ring`, pero con defaults todavía habilitados; y
- QUINN 0.11.9 con `ring` y `qlog`, también con defaults habilitados.

Rustls 0.23.31 define por defecto `aws_lc_rs`, logging, std, TLS 1.2 y
`prefer-post-quantum`; además el workspace activa `ring`. El grafo contiene
ambos proveedores.

El comportamiento observable del helper IETF es más estrecho:

- `moq-native-ietf/src/tls.rs:56` crea explícitamente el proveedor ring;
- líneas 94-95 y 110-111 limitan cliente y servidor a TLS 1.3; y
- línea 154 carga claves mediante la implementación de firma ring.

Por ello no se debe afirmar que AWS-LC sea el proveedor activo de esas
configuraciones concretas. Tampoco se puede concluir que sea irrelevante: otros
consumidores dependen de los defaults unificados, la crate se compila y enlaza,
y futuras rutas pueden usarla.

## Advisories congelados de Batch T

La fuente primaria reproducible sigue siendo la DB oficial RustSec en commit
`6420e39260b3d771b049954cf5d52b57e2118da4`. El JSON retenido confirma:

| Advisory | Condición resumida | Mínimo corregido RustSec | Decisión consolidada |
|---|---|---:|---:|
| `RUSTSEC-2026-0045` | canal temporal en verificación AES-CCM EVP | `aws-lc-sys >=0.38.0` | `>=0.39.0` |
| `RUSTSEC-2026-0046` | bypass de cadena en `PKCS7_verify` | `aws-lc-sys >=0.38.0` | `>=0.39.0` |
| `RUSTSEC-2026-0047` | bypass de firma en `PKCS7_verify` | `aws-lc-sys >=0.38.0` | `>=0.39.0` |
| `RUSTSEC-2026-0048` | error de scope de CRL/IDP | `aws-lc-sys >=0.39.0` | `>=0.39.0` |

El índice local confirma que `aws-lc-rs 1.16.2` es la primera release
cacheada no-yanked que requiere `aws-lc-sys ^0.39.0`. `1.16.1` requiere
`^0.38.0` y no cierra 0048.

El plan incluye también `rustls-webpki 0.103.13` para cerrar en la línea 0.103
`RUSTSEC-2026-0049`, `RUSTSEC-2026-0098`, `RUSTSEC-2026-0099` y
`RUSTSEC-2026-0104`. La línea 0.102 seguirá afectada hasta H.

Partiendo de las 16 entradas vulnerables de U1, el resultado matemático
esperado contra la DB congelada sería eliminar ocho: cuatro de AWS-LC y cuatro
de webpki 0.103. Quedarían ocho entradas vulnerables y seis warnings. Esto no
es un resultado de auditoría: no se ha resuelto ni escaneado un lock T.

## Procedencia, checksums, MSRV y licencias

Los registros sparse oficiales cacheados y no-yanked proporcionan:

| Paquete objetivo | Checksum del índice | MSRV del índice |
|---|---|---:|
| `aws-lc-rs 1.16.2` | `a054912289d18629dc78375ba2c3726a3afe3ff71b4edba9dedfca0e3446d1fc` | 1.71 |
| `aws-lc-sys 0.39.0` | `1fa7e52a4c5c547c741610a2c6f123f3881e409b714cd27e6798ef020c514f0a` | 1.71 |
| `rustls-webpki 0.103.13` | `61c429a8649f110dddef65e2a5ad240f747e85f7758a6bccc7e5777bd33f756e` | 1.71 |

Rust 1.71 es compatible con el toolchain aprobado 1.93. Esto sólo demuestra
la declaración del índice, no que todos los targets soportados compilen.

Las archives actuales sí están cacheadas y verifican estas expresiones:

- `aws-lc-rs 1.13.3`: `ISC AND (Apache-2.0 OR ISC)`;
- `aws-lc-sys 0.30.0`: `ISC AND (Apache-2.0 OR ISC) AND OpenSSL`; y
- `rustls-webpki 0.103.4`: `ISC`.

Son materiales de terceros y conservan sus licencias. La revisión técnica no
los relicencia bajo `MIT OR Apache-2.0`.

Las archives objetivo no están en la caché oficial local. El índice sparse no
incluye la expresión SPDX completa, notices, VCS commit ni contenido del
archive. Por tanto quedan **no verificados localmente** para 1.16.2, 0.39.0 y
0.103.13:

- coincidencia archive/checksum;
- licencia y textos completos;
- copyright/notices y terceros embebidos;
- commit/path VCS empaquetado;
- build script exacto y fuentes C/assembly; y
- inventario real que debe entrar en SBOM.

No se debe aceptar un commit T hasta poblar una caché autorizada, obtener las
archives oficiales y verificar cada punto sin red durante la revisión final.

## Código nativo y build tooling esperado

El target `aws-lc-sys 0.39.0` declara en el índice:

- `cc ^1.2.26` con compilación paralela;
- `cmake ^0.1.54`;
- `dunce ^1.0.5`;
- `fs_extra ^1.3.0`; y
- `bindgen ^0.72.0` opcional.

El wrapper `aws-lc-rs 1.16.2` deshabilita defaults en su edge a sys y requiere
`zeroize ^1.8.1`. Sus features conservan rutas separadas `fips`, `non-fips`,
`bindgen`, `prebuilt-nasm`, `ring-io` y `ring-sig-verify`.

Una implementación futura debe usar el toolchain/container aprobado, sin
instalación global ni descargas durante build. Debe registrar compilador C,
CMake, ensamblador si aplica, targets, flags y si usó bindings pre-generados o
Bindgen. Un build que necesite instalar libclang, NASM u otra herramienta no
inventariada sale del alcance y se detiene.

## FIPS y no-FIPS

El lock U1 no contiene `aws-lc-fips-sys`; las features inspeccionadas no
seleccionan `fips`. La recomendación conserva esa situación.

Actualizar `aws-lc-sys` no convierte el producto en FIPS, no acredita una
configuración y no demuestra que una frontera criptográfica esté validada. El
memo no evalúa certificaciones ni formula claims de cumplimiento.

Habilitar `fips`, introducir `aws-lc-fips-sys` o cambiar las condiciones de
build sería una nueva dependencia/proveedor y requiere una decisión separada,
evidencia del módulo exacto, plataforma, configuración y alcance de cualquier
claim.

## Impacto esperado en QUIC, Rustls y mTLS

### QUIC y WebTransport

No se espera cambio de API, draft, ALPN o wire porque no hay motivo de
constraint para mover QUINN, WebTransport ni Rustls. Sin embargo, el binario
puede recompilar código nativo diferente y la feature unification sigue
incluyendo AWS-LC. Son obligatorias pruebas de handshake, retransmisión,
conexión/rechazo, WebTransport y MoQT draft-16.

### Rustls y validación X.509

Webpki 0.103.13 corrige validación de CRL y name constraints. Es posible que
una cadena antes aceptada sea rechazada correctamente. Esto debe tratarse como
cambio de seguridad esperado, no relajarse mediante fallback o verifier
permisivo.

### mTLS e identidad

El helper U1 inspeccionado crea configuraciones TLS 1.3 con ring y la ruta base
mostrada usa `with_no_client_auth`; no demuestra por sí misma mTLS productivo.
Las pruebas I1/I2 y la política privada de identidad pertenecen a otras ramas y
owners. Después de integrar secuencialmente T habrá que repetir casos mTLS
positivos y negativos con fixtures públicos/sintéticos aprobados: CA correcta,
CA ajena, certificado expirado, SAN/name constraints, cadena incompleta,
revocación/CRL cuando esté soportada y ausencia de identidad.

T no puede copiar I1/I2 ni cambiar trust material para fabricar esa evidencia.

## Alternativas

| Alternativa | Beneficio | Consecuencia real | Decisión |
|---|---|---|---|
| A. Actualización mínima del mismo grafo no-FIPS | Cierra ocho entradas congeladas sin manifests ni API | Cambia código C/assembly; mantiene duplicidad ring/AWS-LC | **Recomendada**, con autorización explícita y gates |
| B. Estandarizar ring-only | Puede eliminar AWS-LC y su toolchain nativo | Cambia features/proveedor en Rustls, QUINN y consumidores; necesita manifests y pruebas arquitectónicas | Separar de T; no autorizada |
| C. Estandarizar AWS-LC | Elimina duplicidad si todas las rutas migran | Cambia el proveedor explícito ring, firma de claves y pruebas IETF | Separar de T; no autorizada |
| D. Activar FIPS | Puede responder a una necesidad futura concreta | Introduce `aws-lc-fips-sys`, build/configuración y obligaciones de evidencia distintas | No usar como remedio; decisión separada |
| E. Actualizar Rustls/QUINN/WebTransport ampliamente | Puede incorporar otros fixes | Amplía API, wire/behavior y lock sin necesidad de constraints | Rechazada para el primer intento |
| F. Diferir o ignorar advisories | Cero delta inmediato | Mantiene cuatro fallos crypto de sys y cuatro de webpki 0.103 | No aceptable como estado de publicación |

## Decisión exacta que debe tomar el usuario

Antes de que `TP-RUST-DIST` implemente, el usuario debe autorizar o rechazar
esta proposición concreta:

> **Autorizar Batch T como actualización in-place del proveedor AWS-LC
> no-FIPS ya presente, fijando `aws-lc-rs 1.16.2`, `aws-lc-sys 0.39.0` y
> `rustls-webpki 0.103.13`, preservando los manifests, la selección explícita
> ring de `moq-native-ietf` y la topología actual de features. El permiso sólo
> cubre los movimientos transitivos mínimos necesarios de `zeroize`, `cmake`
> y `dunce`, más la poda demostrable del subgrafo Bindgen. No autoriza ring-only,
> AWS-LC-only, FIPS, otro proveedor, ni cambios Rustls/QUINN/WebTransport.**

Recomendación TP-OSS-SC: **autorizar esa proposición exacta**. Después, resolver
en un worktree aislado y devolver el delta para revisión independiente antes de
commit local.

## Allow-set esperado para la futura resolución

La resolución todavía no existe. El siguiente inventario es una frontera de
revisión, no permiso para editar este snapshot:

| Paquete | Expectativa conservadora |
|---|---|
| `aws-lc-rs` | exactamente `1.16.2` |
| `aws-lc-sys` | exactamente `0.39.0` |
| `rustls-webpki 0.103` | exactamente `0.103.13` |
| `zeroize` | mínimo compatible `1.8.1`; revisar la versión exacta resuelta |
| `cmake` | mínimo compatible `0.1.54`; revisar la versión exacta resuelta |
| `dunce` | mínimo compatible `1.0.5`; revisar la versión exacta resuelta |
| `bindgen 0.69.5` y hojas exclusivas | probable eliminación; no actualización implícita |
| `cc 1.2.40`, `fs_extra 1.3.0`, `untrusted 0.9.0` | sin movimiento esperado |

La implementación debe comparar registros completos del lock, no sólo nombres
y versiones. Toda alta, baja o cambio fuera del allow-set exige explicación y
nueva revisión antes de continuar.

## Condiciones obligatorias de parada

Detener la implementación sin commit si ocurre cualquiera de estas condiciones:

1. falta una archive objetivo o no coincide con el checksum del índice;
2. cambia una licencia, falta un notice o aparece material tercero no
   inventariado;
3. el resolver toca un `Cargo.toml`, source, fixture, license o cualquier path
   distinto de `Cargo.lock`;
4. se mueve Rustls, Ring, QUINN, quinn-proto, WebTransport, Hyper, Redis,
   Reqwest o la línea Rustls 0.22;
5. aparecen `aws-lc-fips-sys`, feature `fips`, un tercer proveedor o cambia la
   selección explícita ring;
6. Bindgen 0.72/libclang queda seleccionado sin una justificación y decisión
   específica;
7. se necesita instalar tooling global, hacer fetch durante build o usar un
   artefacto no fijado;
8. cambia TLS 1.3, ALPN `moqt-16`, draft-16, wire, trust policy, identidad o
   comportamiento de mTLS;
9. un test que pasaba en U1 falla, o el nuevo fallo no puede separarse de los
   baseline failures documentados;
10. el audit congelado no elimina exactamente las ocho entradas esperadas,
    añade un finding o modifica warnings sin explicación;
11. una DB actual autorizada publica un mínimo mayor o un nuevo advisory para
    las versiones objetivo; o
12. el build/SBOM demuestra una pareja wrapper/sys mezclada o código nativo no
    reproducible en los targets aprobados.

## Gates de implementación y revisión

### Identidad y delta

- partir del commit U1 exacto y lock SHA-256 de este memo;
- conservar stage limpio antes de resolver;
- registrar comando/toolchain y diff de registros completos;
- demostrar que sólo cambia `Cargo.lock` y que el allow-set explica todo; y
- exigir DCO en el futuro commit local.

### Supply chain y licencias

- obtener las tres archives oficiales en una caché temporal/autorizada;
- cotejar archive, sparse index y lock por SHA-256;
- inspeccionar `Cargo.toml`, `.cargo_vcs_info.json`, license, notices, código
  embebido, build scripts y terceros;
- ejecutar cargo-deny bajo una policy revisada o declarar el gate incompleto;
- ejecutar REUSE sobre source y comparar SBOM normal/build/all-features; y
- registrar la eliminación o incorporación exacta de tooling nativo.

### Features y build

- `cargo metadata --locked` y árboles inversos de Rustls, aws-lc-rs,
  aws-lc-sys, webpki, Ring y QUINN;
- diff de features antes/después, demostrando ring + AWS-LC igual que U1 y
  FIPS ausente;
- build nativo en la imagen Rust 1.93 fijada, sin red y con toolchain C/CMake
  inventariado;
- builds normal, build, dev y all-features; y
- package/list y extracción del crate candidato cuando corresponda.

### Seguridad funcional

- tests upstream focales de las crates objetivo;
- TLS 1.3 cliente/servidor con proveedor ring explícito;
- cadenas válidas e inválidas, SAN/name constraints y CRL cuando haya fixtures
  públicos y soporte real;
- tests QUINN/WebTransport/MoQT, ALPN/draft-16 e interoperabilidad;
- mTLS positivo/negativo después de integrar secuencialmente la rama que lo
  implemente, sin incorporar ese código en T; y
- comprobación de que no aparece fallback permisivo ni cambio de trust.

### Advisories y regresiones

- cargo-audit sin fetch contra la DB congelada exacta y, en una fase autorizada,
  contra una DB actual fijada;
- cero suppressions/ignores nuevos;
- mantener visibles las ocho vulnerabilidades y seis warnings esperados fuera
  de T;
- `cargo check/test/clippy` completos, distinguiendo los baseline failures ya
  registrados; y
- `git diff --check`, validación TOML y escaneo redactado de secretos del delta.

## Rollback

El rollback mecánico es restaurar exactamente U1:

- commit base `4547800088881cb4782c544ebfec0a1904ed1fab`;
- lock SHA-256
  `0b8ebcce6495ea65cc0acb0a94852e0067f78b06aa956dc8a368195bce626e19`.

Wrapper, sys crate y webpki deben revertirse juntos. Nunca se conserva una
pareja `aws-lc-rs`/`aws-lc-sys` mezclada ni tooling huérfano. El rollback reabre
los ocho findings congelados y sólo es una recuperación temporal, no un estado
aceptable para publicación.

## Límites de evidencia

Este memo no ejecutó Cargo resolver, build, tests, cargo-audit ni cargo-deny.
No existe un lock T que validar. La caché permitió leer registros oficiales del
índice y las archives actuales, pero no las archives objetivo. Tampoco se
consultó una DB RustSec posterior al commit congelado.

Quedan no verificados hasta una implementación autorizada:

- delta exacto de Cargo y poda real de Bindgen;
- archivos, licencias, notices y VCS de las versiones objetivo;
- resultado en Linux/WSL2 y demás targets aprobados;
- comportamiento funcional/interop/mTLS;
- SBOM y tamaño/código nativo final; y
- findings aparecidos después de la DB congelada.

No se presenta ninguna de esas ausencias como check aprobado.

## Actividad y estado final

La inspección usó Git, Python/TOML, SHA-256 y lectura streaming de archives e
índice desde contenedores ya detenidos. No arrancó contenedores, no instaló
herramientas, no usó web o red y no resolvió dependencias.

El worktree U1 permaneció limpio en el commit, tree y lock vinculados. No hubo
checkout, branch, stage, commit, push, tag, release, PR, issue, publicación,
mensaje, modificación de configuración Git ni mutación remota. Sólo se creó
este memo en el repositorio Teremoq.

**DECISION BRIEF ONLY / NO LOCK RESOLUTION / NO REMOTE MUTATION**
