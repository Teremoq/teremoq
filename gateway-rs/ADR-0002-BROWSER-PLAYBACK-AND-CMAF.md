# ADR-0002: reproducción web draft-16 y empaquetado CMAF

- Estado: sustituida por `ADR-0003` para el cliente de salida; evidencia Shaka conservada
- Fecha: 2026-08-23
- Alcance: salida reproducible y comparación visual del supervisor

## Contexto

El Gateway partía de cuatro Tracks MoQT draft-16 cuyos Objects contenían access units elementales. Ese contrato permitía validar transporte, scheduler y descarte, pero no era directamente reproducible por un navegador: un cliente MSF/CMSF necesita un Track `catalog`, datos de inicialización MP4 y Objects CMAF formados por `moof` + `mdat`. La primera vertical Track 0/H.264 ya implementa ese contrato; la reproducción real en navegador sigue pendiente.

La revisión exacta de `cloudflare/moq-rs` usada por Teremoq, `bf87128affd316463e5dcc7599a45001f222b6de`, implementa MoQT draft-16. Su ejemplo `moq-pub` documenta el formato fMP4 histórico, pero su catálogo y el cliente `video-dev/moq-js` estable corresponden al contrato anterior. `moq-js` 0.4.3 ofrece únicamente `moq-00`/draft-14 y por ello no puede conectarse al Gateway sin degradar o duplicar el transporte.

La reproducción debe permanecer fuera del camino crítico. El Gateway puede re-empaquetar media codificada, pero nunca decodificarla ni recodificarla.

## Decisión

### Cliente de salida

La baseline estable es **Shaka Player 5.2.7**, tag y commit `114ae42d266ad104ee3d4023bbeb01caadef65a1`, licencia Apache-2.0. Su build experimental oficial negocia `moqt-16`, consume catálogos MSF y reproduce packaging `cmaf`/`chunk-per-object` mediante MSE. La prueba real demostró, sin embargo, que esa release no es interoperable con la revisión MoQT fijada por Teremoq.

Se autorizó temporalmente la evaluación del commit oficial Shaka `adc8c1bec77060060613f59c6c16dce0ee3eeef6` del 19 de agosto de 2026. La excepción no permitió seguir `main`, aplicar parches locales, relajar `moq-rs` ni copiar implementación Shaka al proyecto. El bundle se compiló desde ese checkout exacto con el Dockerfile oficial incluido en el mismo commit, el `package-lock.json` upstream y el build type `experimental` de release.

La matriz Chrome–Shaka–`moq-rs` no superó la prueba E2E, por lo que la excepción expiró y no es una dependencia activa. Se restauró la baseline 5.2.7 y el bundle experimental quedó archivado únicamente como evidencia reproducible. El owner del bloqueo es Distribución y la matriz se revisará cuando Shaka o `moq-rs` publiquen una revisión candidata compatible.

`video-dev/moq-js` 0.4.3 se conserva como herramienta de contraste draft-14 y queda descartado como reproductor final mientras no publique una release compatible con draft-16. No se cambia `moq-rs` a draft-14 para acomodarlo.

`moqtail/moqtail` 0.12.1, commit `8afe20d696c6a4990474f7bcaa52eda91582b5ba`, licencia Apache-2.0, se admite como segundo peer de interoperabilidad CMSF. No reemplaza al player seleccionado ni al transporte del Gateway.

### Empaquetado

El empaquetador preferido es `cmafmux` del repositorio oficial `GStreamer/gst-plugins-rs`, licencia MPL-2.0. Para el runtime GStreamer 1.22 actual, el candidato reproducible es el tag `gstreamer-1.22.12`, commit `a84bbc66f30573b62871db163c48afef75adf6ec`, crate/plugin `gst-plugin-fmp4` 0.9.13. Se construirá como plugin dinámico separado y se documentarán los avisos MPL-2.0.

La imagen de laboratorio construye y carga esa revisión exacta de `cmafmux`. Una prueba exploratoria previa con `mp4mux` 1.22.0 de `gst-plugins-good` (LGPL-2.1-or-later) probó la viabilidad del re-empaquetado, pero `mp4mux` queda solo como fallback condicionado a una prueba real con Shaka y no como elección silenciosa de producción.

### Contrato de publicación

El namespace publicará un Track `catalog` con JSON MSF versión 1 y entradas de media con nombre estable, `packaging: "cmaf"`, rol, codec RFC 6381, datos de inicialización Base64 y metadatos necesarios para selección. Los Tracks de vídeo transportarán exactamente un chunk CMAF completo por Object. Un Group comienza en un punto de acceso aleatorio; los Objects delta conservan prioridad 2 y deadline.

El catálogo es metadata de aplicación, no un frame de control MoQT. La sesión, negociación, namespaces, suscripciones, Tracks, Groups, Subgroups y Objects continúan delegados a `moq-rs`; no se serializa MoQT manualmente.

La primera vertical reproducible admite solo H.264 ya codificado en Track 0. H.265, MPEG-2 Video, Track 1, audio y telemetría siguen funcionando bajo el contrato existente, pero no se anuncian como reproducibles en el catálogo hasta que exista evidencia por codec. No se transcodifica MPEG-2 a H.264 dentro del Gateway.

### Supervisor y medida

Shaka se ejecuta en el navegador. La vista de entrada reutiliza MediaMTX 1.20.0 en un contenedor externo y recibe una segunda copia SRT generada en origen; no existe un tap en serie dentro del Gateway. Ambos observadores son prescindibles: su caída no puede cerrar una task crítica ni ejercer backpressure sobre el Gateway.

La comparación usa fuente + PTS/timecode + secuencia. `ingest_to_publish` se mide en el Gateway; `network_and_subscriber` y `presentation` los reporta el cliente de salida. `glass_to_glass` solo se etiqueta como medido cuando origen y observador comparten una referencia temporal calibrada; en caso contrario se muestra como estimación con su error.

## Alternativas evaluadas

| Opción | Licencia | Resultado |
| --- | --- | --- |
| Shaka Player 5.2.7 | Apache-2.0 | Baseline estable; no interoperable por su codificación de `GROUP_ORDER=PUBLISHER`. |
| Shaka Player `adc8c1bec77060060613f59c6c16dce0ee3eeef6` | Apache-2.0 | Evaluado bajo excepción exacta y rechazado: conserva `GROUP_ORDER=0` en SUBSCRIBE draft-16. |
| `video-dev/moq-js` 0.4.3 | MIT OR Apache-2.0 | Rechazado como cliente final por negociar solo draft-14. |
| `cloudflare/moq-rs/moq-pub` | MIT OR Apache-2.0 | Reutilizable como referencia histórica, pero su catálogo/cliente estable no coincide con el contrato MSF actual y su ejemplo declara limitaciones de audio. |
| `rafaelcaricio/gst-moq-pub` | MPL-2.0 | No adoptado: proyecto comunitario pequeño y duplicaría transporte/publicación ya implementados. |
| MOQtail 0.12.1 | Apache-2.0 | Segundo peer de contraste; reemplazar `moq-rs` exigiría un bake-off completo. |
| MediaMTX | MIT | Útil como herramienta externa, pero no implementa la política propia de Tracks, prioridades y descarte de Teremoq. |
| Reproductor propio | N/A | Prohibido: duplicaría MoQT, CMSF, MSE/WebCodecs y controles ya desarrollados. |

## Consecuencias y riesgos

- Se añade un plugin dinámico MPL-2.0 y un artefacto web Apache-2.0 al inventario de terceros; ambos necesitan pin y avisos de distribución.
- El formato de aplicación MSF/CMSF todavía evoluciona. Transport, catálogo y player deben actualizarse como una matriz probada, nunca por separado.
- El fragmentado puede introducir espera. El objetivo inicial es un chunk por frame o una duración máxima configurable de 100 ms, verificada con percentiles reales.
- Descartar un fragmento delta puede invalidar dependencias posteriores. El scheduler debe conservar la regla de esperar al siguiente punto de acceso cuando se pierda la decodificabilidad.
- La fixture persistente MPEG-2/AAC no sirve para reproducción web H.264. El test genera una entrada H.264 sintética y efímera fuera del Gateway; ningún encoder forma parte del runtime de producción.

## Evidencia de navegador del 23 de agosto de 2026

La prueba se ejecutó con Chrome, Shaka Player 5.2.7, el relay local `moq-relay-ietf`, una fuente H.264/PID 256 duplicada en origen y el Gateway real. El observador MediaMTX estableció WebRTC y presentó la entrada. El Gateway recibió SRT, detectó H.264, generó CMAF y publicó Objects; el snapshot registró actividad real en las cuatro fases y percentiles `ingest_to_publish`.

La primera conexión WebTransport reveló que `rcgen::generate_simple_self_signed()` genera una vigencia 1975–4096, incompatible con la autenticación mediante `serverCertificateHashes`, cuyo máximo es dos semanas. El relay de desarrollo genera ahora una identidad ECDSA persistente de 13 días más cinco minutos de tolerancia de reloj, publica su SHA-256 DER y marca el perfil `webtransport-hash-v1`. Las identidades anteriores se archivaron y no se reutilizan.

Después de corregir TLS, Chrome negoció WebTransport y MoQT con el relay. Shaka terminó con `MSF_CATALOG_TIMEOUT` (`4064`) y el relay registró `decode error: invalid group order`. La comparación de los dos upstreams demuestra la causa:

- Shaka 5.2.7 `marshalSubscribeDraft16_()` añade siempre el parámetro `GROUP_ORDER` (`0x22`) con `PUBLISHER = 0`.
- `moq-rs` en la revisión fijada interpreta la ausencia de `GROUP_ORDER` como orden del publisher y rechaza explícitamente el valor `0`; solo `1` y `2` son valores válidos cuando el parámetro existe.
- El commit Shaka `adc8c1bec77060060613f59c6c16dce0ee3eeef6`, todavía no incluido en una release estable evaluada, reconoce y corrige varios defectos draft-16 dentro de una reestructuración mayor que añade draft-18.

No se parchea el bundle, no se relaja el decoder del relay y no se adopta una rama flotante. El 23 de agosto de 2026 se autorizó la excepción temporal descrita en esta ADR para el commit exacto `adc8c1bec77060060613f59c6c16dce0ee3eeef6`.

El build oficial produjo dos veces el mismo bundle de 1.141.220 bytes, versión embebida `v5.2.6-main-4-gadc8c1bec` y SHA-256 `d501099d5bd9a921f8a6ef72517f382fe92f051dfba005bd476190f04ff792a9`. Las entradas verificadas fueron: Dockerfile `13122e4982ea499c77889c3ab659dd4b631876a4f7afdc2ef95097f7533325b3`, `package-lock.json` `d801f4e8dc2cbcd9290a7acbca9837d60ffe551b6361b8b1baf43464ad646637` y licencia Apache-2.0 `20ce2eba547fd0a8c4023511c003eabe510982a335cccd4e270f1f55ffbd2250`.

Chrome cargó ese SHA exacto, abrió WebTransport y volvió a terminar en `MSF_CATALOG_TIMEOUT` (`4064`); el relay volvió a registrar `decode error: invalid group order`. La inspección del checkout confirma que `BufferControlWriter.marshalSubscribe()` aún añade `PARAM_GROUP_ORDER` (`0x22`) con `RequestIdSession.subscribe().groupOrder = PUBLISHER = 0`. El commit corrige otros cuatro defectos draft-16 descritos por upstream, pero no este desacuerdo. La excepción queda cerrada como fallida y la salida permanece no disponible.

## Criterios de aceptación

1. ✅ El inventario de factorías demuestra ausencia de Decoder y Encoder.
2. ✅ Un fixture MPEG-TS/H.264 produce inicialización y Objects `moof` + `mdat` acotados.
3. El catálogo se valida contra un parser independiente y un cliente Shaka compatible.
4. ❌ Shaka 5.2.7 y el commit autorizado negocian WebTransport con TLS fijado, pero ambos envían `GROUP_ORDER=0` y no completan SUBSCRIBE con la revisión actual de `moq-rs`.
5. Bajo presión, los Objects delta pueden descartarse sin bloquear audio/telemetría y la imagen recupera en el siguiente punto de acceso.
6. Desconectar el tap SRT, cerrar el navegador o saturar el preview no altera la ingesta, el scheduler ni la publicación.
7. El supervisor diferencia medidas reales, estimaciones y valores no disponibles.
