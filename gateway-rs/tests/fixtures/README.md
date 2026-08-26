# MPEG-TS test fixture

`mpeg2-aac.ts` is synthetic media generated from FFmpeg filters. It contains no
third-party audiovisual material: one second of `testsrc` video and a sine wave.

- Program: `1`
- Video: MPEG-2, PID `256`, 160x90 at 10 fps
- Audio: AAC, PID `257`, 48 kHz
- SHA-256: `5c8c005ebec9c722bcdf5bd790532827b46514e0e2230ca7cdc66be4740336ec`

Generation command (FFmpeg 5.1.9):

```sh
ffmpeg -hide_banner -loglevel error \
  -f lavfi -i testsrc=size=160x90:rate=10 \
  -f lavfi -i sine=frequency=1000:sample_rate=48000 \
  -t 1 -c:v mpeg2video -g 5 -bf 1 -c:a aac -b:a 64k \
  -streamid 0:256 -streamid 1:257 -mpegts_service_id 1 \
  -f mpegts mpeg2-aac.ts
```

La prueba H.264/CMAF genera una fixture efímera equivalente mediante FFmpeg
5.1.9 dentro del contenedor de laboratorio. No se conserva el binario para
evitar incorporar un artefacto codificado opaco; la fuente `testsrc` es
sintética y se licencia CC0-1.0 como el resto de fixtures. FFmpeg y `libx264`
solo se ejecutan durante el test: el binario `gateway-rs` recibe H.264 ya
codificado y no enlaza ni invoca ningún encoder.

The fixture and this metadata are dedicated to the public domain under
[CC0-1.0](https://creativecommons.org/publicdomain/zero/1.0/).
