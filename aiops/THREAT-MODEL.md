# Threat model de la foundation AIOps local

## Alcance y activos

La Task 08 protege la frontera entre observabilidad del Gateway y un análisis
local futuro. Los activos principales son la disponibilidad del directo, la
confidencialidad de datos operativos y de clientes, la integridad de políticas
de routing/scheduler y la trazabilidad de recomendaciones. Ollama, modelos y un
orquestador no están activos ni forman parte del trusted computing base actual.

Fuera de alcance: ejecución de acciones, workflows, escritura al Gateway,
selección de modelo y remediación de los gaps upstream descritos en ADR-0005 y
ADR-0006.

## Límites de confianza

1. Los logs y métricas del Gateway son datos no confiables hasta que un
   agregador futuro aplique allowlist, redacción y límites.
2. Una `observation` validada es evidencia acotada, no identidad ni decisión.
3. Toda salida LLM se trata como texto atacante y debe satisfacer el contrato
   de `recommendation` y el filtro de contenido.
4. Un orquestador futuro es otra frontera de confianza y nunca hereda autoridad
   del modelo.
5. El Gateway y sus políticas deterministas permanecen fuera de la red AIOps y
   no exponen un endpoint de acción a esta foundation.

## Amenazas y controles

| Amenaza | Control actual | Riesgo residual / gate futuro |
| --- | --- | --- |
| Payload arbitrario o campo sorpresa | `additionalProperties=false`, enums y tamaños | agregar nuevos eventos requiere nueva versión y revisión |
| Exfiltración de secretos, PKI o identidad | campos allowlisted; filtro de claves, PEM y localizadores; rechazo en vez de redacción tardía | el productor futuro debe redactar antes de persistir |
| Cardinalidad explosiva | sin IDs por conexión/cliente; dimensiones enumeradas; ventanas y contadores acotados | medir volumen y limitar cola/series en la implementación futura |
| Prompt injection desde logs o salida LLM | observaciones sin texto libre; filtro de recomendaciones; fixtures negativos | ningún filtro léxico es prueba completa; el modelo sigue sin autoridad |
| Acción no autorizada | recomendación fija `dry_run`, `executable=false`, `authority=none`; ejecución rechaza todo | exige ADR, política y autorización separadas |
| Replay o duplicado | IDs acotados y vínculo causal obligatorio | consumidor futuro debe deduplicar e imponer ventana temporal |
| LLM malformado o oversized | parseo JSON Schema, máximo de fichero y longitudes | detener análisis; nunca fallback permisivo |
| Modelo o pesos sustituidos | manifiesto exacto, digest y hash; ningún modelo aprobado | verificar artefacto local y licencia antes de habilitar |
| Servicio AIOps expuesto | bootstrap sólo admite HTTP loopback y opt-in explícito | red interna, autenticación y firewall requieren diseño futuro |
| Dependencia de AIOps en el camino crítico | no hay llamadas desde/al Gateway | conservar colas prescindibles y pérdida preferente de observabilidad |
| Flood o fallo upstream de federación | se conserva `capacity_enforced=false` cuando aplique | ADR-0006 continúa bloqueado; AIOps no puede compensarlo |
| Suplantación de principal | principal y material TLS prohibidos en el contrato AIOps | ADR-0005 continúa bloqueado; el LLM no autoriza namespaces |

## Red, secretos y retención

El modo default del bootstrap realiza cero conexiones. El único modo de red
definido es un probe explícito contra `127.0.0.1` o `::1`; rechaza userinfo,
paths, query, hosts remotos, timeouts no acotados y manifests sin hash. No hay
pull, generación, acceso a Internet ni arranque de servicio.

No deben persistirse payloads de origen. Requisito para la futura
implementación: observaciones máximo 24 horas y recomendaciones máximo 7 días,
con borrado acotado y auditable; esos valores son límites conservadores
propuestos, no una política desplegada. Métricas agregadas sin identidad pueden
tener una retención distinta sólo mediante decisión documentada.

Los logs del validador y bootstrap comunican categorías de rechazo y nunca
incluyen el documento, host rechazado, nombre de cliente, modelo recibido o
secreto.

## Replay, idempotencia y circuit breaker

Un consumidor futuro debe mantener una caché acotada de `event_id` y
`recommendation_id` durante la ventana de retención. Un duplicado produce el
mismo resultado y no vuelve a abrir handoff. Timestamps fuera de la ventana,
IDs reutilizados con contenido distinto y cadenas causales inexistentes se
rechazan. El reloj de pared no autoriza acciones.

El análisis futuro se abre por defecto si falla validación, modelo, almacenamiento
o cola: deja de producir recomendaciones sin afectar al Gateway. El circuit
breaker debe abrirse ante ratio sostenido de inválidos, timeout, backlog o
fallos del runtime; debe tener límites y recuperación manual/temporizada
documentados. Abrir o cerrar el breaker sólo cambia el análisis, nunca routing,
bitrate, Object Dropping, scheduler ni sesiones.

## Condiciones para ampliar alcance

Antes de cualquier ejecución se requieren, como mínimo: threat model revisado,
schema de ejecución no vacío, identidad autenticada, autorización por política
determinista, allowlist de acciones y parámetros, simulación, aprobación humana
definida, idempotencia, rate limit, auditoría inmutable, rollback probado y un
circuit breaker independiente. El LLM no participa en esas decisiones de
seguridad.
