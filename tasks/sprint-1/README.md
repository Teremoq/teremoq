# Sprint 1: Seguridad y Concurrencia

Este directorio contiene los contratos de ejecución para las tareas posteriores
a la PKI Smallstep y al cliente mTLS del Gateway.

## Orden de ejecución

1. Task 03, `task-03-federation-authorization.md`: completada mediante Ruta B.
2. Task 04, `task-04-concurrency-isolation.md`: completada como caracterización;
   los límites de relay continúan bloqueados por upstream.
3. Ejecutar Task 05, `task-05-upstream-coordination.md`, para actualizar la
   investigación y preparar el paquete de contribución upstream.

Task 05 depende de los ADRs de Tasks 03 y 04. No publica issues ni PRs sin una
autorización explícita posterior del Master/usuario.

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
