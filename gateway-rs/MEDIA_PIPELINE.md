# Pipeline multimedia y empaquetado CMAF

Cada conexión SRT autorizada crea un pipeline independiente por `program_number` configurado:

```text
appsrc (MPEG-TS, acotado) → tsdemux (program-number, latency=0)
  → queue (64 buffers) → parser de códec → appsink (acotado por Track)

Tracks 0 y 1/H.264:
  → queue → h264parse → capsfilter (avc, AU) → cmafmux → appsink (BufferList)
```

`tsdemux` es la implementación oficial de GStreamer para PAT, PMT, PID y PES. El código propio se limita a conectar pads dinámicos, aplicar el routing validado y convertir unidades codificadas a `Track`, `Group` y `MediaObject`. PTS, DTS, PID, programa, códec, identidad de conexión y reloj monotónico de ingesta se conservan. Para elementary streams, `DELTA_UNIT` separa random access de vídeo delta. Para CMAF, la clasificación se obtiene de los flags ISO-BMFF de `tfhd`/`trun`, no de las flags externas de un `BufferList`. `DISCONT` genera observabilidad.

No existe decoder, encoder, convertidor, resampler ni payload PCM/píxel. Los Tracks 0 y 1/H.264 se convierten de Annex B a AVC y se re-empaquetan con el `cmafmux` oficial; no se altera el bitstream comprimido. H.265 y MPEG-2 Video permanecen como elementary streams. Los otros formatos admitidos usan sus parsers oficiales. Al arrancar, el Gateway comprueba la presencia y la clase de todas las factorías, incluido `cmafmux`.

## Códecs admitidos

| Track | Caps GStreamer | Parser |
| --- | --- | --- |
| Vídeo HQ/LQ | H.264, H.265, MPEG-2 Video | `h264parse`, `h265parse`, `mpegvideoparse` |
| Audio crítico | AAC, Opus, AC-3, E-AC-3 | `aacparse`, `opusparse`, `ac3parse` |
| Telemetría | teletext privado, KLV o ID3 configurado para JSON | `identity` y validación `serde_json` |

Un PID no configurado o un códec no admitido se conecta a `fakesink` para que no detenga otros streams del programa. Una cola llena, un objeto fuera de límite o un error del bus cierra únicamente la sesión multimedia causante. Las sesiones inactivas se liberan con un timeout acotado.

## Empaquetado implementado

`cmafmux` procede de `GStreamer/gst-plugins-rs`, tag `gstreamer-1.22.12`, commit `a84bbc66f30573b62871db163c48afef75adf6ec`, plugin `gst-plugin-fmp4` 0.9.13. Produce la inicialización `ftyp+moov` y chunks `moof+mdat` de hasta 100 ms. La inicialización se conserva fuera del payload de media para generar el catálogo MSF y restaurar sesiones.

En las fronteras de fragmento, `cmafmux` puede entregar `ftyp+moov`, `styp`, `moof` y cabecera `mdat` en miembros distintos del mismo `BufferList`. El adaptador localiza cajas ISO-BMFF completas, elimina `styp` del Object y concatena desde `moof`; no inspecciona ni copia píxeles. Un Object CMAF inválido se rechaza y se registra sin detener otras sesiones.

## Evidencia reproducible

`tests/media_pipeline.rs` alimenta una fixture sintética CC0 por mensajes de 1316 bytes y exige Objects MPEG-2/AAC con PTS. Genera además H.264 sintético de forma efímera para HQ y LQ, exige inicialización `ftyp+moov`, chunks `moof+mdat`, resolución y codec RFC 6381 correctos, y comprueba por `trun` un chunk random-access y otro delta. FFmpeg/libx264 solo crea la entrada del test fuera del Gateway. Otra prueba introduce bytes corruptos y comprueba aislamiento y cierre sin pánico. Los tests unitarios auditan las factorías y el mapeo real de nombres de pad `tsdemux` a PID.
