# Supervisor web de señal

El Gateway incorpora un dashboard local de solo lectura para seguir la señal desde SRT hasta la distribución. Arranca con el mismo proceso y, por defecto, está disponible en:

```text
http://127.0.0.1:9080/
```

La solución incluye dos superficies de reproducción real, además de metadatos y contadores. La entrada se decodifica en un observador MediaMTX aislado y se incrusta por WebRTC; la salida se reproduce exclusivamente en `supervisor-web` mediante el player propio WebTransport/WebCodecs/canvas. La decodificación permanece fuera de `gateway-rs`, preservando zero-transcoding y el aislamiento del camino crítico.

## Fases visibles

| Fase | Información actual | Estado durante esta entrega |
| --- | --- | --- |
| SRT Ingest | conexiones, peer, mensajes, bytes y edad de actividad | Real |
| MPEG-TS Demux | Objects, bytes y actividad global | Real |
| Object Scheduler | suscriptores, cola, bytes, aceptados, descartados y expulsados | Real |
| MoQ Distribution | sesión relay, Objects/bytes publicados y última actividad | Real, MoQT draft-16 |
| Latencia interna | ventana acotada, p50, p95, p99 y máximo de `ingest_to_publish` | Real |

El bloque de Tracks muestra Track, códec, programa/PID, Group/Object, tipo de access unit, PTS/DTS, acumulados y edad de la última unidad. Los estados posibles son:

El bloque del scheduler agrega todas las colas independientes. La fase MoQ es `waiting` mientras no existe sesión, `active` cuando publica y `stale` después de una desconexión. El snapshot incluye `moq.connected`, el ID de conexión, el origen seguro del relay y acumulados; nunca expone la ruta completa ni credenciales.

El bloque de latencia conserva como máximo 4096 muestras monotónicas. El snapshot expone `latency.metric`, `samples`, `window_capacity`, `p50_ms`, `p95_ms`, `p99_ms` y `max_ms`. Los campos `network_and_subscriber_ms`, `presentation_ms` y `glass_to_glass_ms` son deliberadamente `null`: el Gateway no inventa los tramos que todavía no observa.

- `waiting`: todavía no se observó señal.
- `active`: hubo actividad en los últimos tres segundos.
- `stale`: existió señal, pero dejó de actualizarse durante más de tres segundos.
- `unavailable`: el snapshot no pudo leerse temporalmente.

## Rutas

| Ruta | Uso |
| --- | --- |
| `/` | Dashboard adaptable a escritorio y móvil |
| `/api/v1/snapshot` | Snapshot JSON versionado para lectura local |
| `/api/v1/playback` | URLs públicas y disponibilidad de los dos observadores; no expone rutas locales |
| `/api/v1/moq-certificate.sha256` | Fingerprint DER del relay para `serverCertificateHashes` de WebTransport |
| `/healthz` | Disponibilidad del servidor HTTP, respuesta `200` |

Para una comprobación rápida:

```bash
curl --fail http://127.0.0.1:9080/healthz
curl --fail http://127.0.0.1:9080/api/v1/snapshot
curl --fail http://127.0.0.1:9080/api/v1/playback
```

## Activar los dos visores

Arranca primero el relay para que genere su certificado y fingerprint persistentes:

```bash
cargo run --example dev_moq_relay
```

El certificado autofirmado de desarrollo dura menos de 14 días, requisito de
WebTransport cuando se usa `serverCertificateHashes`. Al caducar debe rotarse
de forma coordinada junto con su fingerprint; nunca se amplía su vigencia para
evitar esa rotación.

En otra terminal, arranca el observador de entrada:

```bash
docker compose -f tests/preview/compose.yaml up -d
```

La fuente debe duplicar el stream en origen: `srt://127.0.0.1:9000` para Teremoq y `srt://127.0.0.1:8890?streamid=publish:input` para MediaMTX. El ejemplo completo está en `tests/preview/README.md`. La vista de entrada aparecerá cuando se cargue el observador; la salida pasará a `REPRODUCIENDO` únicamente cuando el player propio reciba y decodifique una muestra CMAF real.

## Seguridad y aislamiento

- `TEREMOQ_SUPERVISOR_BIND_ADDR` solo acepta direcciones loopback y un puerto distinto de cero.
- Las respuestas usan `no-store`, `nosniff` y una Content Security Policy que permite solo `self` y los orígenes loopback configurados para WebRTC/WebTransport.
- No se exponen passphrases, Stream IDs ni payloads de media o telemetría.
- Las fuentes se acotan al límite configurado de sesiones SRT y los Tracks son siempre cuatro.
- La instrumentación usa `try_read`/`try_write`: pierde una muestra de supervisión antes que esperar por un lock en el camino de señal.
- Si el bind o el servidor fallan, se registra `supervisor_web_unavailable` y se reintenta cada cinco segundos. El directo continúa.

Publicarlo fuera de loopback queda fuera del alcance de la PoC y requerirá autenticación, autorización, TLS y límites de petición antes de habilitarse.

## Comparación de vídeo y latencia final

El supervisor ya muestra los dos reproductores dentro de la misma pantalla:

1. **Entrada:** un observador SRT independiente recibe una copia del stream de origen y la decodifica exclusivamente para preview.
2. **Salida:** el player propio, ejecutado fuera del proceso Gateway, negocia MoQT draft-16, se suscribe al Track CMSF publicado y decodifica H.264 mediante WebCodecs.

Ambos observadores son procesos o clientes separados, con colas acotadas y política de descarte propia. Nunca se insertan en serie dentro del camino de señal; si fallan, el directo continúa y el dashboard muestra la vista afectada como no disponible.

La medida no debe inferirse de la posición visual aproximada de dos reproductores. Cada unidad comparable conserva una clave de correlación formada por fuente, PTS/timecode e identificador de secuencia. Los puntos de medición previstos son:

| Tramo | Inicio | Fin |
| --- | --- | --- |
| `ingest_to_publish` | recepción monotónica SRT | publicación del Object |
| `network_and_subscriber` | publicación del Object | recepción en el cliente MoQT |
| `presentation` | recepción en cliente | frame presentado |
| `glass_to_glass` | captura/timecode de origen | frame presentado al usuario |

El panel presenta valor actual, p50, p95 y p99, junto con duración de la muestra y margen de error de sincronización. Para afirmar latencia `glass_to_glass`, el origen y el observador final deben compartir una referencia temporal calibrada o usar un timecode verificable transportado extremo a extremo. Sin esa calibración, el panel etiqueta la cifra como estimación y no como latencia total certificada.

La arquitectura activa del reproductor está fijada en `ADR-0003-CUSTOM-WEBTRANSPORT-WEBCODECS-PLAYER.md`; `ADR-0002` conserva únicamente la evidencia histórica de la alternativa descartada. No se reproduce media simulada: si faltan el observador, WebTransport, WebCodecs, el fingerprint, catálogo u Objects, la vista correspondiente explica el estado y permanece no disponible.
