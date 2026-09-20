# moq-rs upstream submission package — NOT SUBMITTED

> **DESIGN NOT SUBMITTED.** Nothing in this directory has been posted to the
> `cloudflare/moq-rs` repository. One direct, channel-discovery contact was made
> through Cloudflare's official Open Source contact; no draft, document, code,
> repository link, issue, Discussion, pull request, fork, branch, push, or
> dependency update was published or created.

This is a review package for two independent embedder contracts that are still
absent from official `moq-rs` at
[`bf87128affd316463e5dcc7599a45001f222b6de`](https://github.com/cloudflare/moq-rs/commit/bf87128affd316463e5dcc7599a45001f222b6de):

1. connection-bound, verified client evidence that can reach authorization
   before scope and namespace state; and
2. immediate, bounded admission for pending transport handshakes and established
   MoQT sessions, including coordinated shutdown.

The decision is **Route B**: neither current `main` nor the latest relevant
official releases provide all required production contracts. Existing partial
facilities (`Connection::peer_identity()` in QUINN, path-based
`Coordinator::resolve_scope()`, `FuturesUnordered`, idle timeout, and connection
gauges) are not presented as a complete solution.

## Ownership and review

- Owner: `TP-RUST-DIST` — Rust APIs, compatibility, lifecycle, concurrency,
  tests, and upstream contribution strategy.
- Required reviewer: `TP-SEC-PKI` — authenticated evidence, fail-closed behavior,
  redaction, and separation of authentication from authorization.
- Publication authority: the Master. The Master authorized only the completed
  initial channel-discovery contact. Any design submission or follow-up requires
  new explicit authorization.

The required security invariant is:

```text
verified certificate -> authenticated principal -> role -> operation -> exact namespace
```

A certificate that validates cryptographically but is not authorized grants no
namespace access.

## Contents

- [`discovery-2026-08.md`](discovery-2026-08.md) — reproducible official-source
  discovery, exact revisions, related work, and the Route B decision.
- [`peer-identity-issue-draft.md`](peer-identity-issue-draft.md) — copy-ready
  identity/design draft.
- [`concurrency-admission-issue-draft.md`](concurrency-admission-issue-draft.md) —
  copy-ready bounded-admission/design draft.
- [`contribution-plan.md`](contribution-plan.md) — maintainer coordination,
  independent PR series, ordering, and integration handoff.
- [`compatibility-and-test-matrix.md`](compatibility-and-test-matrix.md) — source,
  semver, transport/wire, lifecycle, security, and test coverage.
- [`contact-log-2026-08.md`](contact-log-2026-08.md) — **CONTACT MADE**, exact
  authorized message, official channel basis, response state, and remaining
  restrictions.

The two issue drafts are deliberately independent. Authenticated context may be
opaque to admission accounting, so neither implementation needs the other to be
reviewable.

## Current blockers

Preparing this package does not make authenticated federation or bounded
concurrency production-ready. Productive relay use remains blocked until
upstream (or a separately approved integration strategy) provides and tests both
contracts, and Teremoq then adopts the approved atomic crate set without wire,
ALPN, or draft regression.
