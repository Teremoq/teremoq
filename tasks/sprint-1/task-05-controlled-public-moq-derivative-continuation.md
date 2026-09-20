# Continuación de Task 05: derivado público controlado de moq-rs

- Perfil propietario único: `TP-RUST-DIST`
- Revisor obligatorio de identidad/privacidad: `TP-SEC-PKI`
- Revisión de gobernanza precedente aceptada: `TP-OSS-SC`
- Decisión del usuario: 2026-08-26
- Estado: transición pública autorizada; I1/I2/C1/C2 no autorizados

Este contrato sucede al modelo operativo de
`task-05-controlled-moq-mirror-continuation.md`. El contrato anterior se conserva
sin reescritura como evidencia del bootstrap privado que realmente ocurrió. No
es el runbook vigente para nuevas fases.

## Alcance de esta continuación

La misma Task 05 conserva propiedad sobre el derivado público independiente
`Teremoq/moq-rs-teremoq`. El baseline aprobado continúa siendo:

```text
commit bf87128affd316463e5dcc7599a45001f222b6de
tree   d76319009e815fb8923e21fc8319e17a0aaf8174
branch teremoq/baseline-draft16-bf87128
```

La rama sólo expresa procedencia. Builds e integraciones consumen commits
completos. El repositorio no es un fork de GitHub, permanece `MIT OR
Apache-2.0`, y toda contribución futura dentro de él usa esa misma expresión.

## Límites vigentes

Esta transición no autoriza crear commits, ramas, tags, pushes, issues,
Discussions, pull requests o releases. Tampoco autoriza I1, I2, C1, C2, cambios
de pins, vendoring, un segundo stack QUIC/WebTransport, wire/draft/ALPN nuevos,
dependencias/features nuevas, PKI, secretos, identidades/configuración de
clientes o datos operativos.

Los controles de repositorio aceptados por Task 06 deben mantenerse. Rulesets,
CodeQL Rust y Dependency Graph/SBOM continúan pendientes y no se presentan como
activos. El verificador actual sólo acepta el estado baseline de una rama exacta
y cero tags; no puede reutilizarse sin cambios después de crear una rama de
trabajo. Antes de la primera rama futura, la fase expresamente autorizada debe
producir y revisar localmente cada commit, conocer su SHA completo y evolucionar
`baseline.env`, el verificador y sus tests hacia un inventario cerrado de refs
completas y sus SHAs completos. La comprobación pre-push y la posterior deben
rechazar refs ausentes, adicionales o movidas y todos los tags. No se permiten
reglas por prefijo ni recuentos relajados, y este contrato no inventa ni aprueba
ningún SHA futuro. Toda acción pública requiere además revisión de
publicación/supply chain.

## Próxima fase posible: identidad I1/I2

Sólo una autorización posterior del Master puede iniciar la fase de identidad.
El prompt de esa continuación deberá fijar:

- I1 en `moq-native-ietf`: `quic::Server::accept`, `accept_session`, `ConnInfo`,
  `quinn::Connection::peer_identity()` y un retorno connection-owned/redactado;
- I2 en `moq-relay-ietf`: `Relay::{new,run}`, `CoordinatorContext`,
  `Coordinator::resolve_scope`, `ConnectionMeta` y hooks ilustrativos
  `AuthenticatedSession`/`SessionAuthorizer`/`Operation`;
- branches nuevas, pequeñas e inmutables desde el baseline exacto, sin usar
  branch names como dependencia;
- inventario exacto de cada ref aprobada y su SHA completo incorporado a la
  configuración y al verificador antes de crear la primera rama remota;
- `TP-SEC-PKI` como gate sobre fail-closed, aislamiento, redacción y la secuencia
  `verified certificate -> authenticated principal -> role -> operation -> exact
  namespace`;
- SPIFFE, principal, roles y policy fuera de `moq-rs`;
- ausencia de wire/draft/ALPN/dependency/feature/`unsafe` changes;
- pruebas sobre QUINN/rustls real para ausencia/tipo inesperado/denegación,
  ordering antes de scope/namespace, dos peers y salida sensible;
- revisión de licencia/procedencia y controles antes de cualquier push público.

El Master debe decidir además cómo tratar los fallos existentes del baseline:
`cargo test --verbose --locked` E0308 en un test de `moq-transport` y dos diffs de
`cargo fmt --all -- --check`. No pueden ocultarse ni corregirse bajo la mera
autorización de I1/I2.

## Fases posteriores no autorizadas

- **Admisión C1/C2:** `moq-native-ietf` y `moq-relay-ietf`, QUINN real, N/N+1,
  liberación RAII, deadline, cancelación, shutdown, métricas y revisión
  `TP-PLATFORM-CHAOS`.
- **Integración:** commits aprobados solamente, pin atómico de los tres crates,
  autorización SPIFFE, Chaos, draft-16/ALPN/Objects, rollback y retirada del
  relay de laboratorio, con ambos revisores.

Ninguna fase comienza automáticamente al aceptar este documento. El relay sigue
no productivo y los blockers de Zero-Trust y concurrencia acotada siguen abiertos.
