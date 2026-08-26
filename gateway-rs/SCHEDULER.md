# Scheduler por suscriptor — Pasos 5 y 6

El scheduler recibe `MediaObject` codificados y mantiene una cola independiente para cada suscriptor. Clonar un Object clona `Bytes` y `Arc`, no el payload. El consumidor extrae el Object antes de esperar al publisher, por lo que una escritura de red lenta nunca mantiene el lock de la cola.

## Prioridades

| Prioridad | Contenido | Política |
| --- | --- | --- |
| 0 | Audio crítico y telemetría | Reclama primero vídeo pendiente; si aun así no cabe o expira, expulsa solo al suscriptor |
| 1 | Random access/keyframe de vídeo | Reclama vídeo delta; si no cabe, invalida el Group |
| 2 | Vídeo delta P/B | Descarte inmediato por capacidad o al superar su TTL |

La extracción siempre intenta Prioridad 0, luego 1 y finalmente 2. La FIFO se conserva dentro de cada prioridad.

## Dependencias de Group

- Un delta solo se admite si su Group comenzó en random access y ese punto de acceso sigue siendo válido para el suscriptor.
- Si un random access expira o se reclama, todos sus deltas pendientes se descartan como `dependency_not_decodable`.
- Un nuevo Group elimina vídeo pendiente del Group anterior del mismo Track como `group_superseded`.
- HQ y LQ mantienen estado de decodificación independiente.

## Límites y aislamiento

Cada cola aplica simultáneamente `queue_objects` y `queue_bytes`. No existe una cola global de payloads. El registro de suscriptores está acotado y cada consumidor tiene un único receiver. Los locks protegen únicamente operaciones síncronas y acotadas sobre la cola; nunca atraviesan `.await`.

El Paso 6 registra `moq-relay-N` solo después de completar QUIC/WebTransport y el setup MoQT. Al caer el relay se elimina esa cola, el Gateway sigue ingiriendo y el siguiente intento obtiene una generación nueva. El relay oficial crea una sesión de transporte independiente por consumidor final; por eso el consumidor lento probado no bloquea al rápido ni al publisher.

## Evaluación

Las pruebas cubren prioridad, FIFO por clase, límites de Objects y bytes, TTL con reloj Tokio pausado, supersesión de Group, dependencia perdida, payload compartido y expulsión aislada de un consumidor lento. El fixture MPEG-TS también atraviesa demux y scheduler para verificar que audio crítico precede al vídeo ya clasificado.
