<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Task 11: revisión TP-OSS-SC de coste y supply chain del hito 100

Fecha de revisión: 2026-08-28

Estado: **HITO 100 BLOQUEADO HASTA RECIBIR LOS ARTEFACTOS Y LA EVIDENCIA
LOCAL; HITO 1.000 PROHIBIDO**

Esta es una revisión técnica, no asesoría legal. No autoriza contratar un
proveedor, crear recursos remotos, usar credenciales, publicar, cambiar el
producto ni extrapolar capacidad.

## Hallazgos primero

### Alta — el paquete apareció durante la revisión, pero no es reproducible aún

En la inspección inicial de las 15:26 CEST no existían
`infra/virtual-nodes/` ni `control-plane/`. Por tanto no hay imágenes,
Dockerfiles, manifests, herramientas, schemas o inventarios de Task 11 sobre
los que verificar licencia, digest, procedencia, compatibilidad Apache-2.0 o
exposición de secretos.

La reinspección obligatoria de las 15:31 CEST detectó una entrega concurrente
nueva bajo `infra/virtual-nodes/`: Compose, dos scripts, topología y un
`versions.env`. Se auditó ese segundo snapshot read-only. `control-plane/`
continuó ausente. Esto no es un resultado limpio: el gate sigue incompleto y
cualquier cambio posterior necesita una revisión diferencial.

El pin inmutable de imagen está en `infra/virtual-nodes/versions.env:4-5`, pero
`.gitignore:13` ignora todos los `*.env`. El fichero no aparece en `rg --files`
ni en el inventario Git y no acompañaría un commit normal. Compose exige ese
valor en `infra/virtual-nodes/compose.yaml:5`; sin una excepción Git explícita
o un formato versionable no-secreto, el harness no se reproduce desde el
repositorio. Severidad alta; owner `TP-PLATFORM-CHAOS`.

### Alta — el adaptador no bloquea capacidades 1.000

`infra/virtual-nodes/provider-adapter.sh:27-29` sólo exige que capacity sea un
entero sin signo. Las validaciones/selecciones de las líneas 103, 136 y 153-154 no aplican un
máximo, por lo que `1000` y valores mayores son sintácticamente válidos. La
topología fija 25 para cada distribuidor, pero `--capacity` puede sobrescribir
ese valor en create/configure.

El gate requerido es fail-closed `<=100`, idealmente con un máximo de contrato
único y tests de 100/101/1000. No se corrige aquí porque el adaptador pertenece
a otra Task. Severidad alta; owner `TP-CONTROL-AUTOSCALE`/
`TP-PLATFORM-CHAOS`.

### Alta — `control-plane/` continúa ausente

No existen todavía formatos desired-state, reconciliación, límites globales,
cost ledger ni lifecycle de Task 11 que auditar. No puede demostrarse que el
plano de control vaya a respetar el máximo 100 aunque el adaptador se corrija.
Referencia: `control-plane/`, path ausente, línea no aplicable. Owner
`TP-CONTROL-AUTOSCALE`; revisor `TP-OSS-SC`.

### Media — la imagen está fijada localmente, pero carece de SBOM/provenance cerrada

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

### Informativa — source y escaneo focal no exponen secretos

Los cuatro artefactos versionables y `versions.env` contienen SPDX
`Apache-2.0`; REUSE 5.1.1 pasó el árbol completo con 272/272. Gitleaks 8.30.1,
imagen oficial fijada y redacción 100 %, escaneó 12,55 KB y no encontró leaks.
La búsqueda complementaria no halló asignaciones de credenciales, PEM privado,
URLs autenticadas ni rutas locales. No se muestran valores sensibles.

`bash -n`, PyYAML 6.0.3 y `docker compose config --quiet` pasaron. No había
`shellcheck` ni validador Markdown/link local instalado. La etiqueta
`infra/virtual-nodes/compose.yaml:42` conserva `teremoq.task: "10"`; cualquier
evidencia reutilizada por Task 11 debe distinguir el owner/run real para no
atribuirla al hito equivocado.

### Alta — no hay evidencia que permita convertir 100 espectadores en nodos

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

## Snapshot local y límites

| Evidencia | Resultado |
| --- | --- |
| `.cursorrules` | SHA-256 `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2`; 488 líneas leídas completas |
| Git inicial | rama `main`, HEAD `0faee5dec127e47649a08b82bade8f3faf69c8ab` |
| Estado Git | árbol sucio con cambios ajenos; ninguno fue revertido, modificado ni incluido |
| `infra/virtual-nodes/` | ausente inicialmente; cinco artefactos presentes en la reinspección 15:31 CEST |
| `control-plane/` | ausente en inspección inicial y reinspección |
| Directorio propiedad de esta revisión | sólo `docs/capacity-reviews/` |
| Recursos/servicios remotos creados | ninguno |
| Credenciales usadas | ninguna |

Inventario supply-chain congelado tras la entrega concurrente:

| Path/objeto | SHA-256 |
| --- | --- |
| `infra/virtual-nodes/compose.yaml` | `314b2dc5413c8d083f9a426b4ab1763a6bef323786a7ab5f5fd101efad5181c6` |
| `infra/virtual-nodes/node-runtime.sh` | `5918447709f69cf79545d5be1e8e111d78122577fff6106d8e7f8720a057ff7e` |
| `infra/virtual-nodes/provider-adapter.sh` | `e484d90602e5633514a776f6b88d4ebe225abc35fcfd47fb22aec06c01b4c637` |
| `infra/virtual-nodes/topology/default.tsv` | `e218a77292f8fef7645f522739af546406aec6f131ba44bb4be29c08415fc28e` |
| `infra/virtual-nodes/versions.env` | `0c13fb3e7becf9b81c2cd62ef7a4f230312d0455e220bcf4b178daeb1b11ebe5` |
| imagen local inspeccionada | `ba076cf0a26aa41efdd2f0f80687ef97009d1526680751456c19cc944dff1d0b` |
| Dockerfile asociado por history | `9a4419f66806e6b0b3af1d4c62591460bf73cc9b457d1faf8c0afce15ead0bc6` |

El adapter cambió una vez durante la revisión; el hash de la tabla corresponde
al segundo snapshot y sustituye al hash preliminar. Si cualquiera de estos
cinco ficheros cambia antes de integrar sus Tasks propietarias, el dictamen de
línea/supply-chain debe repetirse.

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

Estado aplicado al snapshot recibido: hardening Compose, sintaxis, SPDX/REUSE y
secret scan pasan; versionado del pin, SBOM/provenance, licencia completa de la
imagen y límite máximo fallan o quedan incompletos.

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
- configuración local fail-closed con máximo global `<= 100`;
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

- 100 espectadores más la reserva aprobada, sin superar límite global 100 de
  sesiones reales ni crear recursos remotos;
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

No existe un gate automático de 100 a 1.000. Debe fallar cerrado cualquier
configuración `>100`. Para abrir un futuro diseño de 1.000 se requieren:

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
| Alta | `infra/virtual-nodes/versions.env:4-5`; `.gitignore:13` | El digest requerido está ignorado y no forma parte del inventario versionable | Bloquea reproducibilidad 10/25/50/100 |
| Alta | `infra/virtual-nodes/provider-adapter.sh:27-29,103,136,153-154` | Capacity acepta 1.000 o cualquier entero sin máximo | Bloquea 100 y 1.000 |
| Media | imagen fijada en `versions.env:4` | Digest local coincide, pero no hay SBOM/provenance/licencias cerradas | Bloquea supply-chain 100 |
| Alta | `control-plane/`, ausente | No hay formatos, límites, coste, lifecycle ni evidencia de secretos que auditar | Bloquea 10/25/50/100 |
| Alta | evidencia de capacidad, ausente | `K`, `b`, `o`, reserva y cooldown no medidos | Bloquea coste por espectador y 100 |
| Media | ledger remoto, ausente | No puede probarse ausencia global de recursos fuera de esta Task | Bloquea cualquier claim de cuenta limpia |

No se asignan defectos de línea ficticios a archivos inexistentes. Cuando las
otras Tasks entreguen, el Master debe solicitar una revisión diferencial con
archivo, línea, hash y severidad reales.

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

Herramientas locales: Bash 5.3.9, Python 3.14.4, PyYAML 6.0.3, Docker 28.3.3,
Compose 2.39.2, `docker-sbom 0.6.0`/Syft 0.43.0, REUSE 5.1.1 por digest
`sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da`
y Gitleaks 8.30.1 por digest
`sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f`.
REUSE y Gitleaks se ejecutaron sin red y con el source montado read-only.

No se ejecutó carga. Se auditó el snapshot local nuevo de virtual-nodes, pero
no existe `control-plane/`, SBOM final ni evidencia de ejecución 10/25/50/100.
No se afirma compatibilidad Apache-2.0 de la imagen completa. No se consultaron
facturas, cuotas ni cuentas de proveedor. Los precios pueden cambiar y deben
reconfirmarse antes de una decisión económica.

## Decisión

- **Coste local remoto medido por esta revisión: 0.** Electricidad/hardware y
  coste local total: no medidos.
- **Estimación cloud:** sólo fórmula parametrizada con tarifas públicas
  fechadas; no factura ni benchmark.
- **Supply chain:** virtual-nodes revisado con blockers; control-plane ausente.
- **Hito 100:** bloqueado hasta que pasen inventario, digests, SBOM, pruebas
  10/25/50/100, cleanup y reconciliación a cero.
- **Hito 1.000:** bloqueado explícitamente y requiere nueva autorización.

**LOCAL REVIEW ONLY / NO CLOUD RESOURCE / NO CREDENTIAL / NO PUBLICATION**
