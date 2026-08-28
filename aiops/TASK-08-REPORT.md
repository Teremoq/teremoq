# Task 08 — Foundation AIOps local

## Hallazgos primero

1. **Crítico, corregido:** `agents_schema.json` admitía un `payload` arbitrario
   y acciones como cambios de bitrate u Object Dropping. Ahora es un alias
   inequívoco del contrato de recomendación no ejecutable; el formato legacy se
   prueba como inválido.
2. **Alto, corregido:** `init_agents.sh` seleccionaba un modelo por default,
   esperaba sin deadline y hacía pull implícito. Ahora el default no usa red ni
   modelo; sólo se admite un probe loopback explícito, acotado y aprobado.
3. **Alto, contenido:** los logs documentados contienen IDs, peers, errores y
   otros valores no aptos para un prompt o métrica de baja cardinalidad. El
   contrato AIOps sólo acepta agregados allowlisted y rechaza identidad,
   localizadores, material sensible y payload. No se implementó un agregador en
   esta Task.
4. **Alto, abierto por diseño:** ADR-0005 no dispone de identidad autenticada en
   el punto de autorización y ADR-0006 no dispone de admisión/concurrencia
   acotada del relay. Ninguna recomendación AIOps se presenta como mitigación de
   esos gaps.
5. **Gate cerrado:** no existe modelo seleccionado, licencia de pesos aceptada
   ni artefacto descargado. El manifiesto válido contiene `model: null`.
6. **Tooling:** se reutiliza `jsonschema` 4.19.2 con Draft 2020-12. Su CLI está
   deprecada por upstream; una migración futura a `check-jsonschema` debe pasar
   por el toolchain común y fijar versión. No se añadió dependencia.

## Contratos y decisiones

- `observation` acepta sólo ventanas de 1..300 segundos, dimensiones enumeradas
  y contadores/rangos acotados derivados de observabilidad del Gateway.
- `recommendation` exige evidencia causal, vocabulario de seguimiento seguro,
  `dry_run=true`, `executable=false`, `authority=none` y autorización futura.
- `execution` es un sentinel fail-closed que rechaza cualquier instancia.
- El manifiesto permite cero o un modelo. Una aprobación exige nombre exacto,
  digest, fuente, licencia de pesos, tamaño, contexto, fecha, rol y uso.
- El LLM nunca es autoridad de autenticación, autorización, scheduler, routing,
  bitrate u Object Dropping.
- No se seleccionó orquestador. n8n no se distribuye ni es dependencia; su
  posible uso interno requiere revisión de términos y una Task futura.

## Threat model y operación futura

`THREAT-MODEL.md` documenta límites de confianza, prompt injection,
exfiltración, cardinalidad, replay/idempotencia, retención, redacción, red
loopback y circuit breaker. El handoff futuro sólo entrega recomendaciones
validadas a una cola interna acotada; no existe ruta de llamada al Gateway.

La retención propuesta (no desplegada) es como máximo 24 horas para
observaciones y 7 días para recomendaciones. El productor futuro debe redactar
antes de construir/persistir el documento. Un fallo del análisis abre el
circuit breaker y detiene recomendaciones sin afectar al directo.

## Inventario exacto de Task 08

- `aiops/README.md`
- `aiops/THREAT-MODEL.md`
- `aiops/MODEL-SUPPLY-CHAIN.md`
- `aiops/TASK-08-REPORT.md`
- `aiops/TASK-08-HASHES.txt`
- `aiops/agents_schema.json`
- `aiops/init_agents.sh`
- `aiops/model-manifest.json`
- `aiops/schemas/aiops-observation-v1.schema.json`
- `aiops/schemas/aiops-recommendation-v1.schema.json`
- `aiops/schemas/aiops-execution-v1.schema.json`
- `aiops/schemas/model-manifest-v1.schema.json`
- `aiops/fixtures/valid/observation-object-drop.json`
- `aiops/fixtures/valid/observation-federation-capacity.json`
- `aiops/fixtures/valid/recommendation-dry-run.json`
- `aiops/fixtures/invalid/observation-extra-field.json`
- `aiops/fixtures/invalid/observation-high-cardinality.json`
- `aiops/fixtures/invalid/observation-sensitive-data.json`
- `aiops/fixtures/invalid/observation-operational-identity.json`
- `aiops/fixtures/invalid/observation-media-payload.json`
- `aiops/fixtures/invalid/observation-limits.json`
- `aiops/fixtures/invalid/recommendation-prompt-injection.json`
- `aiops/fixtures/invalid/recommendation-unauthorized-action.json`
- `aiops/fixtures/invalid/recommendation-malformed.json`
- `aiops/fixtures/invalid/execution-disabled.json`
- `aiops/fixtures/invalid/model-missing-license.json`
- `aiops/fixtures/invalid/legacy-agent-message.json`
- `aiops/tests/validate_instance.sh`
- `aiops/tests/test_contracts.sh`
- `aiops/tests/test_bootstrap.sh`
- `aiops/tests/run.sh`

`TASK-08-HASHES.txt` contiene el hash del payload del patch (todos los archivos
anteriores salvo el informe y el propio fichero de hashes) y el SHA-256 exacto
de este informe, evitando una referencia circular.

## Pruebas ejecutadas

- `bash -n aiops/init_agents.sh aiops/tests/*.sh`: PASS.
- `aiops/tests/test_contracts.sh`: PASS; fixtures válidas e inválidas, alias
  legacy, prompt injection, campos extra, cardinalidad, datos sensibles, acción
  no autorizada, límites, JSON malformado, ejecución y modelo incompleto.
- `aiops/tests/test_bootstrap.sh`: PASS; modo offline, host, opt-in, timeouts,
  no modelo implícito, no pull, mensaje redactado y fake `curl` no invocado.
- `aiops/tests/run.sh`: PASS.
- Parseo/validación con `jsonschema -V Draft202012Validator`: PASS.
- Búsqueda de material PEM/secreto en JSON no negativo: PASS.
- `git diff --check -- aiops`: PASS.
- Búsqueda de caches/artefactos/dependencias vendorizadas: PASS.

Todos los tests son locales, deterministas y acotados. No se ejecutó un probe
positivo contra Ollama: hacerlo requeriría aprobar un modelo real, lo que está
fuera de la Task. La prueba confirma que el manifiesto vacío falla antes de
invocar `curl`.

## Límites y decisiones aún necesarias

- Selección, licencia y procedencia de pesos; hardware, contexto y parámetros.
- Toolchain estándar futuro que sustituya el CLI deprecado de `jsonschema`.
- Implementación del agregador/redactor y sus límites de cola/frecuencia.
- Backend de retención y borrado auditable.
- Política de prompts y evaluación de un modelo real con datos sintéticos.
- Elección/licencia del orquestador interno y diseño del handoff.
- Cualquier esquema de ejecución, identidad, política, aprobación, rollback y
  auditoría; no se infiere de esta foundation.
- Resolución upstream de ADR-0005 y ADR-0006 antes de afirmaciones productivas.

## Confirmaciones de alcance

No se crearon agentes ni workflows. No se descargaron modelos, no se arrancaron
servicios y no se usó red externa. No se añadió ni vendorizó n8n, Node-RED u
otro orquestador. No se instaló herramienta ni dependencia. No hay código que
llame al Gateway ni que re-enrute, cambie bitrate, altere Object Dropping o
ejecute una acción. El commit de entrega incluye exclusivamente `aiops/**`.

## Estado

**READY FOR MASTER REVIEW**
