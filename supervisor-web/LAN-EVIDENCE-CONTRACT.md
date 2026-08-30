# Contrato Web cerrado de observación LAN v1

Este documento es la fuente de verdad para los JSON descargados por
`supervisor-web`. Platform debe consumir estos nombres y estructuras
directamente. No debe renombrar campos por analogía ni interpretar una ausencia
como cero. Los objetos son cerrados: toda propiedad es obligatoria y cualquier
propiedad desconocida se rechaza.

Los JSON son observaciones locales exportadas por el usuario, no atestaciones
criptográficas. El límite del fichero es 65.536 bytes UTF-8. Los enteros son
enteros seguros JavaScript no negativos, nunca booleanos. Los números medidos
deben ser finitos. Los timestamps son UTC canónicos `toISOString()`, fin mayor
o igual a inicio y su diferencia debe coincidir con `duration_ms` con una
tolerancia máxima de 5.000 ms. `duration_ms` está entre 600.000 y 86.400.000.
Ambas pantallas descargan el nombre exacto
`local-browser-observation-user-exported.json`; el directorio de evidencia del
run/nivel aporta el aislamiento y no se debe renombrar el fichero.

## Campos comunes

| Propiedad | Tipo y contrato |
| --- | --- |
| `schema_version` | literal entero `1` |
| `export_kind` | `lan-real-player` o `lan-load-sessions`, según el esquema |
| `source` | literal `local-browser-observation-user-exported` |
| `measurement_status` | literal `measured`; `incomplete` nunca pasa `collect` |
| `mode` | `real-player` o `lightweight-moq`, según el esquema |
| `level` | `1` para player; exactamente `5`, `10` o `25` para carga |
| `run_id` | string `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$` |
| `source_commit` | string `^[0-9a-f]{40}$`, ligado a config/paquete |
| `started_at_utc`, `ended_at_utc` | strings UTC canónicos y coherentes |
| `phase` | literal `closed` |
| `requested_sessions` | `1` o exactamente el nivel de carga |
| `active_sessions_peak` | igual a `requested_sessions` |
| `objects_observed`, `bytes_observed` | enteros seguros positivos, observados por callbacks reales |
| `duration_ms` | entero seguro `600000..86400000` y coherente con timestamps |

## Nivel 1: `lan-real-player`

Además de todos los campos comunes, el objeto tiene exactamente estas
propiedades:

| Propiedad | Tipo y contrato |
| --- | --- |
| `track` | entero `0` o `1` |
| `frames_observed` | entero seguro positivo; frames realmente presentados |
| `presentation_rx_to_canvas_p95_ms` | número finito `0..duration_ms` |
| `g2g_measurement_status` | `measured` o `not_available` |
| `g2g_p95_ms` | número finito `0..duration_ms` si está medido; en otro caso `null` |
| `session_losses` | entero seguro `>=1`; incluye la pérdida usada por la observación armada |
| `session_recoveries` | entero seguro entre `0` y `session_losses` |
| `last_session_recovery_ms` | `null` cuando no hay recuperación; si la hay, entero `0..duration_ms` |
| `wifi_recovery_status` | literal `measured` para evidencia coleccionable |
| `wifi_recovery_armed` | booleano `true` |
| `wifi_loss_observed` | booleano `true` |
| `wifi_recovery_observed` | booleano `true` |
| `wifi_recovery_ms` | entero seguro `1..180000`; diferencia monotónica redondeada hacia arriba al milisegundo |
| `wifi_recovery_provenance` | literal `operator-armed-browser-monotonic-session-loss-to-first-recovered-object` |
| `last_error` | `null` |
| `unavailable_measurements` | objeto cerrado descrito abajo |

`unavailable_measurements` contiene exactamente:

- `quic_packet_loss: "not_available"`
- `quic_jitter_ms: "not_available"`
- `authorized_viewers: "not_measured"`
- `ingest_to_publish_ms: "not_available"`
- `network_subscribers: "not_available"`

Antes del armado, `exportPlayerEvidence` conserva
`wifi_recovery_status="not_measured"`, los tres booleanos en `false`, valor
`null`, provenance `not_available` y `measurement_status="incomplete"`. Armado
sin pérdida, pérdida sin Object recuperado, cancelación o expiración también
permanecen incompletos y `collect` los rechaza. Sólo el botón explícito
**Armar observación**, una pérdida de sesión posterior y el primer Object nuevo
dentro de 180 segundos producen el valor. Rearmar reemplaza la ventana anterior
y desmontar el componente cancela timer y estado activo.

Fixture versionado:
[`src/lib/lan-lab/fixtures/player-level-1.valid.json`](src/lib/lan-lab/fixtures/player-level-1.valid.json).

## Niveles 5/10/25: `lan-load-sessions`

Además de los campos comunes, el objeto tiene exactamente:

| Propiedad | Tipo y contrato |
| --- | --- |
| `closed_sessions` | entero seguro mayor o igual al nivel; incluye generaciones recuperadas |
| `local_stream_rejections` | entero seguro no negativo |
| `errors` | entero seguro mayor o igual a `local_stream_rejections` |
| `reconnect_attempts` | entero seguro no negativo |
| `session_losses` | entero seguro no negativo |
| `session_recoveries` | entero seguro entre `0` y `session_losses` |
| `last_session_recovery_ms` | `null` sin recuperación; si existe, entero seguro no negativo |
| `first_connected_ms` | entero seguro no negativo |
| `all_active_ms` | entero seguro mayor o igual a `first_connected_ms` |
| `last_object_ms` | entero seguro entre `first_connected_ms` y `duration_ms` |
| `last_error` | `null` o uno de los errores redactados enumerados por el validador |
| `unavailable_measurements` | objeto cerrado descrito abajo |

`unavailable_measurements` contiene exactamente los cinco campos base del
player y, además:

- `presentation_p95_ms: "not_available"`
- `g2g_p95_ms: "not_available"`
- `wifi_recovery_ms: "not_available"`
- `frames_observed: "not_available"`

No existe atribución Wi-Fi para sesiones ligeras. El mismo esquema se usa para
5, 10 y 25 cambiando conjuntamente `level`, `requested_sessions`,
`active_sessions_peak` y el mínimo de `closed_sessions`.

Fixture versionado:
[`src/lib/lan-lab/fixtures/lightweight-level-5.valid.json`](src/lib/lan-lab/fixtures/lightweight-level-5.valid.json).
El test parametrizado valida la misma forma con niveles 5, 10 y 25.

## Implementación y regresiones

- Export player: `src/lib/lan-lab/player-evidence.ts`.
- Export carga: `src/lib/lan-lab/load-generator.ts`.
- Máquina de armado: `src/lib/lan-lab/wifi-recovery.ts`.
- Validador de `collect`: `scripts/validate-lan-evidence.mjs`.
- Contrato/fixtures adversariales: `src/lib/lan-lab/evidence-contract.test.ts`.
- Armado, pérdida, recuperación, rearmado, expiración y teardown:
  `src/lib/lan-lab/wifi-recovery.test.ts`.

Platform puede transformar estos campos a su TSV compuesto después de validar
este contrato cerrado, pero no debe presentar esa transformación como el JSON
fuente del navegador ni inventar campos ausentes.
