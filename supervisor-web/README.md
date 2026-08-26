# Supervisor Web de Teremoq

Supervisor comparativo aislado para observar la entrada SRT y seleccionar los
Tracks 0/1 (vídeo HQ/LQ) publicados por `gateway-rs`. La entrada procede de un tap MediaMTX
prescindible; la salida conecta con el relay mediante WebTransport, recibe el
subconjunto de MoQT draft-16 documentado en `ADR-0003`, desempaqueta CMAF con
MP4Box.js, decodifica H.264 mediante WebCodecs y presenta cada `VideoFrame` en
un `canvas`.

No forma parte del data plane del Gateway y no puede introducir contrapresión
en ingesta, demux, scheduler ni publicación.

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

La misma sesión se suscribe a `3-telemetry` y muestra vehículo, velocidad,
coordenadas y secuencia tras validar UTF-8, JSON, tamaño y rangos. El Gateway
rota audio y telemetría cada 32 Objects a un Subgroup nuevo para mantener cada
stream acotado sin descartar ni agregar datos críticos.

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
