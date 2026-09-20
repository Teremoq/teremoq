# ADR-0007: controlled public moq-rs derivative

- Status: **Accepted as a controlled public derivative; implementation gated**
- Date: 2026-08-26
- Owner: `TP-RUST-DIST`
- Required identity/privacy reviewer: `TP-SEC-PKI`
- Open-source and supply-chain review: `TP-OSS-SC`
- Official upstream: `https://github.com/cloudflare/moq-rs.git`
- Controlled derivative: `https://github.com/Teremoq/moq-rs-teremoq`
- Approved baseline: `bf87128affd316463e5dcc7599a45001f222b6de`
- Approved tree: `d76319009e815fb8923e21fc8319e17a0aaf8174`

## Context and decision history

ADR-0005 demonstrates that the fixed `moq-rs` relay cannot carry verified,
connection-bound client evidence to authorization before scope and namespace
state. ADR-0006 demonstrates that the native accept path and relay lack separate
immediate bounds for pending handshakes and established sessions, plus a bounded
cancel-and-drain lifecycle. Task 05 reproduced both blockers and prepared a
package that remains `NOT SUBMITTED`.

The initial exception created `Teremoq/moq-rs-teremoq` as a private independent
mirror and uploaded only the unaltered official baseline. That event and its
before/after state remain truthfully recorded in
`upstream/mirror/bootstrap-report-2026-08.md`.

On 2026-08-26 the user subsequently selected an open-source model: original
Teremoq code is Apache-2.0, while the independent `moq-rs` derivative remains
`MIT OR Apache-2.0`. Task 06, owned by `TP-OSS-SC`, transitioned the independent
repository to public visibility after history, secret, provenance, REUSE and
repository-control review. This later decision supersedes the private operating
model; it does not rewrite the private bootstrap as though it never occurred.

The current decision is therefore a **controlled public independent derivative**,
not a GitHub fork. It preserves official history and license, carries only
reviewed generic embedder changes, and is a temporary implementation vehicle
until equivalent official APIs are available. Public visibility does not
authorize publication of product configuration, trust material or patches, and
does not itself authorize I1, I2, C1 or C2.

## Repository and baseline contract

`Teremoq/moq-rs-teremoq` must remain all of the following:

- public, independent (`fork=false`, no parent), and not archived;
- rooted at the exact official baseline commit and tree above;
- dual-licensed `MIT OR Apache-2.0`, with upstream `LICENSES/` and REUSE
  metadata preserved;
- limited during this transition to the single immutable branch
  `teremoq/baseline-draft16-bf87128`, with zero tags;
- consumed only by full commit ID, never by branch name; and
- free of Teremoq secrets, PKI, customer configuration, production namespaces,
  operational data and unsupported product claims.

The repository is independent to keep provenance and lifecycle under explicit
Teremoq governance. It must not be represented as a Cloudflare-endorsed fork or
as an official `moq-rs` distribution.

The current `baseline.env` and verifier are deliberately phase-specific: they
accept exactly the single baseline branch above and zero tags. Before any later
authorized phase creates its first remote branch, that phase must first evolve
the configuration and verifier locally to an exact approved-ref inventory. Each
entry must bind one complete ref name to one full commit SHA known from the
reviewed local commit set. The updated verifier must reject missing, additional
or moved refs and every tag. A prefix allowlist, `branch_count >= 1`, or another
open-ended count rule is prohibited. No future I1/I2/C1/C2 SHA is approved or
invented by this ADR revision.

## Future contract boundary

Only a later Master authorization may begin these review units:

- **I1 — `moq-native-ietf`:** expose verified peer evidence from the established
  `quinn::Connection` and bind it to the accepted session.
- **I2 — `moq-relay-ietf`:** carry a redacted authenticated context to required,
  fail-closed authorization before scope and namespace state.
- **C1 — `moq-native-ietf`:** bound pending QUIC/TLS/WebTransport establishment
  with immediate disposition and an absolute monotonic deadline.
- **C2 — `moq-relay-ietf`:** enforce a relay-global established-session limit
  and bounded coordinated shutdown.

Future source changes are limited to `moq-native-ietf` and `moq-relay-ietf`,
their focused tests and necessary documentation. `moq-transport` remains
wire-compatible and unchanged unless a test demonstrates a minimal required
adjustment and the Master explicitly approves it. Every new contribution in the
derivative uses `MIT OR Apache-2.0`.

## Invariants

1. Zero-Transcoding remains unchanged.
2. The existing QUINN/rustls/WebTransport stack remains the only native stack.
3. MoQT remains draft-16; raw QUIC/WebTransport ALPNs, setup, Tracks, Groups and
   Objects do not change.
4. Certificates, DER/PEM, principal, roles and authorization results are never
   serialized into MoQT, headers, URLs, queries, qlog, mlog or metrics.
5. Evidence comes only from the same established connection after its handshake
   and remains connection/session-owned.
6. Required authorization is fail-closed before `resolve_scope`, Producer,
   Consumer, registration, lookup, forwarding or namespace mutation.
7. The policy boundary remains `verified certificate -> authenticated principal
   -> role -> operation -> exact namespace`.
8. SPIFFE parsing, principal construction, roles and deployment policy remain
   outside `moq-rs`.
9. Pending-handshake and established-session capacity are independent.
10. `Endpoint::accept()` yields `quinn::Incoming` before immediate
    `try_acquire`; saturation creates no permit waiter.
11. One RAII owner releases each permit/gauge exactly once on every terminal
    path.
12. Shutdown stops acceptance and cancels/drains to one monotonic deadline,
    returning with lifecycle gauges at zero.

## Alternatives rejected

- **Wait without an implementation vehicle:** still the lowest-maintenance exit,
  but supplies no schedule for the demonstrated contracts.
- **Publish direct upstream PRs now:** the design package is unsubmitted and no
  publication authorization exists.
- **Local Cargo patch or vendoring:** obscures provenance and creates an active
  source copy inside Teremoq.
- **Second QUIC/WebTransport endpoint or copied relay:** duplicates protocol and
  lifecycle ownership.
- **Reimplement QUIC, WebTransport or MoQT:** violates the reuse rule.
- **Connected GitHub fork:** would present the work inside the upstream fork
  network; the selected model is an explicitly named independent derivative.
- **Keep the derivative private:** was the original bootstrap decision, later
  superseded by the user's open-source governance decision after Task 06 review.

## Public-repository controls

The fail-closed verifier requires public visibility, independence, exact
baseline provenance, preserved license objects, Secret Scanning, Push
Protection, Private Vulnerability Reporting, Dependabot Alerts, GitHub-owned-only
Actions with full-SHA pinning, read-only default workflow permission, no workflow
PR approval and web commit sign-off.

Rulesets are prepared locally but are not active. They are not claimed as a
control until separately activated and verified. CodeQL Rust default setup is
blocked by GitHub API HTTP 422 and remains pending. Dependency Graph/SBOM is not
assumed while the REST SBOM endpoint returns 404. Public visibility permits
anyone to read and fork the repository; secret and product-data exclusion is
therefore a publication boundary, not merely an access-control recommendation.

## Risks and mitigations

| Risk | Required mitigation |
|---|---|
| Upstream divergence | Immutable baseline per update; exact commit/tree delta; replay only approved commits. |
| Public disclosure | Pre-publication secret/provenance review; prohibit PKI, identities, customer configuration and operational data. |
| Misattribution | Preserve upstream copyright/license and label the repository an independent Teremoq derivative. |
| CVEs and stale dependencies | Advisory and dependency review on each baseline and before every product pin. |
| MSRV/toolchain drift | Record exact toolchain and failures; do not claim reproducibility when required gates fail. |
| Supply-chain substitution | Full commit pins, tree comparison, license blob comparison and read-only verifier. |
| Unauthorized branch movement | New branches for new baselines/series; no rebase or force-push on consumed refs. |
| Missing rulesets/CodeQL/SBOM | Keep them explicit blockers or pending controls; never infer them from other settings. |
| Derivative unavailable | Fail closed unless the exact commit is in a trusted cache; permit a verified source archive only as disaster recovery, not active vendoring. |

## Synchronization, rollback and exit

There is no force-push, destructive rebase or `git push --mirror` workflow.
Every synchronization records an official full commit/tree, inspects wire,
license, dependency and blocker deltas, creates a new baseline branch, and
replays only reviewed Teremoq commits into new phase/integration branches.
Product pins may change only in a separately authorized integration phase and
must update `moq-native-ietf`, `moq-transport` and `moq-relay-ietf` atomically.

For every future branch, the reviewed local commit SHA and intended full ref
name are entered into the exact inventory and the revised verifier is tested
before the explicit non-force push. Post-push verification then compares the
entire remote branch inventory against those exact pairs; it does not merely
count branches or accept a naming prefix.

Rollback selects the previous approved full commit through an authorized atomic
pin change; it never moves a baseline branch. Exit occurs when an official
Cloudflare release or immutable commit covers I1/I2/C1/C2 with equivalent tests
and preserves draft-16/wire behavior. Only one implementation may remain active.

## Mandatory stop conditions

Stop and return to the Master for any wire/draft/ALPN change, new dependency or
feature, `unsafe`, second transport stack, incompatible license, missing notice,
copied relay/product source, secret or private deployment data, baseline rewrite,
or public action outside the specifically authorized phase.

## Readiness

This transition proves repository governance and exact provenance only. The
baseline reproducibility run records upstream test and formatting failures, so
it is not a fully passing baseline. I1/I2/C1/C2 remain unstarted. Zero-Trust,
bounded admission, bounded shutdown, denial-of-service resistance, soak stability
and commercial readiness remain unresolved; the federated relay is not
productive.
