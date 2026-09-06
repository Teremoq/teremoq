# Continuación LAN · player real y carga 5/10/25

## Hallazgos y estado

- **READY FOR MASTER REVIEW** sujeto a la prueba física LAN, que este cambio no
  simula ni declara ejecutada.
- El player histórico `/` conserva decode/canvas, loopback y sus límites. La
  nueva `/lan-load` sólo existe de forma utilizable con `TEREMOQ_LAN_LAB=1`,
  Host loopback y GET/HEAD.
- Las cardinalidades ligeras son exactamente 5, 10 y 25. Un valor 0, distinto o
  mayor de 25 se rechaza antes de alterar una ejecución viva.
- No son clientes mTLS ni viewers autorizados: son sesiones MoQT desde una única
  IP permitida por el banco, con TLS fingerprint-pinned y namespace validado.
- No se añadieron dependencias, endpoints mutables, Gateway, input, Operations,
  infraestructura ni acceso remoto.

## Arquitectura y aislamiento

`LanLoadGenerator` reutiliza `resolvePlayerConnection` y `MoqSession`, se
suscribe sólo a Track 1 LQ y consume Objects sin catálogo, demux, VideoDecoder o
canvas. Cada sesión hereda las colas acotadas MoQT existentes, tiene timeout de
handshake/suscripción de 8 s y un presupuesto total de seis reintentos durante
30 s. Una generación nueva espera el cleanup de la anterior; stop aborta
handshakes, timers y sesiones y espera sus cierres.

El proxy LAN sólo permite `/`, `/lan-load`, favicon y estáticos `/_next` desde
`localhost`/`127.0.0.1`. `/gateway`, `/input`, `/operations`, rutas desconocidas,
Hosts remotos y métodos mutables permanecen cerrados. El build normal deja
`/lan-load` como 404; `build:lan` la vuelve dinámica y la incluye en standalone.

## Métricas y evidencia

Los JSON diferenciados `lan-real-player` y `lan-load-sessions` incluyen
`run_id`, `source_commit`, nivel e inicio/fin UTC procedentes del
`LAN-CONFIG.json` hash-bound. Sólo pasan a `measured` tras 600 s, cierre total y
contadores reales suficientes.

- Nivel 1: frames, Objects, bytes, presentation/RX-to-canvas p95, G2G p95 sólo
  con timecode visual, pérdidas/recuperaciones y tiempo hasta el primer frame
  recuperado. La recuperación Wi-Fi sólo se mide tras armado explícito del
  operador, pérdida de sesión posterior y primer Object nuevo dentro de una
  ventana cancelable de 180 segundos.
- Niveles 5/10/25: sesiones solicitadas, pico activo, cierres, Objects, bytes,
  pérdidas/recuperaciones y tiempo hasta el primer Object recuperado.
- `authorized_viewers` queda `not_measured`; frames/presentation/G2G en carga,
  ingest-to-publish, subscribers de red y pérdida/jitter QUIC quedan
  `not_available`. La atribución Wi-Fi sólo existe para el flujo armado de
  nivel 1; nunca se infiere de un reconnect ordinario.

La descarga es `local-browser-observation-user-exported`. El operador la mueve
manualmente al `EvidenceDirectory`; `collect` valida el esquema cerrado y
registra SHA-256 como detección de cambios, con estado
`not_attested_user_export`. No se presenta como evidencia autenticada.

El contrato fuente exacto que Platform debe consumir, incluidos nombres,
tipos, límites, invariantes y fixtures diferenciados, está en
`LAN-EVIDENCE-CONTRACT.md`; no se sustituyen `duration_ms`, `frames_observed`,
`objects_observed`, `presentation_rx_to_canvas_p95_ms`, `session_losses` o
`session_recoveries` por aliases de Platform.

## Contrato Platform y paquete

`package:lan` exige `--player-identity <sha256:64 hex>`, comprueba internamente el HEAD
local y que todo el checkout —incluidos untracked— está limpio. Genera
`lan-launcher.tsv` de doce claves y un manifest con versiones separadas de
updater/player/config e identidad árbol+lock; el commit queda en VERSION como
procedencia exterior de la petición, no en los bytes del player.

El launcher valida `VERSION.tsv` exterior, `LAN-CONFIG.json` de siete claves y
sus hashes; cruza run, commit, IPv4/URL MoQT, fingerprint y namespace. Verifica
inventario exhaustivo sin extras/symlinks, Node, puerto loopback libre,
readiness acotada y la identidad PID/executable/cmdline/start-time antes de
stop. No contiene URL de artefacto ni usa red remota.

Por diseño, `package:lan` sólo puede ejecutarse después de crear el commit DCO y
dejar el worktree limpio. Su resultado y hashes se entregan junto al hash del
commit; no se anticipan en este documento.

## Verificación

- Runtime: Node Linux 22 (`node:22-bookworm-slim`).
- `npm test`: 26 ficheros, 226/226 tests.
- `npm run lint`: correcto.
- `tsc --noEmit`: correcto.
- `npm run build`: correcto; `/` loopback estático y `/lan-load` no utilizable.
- `npm run build:lan`: correcto; `/` y `/lan-load` dinámicos, standalone creado.
- `npm audit --audit-level=high`: 0 vulnerabilidades.
- `package:lan`: puerta post-commit limpia obligatoria; resultado en la entrega.
- Navegador/banco real: no ejecutado en este entorno; no se declara E2E.
- PowerShell no está instalado en el runtime Linux; el launcher se verificó con
  contratos y regresiones estáticas, y queda pendiente su ejecución por Platform
  en el cliente Windows del banco.

## Límites

No se abrieron puertos, no se probó UDP/14433, no se usaron credenciales y no
se configuró forwarding/certificado. No hubo push, fetch, publicación, release
o despliegue. Platform conserva la composición del banco y el Gateway conserva
las métricas server-side.
