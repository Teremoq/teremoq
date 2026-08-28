# AIOps local foundation (Task 08)

Este directorio contiene únicamente contratos y controles offline para una
futura capacidad AIOps. No contiene agentes, workflows, un orquestador, un
modelo aprobado ni integración de escritura con el Gateway.

## Fronteras de autoridad

El flujo permitido en esta fase es unidireccional:

```text
logs/métricas estables -> agregación y redacción -> observation
observation -> análisis futuro opcional -> recommendation (dry_run)
recommendation -X-> execution -X-> Gateway
```

El LLM no autentica, autoriza, planifica, enruta ni decide Object Dropping. Los
mecanismos deterministas del Gateway y los ADR de autorización/concurrencia
siguen siendo la única fuente de verdad. Una recomendación no es una orden.

## Contratos versionados

| Contrato | Estado | Límite principal |
| --- | --- | --- |
| `schemas/aiops-observation-v1.schema.json` | permitido | agregados de logs/métricas, campos y cardinalidad allowlisted |
| `schemas/aiops-recommendation-v1.schema.json` | permitido | `dry_run=true`, `executable=false`, `authority=none` |
| `schemas/aiops-execution-v1.schema.json` | deshabilitado | el esquema rechaza toda instancia |
| `schemas/model-manifest-v1.schema.json` | gate de supply chain | un único modelo exacto o `null`; todos los metadatos son obligatorios antes de aprobación |

Todos usan JSON Schema draft 2020-12, cierran propiedades adicionales y fijan
tamaños, rangos, enums y cardinalidad. `tests/validate_instance.sh` añade a la
validación estándar límites de fichero y rechazo de material sensible,
localizadores operativos y lenguaje típico de prompt injection. No implementa
un motor JSON Schema propio.

`agents_schema.json` se conserva como punto de entrada de compatibilidad y
referencia exclusivamente el contrato de recomendación v1. El formato legacy
(`trigger_event.payload` y `action_required`) queda rechazado; no existe un
segundo contrato ambiguo.

## Datos admitidos y datos prohibidos

Las observaciones sólo aceptan ventanas agregadas de hasta 300 segundos,
dimensiones enumeradas y mediciones de baja cardinalidad derivables de
`gateway-rs/OBSERVABILITY.md`. No aceptan errores crudos, IDs de conexión o
suscriptor, peer, Stream ID, principal, certificado, fingerprint, namespace,
URL operativa, payload, vídeo, audio, credencial ni identificador de cliente.

La redacción debe ocurrir antes de construir la observación. El validador
rechaza el evento si aparece un campo prohibido; nunca intenta sanear un valor
potencialmente secreto después de ingerirlo.

## Bootstrap Ollama fail-closed

`init_agents.sh` tiene dos modos:

- `validate` (default): valida endpoint loopback, timeouts y manifiesto; no
  habilita modelo ni realiza ninguna operación de red.
- `probe`: reservado para una operación local futura y explícita. Requiere
  `AIOPS_NETWORK_OPT_IN=true`, nombre y digest exactos, hash del manifiesto y un
  modelo aprobado. Sólo consulta `/api/tags` en loopback con timeouts acotados.

El manifiesto actual contiene `"model": null`, por lo que `probe` falla antes
de invocar `curl`. El script no tiene modo pull, no selecciona un modelo por
default, no genera texto y no imprime variables sensibles.

Ejemplo offline seguro:

```sh
aiops/init_agents.sh
```

## Validación reproducible

La suite usa Bash, `jsonschema` y `rg` ya disponibles; no instala nada y no usa
red externa:

```sh
aiops/tests/run.sh
```

Para validar una instancia individual:

```sh
aiops/tests/validate_instance.sh observation path/to/observation.json
aiops/tests/validate_instance.sh recommendation path/to/recommendation.json
```

La herramienta `jsonschema` CLI está deprecada por upstream aunque la librería
instalada soporta draft 2020-12. Cuando el toolchain del repositorio adopte
`check-jsonschema`, debe fijar su versión mediante la gobernanza general; esta
Task no instala ni añade esa dependencia.

## Handoff futuro a un orquestador interno

Un orquestador futuro sólo podrá recibir recomendaciones ya validadas por una
cola interna acotada. Deberá revalidar el contrato, deduplicar por
`recommendation_id`, conservar el vínculo a `based_on_event_ids`, aplicar
backpressure y abrir un registro de revisión; no podrá convertir el documento
en una llamada al Gateway.

Habilitar ejecución exige otra Task y una decisión de arquitectura con esquema
de ejecución separado, política determinista, autenticación/autorización
independientes del LLM, simulación, auditoría, rollback, circuit breaker y
tests. n8n sólo podría evaluarse para uso interno bajo sus términos; no se
distribuye ni se añade como dependencia aquí. Ningún orquestador alternativo se
ha seleccionado.
