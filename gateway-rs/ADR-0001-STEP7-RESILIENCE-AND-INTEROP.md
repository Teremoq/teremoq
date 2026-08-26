# ADR-0001: banco de resiliencia e interoperabilidad externa

- Estado: aceptado para la PoC
- Fecha: 2026-08-23

## Contexto

Teremoq debe priorizar actualidad y continuidad en redes hostiles, mantener zero-transcoding y evitar que un cliente lento bloquee al resto. Una prueba únicamente en loopback limpio no valida esas propiedades. MoQT también evoluciona por drafts, de modo que compartir código con un relay de la misma revisión es necesario pero insuficiente como evidencia externa.

## Decisión

1. Mantener el camino de datos en las bibliotecas upstream fijadas de `moq-rs`; no crear una implementación MoQT propia.
2. Añadir un banco opt-in en contenedor aislado que aplique `tc netem`, reinicie el relay y ejecute dos subscribers con velocidades distintas.
3. Modelar GOPs de 30 Objects, registrar gaps y medir recuperación al siguiente I-frame.
4. Usar backoff exponencial acotado con jitter y presupuesto móvil para las reconexiones; no encolar señal durante una desconexión del relay.
5. Separar métricas de latencia. El Gateway publica `ingest_to_publish`; el banco publica `publish_enqueue_to_subscriber`. `presentation` y `glass_to_glass` quedan nulos sin un cliente de reproducción y una referencia temporal calibrada.
6. Ejecutar la matriz oficial `moq-interop-runner` contra `moxygen` en draft-16 y registrar tanto éxitos como fallos.

## Consecuencias

- Las regresiones de memoria, shutdown, aislamiento y latencia tienen un comando reproducible y gates explícitos.
- El test hostil es ignorado por defecto porque necesita `NET_ADMIN` dentro de un contenedor; la suite ordinaria continúa sin privilegios.
- La evidencia externa actual es parcial: 7/8 casos del runner pasaron y `publish-track-subscribe` falló. No se promociona `moxygen` a dependencia ni se afirma interoperabilidad completa.
- La medición de cinco minutos es un soak de PoC, no una cualificación Tier-1 de 24/72 horas ni una prueba sobre enlaces de motorsport reales.
- El preview de vídeo futuro se mantendrá fuera del camino crítico del Gateway.
