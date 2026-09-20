# I2 local review: required authenticated relay authorization

- Status: **LOCAL ONLY / NOT PUSHED / NOT COMMITTED**
- Review snapshot: 2026-08-27T19:57:06Z
- Owner: `TP-RUST-DIST`
- Required reviewer: Task 03 / `TP-SEC-PKI`
- Scope: I2 in `moq-relay-ietf` only
- I1 base commit: `05b41127ecbd48de4c59fe1626c43b1e423c33a9`
- I1 base tree: `eca64a72e148482fb82b963edc2f2c9af28803f2`
- Local branch: `teremoq/i2-required-auth-bf87128`, without tracking
- C1/C2 and product integration: not started
- Current snapshot: see **Security-review correction iteration** below. The
  earlier snapshot is retained verbatim as historical evidence and is
  superseded where the appendix says so.

## Findings for review

### High: mandatory identity/privacy review remains open

I2 is implemented only as unstaged local working-tree content. The API and
ordering below passed the engineering gates, but Task 03 / `TP-SEC-PKI` has not
yet reviewed the result. No local commit or publication is authorized by this
report.

### Medium: the relay crate cannot independently construct a valid mTLS peer

`moq-relay-ietf` has no direct rustls dependency. A compile probe confirmed that
a transitive rustls crate is not nameable from its tests. Adding rustls as a
development dependency solely for I2 would violate the authorized no-manifest,
no-dependency boundary, so it was not done.

The fixed I1 integration test was rerun with the exact toolchain and proves that
real QUINN/rustls client certificates produce connection-bound
`VerifiedPeerEvidence` on raw QUIC and WebTransport. I2 tests then exercise the
authenticated-context, scope and per-operation gates over real QUINN/rustls
sessions. The remaining composition point -- a valid certificate reaching an
I2 authorizer that rejects it -- is structurally present but needs the mandatory
reviewer to accept this split coverage or authorize a later test-only dependency
change. This limitation is not presented as a passing end-to-end mTLS I2 test.

### Low: crate-wide Gitleaks has one unchanged baseline false positive

Gitleaks flags the literal PEM marker in the pre-existing comment at
`moq-relay-ietf/src/tls.rs:115` as `private-key`. The file is byte-identical to
I1 and contains no key material at that line. A separate scan of every I2 file
found zero leaks. The baseline finding was retained and documented rather than
suppressed or edited under I2.

## Final API implemented locally

The public surface is additive and uses the existing direct `async-trait`
dependency:

- `AuthenticatedSession` is an upstream-owned wrapper with private fields over
  `Arc<dyn Any + Send + Sync + 'static>`. `new` and `new_relay_peer` are the
  controlled constructors. `downcast_ref` provides checked borrowed recovery;
  it does not require `Debug` and does not reveal a dynamic type name.
- `AuthenticatedSession` has fixed manual output
  `AuthenticatedSession(<redacted>)`. Its contract requires the embedder to
  derive a minimal principal while borrowing I1 evidence and not retain DER in
  the authenticated context, logs or metrics.
- `SessionAuthorizer: Send + Sync + 'static` is object-safe through
  `async_trait` and is accepted as `Arc<dyn SessionAuthorizer>`. It has separate
  `authenticate`, authenticated `resolve_scope` and exact `authorize` hooks.
- `Operation` uses MoQT `TrackNamespace` or `TrackNamespacePrefix` values for
  `Publish`, `PublishNamespace`, `Subscribe`, `SubscribeNamespace`,
  `DiscoverNamespace`, `TrackStatus` and `RelayPeer`. `RelayPeerOperation`
  preserves the exact underlying action. Both operation types have fixed,
  target-redacted manual `Debug` output.
- `AuthorizationError` distinguishes authentication rejection, authorization
  denial and authenticated-context type mismatch using fixed, non-sensitive
  `Debug` and `Display` text.
- `Relay::new_required(config, authorizer)` and
  `RelayConfig::build_required(authorizer)` select required mode without adding
  a field to the public `RelayConfig` struct.

The existing `Relay::new`, `RelayConfig::build`, `Consumer::new`,
`Producer::new` and legacy acceptance signatures are unchanged. The new trait
has no existing implementers to break, its builder is opt-in, public operation
enums are non-exhaustive, and Rust provides no stable cross-version ABI to
preserve. No generic parameter was added to `Relay` or its builders.

## Fail-closed ordering

Required mode follows this order for each accepted inbound connection:

1. Every clean `quic::Server` is consumed into I1's lifetime-stable
   `PeerEvidenceServer` before any accept future is created. Legacy and required
   pending sets cannot mix.
2. I1 returns either an `AcceptedSession`, a typed evidence-conversion error or
   endpoint closure. A conversion error exposes no application session.
3. `PeerEvidence::Absent` and unsupported evidence close the same connection
   before authentication or MoQT setup, with fixed logs and low-cardinality
   metric labels. There is no legacy fallback.
4. `PeerEvidence::Rustls` is borrowed by `SessionAuthorizer::authenticate`
   before `moq_transport::Session::accept_with_config`. An authentication error
   closes the connection and exposes no MoQT session.
5. Evidence is dropped once the embedder returns its opaque
   `AuthenticatedSession`. The relay then resolves required scope exclusively
   from that authenticated context, still before MoQT setup. The required hook
   receives no connection path, address, SNI, `ConnInfo` or connection tag.
6. Only after authentication and scope authorization succeed does MoQT setup
   run. Required mode never calls legacy `Coordinator::resolve_scope` or
   `ConnectionTagger`; those remain confined to legacy mode.
7. Producer and Consumer are created only after the authenticated scope gate.
   Their `SessionContext` client/relay classification comes only from
   `AuthenticatedSession`, never from transport metadata.
8. Each operation is authorized before its first relay-visible action:

| Protocol action | Required gate before |
|---|---|
| `PUBLISH` | metrics, track reader extraction, local/coordinator registration and `PUBLISH_OK` |
| `PUBLISH_NAMESPACE` | metrics, local route registration, coordinator registration, forwarding and `REQUEST_OK` |
| `SUBSCRIBE` | metrics, local/remote lookup, cache mutation and response |
| `SUBSCRIBE_NAMESPACE` | leases, coordinator interest, snapshot and `REQUEST_OK` |
| `NAMESPACE` / `NAMESPACE_DONE` discovery | each exact namespace emission or removal |
| `PUBLISH` caused by namespace discovery | each exact track namespace before forwarding |
| `TRACK_STATUS` | local or remote lookup |
| authenticated relay peer | both the exact base operation and an explicit `RelayPeer` operation |

Authorization denials drop the existing protocol request handle, using its
current rejection behavior without a new frame, queue, transport or wire value.
SPIFFE parsing, X.509 interpretation, principal construction, roles and ACL
policy remain entirely with the embedder.

## Tests and results

The new test module uses the existing public I1 synthetic DER fixtures. It
encodes them to temporary PEM files at runtime, uses the real
`moq-native-ietf` QUINN/rustls endpoint, and removes the temporary directory by
RAII. It neither copies fixtures into the relay crate nor adds a crate.

| Test/gate | Result |
|---|---|
| I2-focused tests | pass; 9/9 |
| `cargo test --locked -p moq-relay-ietf` | pass; 132 library tests, 16 binary tests, 1 doctest passed and 1 ignored |
| I1 `peer_evidence` integration regression | pass; 6/6 |
| `cargo clippy --locked --no-deps -p moq-relay-ietf --tests -- -D warnings` | pass |
| rustfmt check limited to the six I2 Rust files | pass |
| `git diff --check` | pass |
| `git diff --cached --check` | pass; index empty |
| no-index whitespace checks for both new files | pass; exit 1 only because content exists, with no diagnostic |
| public derivative live verifier after work | pass; remote remains exact baseline-only state |
| Gitleaks 8.30.1 over every I2 file | pass; zero leaks |
| crate-wide Gitleaks | expected nonzero from the unchanged `src/tls.rs:115` PEM-marker comment only |

The focal tests cover:

- no certificate on raw QUIC and WebTransport: rejection before authentication,
  MoQT, scope and namespace state;
- I1 typed unexpected-identity failure producing no inbound session;
- authenticated scope denial and checked context-type mismatch;
- authorized `PUBLISH` and rejected `SUBSCRIBE` over two different exact
  namespaces;
- `PUBLISH_NAMESPACE` denial before local or coordinator mutation;
- `SUBSCRIBE_NAMESPACE` authorization on the exact prefix plus separate
  authorization of each exact namespace disclosed;
- two concurrent real sessions retaining distinct opaque contexts and exact
  namespaces;
- relay-peer classification and its second explicit authorization gate;
- object safety, `Send + Sync`, no-`Debug` embedder context and fixed redaction;
- unchanged legacy acceptance over raw QUIC and WebTransport; and
- unchanged `moqt-16`, draft-16 numeric value and MoQT Objects types.

No arbitrary UDP test is represented as QUIC and no fragile sleep is used;
bounded Tokio timeouts only guard test failure.

## Toolchain and scanners

- official `rust:1.93.0` image at digest
  `sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57`;
- rustc 1.93.0 commit
  `254b59607d4417e9dffbc307138ae5c86280fe4c`;
- Cargo 1.93.0 commit
  `083ac5135f967fd9dc906ab057a2315861c7a80d`;
- Clippy 0.1.93 and rustfmt 1.8.0-stable from that exact toolchain, installed
  only inside disposable containers;
- rustup 1.28.2, used only inside the disposable image to install those
  components; Rust tooling is `MIT OR Apache-2.0`; and
- Gitleaks 8.30.1, image digest
  `sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f`,
  source revision `83d9cd684c87d95d656c1458ef04895a7f1cbd8e`, MIT.

## Delta and protected hashes

The local I2 working tree contains exactly these six crate files:

- new `moq-relay-ietf/src/authorization.rs`;
- new `moq-relay-ietf/src/i2_tests.rs`;
- modified `moq-relay-ietf/src/lib.rs`;
- modified `moq-relay-ietf/src/relay.rs`;
- modified `moq-relay-ietf/src/producer.rs`; and
- modified `moq-relay-ietf/src/consumer.rs`.

Nothing is staged. `HEAD` remains the exact I1 commit and the local branch has
no upstream/tracking branch.

The following working-tree hashes remain identical to the approved I1 base:

| Protected object | SHA-256 |
|---|---|
| workspace `Cargo.toml` | `6665802c9ad7192d61521a62877454e25bde7072c611e617780a932f583aa48f` |
| `Cargo.lock` | `b518a2fa4a6d7a0ffe0bdfe4b530f05196ac0f5e6f7ef51da9e5a83c0b0561c0` |
| `moq-native-ietf/Cargo.toml` | `3180121a89c58071718236a408f36c1c87757d6f9ff81e899fb3b5814c8d4c8e` |
| `moq-relay-ietf/Cargo.toml` | `c88726b7739c35c4fcb42fd511bfe608e478b5d2489729081821fc84cd1b318d` |
| `moq-transport/Cargo.toml` | `78f582c201082f7badece64f7fa65d215a6694412b7a7699332fa3bc9a4f3743` |
| root `REUSE.toml` | `afc7fd86e591a56078b11982ee4d039ea1dfe3f9d56a90e3e7fa9f84fbddb6cc` |
| MIT license | `c7d191b5901a741f2e39c74bd7a7594014a81fbe2bc7d533d4c29ad4cfe4e057` |
| Apache-2.0 license | `1248f876e0140942002b476a19c95d5b5b44c625e69c96611d23119ee87fa04e` |
| setup/draft/ALPN module | `c49d71dcacd5e3f5eef7a673e11b9058d3fd701e1fb83331a737098894a2d750` |
| transport message module | `e5760f5ce2927b2437511b3e616fea2615d82e916d4b6036b7f5450ae0973352` |

`moq-native-ietf`, `moq-transport`, `moq-api`, all manifests, `Cargo.lock`,
features, licenses and REUSE configuration have no I2 delta. No `unsafe`, new
dependency, new feature, serialization, header/query identity, QUIC endpoint,
wire frame, draft, ALPN, setup, Group, Track or Object change was added.

The known full-workspace E0308 failure and two baseline rustfmt diffs were not
rerun or modified under I2. The focal relay crate gates pass independently.

## Remote and product boundary

The read-only public verifier passed after implementation and still reports the
public independent derivative with only the approved remote baseline commit
`bf87128affd316463e5dcc7599a45001f222b6de`, tree
`d76319009e815fb8923e21fc8319e17a0aaf8174`, and preserved
`MIT OR Apache-2.0`. The local I2 branch is absent remotely.

No commit, push, pull request, issue, Discussion, tag, release, tracking branch,
repository setting change or maintainer communication occurred. Teremoq product
pins, runtime dependencies, Rust/product source, PKI, Docker and Chaos were not
changed. C1, C2 and integration were not started.

## Required next gate

The Master must send this local working tree and report to Task 03 /
`TP-SEC-PKI` for a formal fail-closed, evidence-retention and redaction review.
After that verdict, the Master must choose exactly one of: request local I2
changes, authorize one local I2 commit, or reject the design. None of those
choices authorizes a push or starts C1/C2/integration automatically.

**LOCAL ONLY / NOT PUSHED / NOT COMMITTED**

## Third local iteration: two-phase inbound setup boundary

Timestamp: 2026-08-27 21:34:33 UTC. This appendix responds to the formal
`TP-SEC-PKI` rereview whose SHA-256 is
`71414890a1b2466916e3f4872e0da1d3c1ac0ca5f9cf0ae3883f90142f86502c`.
The rereview remains `CHANGES REQUIRED`; this local correction does not claim
that its HIGH finding is closed before another formal review.

### Corrected transport boundary

`moq-transport` now exposes additive `Session::accept_pending`,
`Session::accept_pending_with_config` and the non-clonable, owned
`PendingSession`. The pending phase owns the WebTransport session and control
stream, decodes and validates CLIENT_SETUP using the existing decoder, and uses
the existing path normalization with WebTransport CONNECT precedence over raw
QUIC PATH. It exposes only `Option<&str>`.

Before `PendingSession::finish` there is no mlog creation or serialization, path
or KVP logging, peer request-ID logging, SERVER_SETUP construction or send,
Queue, PendingRequests, Publisher, Subscriber, Session, or application task.
Dropping the guard rejects via ordinary ownership teardown. Public `finish`
consumes the guard exactly once and uses fixed, redacted observability; it never
records the requested path or CLIENT_SETUP parameters. The legacy
`Session::accept` and `accept_with_config` retain their signatures and existing
post-accept observability through a private legacy finish path.

Required relay ordering is now demonstrably:

1. borrow I1 verified evidence from the accepted QUINN connection;
2. authenticate and discard the evidence before MoQT state;
3. pending CLIENT_SETUP decode and canonical path derivation only;
4. authorize `(authenticated context, requested resource path)`;
5. finish transport setup and send SERVER_SETUP only when allowed; and
6. then create SessionContext, Producer, Consumer or other relay state.

Missing or denied paths close the same connection with fixed text. They produce
no SERVER_SETUP, mlog, handles, Coordinator/tagger call, registration, lookup,
forwarding or namespace mutation. IP, SNI, CID, ConnInfo, ConnectionTagger and
the path remain resources/metadata and never authenticated identity.

### Deterministic evidence

The raw QUIC and WebTransport path-gate test blocks the authorizer with a local
semaphore after it observes the exact canonical path. While blocked, the client
setup `JoinHandle` is not finished, the isolated mlog directory is empty, and
all independent Coordinator and relay-effect counters are zero. Releasing a
denial makes client setup fail and retains every zero. Releasing an allowed path
completes setup and permits the existing exact-operation tests. The missing-path
case likewise fails setup with no mlog or handles. No sleep is used; timeouts are
watchdogs only. Legacy raw QUIC and WebTransport continue to pass.

The transport package also has a public API ownership/`Send` integration test
and unit coverage for canonical CONNECT-over-PATH precedence. The latter is
type-checked but the complete `moq-transport` lib-test target remains blocked by
the pre-existing unrelated E0308 at `src/serve/tracks.rs:501`; it was not edited.

### Package-local fixture boundary

Exactly five public synthetic DER fixtures were copied byte-for-byte into
`moq-relay-ietf/tests/data/i2`: CA certificate, server certificate/key and
client-A certificate/key. Each binary has an adjacent SPDX/REUSE sidecar. The
test-only README states that the keys are public non-production material and
records provenance through `SHA256SUMS`. The copied SHA-256 values match the I1
source bytes exactly:

- CA: `ea33add88bed4676c51baa4f8da9df33d04e99cecf7d0846a756e23b0f66461b`;
- server certificate: `053a80b61f971f0601d83305ec6139fbcd7ed2f78c541078ac6e68a7e6da16bc`;
- server key: `1d02d7ec66886fc2bb2cc3104851e1c182d7980e946d8df2e8f0f3ae33c30436`;
- client-A certificate: `e75cc0d4f020259b4b86d5b722762cbd7aba9b219a8d3234a8b5c5af3e214eb2`;
- client-A key: `416263df93ab7f326f2d82f198fcdf9da850a55e5564ca964c3eceb7976bd288`.

All `include_bytes!` paths now remain inside the relay package. `cargo package
--list --allow-dirty` lists all five DER files, all five sidecars, README and
SHA256SUMS. A `--no-verify` package contained 38 files and tar inspection proved
all fixture paths were under
`moq-relay-ietf-0.7.25/tests/data/i2/`.

### Validation snapshot

Rust used the official 1.93.0 slim image fixed at
`sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57`;
rustfmt and Clippy were installed only in that disposable container.

| Gate | Exact result |
|---|---|
| `cargo test --locked -p moq-relay-ietf` | PASS: library 143/143, binary 16/16, doctests 1 passed/1 ignored |
| I1 `cargo test --locked -p moq-native-ietf --test peer_evidence` | PASS: 6/6 |
| `cargo test --locked -p moq-transport --test pending_accept` | PASS: 1/1 |
| raw QUIC/WebTransport pending, deny, missing, allow and legacy tests | PASS within the 143 relay tests |
| relay Clippy `--tests -- -D warnings` | PASS |
| focused transport integration-test Clippy `-D warnings` | PASS |
| complete transport Clippy `--tests -D warnings` | BLOCKED only by known baseline E0308 at `serve/tracks.rs:501` |
| focal rustfmt 1.93 `--check` | PASS |
| `git diff --check`, cached check and no-index checks | PASS; stage empty |
| REUSE 5.1.1 image `sha256:11eb8a...64f9da` | PASS: 209/209, Apache-2.0 and MIT, zero missing/bad licenses |
| Gitleaks 8.30.1/MIT fixed digest over every changed source and fixture directory | PASS: zero leaks |
| Gitleaks over entire relay crate | one pre-existing synthetic private-key literal in unchanged `src/tls.rs:115`; no I2 finding |

Full `cargo package --allow-dirty` predictably fails verification because the
registry releases of `moq-native-ietf` and `moq-transport` do not yet contain I1
or this pending API. The error names the missing I1 evidence types/method and
pending accept method. Packaging is therefore not publication-ready. The
existing yanked-`bytes` warning and lock advisories are baseline supply-chain
work owned by `TP-OSS-SC`; no version was changed or suppressed here.

### Exact third-iteration delta

In addition to the previously recorded I2 relay files and approved rustls
dev-dependency, this iteration modifies
`moq-transport/src/session/mod.rs`, adds
`moq-transport/tests/pending_accept.rs`, and adds the twelve package-local
fixture/inventory/sidecar files under `moq-relay-ietf/tests/data/i2/`.

Current SHA-256 anchors:

- transport session: `5fa5a8a1c8d68faf86553146eb7b0d39a7ee9aea6a41b97e4abf261500115b00`;
- transport API test: `7165d0bb033e8e0ffe180b384879b8d738235f9e021da57d4a8505567e6f2de1`;
- relay integration tests: `595ac7f27b545c9370b22b8fbf483ac0c4de91e779413f93fc42643d6dca0e6f`;
- relay orchestration: `d224efb6055d10cfd853ac660df93dabda34e2d65424f84d5ecb3a1da29b9bbe`;
- fixture README: `3f6ffc3096c54975fb75b795a06a7b5083c6bd3388a03c3a9023bc3a3ef54862`;
- fixture inventory: `97ed99bcd8d4144652bc729dd6f7e80a4e258f397f3b620a274d9c8b08e2bee9`.

`HEAD` remains I1
`05b41127ecbd48de4c59fe1626c43b1e423c33a9`, its tree remains
`eca64a72e148482fb82b963edc2f2c9af28803f2`, the branch remains
`teremoq/i2-required-auth-bf87128` with no tracking, and the index remains
empty. No commit, push or remote operation occurred. C1/C2 and integration have
not started.

The next gate is a new formal `TP-SEC-PKI` review of this exact snapshot. The
HIGH is not declared closed here.

**LOCAL ONLY / NOT COMMITTED / NOT PUSHED**

---

## Security-review correction iteration

- Snapshot: `2026-08-27T20:54:25Z`
- Binding review: `i2-tp-sec-pki-review-2026-08.md`
- Review SHA-256:
  `ec5960dd6e2a77a30de45c24eed4f95df132d3d9f38fe5085af293682f7754bd`
- Owner: `TP-RUST-DIST`
- State: **LOCAL ONLY / NOT PUSHED / NOT COMMITTED**

This appendix records the correction of all three findings in the binding
`CHANGES REQUIRED` review. It supersedes the earlier current-state claims about
scope resolution, the missing direct rustls test dependency, the six-file
inventory and the nine-test count. It does not erase the earlier snapshot or
change the formal review verdict; Task 03 / `TP-SEC-PKI` must review this new
working tree.

### Corrected requested-resource contract and ordering

`RequestedConnectionPath` is now an upstream-owned typed wrapper with private
storage, a borrowed `as_str` accessor and fixed redacted `Debug`. It is a
resource, not authenticated identity. `SessionAuthorizer::resolve_scope`
receives both `&AuthenticatedSession` and `&RequestedConnectionPath`; it remains
object-safe behind `Arc<dyn SessionAuthorizer>`.

Required mode now applies this order on raw QUIC and WebTransport:

1. I1 evidence is extracted from the established QUINN connection.
2. `PeerEvidence::Rustls` is borrowed by `authenticate`; conversion errors,
   absent evidence, unsupported evidence and authentication denial close the
   same connection without a session handle or fallback.
3. Only the minimal MoQT setup needed to obtain the canonical requested path is
   performed. For raw QUIC this is the unavoidable CLIENT_SETUP PATH exchange;
   WebTransport uses its canonical CONNECT path.
4. A missing path closes fail-closed. Otherwise the required authorizer resolves
   `(authenticated context, exact requested path)` immediately.
5. Only after this gate may the relay create `SessionContext`, Producer,
   Consumer, watchers, perform lookup, registration, forwarding or namespace
   mutation. Required mode never calls legacy `Coordinator::resolve_scope` or
   `ConnectionTagger`.

`AuthorizationError::MissingConnectionPath` is fixed and non-sensitive. Path,
context and all operation `Debug` output remain redacted. Authentication still
derives exclusively from borrowed `VerifiedPeerEvidence`; IP, SNI, CID,
`ConnInfo`, connection path and `ConnectionTagger` do not contribute to
identity. SPIFFE, X.509 interpretation, principal, roles and ACL policy remain
outside `moq-rs`.

### Integrated and adversarial evidence

The tests now consume the fixed public DER fixtures directly through rustls
0.23.31. No certificate is generated or PEM-encoded at runtime. The server uses
the official `WebPkiClientVerifier`, the client presents the fixed synthetic
certificate, and both raw QUIC and WebTransport traverse
`Relay::new_required`.

The valid-certificate authentication-denial test proves exactly one call to
`authenticate`, zero scope calls, zero Coordinator calls, client setup failure,
and zero Producer, Consumer, lookup, registration, response or namespace
effects. Separate integrated tests use the same synthetic certificate and
derived test context for an allowed exact path and a denied exact path over both
transports. The denied and missing-path cases create no relay application state.

Per-session probes exist only under `cfg(test)`, are injected by each test and
have no global or thread-local state. They are independent of the authorizer's
operation record and observe the actual effect boundaries. Together with MoQT
handles, `Locals` state and an independently instrumented Coordinator they prove:

| Denied action | Deterministic zero-effect evidence |
|---|---|
| `PUBLISH` | protocol error; no reader extraction, local/Coordinator registration or positive response |
| `SUBSCRIBE` against an existing track | protocol error; no local/remote lookup, cache or serve; independent fixture remains present |
| `SUBSCRIBE_NAMESPACE` | `REQUEST_ERROR`; no lease, Coordinator interest, snapshot or `REQUEST_OK` |
| `NAMESPACE` | no event and no known-state effect after exact discovery denial |
| `NAMESPACE_DONE` | initial allowed event remains; denied removal emits no event or known-state mutation |
| discovery with `Publish` | base gate allowed, exact second gate denied, zero outbound `PUBLISH` |
| `TRACK_STATUS` against an existing track | no lookup and no response |
| authenticated relay peer | base operation allowed, explicit second relay-peer gate denied; no registration, lookup, forwarding, response or mutation |

No test uses sleeps. Timeouts are watchdogs around protocol completion or an
independent semaphore signal; they are not the effect oracle.

### Exact validation results

All Cargo tests ran with the official Rust 1.93.0 slim image pinned at
`sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57`,
rustc commit `254b59607d4417e9dffbc307138ae5c86280fe4c`.

| Validation | Result |
|---|---|
| I2-focused test filter | PASS: 20/20 |
| `cargo test --locked -p moq-relay-ietf` library | PASS: 143/143 |
| same command, binary | PASS: 16/16 |
| same command, doctests | PASS: 1 passed, 1 ignored |
| `cargo test --locked -p moq-native-ietf --test peer_evidence` | PASS: 6/6 |
| `cargo clippy --locked --no-deps -p moq-relay-ietf --tests -- -D warnings` | PASS |
| rustfmt 1.93 check over the six I2 Rust files | PASS |
| `git diff --check` and `git diff --cached --check` | PASS; index empty |
| no-index checks for both new Rust files | PASS: exit 1 means content exists; no whitespace diagnostic |
| Gitleaks 8.30.1 fixed image over all eight delta files | PASS: zero leaks in each file |

Clippy and rustfmt were installed only inside a disposable, previously audited
Rust 1.93 tool image at
`sha256:ba076cf0a26aa41efdd2f0f80687ef97009d1526680751456c19cc944dff1d0b`;
the host was not modified. Gitleaks used the fixed MIT-licensed image digest
`sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f`.

### Exact delta, licenses and hashes

The current unstaged delta is exactly:

- modified `Cargo.lock`;
- modified `moq-relay-ietf/Cargo.toml`;
- new `moq-relay-ietf/src/authorization.rs`;
- modified `moq-relay-ietf/src/consumer.rs`;
- new `moq-relay-ietf/src/i2_tests.rs`;
- modified `moq-relay-ietf/src/lib.rs`;
- modified `moq-relay-ietf/src/producer.rs`; and
- modified `moq-relay-ietf/src/relay.rs`.

The only manifest change is the explicitly authorized dev-dependency
`rustls = 0.23.31` with `default-features = false` and feature `ring`.
`Cargo.lock` adds only `rustls 0.23.31` to the existing
`moq-relay-ietf` package dependency list; no package version or checksum
changed. rustls 0.23.31 declares `Apache-2.0 OR ISC OR MIT`. It is test-only and
adds no runtime dependency or feature to the relay.

| Current object | SHA-256 |
|---|---|
| `Cargo.lock` | `13b9f1c54ccbe644dcf4f07542f610950cd013b291c928b6b3ad39ac1751ce80` |
| `moq-relay-ietf/Cargo.toml` | `83185ddb3f1523a6d7d9c577abbf29010eb34d6043538c1b28ff1057bb888b11` |
| `authorization.rs` | `101fc1a0a8c1fc8d61453f43617cbfef1913a7db91767f29c9e59b9970d148c2` |
| `consumer.rs` | `06f601e1f4efdb3c7f4bca99114d275db0abcdca436fece01c352f3fb13a256d` |
| `i2_tests.rs` | `607fc9e7d2f9bbcfcfc16314f7375c5e580d93be4038f24fe6d8568a173523c4` |
| `lib.rs` | `c3ccba4a249469e3926a5a6e8f92912694808c13e2fe9cd42e74c08dc9c34990` |
| `producer.rs` | `8b9c723341ad93c77f94a57fc833323c695d45078edd541c0a42a80ea51e966e` |
| `relay.rs` | `0879a9a01d84cbf6a41f02f0ac3bb72280c838f67948e871a17ee1a463095a66` |

The workspace manifest, `moq-native-ietf`, I1, `moq-transport`, setup, draft,
ALPN, wire types, Objects, REUSE and root license files are byte-identical to
I1. Protected hashes remain:

- workspace manifest:
  `6665802c9ad7192d61521a62877454e25bde7072c611e617780a932f583aa48f`;
- `moq-native-ietf/Cargo.toml`:
  `3180121a89c58071718236a408f36c1c87757d6f9ff81e899fb3b5814c8d4c8e`;
- `moq-transport/Cargo.toml`:
  `78f582c201082f7badece64f7fa65d215a6694412b7a7699332fa3bc9a4f3743`;
- setup/ALPN module:
  `c49d71dcacd5e3f5eef7a673e11b9058d3fd701e1fb83331a737098894a2d750`;
- draft version module:
  `384772b32812a0761fa55d16a9fd29e30595323ece1b3fca013ec3720eaec4ad`;
- `REUSE.toml`:
  `afc7fd86e591a56078b11982ee4d039ea1dfe3f9d56a90e3e7fa9f84fbddb6cc`;
- MIT license:
  `c7d191b5901a741f2e39c74bd7a7594014a81fbe2bc7d533d4c29ad4cfe4e057`;
- Apache-2.0 license:
  `1248f876e0140942002b476a19c95d5b5b44c625e69c96611d23119ee87fa04e`.

`HEAD` remains I1
`05b41127ecbd48de4c59fe1626c43b1e423c33a9`, the branch remains
`teremoq/i2-required-auth-bf87128` without tracking, and the stage is empty.
The known full-workspace baseline E0308 and two unrelated rustfmt diffs were not
modified or hidden; full-workspace checks were not repeated in this correction.

### Remaining gate

No I2 finding is claimed closed until Task 03 / `TP-SEC-PKI` reviews this exact
new snapshot. The Master must request that second formal review. Only an
`APPROVE FOR LOCAL COMMIT` verdict plus separate Master authorization could
permit a local commit. Push, PR, issue, Discussion, tag, release, remote mutation,
product pins, I1 changes, C1, C2 and integration remain unauthorized and were
not performed.

**LOCAL ONLY / NOT PUSHED / NOT COMMITTED**

---

## Current-state chronology marker

The later snapshot is the section **Third local iteration: two-phase inbound
setup boundary**, timestamped 2026-08-27 21:34:33 UTC above. It supersedes only
the current-state and inventory claims in the intervening historical security
correction appendix; those older results remain preserved as review history.
The authoritative current gate is a new formal `TP-SEC-PKI` review of the
two-phase snapshot. No HIGH finding is claimed closed.

**LOCAL ONLY / NOT COMMITTED / NOT PUSHED**
