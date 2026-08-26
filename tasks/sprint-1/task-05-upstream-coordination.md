# Prompt para Task 05: Coordinación upstream de identidad y admisión

- Perfil propietario: `TP-RUST-DIST` (Rust Distributed Systems Engineer)
- Perfil revisor obligatorio: `TP-SEC-PKI` (Security & PKI Engineer)
- Registro: `tasks/TECHNICAL-PROFILES.md`

Copia y pega íntegramente el siguiente prompt en la Task 05.

---

Actúa bajo el perfil `TP-RUST-DIST`, Rust Distributed Systems Engineer y
mantenedor de integración upstream para Teremoq. Trabaja directamente en el
workspace `/home/jimbomilk/teremoq` bajo Ubuntu/WSL2.

Tu misión es convertir los blockers confirmados por Tasks 03 y 04 en una
propuesta upstream actual, mínima, mantenible y lista para revisión por los
mantenedores de Cloudflare `moq-rs`. Esta Task prepara la coordinación y el
paquete de contribución, pero **no abre issues, no publica PRs, no hace push y no
cambia las dependencias de Teremoq** sin una autorización posterior explícita.

## 1. Propiedad y colaboración

1. Lee `tasks/TECHNICAL-PROFILES.md` y conserva un único perfil propietario.
2. `TP-RUST-DIST` es responsable de APIs Rust, compatibilidad, concurrencia,
   lifecycle, tests y estrategia de contribución.
3. `TP-SEC-PKI` es revisor obligatorio del flujo de identidad autenticada,
   fail-closed, redacción y separación entre autenticación y autorización.
4. No crees un perfil nuevo ni una Task secundaria para dividir este trabajo.
5. Si detectas una incidencia en Task 03 o 04, documéntala para devolverla a su
   Task propietaria; no reescribas sus componentes fuera de este alcance.

## 2. Preflight obligatorio

Antes de editar:

1. Lee completamente `/home/jimbomilk/teremoq/.cursorrules`. Es la fuente de
   verdad y prevalece sobre este prompt ante cualquier conflicto.
2. Lee completamente:
   - `gateway-rs/ADR-0004-FEDERATED-MTLS.md`;
   - `gateway-rs/ADR-0005-FEDERATED-AUTHORIZATION.md`;
   - `gateway-rs/ADR-0006-FEDERATION-CONCURRENCY.md`;
   - `gateway-rs/upstream/moq-rs-peer-identity-proposal.md`;
   - `gateway-rs/upstream/moq-rs-concurrency-limits-proposal.md`;
   - `gateway-rs/Cargo.toml`, `Cargo.lock`, `deny.toml` y `DEPENDENCIES.md`;
   - `gateway-rs/examples/dev_mtls_moq_relay.rs`;
   - `gateway-rs/tests/federation_concurrency.rs` y `tests/mtls_quic.rs`;
   - `chaos/federation/README.md` y el último reporte hostile combinado.
3. Comprueba si existe metadata Git. Si no existe, registra la limitación, pero
   no inicialices un repositorio.
4. Preserva cambios existentes y no regeneres reports, PKI o artefactos ajenos.
5. Usa `apply_patch` para ediciones manuales.
6. No añadas crates, no copies código upstream, no vendorizas `moq-rs`, no
   crees un fork local y no implementes un segundo endpoint QUIC.

## 3. Descubrimiento upstream actual

La revisión fijada por Teremoq es:

`bf87128affd316463e5dcc7599a45001f222b6de`

No presupongas que sigue siendo el HEAD o que las APIs continúan ausentes.
Investiga de nuevo usando exclusivamente fuentes primarias oficiales:

- repositorio y código de `cloudflare/moq-rs`;
- releases y tags oficiales;
- issues y pull requests abiertos y cerrados;
- documentación oficial de QUINN y rustls para las versiones realmente usadas;
- `CONTRIBUTING`, plantillas y política de compatibilidad del repositorio.

Registra para cada fuente URL directa, fecha de consulta, release o commit
completo, licencia y conclusión. Busca como mínimo:

- `peer_identity`, `client certificate`, `mTLS`, `authenticated identity`,
  `principal`, `authorization`, `CoordinatorContext` y `resolve_scope`;
- `max_pending_handshakes`, `handshake timeout`, `Incoming::retry`,
  `Incoming::refuse`, `admission`, `max connections`, `session limit`,
  `FuturesUnordered`, shutdown y connection metrics.

No uses blogs, snippets, respuestas de terceros o memoria del modelo para
afirmar que una API existe o no existe.

## 4. Puerta de decisión

Clasifica el resultado en una sola ruta y documéntala.

### Ruta A: upstream ya ofrece los contratos

Selecciona Ruta A únicamente si una release o commit oficial permite:

- obtener la identidad cliente verificada de la conexión establecida;
- llevar un principal autenticado hasta autorización antes de scope/namespace;
- limitar por separado handshakes pendientes y sesiones establecidas;
- rechazar sobrecarga sin esperar en una cola de permits;
- mantener MoQT draft-16, ALPN y las rutas WebTransport/raw QUIC actuales.

En Ruta A:

1. No actualices todavía `Cargo.toml` ni `Cargo.lock`.
2. Crea un informe de adopción con APIs y símbolos exactos.
3. Define la actualización atómica necesaria de `moq-native-ietf`,
   `moq-transport` y `moq-relay-ietf`.
4. Identifica cambios de wire protocol, draft, ALPN, semver y licencias.
5. Produce el handoff exacto para una futura Task de integración Teremoq.
6. Marca las propuestas locales anteriores como superseded sólo en el informe;
   no las borres ni alteres ADRs sin que la integración haya sido aprobada.

### Ruta B: los contratos siguen ausentes

Si falta cualquiera de los contratos productivos, selecciona Ruta B y prepara
un paquete de contribución upstream. No presentes APIs parciales como solución.

## 5. Contrato de identidad requerido

La propuesta debe preservar la separación:

`certificado verificado -> principal autenticado -> rol -> operación -> namespace`

El diseño debe cumplir:

1. Obtener identidad sólo después de que QUINN/rustls complete el handshake.
2. Usar `Connection::peer_identity()` o la API oficial equivalente de la versión
   revisada; no correlacionar callbacks mediante estado global o thread-local.
3. Mantener certificados ligados al objeto de conexión/sesión.
4. No serializar certificados, principal o roles por MoQT, headers o query.
5. No registrar DER, PEM, subject, SAN, serial o identidad completa.
6. Hacer la evidencia autenticada disponible antes de `resolve_scope` y antes de
   crear Producer, Consumer o estado de namespace.
7. Permitir autorización por `publish`, `subscribe` y `relay-peer` sobre el
   namespace exacto.
8. Mantener un modo legacy explícito para compatibilidad y un builder `required`
   inequívocamente fail-closed.
9. No convertir IP, SNI, path o `ConnectionTagger` en principal autenticado.
10. Mantener la interpretación SPIFFE y la política de roles fuera de `moq-rs`;
    el upstream sólo transporta evidencia/contexto autenticado y ofrece hooks.

El revisor `TP-SEC-PKI` debe poder verificar en los documentos que un certificado
válido sin autorización no obtiene acceso a ningún namespace.

## 6. Contrato de admisión requerido

La propuesta de concurrencia debe separar al menos:

- capacidad de QUIC/TLS/WebTransport pendiente por endpoint;
- capacidad de sesiones MoQT establecidas por relay.

El diseño debe cumplir:

1. `Endpoint::accept()` obtiene primero un `quinn::Incoming`; el permit se intenta
   adquirir antes de llamar `Incoming::accept()`/`accept_with()` o iniciar trabajo
   costoso. No describas como posible adquirir un permit antes de disponer del
   `Incoming`.
2. Usar admisión inmediata tipo `try_acquire`; nunca esperar un permit para una
   conexión remota ya llegada.
3. Rechazar o reintentar mediante APIs oficiales `Incoming::refuse()` y
   `Incoming::retry()` cuando sean aplicables.
4. Aplicar un deadline monotónico absoluto a QUIC/TLS y WebTransport CONNECT; el
   idle timeout no lo sustituye.
5. Mantener el permit de handshake hasta éxito, error, timeout o cancelación de
   toda esa fase y liberarlo exactamente una vez mediante RAII.
6. Adquirir un permit de sesión independiente después del transporte y antes de
   crear la task MoQT o mutar namespaces.
7. Rechazar N+1 sin crear una cola interna ni una task de sesión.
8. Definir semántica global frente a per-endpoint para evitar multiplicación
   accidental de límites.
9. Definir cierre coordinado que cancele y drene handshakes y sesiones dentro de
   un deadline, con gauges a cero después del shutdown completado.
10. Exponer contadores y gauges de baja cardinalidad sin direcciones como labels.

## 7. Compatibilidad y división de contribuciones

Decide, basándote en la estructura y preferencias actuales del upstream, si la
contribución mantenible debe presentarse como:

- un issue de diseño y dos PRs pequeños enlazados;
- dos issues independientes y PRs secuenciales;
- otra división exigida por `CONTRIBUTING`.

No combines identidad y límites en un cambio monolítico si pueden revisarse de
forma independiente. Documenta dependencias de orden; por ejemplo, admisión de
sesión puede aceptar inicialmente metadatos opacos y después integrarse con el
contexto autenticado.

Analiza explícitamente:

- compatibilidad de source para builders y struct literals públicos;
- compatibilidad binaria cuando aplique;
- impacto semver;
- features y dependencias nuevas;
- comportamiento legacy y warnings de configuración insegura;
- WebTransport y raw QUIC;
- MoQT draft-16 y ALPN;
- ownership, lifetimes, `Send`/`Sync`, redacción de `Debug` y RAII;
- estrategia de retirada de cualquier adaptación temporal de Teremoq.

## 8. Tests upstream propuestos

El paquete debe incluir una matriz concreta de tests mantenibles en `moq-rs`:

- certificado cliente ausente;
- tipo dinámico de identidad inesperado;
- identidad válida pero no autorizada;
- rechazo antes de scope y namespace;
- dos peers concurrentes sin contaminación de identidad;
- límite de handshakes N y rechazo inmediato N+1;
- liberación por éxito, error TLS, timeout, cancelación y drop;
- QUIC Retry configurable;
- límite de sesiones N y rechazo N+1 antes de task/namespace;
- recuperación del permit al cerrar sesión;
- shutdown con handshakes y sesiones activos;
- múltiples endpoints con semántica documentada;
- regresión WebTransport/raw QUIC, ALPN, draft-16 y MoQT Objects;
- eventos y `Debug` sin material sensible.

Los tests de handshake pendiente deben usar QUINN/upstream real y control de
paquetes, nunca UDP crudo presentado como QUIC.

## 9. Estructura de entrega

Crea únicamente esta estructura, adaptándola sólo si existe una convención
upstream mejor documentada:

```text
gateway-rs/
  upstream/
    submissions/
      README.md
      discovery-2026-08.md
      peer-identity-issue-draft.md
      concurrency-admission-issue-draft.md
      contribution-plan.md
      compatibility-and-test-matrix.md
```

En Ruta A, sustituye los dos issue drafts por
`official-api-adoption-plan.md`. No crees documentos vacíos o placeholders.

`README.md` debe indicar prominentemente `NOT SUBMITTED` y explicar que ningún
contenido se ha publicado upstream.

Los issue drafts deben estar listos para copiar en GitHub e incluir:

- problema reproducible sin lenguaje comercial;
- revisión y símbolos afectados;
- impacto para embedders genéricos, no sólo Teremoq;
- propuesta API mínima e ilustrativa;
- alternativas rechazadas;
- compatibilidad;
- tests;
- preguntas concretas para maintainers;
- ausencia de claims de producción no demostrados.

No incluyas secretos, paths locales, IPs externas, logs completos o narrativa
militar/comercial del producto en una propuesta técnica upstream.

## 10. Validación

Como esta Task es documental, no ejecutes toda la suite Rust salvo que hayas
modificado source, manifests o lockfiles, algo que no está permitido por defecto.

Ejecuta al menos:

```bash
git diff --check                         # sólo si existe metadata Git
rg -n "TODO|TBD|PLACEHOLDER" gateway-rs/upstream/submissions
rg -n "NOT SUBMITTED" gateway-rs/upstream/submissions/README.md
```

Valida manualmente:

- todos los enlaces apuntan a fuentes primarias;
- commits y releases son inmutables y exactos;
- los snippets Rust son sintácticamente plausibles y se marcan como
  ilustrativos si no se compilan;
- ningún default denominado seguro mantiene fallback legacy;
- identidad y admisión pueden revisarse en contribuciones pequeñas;
- no se modificaron `Cargo.toml`, `Cargo.lock`, `deny.toml` ni código Teremoq;
- no se realizó ninguna acción externa.

Si usas una herramienta adicional, fija versión y licencia. No instales nada
globalmente.

## 11. Criterios de aceptación

La Task queda aceptable cuando:

1. La búsqueda upstream está actualizada y es reproducible.
2. La Ruta A o B está justificada con símbolos y enlaces oficiales.
3. Los dos blockers disponen de un contrato mínimo claro.
4. El wording incorrecto sobre adquirir antes de recibir `Incoming` está
   corregido.
5. La estrategia de compatibilidad y semver es explícita.
6. La matriz cubre identidad, concurrencia, cancelación y regresión de wire.
7. Los drafts están listos para revisión humana, pero marcados `NOT SUBMITTED`.
8. No se abrió issue, PR, fork o push.
9. No se añadieron dependencias ni se modificó código de producto.
10. El siguiente paso requiere una decisión concreta del Master: autorizar
    publicación, pedir ajustes o adoptar una API oficial encontrada.

## 12. Entrega final obligatoria

Presenta hallazgos primero, ordenados por severidad, y después:

- perfil propietario y revisor aplicado;
- ruta A o B;
- estado actual upstream con commit/release y fecha;
- issues/PRs relacionados encontrados;
- archivos y estructura creados;
- división recomendada de issues y PRs;
- contratos de identidad y admisión;
- compatibilidad y riesgos;
- validaciones ejecutadas;
- confirmación `NOT SUBMITTED`;
- blockers que siguen impidiendo el relay productivo;
- decisión exacta que necesita tomar el Master.

No declares resueltos Zero-Trust ni concurrencia acotada por haber preparado una
propuesta. No publiques nada externamente en esta Task.

---
