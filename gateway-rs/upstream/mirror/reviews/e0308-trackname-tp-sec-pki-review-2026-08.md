<!-- SPDX-License-Identifier: Apache-2.0 -->

# Revisión independiente TP-SEC-PKI — paquete E0308 `TrackName`

Fecha de revisión: 2026-08-28  
Rol: `TP-SEC-PKI`  
Objeto: snapshot staged, local y no comprometido de `/home/jimbomilk/moq-rs-teremoq-e0308-work`  
Modo: read-only; sin red, instalación, commit, push, fetch, publicación ni mutación remota

## Hallazgos

### Bloqueantes

Ninguno atribuible al paquete E0308 revisado.

### Riesgo heredado — inventario RustSec continúa rojo

El `Cargo.lock` del snapshot es byte-idéntico al de la base Q+U1 y la auditoría offline devuelve 16 vulnerabilidades y 6 warnings. El delta no modifica el lock, manifests, configuración de auditoría ni listas de exclusión; por tanto, no introduce ni oculta estos resultados. Permanecen:

- `RUSTSEC-2024-0421` en `idna 0.5.0`.
- `RUSTSEC-2025-0055` en `tracing-subscriber 0.3.18`.
- `RUSTSEC-2026-0045`, `RUSTSEC-2026-0046`, `RUSTSEC-2026-0047` y `RUSTSEC-2026-0048` en `aws-lc-sys 0.30.0`.
- `RUSTSEC-2026-0049`, `RUSTSEC-2026-0098`, `RUSTSEC-2026-0099` y `RUSTSEC-2026-0104`, cada uno sobre `rustls-webpki 0.102.4` y `rustls-webpki 0.103.4` — ocho entradas.
- `RUSTSEC-2026-0204` en `crossbeam-epoch 0.9.18`.
- `RUSTSEC-2026-0258` en `h2 0.4.5`.
- Warnings: `RUSTSEC-2024-0436` (`paste 1.0.15`, unmaintained), `RUSTSEC-2025-0056` (`adler 1.0.2`, unmaintained), `RUSTSEC-2025-0134` (`rustls-pemfile 2.1.2`, unmaintained), `RUSTSEC-2026-0097` (`rand 0.8.5` y `0.9.2`, unsound) y `RUSTSEC-2026-0190` (`anyhow 1.0.85`, unsound).

Este inventario es riesgo heredado, no un defecto corregido ni aprobado por este paquete. El batch criptográfico T sigue siendo una decisión independiente y **no queda autorizado** por este dictamen. La cadena de dependencias no debe presentarse como completamente saneada.

### Informativo — delta estrictamente test-only y sin fuga nueva

- En `moq-transport/src/serve/tracks.rs:499`, dentro del módulo abierto por `#[cfg(test)]` en la línea 283, el valor esperado pasa de `&str` a `TrackName::from(track_name)`. Esto resuelve el `E0308` del assert y no modifica ninguna ruta productiva.
- `TrackName::from(&str)` ya existente en `moq-transport/src/coding/track_namespace.rs:164-167` copia literalmente `value.as_bytes()` a un `Vec<u8>`. No normaliza, canonicaliza, interpreta ni valida identidad, namespace o autorización. La codificación y decodificación wire permanecen sin cambios en las líneas 182-205.
- Los cambios de `moq-transport/src/serve/tracks.rs:307-308` y `moq-transport/src/serve/subgroup.rs:937-938` son sólo el layout producido por rustfmt, también bajo `#[cfg(test)]` (`tracks.rs:283` y `subgroup.rs:636`).
- El diff no añade tracing, logging, métricas, errores, payloads ni representación `Debug`/`Display`; no hay una superficie nueva capaz de revelar certificados, identidad, path, namespace, track o datos del peer.

## Identidad congelada y preflight

Todos los bindings se reprodujeron al inicio y antes de redactar este informe:

| Propiedad | Valor observado |
|---|---|
| `.cursorrules` SHA-256 | `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2` |
| HEAD/base | `afeaa94cb41491a07ce55010ff00a88d5e8716a9` |
| tree de HEAD | `4696ae59a07ec1b3930a654e03e412221f9a8a5d` |
| staged tree | `cccd0d60c9ebfe191dca9d73e7ab8b27ae4d4ea5` |
| cantidad de paths staged | `2` |
| pathset SHA-256 | `37546925cd09e15789c286e450c705bdf0db51781cb2a28f3ce9f2731b797799` |
| status-z SHA-256 | `3e66c5d217fdb0ec2f11fa3816a276857afbef697a587d9e980a936189ad1000` |
| `Cargo.lock` SHA-256 | `d6196fd8f31ea3b2cabbdb0e57546810643f344567f3e358ee3c000b3e2b59f5` |
| unmerged / unstaged | `0` / `0` |
| tracking branch | ninguno |
| owner report SHA-256 | `f47f559a169d1a10ca30a00c1f26c56f676f66beabbe234c5d4b029f0d9e9ffd` |

Los dos únicos paths staged son:

- `moq-transport/src/serve/subgroup.rs`
- `moq-transport/src/serve/tracks.rs`

El diff binario staged tiene SHA-256 `2e1090c4b991b25abcaad81cca670075ad471c2a5ce54dd0bb08f07285debb22` y `git diff --cached --check` finaliza sin errores.

Hashes de contenido revisados:

| Archivo | Base | Staged |
|---|---|---|
| `moq-transport/src/serve/subgroup.rs` | `f5c21e89c18dd21f8900d491920ad3b378653df3d4d5bfe0f176d928cf972382` | `30d401d94aba88cf89e828ee348db2ac1bbc521bdc8ec5c3f282ee12e4b200d7` |
| `moq-transport/src/serve/tracks.rs` | `a8303c94925707a0a257923725bf84e4ec730b07d6bb2330fda5329b632fe0b7` | `412a2fc82c143eb6c1f0040b44f66794d4cd9fed8c3e63db5d6a2e8635ef0bec` |

## Auditoría del límite de seguridad

La inspección completa con `git diff --cached`, `--function-context` y blobs del índice demuestra que los tres hunks quedan dentro de módulos compilados sólo para test. Ningún source productivo, manifest, lockfile, configuración, fixture o protocolo está en el delta.

En particular:

- No cambia la normalización o canonicalización de `TrackName`, path o namespace.
- No cambia autenticación, autorización, identidad, mTLS ni `PeerEvidence`; tampoco la ligadura de evidencia a la conexión.
- No cambia la codificación wire, drafts, ALPN, QUIC ni WebTransport.
- No cambia la redacción ni se incorpora logging de datos sensibles.
- No cambia `rustls`, el proveedor `aws-lc`, `webpki`, `ring`, `quinn` ni `bytes`.
- No se añade dependencia, feature, `unsafe`, parser, política Teremoq ni código criptográfico.

El índice frente a HEAD devuelve cero paths fuera de los dos permitidos y cero diferencias en `Cargo.toml`, `Cargo.lock` o manifests de workspace. Como comprobación de la resolución efectiva del lock permanecen, entre otros, `aws-lc-rs 1.13.3`, `aws-lc-sys 0.30.0`, `rustls 0.22.4/0.23.31`, `rustls-webpki 0.102.4/0.103.4`, `rustls-pki-types 1.12.0`, `ring 0.17.14`, `quinn 0.11.9`, `quinn-proto 0.11.15`, `bytes 1.11.1` y `web-transport-quinn 0.11.8`.

## Validaciones ejecutadas

Las validaciones Rust se ejecutaron offline en contenedor local, con el source montado read-only, `--network none`, un target temporal externo al worktree y la imagen `teremoq-local-rust193-components@sha256:f522c28d5beb21591f46e8c165030f70b32dd5b51107577ad196910e7147a007`. Dentro del contenedor: `rustc 1.93.0`, `cargo 1.93.0`, rustfmt `1.8.0` y clippy `0.1.93`. El target temporal `/home/jimbomilk/.cache/teremoq-e0308-sec-target.Mpog4I` fue eliminado al terminar.

| Comando | Resultado |
|---|---|
| `cargo fmt --all -- --check` | PASS |
| `cargo check --locked --offline -p moq-transport` | PASS |
| `cargo test --quiet --locked --offline -p moq-transport` | PASS: 270 unit, 1 integration; 0 fallos; 1 doctest ignorado |
| `cargo clippy --quiet --locked --offline --no-deps -p moq-transport --tests -- -D warnings` | PASS |
| `cargo test --quiet --locked --offline -p moq-native-ietf` | PASS: 32 unit + 6 `peer_evidence`; 0 fallos |
| `cargo test --quiet --locked --offline -p moq-relay-ietf` | PASS: 175 lib + 16 bin + 10 integration + 1 doctest; 0 fallos; 1 doctest ignorado |
| `cargo test --quiet --locked --offline -p moq-relay-ietf required_bounded_positive` | PASS: raw QUIC y WebTransport, 2 pruebas |
| `git diff --cached --check` | PASS |

La suite relay completa incluye las pruebas de denegación de certificado, evidencia ausente, capacidad N+1 antes de autenticación, path/scope autenticado, aislamiento concurrente y compatibilidad legacy. Dos intentos adicionales con un filtro incompleto y `--exact` seleccionaron 0 pruebas porque omitían el prefijo de módulo `i2_tests::`; se registran por transparencia y **no** se cuentan como evidencia focal. La ejecución completa anterior sí cubrió esos tests, y la prueba positiva raw/WebTransport se volvió a ejecutar con un filtro válido.

La búsqueda de secretos se ejecutó sobre `moq-transport/src/serve` con `zricethezav/gitleaks:v8.30.1@sha256:c00b91fc1b0570f5450267fdc4bd9a8fa3f134721e72506850916e30e355bb7f`, `--network none` y source read-only: 110281 bytes inspeccionados, 0 leaks.

La auditoría se ejecutó sin fetch con `cargo-audit 0.22.2` (binario SHA-256 `507532dd1ec54506ba6c3839b55a5ab0b47470c9667e9134926be35b10e231a3`) y el checkout local oficial de RustSec commit `a7bfe16948bf6f3ee25bdee4822209f87da21b80`, tree `1152ddcadf432f7bf97746e51fb7f2d9e5968c49`. El JSON resultante tiene SHA-256 `9fd2fe4ed24c7885cb266fb654491af01034cdbea1f98e39e98fb14701d80ec3`; exit code 1 por el inventario heredado descrito arriba, sin ignore ni supresión.

## Limitaciones y alcance del dictamen

- La auditoría RustSec usa un snapshot local fijado y no consulta red; no afirma conocer advisories posteriores a ese checkout.
- El resultado autoriza únicamente considerar el commit local de estos dos hunks test-only. No autoriza T, publicación, release, push, C2 adicional ni readiness comercial o productiva.
- Los advisories residuales requieren una decisión y revisión separadas; este paquete no los corrige.
- No se alteró ni se validó una PKI productiva; esta revisión verifica que el delta E0308 no invade ese límite.

## Veredicto

APPROVE

El staged package resuelve el error de tipo sólo en tests, mantiene byte-idénticos los límites criptográficos y de dependencia, y no introduce cambios de seguridad, protocolo, redacción o wire. La autorización queda restringida a que el Master considere un commit local de este snapshot exacto.

Confirmación: **READ-ONLY SECURITY REVIEW / NO WORKTREE EDIT / NO COMMIT / NO PUSH / NO REMOTE MUTATION**.
