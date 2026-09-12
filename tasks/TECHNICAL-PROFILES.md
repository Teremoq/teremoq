# Perfiles técnicos de Teremoq

Este registro evita crear un perfil distinto por cada Task. Un perfil puede ser
propietario de múltiples Tasks de su dominio. El Master Tech Lead define alcance,
prioridades, candidata, dependencias y aceptación, y devuelve cualquier incidencia
a la Task propietaria. Sólo coordina: no desarrolla, depura, integra técnicamente
ni ejecuta ensayos. Task 05 es el integrador técnico único.

## Delegación vigente del laboratorio (2026-09-12)

El contrato [Cierre de la PoC y delegación de pruebas](poc/ACCEPTANCE-AND-DELEGATION.md)
registra DOC-POC-20260912-01. El responsable único del laboratorio es
`15.Platform RC100 Stabilization` / `TP-PLATFORM-CHAOS`
(`01a053e4-d0b3-74f1-84f8-03768ae84ee5`). Administra encargos y leases de
CLIENTE-01 en el issue privado existente, ensayos y cleanup ordenado.
CLIENTE-01 prepara y ejecuta localmente sólo sus encargos con acuse y lease
limitada, dentro de permisos y procedimientos vigentes. El cleanup nunca
concurre con un ensayo; una asistencia registrada no demuestra autonomía.

Task 05 (`01a03e47-a0db-7a20-ba4a-290bf8fbd09e`) recibe commits DCO y evidencias
y realiza la integración técnica. TP-OSS-SC es propietario documental de este
encargo. Web, Rust y Seguridad conservan sus dominios; no se crea otro perfil.
El canal propio/C1–C10 queda congelado para un hito posterior, salvo dependencia
real mínima asignada a su owner; no es prerrequisito del primer hito audiovisual.

Teremoq publica su código original bajo Apache-2.0 y mantiene privados los
despliegues B2B, las configuraciones de clientes y el trust material. El mirror
`moq-rs-teremoq` conserva la licencia upstream MIT OR Apache-2.0.

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
- Task 05: revisor de privacidad, procedencia y fronteras de identidad durante
  las fases de mirror e identidad.

## TP-RUST-DIST: Rust Distributed Systems Engineer

Responsable de `gateway-rs`, Tokio, QUIC/MoQT mediante APIs upstream, aislamiento
de sesiones, concurrencia acotada, lifecycle, scheduler, integración del relay y
contribuciones técnicas a `moq-rs`.

No reimplementa protocolos ni mantiene forks silenciosos. Los cambios de
seguridad ligados a certificados requieren revisión de `TP-SEC-PKI`.

Tasks asignadas:

- Task 02: integración mTLS del Gateway Rust.
- Task 04: concurrencia, aislamiento y chaos federado.
- Task 05: coordinación upstream, derivado público controlado de `moq-rs`,
  identidad, admisión e integración mediante fases sucesivas.

## TP-PLATFORM-CHAOS: Platform & Chaos Engineer

Responsable de Docker, scripts de infraestructura, redes de laboratorio,
`tc netem`, reproducibilidad, cleanup, límites de contenedor y ejecución segura
de smoke, hostile y soak.

No modifica la semántica del Gateway o de MoQT para hacer pasar un ensayo. Es
revisor obligatorio cuando una Task Rust añade o cambia harnesses de Chaos.

Tasks asignadas:

- Task 04, como perfil revisor del harness de Chaos.

## TP-OSS-SC: Open Source & Software Supply Chain Engineer

Responsable de gobernanza open-source, procedencia, inventarios de terceros,
SPDX/REUSE, SBOM, controles de GitHub y gates de supply chain y release.
Verifica que secretos, PKI runtime, configuraciones de clientes, namespaces
productivos y datos operativos no se publiquen.

No modifica lógica Rust o Next.js, protocolos, comportamiento del Gateway,
dependencias runtime, Docker productivo ni PKI. `TP-RUST-DIST` conserva la
propiedad de la implementación Rust y de contribuciones técnicas a `moq-rs`;
`TP-SEC-PKI`, de identidad, trust material, rotación y revocación; y
`TP-PLATFORM-CHAOS`, de redes, contenedores y harnesses de laboratorio.

Tasks asignadas:

- Bootstrap de gobernanza y supply chain de los repositorios públicos.

## TP-WEB-REALTIME: Real-Time Web Media Engineer

Responsable de `supervisor-web`, Next.js App Router, React, WebTransport del
navegador, el receptor MoQT draft-16 acotado por ADR-0003, WebCodecs, canvas,
telemetria de cliente, accesibilidad y pruebas E2E en Chrome/Edge.

No modifica `gateway-rs`, no implementa un relay o publisher MoQT, no amplia el
subconjunto browser a un stack generico y no introduce contrapresion en el data
plane. Los cambios de dependencias requieren revision de `TP-OSS-SC`.

Tasks asignadas:

- Task 07: endurecimiento MVP del supervisor web y del cliente multitrack.

## TP-AIOPS-EDGE: Edge AIOps Engineer

Responsable de `aiops`, contratos de eventos, guardrails para Ollama, inventario
de modelos, workflows internos autorizados y evaluacion de automatizaciones
locales fuera del camino critico.

No modifica el scheduler, la semantica de Object Dropping, `gateway-rs`, PKI ni
redes de despliegue. Durante las fases del Gateway en las que `.cursorrules`
limita AIOps a logs y metricas, solo puede preparar contratos, validadores,
threat models y bootstrap fail-closed; no crea agentes o workflows operativos.
La distribucion de n8n y la seleccion de pesos de modelos requieren revision de
licencia y autorizacion separada.

Tasks asignadas:

- Task 08: foundation AIOps local, contratos y controles de suministro, sin
  workflows operativos.

## TP-CONTROL-AUTOSCALE: Distributed Control Plane & Autoscaling Engineer

Responsable del plano de control distribuido y neutral respecto al proveedor:
topologia jerarquica, desired state, registro y lifecycle de nodos, reservas de
capacidad, placement multi-region, reconciliacion, autoescalado, cooldown,
histeresis, limites de nodos y coste, proteccion antifraude, recuperacion y
apagado seguro. Mantiene el simulador local determinista y el modelo de costes
configurable, sin poner el plano de control en la ruta critica del video.

No implementa PKI ni emite identidades, no modifica la semantica MoQT o el data
plane de `gateway-rs`, no administra contenedores o redes del harness y no crea
workflows AIOps. `TP-SEC-PKI` revisa autenticacion y bootstrap;
`TP-RUST-DIST`, los contratos del Gateway; `TP-PLATFORM-CHAOS`, infraestructura
y pruebas de fallo; y `TP-OSS-SC`, dependencias, imagenes y fuentes de coste.

Tasks asignadas:

- Task 09: plano de control y autoescalado local para el hito de 100
  espectadores.

## Creación futura

Los perfiles de media pipeline, observabilidad o
QA se añadirán aquí únicamente cuando se cree la primera Task que necesite ese
dominio. No se anticipan perfiles sin trabajo asignado.
