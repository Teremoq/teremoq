# Contrato de identidad y distribución LAN v1

Los documentos son JSON UTF-8 canónico en una línea terminada por LF. Son
objetos cerrados: todas las propiedades son obligatorias; se rechazan campos
desconocidos, duplicados, otro orden, tipos alternativos y serializaciones no
canónicas. El límite es 4096 bytes para dependencias y 8192 para player/recibo.

## Versiones separadas

- `updater_version`: `2.0.0`, versión del orquestador de distribución.
- `player_identity`: identidad inmutable de los bytes del player.
- `player_version`: versión SemVer leída de `supervisor-web/package.json`.
- `config_schema_version`: entero `1`, versión de `LAN-CONFIG.json`; no contiene
  ni identifica una configuración local concreta.

## Identidad y path inmutable

`player_identity` es `sha256:<64 hex minúsculas>` sobre estos bytes exactos:

```text
schema_version=1
source_tree=<Git tree de supervisor-web, 40 hex>
package_lock_sha256=<SHA-256 de supervisor-web/package-lock.json, 64 hex>

```

La generación y su evidencia se guardan exclusivamente como
`players/sha256-<64 hex>` y `generations/sha256-<64 hex>.json`. Un commit A y un
commit B con el mismo árbol `supervisor-web` y lock producen el mismo path. El
`source_commit` sólo aparece en el recibo/estado externo de la petición para
trazabilidad del updater; no forma parte del player ni decide su reutilización.

`build:lan` usa `player_identity` como Build ID y como semilla para normalizar
metadata aleatorio de Next. `package:lan` valida árbol, lock e identidad y no
serializa el commit. `BUILD-PROVENANCE.json`, `lan-launcher.tsv` y
`MANIFEST.sha256.json` quedan ligados a identidad/árbol/lock/versiones.

## Snapshot de dependencias v1

Sólo se admite Windows x64. El snapshot inmutable se identifica por lock,
versiones exactas Node/npm, plataforma y arquitectura. Orden exacto:

1. `schema_version`: entero `1`.
2. `status`: `npm-ci-snapshot-verified`.
3. `package_lock_sha256`: 64 hex.
4. `node_version`: `v22.<entero>.<entero>`.
5. `npm_version`: `10.<entero>.<entero>`.
6. `platform`: `win32`.
7. `architecture`: `x64`.
8. `snapshot_relative_path`: path canónico derivado de los cinco campos previos.
9. `inventory_files`: entero seguro 1..200000.
10. `total_bytes`: entero seguro 1..1073741824.
11. `inventory_sha256`: 64 hex del inventario ordenado con path, modo, bytes y
    SHA-256 de cada fichero.

En modo `node`, la primera ejecución hace `npm ci` y sella una copia de
`node_modules`; las posteriores vuelven a medir el snapshot, lo copian al
worktree y vuelven a medir la copia antes del build, sin ejecutar `npm ci`.
Ausencia parcial, symlink, adulteración, runtime/plataforma/arquitectura distinta
o evidencia abierta fallan cerrado. En modo `integration` no se consume el
snapshot: cada uno de los dos worktrees ejecuta su propio `npm ci`.

## Evidencia del player v1

Orden exacto: `schema_version`, `status=sealed-player`, `player_identity`,
`player_version`, `config_schema_version`, `source_tree`,
`package_lock_sha256`, `node_version`, `npm_version`, `platform`, `architecture`,
`created_build_mode`, `created_builds`, `build_verification`,
`manifest_sha256`, `launcher_contract_sha256`, `artifact_inventory_sha256` y
`player_relative_path`.

Los hashes son 64 hex; árbol 40 hex; versiones/runtime siguen las reglas
anteriores. `created_build_mode=integration` exige `created_builds=2` y
`double-build-byte-identical`; `node` exige `1` y `single-build`. Una petición
de integración sólo reutiliza evidencia de integración; nodo admite cualquiera
de las dos. Antes de devolver `reused` se vuelve a medir todo el artefacto.

## Recibo de distribución v1

Orden exacto: `schema_version`, `status`, `updater_version`, `player_identity`,
`player_version`, `config_schema_version`, `build_mode`, `source_commit`,
`source_tree`, `package_lock_sha256`, `node_version`, `npm_version`, `platform`,
`architecture`, `dependency_status`, `previous_source_commit`,
`source_diff_files`, `source_diff_sha256`, `builds_executed`,
`build_verification`, `manifest_sha256`, `launcher_contract_sha256`,
`artifact_inventory_sha256`, `player_relative_path`.

- `status`: `built|reused`.
- `dependency_status`: `snapshot-created|snapshot-reused-verified|`\
  `integration-npm-ci|not-used`.
- `source_commit` y `previous_source_commit`: 40 hex; el segundo también admite
  `none`. `source_diff_files` es entero seguro 0..4096.
- Construcción: integración = 2, nodo = 1. Reutilización = 0 y `not-used`.
- Verificación: `double-build-byte-identical|single-build|`\
  `reused-integration-double|reused-node-single` coherente con modo/estado.

Ningún documento incluye configuración local, URLs operativas, fingerprints,
paths absolutos, secretos, credenciales, claves o material PKI.
