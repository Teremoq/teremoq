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

WebTransport, WebCodecs, `VideoDecoder`, `EncodedVideoChunk`, `VideoFrame` y
canvas son APIs del navegador y no dependencias vendorizadas.

Las dependencias transitivas y sus textos de licencia se resuelven mediante
`package-lock.json`; el artefacto candidato debe generar además un SBOM y pasar
la revisión jurídica definida en `.cursorrules`.
