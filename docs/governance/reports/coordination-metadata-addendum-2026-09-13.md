<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Adenda: metadatos mínimos en el canal privado existente

Fecha: 2026-09-13. Propietario documental: TP-OSS-SC.
Estado: entrega local para integración posterior por Task 05 y aceptación del
Master; no cambia la candidata ni condiciona la continuidad de la campaña.

## Origen y relación con el contrato

RESPONSABLE-PRUEBAS transmite por instrucción expresa del Master su confirmación
del 13 de septiembre a las 19:11: el MISMO issue privado
`Teremoq/teremoq-lan-coordination#1` puede transportar los metadatos mínimos
necesarios para CLIENTE-01 enumerados abajo. RP refiere observación mediante API
de `private=true` a las 19:11:48. Son autorización y evidencia comunicadas por
RP; TP-OSS-SC no ha repetido la consulta ni publicado contenido en ese issue.

La precisión se aplica a §§ 1 y 2.1 del contrato
`tasks/poc/ACCEPTANCE-AND-DELEGATION.md`, revisión DOC-POC-20260912-01, leído
en la candidata `a3c4fe3c31336584ab72a5078c7ad5d45a2c1c4e`.
La aceptación B previa de lectura LOCAL es distinta: no se interpreta como
permiso de transmisión. La base para esta excepción es la autorización expresa
posterior descrita aquí, no aquella lectura ni el carácter público del código.

## Precisión contractual mínima

En el mismo issue privado existente se permite comunicar exclusivamente la
IP LAN, el endpoint LAN, la referencia de run y el fingerprint del certificado
PÚBLICO que sean necesarios para el encargo de CLIENTE-01. Cada comunicación
debe minimizar esos campos y vincularlos al encargo vigente; no se autoriza un
inventario general de la red. Un fingerprint público no es una clave privada,
una capability ni una autorización de acceso.

Antes de transmitir esos metadatos, RP debe disponer de una comprobación actual
mediante API de que el repositorio exacto sigue con `private=true`. La observación
histórica citada no acredita privacidad indefinida. Si no puede comprobarse o
el repositorio deja de ser privado, no se envían esos metadatos y se informa al
Master; no se abre un canal alternativo. Este requisito se refiere al envío,
no impone una nueva revisión OSS ni bloquea otros trabajos autorizados.

La prohibición general de IP/certificados de §2.1 se precisa sólo en esa medida:
no se autoriza adjuntar el certificado completo ni otro material de confianza.
Siguen prohibidos claves privadas, capabilities, credenciales, tokens, volcados
de configuración y logs crudos. No se añaden rutas locales ni datos operativos
ajenos a los cuatro metadatos mínimos autorizados. No se trasladan sus valores
al código o documentación públicos. Esta adenda no incluye ningún valor real.

No se crea otro issue, canal, repositorio o correo. Permanecen intactos el
encargo/UUID, destinatario, ACK, lease limitada, acciones permitidas y cierre
del procedimiento existente. La excepción no concede órdenes arbitrarias,
permisos administrativos, bypass TLS ni cambios de identidad o candidata.
Tampoco acredita ejecución, activación del cliente, vídeo/audio o autonomía.

## Entrega y límites

Master conserva alcance y aceptación; Task 05 realiza la integración técnica
posterior. RP conserva la coordinación del issue y las leases. Esta entrega
documental no modifica integración, producto ni la candidata a3c4fe3; no abre
una nueva puerta bloqueante ni reabre las revisiones ya cerradas.

Se entrega únicamente este archivo, con SPDX Apache-2.0 y comprobación local de
whitespace y ausencia de placeholders. No se hace commit porque el índice
compartido contiene cambios ajenos; se conserva intacto. La incorporación
posterior seguirá DCO/Signed-off-by en el commit real del integrador, sin
presentar esta entrega sin commit como cumplimiento DCO ya demostrado.

Sin publicación, push, consulta o mutación remota, operaciones de cliente/AV,
instalación ni cambios de dependencias. Revisión documental técnica, no
asesoramiento jurídico.
