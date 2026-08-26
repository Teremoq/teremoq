# Prompt para Task 04: Concurrencia, aislamiento y chaos federado

- Perfil propietario: `TP-RUST-DIST` (Rust Distributed Systems Engineer)
- Perfil revisor: `TP-PLATFORM-CHAOS` (Platform & Chaos Engineer)
- Registro: `tasks/TECHNICAL-PROFILES.md`

Copia y pega íntegramente el siguiente prompt en la Task 04, después de que
Task 03 haya terminado y su ADR esté disponible.

---

Actúa como Principal Rust Distributed Systems Engineer especializado en Tokio,
QUIC y pruebas de carga para broadcast crítico. Trabaja directamente en
`/home/jimbomilk/teremoq` bajo Ubuntu/WSL2.

Tu misión es demostrar y endurecer la concurrencia acotada de la federación
privada sin afectar la ingesta, el scheduler, Object Dropping ni el principio
Zero-Transcoding. Un peer lento, inválido o malicioso no puede bloquear un peer
válido ni provocar crecimiento no acotado de memoria, tasks, handshakes o
reintentos.

## 1. Preflight obligatorio

1. Lee completamente `/home/jimbomilk/teremoq/.cursorrules`.
2. Lee el resultado de Task 03, especialmente
   `gateway-rs/ADR-0005-FEDERATED-AUTHORIZATION.md` y cualquier documento en
   `gateway-rs/upstream/`. No presupongas que autorización SPIFFE ya funciona.
3. Inspecciona `Cargo.toml`, `Cargo.lock`, `deny.toml`,
   `ADR-0004-FEDERATED-MTLS.md`, `src/gateway.rs`, `src/adapters/moq.rs`,
   `src/scheduler.rs`, `src/adapters/srt.rs`, `src/lifecycle.rs`,
   `examples/dev_mtls_moq_relay.rs`, `tests/mtls_quic.rs`,
   `tests/moq_relay_interop.rs` y `tests/lab/`.
4. Inspecciona el source exacto del commit fijado de `moq-rs`, en particular
   `moq-native-ietf::quic::Server::accept` y `moq-relay-ietf::Relay::run`.
5. Preserva cambios existentes; no reviertas trabajo ajeno.
6. Usa `apply_patch` para ediciones manuales y crea toda carpeta necesaria.
7. No ejecutes chaos sobre interfaces, puertos o contenedores compartidos. Todo
   ensayo debe quedar en una red Docker aislada con cleanup por `trap`.

## 2. Hechos y riesgos de partida que debes verificar

- El Gateway actual mantiene una única sesión publisher MoQT con timeout,
  backoff exponencial, jitter y presupuesto móvil.
- SRT tiene `max_sessions`; el scheduler tiene límites por Objects, bytes y
  subscribers.
- `moq-native-ietf::quic::Server` procesa handshakes concurrentemente mediante
  `FuturesUnordered` y usa idle timeout, pero en la revisión fijada no se ha
  demostrado un límite explícito de handshakes pendientes.
- `moq-relay-ietf::Relay::run` mantiene tasks de conexión en otro
  `FuturesUnordered`; no se ha demostrado un máximo explícito de sesiones
  activas.
- El relay 4443 actual es un laboratorio loopback, no el relay federado
  productivo.

No confundas "los peers válidos progresan" con "el consumo está acotado". Un
test pequeño que pasa no demuestra resistencia a un flood.

## 3. Objetivos verificables

1. Definir límites explícitos y configurables para cada colección alimentada
   por red que Teremoq controle.
2. Aislar handshakes pendientes, sesiones activas, publishers, subscribers y
   reconexiones.
3. Rechazar exceso de carga de forma temprana y observable, sin espera
   indefinida ni cola oculta.
4. Confirmar que un peer válido mantiene progreso bajo mezcla de peers lentos e
   inválidos dentro del perfil de prueba.
5. Confirmar cierre coordinado sin tasks, contenedores, reglas `tc` ni material
   PKI temporal huérfano.
6. Medir memoria RSS, número de tasks/sesiones, sockets, tasa de aceptación,
   rechazos, tiempo de handshake y tiempo de recuperación. No inventar SLOs.

## 4. Puerta de reutilización upstream

Antes de implementar límites en el relay:

1. Busca en la revisión fijada y en releases/issues/PRs oficiales de `moq-rs`
   knobs para máximo de handshakes pendientes, máximo de conexiones/sesiones,
   timeout de handshake, retry/address validation y cierre por sobrecarga.
2. Revisa APIs oficiales de QUINN/rustls sólo a través de `moq-rs`; no añadas
   un segundo endpoint directo ni reconstruyas WebTransport/MoQT.
3. Si una release compatible ofrece límites públicos, documenta y realiza una
   actualización atómica fijada, con regresión completa de draft-16.
4. Si faltan límites públicos, no copies `Server::accept` o `Relay::run`, no
   vendorizas y no mantengas un fork silencioso. Documenta el blocker en
   `gateway-rs/ADR-0006-FEDERATION-CONCURRENCY.md` y añade a
   `gateway-rs/upstream/` una propuesta mínima de API y tests upstream.
5. Un límite de Docker, cgroup o firewall es defensa adicional, no reemplaza el
   límite de estado lógico dentro del proceso.

Si el upstream impide imponer un límite real, caracteriza el comportamiento y
declara el gap. No presentes un test acotado como garantía de producción.

## 5. Implementación permitida

### 5.1 Componentes propios

- Amplía configuración existente sólo para límites que puedan conectarse a una
  frontera real. Todos los valores deben tener default, mínimo, máximo y
  validación fail-closed.
- Usa `tokio::sync::Semaphore`, `JoinSet`, `CancellationToken`, channels
  acotados y timeouts monotónicos cuando corresponda. No mantengas un permit a
  través de trabajo no relacionado.
- La saturación de una sesión nunca adquiere un lock global del data plane.
- No uses `spawn_blocking` para esconder I/O de red o esperas async.
- No añadas colas sin límite ni `collect()` sobre streams controlados por red.
- Mantén errores recuperables por peer; sólo errores de configuración local o
  invariantes globales pueden impedir startup.
- Conserva el orden de startup: identidad mTLS y configuración válidas antes de
  GStreamer/SRT/listeners de servicio.

### 5.2 Relay upstream

- Reutiliza límites oficiales si existen.
- Si el upstream permite inyectar un admission controller público, implementa
  uno pequeño y específico de Teremoq; no copies el relay.
- Cuando no haya capacidad disponible, rechaza/cierra esa conexión y libera
  estado inmediatamente. No pongas conexiones remotas a esperar por un permit
  indefinidamente.
- Separa como mínimo capacidad de handshake y capacidad de sesión autenticada,
  si la API realmente permite observar ambas fases.
- No eleves una conexión a `relay-peer` por IP/SNI/path; respeta la decisión de
  Task 03.

## 6. Estructura que debes crear

Crea sólo lo necesario, usando como base:

```text
chaos/
  federation/
    README.md
    run.sh
    lib.sh
    profiles/
      smoke.env
      hostile.env
    reports/
      .gitignore
gateway-rs/
  tests/
    federation_concurrency.rs
  ADR-0006-FEDERATION-CONCURRENCY.md
  upstream/
    moq-rs-concurrency-limits-proposal.md   # sólo si falta API
```

Los scripts deben pasar `bash -n` y, si está disponible, `shellcheck`. Los
reports generados no se versionan salvo un resumen Markdown anonimizado y
reproducible. No guardes certificados, claves, tokens, IPs externas ni dumps de
payload.

## 7. Harness de chaos

1. Reutiliza Docker, `tc netem` y scripts existentes en `gateway-rs/tests/lab`
   cuando cubran la necesidad. No desarrolles un simulador de red propio.
2. Usa una red bridge Docker exclusiva y nombres de proyecto únicos.
3. Fija toda imagen por versión y digest. No uses `latest`, tags flotantes ni
   colecciones de paquetes instaladas por conveniencia.
4. Concede `NET_ADMIN` únicamente al contenedor que aplica `tc`; no uses
   `--privileged`.
5. El script debe comprobar requisitos, puertos, Docker y reloj antes de tocar
   estado; debe restaurar qdisc y eliminar contenedores/redes temporales incluso
   ante `SIGINT`, error o timeout.
6. Soporta al menos perfiles `smoke` y `hostile`, con semillas y parámetros
   impresos en el reporte.
7. Define duración y carga acotadas por defecto. Un soak largo debe requerir un
   flag explícito, nunca arrancar accidentalmente.

## 8. Matriz mínima de pruebas

Ejecuta pruebas herméticas y una integración Smallstep real para:

1. Un Gateway válido conecta y publica mientras varios handshakes inválidos
   fallan.
2. Handshakes TCP-style parciales no aplican a QUIC: simula peers QUIC que
   inician y no completan TLS usando una herramienta/biblioteca upstream, no UDP
   crudo presentado como QUIC.
3. Certificados anónimo, CA incorrecta, EKU incorrecta, expirado y no autorizado
   se aíslan por motivo.
4. Al alcanzar el máximo real, la conexión N+1 se rechaza temprano y la memoria
   no crece con una cola de espera.
5. Al cerrar una sesión, el permit se recupera y una nueva conexión progresa.
6. Cancelación durante handshake y durante sesión libera permit y task.
7. Un subscriber lento no retrasa a uno rápido ni a la ingesta.
8. Una tormenta de reconexión respeta backoff, jitter y presupuesto; no crea
   múltiples publishers simultáneos para el mismo Gateway.
9. Pérdida, jitter, reordenación, limitación de ancho de banda y partición
   temporal no hacen crecer memoria de forma sostenida.
10. Audio/telemetría conservan prioridad; vídeo delta se descarta antes bajo
    congestión. No prometas entrega física imposible.
11. El relay browser 4433 y el privado 4443 permanecen aislados.
12. El cierre deja cero procesos de prueba, cero qdisc temporales y cero secrets
    fuera del runtime efímero.

No generes cientos de certificados persistentes. Reutiliza identidades de test
acotadas y genera material hermético en directorios temporales con `umask 077`.

## 9. Métricas y criterios de evidencia

Cada reporte debe incluir:

- commit/revisión, toolchain, kernel, Docker, CPU y memoria disponibles;
- perfil, semilla, duración y número de peers;
- límites configurados y límite realmente aplicado;
- p50/p95/p99/máximo de handshake y recuperación;
- RSS inicial, pico y final;
- sesiones aceptadas/rechazadas/cerradas y motivo enumerable;
- progreso del peer válido y Objects recibidos;
- tasks/sockets antes, durante y después;
- advertencia clara cuando una métrica no pueda observarse con APIs públicas.

No declares ausencia de leak por una única muestra. Para soak, compara ventanas
estables y reporta pendiente o error de medición. No declares sub-segundo,
Tier-1 ni capacidad productiva sin carga, hardware, red y duración.

## 10. Observabilidad

Añade sólo eventos de baja cardinalidad y schema versionado, por ejemplo:

- `federation_admission_rejected` con reason enumerable;
- `federation_capacity_changed` sólo en transiciones relevantes;
- `federation_handshake_timeout`;
- `federation_session_closed`.

No registres certificados, SPIFFE completos sin necesidad, namespaces no
acotados, direcciones de clientes como labels de métricas ni errores crudos que
puedan contener paths/secrets.

## 11. Puertas de calidad

```bash
bash -n chaos/federation/*.sh
cargo fmt --check
cargo check --locked --all-targets --all-features
cargo clippy --locked --all-targets --all-features -- -D warnings
cargo test --locked --all-targets --all-features
cargo deny check
cargo audit
```

Ejecuta el perfil smoke siempre. Ejecuta hostile sólo dentro de la red aislada
y con timeout global. Si el entorno no permite `NET_ADMIN`, ejecuta la parte
hermética, conserva el harness y reporta exactamente la prueba pendiente.

## 12. Entrega final obligatoria

Presenta hallazgos primero, ordenados por severidad, y después:

- límites existentes, añadidos y todavía imposibles de imponer;
- decisión upstream y evidencia;
- archivos y carpetas creados/modificados;
- comandos y pruebas con resultados;
- tabla de carga y métricas medidas;
- comportamiento de peer válido frente a inválidos/lentos;
- limpieza verificada;
- dependencias/licencias nuevas o confirmación de que no hubo;
- blockers para considerar productivo el relay federado;
- siguiente acción exacta.

No marques "concurrencia acotada" si `FuturesUnordered` u otra colección
alimentada por red sigue sin límite efectivo.

---
