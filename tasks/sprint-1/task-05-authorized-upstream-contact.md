# Continuación autorizada de Task 05: contacto inicial upstream

- Perfil propietario: `TP-RUST-DIST` (Rust Distributed Systems Engineer)
- Perfil revisor obligatorio: `TP-SEC-PKI` (Security & PKI Engineer)
- Task: continuación de Task 05; no es una Task ni un perfil nuevos
- Autorización del Master/usuario: 2026-08-26

Copia y pega íntegramente el siguiente prompt en la Task 05 existente.

---

Continúa en la Task 05 existente bajo el perfil `TP-RUST-DIST`, con revisión
obligatoria de `TP-SEC-PKI`. Trabaja directamente en
`/home/jimbomilk/teremoq` bajo Ubuntu/WSL2.

El Master y el usuario autorizan exclusivamente un contacto inicial y acotado
con los mantenedores oficiales de `cloudflare/moq-rs` para preguntar qué canal y
división de contribuciones prefieren. Esta autorización no permite abrir issues,
Discussions o pull requests, crear forks o branches, hacer push, publicar código,
compartir el repositorio privado de Teremoq ni cambiar dependencias.

## 1. Preflight obligatorio

1. Lee completamente `/home/jimbomilk/teremoq/.cursorrules`.
2. Lee completamente:
   - `tasks/TECHNICAL-PROFILES.md`;
   - `tasks/sprint-1/README.md`;
   - los seis documentos de `gateway-rs/upstream/submissions/`;
   - `gateway-rs/upstream/moq-rs-peer-identity-proposal.md`;
   - `gateway-rs/upstream/moq-rs-concurrency-limits-proposal.md`.
3. Preserva todos los cambios existentes. No modifiques código Rust, manifests,
   lockfiles, dependencias, tests, PKI, Chaos, ADRs o frontend.
4. Confirma mediante fuentes primarias oficiales el `HEAD` actual de `main`, el
   estado de `draft-18-dev`, la política de contribución y los canales oficiales
   disponibles justo antes de contactar.
5. Si `main` ya no es
   `bf87128affd316463e5dcc7599a45001f222b6de`, inspecciona el delta oficial para
   identidad, autorización y admisión. Si alguno de los contratos apareció o la
   Ruta B puede haber cambiado, no envíes un mensaje obsoleto: actualiza sólo el
   discovery propiedad de Task 05 y vuelve al Master.

## 2. Descubrimiento del canal

Usa únicamente superficies oficiales del proyecto u organización:

- `cloudflare/moq-rs` y su metadata oficial;
- README, CONTRIBUTING, SECURITY, CODEOWNERS y `.github` si existen;
- GitHub Discussions, organización o perfiles oficiales de maintainers;
- un email o canal comunitario sólo si el propio proyecto lo presenta como canal
  para contribuciones o discusión de diseño.

No uses un canal de vulnerabilidades para una propuesta de funcionalidad, no
contactes cuentas personales obtenidas de fuentes no oficiales, no hagas contacto
masivo y no secuestres comentarios de issues o PRs no relacionados.

Si no existe un canal directo oficial que permita realizar la pregunta sin abrir
un issue, Discussion o PR, detente. Documenta las opciones oficiales encontradas
y solicita al Master una autorización específica para una de ellas.

## 3. Mensaje autorizado

Antes de enviarlo, `TP-SEC-PKI` debe revisar que no incluya identidades, paths
locales, certificados, logs, IPs, secretos, datos comerciales, narrativa militar
ni afirmaciones de producción no demostradas.

Puedes adaptar únicamente saludo, nombre del canal y referencia al commit actual.
No amplíes preguntas ni adjuntes documentos o código sin volver al Master.

```text
Subject: moq-rs embedder API design: verified peer context and bounded admission

Hello moq-rs maintainers,

We are evaluating two independent generic embedder gaps against the current
moq-rs main revision:

1. making connection-bound QUINN/rustls verified peer evidence available to
   relay authorization before scope or namespace state is created; and
2. immediate, separate admission bounds for pending native handshakes and
   established relay sessions, including bounded shutdown.

We have prepared design drafts and test matrices, but have not opened an issue,
prepared a pull request, or published code. Issue creation appears to be
restricted. Which official channel would you prefer for discussing these two
designs? Would you prefer two independent design threads with small crate-scoped
PRs, or two focused cross-crate PRs?

The proposals preserve the existing MoQT draft, ALPNs, WebTransport/raw QUIC wire
behavior, and keep deployment-specific identity and authorization policy outside
moq-rs. At this stage we only need guidance on the discussion channel and review
shape.

Thank you.
```

## 4. Envío y límites

1. Envía una sola vez y a un único canal o punto de contacto oficial.
2. No compartas links al repositorio privado ni a archivos locales de Teremoq.
3. No pegues todavía los issue drafts completos.
4. No abras recursos públicos nuevos si el canal requiere hacerlo.
5. No negocies cambios de wire, draft, trust model, dependencias o breaking API.
6. Si el mantenedor pide cualquiera de esas acciones, agradece la orientación y
   vuelve al Master sin ejecutarla.
7. No interpretes silencio, una reacción o una respuesta informal como aprobación
   técnica.

## 5. Trazabilidad documental

Crea, sólo dentro del alcance de Task 05:

```text
gateway-rs/upstream/submissions/contact-log-2026-08.md
```

El fichero debe registrar sin secretos:

- estado `CONTACTED`, `NOT CONTACTED` o `RESPONSE RECEIVED`;
- fecha y hora UTC;
- commit de `main` verificado antes del contacto;
- URL oficial del canal o descripción del medio directo;
- por qué el canal estaba autorizado;
- texto exacto finalmente enviado, o motivo exacto por el que no se envió;
- alcance que continúa sin autorizar;
- estado de respuesta y siguiente decisión requerida del Master.

Actualiza `gateway-rs/upstream/submissions/README.md` para enlazar el registro,
sin retirar `NOT SUBMITTED` de los drafts. Si se realizó el contacto, distingue
claramente entre `CONTACT MADE` y `DESIGN NOT SUBMITTED`.

No registres tokens, cookies, headers, usernames privados, emails no publicados,
configuración de credenciales ni output completo de herramientas autenticadas.

## 6. Validación

Ejecuta al menos:

```bash
git diff --check
rg -n "TODO|TBD|PLACEHOLDER" gateway-rs/upstream/submissions
rg -n "NOT SUBMITTED|CONTACTED|NOT CONTACTED|RESPONSE RECEIVED" \
  gateway-rs/upstream/submissions
git status --short
```

Verifica manualmente que:

- sólo cambió documentación propiedad de Task 05;
- el contacto coincide con el mensaje y alcance autorizados;
- no se abrió issue, Discussion, PR, fork o branch;
- no se publicó código ni se cambió ninguna dependencia;
- no se expuso información de Teremoq;
- el resultado no declara resueltos los blockers.

No ejecutes suites Rust para cambios puramente documentales.

## 7. Entrega obligatoria

Presenta primero cualquier incidencia y después:

1. perfil propietario y revisor aplicado;
2. revisión upstream comprobada;
3. canales oficiales encontrados;
4. si se contactó o se detuvo de forma segura;
5. canal y texto exacto enviado, si aplica;
6. archivos modificados;
7. validaciones ejecutadas;
8. confirmación de todas las acciones que siguen sin autorizar;
9. respuesta recibida o estado pendiente;
10. siguiente decisión exacta que necesita tomar el Master.

No continúes con una segunda comunicación ni con una contribución técnica hasta
recibir otra autorización explícita.

