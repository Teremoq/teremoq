# Banco de resiliencia del Paso 7

Fecha de ejecución: 2026-08-23. El banco se ejecuta en un contenedor Linux aislado con `NET_ADMIN`; nunca altera la interfaz del host. Usa el relay TLS oficial de la revisión fijada de `moq-rs`, el publisher real de `gateway-rs` y dos subscribers MoQT reales.

Entorno observado: WSL2 Linux `6.18.33.2`, Docker Engine `28.3.3`, 8 vCPU Intel i7-8650U y 7,7 GiB de RAM asignada. La imagen local resultante quedó identificada como `teremoq-step7-lab@sha256:315ab1185640250a0bc5143796e5098f90e5ece1041cdf4fabf99a80ff1e2c30`; una reconstrucción reproduce las entradas fijadas, pero genera un nuevo attestation manifest si cambia el builder.

## Perfil reproducible

`scripts/run-step7-lab.sh` aplica sobre loopback:

```text
delay 35 ms ± 15 ms (normal)
loss 3 % con correlación 25 %
duplicate 0,1 %
reorder 10 % con correlación 50 %
rate 6 Mbit/s
netem limit 1000 paquetes
```

La carga predeterminada es 20 Objects/s de 8192 bytes, GOP de 30 Objects y cinco minutos. El subscriber lento añade 120 ms antes de cada lectura. El ensayo aborta y reinicia el relay antes de publicar para validar la reconexión del Gateway. Si una publicación/suscripción MoQT termina normalmente durante la degradación, cada cliente reabre su propia sesión y suscripción con backoff corto acotado por la duración del test; el informe conserva número de reconexiones y peor tiempo de recuperación. El script exige `TEREMOQ_LAB_ISOLATED=1` y limpia el `qdisc` mediante `trap`.

```bash
docker build -f tests/lab/Dockerfile -t teremoq-step7-lab:rust-1.93 .
docker run --rm --cap-add NET_ADMIN \
  -v "$PWD:/workspace" -w /workspace \
  -e TEREMOQ_LAB_ISOLATED=1 \
  teremoq-step7-lab:rust-1.93 \
  ./scripts/run-step7-lab.sh
```

La imagen base está fijada por digest en `tests/lab/Dockerfile`; los paquetes Debian del banco también usan versiones exactas. El banco no forma parte del artefacto de producción.

## Métricas y criterios

- Correlación por secuencia y reloj monotónico dentro del mismo proceso de prueba.
- Latencia `publish_enqueue_to_subscriber` p50/p95/p99/máxima por consumidor.
- Objetos recibidos, gaps y reordenamientos observados.
- Recuperación hasta el siguiente I-frame tras detectar un gap.
- Reconexión del publisher tras caída explícita del relay.
- Terminaciones normales de Track, reconexiones de cada subscriber y peor tiempo de resuscripción.
- RSS al inicio/final, número de tasks del proceso y colas del publisher al cerrar.
- Contadores de Objects aceptados, descartados y sesiones expulsadas.

Los gates automáticos exigen tráfico real, aislamiento observable del consumidor lento, al menos 95 % de entrega al rápido, crecimiento RSS menor o igual a 64 MiB, no más de dos tasks residuales transitorias y colas finales a cero. Una terminación MoQT normal (`cancelled`, `done` o `closed(0)`) se registra; en el consumidor rápido solo se admite durante el último segundo del ensayo. El límite RSS detecta crecimiento evidente en esta PoC; no demuestra por sí solo ausencia matemática de fugas.

## Resultados observados

### Perfil hostil de control, 30 segundos

| Métrica | Resultado |
| --- | ---: |
| Objects enviados / rápido / lento | 601 / 601 / 248 |
| Reconexión publisher | 836 ms |
| Rápido p50 / p95 / p99 / máximo | 130 / 156 / 168 / 184 ms |
| Lento p50 / p95 / p99 / máximo | 166 / 204 / 215 / 222 ms |
| Gaps rápido / lento | 0 / 352 |
| RSS inicio / final / crecimiento | 20484 / 21344 / 860 KiB |
| Tasks inicio / final | 2 / 2 |
| Cola final Objects / bytes | 0 / 0 |

El consumidor lento perdió actualidad sin reducir la entrega al consumidor rápido. No hubo gaps en el rápido, por lo que su métrica de recuperación de I-frame no aplica. El lento completó nueve recuperaciones; su máximo de 7409 ms refleja que, con lectura deliberadamente lenta y política de actualidad, puede saltarse varios GOP antes de observar otro punto de acceso.

### Soak hostil, cinco minutos

| Métrica | Resultado |
| --- | ---: |
| Objects enviados / rápido / lento | 6001 / 5929 / 2423 |
| Reconexión publisher inicial | 904 ms |
| Resuscripciones rápido / lento | 7 / 9 |
| Peor resuscripción rápido / lento | 613 / 586 ms |
| Rápido p50 / p95 / p99 / máximo | 130 / 159 / 175 / 221 ms |
| Lento p50 / p95 / p99 / máximo | 163 / 200 / 216 / 238 ms |
| Gaps rápido / lento | 72 / 3577 |
| Recuperación I-frame p95 rápido / lento | 2026 / 8863 ms |
| RSS inicio / final / crecimiento | 20584 / 33656 / 13072 KiB |
| Tasks inicio / final | 2 / 2 |
| Cola final Objects / bytes | 0 / 0 |

El rápido conservó el 98,8 % de los Objects bajo el perfil hostil y se resuscribió tras cada una de las siete terminaciones normales de Track. El lento perdió actualidad y necesitó nueve resuscripciones independientes, sin reducir el progreso del rápido. El publisher aceptó los 6001 Objects, no expulsó sesiones internas y terminó con las colas vacías. No se observó deadlock ni task huérfana; el RSS aumentó 12,8 MiB y quedó dentro del techo de 64 MiB del ensayo.

El resultado estructurado completo se conserva en `tests/evidence/step7-resilience-soak-2026-08-23.json`.

## Interpretación y límites

- Esta cifra no es latencia SRT→pantalla ni `glass_to_glass`; empieza cuando el Object entra al scheduler del publisher y termina cuando el subscriber de prueba lo lee.
- `netem` sobre loopback condiciona todos los flujos locales del banco. Es reproducible para regresión, pero no sustituye radios, módems, rutas móviles ni hardware de cliente real.
- La carga hostil cuantitativa usa `Track 0` para medir GOP, lag y recuperación visual. Las invariantes de audio/telemetría crítica y aislamiento por Track tienen tests deterministas del scheduler, pero todavía requieren una matriz de red multi-Track con media real antes de una cualificación broadcast.
- La carga es sintética y conserva la jerarquía GOP/Object, pero no decodifica imagen. La comparación visual y el tramo de presentación permanecen para la entrega final.
- La primera carga de 32768 bytes situaba el caudal útil demasiado cerca de 6 Mbit/s y colapsó ambos consumidores; se conserva como hallazgo de límite, no como resultado aprobado. El perfil de aceptación usa 8192 bytes para medir resiliencia bajo degradación sin convertir todo el ensayo en sobrecarga permanente.
- El backoff MoQT está acotado, usa jitter 80–120 % y presupuesto por ventana. Una desconexión no acumula media antigua y no detiene SRT/media.
