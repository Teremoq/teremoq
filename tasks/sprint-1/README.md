# Sprint 1: Seguridad y Concurrencia

Prioridad de trabajo actual: [cierre de PoC y delegación de pruebas](../poc/ACCEPTANCE-AND-DELEGATION.md)
(acuerdo del usuario, 2026-09-09). El Master debe transmitirlo al responsable
existente e incluir vídeo real, actualizaciones y recuperación del canal.
Las secciones siguientes conservan el registro histórico del sprint; no
sustituyen la matriz actual de evidencia requerida por el contrato de cierre.

Este directorio contiene los contratos de ejecución para las tareas posteriores
a la PKI Smallstep y al cliente mTLS del Gateway.

## Orden de ejecución

1. Task 03, `task-03-federation-authorization.md`: completada mediante Ruta B.
2. Task 04, `task-04-concurrency-isolation.md`: completada como caracterización;
   los límites de relay continúan bloqueados por upstream.
3. Task 05, `task-05-upstream-coordination.md`: completada mediante Ruta B. El
   paquete de contribución está preparado en
   `gateway-rs/upstream/submissions/` y permanece `NOT SUBMITTED`.
4. El contrato histórico `task-05-controlled-moq-mirror-continuation.md`
   produjo el baseline privado inalterado. Queda sucedido, sin reescribir sus
   hechos, por `task-05-controlled-public-moq-derivative-continuation.md`.
5. La transición de gobernanza al derivado público independiente está
   documentada en ADR-0007 y
   `gateway-rs/upstream/mirror/public-transition-report-2026-08.md`. I1, I2, C1,
   C2 y la integración no han comenzado.

Task 05 depende de los ADRs de Tasks 03 y 04. No publica issues ni PRs sin una
autorización explícita posterior del Master/usuario.

## Próxima puerta

El Master ha aceptado los entregables documentales de Tasks 04 y 05. No se crea
una Task o perfil duplicado para la coordinación externa: si el usuario autoriza
el contacto upstream, la misma Task 05 y el perfil `TP-RUST-DIST` continúan como
propietarios, con revisión `TP-SEC-PKI` para identidad y redacción.

El usuario autorizó el contacto inicial acotado el 2026-08-26. Su contrato de
ejecución está en `task-05-authorized-upstream-contact.md`.

Task 05 realizó un único contacto el 2026-08-26 mediante la dirección oficial
`opensource@cloudflare.com`; el envío está auditado en
`gateway-rs/upstream/submissions/contact-log-2026-08.md`. No se envió ningún
draft, documento, link privado o código y la respuesta permanece pendiente.
No está autorizado un segundo mensaje o reply. Abrir issues, Discussions o PRs,
publicar código, crear un fork o cambiar dependencias requiere el alcance
explícito correspondiente después de revisar la respuesta upstream.
El usuario ha prohibido nuevos emails externos desde Tasks o agentes; cualquier
comunicación futura se limitará a preparar un borrador local para envío manual.

El usuario aprobó primero el mirror privado controlado y, después de la revisión
de gobernanza/supply chain aceptada, decidió transformarlo en un derivado público
controlado dentro del modelo open-source. `Teremoq/moq-rs-teremoq` continúa como
repositorio independiente (`fork=false`, sin parent), conserva `MIT OR
Apache-2.0` y contiene únicamente el baseline oficial inalterado. El cambio
posterior no invalida el bootstrap privado histórico.

La misma Task 05 y `TP-RUST-DIST` conservan la propiedad de identidad, admisión e
integración, con los revisores existentes. Public visibility no autoriza commits,
branches, pushes, issues, PRs o releases. El baseline exacto pasa clippy y tests
específicos native/relay con Rust 1.93.0, pero no pasa el test workspace locked ni
fmt por fallos upstream registrados; el Master debe revisar ese gate antes de
autorizar I1/I2.

Los perfiles propietarios y revisores se definen una sola vez en
`../TECHNICAL-PROFILES.md`; no se crean perfiles nuevos por Task.

## Estado de partida verificado

- Task 01: PKI Smallstep operativa, perfiles y smoke tests aprobados.
- Task 02: cliente Gateway mTLS TLS 1.3 operativo contra el relay privado.
- Integración positiva: publicación MoQT draft-16 de `/teremoq/live` aprobada.
- Integración negativa: certificado con EKU incorrecta rechazado.
- La revisión fijada de `moq-rs` es
  `bf87128affd316463e5dcc7599a45001f222b6de`.
- En esa revisión, `quinn` conoce la identidad mediante `peer_identity()`, pero
  `moq-native-ietf::quic::ConnInfo` no expone la cadena cliente y
  `moq-relay-ietf::CoordinatorContext` no transporta una identidad X.509/SPIFFE.
- La clasificación upstream por IP, SNI o path no es una identidad Zero-Trust.

## Criterio de cierre

No declarar completado Zero-Trust sólo porque mTLS valide la cadena. El cierre
requiere autenticación de certificado, autorización por identidad y namespace,
límites de concurrencia verificables, rechazo fail-closed y evidencia de chaos.

Tasks 03 y 04 pueden estar cerradas dentro de su alcance documental y de
caracterización mientras este criterio de producto siga abierto. Task 05 sólo
prepara la coordinación upstream y tampoco cierra por sí misma esos blockers.
