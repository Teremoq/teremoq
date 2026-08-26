# Evidencia de interoperabilidad SRT y MoQT

Fecha: 2026-08-23. Entorno aislado Linux, loopback, sin pérdida inducida.

## Matriz validada

| Sentido | Caller / sender | Listener / receiver | Resultado |
| --- | --- | --- | --- |
| Ingesta principal | FFmpeg 5.1.9 enlazado con Haivision `libsrt` 1.5.1 | `gateway-rs`, Shiguredo `shiguredo_srt` 2026.1.0-canary.1 | MPEG-TS continuo recibido; TSBPD 120 ms; cero pérdidas en la ejecución |
| Ingesta cifrada | Mismo FFmpeg/Haivision, AES-128 | `gateway-rs`, AES-128 | 147 paquetes y 158580 bytes acumulados en 6 s; cierre limpio |
| Reconexión | Dos Callers FFmpeg consecutivos con el mismo Stream ID | `gateway-rs` | Identidades distintas `srt-1` y `srt-2`; ambas recibieron datos y cerraron limpiamente |
| Concurrencia | Dos Callers FFmpeg simultáneos (`main`, `telemetry`) | `gateway-rs` | Dos sesiones activas, contadores independientes y progreso simultáneo |
| Autorización | FFmpeg con Stream ID desconocido | `gateway-rs` | Rechazado y desconectado; sin registrar el valor del Stream ID |
| Sentido inverso | Caller oficial del checkout Shiguredo | Haivision `srt-live-transmit` 1.5.1 | Conexión aceptada y un paquete recibido sin pérdida |

## Comandos reproducibles del camino de ingesta

Gateway cifrado:

```bash
TEREMOQ_SRT_PASSPHRASE=interopsecret \
TEREMOQ_SRT_STATS_INTERVAL_SECS=1 \
target/debug/gateway-rs
```

Sender Haivision mediante FFmpeg:

```bash
ffmpeg -hide_banner -loglevel info -re \
  -f lavfi -i testsrc=size=320x180:rate=10 -t 6 \
  -c:v mpeg2video -f mpegts \
  'srt://127.0.0.1:9000?mode=caller&streamid=teremoq-main&latency=120000&passphrase=interopsecret&pbkeylen=16'
```

Los eventos `srt_connection_opened`, `srt_receiver_stats` y `srt_connection_closed` constituyen la evidencia del receptor. La progresión observada fue 24792, 51528, 80724, 110656, 129212 y 158580 bytes; `total_lost` permaneció en cero.

## Sentido inverso

Se compiló y ejecutó el ejemplo `srt_caller` del repositorio oficial de Shiguredo, sin copiarlo al producto. El peer de contraste fue:

```bash
srt-live-transmit -v -t:15 -s:1 -f \
  'srt://:9001?mode=listener&latency=120' \
  'udp://127.0.0.1:9002'
```

Haivision informó `RECEIVED: 1`, `LOST ... RECEIVED: 0` y RTT de 0,412 ms. El ejemplo upstream necesitó una corrección temporal de formato en sus dos manifiestos de ejemplo porque las tablas inline multilínea no son TOML válido; no se modificó la biblioteca publicada ni se incorporó el parche a Teremoq. También se observó que el ejemplo Caller repite su acción de desconexión tras EOF; la prueba definitiva mantuvo stdin abierto y terminó desde el Listener.

## Alcance y límites

- Esta evidencia valida interoperabilidad funcional en loopback, no el perfil de red hostil. Pérdida, reordenamiento, RTT alto y fluctuante, TLPKTDROP y soak prolongado requieren el banco de red de la PoC.
- El backend Shiguredo continúa clasificado como experimental y no queda aprobado para producción por estas pruebas.
- OBS no se ejecutó en este entorno; FFmpeg usa la misma implementación Haivision `libsrt` y cubre el mínimo explícito del Paso 3.
- La evidencia SRT no incluye todavía el perfil hostil ni soak del Paso 7.

## MoQT draft-16 y federación mTLS — Task 02

La prueba automatizada `moq_relay_interop` ejecuta el publisher `gateway-rs`, `moq-relay-ietf` y dos subscribers mediante la misma revisión oficial Cloudflare, sin frames propios. Usa Root A, intermediate A, certificado servidor con EKU `serverAuth` e identidad Gateway distinta con EKU `clientAuth`; relay y subscribers exigen mTLS real. Ambos consumidores reciben el mismo Object y el segundo demora deliberadamente 250 ms su lectura sin retrasar al primero.

```bash
cargo test --test moq_relay_interop -- --nocapture
```

Resultado observado el 2026-08-25: `1 passed; 0 failed; 1 ignored` (el caso ignorado es el soak/netem explícito), en 0,51 s. El test activo verifica certificado cliente obligatorio, QUIC/WebTransport, setup draft-16, `PUBLISH_NAMESPACE`, Track `0-video-hq`, Group, Subgroup priorizado y Object extremo a extremo.

El nuevo `mtls_quic` genera sin Internet Root/Intermediate A, servidor A, Gateway A, Gateway con EKU errónea, Root/Gateway B y Gateway expirado. Resultado observado el 2026-08-25: `8 passed; 0 failed`, en 0,17 s. Demuestra:

- Cadena leaf → intermediate válida, validación de SAN y setup MoQT.
- Rechazo durante TLS de cliente anónimo, CA B, EKU servidor usada como cliente, certificado expirado y hostname fuera de SAN.
- Cuatro clientes válidos progresando concurrentemente mientras cinco inválidos son rechazados; un cliente válido que cede voluntariamente no retrasa al resto.
- Timeout global de 10 s y finalización/await de todas las tasks de test.

Para evaluar los relays manualmente:

```bash
cargo run --example dev_moq_relay

set -a
source ../infra/pki/runtime/env/relay-dev-1.env
set +a
cargo run --locked --example dev_mtls_moq_relay
```

`dev_moq_relay` conserva el laboratorio browser UDP/4433 y su identidad persistente. `dev_mtls_moq_relay` escucha por defecto UDP/4443, no genera certificados, sólo sirve `/publish` y exige una identidad cliente emitida por la CA configurada. Es un laboratorio de integración, no el servicio federado productivo final.

La verificación de artefactos de Task 01 devolvió `PKI verification passed`. En el contenedor de validación, su URL `https://localhost:4443/publish` seleccionó `::1` mientras el relay estaba fijado a `127.0.0.1`, por lo que esa combinación exacta agotó el timeout. Usando `https://127.0.0.1:4443/publish` —SAN presente en el mismo certificado, sin desactivar verificación— el Gateway completó TLS 1.3, WebTransport, setup MoQT y `PUBLISH_NAMESPACE /teremoq/live`. El cliente oficial `moq-test-client 0.1.11` sin identidad fue rechazado con `peer sent no certificates`; una identidad autofirmada ajena fue rechazada con `UnknownIssuer`. Ninguno alcanzó setup. El listener browser UDP/4433 siguió activo durante el contraste.

Los tests locales demuestran integración rustls↔rustls reutilizando QUIC/WebTransport/MoQT upstream; no prueban interoperabilidad mTLS universal. Draft, wire protocol y ALPN no cambiaron. Falta contrastar autenticación de certificado cliente con un peer QUIC/WebTransport independiente. La evidencia externa MoQT existente continúa parcial 7/8 y no incluye mTLS. Finalmente, mTLS autentica al Gateway pero todavía no autoriza identidad contra namespace.

Desde la vertical CMAF, Track 0/H.264 publica chunks `moof+mdat` y un catálogo MSF v1 derivado de la inicialización real de `cmafmux`. La prueba multimedia valida estructura ISO-BMFF, flags de random access/delta, codec RFC 6381 y dimensiones. Esto completa el contrato de contenido previo al navegador, pero todavía no declara reproducción web: falta ejecutar Shaka Player 5.2.7 contra el relay real y presentar frames. `video-dev/moq-js` 0.4.3 negocia draft-14 y no es compatible con el transporte draft-16 fijado.

## Interoperabilidad externa — Paso 7

Se ejecutó el runner oficial `englishm/moq-interop-runner` en la revisión exacta `956129f28e323902c7d46068a5ceef54aa98b9ac` contra el relay público de `moxygen`, usando el cliente oficial `moq-rs`, draft-16 y WebTransport. La imagen cliente quedó identificada por el digest `sha256:80b062f753f7d28add68bd3f1c0ccdbeff5b244a41d7432f6afc44ff77a3f087`.

```bash
./run-interop-tests.sh \
  --remote-only --relay moxygen --client moq-rs \
  --target-version draft-16 --only-at-target --webtransport-only
```

Resultado observado el 2026-08-23: 7 de 8 casos TAP pasaron. Pasaron `setup-only`, `publish-namespace-only`, `subscribe-error`, `publish-namespace-subscribe`, `subscribe-before-publish-namespace`, `publish-namespace-done` y `publish-track-only`. Falló `publish-track-subscribe` con `subscriber track mode failed: done`.

El resumen estructurado y versionado de esta ejecución se conserva en `tests/evidence/moq-interop-runner-2026-08-23.json`.

Por tanto, existe evidencia externa de setup, namespace y publicación de Track entre implementaciones, pero **no** se declara interoperabilidad completa de entrega de Objects con `moxygen`. El runner apunta actualmente a draft-18 y conserva matrices para drafts anteriores; esta ejecución fijó draft-16 porque es el contrato real de Teremoq. Migrar de draft requiere actualizar conjuntamente `moq-rs`, ALPN, tests y esta matriz.

La interoperabilidad end-to-end del Gateway continúa cubierta localmente por `tests/moq_relay_interop.rs`, que usa las APIs públicas upstream, TLS/WebTransport reales y consumidores a velocidades distintas. No se implementaron frames MoQT propios para forzar compatibilidad.

Como comprobación adicional, el binario real se conectó directamente a `https://fb.mvfst.net:9448/moq-relay`, completó setup draft-16, abrió el subscriber interno `moq-relay-1` y publicó el namespace `/teremoq/interop/direct-20260823`. Durante la misma sesión recibió por SRT una fixture MPEG-TS externa, descubrió vídeo MPEG-2 y audio AAC y ejercitó el scheduler. Esta comprobación valida conexión y anuncio del Gateway contra moxygen; no demuestra que un cliente moxygen haya consumido sus Objects, por lo que no altera el resultado parcial 7/8 del runner.

## Puerta de autorización federada — esta Task

La revisión oficial fijada
`bf87128affd316463e5dcc7599a45001f222b6de` fue comparada el 2026-08-25 con los
tags compatibles más recientes: `moq-native-ietf 0.10.0`,
`moq-relay-ietf 0.7.25` y `moq-transport 0.16.1`. El commit fijado era también el
`HEAD` oficial observado. En todos los casos `ConnInfo` omite la cadena cliente,
`ConnectionMeta` sólo contiene socket/IP local/SNI/path,
`Coordinator::resolve_scope` sólo recibe path y `CoordinatorContext` deriva el
origen de relay del socket.

QUINN 0.11.11 sí ofrece `Connection::peer_identity()` y documenta la cadena
rustls, pero `moq-native-ietf` no la conserva antes de mover la conexión a la
sesión. No existe por tanto una API pública que permita demostrar autorización
`SPIFFE -> rol -> operación -> namespace` sin copiar o bifurcar el relay.

Se eligió la Ruta B de `ADR-0005-FEDERATED-AUTHORIZATION.md`. No se añadieron
tests de autorización aparentes ni se reinterpretan los tests mTLS existentes:
siguen demostrando autenticación, aislamiento de handshake y conservación de
Objects, no autorización de namespace ni interoperabilidad mTLS universal. No
se ejecutó Smallstep de autorización porque la integración completa está
bloqueada antes de ese punto.
