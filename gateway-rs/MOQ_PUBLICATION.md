# Publicación MoQT draft-16 — Paso 6

`gateway-rs` usa directamente las abstracciones de Cloudflare `moq-rs`: `Publisher::connect`, `publish_namespace`, `serve::Tracks`, `serve::Subgroups` y `SubgroupWriter::write`. No serializa mensajes de control ni frames de datos MoQT.

## Mapeo

| Track lógico | Nombre MoQT | Group | Subgroup | Object |
| --- | --- | --- | --- | --- |
| Catálogo | `catalog` | generación de inicialización | prioridad 0 | JSON MSF v1 con `initData` |
| 0 Vídeo HQ H.264 | `0-video-hq` | GOP iniciado en random access | ID original del Object, prioridad 1/2 | chunk CMAF `moof+mdat` |
| 1 Vídeo LQ H.264 | `1-video-lq` | GOP iniciado en random access | ID original del Object, prioridad 1/2 | chunk CMAF `moof+mdat` |
| 2 Audio crítico | `2-critical-audio` | secuencia temporal acotada a 32 Objects | ID original, prioridad 0 | Access unit codificada |
| 3 Telemetría | `3-telemetry` | secuencia temporal acotada a 32 Objects | ID original, prioridad 0 | JSON validado |

Los Objects de un GOP comparten un Subgroup ordenado. Esta elección conserva la secuencia de decodificación sin inventar extensiones: MoQT prioriza Subgroups, mientras que el modelo de dominio distingue keyframes y vídeo delta dentro del GOP. Para Tracks 0 y 1/H.264, el catálogo publica una entrada por representación y declara `packaging: "cmaf"`, codec RFC 6381, dimensiones e inicialización Base64. Una inicialización idéntica no vuelve a publicarse; un cambio genera una nueva revisión acotada del catálogo. `Bytes` se comparte hasta el writer upstream y el Gateway no decodifica ni transcodifica.

Audio y telemetría rotan a un Group/Subgroup nuevo cada 32 Objects. El límite
termina cada stream QUIC de forma periódica, mantiene acotado al receptor y no
implica descarte, agregación ni cambio de prioridad de los datos críticos.

La vertical reproducible admite Tracks 0 y 1 cuando llegan ya codificados en H.264. Audio, telemetría y los demás codecs continúan bajo el contrato elemental probado, pero no se anuncian como reproducibles hasta disponer de validación independiente.

## Recuperación

El endpoint QUIC se mantiene y cada reconexión crea una sesión y una cola `moq-relay-N` nuevas. La cola solo existe después del setup; si el relay no está disponible, la ingesta continúa y no acumula contenido antiguo. Un fallo de `Session::run`, `publish_namespace` o del writer cierra esa sesión, actualiza el supervisor y reintenta tras el intervalo configurado.

El relay local es una herramienta de evaluación, no un componente reimplementado: embebe `moq-relay-ietf` y añade únicamente política de alcance. En el modo loopback normal, `/publish` obtiene `ReadWrite`, `/watch` obtiene `ReadOnly` y el bind loopback actúa como frontera de acceso de desarrollo. El opt-in LAN no cambia ese bind: como el proxy UDP oculta el origen real, exige una capacidad run-scoped de 256 bits cargada desde un fichero absoluto, regular, no-symlink y `0600`. Sólo el Gateway local compone en memoria el path de publicación; el cliente LAN conserva únicamente `/watch`, y `/publish` o cualquier ruta desconocida se rechazan. Esta capacidad acotada no sustituye identidad mTLS ni autorización federada; un despliegue remoto debe usar la política de identidad del relay requerido.
