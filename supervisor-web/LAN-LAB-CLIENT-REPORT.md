# LAN LAB CLIENT — MASTER REVIEW

## Hallazgos

1. El endpoint frontend LAN no puede reutilizar UDP/4433: la configuración
   cliente queda cerrada a `https://<IPv4-RFC1918>:14433/watch`. El relay
   backend en `127.0.0.1:4433` y el forwarding 14433 → 4433 permanecen fuera de
   este paquete.
2. La comprobación anterior del último octeto sólo representaba una `/24`.
   `prefix_length` es ahora obligatorio (entero 8..30) y la IPv4 se compara con
   la red y broadcast calculadas con la máscara real. También se rechazan
   subredes que salen del bloque RFC1918 correspondiente.
3. El namespace real no es estable: `gateway-rs` admite
   `TEREMOQ_MOQ_NAMESPACE` (default `teremoq/live`). Por ello `namespace` forma
   parte del contrato local exacto y aplica sus límites: ASCII, máximo 256
   bytes, segmentos no vacíos ni `.`/`..`, caracteres alfanuméricos, `-`, `_`
   y `.`.
4. Next.js 16 sirve normalmente en todas las interfaces y `connection()` vuelve
   dinámica una ruta. El launcher standalone fija `HOSTNAME=127.0.0.1`, mientras
   que `connection()` sólo queda alcanzable en `build:lan`; el build loopback
   conserva `/` estático.
5. El player LAN no necesita ninguna API del supervisor. Playback, snapshot,
   preview, operaciones y certificado HTTP quedan sin rewrites, bloqueados por
   el proxy y, para el handler de operaciones, también rechazados en origen.

## Arquitectura y lifecycle

- `TEREMOQ_LAN_LAB=1` es el único opt-in. Si el JSON local falta o es inválido,
  la UI permanece en LAN con estado `unavailable`; nunca cae a loopback.
- El contrato inmutable admite exactamente `schema_version`, `relay_url`,
  `fingerprint_sha256`, `prefix_length` y `namespace`. No acepta DNS, IPv6,
  loopback, IP pública, multicast, link-local, rangos, credenciales, query,
  fragment, otro path, otro puerto ni claves desconocidas.
- La configuración validada se vuelve a validar en el engine. WebTransport
  sigue recibiendo el SHA-256 mediante `serverCertificateHashes`; no existe
  bypass TLS, de fingerprint ni de protocolo.
- El modo LAN omite el polling Gateway por completo. El cleanup de React aborta
  readers/configuración, cancela timers y detiene la generación del engine. La
  conmutación HQ/LQ y la recuperación manual reutilizan el aislamiento por
  generación, cierre idempotente y backoff acotado existente (seis intentos,
  30 segundos), sin loop infinito.
- La matriz mantiene vídeo HQ/LQ, audio crítico y telemetría separados. Los
  datos Gateway ausentes aparecen como `NO MEDIDA` o `—`, no como cero. El
  engine conserva colas acotadas y sólo descarta vídeo delta bajo presión.
- El proxy LAN sólo admite `GET`/`HEAD` con `Host` localhost/127.0.0.1 y bloquea
  `/gateway`, `/input`, `/operations`, variantes codificadas y paths ambiguos
  con doble slash.

## Empaquetado

- `build:lan` genera el output `standalone` trazado por Next.js 16; el build
  normal no usa standalone ni `connection()`.
- `package:lan` exige un directorio nuevo fuera del checkout, copia únicamente
  el runtime trazado, `.next/static` y el launcher, y limita el paquete a
  128 MiB. No lee Git, `origin/main`, el árbol del repositorio ni el
  `node_modules` completo.
- Dos empaquetados del mismo build dieron inventarios idénticos: 1.275 ficheros,
  65.653.062 bytes de contenido y SHA-256 de manifiesto
  `124c7e9eb10fbe4f15f80c06a186ae2d2f4d46031e3cdcb0c665f24a244299de`.
  Los artefactos temporales se eliminaron tras validar.

## Inventario

- Contrato/frontera: `src/lib/lan-lab/config.ts`, tests de contrato y paquete,
  `src/proxy.ts`, tests del proxy, `next.config.ts`.
- Runtime/UI: `src/app/page.tsx`, `src/app/page.module.css`,
  `src/components/teremoq-player.tsx`, `src/lib/player/engine.ts`, defensa del
  handler de operaciones y regresiones de engine, reconnect, UI y operaciones.
- Paquete/documentación: `scripts/build-lan-lab.mjs`,
  `scripts/package-lan-lab.mjs`, `scripts/start-lan-lab.mjs`, `package.json`,
  `README.md` y este informe.
- No se añadieron dependencias y `package-lock.json` no cambió.

## Pruebas y resultados

- Node Linux `v22.22.1`.
- `npm ci`: correcto; 415 paquetes instalados, 416 auditados, 0 vulnerabilidades.
- Foco LAN: 5 ficheros, 61/61 tests.
- `npm test`: 20 ficheros, 157/157 tests.
- `npm run lint`: correcto.
- `npm run build`: correcto; `/` loopback prerenderizado estático.
- `npm run build:lan`: correcto; `/` LAN dinámico y standalone generado.
- `./node_modules/.bin/tsc --noEmit`: correcto.
- `npm audit --audit-level=high`: 0 vulnerabilidades.
- `git diff --check`: correcto.

## Límites y riesgos

- No hay ejecutable Chrome/Chromium local. Los harness `test:cadence` y
  `test:multitrack` existen, pero no se ejecutaron ni se presentó una simulación
  como interoperabilidad. La prueba E2E requiere el banco real y Chrome/Edge en
  Windows.
- Este cambio no abre UDP/14433, no configura el forwarding al backend 4433 y no
  aprovisiona certificado/fingerprint. Son precondiciones externas del banco.
- El standalone contiene únicamente las dependencias runtime seleccionadas por
  el trazado oficial de Next.js; por eso conserva un subárbol `node_modules`
  mínimo, no el árbol de desarrollo.
- No se levantó el servidor para validar el launcher, porque la coordinación
  prohíbe abrir puertos en esta tarea. Build, inventario y launcher se validaron
  sin red real.

## Estado

**READY FOR MASTER REVIEW**
