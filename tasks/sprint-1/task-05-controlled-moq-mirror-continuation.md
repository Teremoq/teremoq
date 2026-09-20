# Continuación de Task 05: Mirror privado controlado de moq-rs

- Perfil propietario: `TP-RUST-DIST` (Rust Distributed Systems Engineer)
- Perfil revisor obligatorio: `TP-SEC-PKI` (Security & PKI Engineer)
- Registro: `tasks/TECHNICAL-PROFILES.md`
- Decisión arquitectónica autorizada por el usuario: 2026-08-26

Copia y pega íntegramente el siguiente prompt en la Task 05 existente.

---

Actúa bajo el perfil `TP-RUST-DIST`, Rust Distributed Systems Engineer y
mantenedor del mirror controlado de `moq-rs` para Teremoq. Trabaja directamente
en `/home/jimbomilk/teremoq` bajo Ubuntu/WSL2.

Tu misión es crear la base auditable, privada y reproducible que permitirá
implementar los contratos de identidad y admisión bloqueados en upstream, sin
reimplementar QUIC, WebTransport o MoQT y sin introducir todavía el mirror como
dependencia de producto.

El usuario ha autorizado esta excepción de arquitectura. No es un fork
silencioso ni permanente: debe quedar documentado mediante ADR, revisión exacta,
licencias, controles de acceso, estrategia de sincronización, pruebas y salida.

## 1. Propiedad y límites de autorización

1. `TP-RUST-DIST` es el único propietario de la Task.
2. `TP-SEC-PKI` revisa privacidad del repositorio, secretos, procedencia,
   redacción y las futuras fronteras de identidad autenticada.
3. No crees perfiles adicionales ni subdividas esta Task.
4. Está autorizado crear un único repositorio privado independiente para el
   mirror y subir únicamente el baseline oficial inalterado.
5. No está autorizado:
   - crear un fork público o un fork conectado a la red pública de GitHub;
   - enviar emails o mensajes externos;
   - abrir issues, Discussions o pull requests públicos;
   - publicar drafts o código de Teremoq;
   - implementar todavía I1, I2, C1 o C2;
   - cambiar `gateway-rs/Cargo.toml`, `Cargo.lock` o `deny.toml`;
   - vendorizar source dentro del repositorio Teremoq;
   - copiar el relay o crear otro endpoint QUIC;
   - usar ramas flotantes, force-push o `git push --mirror`.
6. Si cualquier acción exige ampliar estos límites, detente y vuelve al Master.

## 2. Preflight obligatorio

Antes de editar o crear recursos:

1. Lee completamente `/home/jimbomilk/teremoq/.cursorrules`.
2. Lee completamente:
   - `tasks/TECHNICAL-PROFILES.md` y `tasks/sprint-1/README.md`;
   - `gateway-rs/ADR-0004-FEDERATED-MTLS.md`;
   - `gateway-rs/ADR-0005-FEDERATED-AUTHORIZATION.md`;
   - `gateway-rs/ADR-0006-FEDERATION-CONCURRENCY.md`;
   - todo `gateway-rs/upstream/submissions/`;
   - `gateway-rs/Cargo.toml`, `Cargo.lock`, `deny.toml` y `DEPENDENCIES.md`.
3. Preserva todos los cambios existentes y no regeneres PKI, reports o fixtures.
4. Verifica mediante fuentes oficiales actuales:
   - HEAD de `cloudflare/moq-rs/main` y `draft-18-dev`;
   - licencia y notices del commit base;
   - política vigente de visibilidad de forks y duplicación/mirroring de GitHub.
5. Registra URL, fecha, commit completo, licencia y conclusión. No uses memoria
   del modelo o fuentes de terceros para decisiones de repositorio.
6. Comprueba `gh auth status` sin imprimir tokens y verifica que la identidad
   autenticada puede crear repositorios privados bajo la organización `Teremoq`.
7. No cambies configuración Git global ni almacenes credenciales en archivos.

## 3. Modelo de repositorio obligatorio

El destino previsto es:

```text
github.com/Teremoq/moq-rs-teremoq
```

Debe ser un repositorio **privado independiente**, no un GitHub fork. La razón es
que un fork de un repositorio público pertenece a su red de forks y no sirve como
frontera privada para trabajo comercial no publicado. GitHub documenta el mirror
independiente mediante duplicación de repositorio.

Reglas:

1. Si el destino ya existe, inspecciona visibilidad, propietario, refs y contenido
   antes de actuar. No sobrescribas ni borres nada.
2. Si no existe, créalo vacío con visibilidad privada, issues y wiki desactivados.
3. Inmediatamente después de crearlo, verifica mediante API oficial que
   `visibility == PRIVATE`.
4. Si no puedes demostrar visibilidad privada, no subas ningún objeto Git y
   detente. No uses un repositorio público como fallback.
5. No uses `gh repo fork` ni `git push --mirror`.
6. En un checkout temporal fuera del workspace, configura:
   - `upstream`: `https://github.com/cloudflare/moq-rs.git`;
   - `origin`: el repositorio privado independiente.
7. Parte exactamente de:

```text
bf87128affd316463e5dcc7599a45001f222b6de
```

8. Crea y sube únicamente una rama baseline inalterada:

```text
teremoq/baseline-draft16-bf87128
```

9. La rama debe apuntar exactamente al commit oficial anterior. No añadas commits
   propios, workflows, secretos, producto o documentación Teremoq en el mirror
   durante esta Task.
10. Verifica después del push que el SHA remoto coincide y que el repositorio
    continúa privado.
11. No cambies la rama por defecto si hacerlo requiere inventar una convención;
    documenta su estado y la recomendación para la futura Task de implementación.

Si el HEAD oficial cambió, conserva el baseline aprobado anterior para
reproducibilidad y registra el nuevo HEAD. No muevas la base sin una nueva
decisión Master y una reevaluación de los blockers.

## 4. ADR de excepción

Crea:

```text
gateway-rs/ADR-0007-CONTROLLED-MOQ-MIRROR.md
```

Debe incluir como mínimo:

1. Estado `Accepted for controlled implementation`, fecha, propietarios y
   revisores.
2. Contexto: blockers demostrados por ADR-0005/0006 y paquete Task 05.
3. Decisión: mirror privado independiente, commit base exacto y cuatro contratos
   futuros I1/I2/C1/C2.
4. Justificación frente a esperar upstream, PR directo, patch local, vendoring,
   segundo endpoint y reimplementación.
5. Frontera de cambios permitidos: sólo `moq-native-ietf` y
   `moq-relay-ietf`; `moq-transport` permanece wire-compatible salvo que un test
   demuestre que necesita un ajuste explícitamente aprobado.
6. Invariantes:
   - Zero-Transcoding;
   - mismo QUIC/rustls/WebTransport;
   - MoQT draft-16 y ALPN sin cambios;
   - certificados/principal/roles nunca serializados;
   - autorización fail-closed antes de scope/namespace;
   - límites separados de handshake y sesión;
   - rechazo inmediato sin cola de permits;
   - shutdown acotado y RAII.
7. Riesgos: divergencia, mantenimiento, CVEs, MSRV, supply chain, visibilidad,
   disponibilidad del mirror y dependencia de credenciales durante builds.
8. Mitigaciones y criterios de rollback.
9. Política de sincronización sin force-push: nuevas ramas desde cada baseline
   upstream y replay auditable de commits propios.
10. Estrategia de salida: volver a releases/commits oficiales cuando cubran el
    contrato; prohibido mantener dos implementaciones activas.
11. Condiciones que obligan a parar: cambio de draft/wire, nueva dependencia,
    unsafe, segundo stack QUIC, licencia incompatible o necesidad de copiar relay.
12. Declaración explícita de que esta fase no vuelve productivo el relay.

## 5. Estructura documental y verificador

Crea la estructura necesaria:

```text
gateway-rs/
  upstream/
    mirror/
      README.md
      baseline.env
      PATCH-SERIES.md
      SYNC-RUNBOOK.md
      bootstrap-report-2026-08.md
infra/
  upstream-mirror/
    verify-private-moq-mirror.sh
```

### `baseline.env`

Debe contener sólo datos públicos/no secretos y ser sourceable por POSIX shell:

```text
MOQ_UPSTREAM_URL=https://github.com/cloudflare/moq-rs.git
MOQ_MIRROR_REPO=Teremoq/moq-rs-teremoq
MOQ_BASE_REV=bf87128affd316463e5dcc7599a45001f222b6de
MOQ_BASE_BRANCH=teremoq/baseline-draft16-bf87128
```

No incluyas tokens, usuarios locales, rutas absolutas o URLs con credenciales.

### `PATCH-SERIES.md`

Define sin implementar:

- I1: evidencia verificada ligada a conexión en `moq-native-ietf`;
- I2: contexto autenticado y autorización required en `moq-relay-ietf`;
- C1: admisión acotada de handshakes en `moq-native-ietf`;
- C2: límite global de sesiones y shutdown en `moq-relay-ietf`;
- orden, ramas futuras, dependencias y gates de revisión;
- una rama de integración futura que combine únicamente commits aprobados.

### `SYNC-RUNBOOK.md`

Documenta un proceso manual, reproducible y sin push destructivo:

1. obtener refs oficiales;
2. inspeccionar delta y licencias;
3. crear nueva rama desde un commit completo;
4. reproducir los commits Teremoq mediante cherry-pick o reimplementación
   revisada, nunca rebase/force-push sobre una línea ya consumida;
5. ejecutar gates completos;
6. cambiar pins sólo en una Task de integración autorizada;
7. conservar rollback al baseline anterior.

### `verify-private-moq-mirror.sh`

Debe ser read-only, fail-closed, compatible con Bash de Ubuntu/WSL2 y:

- cargar `baseline.env` desde una ruta relativa estable;
- requerir `git`, `gh`, `curl` y `rg` sólo si realmente se usan;
- comprobar autenticación sin mostrar credenciales;
- consultar visibilidad por API y exigir `PRIVATE`;
- comprobar que la rama baseline remota existe y apunta al SHA exacto;
- comprobar que el SHA existe en el upstream oficial;
- no clonar source, no hacer push y no modificar configuración;
- usar mensajes redactados y códigos de salida distintos para prerequisito,
  privacidad, ausencia de ref y mismatch de SHA;
- incluir `set -Eeuo pipefail`, cleanup por `trap` si crea temporales y ayuda
  `--help`.

## 6. Baseline y pruebas

Antes de aceptar el mirror:

1. Verifica que el tree SHA del baseline privado coincide con upstream.
2. Comprueba LICENSE-MIT, LICENSE-APACHE o equivalentes y SPDX de los crates
   afectados. Conserva todos los notices.
3. Ejecuta el verificador read-only al menos en:
   - configuración válida;
   - repo/ref inexistente mediante override seguro o fixture sin red destructiva;
   - SHA esperado incorrecto;
   - ausencia simulada de una herramienta requerida.
4. Si existe toolchain reproducible, ejecuta los checks upstream requeridos para
   `moq-native-ietf`, `moq-relay-ietf` y `moq-transport` en el baseline sin
   modificarlo. Si no existe, registra el blocker exacto; no declares el baseline
   compilado.
5. No uses tests Teremoq para justificar que el source upstream inalterado es
   correcto; estos sólo serán gates de integración posteriores.
6. No ejecutes Chaos en esta Task.

## 7. Seguridad y supply chain

1. El mirror no recibe secretos de producción ni claves PKI.
2. No copies GitHub tokens a Dockerfiles, logs, reports o Git remotes.
3. Recomienda least privilege, MFA y branch protection, pero no inventes que están
   activos: registra evidencia real o estado pendiente.
4. Builds productivos futuros deben pinchar commit completo, nunca branch.
5. Documenta cómo construir cuando el mirror no esté disponible y cómo conservar
   un source archive verificado sin convertirlo todavía en vendoring activo.
6. Registra licencia, procedencia, commit, tree SHA y fecha en
   `gateway-rs/DEPENDENCIES.md` sólo como candidato aprobado, sin cambiar la
   dependencia activa.
7. No añadas una dependencia, herramienta o action de terceros sin versión,
   licencia y aprobación según `.cursorrules`.

## 8. Handoff de implementación

Esta fase debe dejar definidos, pero no ejecutar, los siguientes paquetes de
trabajo de la misma Task 05 y el mismo propietario `TP-RUST-DIST`:

1. Fase identidad, con revisión `TP-SEC-PKI`: I1 + I2 en ramas privadas
   pequeñas, tests fail-closed y redacción.
2. Fase admisión, con revisión `TP-PLATFORM-CHAOS`: C1 + C2, tests QUINN reales,
   N/N+1, cancelación, shutdown y métricas.
3. Fase integración, con ambos revisores: rama de integración, pin atómico de los
   tres crates, autorización SPIFFE, chaos, ALPN/draft/Objects, rollback y
   retirada del relay de laboratorio.

No comiences todavía esas fases. Entrega al Master los símbolos, ramas y gates
exactos para redactar las continuaciones de la misma Task 05, sin crear Tasks o
perfiles duplicados.

## 9. Validación obligatoria

Ejecuta al menos:

```bash
git diff --check
bash -n infra/upstream-mirror/verify-private-moq-mirror.sh
shellcheck infra/upstream-mirror/verify-private-moq-mirror.sh
infra/upstream-mirror/verify-private-moq-mirror.sh
rg -n "TODO|TBD|PLACEHOLDER" \
  gateway-rs/ADR-0007-CONTROLLED-MOQ-MIRROR.md \
  gateway-rs/upstream/mirror infra/upstream-mirror
git status --short
```

Si `shellcheck` no está instalado, no lo instales globalmente: usa una imagen
oficial fijada por digest ya aprobada o registra la limitación.

Verifica manualmente:

- repositorio privado independiente, no fork;
- baseline remoto exacto e inalterado;
- ausencia de force-push y refs ocultas publicadas;
- ausencia de emails o comunicación externa;
- ninguna dependencia/product file modificada;
- ninguna implementación I1/I2/C1/C2 iniciada;
- ningún secreto, path local o identidad en documentación/logs;
- todos los nuevos archivos dentro de la estructura autorizada.

## 10. Criterios de aceptación

La Task queda aceptable cuando:

1. El mirror independiente existe y su visibilidad `PRIVATE` está demostrada.
2. La rama baseline apunta exactamente al commit oficial aprobado.
3. ADR-0007 justifica y limita la excepción de fork/mirror.
4. Licencia, procedencia y estrategia de actualización están auditadas.
5. El verificador read-only pasa casos positivos y negativos.
6. No se cambió el grafo de dependencias de Teremoq.
7. No se publicaron parches ni información del producto.
8. No se enviaron emails o mensajes externos.
9. Las siguientes fases de Task 05 tienen handoff claro sin haber sido ejecutadas.
10. El relay continúa marcado no productivo.

## 11. Entrega final obligatoria

Presenta hallazgos primero, por severidad, y después:

- perfil propietario y revisor aplicado;
- URL y visibilidad comprobada del mirror, sin credenciales;
- revisión upstream y rama baseline exactas;
- si el repositorio se creó o ya existía;
- ADR y estructura creados;
- licencias y procedencia;
- branch/permission controls demostrados y pendientes;
- comandos y resultados de validación;
- archivos locales modificados;
- confirmación de ausencia de cambios de producto/dependencias;
- riesgos residuales y rollback;
- handoff exacto para las fases de identidad, admisión e integración de Task 05;
- siguiente decisión concreta requerida del Master.

No declares resueltos Zero-Trust, concurrencia acotada o readiness comercial por
haber creado el mirror.
