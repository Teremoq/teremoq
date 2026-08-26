# ADR-0003: player custom WebTransport, WebCodecs y canvas

- Estado: aceptada
- Fecha: 2026-08-24
- Alcance: cliente de salida aislado `supervisor-web`

## Contexto

Shaka Player 5.2.7 y el commit oficial excepcional evaluado en `ADR-0002` no interoperan con la revisión MoQT draft-16 fijada de `moq-rs`. `video-dev/moq-js` 0.4.3 solo implementa draft-14. Se rechaza degradar el Gateway a draft-14 y se autoriza un cliente receptor propio, limitado a la vertical necesaria para observar Tracks 0 y 1/H.264.

El contrato real no entrega elementary frames en datagramas. `gateway-rs` publica un Track `catalog`, `0-video-hq` y `1-video-lq` como Subgroups MoQT draft-16; cada Object de vídeo contiene un chunk CMAF `moof+mdat`, y el catálogo aporta una inicialización `ftyp+moov` en Base64 por representación. El cliente debe desempaquetar CMAF antes de crear `EncodedVideoChunk`.

## Decisión

Se crea `supervisor-web` como aplicación Next.js App Router separada, con componentes cliente React. Usa:

- WebTransport nativo y `serverCertificateHashes` para el relay local.
- Un receptor MoQT draft-16 mínimo: setup, SUBSCRIBE de `catalog` y una de las representaciones `0-video-hq`/`1-video-lq`, SUBSCRIBE_OK/ERROR, Subgroups y Objects. No implementa publicación, relay, anuncios genéricos ni drafts alternativos.
- GPAC MP4Box.js 2.4.1 (BSD-3-Clause) como parser ISO BMFF/CMAF oficial y fijado. Extrae `avcC`, tiempos y muestras AVC sin mantener un parser MP4 propio.
- `VideoDecoder`/`EncodedVideoChunk` para H.264 y canvas 2D para presentar cada `VideoFrame`.
- Colas acotadas y política temporal: si falta continuidad, hay error de decoder o crece `decodeQueueSize`, se descartan deltas y se espera un keyframe nuevo. No se acumula vídeo antiguo.
- Un único Subgroup ordenado por Track/Group, siguiendo el patrón oficial de
  `moq-pub`: sus Objects CMAF se escriben y consumen incrementalmente en el
  mismo stream QUIC. Abrir un Subgroup por fotograma queda prohibido porque los
  streams independientes pueden completarse fuera de orden y hacer que un
  keyframe llegue detrás de sus deltas.

El player es un consumidor prescindible. Nunca añade backpressure al Gateway, no contiene secretos, no escucha fuera de loopback en la PoC y no altera el scheduler ni la publicación.

## Límites de implementación

1. Solo MoQT draft-16/`moqt-16`, H.264/AVC y packaging CMAF para Tracks 0/1.
2. Máximo 64 KiB por mensaje de control, 4 MiB por Object y 32 muestras por fragmento; cualquier exceso cierra solo la sesión del player.
3. Todo reader, decoder y frame se cierra al desmontar el componente o reconectar.
4. La integración rechaza fragments truncados, muestras u offsets fuera de rango, varints no canónicos, codecs desconocidos y timestamps fuera del rango seguro de JavaScript.
5. No se copian implementaciones de otros players. Los fixtures de wire se derivan del publisher real y no contienen media con licencia restrictiva.

## Latencia y observabilidad

El cliente registra `object_received`, `chunk_submitted`, `frame_decoded`, `frame_presented`, `delta_dropped` y `decoder_resync`, con Track, Group, Object, timestamp de media y reloj monotónico local. Publica p50/p95/p99 para recepción→presentación. El fixture sintético añade antes del encoder un timecode visual Unix en centésimas, Gray de 38 bits y checksum. Entrada y salida publican G2G solo al validarlo y declaran resolución ±10 ms al compartir reloj de host. Otras fuentes permanecen no disponibles hasta transportar un timecode calibrado, por ejemplo PTP/LTC.

Para localizar el presupuesto temporal sin inferencias, la salida separa además
`origen → recepción del Object` y `recepción → canvas`, ambos con ventana
acotada y percentiles. El muxer publica chunks CMAF de un fotograma nominal a
30 fps (33.333.333 ns) dentro de fragments/GOP de un segundo. Esta decisión
triplica aproximadamente la cadencia de Objects respecto a chunks de 100 ms,
pero evita retener varios frames antes de poder publicarlos; es coherente con
la prioridad de latencia temporal sobre eficiencia de empaquetado.

## Riesgos y estrategia de salida

- MoQT y CMSF evolucionan; cualquier cambio de draft exige una ADR y fixtures nuevos.
- Un parser propio aumenta superficie de seguridad. Fuzzing, límites y pruebas de truncamiento son puertas previas a exposición remota.
- WebCodecs no está disponible en todos los navegadores. La PoC soporta Chrome/Edge y muestra `unavailable` en otros.
- La excepción se retira cuando exista una librería browser estable, licenciable e interoperable con la matriz exacta de Teremoq. La UI y la política de latencia podrán conservarse sobre ese transporte reutilizado.

## Criterios de aceptación

1. El build Next.js y los tests TypeScript pasan en modo estricto.
2. El cliente negocia `moqt-16` y recibe el catálogo desde el relay real.
3. Un fixture CMAF real produce configuración AVC y muestras con timestamps monotónicos.
4. Chrome presenta Tracks 0 y 1 seleccionables en canvas y recupera tras eliminar frames delta hasta el siguiente keyframe.
5. Cerrar, recargar o saturar el player no cambia ingesta, scheduler ni publicación.
6. No se declara latencia glass-to-glass sin correlación temporal extremo a extremo.

## Evidencia de aceptación

El 2026-08-24 se verificó la vertical real con `gateway-rs`, relay WebTransport y
Google Chrome 151.0.7922.173:

- negociación `moqt-16`, catálogo MSF y suscripción a `0-video-hq` correctas;
- H.264 `avc1.42c01f`, canvas 1280×720 con píxeles no negros y frames sucesivos;
- cola de decoder acotada, descartes delta activos y recuperación sin detener la sesión;
- sin errores de página ni promesas rechazadas durante la muestra;
- ventana recepción→canvas acotada a 512 frames con p50/p95/p99 y cardinalidad;
- en una muestra diagnóstica de 263 frames: p50 124,5 ms, p95 320,0 ms y
  p99 460,6 ms;
- dos navegadores simultáneos conservaron rutas QUIC independientes y terminaron
  la ventana de prueba sin `Connection lost`.
- con el timecode visual activo, una ventana headless de 512 muestras midió en
  salida p50 1.062,0 ms, p95 1.621,5 ms y p99 1.822,4 ms; la entrada mostró
  p50 536,5 ms y el diferencial p50 salida−entrada fue +525,5 ms. El Gateway
  mantuvo cola cero e `ingest_to_publish` p95 de 35 ms durante la lectura.
- después de reducir el chunk CMAF de 100 ms a un fotograma nominal, una
  segunda ventana headless de 143 muestras midió salida p50 396,7 ms,
  p95 560,7 ms y p99 643,0 ms. El desglose fue origen→recepción p50 347,5 ms /
  p95 473,8 ms y recepción→canvas p50 48,4 ms / p95 109,2 ms /
  p99 162,5 ms. La cola observada del decoder terminó en cero.
- la regresión de cadencia posterior agrupó los Objects de cada GOP en un
  Subgroup fiable y ordenado, añadió reordenación acotada defensiva en cliente
  y habilitó preferencia por decoder hardware. El cambio normal entre Groups
  no reinicia el decoder: solo una pérdida real activa la resincronización.
  Un playout acotado de 250 ms presenta por timestamp sobre el reloj del
  compositor y limita la memoria a 32 frames decodificados.
- con el fixture local 640×360@30 y el runtime Rust en perfil `release`, Chrome
  headless presentó 652 frames en 21,86 s: 29,83 fps, intervalo de dibujo p50
  33,3 ms, p95 48,8 ms, cero intervalos superiores a 100 ms y 0,97% de
  descartes cliente. La puerta automática exige al menos 25 fps, p95 de dibujo
  no superior a 80 ms, pausa máxima de 500 ms y menos de 5% de descartes.
- una regresión posterior detectó que aplicar de nuevo los 250 ms de buffer de
  arranque tras cada underflow podía convertir una interrupción transitoria en
  una pausa de 535,7 ms. El pacer conserva 250 ms solo al iniciar y usa un
  margen acotado de 50 ms al recuperarse. Con el fixture simultáneo de entrada
  y salida 480×270@30, la puerta de 20 s presentó 646 frames en 22,68 s:
  28,48 fps, intervalo p50 33,3 ms, p95 57,1 ms, pausa máxima 446,2 ms,
  descartes cliente 0,70% y cero errores de página.
- la extensión LQ empaquetó también Track 1/H.264 mediante el mismo `cmafmux`,
  publicó ambas representaciones en una revisión del catálogo y permitió
  seleccionar HQ/LQ sin reiniciar el Gateway. Con una fuente LQ 320×180@15,
  la puerta Chrome de 10 s presentó 14,8 fps, intervalo p50 66,7 ms, p95
  77,3 ms, pausa máxima 338,1 ms y 1,02% de descartes cliente, sin errores de
  página.
- la suscripción de Track 3 reveló que un Subgroup crítico indefinido chocaba
  con el límite defensivo de 32 Objects del receptor. El publisher rota ahora
  Groups de audio/telemetría cada 32 Objects, sin descarte. La prueba conjunta
  de 10 s mantuvo vídeo HQ a 29,16 fps y la secuencia de telemetría avanzó de
  95 a 152 sin errores de página.

Las cifras anteriores son muestras diagnósticas locales, no una garantía. La
medición G2G solo es válida para el fixture visual de mismo host; una fuente
broadcast continúa bloqueada hasta incorporar timecode de origen y calibración
de relojes verificables. La segunda ejecución satisface el objetivo sub-segundo
en p95 para esta ventana y fixture concretos, pero no constituye un SLA ni una
certificación de cadencia: Chrome headless usa decodificación software, realizó
descartes agresivos para conservar actualidad y debe sustituirse por pruebas
sostenidas en el navegador y hardware objetivo antes de una demostración al
cliente.
