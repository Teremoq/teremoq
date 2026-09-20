# Inventario directo de terceros — supervisor-web

Fecha de revisión técnica: 2026-08-24. Esta revisión no sustituye la aprobación
jurídica previa a distribución comercial.

| Componente | Versión | Repositorio oficial | Licencia | Uso |
|---|---:|---|---|---|
| Next.js | 16.3.2 | https://github.com/vercel/next.js | MIT | App Router, build y servidor web aislado |
| React | 19.2.8 | https://github.com/facebook/react | MIT | Componente funcional y ciclo de vida del player |
| React DOM | 19.2.8 | https://github.com/facebook/react | MIT | Renderizado de la interfaz |
| MP4Box.js | 2.4.1 | https://github.com/gpac/mp4box.js | BSD-3-Clause | Parsing ISO BMFF/CMAF y extracción de muestras AVC |
| Vitest | 4.1.11 | https://github.com/vitest-dev/vitest | MIT | Tests de desarrollo; no se incluye en runtime |
| Puppeteer Core | 25.8.0 | https://github.com/puppeteer/puppeteer | Apache-2.0 | Prueba E2E de cadencia contra Chrome; no se incluye en runtime |
| TypeScript | 5.9.3 | https://github.com/microsoft/TypeScript | Apache-2.0 | Compilación y comprobación estática; no se incluye como runtime del navegador |
| ESLint | 9.39.5 | https://github.com/eslint/eslint | MIT | Análisis estático de desarrollo |
| eslint-config-next | 16.3.2 | https://github.com/vercel/next.js | MIT | Configuración de lint para Next.js |
| @types/node | 20.19.43 | https://github.com/DefinitelyTyped/DefinitelyTyped | MIT | Tipos de desarrollo |
| @types/react | 19.2.18 | https://github.com/DefinitelyTyped/DefinitelyTyped | MIT | Tipos de desarrollo |
| @types/react-dom | 19.2.5 | https://github.com/DefinitelyTyped/DefinitelyTyped | MIT | Tipos de desarrollo |

WebTransport, WebCodecs, `VideoDecoder`, `EncodedVideoChunk`, `VideoFrame` y
canvas son APIs del navegador y no dependencias vendorizadas.

Las dependencias transitivas y sus textos de licencia se resuelven mediante
`package-lock.json`; el artefacto candidato debe generar además un SBOM y pasar
la revisión jurídica definida en `.cursorrules`.

`npm ls --all --json` y `npm ls --omit=dev --all --json` son las fuentes de
inventario reproducible para el árbol instalado. Este fichero registra las
dependencias directas; no sustituye el SBOM transitivo del artefacto candidato.

En la revisión del lockfile de 2026-08-26 se inventariaron 490 entradas, todas
con metadatos de licencia: 505 pares nombre/versión en el árbol instalado y 59
en el árbol con `--omit=dev`. Además de las licencias permisivas predominantes,
el lockfile contiene paquetes opcionales o transitivos bajo MPL-2.0, componentes
Sharp/libvips bajo LGPL-3.0-or-later o expresiones combinadas, `caniuse-lite`
bajo CC-BY-4.0, `minimatch` bajo BlueOak-1.0.0 y `argparse` bajo Python-2.0.
Su presencia en el lockfile no implica que todas las variantes de plataforma se
distribuyan. El SBOM del artefacto debe resolver el conjunto realmente incluido
y conservar sus notices antes de cualquier distribución.
