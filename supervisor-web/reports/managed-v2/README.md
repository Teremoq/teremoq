# Reparación de composición del launcher managed-v2

## Hallazgos y puertas pendientes

La base `a74d0b476b55b0d59b13bab64555c3e17e2c655a` preparaba un estado
Platform v2 que el launcher Web rechazaba por ruta, VERSION y configuración.
Esta reparación conecta esas fronteras existentes. **No acredita arranque,
LAN, reproducción, 30 minutos, audio ni cierre de seguridad de la integración.**

El invocador debe fijar el script y todas sus dependencias **antes de cargarlo**.
El autocheck de un script ya cargado no evita su sustitución previa. Platform
es propietario de esa corrección F01 y Task05 de la prueba integrada con
artefacto construido y sellado; ambas requieren revisión TP-SEC-PKI. El commit
Platform inicial `b99231f639667e6c55015808698ae85db73e5680` no basta por sí solo.
Task05 comunicó aprobación de seguridad del invocador corregido
`e47a223e05973897f4cd3095b49811863294fd9c`; será la referencia de composición.
Esa aprobación no cubre todavía este launcher Web ni la sesión AV posterior.

## Contrato acordado con Platform

No se añade launcher, cliente, canal ni action al TSV:
`actions=start,status,stop,collect` sigue intacto.

```powershell
# Mismo proceso PowerShell 5.1; ValidateOnly no crea EvidenceDirectory.
& $state.LauncherPath -Action Start -ValidateOnly `
  -StateRoot $state.StateRoot -RunId $run -Level 1 `
  -VersionPath $state.VersionPath -FingerprintPath $state.FingerprintPath `
  -EvidenceDirectory $evidence
# Start utiliza los mismos parámetros, sin ValidateOnly, y revalida todo.
```

`ValidateOnly` sólo admite `Start`. Devuelve JSON cerrado con `schema_version=1`,
`status=validated`, `run_id`, `level`, `updater_commit` y `player_identity`.
No arranca Node, no ejecuta `node --version`, no prueba puertos, no asigna env,
no crea directorios, ni escribe estado o logs. No reserva el puerto ni promete
readiness. El uso del API nativo de Windows se enlaza mediante Reflection.Emit,
sin `Add-Type`/compilador externo. No importa módulos de infraestructura.

La selección A/B sigue perteneciendo a Platform. Web verifica:

- `StateRoot/control/active.json`: las 14 propiedades cerradas del productor
  `New-TeremoqLanSlotRecord`, tipos exactos, versión `2.0.0` y protocolo
  `teremoq-lan-updater-v3`.
- Identidad = SHA-256 ASCII de
  `schema_version=1\nsource_tree=<tree>\npackage_lock_sha256=<hash>\n`.
- Player exacto `StateRoot/players/sha256-<identityHex>`; slot exacto
  `StateRoot/versions/u-<updater_commit>-p-<identityHex>` seleccionado en active.
- VERSION v2 de 14 claves, CLIENT-COMPATIBILITY v2 de 16 claves y SHA256SUMS
  cerrado de dos entradas, cruzados con active, manifest y contrato.
- Config exterior de **seis** claves en `StateRoot/config/LAN-CONFIG.json` y pin
  exacto en `StateRoot/config/public-identity/relay-cert.sha256`.
- Config canónica RFC1918 HTTPS `:14433/watch`, no `/publish`, con namespace,
  prefijo, IP unicast y fingerprint coherentes. No se leen claves/capabilities.

`updater_commit` se añade en memoria como `source_commit` a la configuración
runtime de siete claves ya consumida por Web. Significa **procedencia del
updater de esa ejecución**, nunca identidad o commit de compilación del player.
Config6 y bytes del player no se reescriben al cambiar de updater. Una env
heredada distinta se rechaza; el Start conserva su restauración del entorno
tras crear el hijo. `ValidateOnly` no lo modifica en ningún momento.

## Límites y conservación de integridad

Active, TSV y SHA256SUMS: 4096 bytes; config y runtime enriquecido: 512;
fingerprint: 128; manifest y script: 1 MiB; inventario: hasta 10000 ficheros,
20000 entradas incluidas carpetas, paths relativos de 512 caracteres y 128 MiB
totales. Ficheros extra, ausentes, enlaces/reparse en cualquier ancestro,
duplicados, escapes JSON no canónicos, tipos y propiedades desconocidas fallan
cerrados. El JSON se parsea con la implementación nativa y se contrasta su
representación canónica; no se inventa otro parser JSON.

Tamaño, parsing y hash se calculan sobre el mismo descriptor, con lectura
incremental y comprobación de EOF. Se verifica la ruta final del descriptor.
Los handles `FileShare.Read` se mantienen durante toda la validación/acción,
incluidos manifest y ficheros ejecutables/dependencias, y se liberan en
`finally`, también ante error. Esta retención no sustituye el pin previo del
invocador ni es una atestación de integridad de toda la vida del Node después
de retornar el launcher.

## Pruebas reproducibles

```powershell
# Desde checkout Windows/UNC accesible; no ejecuta el producto ni abre LAN.
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\supervisor-web\scripts\test-managed-launcher.ps1
```

El canario usa el productor de slots real de Platform de la base, el launcher
Web real y ficheros de prueba con hashes reales. **server.js y el validator
de esos fixtures son sentinelas que nunca se ejecutan**, no un build de Next.
No se presenta esta prueba como `Prepare` completo ni como artefacto AV real.
Los materiales regenerables quedan en `evidence/managed-v2-*/node_modules/`
(excluidos del descubrimiento de tests/lint), con resumen en `result.json`.
No contienen observación de navegador ni credenciales.

Casos: cuatro niveles, ausencia de efectos, locks retenidos hasta el receipt y
liberados después, active duplicado/desconocido/bool/ausente/excesivo,
identidad/slot erróneos, VERSION v1/duplicado/commit incoherente, hashes cruzados,
config7/duplicada/excesiva/bool/host público/`publish`, overflow al enriquecer,
pin distinto/ruta ajena, inventario extra/ausente/cambiado y límites/tipos
anidados del manifest. Las comprobaciones de fuente TypeScript están etiquetadas
explícitamente como estructurales, no E2E.

Puertas locales previas al commit: `npm test` (283 tests), `npm run lint`,
`tsc --noEmit` después del build y `npm run build` pasan. Runtime Linux
Node 22.22.1, npm 10.9.8, Next 16.3.2, lockfile sin cambios; dependencias
reutilizadas de instalación local con el mismo lockfile. PowerShell 5.1 real:
**39 canarios PASS**, resultado en [ps51-result.json](ps51-result.json).
`npm audit --offline --audit-level=high` devuelve cero vulnerabilidades según
la caché, **no una consulta actual al registro**. No se ha usado red.
`build:lan` y `package:lan` exigen commit limpio y se ejecutan tras congelarlo;
sus resultados/hashes se entregan como evidencia poscommit, sin falsificar
procedencia de un build dirty. El primer `tsc` sin tipos Next generados falló;
pasó después de `build`. La copia inicial de deps Windows se apartó de forma
recuperable antes de usar los bindings Linux; no se actualizó ninguna dependencia.

## Composición pendiente del integrador

Task05 debe integrar los commits Web y Platform corregido (no el wrapper F01),
congelar HEAD, y ejecutar el recorrido existente `Prepare-LanClientFromGit` →
`Verify-Package` → `Invoke-LanLoad -Action Validate` contra **ese mismo
artefacto Windows construido y sellado**. Requisitos: Windows/PowerShell 5.1,
Node 22/npm 10, Git aprobado, checkout limpio, caché/snapshot de dependencias
verificado, configuración pública del banco y StateRoot separado del checkout.
No sustituir el build/receipt por los fixtures de este informe. Sin caché
disponible debe declararse esa puerta pendiente, no habilitar descargas aquí.
La validación estática no necesita fuente de vídeo, listeners ni canal propio.

No se modifica `/`, decoder, MoQT, audio, métricas, evidencia baseline, dashboard
ni carga ligera. No hay nuevas dependencias, cambios infra/PKI, credenciales,
push, publicación, fetch, despliegue o recursos remotos. Entrega Web revisable;
aceptación de composición y seguridad todavía pendientes de Task05/TP-SEC-PKI.
