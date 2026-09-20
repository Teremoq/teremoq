# C1 review plan — bounded pending handshakes

- Revisor: `TP-PLATFORM-CHAOS`
- Fecha: 2026-08-27
- Baseline obligatorio: `bf87128affd316463e5dcc7599a45001f222b6de`
- Tree del baseline: `d76319009e815fb8923e21fc8319e17a0aaf8174`
- Alcance futuro: `moq-native-ietf` y sus pruebas/documentación enfocadas
- Estado: **diseño de prueba; C1 no está implementado ni autorizado**
- Declaración de aislamiento: **LOCAL TEST PLAN ONLY / NO SOURCE EDIT / NO REMOTE MUTATION**

Este documento especifica los gates que aplicará `TP-PLATFORM-CHAOS` cuando
`TP-RUST-DIST` entregue C1. No crea branch, commit o cambio de producto, no
autoriza publicación y no utiliza el working tree de I2 como evidencia. C2,
admisión de sesiones del relay, identidad y autorización quedan fuera de este
paquete.

## Hallazgos previos por severidad

### Crítico — el baseline no tiene un límite estructural

En el source exacto, `moq-native-ietf/src/quic.rs:403-409` almacena cada fase en
un `FuturesUnordered` privado. `Server::accept`, líneas 412-431, recibe cada
`quinn::Incoming` desde `self.quic.accept()` y lo inserta con `push()` sin
admisión ni máximo. Ninguna prueba finita de Task 04 transforma esa colección en
una colección acotada. C1 sólo podrá aprobarse si la longitud de trabajo
aceptado queda estructuralmente limitada a N y N+1 nunca se inserta.

### Alto — QUINN tiene otra frontera previa, acotada pero demasiado amplia

El source exacto de `quinn 0.11.9` usa un `VecDeque<proto::Incoming>` interno.
No es ilimitado en conjunto con `quinn-proto`: `ServerConfig` fija por defecto
`max_incoming=65536`, `incoming_buffer_size=10 MiB` por `Incoming` y
`incoming_buffer_size_total=100 MiB`. Esos knobs son públicos en
`quinn::ServerConfig`, pero `moq-native-ietf` no los expone ni los configura.

C1 debe distinguir dos límites per-endpoint: la cola QUINN pre-admisión y las
fases costosas admitidas en `FuturesUnordered`. El constructor bounded debe
aplicar `ServerConfig::max_incoming` antes de crear el endpoint, con un valor
explícito y documentado; la alternativa mínima conservadora es derivarlo del
mismo N no nulo. Los caps de bytes QUINN permanecen explícitamente registrados
si no se cambian. Aprobar C1 no equivale a demostrar que la memoria completa de
QUINN es N objetos ni resistencia a flood; sólo demuestra que ambas colecciones
conocidas tienen caps efectivos y que la fase costosa no supera N.

### Alto — la resolución QUINN del baseline no es 0.11.11

El `Cargo.lock` de `bf87128...` fija `quinn 0.11.9`, `quinn-proto 0.11.13`,
`quinn-udp 0.5.14`, `web-transport-quinn 0.11.8` y `tokio 1.48.0`. Algunos
borradores describen el orden usando QUINN 0.11.11, y el `Cargo.lock` downstream
de Task 04 llegó a resolver 0.11.11, pero eso no es evidencia construible para
la branch C1 que parte del baseline inmutable. La revisión compilará y probará
primero contra el lock del baseline; cualquier actualización del lock reabre
compatibilidad, licencia y alcance.

### Alto — un test downstream no puede fabricar ni pausar `Incoming`

En QUINN 0.11.x, `Incoming::new` no es público. La superficie pública permite
`accept`, `accept_with`, `refuse`, `retry`, `may_retry`,
`remote_address_validated` y `orig_dst_cid`, pero no construir un `Incoming` de
prueba ni ordenar a un cliente de alto nivel que se detenga en un punto exacto
de TLS. `moq_native_ietf::quic::Client::connect` además engloba QUIC/TLS y, para
HTTPS, WebTransport SETTINGS/CONNECT.

C1 debe probarse dentro de `moq-native-ietf`, que ya depende directamente de
QUINN. Los clientes serán endpoints QUINN reales. Una barrera interna disponible
sólo bajo `cfg(test)` detendrá el lado servidor después de recibir un
`Incoming`, sin simular datagramas. No se añadirá QUINN a Teremoq ni otra
dependencia al upstream. Un stall criptográfico en mitad de TLS sigue sin ser
construible de forma determinista mediante el cliente público de alto nivel; se
separa de la prueba estructural de admisión y no se inventa con un sleep.

### Alto — un único timeout debe envolver también WebTransport

`accept_session`, líneas 434-563, llama a `Incoming::accept_with` en la ruta
qlog o a `Incoming::accept` en la ruta normal, espera handshake/connection y
después, para `web_transport_quinn::ALPN`, espera H3 SETTINGS y CONNECT en
`Request::accept`. El idle timeout de 10 segundos no es un deadline absoluto.
C1 debe calcular un solo `tokio::time::Instant` tras admitir el `Incoming` y
usar ese mismo valor hasta que `accept_session` finalice.

### Medio — Retry consume el valor incluso cuando falla

`Incoming::retry(self)` consume `Incoming`. Si resulta ilegal, `RetryError`
devuelve su propiedad mediante `into_incoming()`. La implementación debe
`refuse()` ese valor recuperado; dejar que un error pierda el flujo explícito de
disposición o intentar reutilizar el valor movido será `CHANGES REQUIRED`.
`Retry` sólo procede cuando la política lo habilita y `may_retry()` lo permite.

### Medio — cancelación y drop tienen semánticas diferentes

Cancelar el future externo `Server::accept(&mut self)` no equivale a eliminar
las fases ya guardadas en el `FuturesUnordered`; éstas pertenecen a `Server`.
En cambio, eliminar una fase interna o hacer drop de `Server` sí debe destruir
su guard RAII. Hacer drop de una referencia externa a un controlador compartido
no debe revocar trabajo que todavía posee otro `Arc`. Los tests distinguirán
estos casos para evitar una falsa prueba de cleanup.

### Informativo — Task 04 caracteriza progreso, no C1

Task 04 informa correctamente `handshake_capacity_limit=unenforced` y
`pending_transport_handshake=untestable_with_pinned_public_api`. El hostile
combinado más reciente leído, sin regenerarlo, entregó 1201/1201 Objects al
lector rápido y 480/1201 al lento en una prueba sólo vídeo; no mide N/N+1 de
handshakes. Sus métricas de proceso y cleanup siguen siendo útiles como
regresión posterior, nunca como gate estructural C1.

## Seam exacto y orden obligatorio

La modificación futura debe permanecer en la frontera ya existente:

1. `Endpoint::new` construye el `quinn::ServerConfig` en las líneas 310-321. El
   constructor bounded aplica aquí `max_incoming` antes de crear el endpoint;
   luego crea `Server` en las líneas 350-355.
2. `Server::accept` espera `self.quic.accept()` en líneas 415-416.
3. Sólo después de obtener `quinn::Incoming`, y antes de `accept_session`, se
   intenta capacidad mediante `try_acquire_owned()` o una operación equivalente
   no bloqueante.
4. Con permit, el `Incoming` y el guard se mueven a una única fase de aceptación
   que conserva las rutas existentes:
   `Incoming::accept_with()` para qlog o `Incoming::accept()` para la ruta normal.
5. Sin permit, N+1 se consume en esa misma iteración con `refuse()` o con Retry
   sólo cuando sea legal y esté configurado. Esa rama no hace `await`, no hace
   `spawn` y no hace `push`.
6. El permit termina cuando `accept_session` produce sesión o error, vence el
   deadline o el future es cancelado/dropeado. Se libera antes de entregar la
   sesión establecida a cualquier lógica futura C2.

Esquema normativo, con nombres ilustrativos:

```rust
let Some(incoming) = self.quic.accept().await else {
    return None;
};
let guard = match self.admission.try_admit() {
    Ok(guard) => guard,
    Err(capacity) => {
        self.disposition.consume(incoming, capacity);
        continue;
    }
};
let deadline = self.admission.deadline_from_now()?;
self.accept.push(
    Self::accept_session_until(incoming, qlog, config, deadline, guard).boxed(),
);
```

No se acepta ninguna de estas variantes:

- adquirir un permit antes de que `Endpoint::accept().await` entregue
  `Incoming`;
- `Semaphore::acquire().await`, `acquire_owned().await` o un channel de espera
  después de recibir tráfico remoto;
- crear una task por N+1 para rechazarla después;
- poner el permit sólo alrededor de `conn.await` y liberarlo antes de SETTINGS o
  CONNECT;
- retener el permit C1 durante setup o vida MoQT, que pertenece a C2.

## Contrato de ownership y métricas

### Límite y gauge

El default acotado es **por `Server`/endpoint**: cada constructor acotado crea su
propio `Arc<Semaphore>`. Compartir capacidad entre endpoints exige pasar de
forma explícita el mismo controlador. Clonar accidentalmente configuración no
puede convertir una capacidad global anunciada en N por endpoint.

El cap `quinn::ServerConfig::max_incoming` siempre permanece per-endpoint,
incluso cuando dos Servers comparten el controlador de fases costosas. El
snapshot/documentación debe distinguir `max_buffered_incoming` de
`max_pending_handshakes`; no se suman ni se presentan como un único gauge.

El guard debe ser no clonable y poseer un `OwnedSemaphorePermit`. Para evitar
underflow de un contador duplicado, la instantánea `pending_handshakes` debe
derivarse preferentemente de `limit - available_permits()` en un semáforo cuyo
número de permits nunca se amplía ni se cierra como mecanismo de contabilidad.
Si se conserva un gauge separado, su guard tiene un único owner y una sola ruta
de `Drop`; cada race test debe demostrar que nunca supera N ni baja de cero.

### Deadline

El constructor acotado valida duración no nula y que `Instant::checked_add`
puede representarla antes de abrir servicio. Por cada `Incoming` admitido se
calcula una sola vez un deadline absoluto monotónico. `timeout_at(deadline,
accept_session(...))` envuelve:

- `accept` o `accept_with`;
- QUIC/TLS y ALPN;
- `conn.await`;
- H3 SETTINGS y WebTransport CONNECT/response, cuando corresponda.

No se reinicia el reloj al avanzar de fase ni al recibir tráfico. Un timeout de
Tokio no puede interrumpir código síncrono que no cede; el `File::create` qlog
existente es una limitación real. C1 no debe añadir más I/O síncrono y el gate
de qlog comprobará orden/cleanup sin prometer preempción de filesystem.

### Snapshot y eventos

Sin añadir backend de métricas ni dependencia, una instantánea acotada basada
en atomics debe exponer como mínimo:

- `limit` y `pending_handshakes`;
- `max_buffered_incoming_configured` y los caps de bytes QUINN realmente
  aplicados, aunque QUINN no exponga un gauge instantáneo de su cola;
- `admitted_total`;
- `rejected_total` separado en `refused_capacity` y `retry_capacity`;
- terminales `completed`, `transport_error`, `timeout` y `cancelled`;
- `inflight_futures`, sólo si se puede obtener sin lock async.

Los eventos usan `schema_version=1` y enums fijos. No se admiten dirección IP,
CID, SNI, certificado, identidad, namespace ni texto de error como label. Los
detalles de diagnóstico sensibles permanecen fuera de la superficie métrica.
Una fase admitida produce exactamente un terminal; una N+1 rechazada no produce
un terminal de fase porque nunca la crea.

## Mecanismo determinista de pruebas

Las pruebas enfocadas viven en `moq-native-ietf` y usan la dependencia QUINN ya
existente. Un hook privado bajo `cfg(test)` ofrece eventos one-shot de etapa y
una liberación explícita. Las etapas mínimas son:

```text
incoming_received
permit_acquired
accept_started
transport_established
webtransport_connect_waiting
phase_completed
```

Cada espera de test está protegida por un watchdog amplio sólo para evitar que
CI quede colgado; el resultado se decide por orden de eventos y estado, no por
un sleep o un umbral de milisegundos. El hook no entra en la API pública, no
retiene payloads y no genera una task por conexión rechazada.

Para N/N+1, N clientes QUINN reales inician conexiones y el servidor se detiene
en `permit_acquired`, antes de `Incoming::accept`. El test espera N
confirmaciones, inicia N+1, observa su disposición antes de liberar la barrera y
comprueba que `accept_started` sigue en cero. Esto ejercita el camino real
`Endpoint::accept -> Incoming` y prueba exactamente el orden de admisión. No
afirma haber consumido CPU TLS ni haber detenido TLS en mitad de un vuelo.

Para WebTransport timeout, un cliente QUINN real negocia el ALPN WebTransport
pero no inicia la sesión H3/CONNECT. Para raw QUIC se usa el ALPN MoQT existente.
Cuando una condición TLS concreta no pueda construirse sin una nueva fixture o
API, se usa una fixture estática, pública y marcada exclusivamente para tests o
una configuración rustls construida con dependencias existentes. Añadir
`rcgen`, otro stack o un generador en runtime no es aceptable. La prueba debe
fallar de forma visible si la clasificación de error TLS no es estable; no se
renombra un abort genérico como `tls_error`.

## Matriz C1 enfocada

En todos los casos N es pequeño y fijo para CI, por ejemplo N=2; la prueba de
carga acotada usa un M finito documentado y no infiere capacidad productiva.

| ID | Precondición | Mecanismo determinista | Evento observable | Estado/gauge final | Bug que impediría |
| --- | --- | --- | --- | --- | --- |
| C1-01 orden | Server acotado N=1, barrera antes de `accept` | Un cliente QUINN real genera `Incoming`; el hook bloquea al adquirir | `incoming_received` precede `permit_acquired`, que precede `accept_started` | Tras cancelar: pending=0, inflight=0 | Adquirir antes de recibir tráfico o aceptar antes de capacidad |
| C1-02 N/N+1 refuse | N=2, política `Refuse` | Dos clientes llegan a `permit_acquired`; tercero empieza sin liberar barrera | `refused_capacity` del tercero ocurre antes de cualquier release; no `accept_started` para N+1 | Durante barrera pending=2/inflight=2; final 0/0 | Cola de waiters, push ilimitado o rechazo tardío |
| C1-03 capacidad recuperada | Estado de C1-02 | Se cancela exactamente una fase y se espera su terminal antes de crear cliente nuevo | `cancelled` una vez; el nuevo cliente alcanza `permit_acquired` | Intermedio vuelve a 2; final 0 | Permit perdido o liberación tardía |
| C1-04 éxito raw QUIC | N=1 y ALPN `moq_transport::setup::ALPN` | Cliente real completa la ruta raw; barreras por etapa | `completed` una vez y transporte `RawQuic` | pending=0/inflight=0 | Permit retenido hasta MoQT/C2 o regresión ALPN |
| C1-05 éxito WebTransport | N=1 y `web_transport_quinn::ALPN` | Cliente real completa H3 SETTINGS y CONNECT | `webtransport_connect_waiting` seguido de `completed` | pending=0/inflight=0 | Liberar permit después de TLS pero antes de CONNECT |
| C1-06 error TLS/crypto | Config rustls de test fuerza fallo verificable | Cliente QUINN real presenta la condición; sin UDP manual | Terminal tipado soportado por QUINN/rustls, una vez; no sesión | pending=0/inflight=0 | Leak en `?`, clasificación inventada o double release |
| C1-07 timeout pre-transport | N=1, deadline corto de test y etapa interna controlada | Hook retiene la fase tras `accept_started`; reloj monotónico y watchdog | `timeout` exactamente al vencer el deadline lógico | pending=0/inflight=0; siguiente cliente progresa | Idle timeout usado como deadline o reloj reiniciado |
| C1-08 timeout CONNECT | QUIC/TLS WebTransport establecidos | Cliente real negocia ALPN y retiene H3/CONNECT; evento confirma la etapa | `timeout` sin `completed` pese a conexión activa | pending=0/inflight=0 | Deadline que sólo cubre TLS |
| C1-09 cancelar cada etapa | Una fase admitida por subcaso | Drop del future interno en cada barrera: antes de accept, durante transporte y esperando CONNECT | Un único `cancelled` por subcaso | pending=0/inflight=0 tras cada drop | Guard fuera del future o cleanup parcial |
| C1-10 cancelar `Server::accept` | Hay una fase almacenada y bloqueada | Se cancela sólo la llamada externa y luego se vuelve a llamar | No terminal espurio; la fase sigue registrada y vuelve a progresar | Pending permanece 1 hasta release; final 0 | Confundir cancelación del poller con cancelación del trabajo owned |
| C1-11 drop de Server | N fases admitidas | Drop del `Server` sin liberar barreras; se conserva sólo observer de atomics | N terminales cancelados o una contabilidad de drop equivalente, nunca éxito | pending=0/inflight=0 | `FuturesUnordered`/guards huérfanos |
| C1-12 drop de controlador | Dos Servers poseen controlador compartido | Se elimina el handle externo mientras un Server/future conserva `Arc`; después se elimina el último owner | Primer drop no revoca; último drop ocurre sólo tras liberar guards | Gauge observable final 0 | Lifetime falso, cierre prematuro o Arc cycle |
| C1-13 Retry legal | Política Retry, `may_retry=true`, N saturado | N+1 cliente QUINN real recibe Retry; después se libera un permit antes de su nuevo `Incoming` validado | `retry_capacity`, luego segundo `Incoming` y progreso; no `refused_capacity` inicial | pending nunca >N; final 0 | Retry no configurado, waiter o pérdida del cliente reintentado |
| C1-14 Retry ilegal | Política Retry, `may_retry=false` o `retry()` devuelve error | Se usa el `Incoming` validado real; si hay `RetryError`, se recupera con `into_incoming` | `refused_capacity`/`retry_not_applicable`, nunca `retry_capacity` | pending=N durante saturación; final 0 | Drop implícito ambiguo, loop de Retry o valor sin consumir |
| C1-15 carrera deadline/éxito | Fase lista en el límite absoluto | Barrera y reloj controlado hacen elegibles éxito y timeout en el mismo turno | Exactamente uno de dos terminales permitidos | pending=0; suma terminales=1 | Double decrement/double terminal |
| C1-16 carrera cancelación/error | Error de transporte preparado y cancelación simultánea | Barrera libera ambos caminos en scheduling repetible | Exactamente `transport_error` o `cancelled` | pending=0 en cada iteración | Underflow o contador doble |
| C1-17 ráfaga sin waiters | N=2, M=32 clientes reales y barrera en N | Se espera disposición de los M-N antes de soltar N | M-N rechazos; `inflight_futures` permanece N; ningún evento de waiter | Pico pending=N; final 0 | Colección/task/cola proporcional a M |
| C1-18 qlog/accept_with | qlog habilitado con directorio temporal de test | Cliente real entra por la rama `accept_with`; cleanup RAII del temporal | Mismo orden de C1-01 y un terminal | pending=0/inflight=0 | Bypass de admisión en configuración por conexión |
| C1-19 métricas/redacción | Se ejercitan todos los resultados anteriores | Captura de snapshot/eventos; allowlist de campos y razones | Sólo enums previstos y schema 1 | Gauge 0; contadores cuadran con casos | Cardinalidad por peer, secreto o underflow |
| C1-20 cola QUINN pre-admisión | Constructor bounded con `max_buffered_incoming=2`, todavía sin polling de `Server::accept` | Tres clientes QUINN reales inician; una barrera del socket de test confirma recepción de sus Initials y después se habilita polling | Como máximo dos `incoming_received`; el tercero obtiene rechazo QUINN sin `permit_acquired` | Cola drenada por disposición; pending=0/inflight=0 | Dejar el default 65536, configurar el clone incorrecto o confundir cola QUINN con fases C1 |

### Matriz multi-endpoint y aislamiento de C2

| ID | Precondición | Mecanismo determinista | Evento observable | Estado/gauge final | Bug que impediría |
| --- | --- | --- | --- | --- | --- |
| C1-ME-01 default local | Dos endpoints, cada uno con controlador propio N=1 | Un cliente real ocupa cada barrera; N+1 por endpoint | Cada endpoint rechaza sólo su propio segundo cliente | Cada gauge llega a 1 y vuelve a 0 | Semáforo global accidental o snapshot cruzado |
| C1-ME-02 shared explícito | Dos endpoints reciben el mismo controlador N=1 | Endpoint A ocupa el permit; cliente de B llega antes del release | B emite rechazo inmediato con gauge compartido=1 | Gauge compartido final 0 | Clonar un nuevo semáforo al configurar B |
| C1-ME-03 éxito no ocupa C2 | C1 N=1 y una sesión nativa ya establecida | Tras `phase_completed`, mantener la sesión abierta y conectar otro peer | Segundo peer adquiere C1 aunque la primera sesión siga viva | C1 pending vuelve a 0 con ambas sesiones establecidas | Retener permit de handshake durante vida de sesión |
| C1-ME-04 sin estado relay | Instrumentación de C1 sólo en `moq-native-ietf` | Ejecutar N/N+1 sin construir `Relay`, Producer, Consumer o namespace | Sólo eventos C1 | Todos los gauges C1 a 0 | Acoplamiento indebido a C2/I2 |

### Regresiones de wire y Objects

| ID | Precondición | Mecanismo determinista | Evento observable | Estado/gauge final | Bug que impediría |
| --- | --- | --- | --- | --- | --- |
| C1-WR-01 ambos ALPN | Server legacy y bounded con la misma TLS config | Repetir cliente `https` y `moqt` existente contra ambos | `web_transport_quinn::ALPN` y `moq_transport::setup::ALPN` negociados sin cambio | C1 gauge 0 por conexión | Cambio de ALPN o una ruta sin admisión |
| C1-WR-02 draft-16 setup | Transporte bounded establecido | Ejecutar CLIENT_SETUP/SERVER_SETUP existente en ambos transportes | Setup draft-16 aceptado con fixtures existentes | C1 gauge ya es 0 antes de setup | Extender C1 al wire MoQT o alterar draft |
| C1-WR-03 Objects | Publisher/subscriber existentes sobre bounded server | Publicar varios Objects en un Subgroup y drenarlos en orden | Todos los Objects y cierres existentes coinciden | Gauge C1 0; sin payload retenido | Regresión de Session o retención del permit |
| C1-WR-04 legacy compatible | Constructor y `Server::accept` actuales | Compilar ejemplo/call site sin modificarlo y ejecutar smoke existente | Mismo resultado legacy, con estado unbounded explícito | No aplica gauge bounded | Breaking API o fallback silencioso en API llamada bounded |

## Limitaciones QUINN 0.11.x y alternativa conservadora

1. `Incoming` no tiene constructor público. Los tests que necesitan controlar
   su lifetime deben originarlo con endpoints QUINN reales y sincronizar en el
   seam privado después de `Endpoint::accept`.
2. `Incoming` hace rechazo implícito al dropearse, pero C1 exige una disposición
   explícita y contable en la rama de saturación. El drop implícito sólo es red
   de seguridad, no la política.
3. `retry()` puede fallar y devolver el `Incoming` dentro de `RetryError`; la
   alternativa segura es `into_incoming().refuse()`.
4. El cliente alto nivel no ofrece “pause after ClientHello”. La barrera
   pre-accept prueba el límite y el orden con un `Incoming` real. Un hook privado
   de etapa prueba ownership/deadline. Ninguno se presenta como stall TLS real.
5. Un stall WebTransport sí es construible: establecer QUIC con ALPN h3 y no
   enviar SETTINGS/CONNECT, usando componentes ya fijados.
6. `Config::with_socket_wrapper` podría albergar control de paquetes dentro del
   crate upstream, pero implementar un filtro QUIC robusto sobre
   `AsyncUdpSocket` es más frágil que el hook de etapa y no debe ser requisito de
   C1 sin revisión separada. Nunca se enviará UDP arbitrario etiquetándolo como
   handshake.
7. Un watchdog de tiempo de pared sólo detecta hang del test. No demuestra
   rechazo inmediato. La prueba normativa de inmediatez es que el rechazo N+1
   ocurre antes de liberar N y que no aumenta `inflight_futures`.
8. La cola `RecvState::incoming` de QUINN es privada. Su cap sí es configurable
   mediante `ServerConfig::max_incoming`, pero no tiene gauge público. C1-20
   combina revisión del valor aplicado con comportamiento black-box; cualquier
   métrica instantánea de esa cola se marca `unobservable_with_quinn_0_11_9`.

Si los mantenedores rechazan cualquier hook interno de test, el mínimo aceptable
es conservar C1-01/C1-02 mediante una prueba unitaria del helper privado que
recibe un `Incoming` real y las regresiones black-box. La incapacidad de detener
TLS a mitad de vuelo se reportará como `unobservable_with_public_test_api`; no
se eliminará el gate estructural ni se sustituirá por sleeps.

## Comandos exactos de validación futura

Estos comandos son para la entrega C1 futura, no se ejecutaron al redactar este
plan. Usan el toolchain y digest fijados, sin instalar paquetes, sin publicar
puertos y sin red exterior. La imagen debe contener ya el índice y sources del
lock; si no, el gate falla cerrado y se prepara otra imagen fijada mediante una
decisión separada.

```bash
C1_WORKTREE=/home/jimbomilk/moq-rs-teremoq-work
C1_IMAGE='teremoq-step7-lab:rust-1.93-full@sha256:ba076cf0a26aa41efdd2f0f80687ef97009d1526680751456c19cc944dff1d0b'

git -C "${C1_WORKTREE}" rev-parse HEAD
git -C "${C1_WORKTREE}" diff --check
git -C "${C1_WORKTREE}" diff -- Cargo.toml Cargo.lock

docker run --rm --network none --pids-limit 512 --memory 2g --cpus 4 \
  --security-opt no-new-privileges:true --tmpfs /tmp:rw,nosuid,nodev \
  --tmpfs /workspace/target:rw,nosuid,nodev \
  --mount type=bind,src="${C1_WORKTREE}",dst=/workspace \
  --workdir /workspace --env RUSTUP_TOOLCHAIN=1.93.0-x86_64-unknown-linux-gnu \
  "${C1_IMAGE}" rustc -Vv

docker run --rm --network none --pids-limit 512 --memory 2g --cpus 4 \
  --security-opt no-new-privileges:true --tmpfs /tmp:rw,nosuid,nodev \
  --tmpfs /workspace/target:rw,nosuid,nodev \
  --mount type=bind,src="${C1_WORKTREE}",dst=/workspace \
  --workdir /workspace --env RUSTUP_TOOLCHAIN=1.93.0-x86_64-unknown-linux-gnu \
  "${C1_IMAGE}" cargo fmt --all --check

docker run --rm --network none --pids-limit 512 --memory 2g --cpus 4 \
  --security-opt no-new-privileges:true --tmpfs /tmp:rw,nosuid,nodev \
  --tmpfs /workspace/target:rw,nosuid,nodev \
  --mount type=bind,src="${C1_WORKTREE}",dst=/workspace \
  --workdir /workspace --env RUSTUP_TOOLCHAIN=1.93.0-x86_64-unknown-linux-gnu \
  "${C1_IMAGE}" cargo test --locked -p moq-native-ietf c1_ -- --nocapture

docker run --rm --network none --pids-limit 512 --memory 2g --cpus 4 \
  --security-opt no-new-privileges:true --tmpfs /tmp:rw,nosuid,nodev \
  --tmpfs /workspace/target:rw,nosuid,nodev \
  --mount type=bind,src="${C1_WORKTREE}",dst=/workspace \
  --workdir /workspace --env RUSTUP_TOOLCHAIN=1.93.0-x86_64-unknown-linux-gnu \
  "${C1_IMAGE}" cargo check --locked --workspace --all-targets --all-features

docker run --rm --network none --pids-limit 512 --memory 2g --cpus 4 \
  --security-opt no-new-privileges:true --tmpfs /tmp:rw,nosuid,nodev \
  --tmpfs /workspace/target:rw,nosuid,nodev \
  --mount type=bind,src="${C1_WORKTREE}",dst=/workspace \
  --workdir /workspace --env RUSTUP_TOOLCHAIN=1.93.0-x86_64-unknown-linux-gnu \
  "${C1_IMAGE}" cargo clippy --locked --workspace --all-targets --all-features -- -D warnings

docker run --rm --network none --pids-limit 512 --memory 2g --cpus 4 \
  --security-opt no-new-privileges:true --tmpfs /tmp:rw,nosuid,nodev \
  --tmpfs /workspace/target:rw,nosuid,nodev \
  --mount type=bind,src="${C1_WORKTREE}",dst=/workspace \
  --workdir /workspace --env RUSTUP_TOOLCHAIN=1.93.0-x86_64-unknown-linux-gnu \
  "${C1_IMAGE}" cargo test --locked --workspace --all-targets --all-features
```

Después se registra `git diff --stat`, `git diff -- Cargo.toml Cargo.lock` y el
SHA completo probado. Un filtro `c1_` que ejecute cero tests falla el gate. La
ausencia de diferencias en manifests/lock confirma “sin dependencia/feature
nueva”; no se infiere por el mero éxito de Cargo.

## Gate de revisión

### `APPROVE`

`TP-PLATFORM-CHAOS` emitirá `APPROVE` únicamente si se cumplen simultáneamente:

1. la entrega parte del commit y lock exactos y sólo toca `moq-native-ietf`,
   pruebas y documentación enfocada;
2. `Incoming` se recibe antes del `try_acquire` y sólo se acepta después;
3. N+1 se dispone sin `await`, waiter, task ni inserción en colección;
4. un único deadline monotónico cubre QUIC/TLS y WebTransport CONNECT;
5. el guard RAII libera exactamente una vez en éxito, error, timeout,
   cancelación, drop y races;
6. C1-01 a C1-20, C1-ME-01 a C1-ME-04 y C1-WR-01 a C1-WR-04 pasan o cualquier
   caso no construible queda demostrado por la API exacta y sustituido por la
   alternativa conservadora aquí definida, sin rebajar el contrato;
7. default per-endpoint y controlador compartido explícito quedan probados;
8. gauges llegan a cero, no hay underflow y los eventos son de baja
   cardinalidad sin datos de peer;
9. WebTransport, raw QUIC, ambos ALPN, draft-16 y Objects no regresionan;
10. no hay dependencia, feature, `unsafe`, wire change ni lógica C2; y
11. la documentación conserva el estado no productivo hasta integrar y validar
    C2, identidad/autorización y Chaos posterior.
12. el cap QUINN pre-admisión aplicado y sus caps de bytes quedan registrados
    separadamente del límite N de fases costosas.

### `CHANGES REQUIRED`

Basta una de estas condiciones:

- cualquier `acquire().await`, channel o task de espera por capacidad;
- N+1 entra en el `FuturesUnordered` o inicia `accept`/`accept_with`;
- un timeout relativo nuevo por subfase o un idle timeout presentado como
  deadline absoluto;
- Retry sin `may_retry`/política explícita o sin consumir el valor devuelto al
  fallar;
- permit que sobrevive a `accept_session` y ocupa capacidad durante MoQT/C2;
- prueba basada sólo en sleeps, UDP arbitrario o métricas de proceso;
- `ServerConfig::max_incoming` dejado implícito en 65536 en una API denominada
  bounded, o presentado como gauge observable cuando QUINN no lo expone;
- gauge negativo, mayor que N, terminal duplicado o cleanup distinto de cero;
- label con dirección, CID, SNI, certificado, identidad o namespace;
- cambio de dependencia/lock, ALPN, draft, frame, API breaking o source fuera
  del paquete autorizado; o
- claim de C1 implementado, resistencia DoS, capacidad productiva o relay listo
  para producción sin la integración posterior.

## Evidencia local leída

- `.cursorrules` completa, incluida autonomía y ownership
  `TP-PLATFORM-CHAOS`;
- `ADR-0006-FEDERATION-CONCURRENCY.md`;
- `upstream/moq-rs-concurrency-limits-proposal.md`;
- `upstream/mirror/PATCH-SERIES.md` y `SYNC-RUNBOOK.md`;
- `upstream/submissions/concurrency-admission-issue-draft.md` y
  `compatibility-and-test-matrix.md`;
- blobs del commit `bf87128...` leídos con `git show`, especialmente
  `moq-native-ietf/src/quic.rs`, `tls.rs`, `Cargo.toml` y `Cargo.lock`;
- source oficial exacto de `quinn 0.11.9` y `quinn-proto 0.11.13`, contrastado
  con los checksums del lock, incluidas `Incoming`, `Endpoint::accept`, la cola
  interna y `ServerConfig::{max_incoming,incoming_buffer_size,
  incoming_buffer_size_total}`;
- `tests/federation_concurrency.rs`, `tests/moq_relay_interop.rs`, harness
  `chaos/federation`, perfiles, regresión del sampler y reportes hostile ya
  existentes, sin ejecutar ni regenerar pruebas.

No se leyó el working tree de `moq-relay-ietf` como evidencia C1 y no se realizó
ninguna comunicación o mutación remota.
