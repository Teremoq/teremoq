# Banco multi-Track de la PoC

Fecha de ejecución: 2026-08-24. El ensayo conecta al Gateway real tres sesiones
SRT concurrentes y activa los cuatro Tracks lógicos sin codificar ni decodificar
dentro de `gateway-rs`.

## Topología

- Sesión `teremoq-main`: H.264 HQ en PID 256 y AAC crítico en PID 257.
- Sesión `teremoq-lq`: H.264 LQ en PID 256.
- Sesión `teremoq-telemetry`: JSON a 5 Hz en PID 300, encapsulado por el muxer
  oficial de GStreamer como `meta/x-klv` dentro de MPEG-TS.
- La fuente duplica HQ+AAC en origen hacia MediaMTX para el observador de
  entrada. Esa cuarta conexión no entra en el Gateway.
- El Gateway demultiplexa, clasifica, re-empaqueta únicamente HQ a CMAF y
  publica los cuatro Tracks mediante los writers de `moq-rs`.

FFmpeg y GStreamer pertenecen exclusivamente al generador de laboratorio. La
auditoría de factorías del proceso Gateway continúa rechazando encoders y
decoders.

## Resultado funcional

Una observación de cinco segundos obtuvo:

| Track | Códec | Objects nuevos | Estado |
| --- | --- | ---: | --- |
| 0 · Vídeo HQ | H.264 | 152 | active |
| 1 · Vídeo LQ | H.264 | 76 | active |
| 2 · Audio crítico | AAC | 234 | active |
| 3 · Telemetría | JSON | 25 | active |

El publisher MoQT permaneció conectado, la cola final fue cero y no hubo
expulsiones. Los eventos `object_dropped` de la ventana correspondieron a
Tracks de vídeo; no se observó descarte de Track 2 o Track 3 ni JSON inválido.

## Congestión y continuidad visual

La prueba determinista llena una cola de cuatro Objects con random access y
delta de HQ/LQ. Al llegar audio y telemetría, el scheduler descarta primero los
dos deltas, admite ambos Objects críticos y conserva la sesión. Esto valida la
política exacta independientemente del timing del host.

Con los cuatro Tracks activos, Chrome headless superó la puerta E2E de 20 s:

| Métrica | Resultado | Gate |
| --- | ---: | ---: |
| Cadencia canvas | 28,96 fps | ≥25 fps |
| Intervalo de dibujo p50 / p95 | 33,3 / 58,3 ms | p95 ≤80 ms |
| Pausa máxima | 427,7 ms | ≤500 ms |
| Descartes cliente | 0,55 % | ≤5 % |
| Errores de página | 0 | 0 |

## Límites

- El ensayo de congestión multi-Track del scheduler es determinista; todavía
  debe combinarse con `tc-netem`, media real y un soak prolongado para una
  cualificación broadcast.
- El player actual reproduce únicamente Track 0. LQ, audio y telemetría se
  publican y supervisan, pero su reproducción/presentación queda para un bloque
  posterior.
- Las cifras proceden de loopback y Chrome headless. No son un SLA ni sustituyen
  radios, módems y hardware objetivo.
