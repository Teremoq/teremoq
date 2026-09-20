# Compatibility and test matrix — NOT SUBMITTED

## Compatibility matrix

| Area | Current surface | Proposed constraint | Semver/risk decision |
|---|---|---|---|
| `quic::ConnInfo` | Public fields; external literals and exhaustive destructuring are possible. | Do not add evidence as a field. Add an `AcceptedSession`/companion acceptance path with `#[non_exhaustive]`. | A field addition is source-breaking; companion API can be minor. |
| `Server::accept` | Returns `(web_transport::Session, ConnInfo)`. | Preserve signature and behavior; new evidence/bounded methods or wrappers are additive. | Signature change requires a breaking release. |
| `RelayConfig` and native config | Constructible public structs are used with literals. | Do not add required fields. Pass authorizer/admission through new constructors/builders. | Field addition breaks source. New methods/types can be minor. |
| `Coordinator` | Public async trait; PR #145 previously changed it and documented the break. | Prefer companion object-safe `SessionAuthorizer`; do not add a required method. Default authorization that grants access is forbidden on the required path. | Required trait method/signature change is breaking; a default allow method is insecure. |
| Authorizer object safety | Relay needs to store one runtime-selected authorizer behind `Arc<dyn SessionAuthorizer>`. | Trait methods use the concrete upstream-owned `AuthenticatedSession`; type-erased construction/downcast are inherent wrapper methods, not trait generics or an associated type. | Preserves a non-generic `Relay` and is additive. An associated context type would require generic relay/builders or another erasure boundary. |
| Public enums | Exhaustive downstream matches may exist. | Use new `#[non_exhaustive]` enums for operations/dispositions; do not add variants to existing exhaustive enums casually. | Adding exhaustive variants can break source. |
| Rust ABI | No stable ABI guarantee. | Require downstream recompilation; do not claim binary compatibility. | Binary compatibility is not applicable as a stable contract. |
| Legacy identity | Current relay does not consume verified peer evidence. | Existing constructors may retain behavior; add explicit legacy spelling and an unmistakable `required` path. | Source-compatible, but migration guidance and targeted warning/event are needed. |
| Required identity | No current mode. | Any absent/invalid/unexpected evidence or policy error denies; no fallback to path/SNI/IP/tagger. | New opt-in behavior. A “required” default that falls back is unacceptable. |
| Legacy admission | Current collections are unbounded. | Preserve only for compatibility and document it as legacy; bounded constructors reject invalid limits. | Additive; future default change needs release notes/major-policy review. |
| Warning behavior | No authenticated/admission configuration warning contract. | Warn only for detectable insecure combinations; also emit low-cardinality startup mode events. Never log identity/address. | Blanket warnings would be noisy; silent unsafe “required/bounded” fallback is worse. |
| Dependencies/features | Current graph already contains QUINN, rustls, Tokio, futures, and metrics. | Implement with existing graph; no new crate or feature. | Any discovered dependency need reopens design/license/MSRV review. |
| WebTransport | Accepted after QUIC/TLS and H3 CONNECT. | Same evidence source; CONNECT included in handshake deadline. | Behavior only; no headers/query identity. |
| Raw QUIC | Selected through current MoQT ALPN. | Same evidence/admission contracts as WebTransport. | No setup parameter or ALPN change. |
| Wire/draft | MoQT draft-16; `web_transport_quinn::ALPN` and `moq_transport::setup::ALPN`. | Preserve both ALPNs, draft-16 framing, setup, and Objects. | Any wire/draft change is out of scope and blocks integration. |
| Identity ownership | No exposed chain. | Own rustls certificate DER with the accepted connection/session. Upstream's concrete `AuthenticatedSession` privately stores `Arc<dyn Any + Send + Sync + 'static>` created from an embedder value and offers checked `downcast_ref`. | Avoid borrowed handshake lifetimes, keep `Arc<dyn SessionAuthorizer>` object-safe, and carry one context safely across tasks. |
| Concurrency ownership | Private `FuturesUnordered` collections own work. | One RAII permit/gauge guard per phase future/task; no permit waiter tasks. | Drop/cancel/error must release exactly once. |
| `Debug`/events | Several current metadata types derive `Debug`. | Evidence uses redacted formatting. `AuthenticatedSession` imposes no `Debug` bound and its manual implementation emits only `AuthenticatedSession(<redacted>)`; events expose fixed state/reason. | Deriving or delegating `Debug` over dynamic context is a security regression. |
| Multi-endpoint semantics | One accept future per endpoint; no documented cap scope. | Pending cap per endpoint; established session cap global per relay. Explicit shared controller only for global handshake mode. | Prevent accidental multiplication of the advertised relay limit. |
| Shutdown | `Relay::run` owns tasks without bounded external drain. | Stop accept, cancel, drain to one monotonic deadline, drop/abort remainder, gauges zero before return. | Additive `run_until`/wrapper preferred; changing `run` is breaking. |
| Temporary downstream adaptation | Local examples/tests demonstrate partial mTLS and counters only. | Retire only after official equivalent is adopted atomically and all regression gates pass. | A proposal alone supersedes nothing and resolves no blocker. |

## Authentication and authorization tests

| ID | Scenario | Setup and synchronization | Required assertion |
|---|---|---|---|
| ID-01 | Client certificate absent | Real QUINN/rustls endpoint in required mode; client sends no certificate. | Rejected before authenticated scope resolution, Producer/Consumer creation, or namespace state. |
| ID-02 | Unexpected dynamic identity type | Test QUINN crypto session returns a supported handshake but a non-rustls `Any` identity type. | Required path returns a typed error and denies; no panic and no legacy fallback. |
| ID-03 | Valid identity, no authorization | Trusted certificate authenticates to a principal with no operation grants. | Publish, subscribe, and relay-peer all denied for every namespace. |
| ID-04 | Rejection ordering | Instrument hooks/state factories with deterministic barriers. | Failure occurs before `resolve_scope` when authentication fails and before any namespace state on later denial. |
| ID-05 | Exact namespace | Grant one operation on one namespace and attempt sibling/prefix-confusable namespaces. | Only the exact `(principal, role, operation, namespace)` grant succeeds. |
| ID-06 | Two concurrent peers | Two certificate chains, interleaved barriers across authentication/scope/operation calls. | Each hook sees only its connection-owned context; no contamination. |
| ID-07 | Explicit legacy | Construct through current/legacy API and through required API. | Legacy preserves documented source behavior; required rejects every missing/error path. |
| ID-08 | Sensitive output | Exercise success and all identity errors; format every public error/context with `Debug` and capture tracing. | No DER, PEM, subject, SAN, serial, complete principal, or roles. Only fixed reason/state fields. |
| ID-09 | Both transport paths | Repeat required identity tests over WebTransport and raw QUIC. | Evidence is obtained after the same QUIC/TLS connection handshake; no wire-carried identity. |
| ID-10 | Authenticated context type mismatch | Construct an upstream wrapper with one `Send + Sync + 'static` context type and request another in the authorizer. | Checked downcast returns `None`; required mode denies without panic, empty context, logging, or legacy fallback. |

## Admission, cancellation, and lifecycle tests

| ID | Scenario | Setup and synchronization | Required assertion |
|---|---|---|---|
| AD-01 | Pending handshakes N/N+1 | Real QUINN clients; packet-control harness stalls N handshakes after `Incoming` admission. | Pending gauge is N; N+1 is immediately refused/retried; no permit waiter/future is added. |
| AD-02 | Successful handshake release | Let one stalled handshake and WebTransport CONNECT complete. | Handshake permit/gauge release exactly once when phase completes and session admission begins. |
| AD-03 | TLS error release | Present invalid/aborted TLS input through QUINN. | Error counter increments; permit and gauge return exactly once. |
| AD-04 | Absolute timeout release | Keep packets flowing without completing TLS or H3 CONNECT past `timeout_at` deadline. | Deadline fires despite activity/idle timeout; connection closes and permit returns. |
| AD-05 | Cancellation release | Cancel the phase at each deterministic barrier. | No leak/double release; next incoming is admitted. |
| AD-06 | Future/server drop release | Drop handshake future/server with work active. | RAII releases all owned permits and gauge guards. |
| AD-07 | Retry policy | Exercise unvalidated and already validated Incoming states. | Retry only where `Incoming::retry()` is legal/configured; otherwise documented refusal; no accept work begins. |
| AD-08 | Session N/N+1 | Establish N MoQT sessions and hold them at a deterministic active barrier. | Global gauge N; N+1 creates no session task, Producer/Consumer, or namespace state. |
| AD-09 | Session recovery | Close one admitted session cleanly and after error. | Exactly one permit returns and the next session is admitted. |
| AD-10 | Multiple endpoints | Drive sessions through two or more endpoints. | Pending caps are per endpoint; total active sessions never exceeds one relay-global N. |
| AD-11 | Explicit shared handshake controller | Configure two endpoints with one shared controller. | Documented global pending N is enforced, distinct from default per-endpoint semantics. |
| AD-12 | Shutdown with active work | Hold both pending handshakes and active sessions, then signal shutdown. | Accept stops, work cancels/drains by one deadline, forced remainder drops, all permits return, gauges are zero when shutdown returns. |
| AD-13 | Shutdown race | Race success/error/session close with shutdown repeatedly under deterministic scheduling. | Counters have one terminal outcome per item and gauges never underflow. |
| AD-14 | Metric cardinality/redaction | Exercise all rejection and completion reasons. | Labels come from fixed enums only; no address, SNI, connection ID, namespace, or identity. |

Pending-handshake tests must use QUINN's real endpoint/Incoming path. A packet
control layer may delay or discard selected QUIC datagrams; sending arbitrary UDP
and calling it a handshake is not valid coverage.

## Wire and behavior regression tests

| ID | Scenario | Required assertion |
|---|---|---|
| WR-01 | WebTransport ALPN | Existing `web_transport_quinn::ALPN` succeeds with legacy and new paths. |
| WR-02 | Raw QUIC ALPN | Existing `moq_transport::setup::ALPN` succeeds with legacy and new paths. |
| WR-03 | Draft-16 setup | CLIENT_SETUP/SERVER_SETUP encoding and validation remain unchanged. |
| WR-04 | MoQT Objects | subgroup/object success, reset, close, and error tests remain unchanged. |
| WR-05 | No identity serialization | Packet capture contains no certificate, principal, role, or authorization metadata newly added by the feature. |
| WR-06 | Saturation behavior | Only established existing QUIC/application close or Retry mechanisms are used; no new protocol frame/parameter. |
| WR-07 | Mixed listener transports | WebTransport and raw QUIC share the global relay session budget without changing their individual handshakes. |

## Acceptance evidence for an upstream implementation

Each PR should report:

- exact commit and toolchain/MSRV used;
- focused unit/integration commands and full workspace checks required by
  maintainers;
- deterministic N/N+1 and ordering evidence rather than timing-only assertions;
- zero sensitive output from captured test events;
- no dependency/feature additions;
- unchanged draft/ALPN/wire fixtures; and
- source compatibility examples for old constructors and public struct literals.

Passing these proposed tests would validate the implementation contract. It
would not by itself establish production capacity, security policy correctness,
or deployment readiness.
