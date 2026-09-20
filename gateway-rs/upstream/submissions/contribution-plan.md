# Upstream contribution plan — NOT SUBMITTED

## Recommendation

Use **two independent maintainer-mediated design threads and four small,
sequential pull requests**, not one combined identity/admission change.

The repository has no `CONTRIBUTING.md`, compatibility policy, or issue/PR
templates at the reviewed commit, and GitHub reports that issue creation is
restricted. Therefore the first external step, if authorized, is a short contact
with the maintainers through a channel they accept, asking where the two design
drafts should live. A maintainer may open tracking issues, enable issue creation,
request a Discussion, or ask for draft PRs. This plan does not presume the
answer.

One direct channel-discovery contact was made through Cloudflare's official Open
Source contact on 2026-08-26. No design, issue, Discussion, pull request, code,
or repository link was submitted. See `contact-log-2026-08.md`.

## Proposed review units

### Identity series

**I1 — `moq-native-ietf`: connection-bound verified peer evidence**

- read `quinn::Connection::peer_identity()` only after connection establishment;
- downcast the documented rustls identity type;
- return owned, redacted evidence through an additive acceptance API;
- preserve existing `Server::accept` and both transport paths;
- test absent, present, unexpected dynamic type, concurrent isolation, and
  redaction.

I1 contains no relay policy and no SPIFFE/principal parsing.

**I2 — `moq-relay-ietf`: required authentication and authorization hooks**

- consume I1 evidence before scope resolution;
- add an explicit required builder/constructor and retain a named legacy path;
- carry an upstream-owned `AuthenticatedSession` whose private
  `Arc<dyn Any + Send + Sync + 'static>` stores one embedder context and exposes
  only controlled construction and checked downcast;
- authorize publish, subscribe, and relay-peer for the exact namespace before
  mutation;
- test valid-but-unauthorized denial, context type mismatch, fully redacted
  `Debug`, fail-closed errors, ordering, concurrent isolation, and legacy
  compatibility.

I2 depends on I1. It should not add required methods to the existing
`Coordinator` trait unless maintainers explicitly accept a breaking release.

### Admission series

**C1 — `moq-native-ietf`: per-endpoint pending-handshake admission**

- receive `Incoming`, immediately try the permit, then accept/refuse/retry;
- bound the handshake/WebTransport future collection structurally;
- enforce one absolute monotonic QUIC/TLS/CONNECT deadline;
- use RAII for permit/gauge ownership;
- add deterministic real-QUINN tests for N/N+1 and every release path.

**C2 — `moq-relay-ietf`: global session admission and coordinated shutdown**

- share one session budget across all relay endpoints;
- reject N+1 before task and namespace state;
- cancel and drain handshakes/sessions under one shutdown deadline;
- expose low-cardinality lifecycle metrics and zero-gauge postconditions;
- test multi-endpoint semantics, capacity recovery, and active shutdown.

C2 depends on C1 for a complete bounded-lifecycle story, although its global
session controller can initially accept opaque connection metadata. It does not
depend on I1 or I2. If identity lands later, authenticated context can be carried
through session admission without changing the accounting contract.

## Why four PRs

- I1 and C1 change the native transport boundary; I2 and C2 change relay policy
  and lifecycle. Separating those review surfaces keeps tests and ownership
  local.
- Identity and capacity have no wire-level dependency and should not block each
  other's review.
- A single “security and hardening” PR would combine certificate ownership,
  dynamic downcast behavior, async policy traits, semaphores, Retry, deadlines,
  shutdown, and metrics. That is not a maintainable review unit.
- PR #145 shows that focused cross-crate plumbing can be accepted, but it also
  explicitly documented its breaking trait change. This plan avoids such a
  change unless maintainers choose it.

If maintainers prefer only two PRs, combine I1+I2 into one identity PR and C1+C2
into one admission PR, while retaining separate commits and test sections. Never
combine identity and admission into the same PR.

## Maintainer preflight questions

The completed initial contact asked only:

1. Which official channel should host the two independent designs, given
   restricted issue creation?
2. Do maintainers prefer independent design threads with small crate-scoped PRs
   or two focused cross-crate PRs?

It included the exact current `main` revision but no code-symbol links, private
repository links, attachments, drafts, or deployment claims. Questions about
additive versus breaking APIs, the type-erased wrapper versus a generic relay,
error codes, and metrics naming remain for a later design discussion and are not
authorized until the Master approves the channel and next message.

## Review gates

### Identity gate (`TP-SEC-PKI` required)

- evidence comes from the established `quinn::Connection` only;
- no DER/PEM/subject/SAN/serial/full principal/roles in logs or `Debug`;
- SPIFFE interpretation and role policy remain outside upstream;
- path, SNI, address, and tagger never become authenticated principal;
- required mode rejects absence/type mismatch/policy errors with no fallback;
- `AuthenticatedSession` accepts only `Send + Sync + 'static` context, uses a
  checked downcast, requires no embedder `Debug`, and formats as fully redacted;
- `SessionAuthorizer` remains object-safe behind `Arc<dyn ...>` because generic
  construction/downcast live on the concrete wrapper, not on the trait;
- a valid but unauthorized certificate touches no namespace;
- publish/subscribe/relay-peer checks use the exact namespace.

### Admission gate (`TP-RUST-DIST` owner)

- `Endpoint::accept` yields `Incoming` before the permit attempt;
- `try_acquire` happens before `Incoming::accept`/`accept_with`;
- saturation has immediate refuse/retry disposition and no waiter task;
- handshake and session budgets are independent;
- the deadline covers QUIC/TLS and WebTransport CONNECT;
- all permit releases are RAII and exactly once;
- session capacity is global across endpoints;
- shutdown drains/cancels within a deadline and leaves gauges at zero;
- tests use QUINN and packet control, never raw UDP presented as QUIC.

### Wire and regression gate

- MoQT remains draft-16;
- `web_transport_quinn::ALPN` and `moq_transport::setup::ALPN` are unchanged;
- WebTransport and raw QUIC remain supported;
- no identity/admission value is serialized;
- existing MoQT setup and Object tests pass.

## Versioning and release request

Prefer additive minor releases for new methods, wrappers, builders, and
`#[non_exhaustive]` types. Any accepted change that adds fields to constructible
public structs, changes `Server::accept`, or adds required `Coordinator` methods
needs the maintainer's documented breaking-release decision.

The primary identity proposal keeps `Relay` non-generic by using a new concrete
type-erased `AuthenticatedSession`. Making the authorizer context an associated
type instead would remove direct object safety and propagate a type parameter or
second erasure boundary through `Relay` and its builders; that alternative
requires a separate source/semver decision and is not proposed concurrently.

No new dependencies or features are proposed. If an implementation discovers a
need for one, stop and reopen design review with version, license, MSRV, feature,
and supply-chain impact rather than silently adding it.

## Future Teremoq integration handoff

Only after upstream merges, releases or identifies an immutable adoption commit,
and the Master separately authorizes integration:

1. pin one mutually compatible commit/release set for `moq-native-ietf`,
   `moq-transport`, and `moq-relay-ietf` atomically;
2. verify the resolved QUINN/rustls versions and license policy;
3. adapt the relay through the official required-auth and bounded-admission APIs;
4. run identity, concurrency, hostile, wire/ALPN, WebTransport/raw QUIC, and MoQT
   Object regressions;
5. remove temporary local adaptation only after equivalent official behavior is
   demonstrated and ADRs are updated through their owning Tasks.

Do not mix versions of those three crates merely because one API appears
additive: their draft/setup/session interfaces move together. The current local
proposals become superseded only in the approved integration record, not by this
document package.

## Stop conditions

Stop and return to the Master if maintainers request a wire change, draft change,
new dependency, generic relay/public breaking API, combined monolithic
contribution, or a different trust model. None is pre-authorized.
