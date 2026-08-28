# Task 07 — Real-Time Web Hardening

Estado: **READY FOR MASTER REVIEW**

## Hallazgos

1. **Decoder saturado podía perder el keyframe de recuperación.** La ruta
   conservaba una referencia al `VideoDecoder` después de recrearlo y trataba
   de enviar el keyframe al decoder ya cerrado. Un test nuevo reprodujo el
   defecto; ahora se obtiene la instancia activa después del resync.
2. **El teardown no cancelaba toda la lectura.** Control y Subgroups dependían
   de `reader.cancel()` fire-and-forget, sin una señal común para handshake,
   configuración, control, aceptación de streams y readers incrementales.
3. **La entrega por alias crecía como una cadena de Promises.** Aunque los alias
   estaban separados, cada cadena podía retener Objects sin límite y no había
   una política distinta para vídeo descartable y telemetría crítica.
4. **La reconexión era infinita y filtraba detalle no estable.** Se reiniciaba
   el contador al completar el handshake, no existía presupuesto temporal ni
   jitter, y la UI incorporaba texto de error del peer y la URL completa.
5. **HQ/LQ tenía una carrera de UI.** Un callback tardío del engine anterior
   podía actualizar el snapshot después de crear el nuevo engine.
6. **La configuración de playback aceptaba relay remoto.** Se validaba el
   preview loopback, pero no HTTPS, loopback y ausencia de credenciales para el
   endpoint WebTransport.

## Arquitectura y lifecycle resultantes

- Una conexión, demuxer y decoder pertenecen a una única generación. El cambio
  HQ/LQ, reconexión, cierre o unmount invalida primero la generación y aborta su
  `AbortController`.
- La misma señal llega a `fetch`, establecimiento WebTransport, control MoQT y
  todos los `AsyncByteReader` de Subgroup. Los readers bloqueados se cancelan de
  inmediato y eliminan sus listeners.
- `MoqSession.close()` es idempotente y devuelve la misma promesa. Aborta
  readers, rechaza suscripciones, cierra colas, writer, transporte y espera los
  loops y streams activos. MP4Box detiene callbacks; el decoder invalida su
  generación; el pacer cierra todos los `VideoFrame` pendientes.
- El engine y el componente React usan guards de generación. Un callback o
  frame tardío sólo puede cerrar su recurso; no puede mutar UI, métricas ni
  canvas de la generación nueva.
- La reconexión dispone de seis intentos/30 s, backoff 250–2.000 ms y jitter
  determinista inyectable. El presupuesto sólo se restablece tras presentar un
  frame actual. Stop/cambio de Track elimina el timer inmediatamente.
- Configuración, fingerprint, autenticación inicial WebTransport, protocolo,
  codec y media incompatibles son fail-closed. La UI no reintenta esos estados.
- Un watchdog separa actividad de sesión y actividad de vídeo: vídeo sin
  progreso pasa a `stale` a los 3 s aunque telemetría continúe; peer totalmente
  silencioso inicia reconexión a los 8 s dentro del presupuesto.
- Cada alias usa una cola serial propia de 32 Objects/4 MiB. Vídeo saturado
  descarta únicamente delta y preserva el siguiente keyframe. La cola crítica
  no descarta ni agrega telemetría: un overflow cierra sólo la sesión del player.
- Los estados externos son `waiting`, `connecting`, `active`, `degraded`,
  `stale`, `unavailable` y `closed`, acompañados por razones seguras de baja
  cardinalidad. No se muestran URL completa, fingerprint, namespace,
  certificado, payload o error del peer.

## Inventario de Task 07

- `README.md`
- `TASK-07-REPORT.md`
- `src/components/teremoq-player.tsx`
- `src/components/teremoq-player.module.css`
- `src/lib/moqt/binary.ts`
- `src/lib/moqt/control.ts`
- `src/lib/moqt/delivery-queue.ts`
- `src/lib/moqt/delivery-queue.test.ts`
- `src/lib/moqt/moqt.test.ts`
- `src/lib/moqt/session.ts`
- `src/lib/moqt/subgroup.ts`
- `src/lib/player/activity-watchdog.ts`
- `src/lib/player/cmaf-demuxer.ts`
- `src/lib/player/engine.ts`
- `src/lib/player/reconnect.ts`
- `src/lib/player/reconnect.test.ts`
- `src/lib/player/video-decoder.ts`
- `src/lib/player/video-decoder.test.ts`
- `src/lib/supervisor/api.ts`
- `src/lib/supervisor/api.test.ts`

`package.json`, `package-lock.json` y `THIRD_PARTY_NOTICES.md` ya contenían
cambios al comenzar. Se preservaron literalmente y no forman parte del commit
de Task 07. No se añadieron dependencias.

## Pruebas y resultados

### Baseline

- `npm ci`: PASS, 415 paquetes instalados, 416 auditados, 0 vulnerabilidades.
  El primer intento con npm Windows falló por ruta UNC; la ejecución válida usó
  Node Linux 22.22.1 y el mismo npm/lockfile fijado.
- `npm test`: PASS, 7 ficheros / 43 tests.
- `npm run lint`: PASS.
- `npm run build`: PASS, Next.js 16.3.2, rutas `/` y `/_not-found` estáticas.
- `npm audit --audit-level=high`: PASS, 0 vulnerabilidades.

### Final

- `npm test`: PASS, 10 ficheros / 60 tests.
- `npm run lint`: PASS, sin warnings.
- `npm run build`: PASS, TypeScript y prerender estático correctos.
- `npm audit --audit-level=high`: PASS, 0 vulnerabilidades.
- `tsc --noEmit`: PASS.
- `git diff --check -- supervisor-web`: PASS.

Los tests deterministas cubren reconnect storm, jitter y cancelación; peer
silencioso; telemetría continua con vídeo stale/saturado; reader abortado;
teardown durante configuración y decode; frame de generación anterior; decoder
saturado y recuperación por keyframe; selección explícita HQ/LQ; Object tardío
y Groups obsoletos; límites de relay/namespace y colas críticas.

### E2E real

Chrome y Edge están instalados, pero no había sistema real ni harness activo:
el supervisor en `127.0.0.1:19090` no respondió y CDP en `127.0.0.1:19227`
rechazó la conexión. `test:cadence` y `test:multitrack` quedan **BLOCKED — real
system unavailable**. No se ejecutó una simulación ni se presenta unit como
interoperabilidad.

## Límites y riesgos

- El navegador no ofrece una señal portable que distinga de forma fiable un
  rechazo TLS/fingerprint de todos los fallos previos a `transport.ready`.
  Task 07 aplica la decisión conservadora: cualquier fallo de autenticación
  inicial queda fail-closed. Puede requerir acción manual ante UDP bloqueado
  antes del primer handshake.
- El receptor continúa limitado por ADR-0003 a MoQT draft-16, H.264/CMAF,
  catálogo, vídeo HQ/LQ y telemetría. No publica, no actúa como relay y no se
  convirtió en stack MoQT genérico.
- Audio crítico no se decodifica ni reproduce en browser en esta vertical. Su
  prioridad y entrega siguen siendo responsabilidad del Gateway; el mecanismo
  de cola crítica del browser se aplica a la telemetría suscrita.
- Las pruebas unitarias demuestran políticas locales y lifecycle, no
  interoperabilidad WebTransport/MoQT ni comportamiento sostenido del hardware
  objetivo. Cadence y multitrack reales siguen siendo puerta de integración.
- No se transcodifica ni se introduce ABR. HQ/LQ siguen siendo selecciones
  explícitas de representaciones ya codificadas upstream.

## Entrega

Sólo se modificaron archivos bajo `supervisor-web/**`. No se hicieron push,
fetch, PR, issue, release, despliegue ni comunicación externa. Los hashes del
commit, patch y reporte se calculan después del commit DCO y se entregan al
Master junto con este informe.
