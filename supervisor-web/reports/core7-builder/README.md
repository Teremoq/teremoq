<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Core7: adaptación mínima del builder — revisión de seguridad pendiente

## Hallazgos primero

- **PASS: 16 comprobaciones focales** en Core7.6.6 real, copia nativa Windows,
  `-NoLogo -NoProfile -NonInteractive -File`, sin Bypass. Resultado:
  [result.json](result.json). Es compatibilidad de fixtures/fronteras, no
  preparación de producto, preflight nativo ni ensayo LAN.
- **BLOCKED_BEFORE_LOAD (intento inicial)**: la primera ejecución de
  `scripts/test-build-lan-core7.ps1` mediante `pwsh -NoLogo -NoProfile
  -NonInteractive -File <ruta UNC de WSL>` terminó con código 1. ExecutionPolicy
  rechazó el script no firmado antes de cargarlo. No es una prueba de
  compatibilidad ni un fallo evaluado del wrapper. Master autorizó después
  scratch nativo con bytes/hash verificados y Bypass sólo por proceso de test
  si aún fuese necesario, nunca GPO. La copia nativa no necesitó Bypass.
- **TEST_DISCOVERY_BLOCKED (intento UNC)**: Vitest Windows sobre este worktree UNC no encontró
  tests tras normalizar su raíz a `/wsl.localhost/...`. Un intento anterior falló
  antes por el binding nativo Windows ausente en las dependencias Linux. Se
  resolvió ese binding con `NODE_PATH` al snapshot Windows existente, sin
  instalar/copiar dependencias; eso no resolvió el descubrimiento UNC. Ningún
  intento cuenta como PASS ni como ejecución de la nueva regresión Vitest.
- El canario Node existente de JSON cerrado, identidad, modos y reutilización
  **PASS**, código 0: `node.exe scripts/lan-distribution-contract.canary.mjs`.
  Es una prueba contractual, no reutilización de material real ni un build.
- `node.exe node_modules/typescript/bin/tsc --noEmit`: **PASS**, código 0.
- ESLint focal de `src/lib/lan-lab/distribution-contract.test.ts`: **PASS**, código 0.
- Vitest focal en scratch nativo: **23/23 PASS**, código 0, con
  `node.exe node_modules/vitest/vitest.mjs run src/lib/lan-lab/distribution-contract.test.ts`.
  El primer intento nativo fue 22/23: faltaba en el scratch
  `Start-LanInteractiveClient.ps1`, que el canario histórico lee como texto.
  Se copió byte a byte desde baseline107 y se verificó
  `4ecb4994a840525a00fd1084c176df94b81541b9973d79f1da608b66dfcb1629`;
  no se ejecutó ni modificó ese canal congelado. El siguiente intento fue PASS.
- Los dos primeros intentos nativos fallaron en el **harness**, no se ocultan:
  el receptor argv PowerShell emitía OEM y el helper UTF-8 lo rechazó; se fijó
  UTF-8 explícito como ya hace el wrapper. Después, el catch del test refería
  un tipo interno PowerShell no accesible; se sustituyó por comprobación del
  FQID exacto de rechazo de argumento vacío. Tercer intento: exit 0, 16 checks.
- Revisión exacta de TP-SEC-PKI: **pendiente**; el hash del commit DCO local se
  proporciona en el traspaso. No ejecutar
  Prepare de baseline107 bajo Core7 ni asumir aceptados los deltas Platform.

## Alcance y contrato acordado

Base: `107a769a54028ad985298db16a5229eb49cbd534`, tree
`cb21b8c1e96694f9a7d0605f756cbb55d523b78a`. Rama propia:
`codex/lan-web-core7`; staging de Task05 no se modifica.

Sólo cambia el wrapper existente `lan-player/Build-LanPlayerFromGit.ps1`:

1. Requiere Windows, arquitectura del proceso X64, edición Core y versión
   exacta `7.6.6` antes de cargar helpers, sondear Node, cambiar entorno o
   acceder al estado de build.
2. El ejecutable del proceso actual debe coincidir con `PSHOME/pwsh.exe` y ser
   un fichero regular sin atributo reparse. La instalación, firma y selección
   del runtime oficial son responsabilidad de Platform; este guard no sustituye
   su validación de procedencia ni instala nada.
3. Usa ese `PSHOME` validado en el PATH temporal del hijo Node, restaurando el
   entorno con el mecanismo existente. No resuelve PowerShell por PATH, no
   recae a PS5, no se relanza ni añade un parámetro genérico de ejecutable.

No cambian reproductor, protocolo, métricas, StartInteractive, Repair, canal,
contratos de estado/JSON, npm isolation ni motor de distribución/reutilización.
El caller Prepare pertenece a Platform y también debe validar su host antes de
Initialize/Reset/archive. Sus correcciones y gates no se asumen integrados aquí.

## Runtime y límites de la evidencia

Platform confirmó el servidor Microsoft portable Windows x64 7.6.6 verificado
a las `2026-09-12T15:22:18Z`, side-by-side y sin modificar PATH persistente.
SHA-256 de `pwsh.exe`, corroborado por Web antes del intento:
`bfb46af89433268872ddb43d1ca7a3f433452ee91ed356a9786940f90118e285`.
La firma Microsoft válida y procedencia del ZIP son evidencias comunicadas por
Platform, no una segunda instalación ni auditoría de firma realizada por Web.

La ruta acordada es el directorio por usuario
`AppData/Local/Programs/PowerShell/7.6.6-win-x64/pwsh.exe`, no Program Files ni
PATH global. Las focales autorizadas son exclusivamente del **servidor** vía
WSL, nunca preflight nativo, ensayo LAN o evidencia de runtime de CLIENTE-01.

El harness preparado ejecuta el guard sin modificarlo, comprueba que no cambia
entorno/CWD/encoding, y usa la frontera de procesos existente para argv/JSON
Core7 y Node, rechazo del builder completo por entrada inválida sin crear
StateRoot, y el canario contractual existente. Versiones/arquitecturas/paths
negativos son predicados extraídos del AST y fixtures, no runtimes emulados
presentados como reales. El argumento vacío debe ser rechazado por el binding
existente antes del hijo; no se amplía esa frontera.

El harness crea únicamente su carpeta UUID de evidencia bajo
`supervisor-web/evidence/managed-v2-core7-*`, con fixtures desechables en
`node_modules` y un `result.json` sólo si concluye. El resultado PASS se copió
desde el scratch al informe, sin convertirlo en evidencia audiovisual.
No crea listeners, prepara slots, accede a
certificados ni ejecuta builds/Git updates.

Hashes del intento final (las fuentes se compararon byte a byte antes de usar):

- Wrapper: `44404a231e4562d735415f59d2d801ddcb5c0a48c69e5b2ba8b28a3a8d164ca5`.
- Harness: `c5f17add899f127c63b75a97c64718f0fc50b7e16ccdcd7aa20148d6b1a61d8b`.
- Helper Platform de baseline107:
  `f5ea29cb948103a0476cfdb05378de30c07119d74234a6854dac64e419bfd90b`.
- Resultado raw generado:
  `f36a7a469922485c069a2ee020a4130b34940aa1700f5f79a9e9f3b1b76c9168`.

El JSON versionado normaliza únicamente CRLF a LF para `git diff --check`;
se conserva el raw en el scratch. Los valores no se modifican ni se atribuye
autenticidad a la mera presencia de un hash.

El SHA del ejecutable PS7 coincidió antes y después. Los hijos de las focales
terminaron mediante el helper existente; el harness terminó con exit 0.
Se conservan fuentes/fixtures y diagnósticos en el scratch propio, no son
procesos ni instalaciones. Los fallos anteriores no producen un PASS retroactivo.

La copia nativa de dependencias se midió con `measureDependencySnapshot` y se
comparó con el sidecar existente mediante `assertDependencySnapshot`: **PASS**,
23.798 ficheros, 479.765.367 bytes, inventario
`655028c47b5d7178d4a23e3e70c07321cd3bb0a08b1732600a2b2d01b2444a13`.
La caché original no se modificó. La copia inicial por WSL se interrumpió sólo
en su PID propio y se completó con Robocopy nativo (exit 1, copia correcta);
la medida íntegra posterior valida el destino, no presume completitud por ese
código de salida. No hubo `npm install`/`npm ci` ni cambios de lockfile.

## Identidad, integración y seguridad

Web tree previo: `f6d9955efad1fa43e75925706d1d5eb36871b59b`.
Lock SHA-256 conservado:
`ea213de47c167e46e5879fef9723b19f950c245fe571b9908ec6bb9a64c7c0f8`.
Cambiar el wrapper/tests/documentación cambia el tree Web y, por el contrato
existente, la identidad del player. El artefacto de la identidad anterior no es
reutilizable para esta nueva identidad aunque el reproductor no cambie.
No se altera el cálculo para eludirlo. Task05 decidirá la integración necesaria
una vez congelados y revisados los deltas; no se ejecuta aquí un build adicional.
Nodo mantiene un build si falta su nueva generación, cero sólo si ya existe y
su evidencia se valida. El snapshot de dependencias exige los mismos
Node/npm/plataforma/arquitectura/lock e inventario íntegro.

Dependencias/lockfile: sin cambios. Sin publicación, push, instalación,
credenciales, cambios de política, infraestructura remota u operaciones cliente.
No se repitieron build/build:lan/package/integración ni una auditoría de red:
el encargo es focal y no modifica dependencias. No se presenta la suite completa,
E2E, PS5, artefacto compilado o producto como revalidado por estos resultados.
Estado de entrega: **REVISIÓN PENDIENTE**, no aceptación de producto. La vía
nativa se autorizó expresamente; no acredita la vía UNC ni extrapola las
pruebas PS5 históricas. Task05 integra sólo tras DCO y revisión exacta Security.
