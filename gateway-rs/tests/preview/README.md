# Observador aislado de entrada

Este laboratorio usa MediaMTX 1.20.0 (MIT) como receptor SRT y salida WebRTC
exclusiva para el visor de entrada. No forma parte del binario ni del data plane
de `gateway-rs`.

Arranque:

```bash
docker compose -f tests/preview/compose.yaml up -d
```

La fuente debe producir dos copias en origen: una para Teremoq y otra para el
observador. Ejemplo con un MPEG-TS/H.264 ya codificado, sin recodificarlo:

```bash
ffmpeg -re -i input.ts -map 0 -c copy -f tee \
  '[f=mpegts:onfail=ignore]srt://127.0.0.1:9000?mode=caller&streamid=teremoq-main|[f=mpegts:onfail=ignore]srt://127.0.0.1:8890?mode=caller&streamid=publish:input'
```

El runtime de evaluación que acompaña al supervisor en
`http://127.0.0.1:19080/` publica temporalmente la ingesta del Gateway en el
puerto `19000`, porque el `9000` del host está ocupado por el compose general.
Para esa sesión sustituye únicamente `:9000` por `:19000` en el comando
anterior. El valor predeterminado y el contrato del proyecto siguen siendo
UDP/9000.

El visor WebRTC queda en `http://127.0.0.1:8889/input`. Detener o saturar este
contenedor no puede ejercer contrapresión sobre el Gateway.

El contenedor `teremoq-preview-runtime` debe pertenecer a la misma red Docker
`preview_default` que `input-observer`; de lo contrario el segundo destino SRT
no puede resolver `input-observer:8890`. La salida es deliberadamente opcional
para no detener el directo, por lo que la puerta E2E del Supervisor verifica
además que el `<video>` de entrada progresa realmente.

La fuente visual reproducible del laboratorio genera barras animadas 480×270 a
30 fps con PTS visible y codifica H.264 exclusivamente fuera del Gateway:

```bash
docker exec -it teremoq-preview-runtime tests/preview/run-source.sh
```

El fixture usa un GOP cerrado de 15 frames a 30 fps. Así, un consumidor que
descarte vídeo delta por contrapresión encuentra un nuevo punto decodificable
en un máximo nominal de 500 ms, a cambio de un aumento moderado de bitrate.

## Fuente multi-Track

El banco completo genera fuera del Gateway las cuatro señales lógicas:

| Track | Fuente de laboratorio | Transporte elemental |
| --- | --- | --- |
| 0 · Vídeo HQ | H.264 480×270@30 | MPEG-TS PID 256, Stream ID `teremoq-main` |
| 1 · Vídeo LQ | H.264 320×180@15 y 350 kbit/s | MPEG-TS PID 256, Stream ID `teremoq-lq` |
| 2 · Audio crítico | AAC mono 48 kHz | MPEG-TS PID 257 junto al HQ |
| 3 · Telemetría | JSON a 5 Hz encapsulado como KLV | MPEG-TS PID 300, Stream ID `teremoq-telemetry` |

Solo debe ejecutarse una fuente de preview a la vez; ambos scripts usan un
lock no bloqueante para evitar señales duplicadas. En el runtime de laboratorio:

```bash
docker exec -d -w /workspace teremoq-preview-runtime \
  tests/preview/run-multitrack-source.sh
python3 tests/preview/verify-multitrack.py
```

`verify-multitrack.py` observa cinco segundos y exige tres sesiones SRT, los
cuatro Tracks activos y progresando, una sesión MoQT conectada y cola acotada.
El supervisor principal muestra la misma matriz en `http://127.0.0.1:19090/`.
La prueba determinista
`multitrack_congestion_discards_video_before_critical_data` llena una cola con
HQ/LQ y verifica que audio y telemetría entran desplazando únicamente vídeo,
sin expulsar al consumidor.

La resolución contenida evita que el encoder sintético, el observador WebRTC y
Chrome headless compitan por todos los núcleos del portátil de laboratorio. No
es una reducción aplicada por el Gateway: cualquier fuente externa conserva
su resolución y codec originales.

El laboratorio de cadencia debe ejecutar `gateway-rs` y `dev_moq_relay` desde
`target/release`. El perfil `debug` conserva comprobaciones y código sin
optimizar que compiten con la decodificación software del navegador y no es
representativo de un Gateway desplegado.

El Gateway empaqueta cada fotograma nominal de 30 fps en un chunk CMAF de
33.333.333 ns, manteniendo fragments de un segundo. La granularidad de un
fotograma reduce la espera de publicación respecto a agrupar 100 ms de vídeo,
a cambio de aproximadamente tres veces más Objects y mayor overhead de MoQT.
Es una elección deliberada: actualidad temporal antes que eficiencia de
empaquetado.

La franja inferior contiene un timecode visual de laboratorio generado antes
de codificar: preámbulo fijo, reloj Unix en centésimas codificado como Gray de
38 bits y checksum binario de 8 bits. El cliente solo calcula G2G cuando valida
los tres elementos y el timestamp tiene menos de 10 segundos. La resolución es
±10 ms porque fuente y navegadores comparten el reloj del mismo host. Esta marca
no sustituye PTP/LTC en una fuente broadcast real y nunca atraviesa una ruta de
transcoding dentro del Gateway.

## Exposición QUIC multi-cliente

El relay permanece ligado a loopback dentro del runtime. `loopback_proxy.py`
expone el puerto UDP del laboratorio conservando una asociación backend
independiente por tupla IP/puerto de cada navegador. El proxy admite como máximo
64 clientes y elimina asociaciones sin actividad durante 30 segundos. Nunca se
debe sustituir por un único socket UDP compartido: las respuestas QUIC quedarían
asignadas al último cliente observado y las demás sesiones terminarían por
`idle timeout`.

La prueba de regresión operativa abre al menos dos navegadores simultáneos y
verifica que ambos continúan presentando frames durante toda la ventana. Las
mediciones con Chrome headless y decodificación software sirven para detectar
cortes y progreso del canvas, pero no constituyen una medida Glass-to-Glass ni
una certificación de cadencia; esa entrega requiere navegador/hardware objetivo
y timecode de origen verificable.

La codificación existe solo para crear la fuente de evaluación. El inventario
de factorías del proceso Gateway continúa rechazando cualquier Encoder o
Decoder.
