# Perfiles técnicos de Teremoq

Este registro evita crear un perfil distinto por cada Task. Un perfil puede ser
propietario de múltiples Tasks de su dominio. El Master Tech Lead define alcance,
dependencias y aceptación, integra resultados y devuelve cualquier incidencia a
la Task propietaria; no implementa el código de esas Tasks salvo petición expresa.

## Reglas de asignación

1. Cada Task tiene exactamente un perfil técnico propietario.
2. Una Task puede exigir revisores de perfiles existentes, sin crear copias del
   perfil ni transferirles la propiedad.
3. Un perfil nuevo sólo se crea cuando ninguna responsabilidad existente cubre
   el trabajo sin mezclar dominios incompatibles.
4. El propietario implementa, prueba, documenta y corrige su entrega hasta que
   el Master la acepte o declare un blocker externo.
5. El Master no corrige directamente una entrega rechazada: redacta un prompt de
   devolución para la misma Task y el mismo perfil propietario.
6. Acciones externas irreversibles o públicas, como abrir issues, publicar PRs,
   cambiar dependencias upstream o desplegar, requieren autorización explícita.

## TP-SEC-PKI: Security & PKI Engineer

Responsable de PKI, Smallstep, perfiles X.509, mTLS, SPIFFE, trust domains,
autorización por identidad, rotación, revocación y límites de exposición de
identidades o secretos.

No es responsable del accept loop QUIC, del scheduler ni del harness Docker,
pero revisa los contratos que transportan identidad autenticada entre esas capas.

Tasks asignadas:

- Task 01: infraestructura PKI.
- Task 03: autorización federada SPIFFE por namespace.

## TP-RUST-DIST: Rust Distributed Systems Engineer

Responsable de `gateway-rs`, Tokio, QUIC/MoQT mediante APIs upstream, aislamiento
de sesiones, concurrencia acotada, lifecycle, scheduler, integración del relay y
contribuciones técnicas a `moq-rs`.

No reimplementa protocolos ni mantiene forks silenciosos. Los cambios de
seguridad ligados a certificados requieren revisión de `TP-SEC-PKI`.

Tasks asignadas:

- Task 02: integración mTLS del Gateway Rust.
- Task 04: concurrencia, aislamiento y chaos federado.
- Task 05: coordinación de APIs upstream para identidad y admisión.

## TP-PLATFORM-CHAOS: Platform & Chaos Engineer

Responsable de Docker, scripts de infraestructura, redes de laboratorio,
`tc netem`, reproducibilidad, cleanup, límites de contenedor y ejecución segura
de smoke, hostile y soak.

No modifica la semántica del Gateway o de MoQT para hacer pasar un ensayo. Es
revisor obligatorio cuando una Task Rust añade o cambia harnesses de Chaos.

Tasks asignadas:

- Task 04, como perfil revisor del harness de Chaos.

## Creación futura

Los perfiles de frontend, media pipeline, observabilidad, AIOps, supply chain o
QA se añadirán aquí únicamente cuando se cree la primera Task que necesite ese
dominio. No se anticipan perfiles sin trabajo asignado.
