<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Task 11: revisión TP-OSS-SC de coste y supply chain del hito 100

Fecha de revisión: 2026-08-28

Estado: **ARTEFACTOS RECIBIDOS Y REVISADOS DIFERENCIALMENTE; HITO 100
BLOQUEADO POR GATES DE PUBLICACIÓN/CAPACIDAD; HITO 1.000 PROHIBIDO**

Esta es una revisión técnica, no asesoría legal. No autoriza contratar un
proveedor, crear recursos remotos, usar credenciales, publicar, cambiar el
producto ni extrapolar capacidad.

## Hallazgos primero

### Alta, resuelta — el commit inicial fijó un hash de runtime incorrecto

La evidencia temporal se conserva: en la inspección inicial de las 15:26 CEST
no existían `infra/virtual-nodes/` ni `control-plane/`; a las 15:31 apareció el
primer paquete de virtual-nodes; después cerraron los commits DCO
`51fc10b755090d0045397138f8f19cd98f8d8a82` y
`a541644a9a1127652414ca5dd911514c5b89f30b`. La afirmación anterior de
“ausentes” ya no describe el estado actual.

`git ls-tree -r --name-only` confirma que `versions.env` forma parte de
`51fc10b...` y que los cuatro perfiles `.env` forman parte de `a541644...`.
Aunque `.gitignore:13` coincide con sus nombres, un patrón ignore no elimina
paths ya tracked: un checkout limpio de esos commits sí los contiene. Se retira
el blocker preliminar de inventario Git.

El defecto real del commit `51fc10b...` está en
`infra/virtual-nodes/versions.env:6`: espera runtime SHA `591844...`, mientras
el `node-runtime.sh` comprometido produce `b91762...`. La evidencia PASS no es
reproducible desde ese commit. En el working tree existe una corrección local
que cambia el valor esperado a `b91762...`. El owner la cerró con DCO en
`85299072201564032480308b1ce90a4bebb2b552`; la comprobación independiente
posterior obtuvo expected = observed = `b91762...`, y adapter/policy/harness
volvieron a pasar. El PASS de `51fc10b...` aislado no se acepta, pero el blocker
queda resuelto en el snapshot final `8529907...`.

### Alta — falta integrar un límite autorizado por run/acción

El CLI del control-plane sí restringe su demo a `[10,25,50,100]` y rechaza
escenarios que alcancen `forbidden_execution_viewers=1000`
(`control-plane/src/teremoq_control/cli.py:36-37`); el harness también valida
perfiles 1..100 (`chaos/autoscaling/lib.sh:31-36`). Estos controles positivos
impiden que los comandos revisados ejecuten accidentalmente el perfil 1.000.

`infra/virtual-nodes/provider-adapter.sh:27-29,110,150,167-175` sólo exige que
`capacity` sea un entero sin signo. Esto no debe “corregirse” con un máximo
global 100: la arquitectura aprobada es configurable para futuros hitos
1k/10k/100k. Además, la configuración admite
`maximum_nodes=1000000` y capacidades por nodo de hasta 10.000.000
(`control-plane/config/milestone-100.json:15-18,25-29,35-51`), lo cual es
deliberado. Lo que falta es que cada acción consumida por el adapter lleve y
valide un capacity/budget envelope autorizado para ese run. Para el hito actual
ese envelope/configuración debe rechazar 101/1000; para futuros hitos podrá
cambiar sólo mediante la autorización correspondiente. El gate 100 está hoy
acotado al harness/CLI, no integrado en el boundary de proveedor.

### Media — la imagen ejecutable está fijada localmente, pero carece de SBOM/provenance cerrada

La referencia local
`teremoq-step7-lab:rust-1.93-full@sha256:ba076cf0a26aa41efdd2f0f80687ef97009d1526680751456c19cc944dff1d0b`
coincide con el ID y RepoDigest inspeccionados en este host. Compose usa
`pull_policy: never`, usuario `65532`, filesystem read-only, tmpfs limitado,
`cap_drop: ALL`, `no-new-privileges`, límites de PID/memoria/CPU, redes internas
y cero puertos publicados. Son controles positivos.

Sin embargo, es una imagen amplia del laboratorio Step 7, no una imagen mínima
de nodo virtual. Su history corresponde al Dockerfile
`gateway-rs/tests/lab/Dockerfile` SHA-256
`9a4419f66806e6b0b3af1d4c62591460bf73cc9b457d1faf8c0afce15ead0bc6`,
con base Rust fijada, paquetes Debian versionados y checkout GStreamer fijado.
También contiene FFmpeg, GStreamer base/bad/good y herramientas de desarrollo.
El build usa `apt-get update` y un `git clone`, sin snapshot de repositorio de
paquetes ni provenance verificable.

No hay SBOM versionado junto al harness. El plugin local `docker-sbom 0.6.0`
(Syft 0.43.0) no produjo resultado dentro de dos ventanas de 30 segundos, por
lo que no se afirma un pase. Sin inventario de paquetes/licencias no puede
declararse compatibilidad de la imagen completa con la política Apache-2.0.
El uso interno no relicencia FFmpeg, GStreamer, Debian ni Rust.

### Media — el digest del control-plane es sólo un identificador sintético

`control-plane/config/milestone-100.json:4` y
`control-plane/reports/task-09/milestone-100.json:137` registran
`sha256:07265afe...`, que no corresponde a ninguna imagen local inspeccionable.
El simulador nunca ejecuta esa imagen y el informe dice correctamente que no
crea capacidad real; por tanto no es un secreto ni una sustitución remota. Sin
embargo, llamarlo `image_digest` no demuestra procedencia de un artefacto. El
único OCI local demostrado es el de Task 10, `sha256:ba076c...`, cuyo ID y
RepoDigest coinciden. El control-plane debe etiquetar inequívocamente su valor
como fixture/identificador o enlazarlo a un OCI inventariado antes de usarlo
como evidencia supply-chain.

### Media — los JSON Schemas no expresan todos los límites aplicados por código

`control-plane/contracts/metrics-sample.schema.json:12-28` no fija máximos para
secuencia, espectadores, sesiones, egress ni `maxItems` para reservas;
`control-plane/contracts/desired-state.schema.json:11,19-22` tampoco fija
máximos de generación/nodos. El loader y reconciler sí aplican varios límites,
incluido `maximum_reservations_per_sample` en
`control-plane/src/teremoq_control/engine.py:219-272`. Un consumidor que valide
sólo el contrato JSON aceptaría cargas que después serán rechazadas o que puede
intentar materializar en memoria. Owner `TP-CONTROL-AUTOSCALE`; se requiere
alinear schema y límites efectivos antes de presentar estos contratos como
boundary de integración.

### Media — los parámetros de egress son supuestos, no mediciones del hito

El report publicable separa correctamente “remote infrastructure cost = 0” de
la estimación externa ausente, y declara que no prueba vídeo real. No obstante,
`control-plane/config/milestone-100.json:91,101-102` usa `rate_source` =
`local-simulation-measured` junto a `0.8 Mbit/s` por espectador y 8 % de
overhead. Esos dos valores alimentan los 38,88 GB calculados del report
(`control-plane/reports/task-09/milestone-100.json:73-92`) pero no fueron
medidos por transporte/media. Deben denominarse parámetros/fixtures y no cerrar
`b` ni `o`; el coste cloud sigue sin poder calcularse hasta medir egress real.

### Baja — Python no añade runtime deps, pero no hay build backend declarado

`control-plane/pyproject.toml:3-11` declara `dependencies=[]` y el análisis AST
de source/tests sólo encontró stdlib e imports internos. No existe requirements,
lock ni proveedor SDK. Tampoco hay `[build-system]`; esto es aceptable para la
ejecución install-free revisada, pero no demuestra un sdist/wheel reproducible.
Si se distribuye como paquete Python deberá fijarse y auditarse el backend o
declararse expresamente que no es artefacto de distribución.

### Informativa — licencia, tests y escaneo focal pasan

REUSE 5.1.1 pasó el checkout compartido 282/282 y el aislado 290/290 en el
snapshot final. Gitleaks 8.30.1 con redacción 100 %, sin red y mounts
read-only escaneó 29,95 KB (virtual-nodes), 205,55 KB (Chaos) y 165,80 KB
(control-plane), sin leaks. La búsqueda complementaria no halló claves, PEM
privado, credenciales, URLs autenticadas, namespaces productivos ni rutas
locales persistidas. No se muestran valores sensibles.

Pasaron JSON/TOML con Python 3.14.4, `bash -n`, adapter-test,
compose-policy-test, los cuatro perfiles del harness y 36 tests del
control-plane. `control-plane/reports/task-09/SHA256SUMS` verificó 30/30
entradas. Los reports ignorados bajo `reports/latest/` quedaron fuera de la
frontera publicable y estaban desfasados; no deben confundirse con la evidencia
versionada `reports/task-09/`. No había `shellcheck` ni validador Markdown/link
local instalado.

### Alta — la simulación no convierte 100 espectadores en capacidad real

No se ha medido aún el bitrate agregado de todos los Tracks, retransmisiones,
overhead QUIC/IP, capacidad por nodo, tiempo de warm-up, cooldown ni reserva.
Sin esas variables no se puede decidir si una VM pequeña sostiene 10, 25, 50 o
100 espectadores. Las opciones de proveedor de este informe son referencias
de tarifa, no configuraciones recomendadas ni benchmarks equivalentes.

La variable crítica que falta es `K`, espectadores sostenibles por nodo bajo el
perfil real y sus percentiles de CPU, memoria, red y pérdidas. La segunda es
`b*o`, bitrate efectivo saliente por espectador incluido el overhead medido.
Ambas sólo pueden cerrarse después de las pruebas 10/25/50/100.

### Alta — el coste de egress no puede estimarse sólo con el precio de la VM

Una hora de salida por cada `1 Mbit/s` efectivo consume aproximadamente
`0,439453 GiB` por espectador. A 100 espectadores son `43,9453 GiB` por cada
`1 Mbit/s` y hora; a 1.000, diez veces más. El bitrate real no se sustituye por
un supuesto de marketing.

Además, los proveedores contabilizan la franquicia de forma diferente:

- DigitalOcean prorratea la franquicia por los segundos de vida de los
  Droplets dentro de un ciclo de 28 días y agrupa el saldo por team.
- Lightsail agrega la franquicia por bundle y región; entrada y salida consumen
  franquicia, aunque sólo el exceso de salida se factura.
- Hetzner cuenta tráfico saliente por mes natural y factura el exceso en
  bloques de 100 MB.

Por ello no se publica un único número “por espectador” sin duración, ciclo de
facturación y saldo de franquicia.

### Media — coste remoto de esta revisión es cero, no coste local total cero

Esta Task no creó recursos remotos, no usó credenciales y no ejecutó comandos
de proveedor. El coste remoto medido atribuible a esta revisión local es
exactamente `0` en todas las monedas.

No se midieron electricidad, amortización del host, refrigeración, red local,
tiempo humano ni coste del hardware. Por tanto no se afirma que el coste local
total sea cero. Las tablas cloud son estimaciones parametrizadas de tarifa
pública: no son factura, quote, benchmark ni compromiso de capacidad.

### Media — 1.000 espectadores carece de autorización y de un kill switch de coste

El hito 1.000 queda bloqueado aunque el de 100 pase. Requiere una decisión
separada por su impacto de coste/capacidad, límites máximos de nodos y egress,
presupuesto, alertas, apagado automático, antifraude, prueba progresiva y
autorización expresa antes de cualquier recurso remoto. Extrapolar linealmente
la prueba 100 no es evidencia.

## Snapshot local diferencial y límites

| Evidencia | Resultado |
| --- | --- |
| `.cursorrules` | SHA-256 `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2`; 488 líneas leídas completas |
| Git inicial | rama `main`, HEAD `0faee5dec127e47649a08b82bade8f3faf69c8ab` |
| Git compartido intermedio | rama `main`, HEAD `997fb38ecdf339bdb65fde03b3302d876d284876` antes de los commits propietarios |
| Git compartido final | rama `main`, HEAD `85299072201564032480308b1ce90a4bebb2b552`, tree `50676b3838d056543465f33a71d8d521e4059cc9` |
| Worktree aislado control-plane final | commit `77c1c9fadc60235f2dd3e39dbf81c49f3b141a51`, parent `547d379fbc3fc28ef1029e77bdf3cbb45dc5140c`, tree `9ed18aba2e6023e0fbac97b8960d6da8e3b24152` |
| Estado Git | árbol sucio con cambios ajenos; ninguno fue revertido, modificado ni incluido |
| `infra/virtual-nodes/` | ausente inicialmente; 10 paths tracked finales, incluido `versions.env` |
| `chaos/autoscaling/` | 12 paths tracked finales, incluidos cuatro perfiles `.env`; 10 reports locales ignorados adicionales |
| `control-plane/` | ausente inicialmente; 31 paths tracked finales más 3 artefactos ignorados en `reports/latest/` |
| Directorio propiedad de esta revisión | sólo `docs/capacity-reviews/` |
| Recursos/servicios remotos creados | ninguno |
| Credenciales usadas | ninguna |

Inventario agregado del snapshot final. `pathset` es SHA-256 de paths relativos
ordenados con newline; `inventory` es SHA-256 del listado ordenado
`sha256  path`:

| Alcance | Paths | Pathset SHA-256 | Inventory SHA-256 |
| --- | ---: | --- | --- |
| virtual-nodes, tree `8529907...` | 10 | `99085f1f7e08d6ecc8ddb2e114cb6523b75e809b6e9ea8e3539ca5c8cd56d981` | `89f5d3e183557ee571d05828e0a1cd3a363a029d45198f5d7289b280920bfe93` |
| Chaos, tree `8529907...` | 12 | `eeb4d76ac662cbf5fc56c9bcb4fbdd4f063a9866e29fc2b7a2857110d5f8fe3f` | `480f800bc0d75101a5f6bff8626ea2b2268c0a5d879f355ad07847da223e5701` |
| control-plane, tree `77c1c9f...` | 31 | `a44c7535da0d56fa28fda666e2e4d5de5f25e527d71aee2c0d42b84173199daa` | `0656030ea147c84aba6c45346b842cdce186cbc344773f79b5aeab841f6e52c7` |

Hashes de objetos supply-chain clave:

| Path/objeto | SHA-256 |
| --- | --- |
| `infra/virtual-nodes/compose.yaml` | `54297506f61e04463bba4621c23c79e7da059a78b2b80f8473383fa5951c3609` |
| `infra/virtual-nodes/node-runtime.sh` | `b91762fb91e3cde47fdcb320b8bc30cb2ba4aab15743dc143b849b78cef0da29` |
| `infra/virtual-nodes/provider-adapter.sh` | `0b990cec57ce4dd49aac355352caff5db72addcdcc8d24e7b038bf9b22efa3c7` |
| `infra/virtual-nodes/topology/default.tsv` | `31e86aff182fe29ceae8016689f4d426ae22891e34a9dea0f2e0533bb4fd9499` |
| `infra/virtual-nodes/versions.env` | `8e93495b3a411e880cd0e00549dc8eb68e0bb80746d2510b85dfe18ceb1c7787` |
| `chaos/autoscaling/evidence/task10-local-validation-2026-08.md` | `09c59e0fffd8bb098e566cd667dd3b952ad4f6d181da8d0890332ba38f16c108` |
| imagen local inspeccionada | `ba076cf0a26aa41efdd2f0f80687ef97009d1526680751456c19cc944dff1d0b` |
| Dockerfile asociado por history | `9a4419f66806e6b0b3af1d4c62591460bf73cc9b457d1faf8c0afce15ead0bc6` |
| `control-plane/pyproject.toml` | `82b1bd0e1ce5648d2c0db719d0ddf58a71e1c1345b34b34377942c5dda3b9575` |
| `control-plane/config/milestone-100.json` | `a42d1c109560a9424955e2824c5d913f6ce1274b160aac31f461590d2376c6c1` |
| `control-plane/reports/task-09/SHA256SUMS` | `9c140e05aa4b4fcc746e8285c1699cec6484ee17cce3f81d667921ed419f49ff` |

El adapter y el control-plane cambiaron durante la revisión; los hashes de esta
sección sustituyen los preliminares. La congelación final fue 2026-08-28
16:06:09 CEST y se revalidó sin divergencia. Cualquier cambio posterior requiere
nueva revisión y nunca debe normalizarse silenciosamente.

La ausencia de consultas autenticadas impide demostrar que una cuenta cloud
externa no contenga recursos preexistentes. La evidencia “cero recursos
remotos” exigida al hito debe proceder del ledger local del harness y, si en el
futuro se autoriza un proveedor, de una consulta read-only autorizada y
redactada. Este informe sólo demuestra que esta revisión no creó ninguno.

## Tarifas públicas oficiales consultadas

Fecha de consulta de todas las fuentes: 2026-08-28. No se aplican créditos,
free tiers, compromisos, reservas financieras ni promociones. Las monedas no se
convierten entre sí. Cuando la página no expresa impuestos, el modelo los
excluye y obliga a confirmarlos en la jurisdicción de facturación.

### Opción A — DigitalOcean, `FRA1`, USD

Referencia: Basic Droplet Regular, `1 vCPU`, `1 GiB RAM`, `25 GiB SSD`,
`1.000 GiB` de transferencia saliente mensual listada:

- cómputo: `0,00893 USD/h`, con tope `6 USD/mes`;
- almacenamiento mínimo: `25 GiB SSD` incluido, sin add-on;
- entrada: gratuita;
- exceso de salida: `0,01 USD/GiB`;
- franquicia: acumulada por segundo, redondeo mínimo de facturación de 60
  segundos, ciclo/tope de 2.419.200 segundos (28 días), pool por team y sin
  rollover;
- región modelada: Frankfurt `FRA1`; la documentación indica que el precio de
  bandwidth no varía por región;
- impuestos: no indicados en las páginas de tarifa consultadas; estimación sin
  impuestos.

Fuentes oficiales:

- https://www.digitalocean.com/pricing/droplets
- https://docs.digitalocean.com/products/droplets/details/pricing/
- https://docs.digitalocean.com/platform/billing/bandwidth/

La página de pricing de Droplets fue verificada por el proveedor el
2026-08-25; la de bandwidth, el 2026-07-13.

### Opción B — Hetzner Cloud, Nuremberg `NBG`, EUR o USD

Referencia: Cloud Server compartido `CX23`, `2 vCPU`, `4 GB RAM`, `40 GB` de
disco local, en Alemania:

- cómputo: `0,0088 EUR/h`, tope `5,49 EUR/mes`, o la lista alternativa
  `0,0104 USD/h`, tope `6,49 USD/mes`;
- almacenamiento mínimo: `40 GB` incluido, sin Volume adicional;
- tráfico saliente incluido en EU para CX: `20 TB/mes natural`;
- exceso: `1 EUR/TB` o `1,20 USD/TB`, en bloques de 100 MB;
- entrada y tráfico interno: gratuitos según la definición oficial;
- IPv4 primaria: excluida del precio de servidor y facturada separadamente; no
  se modela hasta fijar IPv6-only o el precio exacto de IPv4;
- impuestos: la tabla internacional declara precios sin VAT; la lista alemana
  separada incluye 19 % VAT. Este modelo usa la lista internacional sin VAT.

Fuentes oficiales:

- https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/
- https://www.hetzner.com/cloud/cost-optimized/
- https://docs.hetzner.com/robot/general/traffic/
- https://docs.hetzner.com/cloud/billing/faq/

La tarifa entró en vigor el 2026-06-15 y la página tuvo su último cambio el
2026-07-08. La página de tráfico muestra último cambio 2024-05-21.

### Opción C — AWS Lightsail, España `eu-south-2`, USD

Referencia: Linux/Unix Nano con IPv4 pública, `2 vCPU`, `0,5 GB RAM`, `20 GB
SSD`, `1 TB` de transferencia:

- cómputo: desde `0,0067 USD/h`, con tope `5 USD/mes` para el bundle mínimo;
- almacenamiento mínimo: `20 GB SSD` incluido;
- almacenamiento de bloque opcional, no necesario para el mínimo: desde 8 GB
  a `0,10 USD/GB-mes`;
- entrada y salida consumen la franquicia; una vez agotada, sólo se factura el
  exceso de salida;
- exceso de salida en España `eu-south-2`: `0,12 USD/GB`;
- transferencia privada a recursos Lightsail/AWS de la misma región puede ser
  gratuita bajo las condiciones oficiales, pero no representa tráfico a
  espectadores de Internet;
- impuestos: no indicados en las páginas de tarifa consultadas; estimación sin
  impuestos.

Fuentes oficiales:

- https://aws.amazon.com/lightsail/pricing/
- https://docs.aws.amazon.com/lightsail/latest/userguide/amazon-lightsail-bundles.html
- https://docs.aws.amazon.com/lightsail/latest/userguide/amazon-lightsail-faq-data-transfer-allowance.html
- https://aws.amazon.com/lightsail/faq/

Las páginas oficiales no muestran una fecha de revisión editorial; los valores
fueron consultados directamente el 2026-08-28.

### Comparabilidad limitada

| Opción | CPU/RAM | Disco incluido | Franquicia listada | Exceso público | Límite de evidencia |
| --- | --- | ---: | ---: | ---: | --- |
| DO FRA1 | 1 vCPU / 1 GiB | 25 GiB | 1.000 GiB, prorrateada | 0,01 USD/GiB | CPU compartida; capacidad de relay no medida |
| Hetzner NBG | 2 vCPU / 4 GB | 40 GB | 20 TB salientes/mes | 1 EUR/TB o 1,20 USD/TB | IPv4 separada; capacidad de relay no medida |
| AWS España | 2 vCPU / 0,5 GB | 20 GB | 1 TB entrada+salida | 0,12 USD/GB | RAM mínima y CPU burst; capacidad de relay no medida |

GB/TB decimales y GiB binarios no son intercambiables. El cálculo final debe
usar la unidad exacta del contador/factura del proveedor y conservar los
factores de conversión; esta tabla no los normaliza para aparentar precisión.

## Modelo parametrizado

Variables:

- `b`: bitrate de media medido por espectador, en Mbit/s, todos los Tracks;
- `o`: multiplicador medido de overhead/retransmisión, `>= 1`;
- `C`: concurrencia real de espectadores;
- `r`: reserva de capacidad como fracción, por ejemplo `0,20`, no fijada aún;
- `T`: duración efectiva de entrega, horas;
- `K`: espectadores sostenibles por nodo, medidos con los gates de calidad;
- `H_i`: horas facturables del nodo `i`, incluyendo warm-up y cooldown;
- `P_h`, `P_m`: tarifa horaria y tope mensual por nodo;
- `A_eff`: franquicia efectiva del ciclo, tras reglas de prorrateo/pooling;
- `I`: entrada que consume franquicia en el proveedor, en su unidad de factura;
- `P_e`: precio de exceso de egress por unidad; y
- `S_extra`, `P_s`: almacenamiento adicional y su tarifa, cero para el mínimo
  incluido de estas tres referencias.

Capacidad reservada y nodos:

```text
C_reservada = ceil(C * (1 + r))
N = ceil(C_reservada / K)
```

Egress real en GiB, cuando `b` usa Mbit/s decimal:

```text
G_out = 0,439453125 * b * o * C * T
G_out_presupuestado = 0,439453125 * b * o * C_reservada * T
```

La reserva aumenta capacidad de cómputo. Sólo se usa para egress presupuestado
si se quiere cubrir la llegada efectiva de esos espectadores; no se factura
tráfico de espectadores inexistentes.

Coste:

```text
Coste_compute = sum_i(min(P_m, P_h * H_i))
Uso_medido = meter_proveedor(G_out, I)
Coste_egress = max(0, Uso_medido - A_eff) * P_e
Coste_storage = S_extra * P_s
Coste_total = Coste_compute + Coste_egress + Coste_storage + otros_confirmados
Coste_por_hora = Coste_total / T
Coste_por_espectador_evento = Coste_total / C
Coste_por_espectador_hora = Coste_total / (C * T)
```

Para DigitalOcean, si no hay otros Droplets en el pool, una aproximación
documentada de franquicia es `A_eff = A_mes * segundos_activos / 2.419.200`.
Para AWS debe restarse también la entrada que consuma franquicia y agregar sólo
bundles iguales en la misma región. Para Hetzner debe conservarse el contador
de mes natural y el redondeo de 100 MB. El cálculo final debe usar el ledger
real, no asumir que toda franquicia mensual está disponible para una prueba
corta.

Variables que sólo cierra el hito 100:

- `b` por perfil real y mezcla de Tracks, p50/p95/p99 y máximo;
- `o`, retransmisiones y bytes realmente contabilizados por el proveedor;
- `K` con CPU, memoria, red, colas y latencia dentro de límites;
- `r`, warm-up, cooldown, tiempo de creación y margen de fallo;
- cantidad y vida de nodos durante scale-out/scale-in;
- entrada computable y franquicia ya consumida del ciclo;
- almacenamiento/logs/SBOM temporales y política de retención; y
- IPv4, balanceador, DNS, snapshots, observabilidad, impuestos y soporte si
  finalmente fueran necesarios.

## Checklist supply-chain previo a revisar artefactos

Estado aplicado al snapshot recibido: hardening Compose, sintaxis, tests
locales, SPDX/REUSE, manifiesto de evidencia Task 09 y secret scan pasan;
SBOM/provenance, licencia completa de imagen, alineación de schemas y envelope
autorizado del run fallan o quedan incompletos. El pin/runtime ya fue corregido.

### Imágenes

- repositorio oficial y owner exactos;
- referencia por digest completo `sha256:...`; tag sólo como dato descriptivo,
  nunca `latest`, rama flotante o tag mutable como identidad;
- arquitectura/OS exactos, fecha y manifest multiarch;
- licencia de imagen/base y de cada componente redistribuido;
- SBOM SPDX o CycloneDX y relación entre imagen, source commit y build;
- firma/provenance cuando exista, sin sustituir digest por firma;
- usuario no root, filesystem read-only cuando aplique, capabilities mínimas,
  sin socket Docker, modo privileged ni mounts de trust material;
- escaneo de vulnerabilidades contra DB fijada y sin suppressions anónimas; y
- política de actualización/rollback y digest anterior conocido.

### Herramientas

- nombre, upstream oficial, versión/commit, checksum/digest y licencia;
- instalación fuera del artefacto o dependencia declarada/reproducible;
- ninguna descarga dinámica durante test y ningún `curl | sh`;
- compatibilidad con Ubuntu/WSL2 y toolchain fijado;
- formato de salida versionado, límites y reloj/unidades explícitos; y
- finalidad concreta: simulación, carga, SBOM, escaneo o cleanup.

### Formats y secretos

- JSON/YAML/TOML sintácticamente válido y schema/version explícito;
- ninguna credencial, token, cookie, clave, certificado, `.env`, endpoint de
  cliente, namespace productivo, identidad SPIFFE real o dato operativo;
- secretos sólo por referencias abstractas a un mecanismo futuro autorizado;
- ejemplos con valores sintéticos inequívocos y sin aspecto productivo;
- logs redactados que no publiquen payloads, peer identity o URLs autenticadas;
- límites para arrays, nodos, espectadores, strings, eventos y retención; y
- inventario de ficheros generados, temporales y excluidos del paquete.

## Gates del hito local

### Gate común antes de 10

- snapshot Git y pathset congelados, stage/working tree diferenciados;
- inventario completo de imágenes/herramientas/formats y licencias;
- todos los digests inmutables y SBOMs disponibles;
- escaneo redactado de secretos sin hallazgo productivo;
- configuración local fail-closed con capacity/budget envelope del hito
  `<= 100`;
- red sin credenciales ni endpoints cloud y ledger remoto inicial vacío;
- comando de cleanup idempotente probado en dry-run; y
- presupuesto parametrizado con las variables aún desconocidas marcadas.

### Prueba 10 — smoke y contabilidad

- 10 espectadores virtuales durante una duración declarada;
- bytes entrada/salida, bitrate, CPU, memoria, errores y coste local remoto `0`;
- creación/registro/heartbeat/terminación de cada nodo;
- cero huérfanos tras cleanup y segundo cleanup sin cambios; y
- mismo inventario de imágenes/digests antes y después.

### Prueba 25 — primer scale-out

- 25 espectadores y evidencia del umbral exacto que dispara scale-out;
- cooldown/histeresis observables, sin oscilación ni doble creación;
- reserva y máximo de nodos respetados;
- fallo de un nodo aislado y reconciliación acotada; y
- cleanup completo con puertos, procesos, redes, volúmenes y temporales vacíos.

### Prueba 50 — estado sostenido y scale-in

- 50 espectadores, duración suficiente para al menos un ciclo de cooldown;
- scale-in sin cortar sesiones ajenas ni conservar nodos ociosos;
- percentiles de bitrate, recursos, latencia de control y errores;
- ledger coste/egress generado desde contadores reales; y
- repetición determinista con hashes de evidencia.

### Prueba 100 — gate de entrega local

- 100 espectadores más la reserva aprobada, sin superar el envelope autorizado
  del run actual ni crear recursos remotos;
- `K`, `b`, `o`, warm-up y cooldown medidos; no extrapolados;
- comportamiento ante saturación y rechazo fail-closed del espectador 101;
- ausencia de crecimiento sostenido, tasks/procesos/contenedores huérfanos y
  leaks de puertos/red/volúmenes;
- SBOM, digest, inventario, logs y reporte de coste ligados al mismo run ID;
- cleanup y reconciliación final a cero verificados por dos inspecciones;
- coste cloud recalculado con tarifas fechadas, sin presentarlo como factura; y
- revisión independiente de `TP-PLATFORM-CHAOS`, `TP-CONTROL-AUTOSCALE` y
  `TP-OSS-SC` sobre el snapshot exacto.

### Bloqueo explícito de 1.000

No existe un gate automático de 100 a 1.000. El run y el capacity/budget
envelope del hito actual deben fallar cerrados ante `>100`; esto no impone un
techo arquitectónico permanente. Para abrir un futuro diseño de 1.000 se
requieren:

1. autorización de alto impacto del usuario para coste e infraestructura;
2. presupuesto máximo por hora/evento y kill switch independiente;
3. pruebas intermedias y capacidad por región/nodo demostrada;
4. cuotas, antifraude, rate limits y egress caps;
5. estrategia multi-region, fallo parcial y rollback;
6. tratamiento de impuestos, soporte, IPv4/LB/DNS/observabilidad; y
7. nueva revisión supply-chain y de privacidad antes de credenciales.

## Defectos a devolver al Master

| Severidad | Referencia | Defecto | Gate |
| --- | --- | --- | --- |
| Alta, resuelta | commit `51fc10b...`, `infra/virtual-nodes/versions.env:6` frente a `node-runtime.sh` | Esperaba `591844...` frente a runtime `b91762...`; `8529907...` sincroniza el pin y revalida | No bloquea el snapshot final; no aceptar el commit inicial aislado |
| Alta | `infra/virtual-nodes/provider-adapter.sh:27-29,110,150,167-175` y contrato v1 | Capacity no consume ni valida un capacity/budget envelope autorizado por run/acción | Bloquea integrar el gate 100; no exige techo arquitectónico global |
| Media | imagen fijada en `versions.env:4` | Digest local coincide, pero no hay SBOM/provenance/licencias cerradas | Bloquea supply-chain 100 |
| Media | `control-plane/config/milestone-100.json:4`; report `:137` | El image digest es un identificador sintético no presente localmente; no prueba procedencia OCI | Bloquea usarlo como evidencia de artefacto |
| Media | `control-plane/contracts/metrics-sample.schema.json:12-28`; `desired-state.schema.json:11,19-22` | Los schemas no expresan máximos/cardinalidad que el código espera aplicar | Bloquea contrato de integración cerrado |
| Media | `control-plane/config/milestone-100.json:91,101-102`; report `:73-92` | 0,8 Mbit/s y 8 % son fixtures bajo un `rate_source` que puede confundirse con medición | Bloquea cerrar bitrate/egress/coste cloud |
| Baja | `control-plane/pyproject.toml:3-11` | Cero deps runtime externas, pero no hay build backend fijado | Sólo bloquea distribución Python, no ejecución install-free |
| Alta | evidencia de capacidad, ausente | `K`, `b`, `o`, reserva y cooldown no medidos | Bloquea coste por espectador y 100 |
| Media | ledger remoto, ausente | No puede probarse ausencia global de recursos fuera de esta Task | Bloquea cualquier claim de cuenta limpia |

`git ls-tree` demuestra que `versions.env` y los cuatro perfiles `.env` están
tracked en `51fc10b...`/`a541644...`; el patrón genérico `.gitignore` no los
elimina del checkout y no se reporta como blocker.

Task 09 cerró primero `547d379fbc3fc28ef1029e77bdf3cbb45dc5140c` y
después el hardening `77c1c9fadc60235f2dd3e39dbf81c49f3b141a51`.
Los commits de Plataforma/Chaos `51fc10b...`, `a541644...`, `8529907...` y ambos
commits Task 09 tienen autor/committer autorizado y el `Signed-off-by` exacto.
Esto satisface DCO local, sin autorizar push/publicación. Los findings pendientes
se remiten a sus owners y no se corrigen desde `docs/capacity-reviews/`.

## Validación documental y limitaciones

Validadores que deben ejecutarse sobre este informe antes del commit:

```bash
git diff --no-index --check /dev/null \
  docs/capacity-reviews/task-11-tp-oss-sc-capacity-cost-review-2026-08.md
rg -n 'TO[D]O|TB[D]|PLACEH[O]LDER|FIXM[E]' \
  docs/capacity-reviews/task-11-tp-oss-sc-capacity-cost-review-2026-08.md
git diff --check
```

Los enlaces oficiales se abrieron y contrastaron el 2026-08-28. No se usó un
buscador secundario como fuente de precio. No hay un validador Markdown/link
local aprobado inventariado todavía; si no está instalado, no se instalará para
esta Task y el gate se declarará limitado.

Herramientas locales: Bash 5.3.9, Python 3.14.4, Docker 28.3.3,
Compose 2.39.2, `docker-sbom 0.6.0`/Syft 0.43.0, REUSE 5.1.1 por digest
`sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da`
y Gitleaks 8.30.1 por digest
`sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f`.
REUSE y Gitleaks se ejecutaron sin red y con el source montado read-only.

No se ejecutó carga real ni Compose smoke en esta revisión. Sí se ejecutaron la
simulación pura 10/25/50/100, los tests de adapter/policy y 36 tests del
control-plane. Es evidencia de estado/control, no de viewer transport. No hay
SBOM final ni se afirma compatibilidad Apache-2.0 de la imagen completa. No se
consultaron facturas, cuotas ni cuentas de proveedor. Los precios pueden
cambiar y deben reconfirmarse antes de una decisión económica.

## Decisión

- **Coste local remoto medido por esta revisión: 0.** Electricidad/hardware y
  coste local total: no medidos.
- **Estimación cloud:** sólo fórmula parametrizada con tarifas públicas
  fechadas; no factura ni benchmark.
- **Supply chain:** virtual-nodes, Chaos y control-plane revisados con blockers
  de frontera publicable, SBOM/provenance, schema y claims.
- **Hito 100:** bloqueado hasta que pasen inventario, digests, SBOM, pruebas
  10/25/50/100, cleanup y reconciliación a cero.
- **Hito 1.000:** bloqueado explícitamente y requiere nueva autorización.

**LOCAL REVIEW ONLY / NO CLOUD RESOURCE / NO CREDENTIAL / NO PUBLICATION**

## Revisión diferencial final de la integración local de autoescalado

Fecha de congelación y revisión: 2026-08-28. Esta sección es histórica y
acumulativa: conserva los hallazgos anteriores y actualiza su estado únicamente
para los commits lineales 02cceece652090790dd731f23dd9df28c3036892 y
4aabe8d5a5f76d52f6d538de777cbc3b553f82dd, aplicados sobre Task 09 hasta
d6f968c3c46802f10b0246808f0afb252fcb6b69.

### Hallazgos diferenciales

#### Alta, resuelta para la integración local — capacity/budget envelope consumido

El hallazgo anterior sobre la ausencia de un límite autorizado por run queda
resuelto para este hito local. infra/virtual-nodes/action-envelope-consumer.py:
69-125 carga la configuración real de Task 09, exige que viewers coincida
exactamente con milestone.gate_viewers, valida deployment, partition, config e
image digest, tier, placement, capacidad de espectadores y egress, y deadline
antes de invocar el adapter. En la configuración congelada el gate es 100; las
ejecuciones 101 y 1.000 fallaron con código 2. Esto no introduce un máximo
arquitectónico: una configuración futura autorizada podría definir otro
envelope.

El adapter vuelve a comprobar el contexto de action, enum, generation,
idempotency, config/image digest, capacity pair y lifecycle en
infra/virtual-nodes/provider-adapter.sh:155-180,218-239,320-400. Las acciones
create/destroy del envelope usan el enum de Task 09; sessions, stop-admit, fail
y drain son transiciones locales directas y acotadas del adapter. No se añadió
un provider SDK, transporte remoto ni una segunda definición del schema.

#### Media, resuelta para el laboratorio — fixture y OCI ya no se confunden

infra/virtual-nodes/contract/v1/image-map.tsv:4 separa explícitamente el
identificador sintético de Task 09, sha256:07265afe..., del OCI local
teremoq-step7-lab:rust-1.93-full@sha256:ba076cf0... y su image ID.
chaos/autoscaling/run-integrated.sh:16-61 fija el subtree de control-plane, el
hash del fichero de configuración y exige un único mapping que coincida con
versions.env antes de tocar Docker. La inspección local obtuvo image ID y
RepoDigest sha256:ba076cf0...; pull_policy sigue siendo never.

La imagen continúa siendo un artefacto amplio de laboratorio, no un producto.
Su label source apunta al repositorio oficial rust-lang/docker-rust, es
linux/amd64 y el Dockerfile asociado conserva SHA-256
9a4419f66806e6b0b3af1d4c62591460bf73cc9b457d1faf8c0afce15ead0bc6.
No existe todavía un SBOM/provenance/licencia cerrada de todos sus paquetes.
Esta limitación no bloquea integrar el simulador local ya inventariado, pero sí
bloquea redistribuir la imagen, usarla como OCI de desired state o presentarla
como supply chain de producción.

#### Media, resuelta — contratos y límites de Task 09 consumidos sin duplicación

El commit d6f968c3c46802f10b0246808f0afb252fcb6b69 ya contiene los contratos
versionados y los límites de payload, acciones, registry, espectadores,
reservas, nodos y coste. El consumer importa loader, ActionEnvelopeGuard, Tier
y Placement desde control-plane/src; su análisis AST no encontró dependencias
externas. control-plane/pyproject.toml:8 conserva dependencies = [] y las 36
entradas de reports/task-09/SHA256SUMS verificaron OK. Los 47 tests de Task 09,
incluidos bounds de schemas, antifraude, capacity y lifecycle, pasaron.

#### Baja, limitación honesta — apply operacional no es atómico

La validación semántica del conjunto seleccionado es atómica y ocurre antes de
la primera subprocess. Una caída operacional posterior puede dejar acciones
anteriores aplicadas. El código no oculta esa condición:
infra/virtual-nodes/action-envelope-consumer.py:127-190 devuelve
action_envelope_partial_apply, status partial_apply, exit 3, resultados ya
aplicados y cleanup_required. El contrato lo declara en
infra/virtual-nodes/contract/v1/provider-adapter.md:70-80 y el test focal cubre
cleanup. Es aceptable para este harness efímero; un provider real requerirá una
estrategia autorizada de compensación/reconciliación.

#### Informativa — fencing, idempotencia, request IDs y lifecycle pasan

Los commits preservan request IDs acotados, idempotency keys completas, registro
limitado, config/image fencing, generación monotónica por partition y rechazo de
generation stale. Un replay exacto resulta unchanged/idempotent_replay. El
destroy falla antes de stop-admit, cero assignments y drain_ack; el flujo
integrado observó expresamente destroy_requires_drain_ack antes de completar la
secuencia válida. Las operaciones y reasons son enums cerrados; no se usan
strings de error como resultado exitoso.

El request ID derivado usa un label validado de 1 a 32 caracteres y un fragmento
de la idempotency key, con máximo documentado de 51 caracteres frente al límite
63 del adapter. La identidad idempotente efectiva sigue siendo la key SHA-256
completa, no el request ID abreviado.

#### Informativa — sin dependencia Python, secreto, endpoint ni puerto remoto

El consumer usa únicamente stdlib y módulos internos. El inventario AST no
encontró import roots externos y no cambió ningún manifest o lock. Gitleaks
8.30.1, redacción 100 %, sin red y source read-only obtuvo cero findings en
infra/virtual-nodes (67.532 bytes), chaos/autoscaling (73.799 bytes) y
control-plane (372.257 bytes). La búsqueda complementaria no halló rutas
/home o /Users, claves privadas, URLs autenticadas, credenciales, identidades o
namespaces productivos.

El harness crea sólo redes Docker internal, no publica puertos y verifica
PortBindings vacío en chaos/autoscaling/run-integrated.sh:415-420. El cleanup
está acotado por labels de run, es idempotente y el estado final read-only del
host mostró cero contenedores, cero redes y cero volúmenes con label Task 10.
No se creó ni consultó ningún recurso cloud.

### Resultado funcional observado y límites no productivos

Se acepta como evidencia owner local, ligada al fichero
chaos/autoscaling/evidence/task10-integrated-100-validation-2026-08.md
SHA-256 2f7016bf69cae18cb6a9e8f12d637df3baa12bb1fe5d8ae7267c2ac99c26c203:

- perfiles 10, 25, 50 y 100: PASS en el harness determinista;
- topología integrada control/bootstrap/scale-out/replacement: 1/3/4/4;
- 100 assignments simuladas recuperadas después del replacement;
- cero pérdidas simuladas;
- replacement: una única muestra de 11.710 ms;
- cleanup Master: 0 contenedores, 0 redes y 0 volúmenes.

Estos valores no representan espectadores reales. Las sesiones y espectadores
son contadores; no hubo vídeo, MoQT, bitrate, retransmisión, PKI, registro,
player ni tráfico a Internet. La muestra de 11.710 ms incluye sólo el flujo
local container/state y no es SLO. No se midieron K, b, overhead o, consumo
eléctrico, amortización, red local ni coste humano. Por tanto:

- coste remoto medido de esta ejecución local: 0;
- coste local total: no medido;
- tarifas cloud del cuerpo anterior: modelo fechado, no factura ni benchmark;
- coste real por espectador: todavía no existe;
- hito 1.000: deshabilitado y no autorizado.

Las tarifas no se actualizaron en esta revisión porque ningún dato de precio era
necesario para decidir la integración local. Antes de una decisión económica
deben reconfirmarse y alimentarse con bitrate/egress y capacidad realmente
medidos.

### Binding, pathsets e inventario

| Elemento | Valor |
| --- | --- |
| Rama | codex/master-integration-v2 |
| HEAD inicial/final antes de este informe | 4aabe8d5a5f76d52f6d538de777cbc3b553f82dd |
| Tree revisado | 977aacb72165e986736d954e6e5f5fb6eb71c9bd |
| Base Task 09 | d6f968c3c46802f10b0246808f0afb252fcb6b69 |
| Status-z limpio | e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 |
| Tracking branch | ninguno |
| Commit infra | 8 paths; pathset 7fd19650bbf0acaed28cb36005ad15ef1fb56ac1509e2bbfd57c463cb24a2a49; inventory 5ede46613aa41192bb494ebe4f4d08956cc32b172b70dc5ff84d7a436389e3df |
| Commit chaos | 6 paths; pathset 7c645df996cfbdffdd19866d827f3aef7ca910b87d94fc81af63e41bb84b5b0b; inventory c3138ff8267c0c285a9c888e3cc9cfbbafc020a3054b45fd45056518fb580713 |
| Delta agregado | 14 paths; pathset d9d44c0bf4f63af047b9f31bcd0814fadedaeb87061077052ea3b8e3bd732853; inventory c7fa69786dc1905531679a1ef1e3c8cdea39caab432048ae13226fa28d71e05c |
| virtual-nodes final | 13 paths; pathset ed75b2bcaac2550106bc1f70a224cc0a37272ea9c62a7464aef492139d65b8c3; inventory 82e7d12b275c3ebf34258c0f8eb3501fd54c1caf34b68e68e42eae8db92ee02a |
| chaos/autoscaling final | 16 paths; pathset 868f0b712902a248a51a77158fe0215f34a609e37bc6e3f930753df847472783; inventory b538ec4eee39d16dc5ff2effb41da55ab71d47ae467372098cef2e3408759396 |
| control-plane de contexto | 37 paths; pathset c1db1386dbe1c7afc0731ee8a5c961d62e8e82d3be71560c0ca4fdf09ecf7b4a; inventory cd56dcf373dcdd1ed1bc16a18bf28f596687752d1f0eb0964aa77e581a820db5 |

Ambos commits son lineales, tienen autor/committer autorizado y exactamente
Signed-off-by: Jose María <12586102+jimbomilk@users.noreply.github.com>.
No hay symlinks, submodules, unmerged, cambios unstaged, target, caches,
bytecode ni reports/latest tracked en los tres alcances revisados.

### Validación reproducida

- Bash 5.3.9: bash -n sobre scripts y tests, PASS.
- Python 3.14.4: AST de todos los Python, JSON y TOML, PASS; imports externos,
  ninguno; dependencies, lista vacía.
- Docker Compose 2.39.2: config --quiet --no-interpolate, PASS.
- provider-adapter-test.sh, PASS.
- action-envelope-consumer-test.sh, PASS.
- compose-policy-test.sh, PASS.
- harness-test.sh, PASS para 10/25/50/100 y límites.
- unittest de control-plane, 47/47 PASS.
- run-integrated.sh dry-run 100, PASS y sin mutación provider/Docker.
- dry-run 101 y 1.000, ambos rechazados con exit 2.
- reports/task-09/SHA256SUMS, 36/36 OK.
- git diff --check para los dos commits, PASS.
- Gitleaks 8.30.1/MIT por digest
  sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f,
  cero findings focales, redacción 100 %, network none.
- REUSE 5.1.1/GPL-3.0-or-later por digest
  sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da:
  delta exacto 14/14 con Apache-2.0, PASS.

El lint REUSE del checkout completo no pasa y no se declara como pase: esta rama
de integración no contiene aún el bootstrap LICENSES/REUSE del repositorio
principal y además conserva artefactos ignorados/generados ajenos. El resultado
global fue 49/384 con información de licencia y 31/384 con copyright, además de
Apache-2.0 sin texto bajo LICENSES. Es un gate baseline/de integración documental
fuera de estos dos commits; el delta de autoscaling sí pasa 14/14. Debe
reconciliarse antes de publicación o de afirmar cumplimiento REUSE global.

No se ejecutó de nuevo el Compose integrado con Docker: la revisión reprodujo
los tests puros y dry-run, verificó la imagen local y contrastó la evidencia
owner inmutable. Evitar una segunda ejecución no reduce la evidencia
supply-chain y evita competir con builds/servicios locales. No estaba
disponible shellcheck ni se instaló.

### Decisión diferencial

No hay findings bloqueantes introducidos por los dos commits para su integración
local de laboratorio. Quedan bloqueadas la publicación, redistribución de la
imagen, capacidad de vídeo real, coste por espectador y cualquier hito 1.000
hasta cerrar REUSE global, SBOM/provenance/licencias de imagen, OCI productivo,
bitrate/egress/capacidad reales y autorización económica/remota.

**APPROVE LOCAL INTEGRATION WITH NON-PRODUCTION LIMITATIONS**

Esta aprobación no anticipa ni revisa la futura entrega Rust ni el Dashboard.

**LOCAL ONLY / NO PROVIDER OPERATION / NO CREDENTIAL / NO PUBLICATION**
