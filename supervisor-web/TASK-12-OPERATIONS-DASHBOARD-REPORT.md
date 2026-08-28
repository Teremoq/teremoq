# Task 12 — Dashboard Central de Operaciones

Estado: **READY FOR MASTER REVIEW**

Perfil propietario: `TP-WEB-REALTIME: Real-Time Web Media Engineer`

Revisiones requeridas: integración contractual con `TP-CONTROL-AUTOSCALE` y
revisión final de seguridad por `TP-SEC-PKI`.

## Hallazgos

1. **No existe aún una fuente operativa real del plano de control.** Task 09
   entrega contratos versionados y un simulador determinista; no entrega un
   endpoint runtime aceptado. La configuración por defecto de `/operations`
   muestra `pendiente de integración`. El reporte local sólo se habilita con
   `TEREMOQ_OPERATIONS_LOCAL_SIMULATION=task-09` y toda su proyección queda
   etiquetada `simulación local`.
2. **El Gateway real no observa demanda autorizada, reservas, nodos o costes.**
   Su snapshot v1 sí aporta las cuatro fases de señal, Tracks, sesiones del
   scheduler, colas, descartes, expulsiones, conexión al relay, volumen
   distribuido y percentiles `ingest_to_publish`. La UI no completa con ceros
   los campos ausentes.
3. **El snapshot Gateway no incluye un timestamp UTC absoluto.** Expone uptime
   y edad de actividad. El adaptador conserva esas edades y asigna como
   timestamp de observación la recepción validada en el navegador. No lo
   presenta como timestamp de origen.
4. **El reporte Task 09 tampoco representa telemetría viva.** Su timestamp
   visible procede del `mtime` del fichero local fijo, validado server-side;
   la edad contractual se declara desconocida. Sus 100 espectadores, nodos,
   recuperación y costes son evidencia de simulación, no estado actual ni
   capacidad audiovisual medida.
5. **No hay contrato aceptado de evento activo ni alertas de seguridad.** Ambos
   aparecen como `pendiente de integración`; no se infieren del tráfico ni de
   la ausencia de alertas de capacidad del simulador.
6. **Las mutaciones siguen bloqueadas por diseño.** No se añadió ningún método
   `POST`, `PUT`, `PATCH` o `DELETE`, Server Action, formulario o handler de
   control. Los nueve controles son botones nativos `disabled` y explican la
   puerta de seguridad pendiente.

## Preflight y procedencia

- Base esperada y real: `d6f968c3c46802f10b0246808f0afb252fcb6b69`.
- Rama local creada desde el worktree desacoplado:
  `codex/task-12-operations-dashboard`.
- El worktree estaba limpio y sin cambios ajenos bajo `supervisor-web/**`.
- Árbol `supervisor-web` integrado:
  `acd975facc63a6b4b674d68616d9a90e747ad2a3`, idéntico a
  `bd35f784ddbb8e0cefe1027bacd00cf79347b5a3:supervisor-web`.
- Task 07 verificada mediante los commits fuente
  `648b800e9da8d1658112435bdd2ab630033445e9` y
  `bd35f784ddbb8e0cefe1027bacd00cf79347b5a3`.
- Árbol `control-plane` integrado:
  `1ffd80a0b2135c86b5d11751aeca49ae791de53d`, idéntico al subtree
  aceptado de Task 09.
- Task 09 verificada mediante los commits fuente
  `547d379fbc3fc28ef1029e77bdf3cbb45dc5140c`,
  `77c1c9fadc60235f2dd3e39dbf81c49f3b141a51` y
  `668b26511e89f5dd913312e7069e6eb7188d3fcb`.
- Se leyó `.cursorrules` completo, el perfil técnico canónico, Task 07,
  `SUPERVISOR.md`, las ADR 0002–0005 aplicables, la implementación relevante de
  `supervisor-web`, y contratos, documentación, configuración, modelo, CLI,
  motor, provider, fixtures y tests de `control-plane`.
- Se leyó la documentación instalada de Next.js 16.3.2 sobre Server/Client
  Components, Route Handlers, caching con y sin Cache Components, variables de
  entorno, navegación y CSS Modules antes de implementar.

## Arquitectura y aislamiento

```text
Gateway v1 real ── /gateway/api/v1/snapshot ── parser estricto ─┐
                                                               ├─ UI /operations
Task 09 local ── GET server-only, opt-in ── proyección redactada┘
Cloud / control real ── pendiente de contrato aceptado
```

- `/` conserva el supervisor técnico, player, lifecycle, polling, validaciones,
  WebTransport, MoQT, WebCodecs y canvas de Task 07. El único cambio es un
  enlace accesible a `/operations`.
- `/operations` es una Client Component separada. Su fallo de parsing, fuente o
  polling no comparte estado con el player ni altera `/`.
- El parser Gateway consume la frontera existente `/gateway`; nunca lee el
  filesystem ni muestra `peer`, `connection_id` o URL de relay.
- El adaptador Task 09 corre server-side en un Route Handler exclusivamente
  `GET`. Sólo admite el valor cerrado `task-09`, lee una ruta fija, limita el
  fichero a 2 MiB, valida el reporte y proyecta un view model sin IDs, digests,
  auth context, paths o errores internos. No existe selector de archivo.
- Los parsers rechazan fail-closed schema distinto de v1, propiedades
  desconocidas, enums/tipos inválidos, enteros fuera del rango JSON seguro,
  edades/timestamps imposibles, cardinalidad o payload excesivo, Tracks/fases
  duplicados, percentiles desordenados, relaciones MoQ incompletas y relaciones
  Task 09 inconsistentes.
- Cada fuente usa un `SingleFlightPoller` con una generación, un request activo,
  `AbortController`, timeout, backoff exponencial acotado y un único timer
  sucesor. El teardown aborta request y timers. Este lifecycle no se mezcla con
  el player.
- Todas las respuestas del adaptador local usan `no-store`, `nosniff` y CSP
  cerrada. No se añadieron dependencias.

## Rutas y archivos

Rutas:

- `/`: supervisor audiovisual existente, con navegación a Operaciones.
- `/operations`: Dashboard Central de Operaciones read-only.
- `/operations/api/control-plane`: `GET` opt-in para la proyección redactada de
  la simulación local; `503 not-configured` por defecto.

Archivos nuevos o modificados:

- `README.md`.
- `TASK-12-OPERATIONS-DASHBOARD-REPORT.md`.
- `evidence/operations-desktop.png`.
- `evidence/operations-tablet.png`.
- `src/app/page.tsx` y `src/app/page.module.css`.
- `src/app/operations/page.tsx` y `src/app/operations/page.module.css`.
- `src/app/operations/api/control-plane/route.ts`.
- `src/components/operations-dashboard.tsx`.
- `src/components/operations-dashboard.module.css`.
- `src/components/operations-dashboard.test.tsx`.
- `src/lib/operations/types.ts`.
- `src/lib/operations/validation.ts`.
- `src/lib/operations/gateway-adapter.ts` y su test.
- `src/lib/operations/control-plane-adapter.ts` y su test.
- `src/lib/operations/poller.ts` y su test.

No se modificó `gateway-rs/**`, `control-plane/**`, `.cursorrules`, perfiles,
infraestructura, PKI, raíz ni lockfiles.

## Fuentes, provenance y freshness

| Provenance | Naturaleza | Timestamp/edad | Estado por defecto |
| --- | --- | --- | --- |
| `gateway-real` | Snapshot v1 real de `gateway-rs` | recepción browser + `last_activity_ms` del contrato | consultado; pérdida/rechazo explícitos |
| `control-plane-simulation` | reporte versionado Task 09 | `mtime` local validado; edad contractual desconocida | `pendiente de integración` salvo opt-in |
| `cloud-future` | integración futura no definida | sin timestamp/edad | `pendiente de integración` o `no medido` |

Freshness Gateway:

- `fresh`: edad no superior a 3 s;
- `aging`: más de 3 s y hasta 10 s;
- `stale`: más de 10 s;
- `unknown`: el contrato no aporta una edad utilizable.

Cada tarjeta incluye provenance, estado de medición, timestamp, edad y
freshness. La tabla de nodos conserva esa metadata a nivel de conjunto y cada
fila mantiene la etiqueta `LISTO · SIMULADO`, además de provider/region
neutrales.

## Diccionario de campos

| Campo de Operaciones | Fuente actual | Calidad |
| --- | --- | --- |
| Estado general | fases Gateway v1 | real, derivado de estados contractuales |
| Evento activo | ninguna | pendiente de integración |
| Espectadores autorizados | último signal Task 09 | simulación local |
| Sesiones activas | scheduler Gateway; Task 09 se muestra aparte | real / simulada, sin confundir |
| Reservas vigentes | último signal Task 09 | simulación local |
| Roles/provider/region/estado | action envelopes + metrics Task 09 | simulación local |
| Capacidad total/disponible/reservada/utilización | actions/signal Task 09 | simulación local |
| Entrada, demux y distribución | fases Gateway | real |
| Gateway–relay | `moq.connected` | real; URL e identidad redactadas |
| Ancho de banda | signal `egress_mbps` Task 09 | simulación, no medida real |
| Volumen distribuido | `moq.bytes` | real acumulado |
| Latencia p50/p95/p99 | `latency.ingest_to_publish` | real si `samples > 0` |
| Cola, descartes, expulsiones | scheduler Gateway | real; cero sólo si explícito |
| Alertas capacidad/fallo | alerts Task 09 | simulación local |
| Alertas seguridad | ninguna | pendiente de integración |
| Sustitución/recuperación/drain | counters/report Task 09 | simulación local |
| Coste medido | `local_measured_remote_infrastructure_cost` | simulación local; cero explícito |
| Coste proveedor estimado | `external_provider_estimate` | no medido (`null`) |
| Estado plano de control | disponibilidad de la proyección | simulación o pendiente |

## Experiencia, accesibilidad y responsive

- Orden implementado: resumen; espectadores/capacidad; nodos; calidad/latencia;
  alertas; costes; actividad; controles deshabilitados.
- Lenguaje visual Teremoq preservado mediante CSS Modules, sin librería visual.
- Landmarks, `nav`, jerarquía `h1/h2/h3`, tabla con `caption`/`thead`/`tbody`,
  listas ordenadas/no ordenadas, `time`, live source states y texto que no
  depende sólo del color.
- Navegación y tabla accesibles por teclado; focus visible; botones nativos
  `disabled`; explicación compartida con `aria-describedby`; contraste oscuro
  con texto explícito y reduced-motion.
- Breakpoints verificables: desktop 1100 px, tablet 820 px y móvil 560 px.

## Controles preparados, no operativos

Se muestran, sin handler:

- iniciar/finalizar evento;
- crear capacidad y escalar distribuidores;
- drenar y sustituir nodo;
- activar redundancia;
- detener autoescalado;
- apagado de emergencia.

Todos requieren antes autenticación, RBAC, CSRF, auditoría, límites de coste,
idempotencia, confirmación crítica, rollback, kill switch e integración
aceptada. Esta Task **no controla la plataforma** y no declara el Dashboard
operativo para mutaciones.

## Evidencia visual

- `evidence/operations-desktop.png`: Chrome headless real, 1440×1100,
  SHA-256 `5df3d86dfadf4e5a0d3071083d844cbf2cdd92095400b6b783c49ae727d12698`.
- `evidence/operations-tablet.png`: Chrome headless real, 820×1180,
  SHA-256 `a4caf3c09c20def19d852f21a76233a187120d9d87dcf844beb6e4dfaec21440`.

La captura activa Task 09 como `simulación local`; el Gateway real estaba
deliberadamente ausente y aparece `Fuente perdida`. No se usó media simulada ni
se afirma interoperabilidad/E2E de vídeo. Chrome mostró la ruta real servida por
Next; no se instaló Playwright ni otro navegador.

## Pruebas y resultados

Baseline Linux reproducible (`node:22-bookworm-slim`, Node 22.22.1):

- `npm ci`: PASS, 415 paquetes, 416 auditados, 0 vulnerabilidades.
- `npm test`: PASS, 10 ficheros / 67 tests.
- `npm run lint`: PASS.
- `npm run build`: PASS, `/` estática.
- `npm audit --audit-level=high`: PASS, 0 vulnerabilidades.
- `git diff --check`: PASS.

Suite final:

- parsers/adaptadores: versión, propiedades, enum/tipos, timestamp/edad,
  cardinalidad, payload, relaciones y percentiles;
- válido/ausente/antiguo/excesivo/malformado/inconsistente;
- cero explícito frente a ausencia;
- pérdida, rechazo y recuperación de Gateway/plano de control;
- cancelación, timeout, backoff, máximo, no solapamiento y teardown;
- provenance/freshness y ausencia de métricas inventadas;
- redacción de IP, URL, IDs, digests, identidad, path y error interno;
- nueve controles nativamente `disabled` y ausencia de métodos mutables;
- landmarks, headings, tabla/listas semánticas, navegación/focus y breakpoints;
- los 67 tests previos del supervisor se ejecutan sin modificación.

Puerta final Linux reproducible (`node:22-bookworm-slim`, Node 22.22.1):

- `npm test`: PASS, 14 ficheros / 87 tests; incluye sin cambios los 67 tests
  previos del supervisor.
- `npm run lint`: PASS.
- `npx tsc --noEmit`: PASS.
- `npm run build`: PASS; `/` y `/operations` estáticas, proyección GET del plano
  de control dinámica.
- `npm audit --audit-level=high`: PASS, 0 vulnerabilidades.
- `git diff --check`: PASS.

No se declara E2E: las capturas verifican render y responsive en navegador real;
los tests deterministas son unitarios/de componente. No se ejecutó una ruta de
vídeo Gateway/relay/player real en esta Task.

## Riesgos y revisión `TP-SEC-PKI`

Revisión obligatoria antes de cualquier integración real:

1. definir cómo se crea y vincula `VerifiedAuthContext` sin exponer principal,
   certificado, URI SPIFFE o trust material;
2. revisar autenticación/autorización de la futura fuente runtime y la frontera
   server-side de redacción;
3. confirmar límites de identidad/cardinalidad, mensajes enumerados y ausencia
   de correlación por IP/SNI/path;
4. confirmar que alertas de seguridad usan un contrato bajo y fail-closed;
5. mantener bloqueadas todas las mutaciones hasta aceptar RBAC, CSRF, auditoría,
   idempotencia y kill switch.

No se editaron dominios de `TP-SEC-PKI` ni `TP-CONTROL-AUTOSCALE`.

## Dependencias y limitaciones

Dependencias añadidas: **ninguna**. `package.json` y `package-lock.json` no se
modificaron.

Limitaciones honestas:

- no hay endpoint real aceptado del plano de control;
- no hay contrato de evento activo ni alertas de seguridad;
- el ancho de banda sólo existe en la simulación Task 09;
- no hay capacidad ni coste cloud real;
- Task 09 no demuestra carga audiovisual ni capacidad productiva;
- la freshness de la fixture local es desconocida por contrato;
- el polling de `/operations` no sustituye observabilidad backend;
- no se ejecutó E2E real de vídeo ni un viewport móvil real; móvil está cubierto
  por reglas y pruebas verificables, desktop/tablet por Chrome real.

## Confirmaciones de entrega

- Pathset de escritura: exclusivamente `supervisor-web/**`.
- Cero push, fetch, PR, issue, release, publicación o despliegue.
- Cero credenciales, recursos remotos o cambios de infraestructura/PKI.
- Cero dependencias o cambios de lockfile.
- Cero endpoints mutables u operaciones de proveedor.
- Commits locales reversibles con DCO exacto de José María.
- Los hashes del commit, patch final y reporte se calculan después del commit y
  se entregan al Master fuera del propio reporte para evitar autorreferencia.

**READY FOR MASTER REVIEW** — pendiente de aceptación del Master y revisión
posterior obligatoria de `TP-SEC-PKI`.

## Corrección de hallazgos Task 13

Tras el dictamen `CAMBIOS REQUERIDOS` de `TP-SEC-PKI`, se corrigieron sin
ampliar el pathset ni la capacidad funcional del dashboard:

- `B-F01`: Gateway y plano de control usan un lector incremental BYOB que
  solicita como máximo 64 KiB y reduce la última lectura a `límite + 1`;
  cancela el body inmediatamente al cruzar el límite. Si una implementación
  no ofrece BYOB, cancela y rechaza fail-closed antes de leer el primer chunk.
  El fixture se abre una vez, se verifica
  y lee sobre ese mismo descriptor con límite durante la lectura y cierre en
  `finally`, eliminando la ventana `stat(path)`/`readFile(path)`.
- `B-F02`: el validador Task 09 v1 cierra `runtime`, `inputs`, rollback,
  cleanup, acciones, envelopes, recovery, métricas, distribuciones y cada uno
  de los cuatro escenarios/reconciles. Aplica los invariantes y hashes cerrados
  por `TP-CONTROL-AUTOSCALE` sólo al artefacto local Task 09; la proyección
  provider/region continúa neutral y no define un contrato cloud.
- `B-F03`: se añadió el índice normalizado
  `reports/task-12/README.md`, enlazado a este informe y a la evidencia
  preservada.

Pruebas añadidas: streams BYOB adversariales de Gateway/control-plane con
cancelación observable exactamente en `límite + 1`; crecimiento del fichero
después de la verificación con cierre observable del descriptor; objetos
anidados desconocidos/faltantes; escenario intermedio, orden y cardinalidad
malformados; y proyección real opt-in del artefacto cuyo SHA-256 raw es
`99ccc74f6e8ceeeaaf86b18aa16a9610b7f6185feec8037a94e41b8c4bf1a77f`.

La configuración continúa GET-only, read-only, opt-in y redactada. Los nueve
controles permanecen nativamente deshabilitados.

Puerta final de la corrección (`node:22-bookworm-slim`, montando la raíz local
para leer el artefacto contractual junto a `supervisor-web`):

- `npm test`: PASS, 15 ficheros / 93 tests.
- `npm run lint`: PASS.
- `npx tsc --noEmit`: PASS.
- `npm run build`: PASS.
- `npm audit --audit-level=high`: PASS, 0 vulnerabilidades.
- `git diff --check`: PASS.

### Re-revisión `B-RR-F01-01`

La re-revisión de `TP-SEC-PKI` identificó que un `DefaultReader` podía entregar
un chunk de tamaño arbitrario antes de que la aplicación lo cancelase. Se
eliminó ese fallback: adquirir BYOB es ahora una precondición cerrada. Si
`getReader({ mode: "byob" })` no está disponible, el body se cancela desbloqueado
y la fuente se rechaza sin ejecutar ningún `pull`. El dashboard conserva el
snapshot fuera de presentación y muestra la fuente/datos como rechazados o no
disponibles; nunca convierte el fallo en cero.

La regresión adversarial usa un body default preparado para producir 700 KiB y
demuestra `pulls = 0` y cancelación observable. La cobertura total pasa a 94
tests, sin cambios de UI, endpoints, controles, dependencias ni evidencia.

Puerta final posterior a la re-revisión:

- `npm test`: PASS, 15 ficheros / 94 tests.
- `npm run lint`: PASS.
- `npx tsc --noEmit`: PASS.
- `npm run build`: PASS.
- `npm audit --audit-level=high`: PASS, 0 vulnerabilidades.
- `git diff --check`: PASS.
