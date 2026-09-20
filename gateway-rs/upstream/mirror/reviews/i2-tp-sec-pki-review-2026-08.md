# I2 formal security review — TP-SEC-PKI

- Fecha de revisión: 2026-08-27
- Revisor: `TP-SEC-PKI`
- Owner del código: Task 05 / `TP-RUST-DIST`
- Clon revisado, sólo lectura: `/home/jimbomilk/moq-rs-teremoq-work`
- Branch local: `teremoq/i2-required-auth-bf87128`
- Base I1 exacta / `HEAD`: `05b41127ecbd48de4c59fe1626c43b1e423c33a9`
- Árbol I1: `eca64a72e148482fb82b963edc2f2c9af28803f2`
- Snapshot revisado: seis ficheros I2 sin stage; cuatro modificados y dos nuevos
- Alcance: revisión adversarial de seguridad y concurrencia; no ownership de código

## Hallazgos

### [HIGH] I2 pierde el recurso solicitado al resolver el scope

`SessionAuthorizer::resolve_scope` sólo recibe `&AuthenticatedSession` y su
documentación excluye expresamente el connection path
(`moq-relay-ietf/src/authorization.rs:238-245`). `RequiredAuthorization` propaga
esa limitación sin otra entrada (`authorization.rs:273-275`). En el camino real,
el relay ejecuta esa resolución en `relay.rs:483-495`, antes de
`Session::accept_with_config` (`relay.rs:508-518`); el path canónico sólo se
consulta posteriormente en el camino legacy (`relay.rs:526-551`).

Esto no preserva el contrato existente de scope. `ScopeInfo` es la clave de
aislamiento para routing y namespaces, y el contrato actual permite que paths
distintos se resuelvan al mismo scope con permisos distintos
(`moq-relay-ietf/src/coordinator.rs:130-148`). `Coordinator::resolve_scope`
define el path como el recurso de entrada y lo usa para resolver scope y permisos
(`coordinator.rs:451-486`). El contexto autenticado es la identidad; el path es el
recurso solicitado. El API I2 actual obliga a ignorar ese recurso o a fingir que
forma parte de la identidad. Los gates posteriores por namespace son necesarios,
pero no recuperan la autorización ni la separación de interfaz que se perdió al
elegir el scope.

No es aceptable exigir un ordering imposible. En raw QUIC, PATH llega durante
CLIENT_SETUP y no existe cuando termina el handshake TLS; WebTransport puede
conocerlo antes. Por tanto, la corrección conservadora no debe retrasar la
autenticación ni volver a señales de transporte como principal:

1. conservar `PeerEvidence::Rustls -> authenticate` antes de cualquier setup;
2. ejecutar únicamente el setup necesario para obtener el path canónico;
3. autorizar/resolver el par `(AuthenticatedSession, requested connection path)`
   inmediatamente después, pasando sólo el path como recurso — nunca IP, SNI,
   `ConnInfo` ni `ConnectionTagger` — y antes de `ScopeInfo`, `SessionContext`,
   Producer, Consumer, watchers, lookup, registro, forwarding o mutación;
4. aplicar el mismo contrato a raw QUIC y WebTransport, y cerrar fail-closed si
   falta el path requerido o se deniega, sin `Coordinator::resolve_scope` legacy;
5. documentar que, para raw QUIC, el setup es el mínimo intercambio previo
   inevitable y que ninguna operación o estado de namespace existe todavía.

Task 05 debe introducir un input tipado de recurso solicitado en el hook required
(o un gate object-safe equivalente), no reutilizar `ConnectionMeta`. Debe probar
con el mismo certificado/contexto un path permitido y otro denegado en raw QUIC y
WebTransport, verificando cero creación de Producer/Consumer y cero efectos de
coordinator/namespace para el path denegado.

### [HIGH] Falta la composición obligatoria “certificado válido -> authorizer deniega”

La cobertura dividida I1+I2 no demuestra el pegamento de seguridad que se va a
consumir. I1 prueba que QUINN/rustls entrega `VerifiedPeerEvidence`; I2 prueba que
`PeerEvidence::Absent` no llega a `authenticate` (`i2_tests.rs:511-555`) y fabrica
directamente `AuthenticatedSession` para todos los tests posteriores
(`i2_tests.rs:407-466`). Ningún test entra en `Relay::new_required`, presenta un
certificado cliente válido, alcanza `SessionAuthorizer::authenticate`, recibe una
denegación y demuestra que no se llama a scope ni se inicia MoQT.

El propio informe owner reconoce el punto de composición no probado en
`gateway-rs/upstream/mirror/reviews/i2-local-review-2026-08.md:22-36`. Además,
`moq_native_ietf::tls::Args` construye cliente y servidor con
`with_no_client_auth`; ADR-0004 registra este límite en
`gateway-rs/ADR-0004-FEDERATED-MTLS.md:22-30`. El test no puede nombrar rustls por
ser una dependencia meramente transitiva. Esta restricción no convierte el gap
en evidencia aceptable.

Task 05 debe añadir un test integrado único, al menos para raw QUIC y
WebTransport, que:

- configure un verifier de certificado cliente real y un cliente con certificado
  válido usando rustls oficial;
- arranque `Relay::new_required` con un authorizer que deniegue `authenticate`;
- pruebe exactamente una llamada a `authenticate`, cero llamadas a
  `resolve_scope`, cero llamadas al Coordinator y fallo del setup cliente;
- pruebe que no existen handle de sesión, Producer, Consumer, registro, lookup ni
  estado de namespace;
- use sólo fixtures sintéticos públicos y no imprima DER, PEM, subject, SAN,
  serial, fingerprint, principal, rol ni contexto.

Si para construirlo dentro de `moq-relay-ietf` se necesita rustls, debe declararse
como dev-dependency directa sobre la versión ya fijada por `Cargo.lock`, sin
cambio de runtime y con revisión explícita de manifest/licencia. Como I2 tenía
una frontera “sin dependencias”, ese ajuste requiere autorización del owner y una
nueva revisión; una dependencia transitiva implícita o un test downstream futuro
no cierran este gate local.

### [MEDIUM] Los bypasses restantes se revisan por lectura, pero no tienen pruebas de efectos reales

La colocación de los gates en source es correcta, pero la suite adversarial no
cubre todo el contrato que pretende probar. `Deny` sólo puede denegar scope,
PUBLISH, PUBLISH_NAMESPACE y SUBSCRIBE (`i2_tests.rs:224-231`), y sólo el test de
PUBLISH_NAMESPACE denegado comprueba estado real de `Locals` y Coordinator
(`i2_tests.rs:649-685`). En particular:

- PUBLISH y SUBSCRIBE se comprueban principalmente mediante el vector de
  operaciones del mismo authorizer; el SUBSCRIBE falla además porque el track no
  existe (`i2_tests.rs:605-646`);
- el test de discovery sólo prueba el caso permitido de NAMESPACE
  (`i2_tests.rs:688-733`), no NAMESPACE_DONE ni denegación;
- no hay test adversarial de TRACK_STATUS ni de PUBLISH causado por
  SUBSCRIBE_NAMESPACE;
- relay-peer usa `Deny::None` y sólo compara dos registros del mismo authorizer
  (`i2_tests.rs:813-843`); no demuestra que una denegación en el segundo gate
  preceda efectos reales.

Task 05 debe añadir pruebas deterministas, sin sleeps, con handles/protocol state
y colaboradores instrumentados independientemente del authorizer para:

1. PUBLISH denegado: error visible, cero extracción/registro local, cero
   `register_track`, cero respuesta positiva;
2. SUBSCRIBE denegado contra un track existente: cero lookup/cache/serve;
3. SUBSCRIBE_NAMESPACE denegado: cero lease, interés, snapshot y REQUEST_OK;
4. DiscoverNamespace denegado tanto para NAMESPACE como NAMESPACE_DONE: ningún
   evento ni mutación de `known` observable;
5. discovery con opción Publish: autorización exacta antes del PUBLISH y ausencia
   del PUBLISH cuando se deniega;
6. TRACK_STATUS denegado contra un track existente: cero lookup y cero respuesta;
7. relay-peer: base permitido y segundo gate denegado, con cero registro, lookup,
   forwarding, respuesta o mutación.

Los timeouts acotados son aceptables como guardas; no deben sustituir una señal
determinista del efecto. Los asserts no deben incluir material de identidad.

## Controles confirmados por source

1. **Encapsulación y redacción.** `AuthenticatedSession` mantiene campos privados,
   contexto `Arc<dyn Any + Send + Sync + 'static>`, downcast comprobado y `Debug`
   fijo (`authorization.rs:12-83`). No usa `type_name`, `TypeId` ni bound `Debug`.
   `Operation`, `RelayPeerOperation` y `AuthorizationError` también tienen output
   fijo y sin targets (`authorization.rs:85-223`).
2. **Object safety y fail-closed.** `SessionAuthorizer` es `Send + Sync + 'static`,
   object-safe mediante `async_trait`, sin defaults permisivos, y se guarda como
   `Arc<dyn SessionAuthorizer>` (`authorization.rs:225-260`). Errores de
   authenticate y scope cierran sólo la conexión (`relay.rs:455-495`).
3. **I1 antes de MoQ.** El modo required consume todos los servers hacia
   `PeerEvidenceServer` antes de aceptar (`relay.rs:361-381`). Error de conversión,
   `Absent` y evidencia no soportada no producen fallback ni MoQT
   (`relay.rs:398-408`, `454-481`).
4. **Evidencia prestada.** `authenticate` recibe `&VerifiedPeerEvidence`; el valor
   owner de I1 se descarta tras producir el contexto (`relay.rs:454-485`). El
   principal, roles, SPIFFE y policy quedan fuera de upstream por contrato
   (`authorization.rs:225-229`).
5. **Sin identidad de transporte.** Aunque `ConnInfo` se extrae para operación
   de transporte, el branch required crea `SessionContext` sólo desde
   `AuthenticatedSession`; `ConnectionTagger`, IP, SNI y path quedan confinados al
   branch legacy (`relay.rs:410-418`, `557-575`). `new_relay_peer` prohíbe esas
   fuentes contractualmente (`authorization.rs:41-54`).
6. **Certificado válido sin decisión.** La lectura de `relay.rs:455-495` muestra
   cierre antes de scope/setup cuando `authenticate` deniega. Falta la prueba
   integrada descrita en el segundo hallazgo.
7. **Gates exactos antes de efectos.** PUBLISH_NAMESPACE autoriza antes de
   métricas, registros y forwarding (`consumer.rs:159-223`); PUBLISH antes de
   métricas, reader y registros (`consumer.rs:392-469`); SUBSCRIBE antes de
   métricas, lookup y cache (`producer.rs:208-331`); SUBSCRIBE_NAMESPACE antes de
   leases y REQUEST_OK (`producer.rs:352-410`).
8. **Discovery y status.** Cada NAMESPACE/NAMESPACE_DONE se autoriza sobre el
   namespace exacto (`producer.rs:479-561`); discovery->PUBLISH vuelve a autorizar
   el namespace exacto como lectura/Subscribe antes de publicar
   (`producer.rs:636-666`); TRACK_STATUS autoriza antes de lookup y respuesta
   (`producer.rs:694-750`). No se observó bypass source en esos handlers.
9. **RelayPeer.** La clasificación sólo existe dentro del contexto autenticado y
   cada operación debe pasar primero el gate base y después `Operation::RelayPeer`
   (`authorization.rs:67-75`, `277-290`). No existe degradación al gate base si el
   segundo falla.
10. **Concurrencia y lifetimes.** El contexto se liga al objeto de sesión mediante
    `Arc`, se clona hacia las tareas Producer/Consumer y no existe mapa global por
    IP/CID ni thread-local. El test de dos sesiones comprueba ausencia de cruce de
    contextos (`i2_tests.rs:760-811`). La retención es del contexto derivado, no de
    `VerifiedPeerEvidence`.
11. **Observabilidad.** Los errores required se ignoran como `_error` y generan
    mensajes fijos y labels de baja cardinalidad (`relay.rs:455-495`). Los
    handlers detectan `AuthorizationError` antes de loggear el error/namespace.
    No se encontró DER/PEM/subject/SAN/serial/fingerprint/principal/rol/contexto o
    nombre de tipo en Debug/Display/tracing/anyhow/métricas/qlog/mlog I2.
12. **Legacy y required.** `Relay::new` y builders existentes permanecen; el modo
    required es opt-in mediante `Relay::new_required`/`build_required`. El branch
    required no llama a Coordinator legacy ni a ConnectionTagger. Las pruebas
    legacy pasan en raw QUIC y WebTransport (`i2_tests.rs:558-603`).
13. **Frontera upstream.** El delta son exactamente seis ficheros de
    `moq-relay-ietf`; manifests, `Cargo.lock`, features, I1, wire/draft/ALPN y
    Objects no cambian. No hay `unsafe`, segundo transporte, parser X.509 ni
    policy Teremoq. El test fija `moqt-16` y draft-16 (`i2_tests.rs:846-855`).
14. **Cobertura I1+I2.** La cobertura dividida no es suficiente para el punto de
    composición de denegación con certificado válido; es obligatorio el test
    único descrito arriba.
15. **Calidad de tests.** No hay sleeps ni asserts que impriman certificados o
    contextos. Sí faltan pruebas independientes de efectos/order para varios
    handlers, según el tercer hallazgo.

## Validaciones reejecutadas

Todas las ejecuciones montaron `/home/jimbomilk/moq-rs-teremoq-work` como
`/work:ro` o `/repo:ro`; `CARGO_HOME` y `CARGO_TARGET_DIR` estuvieron en tmpfs del
contenedor. No se instaló nada globalmente.

| Validación | Resultado |
|---|---|
| Imagen oficial `rust:1.93.0@sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57` | resuelve; rustc `1.93.0`, commit `254b59607d4417e9dffbc307138ae5c86280fe4c` |
| `cargo test --locked -p moq-relay-ietf --lib` | PASS: 132/132 |
| `cargo test --locked -p moq-native-ietf --test peer_evidence` | PASS: 6/6, incluidos certificado presente raw QUIC/WebTransport y aislamiento concurrente I1 |
| rustfmt 1.93 sobre los seis ficheros I2 | PASS |
| `cargo clippy --locked -p moq-relay-ietf --lib --tests -- -D warnings` | PASS |
| `git diff --check` | PASS |
| Gitleaks `v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f`, seis ficheros I2, `--redact` | PASS: cero leaks en cada fichero |
| `cargo fmt --all -- --check` | no limpio por dos diffs baseline fuera de I2: `moq-transport/src/serve/subgroup.rs:934` y `tracks.rs:304`; el check focal I2 sí pasa |
| Stage/index | vacío |

Hashes protegidos confirmados tras las pruebas:

| Objeto | SHA-256 |
|---|---|
| `Cargo.toml` | `6665802c9ad7192d61521a62877454e25bde7072c611e617780a932f583aa48f` |
| `Cargo.lock` | `b518a2fa4a6d7a0ffe0bdfe4b530f05196ac0f5e6f7ef51da9e5a83c0b0561c0` |
| `moq-native-ietf/Cargo.toml` | `3180121a89c58071718236a408f36c1c87757d6f9ff81e899fb3b5814c8d4c8e` |
| `moq-relay-ietf/Cargo.toml` | `c88726b7739c35c4fcb42fd511bfe608e478b5d2489729081821fc84cd1b318d` |
| `moq-transport/Cargo.toml` | `78f582c201082f7badece64f7fa65d215a6694412b7a7699332fa3bc9a4f3743` |
| `REUSE.toml` | `afc7fd86e591a56078b11982ee4d039ea1dfe3f9d56a90e3e7fa9f84fbddb6cc` |
| MIT | `c7d191b5901a741f2e39c74bd7a7594014a81fbe2bc7d533d4c29ad4cfe4e057` |
| Apache-2.0 | `1248f876e0140942002b476a19c95d5b5b44c625e69c96611d23119ee87fa04e` |

## Riesgos residuales

- El wrapper opaco no puede impedir técnicamente que un embedder desobediente
  copie DER dentro de su propio contexto; el contrato, la implementación Teremoq
  y su review deben imponer contexto mínimo derivado.
- SPIFFE parsing, principal, roles, ACL/policy, reload y revocación no están en
  upstream I2 y no deben declararse implementados por este patch.
- `Arc` retiene el contexto derivado mientras vivan tareas de la sesión; esto es
  necesario para aislamiento, pero el contexto downstream debe ser pequeño, sin
  credenciales ni evidencia X.509.
- I2 no demuestra interoperabilidad mTLS independiente ni enforcement de
  revocación.
- Los dos diffs rustfmt baseline del workspace completo siguen fuera del scope I2
  y no se ocultaron ni modificaron.

## Veredicto

**CHANGES REQUIRED**

No se autoriza commit local hasta cerrar los tres hallazgos y reejecutar esta
revisión sobre un snapshot nuevo e inmutable.

**READ-ONLY SECURITY REVIEW / NO COMMIT / NO PUSH / NO REMOTE MUTATION**
