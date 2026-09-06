# Distribución Git local del player LAN

## Hallazgos

- El player standalone generado ocupa decenas de MiB y **no debe versionarse**.
  Git conserva únicamente fuente, lock, contrato y launcher revisables dentro
  de `supervisor-web/**`.
- Un clone nuevo de Windows 10 puede producir el player exacto sin USB, correo
  ni repositorio adicional. La salida se crea exclusivamente bajo un
  `StateRoot` exterior al checkout.
- El flujo falla cerrado si URL/ref/HEAD/árbol/limpieza, hashes de
  `package-lock.json` y `package.json`, Node 22.x o npm 10.x no coinciden.
- Checkout, StateRoot, cache, generaciones, players, worktrees y paquetes se
  fijan por identidad y `realpath`, inspeccionando todos sus ancestros. En
  Windows una política adicional abre cada directorio con un handle Win32,
  compara `GetFinalPathNameByHandleW` y rechaza cualquier atributo
  `ReparsePoint`; se revalida antes de consumo, build, comparación y promoción.
- El modo nodo reutiliza un snapshot inmutable de `node_modules` sólo tras
  revalidar lock, Node/npm exactos, Windows x64 y el inventario completo; también
  valida la copia antes de construir. Su primera ejecución usa `npm ci`. El modo
  integración no reutiliza el snapshot y ejecuta `npm ci` en ambos worktrees.
- Tras la primera generación, el estado conserva el último commit aceptado. La
  siguiente ejecución calcula un `git diff --name-status --no-renames` limitado
  a `supervisor-web`, valida paths/cardinalidad/tamaño y sella número de ficheros
  y SHA-256 del diff en la procedencia exterior.
- La identidad pública del player es SHA-256 de una serialización canónica del
  árbol Git exacto de `supervisor-web` y del SHA-256 de `package-lock.json`.
  La ruta es únicamente `StateRoot\players\sha256-<identidad>`. El commit de la
  petición se conserva fuera del player como procedencia del updater.
- El modo `integration` (por defecto) ejecuta dos builds independientes y exige
  inventario, tamaño y SHA-256 idénticos. El modo `node` ejecuta uno. Un player
  existente sólo se reutiliza si su evidencia cerrada coincide con identidad,
  commit, runtime, modo admisible e inventario medido.
- El constructor no abre puertos, no arranca el player, no lee `VERSION.tsv`,
  `LAN-CONFIG.json`, fingerprints ni evidencia y no ejecuta clone/fetch/pull,
  push o publicación. La adquisición/actualización Git es una fase explícita y
  separada.

## Contrato versionado mínimo

`lan-player/source-contract.tsv` es un TSV cerrado de veinticinco claves y máximo
4096 bytes. Fija repositorio HTTPS canónico, subdirectorio, paths y SHA-256 de
lock/package, Node 22, npm 10, scripts, salida exterior y la futura frontera
`teremoq-client`. `source_commit` se resuelve en runtime contra el HEAD exacto;
una plantilla no puede afirmar de antemano el hash de una versión futura.

`build:lan` genera `.next/TEREMOQ-LAN-BUILD.json` después de un build correcto.
`package:lan` valida ese sello cerrado y lo incorpora como
`BUILD-PROVENANCE.json`; el manifest y `lan-launcher.tsv` conservan el mismo
`player_identity`, árbol y lock. Un `.next` antiguo, otro árbol o herramientas
distintas no se pueden empaquetar como el player actual; el commit exterior no
entra en sus bytes.

Next 16 genera metadata aleatorio para Draft/Preview aunque el cliente LAN no
expone esa capacidad. Durante el empaquetado se valida exactamente esa
subestructura en la copia exterior y se normaliza con dominio y commit
públicos. No se cambia el build del checkout, no se acepta entrada externa y no
se toca material TLS/PKI. Esto elimina el único origen conocido de bytes
aleatorios sin convertir Draft Mode en una capacidad del cliente.

Next 16 también serializa el path absoluto del directorio de build en cuatro
campos conocidos de `required-server-files.json`. El empaquetador exige esos
campos exactos y los convierte a `.` en la copia portable. Rechaza cualquier
aparición adicional del path local, por lo que el paquete no queda ligado a un
worktree ni revela su nombre. La misma validación exacta se aplica al
`nextConfig` embebido por Next en `server.js`; el directorio efectivo de runtime
continúa siendo `__dirname` dentro del player promovido.

El token interno aleatorio de Server Actions se normaliza únicamente cuando los
manifests JS/JSON concuerdan y sus mapas `node` y `edge` están vacíos. Este
cliente no usa esa capacidad: si una versión futura añade una Server Action,
el paquete falla cerrado en vez de normalizarla silenciosamente.

## Primer clone en Windows 10

Instalar Git for Windows, Node 22.x y npm 10.x. En PowerShell 5.1:

```powershell
$Repository = 'https://github.com/Teremoq/teremoq'
$Branch = '<rama aprobada por Master>'
$Checkout = 'C:\Teremoq\source'
$StateRoot = 'C:\ProgramData\Teremoq\lan-client'

git clone --origin origin --branch $Branch --single-branch $Repository $Checkout
if ($LASTEXITCODE -ne 0) { throw 'git clone failed' }

$Commit = (git -C $Checkout rev-parse HEAD).Trim()
$Ref = (git -C $Checkout symbolic-ref --quiet HEAD).Trim()
& "$Checkout\supervisor-web\lan-player\Build-LanPlayerFromGit.ps1" `
  -CheckoutRoot $Checkout `
  -StateRoot $StateRoot `
  -RepositoryUrl $Repository `
  -RepositoryRef $Ref `
  -SourceCommit $Commit
```

El primer `npm ci` descarga exclusivamente las dependencias fijadas por el lock
desde sus orígenes públicos. El constructor fuerza `userconfig` y
`globalconfig` vacíos, registry público exacto, prefix/cache exteriores y
HOME/USERPROFILE/APPDATA/LOCALAPPDATA aislados; elimina variables npm/proxy del
operador, rechaza `.npmrc` en checkout/proyecto y comprueba con npm 10 su
configuración efectiva antes de cada instalación. No se usa
`--offline` en la primera instalación salvo que el cache hash-bound ya haya
sido aprovisionado por un mecanismo revisado.

La salida JSON cerrada devuelve `status` (`built|reused`), `build_mode`,
`builds_executed`, verificación, identidad y digests. `player_relative_path` es
`players/sha256-<player_identity>`. Platform debe resolverla bajo el `StateRoot` y usar
ese directorio como player. No debe esperar ni copiar un
`supervisor-web/lan-player` generado dentro del checkout.

## Actualización y rebuild

La actualización Git permanece visible y auditable:

```powershell
git -C $Checkout status --short
git -C $Checkout fetch --prune origin
git -C $Checkout switch $Branch
git -C $Checkout pull --ff-only origin $Branch

$Commit = (git -C $Checkout rev-parse HEAD).Trim()
$Ref = (git -C $Checkout symbolic-ref --quiet HEAD).Trim()
& "$Checkout\supervisor-web\lan-player\Build-LanPlayerFromGit.ps1" `
  -CheckoutRoot $Checkout `
  -StateRoot $StateRoot `
  -RepositoryUrl $Repository `
  -RepositoryRef $Ref `
  -SourceCommit $Commit
```

El constructor rechaza cambios tracked o untracked, detached HEAD, ref que no
resuelva al commit, más de un remote, URL no exacta y un directorio de salida
existente sin evidencia sellada coincidente. Su JSON de resultado incluye el commit anterior,
el número de paths cambiados y el SHA-256 del diff que comparó.

Si cambió `package-lock.json`, la primera ejecución se detiene antes de
construir. Tras revisar el diff y autorizar el nuevo lock, repetir únicamente
la construcción con `-RefreshDependencies`:

```powershell
& "$Checkout\supervisor-web\lan-player\Build-LanPlayerFromGit.ps1" `
  -CheckoutRoot $Checkout `
  -StateRoot $StateRoot `
  -RepositoryUrl $Repository `
  -RepositoryRef $Ref `
  -SourceCommit $Commit `
  -RefreshDependencies
```

`-Offline` exige que el cache del SHA-256 actual ya esté completo y falla si
falta un paquete. No relaja ninguna validación de Git o procedencia.

## Salida exterior y límites de responsabilidad

El estado generado queda en:

```text
StateRoot/
  .teremoq-web-build/                         cache y evidencias JSON
  players/sha256-<identity>/                 player promovido y manifests
```

Los worktrees temporales se eliminan incluso ante error. Una generación previa
no se sobrescribe. El flujo no selecciona configuración LAN, no compone
evidencia y no concede capacidades; esas tareas siguen en Platform. Una futura
extracción a `teremoq-client` reutilizará este contrato de fuente/lock/salida,
pero este cambio no crea ni supone ese repositorio.

Canarios locales relevantes:

```powershell
& .\supervisor-web\scripts\test-windows-path-policy.ps1
```

El canario crea junction padre, junction intermedio y un symlink de directorio
si el host concede el privilegio; si no, exige un tercer junction como reparse
leaf y lo etiqueta explícitamente. Los tests Vitest cubren además symlinks en
cada posición, sustitución posterior de inode/handle y un global npmrc hostil
con registry, proxy y token señuelo. Los schemas v1 de recibo, evidencia de
dependencias y evidencia de artefacto rechazan campos desconocidos, faltantes,
orden o serialización no canónica; no contienen configuración LAN, secretos ni
material de identidad.

Para el modo reducido de un único nodo de ejecución, Platform añade
`-BuildMode node` al launcher (que emite `--build-mode node`). La omisión conserva el modo
`integration` de dos builds; no cambia `npm run build` ni `build:lan`.
