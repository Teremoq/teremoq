# Task 12 — Dashboard Central de Operaciones

Ruta documental normalizada de la entrega y de sus correcciones de seguridad.

- [Informe canónico de Task 12](../../TASK-12-OPERATIONS-DASHBOARD-REPORT.md)
- [Evidencia desktop](../../evidence/operations-desktop.png)
- [Evidencia tablet](../../evidence/operations-tablet.png)

## Corrección posterior a Task 13

Los hallazgos `B-F01`, `B-F02` y `B-F03` se atienden mediante un commit DCO
adicional, sin modificar la superficie read-only ni las evidencias originales:

- lectura incremental y cancelación en `límite + 1` para respuestas chunked;
- apertura, verificación, lectura acotada y cierre del fixture sobre el mismo
  descriptor;
- validación cerrada de todas las estructuras anidadas y los cuatro escenarios
  del contrato Task 09 v1 aceptado por `TP-CONTROL-AUTOSCALE`;
- comprobación del SHA-256 raw del artefacto local antes de proyectarlo;
- configuración por defecto ausente, simulación explícitamente opt-in y
  proyección pública redactada sin cambios.

Este índice no declara controles mutables ni sustituye la revisión final de
`TP-SEC-PKI`.
