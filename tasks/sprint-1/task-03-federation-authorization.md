# Prompt para Task 03: Autorización federada SPIFFE por namespace

- Perfil propietario: `TP-SEC-PKI` (Security & PKI Engineer)
- Perfil revisor: `TP-RUST-DIST` (Rust Distributed Systems Engineer)
- Registro: `tasks/TECHNICAL-PROFILES.md`

Copia y pega íntegramente el siguiente prompt en la Task 03.

---

Actúa como Principal Rust Security Engineer y mantenedor de integración
upstream para Teremoq. Trabaja directamente en el workspace
`/home/jimbomilk/teremoq` bajo Ubuntu/WSL2.

Tu misión es cerrar, hasta donde permitan APIs públicas y mantenibles, la
separación entre autenticación mTLS y autorización federada. Un certificado
válido no debe otorgar por sí solo permiso para publicar, suscribirse o actuar
como relay sobre cualquier namespace.

## 1. Preflight obligatorio

Antes de editar:

1. Lee completamente `/home/jimbomilk/teremoq/.cursorrules`. Es la fuente de
   verdad y prevalece sobre este prompt si aparece un conflicto.
2. Inspecciona el árbol real, `Cargo.toml`, `Cargo.lock`, `deny.toml`,
   `ADR-0004-FEDERATED-MTLS.md`, `CONFIGURATION.md`, `INTEROPERABILITY.md`,
   `src/security/mtls.rs`, `examples/dev_mtls_moq_relay.rs`,
   `tests/mtls_quic.rs` y `tests/moq_relay_interop.rs`.
3. Comprueba si existe metadata Git. Si no existe, informa de la limitación de
   trazabilidad, pero no inicialices un repositorio ni borres archivos.
4. Preserva cambios existentes. No reviertas trabajo ajeno ni regeneres
   artefactos no relacionados.
5. Usa `apply_patch` para ediciones manuales. Crea las carpetas necesarias y no
   dejes módulos vacíos, placeholders, mocks presentados como producción ni
   código muerto.
6. Antes de añadir código o crates, busca una API oficial y mantenida que cubra
   la necesidad. Consulta sólo código, documentación, issues, PRs y releases
   primarias del upstream correspondiente. Registra URLs, versión o commit,
   fecha, licencia y conclusión.

## 2. Hecho técnico que debes confirmar, no ignorar

La revisión actualmente fijada de Cloudflare `moq-rs` es
`bf87128affd316463e5dcc7599a45001f222b6de`.

La inspección previa encontró que:

- QUINN dispone de `Connection::peer_identity()` después del handshake.
- `moq-native-ietf::quic::ConnInfo` sólo expone connection ID, transporte,
  direcciones y SNI; no expone la cadena de certificados cliente.
- `moq-relay-ietf::ConnectionMeta` sólo recibe IP remota/local, SNI y path.
- `Coordinator::resolve_scope` recibe el path, pero no la identidad TLS.
- `CoordinatorContext` conserva scope, interfaz y origen de relay derivado de
  socket, no una identidad X.509/SPIFFE autenticada.

Vuelve a verificarlo contra el source exacto y contra releases compatibles más
recientes. No inventes una API. IP, puerto, SNI, path, cabecera, query string o
un valor enviado dentro de MoQT no sustituyen la identidad autenticada y no se
pueden usar como principal Zero-Trust.

## 3. Objetivo funcional

El diseño final debe poder aplicar una política explícita:

`identidad SPIFFE autenticada -> rol -> operación -> namespace exacto/prefijo`

Identidades esperadas:

- `spiffe://teremoq.local/gateway/<node-id>`
- `spiffe://teremoq.local/relay/<node-id>`

Operaciones mínimas:

- `publish`
- `subscribe`
- `relay-peer`

Reglas mínimas:

1. Denegar por defecto.
2. Exigir exactamente una URI SAN SPIFFE válida dentro del trust domain
   configurado. DNS SAN, CN, SNI e IP no son principal de autorización.
3. Rechazar URI duplicada, múltiples identidades Teremoq, segmentos vacíos,
   `.`/`..`, percent-encoding ambiguo, caracteres no ASCII y IDs fuera de los
   límites existentes del proyecto.
4. Un Gateway sólo puede publicar namespaces autorizados.
5. Un subscriber sólo puede leer namespaces autorizados.
6. Un relay peer necesita autorización explícita y nunca se clasifica como
   interno sólo por IP/SNI/path.
7. El rechazo ocurre antes de aceptar registro/publicación/suscripción del
   namespace y no abre una ruta anónima de fallback.
8. Nunca registrar PEM, DER, paths privados, subject completo, serial completo
   ni datos enviados por el cliente. Los logs pueden incluir un ID estable de
   baja cardinalidad y el motivo enumerable de rechazo.

## 4. Puerta de decisión upstream obligatoria

No empieces implementando un parser o copiando el relay. Primero clasifica el
resultado en una de estas rutas.

### Ruta A: existe API pública compatible

Sólo usa esta ruta si una release o revisión oficial y mantenida permite llevar
la identidad cliente verificada hasta el punto donde se resuelven permisos y
namespaces, sin un segundo stack QUIC/TLS y sin copiar la aplicación relay.

En ese caso:

1. Documenta la API y por qué conserva MoQT draft-16/ALPN y la interoperabilidad
   existente.
2. Si requiere actualizar `moq-rs`, realiza una actualización atómica de
   `moq-native-ietf`, `moq-transport` y `moq-relay-ietf`, fijada a release exacta
   o commit completo. No uses branch, tag mutable ni `latest`.
3. Ejecuta primero las pruebas existentes para demostrar que no cambia el wire
   protocol ni Zero-Transcoding.
4. Implementa la autorización descrita en las secciones siguientes.

### Ruta B: la API sigue ausente

Si el certificado no llega de forma autenticada al punto de autorización:

1. No implementes una autorización aparente basada en IP, SNI, path o datos
   declarados por el peer.
2. No añadas dependencia directa a `quinn`, `wtransport` u otro stack para
   reconstruir el accept loop.
3. No copies `Relay::run`, no vendorizas `moq-rs`, no crees un fork silencioso y
   no uses estado global/thread-local desde `ClientCertVerifier` para intentar
   correlacionar handshakes concurrentes.
4. Crea `gateway-rs/ADR-0005-FEDERATED-AUTHORIZATION.md` con estado `Blocked by
   upstream API`, evidencia con rutas/símbolos/commit, alternativas rechazadas,
   riesgos, contrato mínimo requerido y estrategia de salida.
5. Crea `gateway-rs/upstream/moq-rs-peer-identity-proposal.md`. Si la carpeta no
   existe, créala. Describe una extensión upstream mínima y retrocompatible que:
   - obtenga la cadena autenticada mediante la API oficial de QUINN;
   - la transporte sin loguearla ni serializarla por MoQT;
   - haga disponible un principal autenticado antes de `resolve_scope`;
   - permita denegar la conexión y pasar identidad/roles al contexto de las
     operaciones de namespace;
   - conserve implementaciones actuales mediante defaults o una API nueva no
     ambigua;
   - incluya tests de certificado ausente, SPIFFE inválido, identidad no
     autorizada y dos peers concurrentes sin contaminación cruzada.
6. Busca issues/PRs upstream existentes antes de proponer uno nuevo. Incluye el
   enlace si existe. No publiques un issue o PR ni cambies dependencias sin
   autorización del usuario.
7. Añade, si es útil, un test de caracterización que demuestre la ausencia del
   principal en la API pública, pero no un test falso de autorización.
8. Declara la Task bloqueada para autorización completa, aunque la documentación
   y propuesta queden terminadas. No declares Zero-Trust completo.

La Ruta B es un resultado válido y preferible a una implementación insegura.

## 5. Implementación requerida únicamente para Ruta A

Crea sólo la estructura que resulte necesaria. La estructura recomendada es:

```text
gateway-rs/
  config/
    federation-policy.example.json
  src/
    federation/
      mod.rs
      identity.rs
      policy.rs
  tests/
    federation_authorization.rs
    fixtures/
      federation/
        README.md
        valid-policy.json
        invalid-*.json
  ADR-0005-FEDERATED-AUTHORIZATION.md
```

Puedes adaptar nombres al diseño existente, pero documenta el motivo y no
crees una segunda configuración o un segundo modelo de errores si los actuales
se pueden ampliar limpiamente.

### 5.1 Identidad

- Consume exclusivamente la cadena que el endpoint TLS ya verificó con
  `WebPkiClientVerifier`/rustls.
- No vuelvas a implementar validación de cadena, firma, vigencia o EKU.
- Para leer URI SAN usa una API oficial existente. Si rustls/webpki no la
  exponen y hace falta un crate X.509, selecciona uno mantenido, con release
  exacta y licencia B2B compatible. No escribas ASN.1/X.509 manual.
- Define tipos cerrados como `FederatedIdentity`, `FederatedRole` y
  `FederationOperation`; evita strings libres en el dominio.
- Los errores externos usan razones enumerables y estables, sin filtrar datos
  del certificado.

### 5.2 Política

- Variable obligatoria: `TEREMOQ_FEDERATION_POLICY_PATH`.
- Carga una sola vez en startup y falla antes de abrir el listener privado.
- Fichero regular, no symlink y no escribible por grupo/otros en Unix.
- JSON versionado, `deny_unknown_fields`, máximo 64 KiB, máximo 1.024
  identidades, máximo 32 reglas por identidad y máximo 256 bytes por namespace.
- Rechaza identidad o regla duplicada, roles vacíos, namespace ambiguo y
  prefijos que no respeten frontera de segmento.
- Conserva la política validada en una estructura inmutable compartida con
  `Arc`; no añadas reload en esta Task.
- El ejemplo no debe contener secretos ni identidades de producción.

Contrato orientativo, ajustable si justificas un modelo más seguro:

```json
{
  "schema_version": 1,
  "trust_domain": "teremoq.local",
  "identities": [
    {
      "spiffe_id": "spiffe://teremoq.local/gateway/gateway-dev-1",
      "roles": ["publish"],
      "namespaces": ["teremoq/live"]
    }
  ]
}
```

### 5.3 Integración y observabilidad

- Reutiliza `moq-relay-ietf` y sus permisos; no serialices frames MoQT.
- Conserva el relay browser en UDP/4433 y el laboratorio privado en UDP/4443.
- Mantén `/publish` y `/watch` como rutas de conexión, pero nunca las uses como
  prueba de identidad.
- Emite eventos JSON versionados para policy loaded, authorization allowed y
  authorization denied. Evita cardinalidad no acotada.
- No expongas la política ni identidades completas en el supervisor.
- Un fallo de autorización afecta sólo a esa conexión.

## 6. Pruebas obligatorias

Para Ruta A añade pruebas deterministas de:

1. Gateway autorizado publica namespace permitido.
2. El mismo Gateway no publica otro namespace.
3. Certificado válido de la CA pero identidad ausente de política es rechazado.
4. Certificado relay no recibe permisos Gateway.
5. Identidad con URI SAN inválida/duplicada/múltiple es rechazada.
6. Política ausente, vacía, demasiado grande, symlink, permisos inseguros,
   campos desconocidos y duplicados falla antes del bind.
7. `publish` no implica `subscribe`, ni a la inversa.
8. Prefijo `teremoq/team-a` no autoriza `teremoq/team-ab`.
9. Dos conexiones concurrentes con identidades distintas no intercambian
   principal, rol ni permisos.
10. Clientes anónimo, CA incorrecta, EKU incorrecta y handshake lento siguen
    aislados y rechazados por las capas correctas.
11. La publicación autorizada mantiene Objects MoQT upstream y
    Zero-Transcoding.

Usa PKI hermética con `rcgen` sólo en tests rápidos y la PKI Smallstep de
`infra/pki` para una integración real. No guardes claves generadas en el repo.

## 7. Documentación y dependencias

- Actualiza `CONFIGURATION.md`, `INTEROPERABILITY.md`, `DEPENDENCIES.md` y el
  ADR aplicable sólo con hechos demostrados.
- Registra toda dependencia directa nueva: upstream, versión exacta, licencia,
  propósito, owner y estrategia de actualización/retirada.
- Si no añades dependencias, dilo expresamente.
- Documenta que autorización no equivale a revocación; CRL/OCSP y recarga de
  certificados quedan fuera de esta Task.
- No declares interoperabilidad universal por probar rustls contra rustls.

## 8. Puertas de calidad

Ejecuta con el toolchain fijado y sin modificar artefactos ajenos:

```bash
cargo fmt --check
cargo check --locked --all-targets --all-features
cargo clippy --locked --all-targets --all-features -- -D warnings
cargo test --locked --all-targets --all-features
cargo deny check
cargo audit
```

Ejecuta además la integración Smallstep positiva/negativa cuando estés en Ruta
A. Si una herramienta no está instalada, usa una versión exacta en entorno
efímero o informa claramente; no instales globalmente ni ocultes la omisión.

## 9. Entrega final obligatoria

Entrega los hallazgos primero, ordenados por severidad, y después:

- ruta elegida A o B y evidencia;
- archivos creados/modificados;
- estructura de carpetas creada;
- APIs upstream y dependencias evaluadas;
- política y amenazas cubiertas, si Ruta A;
- pruebas ejecutadas con conteo y resultado;
- limitaciones y blockers reales;
- siguiente acción exacta.

No marques la autorización completa si el principal autenticado no llega al
punto donde se decide el namespace.

---
