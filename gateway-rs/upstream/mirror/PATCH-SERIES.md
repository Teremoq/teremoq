# Future controlled public-derivative patch series

## Status and rule

This file defines future continuation packages for the same Task 05. It does not
authorize or implement them. Every branch starts from an immutable approved
baseline and contains only focused reviewed commits. No branch is rebased or
force-pushed after review or consumption.

The repository is a public independent derivative, not a fork. Every future
commit uses `MIT OR Apache-2.0` and must pass publication-boundary review for
secrets, PKI, deployment identities, customer configuration and operational
data before any public branch or commit is authorized. This plan does not itself
authorize creating or pushing those branches.

The present verifier accepts exactly the baseline branch and zero tags. A future
authorized phase must know and review its local commit SHAs, then update
`baseline.env` and the verifier to an exact full-ref/full-SHA inventory before
creating any remote phase branch. Prefix allowlists and relaxed branch counts are
not acceptable. The names below are plans only and bind no SHA yet.

Approved baseline:

```text
teremoq/baseline-draft16-bf87128
bf87128affd316463e5dcc7599a45001f222b6de
```

## Identity series

### I1 — verified connection-bound evidence

- Future branch: `teremoq/i1-peer-evidence-bf87128`.
- Crate boundary: `moq-native-ietf` only, plus focused tests/documentation.
- Starting point: exact baseline commit.
- Relevant symbols: `quic::Server::accept`, `accept_session`, `ConnInfo`,
  `quinn::Connection::peer_identity()`, and an additive illustrative
  `AcceptedSession`/`VerifiedPeerEvidence` surface.
- Contract: read rustls evidence only after the same `quinn::Connection` is
  established; own it with the accepted session; reject unexpected dynamic
  identity types in required mode; manual redacted `Debug`.
- Exclusions: SPIFFE parsing, principals, roles, policy, global correlation,
  thread-local state, serialization, or a new transport.

I1 gates:

- certificate absent/present and unexpected dynamic type;
- two concurrent peers without evidence contamination;
- WebTransport and raw QUIC paths;
- DER/PEM/subject/SAN/serial absent from `Debug`, errors, events, metrics, qlog,
  and mlog;
- existing ALPN, draft-16 setup, and Object regressions;
- no dependency, feature, public struct-field, or wire change.

### I2 — required authenticated context and authorization

- Future branch: `teremoq/i2-required-auth-bf87128`.
- Crate boundary: `moq-relay-ietf` only, plus focused tests/documentation.
- Base: reviewed I1 commit, never the moving I1 branch name.
- Relevant symbols: `Relay::new`, `Relay::run`, `CoordinatorContext`,
  `Coordinator::resolve_scope`, `ConnectionMeta`, Producer/Consumer creation,
  and illustrative additive `AuthenticatedSession`, `SessionAuthorizer`,
  `Operation`, and `Relay::new_required` APIs.
- Contract: an upstream-owned type-erased
  `Arc<dyn Any + Send + Sync + 'static>` context wrapper with controlled
  construction, checked downcast, no embedder `Debug` bound, fully redacted
  manual `Debug`, and an object-safe `Arc<dyn SessionAuthorizer>`.
- Required ordering: verified certificate -> authenticated principal -> role ->
  operation -> exact namespace, before scope or namespace state.

I2 gates:

- absent/type-mismatched evidence and all policy errors deny with no legacy
  fallback;
- valid certificate without authorization gets no namespace access;
- publish, subscribe, and relay-peer checks use the exact namespace;
- denial occurs before `resolve_scope`, Producer, Consumer, registration,
  lookup, forwarding, or namespace mutation as applicable;
- concurrent session-context isolation and fully redacted output;
- explicit legacy path remains source-compatible; required mode is fail-closed;
- `SessionAuthorizer` remains object-safe and `Relay` remains non-generic unless
  the Master separately approves the associated-type alternative.

`TP-SEC-PKI` approval is mandatory for both I1 and I2. I2 depends on an approved
I1 commit. Identity work stops on any trust-model, wire, new dependency,
`unsafe`, or breaking-public-API requirement.

## Admission series

### C1 — bounded pending handshakes

- Future branch: `teremoq/c1-handshake-admission-bf87128`.
- Crate boundary: `moq-native-ietf` only, plus focused tests/documentation.
- Starting point: exact baseline commit; independent of I1/I2.
- Relevant symbols: `quic::Server::accept`, `accept_session`,
  `quinn::Endpoint::accept`, `quinn::Incoming::{accept,accept_with,refuse,retry}`,
  the pending `FuturesUnordered`, and illustrative `HandshakeAdmission` /
  `BoundedServer` APIs.
- Contract: receive `Incoming`, immediately `try_acquire`, then accept or
  disposition; never wait for capacity. One absolute monotonic deadline covers
  QUIC/TLS and WebTransport SETTINGS/CONNECT. RAII owns permit and gauge.

C1 gates:

- real QUINN N/N+1 with deterministic packet control, never arbitrary UDP;
- immediate refuse/retry without a waiter or expensive accept work;
- exact release on success, TLS error, timeout, cancellation, future/server
  drop, and races;
- Retry only when legal/configured;
- per-endpoint default semantics and explicit shared-controller semantics;
- low-cardinality metrics and zero sensitive labels;
- WebTransport/raw QUIC, ALPN, draft-16, and Objects unchanged.

### C2 — global sessions and bounded shutdown

- Future branch: `teremoq/c2-session-shutdown-bf87128`.
- Crate boundary: `moq-relay-ietf` only, plus focused tests/documentation.
- Base: reviewed C1 commit, never the moving C1 branch name.
- Relevant symbols: `Relay::new`, `Relay::run`, the relay task
  `FuturesUnordered`, session setup/Producer/Consumer creation, and illustrative
  `RelayAdmission`, `BoundedRelay`, and `run_until` APIs.
- Contract: one relay-global established-session budget across endpoints;
  immediate N+1 rejection before task or namespace state; one shutdown deadline
  covering accept stop, cancellation, drain, forced drop, and zero gauges.

C2 gates:

- N/N+1 across one and multiple endpoints;
- no session task, Producer, Consumer, or namespace mutation for rejected N+1;
- capacity recovery on clean close, error, cancellation, and drop;
- active handshakes/sessions during shutdown, deterministic races, deadline,
  and zero-gauge postcondition;
- no waiter queues, gauge underflow, address/identity labels, wire changes, or
  new dependencies.

`TP-PLATFORM-CHAOS` reviews C1/C2 test design and harness behavior. C2 depends on
an approved C1 commit. Admission work is independent of identity except that the
final session object may carry already approved opaque metadata.

## Future integration branch

- Future branch: `teremoq/integration-draft16-bf87128`.
- Contains only immutable, reviewer-approved I1, I2, C1, and C2 commit IDs.
- May be assembled only after both series pass their gates.
- Must not merge unreviewed branch tips or add product-specific policy.

Integration gates before any product pin:

1. compare commit/tree lineage and licenses against the approved baseline;
2. compile/test the three-crate set with an exact recorded toolchain;
3. run identity fail-closed and redaction coverage;
4. run real-QUINN admission, cancellation, shutdown, and metric coverage;
5. run WebTransport/raw QUIC, both ALPNs, MoQT draft-16 setup, and Object
   regressions;
6. run authorized SPIFFE/namespace integration and Chaos only in the later
   integration continuation;
7. pin `moq-native-ietf`, `moq-transport`, and `moq-relay-ietf` atomically to one
   full integration commit;
8. prove rollback to the prior official baseline and retire the laboratory
   relay only after equivalent behavior is demonstrated.

No phase begins merely because this branch plan exists.
