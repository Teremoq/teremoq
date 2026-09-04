# Supervisor Web de Teremoq

Supervisor comparativo aislado para observar la entrada SRT y seleccionar los
Tracks 0/1 (vídeo HQ/LQ) publicados por `gateway-rs`. La entrada procede de un tap MediaMTX
prescindible; la salida conecta con el relay mediante WebTransport, recibe el
subconjunto de MoQT draft-16 documentado en `ADR-0003`, desempaqueta CMAF con
MP4Box.js, decodifica H.264 mediante WebCodecs y presenta cada `VideoFrame` en
un `canvas`.

No forma parte del data plane del Gateway y no puede introducir contrapresión
en ingesta, demux, scheduler ni publicación.

## Centro de Operaciones read-only

`/operations` añade una superficie separada y tolerante a fallos para explicar
el estado operativo sin alterar el supervisor audiovisual de `/`. Consume el
snapshot versionado real del Gateway mediante la frontera `/gateway` existente
y distingue en cada dato `gateway-real`, `control-plane-simulation` y
`cloud-future`, junto con estado de medida, timestamp, edad y frescura.

La configuración por defecto no carga datos del plano de control y muestra
`pendiente de integración`. Para una demostración exclusivamente local puede
proyectarse el reporte versionado aceptado de Task 09:

```bash
TEREMOQ_OPERATIONS_LOCAL_SIMULATION=task-09 npm run dev
```

La Route Handler asociada sólo exporta `GET`, lee una ruta fija del reporte en
el servidor, valida límites y contrato y devuelve una proyección redactada. El
navegador nunca recibe digests, IDs de nodo, contexto de autenticación, paths o
errores internos. No existe selector de archivo arbitrario.

Los controles de evento, capacidad, drain, sustitución, redundancia,
autoescalado y emergencia son elementos nativos `disabled`. No existe handler
mutable ni endpoint `POST`, `PUT`, `PATCH` o `DELETE`. Una futura superficie
autorizada emitirá órdenes validadas al plano de control y nunca administrará
proveedores directamente.

## Requisitos

- Chrome o Edge con WebTransport y WebCodecs.
- `gateway-rs` y el relay local en ejecución.
- Node.js 22 y npm, o Docker.
- Acceso desde `localhost` o HTTPS: WebTransport y WebCodecs requieren un
  contexto seguro.

## Arranque local

Con Node.js:

```bash
npm ci
TEREMOQ_GATEWAY_HTTP_ORIGIN=http://127.0.0.1:19080 npm run dev
```

Con Docker y el Gateway publicado en el host:

```bash
docker run --rm -it \
  --add-host host.docker.internal:host-gateway \
  -p 19090:3000 \
  -e TEREMOQ_GATEWAY_HTTP_ORIGIN=http://host.docker.internal:19080 \
  -e TEREMOQ_INPUT_PREVIEW_ORIGIN=http://host.docker.internal:8889 \
  -v "$PWD:/app" -w /app node:22-bookworm-slim \
  npm run dev -- --hostname 0.0.0.0
```

Abre `http://127.0.0.1:19090/`. La vista de entrada se conecta al observador
configurado por el Gateway; selecciona **Track 0 · HQ** o **Track 1 · LQ** y
pulsa el botón de conexión para iniciar la salida.
La aplicación obtiene la URL del relay, el namespace y el fingerprint SHA-256
del certificado; no hay que aceptar manualmente un certificado autofirmado.
El servidor Next.js presenta MediaMTX bajo `/input/` en el mismo origen para
que el supervisor pueda garantizar reproducción automática muda y mantener
los endpoints WHEP relativos dentro del proxy local.

## Paquete cliente LAN de laboratorio

El modo normal sigue siendo `LAB LOOPBACK`: `npm run dev` y `npm start`
conservan las APIs `/gateway`, el observador `/input/` y `/operations` read-only.
El cliente LAN es un opt-in separado para una prueba real desde Chrome/Edge en
otro ordenador. No es una configuración de producción ni expone el dashboard
del Gateway.

En PowerShell del ordenador cliente, prepara el artefacto y arráncalo así:

```powershell
npm ci
npm run build:lan
npm run package:lan -- --output C:\teremoq-lan-lab --source-commit <40 hex minúsculas>
Set-Location C:\teremoq-lan-lab
$env:TEREMOQ_LAN_LAB_CONFIG='{"schema_version":1,"relay_url":"https://192.168.10.20:14433/watch","fingerprint_sha256":"<64 hex minúsculas>","prefix_length":24,"namespace":"teremoq/live","run_id":"lan-manual-01","source_commit":"<40 hex minúsculas>"}'
node start.mjs
```

Para arrancar directamente desde el checkout tras `npm run build:lan`, también
se puede definir la misma variable y ejecutar:

```powershell
npm run start:lan
```

`build:lan` es el único build que activa la ruta dinámica LAN y genera el output
standalone mínimo de Next.js. El `npm run build` normal no llama a `connection()`
ni altera `/`: conserva el supervisor `LAB LOOPBACK`. El launcher del artefacto
activa `TEREMOQ_LAN_LAB=1` dentro del proceso hijo y fija el servidor
exclusivamente a `127.0.0.1`; abre `http://127.0.0.1:3000/` en ese mismo
ordenador. El proxy rechaza cualquier `Host` no local, método mutable y acceso a
`/gateway`, `/input` u `/operations`, incluso si alguien cambia el bind por
error. La configuración se hereda localmente al arrancar, se valida de nuevo en
servidor y cliente y no dispone de endpoint HTTP propio.

El JSON admite exactamente siete campos, sin extensiones. La URL debe usar
`https`, una IPv4 RFC1918 literal y canónica, puerto frontal `14433` y path
exacto `/watch`, sin credenciales, query ni fragment. `prefix_length` es un
entero entre 8 y 30; la dirección se rechaza si es la red o broadcast calculada
para ese prefijo o si la subred sale del bloque RFC1918. `namespace` refleja el
namespace MoQT configurado realmente en el Gateway, usa segmentos ASCII de
letras, dígitos, `-`, `_` o `.`, y no puede superar 256 bytes. El fingerprint es
obligatorio y corresponde al SHA-256 DER esperado; el player continúa usando
`serverCertificateHashes` y no incluye opción para desactivar TLS o trust.

`build:lan` y `package:lan` comprueban el HEAD resoluble, el árbol
`supervisor-web` y un checkout completamente limpio. El build deja un sello
cerrado dentro de `.next`; el empaquetado lo cruza con HEAD, lock, `package.json`,
Node y npm y lo incorpora como `BUILD-PROVENANCE.json`. Copia el standalone
trazado por Next.js —incluidas sólo sus dependencias runtime seleccionadas—, los
estáticos y el launcher; no copia el checkout ni el `node_modules` completo.
Exige un directorio nuevo, limita el resultado a 128 MiB y genera
`MANIFEST.sha256.json` ordenado para verificar contenido y tamaño.

### Distribución desde Git sin versionar el binario

El checkout sólo versiona el contrato y el launcher pequeño de
[`lan-player/`](lan-player/). El player generado de unos 65 MiB nunca se añade a
Git: `Build-LanPlayerFromGit.ps1` valida URL, ref, HEAD, limpieza, lock y
Node/npm; crea dos worktrees efímeros; ejecuta dos veces `npm ci`, `build:lan` y
`package:lan`; exige igualdad byte a byte y promueve el resultado únicamente a
un `StateRoot` exterior. Toda la cadena de paths se fija y revalida sin
junctions/reparse; npm usa perfiles, userconfig y globalconfig aislados. Los
comandos de clone, actualización, construcción y
refresco explícito de dependencias están documentados en
[`LAN-GIT-DISTRIBUTION.md`](LAN-GIT-DISTRIBUTION.md).

### Launcher cerrado para Platform y carga progresiva

El paquete contiene `lan-launcher.tsv`, `teremoq-lan-platform.ps1` y un
validador cerrado de evidencia. `package:lan` exige `--source-commit` y enlaza
ese commit tanto al TSV de nueve claves como al manifest, que también conserva
la versión de `package.json`. Un SHA ausente, no canónico o distinto del
`VERSION.tsv` exterior se rechaza.

Platform coloca junto al directorio del player `VERSION.tsv` y
`LAN-CONFIG.json`, ambos públicos, regulares y sin symlinks. `VERSION.tsv`
contiene exactamente `schema_version`, `package_version`, `run_id`,
`source_commit`, `server_ipv4`, `moq_url`, `player_manifest_sha256`,
`launcher_contract_sha256`, `lan_config_sha256`, `player_evidence` y
`load_launcher_status`. Al arrancar, los dos últimos estados son
`not_measured` y `ready`. No existe URL de publicación o descarga remota.

`LAN-CONFIG.json` mide como máximo 512 bytes y contiene únicamente
`schema_version`, `relay_url`, `fingerprint_sha256`, `prefix_length`,
`namespace`, `run_id` y `source_commit`. El launcher valida su hash, la URL RFC1918 exacta
`https://<IPv4>:14433/watch`, el pin del certificado y el namespace; después
serializa el objeto canónicamente sólo para el hijo Node. Rechaza una variable
heredada distinta. Antes de arrancar exige que TCP `127.0.0.1:3000` esté libre,
verifica Node y espera readiness local durante un máximo de 15 segundos. Stop
cruza PID, ejecutable, línea de comando y hora de inicio para impedir PID reuse.

Comandos exactos de Platform para el player real y las tres cargas:

```powershell
& .\teremoq-lan-platform.ps1 -Action start -RunId lan-1 -Level 1 -VersionPath ..\VERSION.tsv -FingerprintPath ..\fingerprint.sha256 -EvidenceDirectory C:\teremoq-evidence\lan-1
& .\teremoq-lan-platform.ps1 -Action start -RunId lan-5 -Level 5 -VersionPath ..\VERSION.tsv -FingerprintPath ..\fingerprint.sha256 -EvidenceDirectory C:\teremoq-evidence\lan-5
& .\teremoq-lan-platform.ps1 -Action start -RunId lan-10 -Level 10 -VersionPath ..\VERSION.tsv -FingerprintPath ..\fingerprint.sha256 -EvidenceDirectory C:\teremoq-evidence\lan-10
& .\teremoq-lan-platform.ps1 -Action start -RunId lan-25 -Level 25 -VersionPath ..\VERSION.tsv -FingerprintPath ..\fingerprint.sha256 -EvidenceDirectory C:\teremoq-evidence\lan-25
```

El nivel 1 sirve `/`; 5, 10 y 25 sirven `/lan-load` y arrancan exactamente esa
cardinalidad al visitar la ruta local. Son sesiones MoQT desde una única IP
permitida por el banco y TLS fingerprint-pinned; el navegador no presenta
identidad cliente mTLS. Consumen Track 1 LQ sin canvas ni WebCodecs. Cada sesión
tiene seis reintentos como máximo durante 30 segundos, ocho segundos de límite
para handshake/suscripción y cleanup cancelable.

Tras tráfico real, se pulsa **Detener y limpiar** y luego **Exportar JSON
local**. La descarga se mueve, sin renombrarla, al `EvidenceDirectory` y se
ejecuta `-Action collect`. Es una
`local-browser-observation-user-exported`: el launcher valida esquema,
cardinalidad, duración mínima de 600 segundos, identidad pública, timestamps UTC,
relaciones y SHA-256, pero devuelve
`not_attested_user_export`; el hash detecta cambios, no demuestra autenticidad.

Para el nivel 1, antes del corte manual se pulsa **Armar observación**. La
ventana dura como máximo 180 segundos y sólo mide desde la primera pérdida de
sesión posterior al armado hasta el primer Object nuevo recuperado. Rearmar
reemplaza la ventana anterior; cancelar, expirar o desmontar no produce una
medición. Un reconnect no armado nunca se atribuye a Wi-Fi. El contrato JSON
cerrado, sus límites y fixtures para Platform están en
[`LAN-EVIDENCE-CONTRACT.md`](LAN-EVIDENCE-CONTRACT.md).

No se infieren espectadores autorizados, subscribers de red,
ingest-to-publish ni pérdida/jitter QUIC. La recuperación Wi-Fi sólo existe con
el armado explícito anterior; fuera de ese flujo permanece no medida/no
disponible. G2G sólo es `measured` si el player decodificó
el timecode visual; con cero muestras queda `null/not_available`.

El paquete LAN no consulta snapshots, playback, operaciones ni el endpoint de
certificado del Gateway. Por ello la entrada SRT, salud global de Tracks,
colas y métricas de ingesta aparecen como **no disponibles/no medidas**, nunca
como cero. La telemetría recibida dentro de la sesión MoQT y las métricas
locales de decode/canvas sí se muestran cuando existen.

Una interrupción breve de Wi-Fi conserva el backoff existente de seis intentos
y 30 segundos. Cuando se agota, el operador puede pulsar de nuevo **Conectar**
para crear una generación limpia; no hay reintento infinito. Exponer el relay
LAN frontal en UDP/14433, encaminarlo hacia el relay backend ya existente en
`127.0.0.1:4433` y preparar el certificado/fingerprint pertenecen al banco E2E;
este paquete no abre puertos ni configura ese forwarding.

## Flujo implementado

```text
Fuente ──SRT──┬──→ gateway-rs → relay → WebTransport/MoQT
              │                         │
              │                         ▼
              │              CMAF → MP4Box.js → WebCodecs → canvas
              │
              └──→ MediaMTX → WebRTC → vista de entrada
```

El receptor limita mensajes de control, Objects, streams activos, Objects por
stream y muestras por fragmento. Consume cada Subgroup incrementalmente y
restaura de forma acotada el orden Group/Object ante terminaciones QUIC fuera
de orden. Si detecta un hueco o presión en la cola del
decoder, descarta vídeo delta y espera el siguiente keyframe; el contenido
antiguo nunca se acumula.

Cada conexión pertenece a una única generación. Al cambiar HQ/LQ, reconectar
o desmontar React se abortan la configuración HTTP, el handshake, control,
aceptación de streams y todos los readers de Subgroup; después se cierran de
forma idempotente sesión, streams, MP4Box, decoder, compositor y `VideoFrame`
pendientes. Los callbacks de generaciones anteriores sólo pueden cerrar su
recurso y nunca actualizar estado o presentar un frame.

La reconexión usa un único presupuesto de seis intentos y 30 segundos, backoff
exponencial entre 250 ms y 2 s y jitter determinista. Se cancela de inmediato
al cerrar o cambiar de Track y sólo se reinicia después de presentar un frame
actual. Configuración local inválida, fingerprint fuera de contrato, fallo de
autenticación WebTransport y protocolo/codec incompatible terminan en
`unavailable`; no entran en un bucle de reconexión.

La misma sesión se suscribe a `3-telemetry` y muestra vehículo, velocidad,
coordenadas y secuencia tras validar UTF-8, JSON, tamaño y rangos. El Gateway
rota audio y telemetría cada 32 Objects a un Subgroup nuevo para mantener cada
stream acotado sin descartar ni agregar datos críticos.

Vídeo, catálogo y telemetría tienen colas seriales independientes por alias,
acotadas a 32 Objects y 4 MiB. La saturación de vídeo descarta sólo deltas y
conserva el siguiente keyframe. La cola crítica nunca convierte telemetría en
"último valor" ni la descarta silenciosamente: si no puede progresar dentro de
su límite, se cierra únicamente la sesión prescindible del player.

## Estados operativos

La salida publica únicamente estados y razones de cardinalidad acotada:
`waiting`, `connecting`, `active`, `degraded`, `stale`, `unavailable` y
`closed`. La UI no muestra la URL completa del relay, fingerprint, namespace,
certificado, payload ni texto de error del peer. Tras tres segundos sin vídeo
marca `stale`; la telemetría puede seguir progresando de forma independiente.
Ocho segundos sin actividad de sesión activan reconexión dentro del presupuesto.

## Métricas

- **RX → Canvas:** tiempo monotónico local entre la llegada del Object y la
  presentación del frame. El supervisor muestra p50/p95/p99 sobre una ventana
  circular acotada a 512 frames, además de la última muestra y su cardinalidad.
  Sirve para diagnosticar cliente y decoder; la ventana se reinicia al reconectar.
- **Origen → RX:** diferencia entre el timecode visual validado del fixture y
  la llegada del Object al navegador. Permite separar la ruta de fuente,
  ingesta, mux, publicación y transporte del coste local de demux/decode/canvas.
- **Ingest → Publish p95:** percentil calculado por el Gateway entre la ingesta
  de una unidad de media y su publicación; no incluye red ni presentación.
- **Paquetes SRT y Group/Object:** datos reales del snapshot del Gateway para
  confirmar actividad y continuidad de la señal observada.
- **Descartes cliente:** objetos o muestras omitidos por discontinuidad,
  saturación o espera de keyframe.
- **G2G del fixture:** la fuente sintética codifica en píxeles un reloj Unix en
  centésimas de segundo con preámbulo, Gray de 38 bits y checksum. Entrada y
  salida publican p50/p95/p99 solo cuando el navegador valida esa marca. Como
  todos los procesos comparten el reloj del host, la resolución declarada es
  ±10 ms. Una fuente broadcast real seguirá como no disponible hasta integrar
  su timecode calibrado mediante PTP/LTC u otro contrato equivalente.

La colocación de ambas imágenes en una página no constituye por sí sola una
medición Glass-to-Glass: el valor existe únicamente cuando la marca de origen
supera preámbulo, checksum y ventana de frescura.

## Verificación

```bash
npm test
npm run lint
npm run build
npm audit --audit-level=high
```

Con el sistema local y Chrome de pruebas ya arrancados, `npm run test:cadence`
exige al menos 25 fps durante 20 segundos, p95 entre dibujos no superior a
80 ms, pausa máxima de 500 ms y menos de 5% de descartes cliente. Esta puerta
complementa las pruebas unitarias del parser incremental, reordenación,
transición normal entre GOPs y playout por timestamp. Antes de medir la salida,
también exige que el vídeo WebRTC del observador de entrada esté reproduciendo
y que su `currentTime` avance.

La misma puerta valida LQ con su cadencia nativa de 15 fps mediante:

```bash
node tests/cadence.mjs --track 1 --duration-ms 10000 --min-fps 12 --max-draw-p95-ms 100
```

El playout acumula 250 ms únicamente al arrancar. Si la cola se vacía durante
la reproducción, restablece el ancla temporal con un margen de 50 ms: volver a
aplicar el buffer completo transformaría una pérdida transitoria en una pausa
visible. La recuperación sigue limitada a un frame por tick del compositor y
nunca reproduce una ráfaga sin cadencia para ponerse al día.

La validación end-to-end debe usar un relay real y Chrome/Edge, no solo los
tests unitarios. El observador de entrada independiente se documenta en
`../gateway-rs/tests/preview/README.md`.

## Dependencias y licencia

Las versiones directas están fijadas en `package.json` y resueltas en
`package-lock.json`. MP4Box.js 2.4.1 procede del repositorio oficial de GPAC y
se usa únicamente para el parsing ISO BMFF/CMAF; el transporte y la política de
latencia siguen siendo código de integración de Teremoq. Consulta
`THIRD_PARTY_NOTICES.md` y `../gateway-rs/ADR-0003-CUSTOM-WEBTRANSPORT-WEBCODECS-PLAYER.md`.
