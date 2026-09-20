# TP-SEC-PKI review: I1 connection-bound peer evidence

- Review date: 2026-08-26
- Reviewer: `TP-SEC-PKI`
- Owner under review: Task 05 / `TP-RUST-DIST`
- Local checkout: `/home/jimbomilk/moq-rs-teremoq-work`
- Branch: `teremoq/i1-peer-evidence-bf87128`
- Reviewed HEAD: `bf87128affd316463e5dcc7599a45001f222b6de`
- Scope: local I1 diff in `moq-native-ietf/src/quic.rs` and
  `moq-native-ietf/tests/` only
- Verdict: **CHANGES REQUIRED**

## Findings

### High: evidence-conversion errors still expose a live session

Locations:

- `moq-native-ietf/src/quic.rs:506`
- `moq-native-ietf/src/quic.rs:511`
- `moq-native-ietf/src/quic.rs:521`
- `moq-native-ietf/src/quic.rs:526`
- `moq-native-ietf/src/quic.rs:565`

`AcceptedSession` stores
`Result<PeerEvidence, PeerEvidenceError>`, while `session()` exposes the live
session without first resolving that result and `into_parts()` returns the
session alongside the unresolved error. Consequently,
`EmptyCertificateChain` or `UnexpectedIdentityType` can be ignored and the
caller can continue using the session after explicitly selecting
`accept_with_peer_evidence()`.

The error variants are distinct and redacted, but placing them inside an
otherwise usable accepted session is not fail-closed by construction. This is
particularly dangerous for I2: a future `required` mode could accidentally
continue to scope or namespace handling by dropping or overlooking the third
tuple element. The current rustls-only configuration makes these two errors
unlikely during a normal verified handshake, but the public API explicitly
models them and must remain safe if they occur.

Required contract correction:

1. Return evidence-conversion failure outside any usable session, for example
   `Option<Result<AcceptedSession, PeerEvidenceError>>`.
2. Construct `AcceptedSession` only after evidence conversion succeeds; its
   field should contain `PeerEvidence`, not a nested `Result`.
3. On `EmptyCertificateChain` or `UnexpectedIdentityType`, close/drop that exact
   connection before returning the typed error and expose no session handle.
4. Keep `PeerEvidence::Absent` explicit so optional callers can observe it and
   I2 `required` can reject it before scope or namespace state.
5. Add a test demonstrating that an evidence-conversion error cannot yield or
   access a session.

### Medium: the legacy accept path now extracts and clones peer certificates

Locations:

- `moq-native-ietf/src/quic.rs:551`
- `moq-native-ietf/src/quic.rs:552`
- `moq-native-ietf/src/quic.rs:654`

`Server::accept()` preserves its source signature but delegates unconditionally
to `accept_with_peer_evidence()`. That path always calls
`quinn::Connection::peer_identity()` and then discards the evidence for legacy
callers. In the fixed QUINN/rustls implementation, `peer_identity()` iterates
the rustls peer certificates, clones each certificate into owned DER and
collects a new vector. Therefore every legacy mTLS acceptance now performs an
unnecessary extraction, allocation and temporary retention of the full chain.

This does not grant the legacy caller a false authorization guarantee because
the evidence is discarded, and it does not change ALPN or MoQT wire behavior.
It nevertheless changes the privacy and resource behavior of the legacy path
and violates the minimum-exposure requirement.

Required contract correction:

1. Evidence capture must be opt-in and fixed before acceptance begins, using a
   server mode or distinct evidence-aware acceptor/type.
2. Legacy `Server::accept()` must not call `peer_identity()` or allocate an
   owned certificate chain.
3. Do not select capture with a per-call flag that can be confused by already
   pending futures in the shared `FuturesUnordered`; the mode must be stable for
   the acceptor lifetime or otherwise preserve each pending connection's
   unambiguous contract.
4. Preserve the exact legacy return type and existing raw QUIC/WebTransport
   wire behavior.
5. Add a focused test or injectable extraction boundary proving that the legacy
   path never invokes the peer-evidence extractor.

### Low: cloneable evidence can outlive its accepted session

Locations:

- `moq-native-ietf/src/quic.rs:409`
- `moq-native-ietf/src/quic.rs:430`

`VerifiedPeerEvidence` and `PeerEvidence` derive `Clone`. The internal `Arc`
avoids an immediate byte-for-byte copy, but cloning either wrapper can retain
the complete DER chain after the corresponding session has closed. Neither
`Send + Sync` nor external policy parsing requires these public `Clone`
implementations: I2 can borrow `certificates()`, derive a redacted principal and
then release the evidence.

Required contract correction:

1. Remove `Clone` from `VerifiedPeerEvidence` and `PeerEvidence` unless a
   concrete in-scope consumer demonstrates that it is necessary.
2. Preserve the borrowed `certificates()` accessor and the existing `Send +
   Sync` guarantees.
3. Document that the embedder must derive its principal while borrowing the
   evidence and must not retain DER in authorization context, logs or metrics.

The public `certificates()` accessor itself is an acceptable trust-boundary
risk: an external X.509/SPIFFE policy needs access to authenticated DER, and a
deliberately malicious or careless embedder can always copy or log bytes it is
allowed to inspect. Fixed wrapper `Debug` implementations reduce accidental
exposure but cannot sandbox the caller. Removing unnecessary wrapper cloning
still narrows accidental retention.

### Low: failing certificate assertions can persist raw DER

Locations:

- `moq-native-ietf/tests/peer_evidence.rs:200`
- `moq-native-ietf/tests/peer_evidence.rs:254`

Both assertions use `assert_eq!` on slices of `CertificateDer`. On failure,
Rust formats both operands with `Debug`; `CertificateDer` implements `Debug`,
so CI or another persisted test log can include raw DER and chain length. The
fixtures are deliberately public and test-only, which reduces the sensitivity,
but the assertions still contradict the redaction invariant and teach an
unsafe diagnostic pattern for future non-public fixtures.

Required contract correction:

1. Compare certificate slices through a boolean assertion with a fixed failure
   message that does not format operands.
2. Do not replace the leak with a full fingerprint or chain-length diagnostic.
3. Retain the two-peer binding assertion without printing certificate material.

## Verified security properties

- The evidence is obtained from the same `quinn::Connection` at
  `moq-native-ietf/src/quic.rs:649-654`, after `conn.await` completes and before
  that connection is moved into raw QUIC or WebTransport session ownership.
- `None`, a non-empty rustls chain, an empty rustls chain and an unexpected
  dynamic `Any` type have separate typed states. There is no IP, SNI, path,
  global, task-local or thread-local fallback to identity.
- The rustls chain is converted to owned, immutable evidence and the relevant
  evidence/error types compile as `Send + Sync`; `AcceptedSession` compiles as
  `Send`.
- Manual `Debug` and fixed `Display` implementations for
  `VerifiedPeerEvidence`, `PeerEvidence`, `PeerEvidenceError` and
  `AcceptedSession` do not expose DER, PEM, chain length, subject, SAN, serial,
  fingerprint or complete identity.
- The I1 diff does not pass evidence to tracing, anyhow contexts, qlog, mlog,
  metrics, URLs, WebTransport metadata or MoQT.
- Raw QUIC and WebTransport use the existing endpoint and are both exercised by
  a real rustls/QUINN handshake. The diff does not change MoQT draft-16, raw
  QUIC ALPN `moqt-16`, WebTransport negotiation, setup, Tracks, Groups or
  Objects.
- The two-peer test launches distinct clients concurrently. It obtains each
  expected client socket before connecting and uses `remote_address` only as an
  independent test oracle for the expected public fixture; production evidence
  comes directly from each accepted connection, not from its address.
- `PeerEvidence`, `PeerEvidenceError` and `AcceptedSession` are
  `#[non_exhaustive]`; fields remain private; the legacy public return type is
  unchanged; the evidence-aware accessors and `into_parts()` are additive.
- No new production `panic`, `unwrap`, `expect` or `unsafe` was added. Existing
  baseline unwraps outside the I1 additions are not reclassified as I1 changes;
  test-only panics are local assertions.

## Fixture and publication review

- `moq-native-ietf/tests/data/` contains a deliberately public test CA, one
  server identity and two client identities. The README says explicitly that
  the keys are test-only, non-production and must never be reused.
- The SHA-256 inventory matches every DER file.
- OpenSSL parsing confirmed valid DER, matching certificate/key pairs, CA basic
  constraints, server/client EKUs and current validity.
- Every binary has an individual `MIT OR Apache-2.0` REUSE sidecar; the README
  and Rust test also carry SPDX headers and record OpenSSL 3.5.5 provenance.
- All fixtures have mode `0644`. This is acceptable for deliberately public,
  committed test keys and must not be copied as a production-key permission
  precedent.
- The binary fixtures contain no PEM private-key markers. No local scanner
  ignore entry was found; a narrow fixture-specific exception should be added
  only if an actual publication scanner flags these known public test assets.
  A blanket key-path exclusion would be unsafe.
- Text added by I1 contains no complete SPIFFE identity, production namespace,
  customer data, certificate subject, serial or private deployment material.

## Delta, tests and residual gaps

At review time the local branch remained at baseline HEAD
`bf87128affd316463e5dcc7599a45001f222b6de`, tree
`d76319009e815fb8923e21fc8319e17a0aaf8174`. The working tree contained only:

- modified `moq-native-ietf/src/quic.rs`; and
- untracked `moq-native-ietf/tests/`.

There were no staged changes. Workspace or crate manifests, `Cargo.lock`,
features, dependencies, `REUSE.toml`, license texts, `moq-transport`,
`moq-relay-ietf` and wire/setup code were unchanged. No `unsafe` was added.

A focused read-only reproduction used Rust 1.93.0 with the checkout mounted
read-only and `CARGO_HOME`/`CARGO_TARGET_DIR` under the disposable container's
`/tmp`:

- `cargo test --locked -p moq-native-ietf --test peer_evidence`:
  **5 passed, 0 failed, 0 ignored**.

An earlier no-network invocation did not run because its ephemeral image lacked
a complete Cargo cache; it made no workspace changes and is not a code failure.
The focused successful run does not independently reproduce the report's full
crate or workspace gates.

Residual gaps after the passing tests:

- Empty-chain and unexpected-`Any` semantics are tested at the typed extractor
  boundary rather than through a second live crypto backend. Adding a backend
  solely for that test would violate I1's single-stack/no-dependency scope.
- There is no test proving that a `PeerEvidenceError` makes the session
  inaccessible; the present API cannot satisfy such a test.
- There is no test proving that legacy acceptance skips extraction; the present
  implementation always extracts.
- Concurrent isolation is exercised with raw QUIC; WebTransport evidence is
  exercised separately. This is sufficient to review connection binding but
  does not replace later I2 concurrent authorization tests.
- I1 exposes authenticated evidence only. It does not parse SPIFFE, construct a
  principal, authorize roles/namespaces or make Teremoq Zero-Trust complete.

## Verdict

**CHANGES REQUIRED**

The same-connection evidence plumbing, redaction and concurrent binding are
sound, but I1 is not ready for a local commit while the evidence-aware API can
return a live session containing an ignored conversion error and the legacy API
always clones certificate material it does not request. The two low-severity
retention/output findings must also be corrected before approval.

## Reviewer activity confirmation

`TP-SEC-PKI` performed read-only inspection of
`/home/jimbomilk/moq-rs-teremoq-work`. The reviewer did not edit that checkout,
did not modify product code, did not create a commit or tag, did not push, and
did not change any remote, issue, pull request, Discussion, release or
repository setting. The only persisted reviewer output is this report in the
Teremoq governance workspace.

## Second iteration — 2026-08-27

This section is an append-only reassessment of the corrected I1 working tree.
It does not replace, weaken or erase the initial `CHANGES REQUIRED` decision
above. The initial decision remains the historical record of the first
iteration; the verdict at the end of this section applies only to the second
iteration reviewed here.

### Review boundary and state

- Local checkout: `/home/jimbomilk/moq-rs-teremoq-work`
- Branch: `teremoq/i1-peer-evidence-bf87128`
- HEAD: `bf87128affd316463e5dcc7599a45001f222b6de`
- Tree at HEAD: `d76319009e815fb8923e21fc8319e17a0aaf8174`
- I1 remains unstaged working-tree content only.
- The only local I1 paths remain modified
  `moq-native-ietf/src/quic.rs` and untracked `moq-native-ietf/tests/`.
- No manifest, lockfile, dependency, feature, license, `unsafe`,
  `moq-transport`, `moq-relay-ietf`, setup, Track, Group, Object or other wire
  implementation changed.

### Findings by current line

No blocking security finding remains in the second iteration. Each of the four
historical findings is resolved as follows.

#### Resolved: evidence errors are outside every usable session

Current locations:

- `moq-native-ietf/src/quic.rs:504-528`
- `moq-native-ietf/src/quic.rs:584-596`
- `moq-native-ietf/src/quic.rs:731-755`
- `moq-native-ietf/src/quic.rs:829-864`
- `moq-native-ietf/src/quic.rs:1124-1146`

`AcceptedSession` now contains `PeerEvidence`, not
`Result<PeerEvidence, PeerEvidenceError>`. `CapturePeerEvidenceMode::capture`
owns `EstablishedConnection` while it extracts evidence and returns an error
before `EstablishedConnection::into_session` can construct WebTransport or raw
QUIC application state. On conversion failure, unwinding the owned resource
from `capture` drops the exact `EstablishedConnection` and its
`quinn::Connection`; no session handle is constructed or returned.

`PeerEvidenceServer::accept()` exposes the required outer shape
`Option<Result<AcceptedSession, PeerEvidenceError>>`. It returns an evidence
error without an application session, while `PeerEvidence::Absent` remains a
distinct successful evidence state for optional consumers and a future I2
`required` authorizer to deny explicitly before scope/namespace processing.

The generic `DropProbe` regression test demonstrates that the resource is
dropped on extraction error and cannot be recovered from the result. A live
unexpected-backend integration case remains intentionally unavailable because
the fixed endpoint has only the rustls backend; the ownership proof is at the
same generic capture boundary used by the real connection.

Risk conclusion: the initial high-severity continuation path is closed. I2 can
implement fail-closed required authorization without receiving a session on
evidence-conversion failure.

#### Resolved: legacy acceptance has a stable no-extraction mode

Current locations:

- `moq-native-ietf/src/quic.rs:561-596`
- `moq-native-ietf/src/quic.rs:758-810`
- `moq-native-ietf/src/quic.rs:820-864`
- `moq-native-ietf/src/quic.rs:1148-1161`
- `moq-native-ietf/tests/peer_evidence.rs:182-196`

`LegacyEvidenceMode::capture` deliberately does not invoke its extractor
closure. `Server` stores only `LegacyAcceptFuture` values, whereas
`PeerEvidenceServer` stores only `PeerEvidenceAcceptFuture` values. The
evidence-aware mode is selected by consuming a clean `Server` before any
legacy acceptance; it cannot be selected after `accept_started` becomes true
or a legacy future exists.

This is a stable type/lifetime decision rather than a per-call flag. Therefore
no future accepted under legacy semantics can later be interpreted as an
evidence-aware result, and legacy `Server::accept()` no longer executes
`Connection::peer_identity()` or clones certificate material. The unit test
uses an observable extractor closure to prove it is not called. The integration
test polls and cancels a legacy accept with no client, then verifies that a mode
switch is rejected.

Risk conclusion: the initial medium-severity privacy/resource regression is
closed, and cancellation cannot reopen a mixed-future transition.

#### Resolved: certificate evidence wrappers are not cloneable

Current locations:

- `moq-native-ietf/src/quic.rs:404-436`
- `moq-native-ietf/src/quic.rs:1163-1173`

`VerifiedPeerEvidence` and `PeerEvidence` no longer implement `Clone`. Their
manual redacted `Debug`, borrowed `certificates()` accessor and `Send + Sync`
properties remain. The API documentation now instructs embedders to derive the
authenticated principal while borrowing the evidence and not retain DER in
authorization context, logs or metrics.

Risk conclusion: the initial low-severity accidental retention path is closed.
An embedder with legitimate access to raw DER can still copy or log it
deliberately; that is an unavoidable external-policy trust-boundary risk, not a
remaining defect in I1.

#### Resolved: certificate assertions cannot format DER

Current locations:

- `moq-native-ietf/tests/peer_evidence.rs:170-180`
- `moq-native-ietf/tests/peer_evidence.rs:224-228`
- `moq-native-ietf/tests/peer_evidence.rs:278-289`

Certificate equality is now reduced to a boolean by `evidence_matches` and
asserted with fixed messages. Neither operand, the chain, its length nor a
fingerprint is formatted on failure. The two-peer test retains the independent
socket-address oracle strictly in test code and does not turn an address into a
production identity.

Risk conclusion: the initial low-severity persisted-test-output disclosure is
closed.

### `EstablishedConnection` and transport regression review

Current locations:

- `moq-native-ietf/src/quic.rs:604-685`
- `moq-native-ietf/src/quic.rs:688-727`
- `moq-native-ietf/src/quic.rs:731-755`

The refactoring separates establishment from application-session construction
without changing the protocol sequence:

1. The original destination CID is captured before accepting `Incoming`.
2. The same qlog-enabled or base server configuration is selected.
3. `handshake_data()` is awaited and downcast through the existing rustls
   handshake type.
4. ALPN and SNI are retained, then the same `Connecting` is awaited to a fully
   established `quinn::Connection`.
5. The selected capture mode receives that exact connection.
6. Only after successful capture is the connection moved to the existing
   WebTransport request/response path or raw QUIC `Session::raw` path.

ALPN comparisons remain byte-exact against
`web_transport_quinn::ALPN.as_bytes()` and `moq_transport::setup::ALPN`.
WebTransport protocol response selection and the raw `moqt://localhost`
session construction remain behaviorally identical to baseline. Lossy UTF-8
conversion remains limited to diagnostic text for ALPN and does not influence
the comparison. No MoQT bytes, draft constants or ALPN values changed.

No new evidence material is passed to qlog, tracing, anyhow contexts, mlog,
metrics, URLs, WebTransport metadata or MoQT. Transport failures continue to
log a root cause and affect only that acceptance future.

### Cancellation and future-isolation review

Current locations:

- `moq-native-ietf/src/quic.rs:758-795`
- `moq-native-ietf/src/quic.rs:798-810`
- `moq-native-ietf/src/quic.rs:820-864`

Both acceptors retain their `FuturesUnordered` collection in the owning server
object. Cancelling an individual call to `accept()` therefore cancels only that
borrow/poll; already inserted connection futures remain owned by the same
acceptor and are polled by the next call. `Server::accept_started` is set at the
first poll before any incoming connection can be inserted. A later attempted
conversion to `PeerEvidenceServer` fails even if the cancelled poll occurred
before a client arrived.

The two queues have different concrete future/result aliases, and conversion
creates a new empty evidence queue only while the legacy queue has never
started. There is no cast, enum fallback, shared map or dynamic mode field that
could mix legacy and evidence-aware futures. Dropping either server drops its
own pending futures and their connection resources.

Risk conclusion: no cancellation or cross-queue route was found that can attach
one peer's evidence to another connection or allow a legacy result into future
required authorization.

### Non-blocking API documentation note

At `moq-native-ietf/src/quic.rs:543`, the variant documentation for
`AcceptanceAlreadyStarted` says that at least one legacy connection future is
pending. The implementation also returns this variant after a legacy accept
has merely been polled and cancelled before any client arrives. The enum name
and fixed `Display` text correctly describe the broader behavior, and the test
at `moq-native-ietf/tests/peer_evidence.rs:182-196` demonstrates it. Tightening
that one doc comment would improve precision but is not a security or commit
blocker.

### Validation evidence

The Master supplied the completed second-iteration validation and requested
that this reviewer not repeat the long suite:

- Rust 1.93 focal crate tests: **13 passed, 0 failed**.
- Clippy including tests: passed.
- Focused rustfmt validation: passed.
- Gitleaks over `moq-native-ietf`: no secrets detected.
- The local branch remains at the approved baseline HEAD with no I1 commit.

`TP-SEC-PKI` independently inspected the complete current diff and test source.
No second transport stack, dependency, feature, `unsafe`, wire change or
private/product identity material was found.

### Residual risks and downstream obligations

- I1 provides verified connection-bound certificate evidence only. It does not
  parse SPIFFE, derive a principal, authorize roles/operations/namespaces or
  make Teremoq Zero-Trust complete.
- I2 `required` must treat `PeerEvidence::Absent` as denial and complete
  identity/policy authorization before `resolve_scope` or namespace state. It
  must never fall back to the legacy acceptor.
- The public `certificates()` accessor necessarily permits an external policy
  implementation to copy or log DER. I2 must borrow, parse, derive a redacted
  principal and release evidence without storing certificate material.
- Empty chain and unexpected dynamic identity are structurally tested at the
  capture boundary, not with a second live crypto backend; adding another
  backend solely for testing would violate the approved single-stack scope.
- Raw QUIC and WebTransport are both covered for evidence. Concurrent
  two-identity isolation is exercised over raw QUIC; I2 still requires its own
  concurrent authorization tests across principal, role and namespace state.
- Pending-handshake/session bounds and bounded coordinated shutdown remain C1
  and C2 concerns. Approval of I1 does not claim those controls complete.
- The fixed public test keys remain test-only and must never become deployment
  material or a production permission precedent.

### Second-iteration verdict

**APPROVE FOR LOCAL COMMIT**

The four findings that caused the initial rejection are corrected, and the
`EstablishedConnection`/`PeerEvidenceServer` refactoring preserves connection
ownership, ALPN, raw QUIC/WebTransport behavior, cancellation safety and future
isolation. This approval authorizes only creation of the reviewed local I1
commit by the owning Task after its normal exact-diff/provenance checks. It does
not authorize push, publication, I2, C1, C2, product pin changes or a Zero-Trust
claim.

### Second-iteration reviewer activity confirmation

`TP-SEC-PKI` did not edit `/home/jimbomilk/moq-rs-teremoq-work`, product code,
tests, manifests or fixtures; did not create a commit or tag; did not push; and
did not modify a remote, issue, pull request, Discussion, release or repository
setting. The only edit performed by this reviewer is this appended historical
section in the Teremoq review report.
