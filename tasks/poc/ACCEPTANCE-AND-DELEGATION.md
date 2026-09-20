<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Cierre de la PoC y delegación de pruebas

Fecha del acuerdo: 2026-09-09.
Origen: instrucciones del usuario consolidadas con autorización expresa para
documentarlas y comunicarlas al Master y al responsable delegado.
Estado: contrato de trabajo; no acredita pruebas superadas ni una delegación
ya aceptada. El Master debe vincular la evidencia y registrar el traspaso.

## 1. Prioridad y alcance

La prioridad número uno es completar una PoC demostrable y reproducible de
Teremoq. Dos resultados son obligatorios: vídeo real entre los dos ordenadores
propios conectados al mismo router y un canal de coordinación que permita
diagnosticar, actualizar y repetir pruebas sin recuperación manual recurrente.

El canal resistente a fallos y la actualización automática forman parte del
cierre; no son mejoras opcionales ni deben aplazarse para declarar éxito.
Una prueba puede fallar y el ordenador debe seguir siendo gestionable, o
recuperar automáticamente esa capacidad cuando vuelva la conectividad.

Reutilizar Gateway, relay, reproductor, canal, actualizador y harnesses
existentes. No crear clientes, launchers, canales o motores paralelos para
sortear problemas de integración. Separar responsabilidades y dominios de
fallo dentro de la solución existente.

Durante este cierre se aplazan nuevas funciones cloud, criptomoneda, AIOps,
dashboard comercial y administración remota general. Son admisibles la
observabilidad mínima necesaria para el ensayo y los cambios que cierren un
criterio o corrijan un riesgo relevante del alcance actual.

La progresión a 5, 10 y 25 reproductores audiovisuales reales es una etapa
posterior a la demostración básica. Los 100 espectadores del modelo simulado
no acreditan capacidad audiovisual. El aislamiento del canal entre varios
clientes sí se verifica en este cierre con al menos dos instancias de cliente
aisladas; indicar si comparten equipo y no confundirlas con varios equipos
físicos ni con espectadores de vídeo reales.

Este contrato fija el hito inmediato. No elimina obligaciones anteriores de
seguridad, Zero-Transcoding, audio/telemetría, interoperabilidad, aislamiento,
soak o calidad que resulten aplicables. El Master debe mapear las puertas
previas a evidencias válidas o pendientes y distinguir «hito LAN aceptado» de
«PoC técnica completa» si quedan obligaciones de cierre sin satisfacer.

## 2. Propiedad y traspaso

- Master: fija prioridades, candidata, dependencias y aceptación; integra
  entregas y asigna defectos. No concentra la ejecución repetitiva de ensayos.
- TP-PLATFORM-CHAOS: responsable único de conducir la campaña, reservar el
  laboratorio, recopilar evidencias y entregar resultados. Reutilizar su tarea
  existente, sin duplicar perfil ni responsabilidad.
- TP-WEB-REALTIME: corrige reproductor, distribución Web y métricas de cliente.
- TP-RUST-DIST: corrige Gateway, relay e integración Rust/MoQT.
- TP-SEC-PKI: revisa identidad, autorización y recuperación de confianza.
- TP-OSS-SC y TP-CONTROL-AUTOSCALE: intervienen cuando el defecto afecte sus
  contratos existentes, sin ampliar el alcance de la campaña.

El Master transmitirá este documento íntegro o un enlace accesible con lectura
obligatoria al agente responsable, junto con la candidata y los requisitos
previos. Pedirá confirmación de recepción y un plan de ensayo que incluya
explícitamente la resiliencia del canal. Un resumen que omita esa parte no
constituye un traspaso válido.

Registrar antes de que el delegado opere el laboratorio:

| Campo de traspaso | Valor que debe registrar el Master |
| --- | --- |
| Tarea y agente responsable | Nombre e identificador de la tarea existente |
| Documento recibido | Revisión o SHA-256 de este contrato y confirmación |
| Candidata | Checkout, commit y artefactos exactos |
| Ensayo en curso | Finalizado o transferido en un punto seguro |
| Propietario del laboratorio | Único operador y periodo de reserva |
| Estado operativo | Procesos, puertos, equipos y tareas en curso |
| Referencias privadas | Rutas autorizadas a configuración y evidencias, sin secretos |
| Siguiente ensayo | Caso, umbrales previos, prerrequisitos y criterio de salida |

El delegado no inicia pruebas hasta recibir el traspaso del laboratorio. El
Master no ejecuta simultáneamente órdenes sobre los mismos equipos. Mientras
tanto los especialistas pueden analizar o corregir componentes en checkouts
aislados. No interrumpir ni duplicar una prueba activa para acelerar el relevo.

## 3. Candidata fija y criterios previos

Cada ensayo usa una versión identificada e inmutable durante la medición.
Las correcciones se incorporan a la siguiente candidata. Registrar por
separado versiones de servidor, canal, actualizador y reproductor, sus
compatibilidades y la configuración efectiva. Una prueba de actualización
debe identificar expresamente las versiones de origen y destino.

Antes de ejecutar, fijar bitrate, codec, resolución, fps, duración, condiciones
de red, referencia temporal y umbrales de cortes, descartes, latencia, recursos,
detección y recuperación. Derivar los umbrales de requisitos aprobados y
declarar los que aún falten; no cambiarlos después para aprobar resultados.
No hace falta pedir al usuario decisiones técnicas rutinarias de bajo riesgo.

## 4. Aceptación audiovisual y actualización

| ID | Caso | Evidencia exigida |
| --- | --- | --- |
| V1 | Arranque reproducible | Dos equipos arrancan con guía sencilla, sin editar código |
| V2 | Vídeo real | Fuente → Gateway → relay → reproductor, al menos 30 minutos; cortes, descartes, CPU, memoria y red registrados |
| V3 | Latencia | p50/p95/p99, tramo, muestras, ventana y precisión; sin afirmar glass-to-glass con relojes no calibrados |
| V4 | Interrupción de red | Corte definido y vuelta de la reproducción sin reiniciar manualmente todo el sistema; tiempo medido |
| U1 | Actualización aprobada | Descarga desde Git de versión exacta autorizada, activación comprobada y configuración conservada |
| U2 | Reutilización | Cambio ajeno al player no lo recompila; componentes y dependencias sin cambios se reutilizan cuando sus verificaciones lo permiten |
| U3 | Actualización fallida | Rechazo o rollback hacia una versión funcional y gestionable, sin perder la configuración |
| V5 | Parada y limpieza | Se liberan sólo recursos propios del ensayo; evidencias conservadas y residuos comprobados |

La existencia de un proceso o un HTTP 200 no prueba reproducción audiovisual.
Registrar soporte y limitaciones de audio/telemetría y recuperar la evidencia
previa aplicable. No declarar continuidad de audio por observar vídeo fluido.

## 5. Contrato de resiliencia del canal

### Independencia y recuperación

El fallo, bloqueo o cierre de una prueba, compilación, reproductor o actualización
no termina el canal. Cada trabajo tiene aislamiento, deadline, cancelación y
limpieza acotada; el cliente queda disponible para la siguiente orden.

Una pérdida de Wi-Fi o caída temporal del servidor provoca reintentos con
backoff, jitter y frecuencia máxima, evitando una avalancha al reconectar
muchos equipos. Agotar un presupuesto temporal no exige intervención manual:
se reanuda conforme a la política aprobada mientras la autorización sea válida.

Tras reiniciar el agente o servidor, reconciliar tareas terminadas, en curso o
interrumpidas. No prometer reanudar una sesión sólo conservada en memoria:
definir y revisar el mecanismo de recuperación autenticada que lo permita.
No pedir nuevo emparejamiento por fallos operativos normales con autorización
vigente. Revocación, cambio de identidad o certificado inválido deben producir
un estado explícito; nunca desactivar comprobaciones para recuperar conexión.

### Órdenes, confirmaciones y resultados

Cada tarea tiene identidad única, cliente destinatario y estados reconocibles:
recibida, ejecutándose, completada, fallida o interrumpida. Usar los nombres
equivalentes del contrato existente antes que inventar un segundo esquema.

Persistir de forma acotada y protegida el estado mínimo para reconciliar
resultados y confirmaciones tras reinicios. No guardar credenciales o sesiones
en claro ni añadir secretos a logs o Git. No inferir finalización por timeout.

Una confirmación perdida permite retransmitir sin repetir el efecto de una
actualización o tarea ya ejecutada. No afirmar ejecución «exactamente una vez»
sin prueba; usar deduplicación, idempotencia y consulta del estado. Si queda
incertidumbre sobre un efecto, reconciliarlo antes de repetirlo.

### Propagación de cambios

El servidor comunica a cada cliente la versión aprobada y observa pendiente,
descargada, activa o fallida. Cada cliente recupera los cambios de la fuente
autorizada; no se requiere replicación arbitraria entre todos los ordenadores.
Una actualización del player no interrumpe el canal. La del propio agente
requiere transferencia controlada o recuperación automática a versión válida.
No actualizar durante una medición salvo que sea el objeto del ensayo.

### Visibilidad operativa mínima

Consultar con herramientas existentes: clientes conectados, desconectados y
recuperándose; último contacto; versiones; tarea y resultado; actualización
pendiente/fallida e intervención humana necesaria. Distinguir datos antiguos o
ausentes. No desarrollar un dashboard nuevo como prerrequisito.

## 6. Matriz obligatoria de fallos del canal

| ID | Inyección | Resultado esperado |
| --- | --- | --- |
| C1 | Fallo y bloqueo del reproductor | Canal disponible, tarea terminal y siguiente orden atendida |
| C2 | Compilación fallida | Diagnóstico conservado y otra tarea ejecutada sin reemparejar |
| C3 | Corte/restauración Wi-Fi | Reconexión autenticada automática; tiempos medidos |
| C4 | Reinicio del agente | Recuperación del control y reconciliación de tareas sin duplicar efectos |
| C5 | Reinicio del servidor | Clientes reconectan y estados/resultados se reconcilian |
| C6 | Pérdida de confirmación | Reentrega sin ejecutar dos veces la acción ni perder resultado |
| C7 | Actualización fallida del player | Versión anterior funcional y canal utilizable |
| C8 | Actualización interrumpida del agente | Recuperación del control por transferencia o rollback probado |
| C9 | Cliente averiado con otro conectado | El cliente sano sigue recibiendo órdenes; recursos acotados |
| C10 | Identidad/certificado/autorización inválidos | Rechazo visible; sin bypass TLS ni reconexión no autorizada |

Registrar repeticiones, condiciones, tiempos de detección/recuperación,
acciones realmente ejecutadas, intervención manual y residuos. Una sola
recuperación no demuestra fiabilidad general. Incluir una secuencia de varios
fallos y tareas sucesivas; fijar su número antes de ejecutar. Declarar qué
casos son reales, simulados, unitarios o pendientes.

## 7. Evidencia, bloqueos y cierre

Mantener una matriz única por ID con estado demostrado/pendiente/bloqueado,
versión, tipo de ensayo, criterio previo, resultado observado, evidencia,
propietario y siguiente acción. Este documento no inicializa ningún caso como
superado: primero hay que revisar las evidencias existentes.

Reutilizar evidencia válida cuando sus versiones y condiciones sigan siendo
aplicables. Repetir pruebas por cambios, fallos o incertidumbres concretas, no
por rutina. Conservar las revisiones independientes exigidas por los riesgos.

Cada defecto incluirá reproducción, causa conocida o hipótesis, propietario,
acción siguiente y prueba de cierre. Ante recurrencia, revisar la interacción
entre componentes antes de añadir otro parche. El responsable de pruebas
devuelve el defecto al propietario; el Master evita asumir sus correcciones.

Entregar candidata identificada, guía repetible, matriz audiovisual/canal,
informe legible y limitaciones. Informar por hitos o bloqueos relevantes qué
quedó demostrado, qué falta, quién lo resuelve y el próximo resultado medible.
No medir progreso por cantidad de commits, documentos o tests.

Las decisiones locales rutinarias y reversibles siguen siendo autónomas. Este
acuerdo no añade permisos para publicar, gastar, cambiar licencias, exponer
información, destruir datos ni operar equipos remotos fuera de autorizaciones
existentes. Los cambios económicos/comerciales del ecosistema no se resuelven
mediante este contrato de pruebas.
