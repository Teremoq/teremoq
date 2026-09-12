<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Propuesta local de cabecera — DOC-POC-20260912-01

Destino previsto: issue privado existente `Teremoq/teremoq-lan-coordination#1`.
Estado: propuesta local; TP-OSS-SC no la publica. Por aclaración del Master,
Platform actualizará la cabecera del MISMO issue conservando el historial,
dentro de su coordinación autorizada, y administrará encargos/leases.
El Master informa que ya comunicó la ampliación del rol mediante el comentario
`5644734166`, UUID `827e30bf-a1bc-4405-9ff8-4b0810783c36`. Es evidencia referida
por el Master, no una consulta ni vigilancia verificada por esta Task.
El texto propuesto empieza a continuación.

---

## Coordinación de la PoC — decisión vigente del 12 de septiembre de 2026

Este issue existente coordina encargos, acuses, cesiones y resultados depurados.
Git distribuye el código a commit exacto autorizado. No abrir otro buzón ni
crear otro canal, cliente o launcher; no usar ZIP/USB para distribución.

MASTER emite sólo alcance y aceptación: fija prioridades, candidata y
dependencias, y revisa, acepta o
devuelve. No desarrolla, depura, integra técnicamente ni ejecuta ensayos.
Task 05 es integrador técnico único. RESPONSABLE-PRUEBAS es
15.Platform RC100 Stabilization / TP-PLATFORM-CHAOS: único responsable del
laboratorio, autoridad de encargos/leases y del cierre ordenado de recursos. Web, Rust y
Seguridad conservan sus dominios.

CLIENTE-01 prepara y ejecuta localmente sólo encargos del RESPONSABLE-PRUEBAS,
dentro de permisos y procedimientos vigentes, después de ACK y con lease
limitada. Cada encargo identifica UUID, acción, commit autorizado, criterio
previo, plazo y lease. Un saludo no basta. Primero demostrar un encargo de
lectura: UUID → ACK CLIENTE-01 → versión instalada observada → resultado
depurado → confirmación del responsable. Distinguir versión solicitada,
descargada y activa. No afirmar vigilancia GitHub sin evidencia verificada.

La lease no se renueva por silencio. Al vencer no se inician acciones nuevas;
la parada o recuperación sigue el plan local ya autorizado. Si Internet cae,
sólo se ejecuta recuperación local acotada preprogramada y después se
reconcilian los resultados. Un efecto incierto se verifica antes de repetirlo.
Registrar toda asistencia; la asistencia no prueba autonomía.

Tras confirmar ese ciclo, medir fuente REAL → Gateway → relay → player del
portátil durante al menos 30 minutos. Fijar antes bitrate, codec, resolución,
fps, red, sincronización, muestras y umbrales. Registrar latencia p50/p95/p99
por tramo y precisión, cortes, descartes, CPU, RAM, tráfico, interrupción,
recuperación y parada. No ajustar umbrales después de observar resultados.
5 GHz es recomendación; TLS, identidad y límites permanecen obligatorios.
Después vendrán 5/10/25 players reales: 100 simulados no prueban capacidad AV.

El canal propio y autonomía/recuperación C1–C10 pasan a un hito posterior.
Conservar código y evidencias y congelar mejoras, salvo dependencia real mínima
encargada a su owner. Mantener seguridad, vídeo, medición, interoperabilidad y
las demás puertas aplicables; no declarar la PoC completa con gates pendientes.

La versión permanece fija durante la medición. Git fetch, validación de commit
y ff-only; configuración y evidencias externas; reutilización del player y
dependencias verificadas; A/B y rollback existentes. Publicación no equivale a
activación. Cambios aislados se evalúan en la siguiente candidata. El cierre
de recursos lo realiza el responsable después del ensayo, nunca a la vez.

En este issue incluir únicamente estado, UUID, commit, resumen depurado y
referencias opacas a evidencia privada. No incluir IP, rutas, secretos,
credenciales, certificados, logs crudos ni datos operativos. La aceptación exige
evidencia contrastada y confirmación del responsable; timeout no es éxito.
