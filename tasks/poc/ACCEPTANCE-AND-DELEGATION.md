<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Cierre de la PoC y delegación de pruebas

Acuerdo inicial: 2026-09-09. Revisión vigente: 2026-09-12.
Decisión expresa del usuario: DOC-POC-20260912-01.
Estado: contrato de trabajo pendiente de integración por Task 05 y aceptación
del Master; no acredita ensayos, acuses, cesiones ni vigilancia ya realizados.

Esta revisión sustituye la prioridad anterior que exigía el canal propio y su
recuperación autónoma junto con el primer hito audiovisual. Conserva sus
requisitos y evidencias como hito posterior (§§ 5–6), sin declararlos aprobados
ni eliminarlos. El contenido fuente del 9 de septiembre era un documento local
sin versionar, SHA-256
`b628d8accff3a97910be6ddb4ddac9a74f1d43450fd6b506c07c28d84373ee9f`;
no estaba en el tree de la base LAN
`a74d0b476b55b0d59b13bab64555c3e17e2c655a`.

## 1. Prioridad y alcance

La prioridad es demostrar primero el ciclo de encargo verificable (§ 2.1) y
después vídeo real entre los dos ordenadores propios conectados al mismo router
(§ 4). Git distribuye código y actualizaciones a un commit exacto autorizado.
El issue privado existente `Teremoq/teremoq-lan-coordination#1` coordina
encargos, acuses, cesiones y resultados depurados; no se crea otro buzón, canal
o cliente. No se añaden launchers ni distribución por ZIP/USB.

El canal propio deja de ser prerrequisito del hito audiovisual. Su autonomía,
actualización automática y recuperación C1–C10 son un hito posterior.
Conservar código y evidencias; congelar sus mejoras salvo una dependencia real
mínima que el Master delimite y encargue al propietario correspondiente.
La asistencia registrada es admisible dentro del encargo y no demuestra
autonomía. No llamar «cierre completo de la PoC» a un hito LAN con gates
posteriores pendientes.

Reutilizar Gateway, relay, reproductor, canal, actualizador y harnesses
existentes. No crear clientes, launchers, canales o motores paralelos para
sortear problemas de integración. Separar responsabilidades y dominios de
fallo dentro de la solución existente.

Durante este cierre se aplazan nuevas funciones cloud, criptomoneda, AIOps,
dashboard comercial y administración remota general. Son admisibles la
observabilidad mínima necesaria para el ensayo y los cambios que cierren un
criterio o corrijan un riesgo relevante del alcance actual.

La progresión a 5, 10 y 25 reproductores audiovisuales reales es posterior a
la demostración básica y requiere campañas autorizadas con condiciones previas.
Los 100 espectadores del modelo simulado no acreditan capacidad audiovisual.
La prueba de aislamiento del canal con al menos dos instancias pertenece al
hito posterior C9; indicar entonces si comparten equipo y no confundirlas con
equipos físicos ni espectadores reales. Una red de 5 GHz es recomendación y
advertencia de riesgo, nunca motivo para aflojar TLS, identidad o límites.

Este contrato fija el hito inmediato. No elimina obligaciones anteriores de
seguridad, Zero-Transcoding, audio/telemetría, interoperabilidad, aislamiento,
soak o calidad que resulten aplicables. El Master debe mapear las puertas
previas a evidencias válidas o pendientes y distinguir «hito LAN aceptado» de
«PoC técnica completa» si quedan obligaciones de cierre sin satisfacer.

## 2. Propiedad y traspaso

- Master: fija alcance, prioridades, candidata y dependencias; revisa, acepta o
  devuelve entregas y asigna defectos. Sólo coordina: no desarrolla, depura,
  integra técnicamente ni ejecuta ensayos.
- Task 05: integrador técnico único, tarea
  `01a03e47-a0db-7a20-ba4a-290bf8fbd09e`. Recibe commits DCO, pathsets y
  evidencias, integra en staging aislado y entrega la candidata al Master.
- RESPONSABLE-PRUEBAS: único responsable del laboratorio, tarea existente
  `15.Platform RC100 Stabilization`, perfil `TP-PLATFORM-CHAOS`,
  `01a053e4-d0b3-74f1-84f8-03768ae84ee5`. Reserva el laboratorio, administra
  los encargos del issue, conduce la campaña, recopila evidencias y cierra
  ordenadamente sus recursos.
- CLIENTE-01: prepara y ejecuta localmente sólo encargos del
  RESPONSABLE-PRUEBAS, con acuse y lease limitada, dentro de los procedimientos
  y permisos vigentes. Ya no queda restringido a soporte de emergencia; esto
  no le concede órdenes arbitrarias, permisos administrativos nuevos ni
  capacidad para modificar alcance o candidata.
- TP-WEB-REALTIME: corrige reproductor, distribución Web y métricas de cliente.
- TP-RUST-DIST: corrige Gateway, relay e integración Rust/MoQT.
- TP-SEC-PKI: revisa identidad, autorización y recuperación de confianza.
- TP-OSS-SC: propietario documental de esta decisión y revisor de supply chain.
  TP-CONTROL-AUTOSCALE interviene sólo cuando afecte a sus contratos existentes.
  Ningún perfil asume el dominio Web, Rust o Seguridad de otro propietario.

El Master transmitirá este documento íntegro o un enlace accesible con lectura
obligatoria al agente responsable, junto con la candidata y los requisitos
previos. Pedirá confirmación de recepción y un plan que distinga el ciclo de
encargo, el hito audiovisual y C1–C10 posterior. No basta un saludo ni la
existencia de este documento para probar recepción, cesión o vigilancia.

Registrar antes de que el delegado opere el laboratorio:

| Campo de traspaso | Valor que debe registrar el Master |
| --- | --- |
| Tarea y agente responsable | Nombre e identificador de la tarea existente |
| Documento recibido | Revisión o SHA-256 de este contrato y confirmación |
| Candidata | Checkout, commit y artefactos exactos |
| Ensayo en curso | Finalizado o transferido en un punto seguro |
| Propietario del laboratorio | RESPONSABLE-PRUEBAS, periodo y cesión confirmada |
| Encargo de CLIENTE-01 | UUID, acción permitida, commit exacto y ACK |
| Lease limitada | Inicio, vencimiento, presupuesto, cancelación y recuperación local autorizada |
| Estado operativo | Procesos, puertos, equipos y tareas en curso |
| Referencias privadas | Rutas autorizadas a configuración y evidencias, sin secretos |
| Siguiente ensayo | Caso, umbrales previos, prerrequisitos y criterio de salida |

El delegado no inicia pruebas hasta recibir el traspaso del laboratorio. El
Master no ejecuta órdenes de ensayo sobre esos equipos. Mientras
tanto los especialistas pueden analizar o corregir componentes en checkouts
aislados. No interrumpir ni duplicar una prueba activa para acelerar el relevo.
El cierre/cleanup pertenece al responsable y ocurre después de terminar o
cancelar ordenadamente el ensayo, nunca concurrentemente. Abarca sólo recursos
propios identificados; conserva evidencias y verifica residuos.

### 2.1 Primer gate: encargo verificable en el issue existente

Antes del ensayo audiovisual, demostrar en orden:

1. RESPONSABLE-PRUEBAS registra un encargo de lectura con UUID único,
   destinatario CLIENTE-01, acción del procedimiento vigente, commit esperado,
   condiciones, criterio previo, plazo y lease limitada.
2. CLIENTE-01 acusa el UUID, alcance, versión del contrato y lease antes de
   actuar; confirma disponibilidad y ausencia de ensayo incompatible.
3. CLIENTE-01 observa la versión realmente instalada. Distingue commit
   solicitado, descargado e instalado/activo; un saludo o un fetch no demuestra
   que ejecute la versión autorizada.
4. Devuelve resultado depurado, estado terminal, versión observada, asistencia
   recibida y referencia opaca a evidencia privada, sin IP, rutas locales,
   secretos, credenciales, certificados ni logs crudos.
5. RESPONSABLE-PRUEBAS contrasta la evidencia y confirma recepción y aceptación
   o devolución del resultado. Sólo entonces queda cerrado el ciclo.

Usar UUID y estados del procedimiento existente, sin inventar otro protocolo,
cliente o formato ejecutable. ACK no equivale a resultado; timeout no equivale
a éxito. No repetir efectos inciertos sin reconciliarlos. La lease vence o se
revoca explícitamente; no se renueva por silencio. Al vencer no se inician
acciones nuevas y sólo se permite la parada/recuperación local ya autorizada.

Si se pierde Internet, aplicar únicamente recuperación local acotada y
preprogramada, con plazo/presupuesto y parada segura fijados antes del ensayo.
Conservar el resultado local y reconciliarlo al volver la conexión. No afirmar
vigilancia continua de GitHub sin evidencia de consultas y acuses; este encargo
documental no instala ni verifica un monitor.

El [borrador de cabecera](ISSUE-HEADER-DRAFT-20260912.md) se entrega a Platform
para actualizar la cabecera del MISMO issue conservando su historial, dentro
de su coordinación autorizada. El Master comunica alcance/aceptación;
Platform es autoridad de encargos/leases; CLIENTE-01 es ejecutor acotado.
El Master informó del comentario `5644734166`, UUID
`827e30bf-a1bc-4405-9ff8-4b0810783c36`, que comunica el cambio de rol; se registra
como evidencia referida, sin afirmar lectura ni acuse del cliente. TP-OSS-SC
no publica ni modifica el issue.

## 3. Candidata fija y criterios previos

Cada ensayo usa una versión identificada e inmutable durante la medición.
Las correcciones se incorporan a la siguiente candidata. Registrar por
separado versiones de servidor, canal, actualizador y reproductor, sus
compatibilidades y la configuración efectiva. Una prueba de actualización
debe identificar expresamente las versiones de origen y destino.

Reutilizar Git: fetch de la fuente autorizada, validación de URL/commit exacto,
checkout limpio y avance ff-only. Ante divergencia o cambios ajenos, detener
la actualización; no forzar reset ni limpiar datos. Configuración, credenciales
y evidencias permanecen fuera del código versionado. Reutilizar el player por
tree de `supervisor-web`, lockfile y dependencias verificadas; conservar los
mecanismos A/B, salud y rollback existentes. Publicación no equivale a
activación: la medición mantiene su versión fija. No ejecutar durante ella una
actualización; las correcciones se prueban en la siguiente candidata aislada.

Antes de ejecutar, fijar bitrate, codec, resolución, fps, duración, condiciones
de red, referencia temporal y umbrales de cortes, descartes, latencia, recursos,
detección y recuperación. Derivar los umbrales de requisitos aprobados y
declarar los que aún falten; no cambiarlos después para aprobar resultados.
No hace falta pedir al usuario decisiones técnicas rutinarias de bajo riesgo.

## 4. Hito audiovisual y actualización controlada

| ID | Caso | Evidencia exigida |
| --- | --- | --- |
| V1 | Arranque reproducible | Dos equipos arrancan con guía sencilla, sin editar código |
| V2 | Vídeo real | Fuente REAL → Gateway → relay → player del portátil, al menos 30 minutos; cortes, descartes, CPU, RAM y tráfico registrados |
| V3 | Latencia | p50/p95/p99, tramo, muestras, ventana y precisión; sin afirmar glass-to-glass con relojes no calibrados |
| V4 | Interrupción de red | Corte definido y vuelta de la reproducción sin reiniciar manualmente todo el sistema; tiempo medido |
| U1 | Actualización aprobada | Descarga desde Git de versión exacta autorizada, activación comprobada y configuración conservada |
| U2 | Reutilización | Cambio ajeno al player no lo recompila; componentes y dependencias sin cambios se reutilizan cuando sus verificaciones lo permiten |
| U3 | Actualización fallida | Rechazo o rollback hacia una versión funcional y gestionable, sin perder la configuración |
| V5 | Parada y limpieza | Se liberan sólo recursos propios del ensayo; evidencias conservadas y residuos comprobados |

El ciclo de lectura de § 2.1 debe estar confirmado antes de V1–V5. U1–U3
validan actualización controlada por Git y rollback existentes; no exigen
autonomía del canal propio. El responsable debe fijar umbrales de aceptación y
condiciones antes del run; si falta un umbral, el caso queda pendiente hasta
fijarlo. Ningún valor de esta tabla acredita un PASS por sí mismo.

La existencia de un proceso o un HTTP 200 no prueba reproducción audiovisual.
Registrar soporte y limitaciones de audio/telemetría y recuperar la evidencia
previa aplicable. No declarar continuidad de audio por observar vídeo fluido.

## 5. Contrato de resiliencia del canal — hito posterior, congelado

Se conserva el contrato técnico anterior para su futura campaña. Los verbos
normativos de esta sección y la matriz § 6 describen aquel hito, no una
obligación de implementar o activar el canal para V1–V5. Toda mejora queda
congelada salvo dependencia real mínima asignada por el Master al owner.
No borrar código, diagnósticos ni evidencias históricas.

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

## 6. Matriz C1–C10 — obligatoria para el hito posterior de autonomía

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

Entregar candidata identificada, guía repetible, matriz del ciclo de encargo y
audiovisual, informe legible y limitaciones. Mantener C1–C10 en una matriz
separada como hito posterior, sin convertirla en gate del primer vídeo.
Identificar por caso asistencia humana, autonomía demostrada o pendiente.
El Master acepta o devuelve la entrega; Task 05 realiza la integración técnica. Informar por hitos o bloqueos relevantes qué
quedó demostrado, qué falta, quién lo resuelve y el próximo resultado medible.
No medir progreso por cantidad de commits, documentos o tests.

Las decisiones locales rutinarias y reversibles siguen siendo autónomas. Este
acuerdo no añade permisos para publicar, gastar, cambiar licencias, exponer
información, destruir datos ni operar equipos remotos fuera de autorizaciones
existentes. Los cambios económicos/comerciales del ecosistema no se resuelven
mediante este contrato de pruebas.

## 8. Preparación referida por los owners — sin aceptación de ensayo

Platform entregó el plan local `PLAN-V1-V5-20260912-01`, SHA-256
`b051d9ca26b180b6dc1542102fed0452de3b004a1c7d3912ef71dbe58077e676`.
Sus umbrales numéricos son propuestas pendientes de aceptación previa del
Master junto con la candidata. Esta sección consolida sus límites declarados;
no reproduce pruebas de runtime ni convierte el plan en permiso de ejecución.

- La lectura READ-VERSION y el acuse del rol ampliado son evidencias distintas.
  El encargo de lectura publicado no demuestra por sí solo ACK, versión
  instalada ni confirmación final. La reserva comunicada era sólo preparación;
  no existe una lease de ensayo audiovisual concedida por este documento.
- La fuente disponible es sintética codificada y transmitida realmente,
  480×270 a 30 fps; no contiene audio ni fija bitrate explícito. El owner debe
  cerrar configuración reproducible/bitrate antes de aceptar condiciones.
  Una fuente sintética transmitida puede dar evidencia audiovisual real de
  laboratorio; no acredita cámara, producción ni soporte de audio. No sustituye
  vídeo por contadores simulados.
- El owner informa de percentiles Web sobre una ventana móvil de 512 muestras,
  snapshots cada 250 ms y exportación JSON sólo de p95. No se promedian esos
  percentiles para inventar percentiles globales de 30 minutos. La disponibilidad
  de muestras, p50/p99, stalls, drops y audio requiere cierre por Web; si falta
  evidencia, V3 o el requisito correspondiente permanece pendiente.
- PKI informa que la emisión existente también construye el endpoint relay;
  requiere una futura lease explícita de arranque loopback supervisado. No se
  autoriza esa operación aquí ni se reutiliza trust material incompatible por
  su sola vigencia. Seguridad conserva la validación de identidad y procedencia.
- Task 05/Platform refieren la vía existente Prepare-LanClientFromGit →
  Verify-Package → Invoke-LanLoad, con estado A/B pending-health y confirmación
  o rollback mediante Manage-LanClientSlots. El integrador debe vincularla a la
  candidata y el responsable al procedimiento/lease antes de ejecutarla.
  Start-LanClientFromGit e INICIAR instalan el canal; su documentación histórica
  no los convierte en vía obligatoria de este hito.
- El preflight 5 GHz existente no se cambia por esta decisión documental.
  Si un gate técnico vigente bloquea la banda disponible, registrar el bloqueo
  y devolverlo a Platform para una corrección mínima revisada; no saltarlo ni
  interpretar «recomendación» como permiso para falsificar un PASS.

La candidata, el plan y los umbrales requieren aceptación; las acciones necesitan
el encargo y la lease del responsable. Se mantienen pendientes separados de
instrumentación, bitrate, audio, PKI y autonomía. Este paquete documental no
declara un hito audiovisual aceptado.
