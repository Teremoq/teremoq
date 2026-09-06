# Contrato de identidad y distribución LAN v1

Todos los documentos descritos aquí son JSON UTF-8 canónico en una sola línea,
terminada por LF. Son objetos cerrados: todas las propiedades son obligatorias,
no se aceptan propiedades desconocidas, otro orden, duplicados, números no
seguros ni serializaciones alternativas. Los parsers aplican límites de 4096
bytes a la evidencia de dependencias y 8192 bytes al resto.

## Identidad y rutas

`player_identity` es `sha256:<64 hex minúsculas>` calculado sobre estos bytes:

```text
schema_version=1
source_tree=<Git tree de supervisor-web, 40 hex>
package_lock_sha256=<SHA-256 de supervisor-web/package-lock.json, 64 hex>

```

`player_relative_path` es exactamente
`players/sha256-<64 hex>/<source_commit de 40 hex>`. El commit sigue en la ruta
porque `package:lan` lo incorpora al player; la identidad no se reduce al commit.

## Evidencia de dependencias

Orden y tipos exactos:

1. `schema_version`: entero `1`.
2. `status`: string `npm-ci-cache-verified`.
3. `source_commit`: string de 40 hex minúsculas.
4. `package_lock_sha256`: string de 64 hex minúsculas.
5. `node_version`: string `v22.<entero>.<entero>`.
6. `npm_version`: string `10.<entero>.<entero>`.
7. `cache_relative_path`: string exacto
   `npm-cache/<package_lock_sha256>/node-<node_version>/npm-<npm_version>`.

La reutilización requiere coincidencia exacta de lock, Node, npm y path. Un
directorio de cache sin esta evidencia se rechaza. `npm ci` continúa ejecutándose
en cada build; nunca se reutiliza `node_modules`.

## Evidencia sellada del player

Orden y tipos exactos:

1. `schema_version`: entero `1`.
2. `status`: string `sealed-player`.
3. `player_identity`: identidad descrita arriba.
4. `source_commit`: 40 hex minúsculas.
5. `source_tree`: 40 hex minúsculas.
6. `package_lock_sha256`: 64 hex minúsculas.
7. `node_version`: versión exacta Node 22.
8. `npm_version`: versión exacta npm 10.
9. `created_build_mode`: `integration|node`.
10. `created_builds`: entero exacto `2` para integración o `1` para nodo.
11. `build_verification`: `double-build-byte-identical` o `single-build`,
    coherente con los dos campos anteriores.
12. `manifest_sha256`: 64 hex minúsculas.
13. `launcher_contract_sha256`: 64 hex minúsculas.
14. `artifact_inventory_sha256`: 64 hex minúsculas.
15. `player_relative_path`: path exacto ligado a identidad y commit.

Una petición `integration` sólo puede reutilizar evidencia de dos builds
byte-identical. Una petición `node` puede reutilizar un artefacto de nodo o el
resultado más fuerte de integración. Antes de reutilizar se vuelve a medir el
manifest, el launcher y todo el inventario regular; symlinks y extras fallan.

## Recibo de distribución

Orden y tipos exactos:

1. `schema_version`: entero `1`.
2. `status`: `built|reused`.
3. `build_mode`: `integration|node`.
4. `player_identity`: identidad cerrada.
5. `source_commit`: 40 hex minúsculas.
6. `source_tree`: 40 hex minúsculas.
7. `package_lock_sha256`: 64 hex minúsculas.
8. `node_version`: versión exacta Node 22.
9. `npm_version`: versión exacta npm 10.
10. `dependency_status`: `created|reused-verified|refreshed|not-used`.
11. `previous_source_commit`: `none` o 40 hex minúsculas.
12. `source_diff_files`: entero seguro entre 0 y 4096.
13. `source_diff_sha256`: 64 hex minúsculas.
14. `builds_executed`: entero `2` (integración construida), `1` (nodo
    construido) o `0` (reutilizado).
15. `build_verification`: `double-build-byte-identical|single-build|`\
    `reused-integration-double|reused-node-single`, coherente con estado/modo.
16. `manifest_sha256`: 64 hex minúsculas.
17. `launcher_contract_sha256`: 64 hex minúsculas.
18. `artifact_inventory_sha256`: 64 hex minúsculas.
19. `player_relative_path`: path exacto ligado a identidad y commit.

`not-used` sólo es válido al reutilizar un player (`builds_executed=0`). Los
recibos no contienen URL operativa, configuración LAN, fingerprints, secretos,
credenciales, paths absolutos ni material PKI.
