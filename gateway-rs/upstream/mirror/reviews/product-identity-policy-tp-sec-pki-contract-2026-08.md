<!--
SPDX-FileCopyrightText: 2026 Teremoq contributors
SPDX-License-Identifier: Apache-2.0
-->

# TP-SEC-PKI: integración local de política de identidad del product pin

Fecha: 2026-08-28  
Rol: `TP-SEC-PKI`  
Ámbito: PKI, política declarativa, pruebas contractuales y coordinación con
`TP-RUST-DIST`; sin push, publicación, secretos reales ni edición de Rust.

## Hallazgos primero

### HIGH — el contrato PKI está integrado, pero el producto aún debe aplicarlo

La política versionada y sus pruebas son fail-closed, pero no convierten por sí
solas el certificado en autorización efectiva. El patch owner actual,
`product-pin-owner-candidate-2026-08.patch` SHA-256
`03efa820f025ce378e2870d90d8af6e6c8a7384548f3b14fc7dd42d2471e3bab`,
todavía acepta cualquier cadena rustls-verificada no vacía como el mismo
publisher opaco. `TP-RUST-DIST` debe sustituir ese marcador por el contrato de
extracción y autorización descrito abajo. No se declara cerrado el gate de
producto mientras no existan y pasen esas pruebas Rust.

### MEDIUM — el scope upstream no expresa `WriteOnly`

El contrato I2 sólo ofrece `ScopePermissions::ReadWrite` o `ReadOnly` y
`can_subscribe()` es verdadero para ambos. Para publicar, el owner debe resolver
el scope como `ReadWrite`; la seguridad de no suscripción depende de que el
`SessionAuthorizer` niegue `Subscribe`, `SubscribeNamespace`,
`DiscoverNamespace` y `TrackStatus` antes del primer lookup, registro,
respuesta o mutación. No se inventa `WriteOnly` en este cambio. Ampliar ese enum
sería un cambio separado del derivado y requiere su propia revisión.

### Sin hallazgos bloqueantes en el slice propietario PKI

La tabla aprobada está representada sin wildcard ni prefix matching:

- principal exacto `gateway-dev-1`;
- path exacto `/publish`;
- operaciones exactas `Publish` y `PublishNamespace`;
- namespace exacto `teremoq/live`;
- cualquier relay, otro principal, recurso u operación: `deny`.

El archivo es público, no contiene material de certificado ni credenciales y
no convierte IP, DNS SAN, SNI, path o disponibilidad de capacidad en identidad.

## Cambios propietarios TP-SEC-PKI

1. `infra/pki/config/identity-policy.json` fija el contrato aprobado, el trust
   domain, la gramática del node ID, exactamente un URI SAN, SAN auxiliares
   permitidos por rol, default-deny y los límites 8/16 KiB/64 KiB.
2. `infra/pki/tests/identity-policy.sh` valida el documento completo y ejecuta
   decisiones positivas y negativas sin certificados ni secretos de
   producción. También prueba los valores frontera y `MAX+1`.
3. `infra/pki/scripts/verify.sh` ejecuta el contrato y contrasta que cada leaf
   Smallstep inicial tenga exactamente un URI SAN dentro de su extensión SAN.
4. `infra/pki/tests/pki-smoke.sh` incorpora el contrato al bootstrap aislado,
   idempotencia, renovación y revocación reales ya existentes.
5. `infra/pki/README.md` documenta la tabla, los límites y que la aplicación
   efectiva pertenece al runtime Rust.

No se modificaron `versions.env`, templates, provisioners, claves, secretos,
`Cargo.toml`, `Cargo.lock`, el derivado MoQ ni código Rust. Smallstep permanece
fijado en:

- `smallstep/step-ca:0.30.2@sha256:a2b17872915c193259b75a5474c398326f41bd199f0842093e52cf4182bc8270`,
  Apache-2.0;
- `smallstep/step-cli:0.30.6@sha256:474768dd54700088e9480210eaf2c25e3041ed1e8302c7cf211725381cec9f5e`,
  Apache-2.0.

## Contrato coordinado con TP-RUST-DIST

La inspección independiente de `TP-RUST-DIST` confirmó que el derivado local
`89cb1798644c32aef06cc625f097cd9acb203417` ya proporciona los gates genéricos
I1/I2/C1/C2 y no debe recibir política Teremoq. La implementación pertenece a
`gateway-rs` y debe limitarse a:

- nuevo `gateway-rs/src/security/federated_identity.rs`;
- export en `gateway-rs/src/security/mod.rs`;
- authorizer real en `gateway-rs/examples/dev_mtls_moq_relay.rs`;
- fixtures URI SAN sintéticos en `gateway-rs/tests/support/pki.rs`;
- pruebas producto raw QUIC/WebTransport en
  `gateway-rs/tests/moq_derivative_contracts.rs` y adaptación de
  `gateway-rs/tests/federation_concurrency.rs`;
- pin exacto e inventario de la dependencia en `Cargo.toml`, `Cargo.lock`,
  `DEPENDENCIES.md` y `deny.toml`.

### Extracción de identidad obligatoria

La dependencia aprobada es
`x509-parser = { version = "=0.18.1", default-features = false }`, licencia
`MIT OR Apache-2.0`. No se habilitan `verify`, `verify-aws` ni `validate`; rustls
sigue siendo el único verificador criptográfico. Su activación productiva
requiere el inventario de distribución y los gates supply-chain del owner.

`authenticate_verified_peer(&VerifiedPeerEvidence)` debe:

1. usar sólo evidencia rustls-verificada y prestada de la misma conexión;
2. rechazar cadena vacía, más de 8 certificados, leaf DER mayor de 16 KiB y
   suma DER mayor de 64 KiB mediante `checked_add`, antes de parsear;
3. parsear sólo `certificates()[0]`, exigir remainder vacío y no buscar
   identidad en intermediates;
4. exigir una única extensión SAN, recorrer todos sus `GeneralName`, rechazar
   cualquier `Invalid` y exigir exactamente un URI incluso si dos URI son
   iguales;
5. para gateway, rechazar cualquier SAN no URI; para relay, tolerar únicamente
   DNS/IP auxiliares e ignorarlos por completo como identidad;
6. aceptar sólo la reconstrucción byte-identical ASCII
   `spiffe://teremoq.local/{gateway|relay}/<node-id>`, con node ID
   `[A-Za-z0-9._-]{1,64}` y sin userinfo, port, query, fragment, `%`, Unicode,
   segmento extra, slash final, `.` o `..`;
7. conservar sólo rol y node ID. DER, PEM, subject, issuer, SAN completo,
   serial, fingerprint y errores/tipos del parser no pueden retenerse ni
   aparecer en `Debug`, `Display`, tracing, mlog/qlog, métricas o `anyhow`.

El authorizer debe aceptar en `authenticate` únicamente
`Gateway("gateway-dev-1")`, no construir nunca `new_relay_peer`, resolver sólo
el path `/publish`, y permitir mediante comparación tipada exacta:

- `Operation::Publish { namespace }`;
- `Operation::PublishNamespace { namespace }`;

cuando el namespace sea exactamente
`TrackNamespace::from_utf8_path("teremoq/live")`. El match debe tener wildcard
deny porque `Operation` es `#[non_exhaustive]`. Todo relay es default-deny.

El ordering protegido del derivado es: C1 admission antes de criptografía;
evidencia I1 ligada a la conexión; C2 admission; `authenticate`; path sólo como
recurso de policy; `resolve_scope`; `SERVER_SETUP`; y autorización de cada
operación antes de efectos. Capacidad no autentica ni autoriza. Required nunca
cae a legacy, coordinator o tagger para resolver identidad.

## Matriz de pruebas

| Gate | Evidencia local | Resultado |
|---|---|---|
| JSON estricto y sin campos permisivos | `python3 -m json.tool` + comparación estructural exacta | PASS |
| `gateway-dev-1` Publish exacto | test contractual | PASS |
| `gateway-dev-1` PublishNamespace exacto | test contractual | PASS |
| otro gateway/path/namespace | casos negativos | PASS, deny |
| Subscribe/SubscribeNamespace/DiscoverNamespace/TrackStatus | casos negativos | PASS, deny |
| RelayPeer y `relay-dev-1` | casos negativos | PASS, deny |
| trust domain, rol, `%`, query y traversal | casos negativos | PASS, deny |
| 8 certificados / leaf 16 KiB / total 64 KiB | fronteras sintéticas | PASS |
| 9 / 16 KiB + 1 / 64 KiB + 1 | fronteras sintéticas | PASS, deny |
| ampliación de allow o límites | mutaciones del documento | PASS, detectadas |
| URI SAN leaf Smallstep | extensión SAN inspeccionada; exactamente uno | PASS |
| bootstrap vacío e idempotente | `make pki-test` | PASS |
| renovación/revocación/temporales/permisos | `make pki-test` | PASS |

Las pruebas Rust todavía obligatorias incluyen DER truncado/trailing, SAN
ausente/duplicado/inválido, cero/dos URI, URI sólo en intermediate, límites,
gramática completa, redacción con canarios y flujos raw QUIC/WebTransport. Deben
probar positivo real hasta `PUBLISH_OK`, denegación antes de efectos y C2 N+1
antes de una segunda autenticación. Un certificado CA-válido pero no
allowlisted debe fallar antes de scope y `SERVER_SETUP`.

## Comandos y resultados

Ejecutados desde `/home/jimbomilk/teremoq`, sin red ni instalación:

```text
bash -n infra/pki/scripts/*.sh infra/pki/tests/*.sh                 PASS
python3 -m json.tool infra/pki/config/identity-policy.json         PASS
infra/pki/tests/identity-policy.sh                                 PASS
make pki-up                                                        PASS; loopback 9443
make pki-verify                                                    PASS
make pki-test                                                      PASS
git diff --check -- infra/pki                                     PASS
```

El smoke test creó su CA e identidades en un directorio temporal aislado,
repitió bootstrap sin cambiar fingerprints, verificó EKU/SAN/cadena/key,
renovación real, revocación registrada, permisos y limpieza, y eliminó ese
runtime al terminar. No se imprimieron claves, passwords, tokens ni PEM.

## Hashes del slice revisado

```text
d4005d735653854a2cb15346859203eacacd818cb4e452da9cd172e72895fa1f  infra/pki/config/identity-policy.json
13935e0122e047117207b8d85d05802eff96b491c31c8f74fc47d55df3625918  infra/pki/tests/identity-policy.sh
13743e424563c7ae036e67a38129ed1beddc7d21d8b7d0e5fc72f197beba5359  infra/pki/scripts/verify.sh
d5fa42d6acc992e55a97565f714ef84f831c0650251487b679919e9886b2ffd4  infra/pki/tests/pki-smoke.sh
1b113a6cf19b1470988dfc8ff201cef67c0855cbda4fc57d5e52cf89d1705eec  infra/pki/README.md
407ebfcfe8d913109c3c622bcbd976906e97af196d6895329436d7ad50c52a91  infra/pki/versions.env (sin cambio)
```

Fingerprints públicos del runtime de desarrollo verificado:

```text
root CA        2eb3eb7b5ea0678f612c57709d35c8c79f2b0b9be32b454b74b4f2b8174879b1
gateway-dev-1  3be0fbd845073240c8c050a1f73e74aab839d2c0f67580c002eea67bb2dcce10
relay-dev-1    0541365ea7a3bcb97f1c0406158928c95f5361729ad5b07d1bf2587a1f34383b
```

Expiraciones públicas: root `2036-08-22 19:12:07Z`; gateway-dev-1
`2026-09-24 19:15:05Z`; relay-dev-1 `2026-09-24 19:14:59Z`. Son artefactos de
desarrollo, no vigencias recomendadas para producción.

## Límites y estado final

- Slice `TP-SEC-PKI`: **completo y validado**.
- Enforcement efectivo del product pin: **requiere cambios de TP-RUST-DIST y
  una rerevisión independiente**.
- El pin Git del derivado sigue bloqueado hasta publicar de forma autorizada el
  commit exacto; este trabajo no autoriza ni realiza esa publicación.
- Revocación Smallstep queda registrada pero el runtime no demuestra todavía
  enforcement CRL/OCSP.
- La decisión criptográfica T, HSM/KMS y readiness productiva/comercial siguen
  fuera de alcance.

Los cambios locales se entregan de forma reversible con DCO:

```text
Signed-off-by: Jose María <12586102+jimbomilk@users.noreply.github.com>
```

No se realizó push, fetch, publicación ni mutación remota.
