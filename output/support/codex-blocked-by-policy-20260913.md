# Codex en Windows: rechazo «blocked by policy» sin causa identificable ni vía de aprobación visible

Informe preparado el 13 de septiembre de 2026 a partir de resúmenes del equipo afectado.

## Resumen

Solicitamos ayuda para identificar una denegación persistente al solicitar desde un agente de Codex una operación de actualización Git delimitada y autorizada por el propietario del equipo. La herramienta devuelve el texto «blocked by policy», sin identificar la regla, el componente decisor ni un mecanismo de aprobación aplicable.

No solicitamos desactivar controles ni eludir una política. Necesitamos saber si el rechazo es intencionado, qué control interviene y cuál es el procedimiento admitido para resolverlo o aportar un diagnóstico útil.

## Entorno comunicado

- Equipo afectado: portátil Windows 10 Home 22H2, según información aportada por el usuario; no se ha verificado de nuevo el sistema operativo para este reporte.
- Superficie: agente utilizado mediante Codex; versión exacta de la aplicación, versión del motor y modelo de la sesión afectada no disponibles en los resúmenes consultados.
- PowerShell 7.6.6 x64 estaba instalado y verificado previamente. Esto no implica que llegara a iniciarse durante los intentos rechazados.
- Cadena de herramientas reportada: `functions.exec` → `exec_command` → respuesta con envoltorio `CreateProcess/Rejected` y texto «blocked by policy».
- Contexto administrativo declarado por el agente afectado: `approval_policy=never`, `sandbox_mode=danger-full-access`, filesystem `disabled/unrestricted`, `network_access=enabled`, con prohibición de solicitar `sandbox_permissions` o escalación por llamada.
- Esas etiquetas no demuestran ausencia de otros controles ni identifican la regla que causó la denegación.

El informe se elabora desde otro ordenador a partir de resúmenes del agente afectado. No se ha inspeccionado directamente su configuración ni se ha reproducido el error en este equipo. No se adjuntan registros brutos.

## Operación prevista

Actualización incremental de una copia Git existente e inactiva, hacia un commit exacto autorizado de un repositorio de GitHub, mediante un procedimiento PowerShell existente. Incluía comprobaciones de identidad de la copia, limpieza, versión esperada, referencia local de recuperación y avance exclusivamente fast-forward.

La operación excluía despliegue, arranque de la aplicación, cambios de credenciales, cambios de permisos, modificación de configuración privada, borrado, reset y clonación de nuevas copias.

Esta descripción no es un reproductor mínimo ejecutable. El comando original completo no se publica porque contiene contexto privado; no se afirma que un `git fetch` aislado reproduzca el problema.

## Cronología reportada — UTC

1. 2026-09-12, 23:35:19–23:37:25: primer intento delimitado. Se reportó rechazo durante el envío de la operación, con «blocked by policy».
2. 2026-09-12, 23:48:55–23:49:26: revisión de la información administrativa ya disponible. No permitió identificar motor, regla o código específico. No constaba un mecanismo de aprobación visible aplicable. Esta revisión no volvió a ejecutar la operación.
3. 2026-09-13, 08:07:21–08:08:04: una nueva solicitud ordinaria del mismo procedimiento, después de una autorización explícita adicional del usuario, volvió a recibir «blocked by policy».

Tras esa segunda denegación no se hicieron más intentos ni se cambiaron herramientas, formato del comando, privilegios o políticas para conseguir el efecto rechazado.

## Resultado observado y límites

- Ambos intentos operativos se reportaron como rechazados antes de iniciar el proceso. La ubicación «antes de CreateProcess» procede de la respuesta comunicada, no de una inspección independiente del sistema operativo.
- Se reporta que no se ejecutaron el fetch, el merge ni la creación de la referencia de recuperación.
- No se demuestra un fallo de Git ni del código del producto.
- No se ha identificado si el rechazo procede de una regla de ejecución, un control del host de herramientas, otra capa de autorización o una incidencia del entorno.
- No hay evidencia suficiente para atribuirlo al antivirus, UAC, PowerShell o a permisos de archivos.
- No se ha verificado un reproductor mínimo ni el alcance del rechazo sobre otros comandos.

## Comportamiento esperado

Si la operación está permitida, que la solicitud se tramite normalmente. Si está prohibida, que el rechazo proporcione una categoría o identificador diagnóstico suficiente, y que indique un mecanismo de aprobación o revisión admitido cuando exista. La autorización del usuario no se considera sustituto de las políticas de la plataforma.

## Impacto

La actualización del cliente y las pruebas posteriores quedan detenidas. La falta de causa o vía de diagnóstico identificable impide elegir una corrección informada.

## Ayuda solicitada

1. ¿Qué capa puede producir esta respuesta y cómo identificar la regla concreta sin volver a ejecutar la operación bloqueada?
2. ¿Qué datos mínimos de versión, sesión o diagnóstico debemos obtener en el equipo afectado y por qué vía admitida?
3. ¿Existe algún problema conocido que pueda generar este rechazo con el contexto administrativo descrito?
4. Si corresponde una política legítima, ¿cuál es el procedimiento oficial para revisarla o solicitar autorización específica?
5. ¿Qué canal privado debemos usar si necesitan el comando original o registros potencialmente sensibles?

## Privacidad

Se han excluido nombres de cuentas, direcciones de correo, IP, rutas locales, direcciones de repositorios del proyecto, commits, identificadores de sesiones, código fuente, credenciales, certificados y registros privados. Los identificadores técnicos necesarios para correlacionar una sesión se aportarían por un canal privado apropiado, tras revisarlos.

## Referencias oficiales consultadas

- https://learn.chatgpt.com/docs/reference/troubleshooting
- https://learn.chatgpt.com/docs/open-source
- https://learn.chatgpt.com/docs/agent-configuration/rules

## Incidencias posiblemente relacionadas

Se revisaron reportes existentes antes de presentar este caso:

- https://github.com/openai/codex/issues/43905 — mismo mensaje con Full Access, pero en una superficie/operación no equivalente documentada.
- https://github.com/openai/codex/issues/43633 — rechazo opaco durante diagnósticos en Windows.

No sabemos si comparten causa raíz. Este reporte aporta el caso de una actualización Git acotada y dos rechazos comunicados, incluido uno tras autorización explícita adicional. Si corresponde al mismo problema, puede vincularse o cerrarse como duplicado.
