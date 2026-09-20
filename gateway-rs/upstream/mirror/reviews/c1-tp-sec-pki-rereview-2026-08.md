<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# C1 TP-SEC-PKI security rereview: corrected bounded native handshakes

Status: **READ-ONLY SECURITY REVIEW / NO COMMIT / NO PUSH / NO REMOTE MUTATION**

Review date: `2026-08-28`.

Reviewer: `TP-SEC-PKI`. Code owner: `TP-RUST-DIST`.

This rereview is limited to exhaustion resistance, admission and permit
ownership, terminal ordering, redaction, and the test-only PKI fixtures. It does
not authorize C2, a push, publication, or any remote mutation.

## Findings

No open security finding was identified in the corrected C1 delta.

### CLOSED — prior HIGH: arbitrary observer no longer exists in the admission or Drop path

Locations: `moq-native-ietf/src/quic.rs:146-157`, `:240-249`, `:273-315`,
`:746-804`, `:840-863`.

The prior public synchronous callback, its event type, its state field, its
constructor parameter and all calls to it have been removed. A symbol and diff
search found no `HandshakeAdmissionObserver`, `with_observer`, observer field,
event emitter, replacement callback, queue, spawned task or other arbitrary
embedder code in production admission or destruction.

`HandshakeAdmissionState` now contains only the semaphore, its immutable limit
and atomic counters. `try_admit` uses the non-waiting `try_acquire_owned`, builds
the guard and increments a scalar counter. `HandshakePermitGuard::drop` only
marks the guard terminal, takes and drops its owned permit, and then increments
the cancellation counter. It cannot block on user code and contains no async
operation, queue operation or task creation. A panic while the bounded accept
future owns the guard unwinds through this same RAII path; the removed callback
can no longer block or panic during that unwind.

The `TestHooks` channel and semaphore at lines 746-804 are wholly `#[cfg(test)]`;
the non-test aliases and functions are `()` and no-ops. They are deterministic
test seams, not a displaced production observer. The phrase “capacity observer
thread” in the assertion at `quic_c1_tests.rs:324` names a standard test thread
which reads a snapshot after the guard was dropped; it is not callable from
admission or `Drop`.

### CLOSED — prior MEDIUM: watchdog coverage and MAX validation are explicit

Locations: `moq-native-ietf/src/quic.rs:74-82`, `:93-117`, `:191-208`,
`:589-607`; `moq-native-ietf/src/quic_c1_tests.rs:156-189`, `:191-214`,
`:237-324`, `:634-648`, `:681-696`, `:724-738`.

All corrected polling/progress loops use one absolute `timeout_at` deadline or
the shared finite watchdog. Failure messages are fixed strings which identify
only an expected stage or counter. There are no sleeps and no peer-derived
values in watchdog failures.

Both public construction boundaries which accept a permit count validate
`limit <= tokio::sync::Semaphore::MAX_PERMITS`. `HandshakeAdmission::new`
performs that check before the only added `Semaphore::new`; it is fallible and
returns the typed `TooManyPendingHandshakes` error. `ServerAdmissionConfig::new`
validates the same bound, and `Endpoint::new_bounded` propagates the fallible
controller construction. `Endpoint::new_bounded_with_admission` accepts only
the two already-validated, private-field types and verifies that their limits
match. The boundary test accepts exactly `MAX_PERMITS` and uses `catch_unwind`
to prove that `MAX_PERMITS + 1` fails without a Tokio panic, including endpoint
propagation.

## Security controls independently confirmed

### Permit lifecycle and memory ordering

- Successful, transport-error and timeout terminals call `finish` at
  `quic.rs:280-301`. It sets the single-finish bit and drops
  `OwnedSemaphorePermit` before publishing the relevant terminal counter with
  `Ordering::Release`.
- Cancellation and unwind use `Drop` at `quic.rs:305-315`; the permit is likewise
  dropped before the cancellation counter's release operation. `finish`
  consumes the guard and sets `terminal=true`, so its subsequent destructor is
  inert. The `Option::take` is an additional exactly-once ownership barrier.
- `snapshot` loads all terminal counters with `Ordering::Acquire` before reading
  `available_permits` (`quic.rs:214-238`). Consequently, a snapshot which
  observes a terminal increment also observes the preceding permit release.
  Non-terminal telemetry remains relaxed and is not used as this publication
  barrier.
- The RAII regression at `quic_c1_tests.rs:301-324` observes zero pending capacity
  before the cancellation terminal, immediately reacquires it, and confirms one
  further cancellation for one further dropped guard.

There is no arbitrary callback left whose panic or blocking behavior could run
inside admission, `finish` or `Drop`. A panic in the handshake future before a
terminal is selected therefore releases capacity through RAII exactly once.

### Fail-closed overload, Retry and deadline behavior

- The bounded server receives a QUINN `Incoming`, performs the immediate permit
  attempt and only then constructs/pushes the expensive accept future
  (`quic.rs:830-863`). No TLS/QUIC accept, WebTransport CONNECT, application
  setup or spawned task precedes permission.
- Saturation calls the synchronous `dispose_capacity` at `quic.rs:880-904`.
  It neither waits nor enqueues work: `Refuse` refuses immediately; `Retry`
  retries only when QUINN says it is legal, and any retry failure regains and
  refuses the `Incoming`. A token-bearing subsequent attempt has
  `may_retry() == false` and is refused, preventing a server-generated Retry
  loop.
- A single absolute `timeout_at` at `quic.rs:906-934` covers the complete
  expensive native accept, including raw QUIC/TLS and WebTransport CONNECT.
  Timeout and transport-error outcomes release their permits before their error
  becomes observable; completion releases before returning the session.
- Real QUINN/rustls tests cover raw QUIC and WebTransport success, overload at
  N+1 and burst N/M, legal and token-bearing Retry paths, TLS failure, absolute
  deadlines before transport and during CONNECT, future cancellation, server
  drop at each test seam, shared/local controllers and qlog/`accept_with`.

### Redaction and trust boundary

The new public snapshot structs expose only schema version, configured caps,
in-flight count and aggregate counters. The C1 delta adds no IP address, CID,
SNI, path, identity, subject, SAN, serial, fingerprint, certificate, key,
payload, peer error or peer-supplied string to `Debug`, `Display`, tracing,
metrics, qlog, watchdog text or assertion messages. Existing legacy `ConnInfo`
and qlog behavior is outside the new observer/counter surface and is unchanged.

No `unsafe`, wire constant, draft number, ALPN, object model, dependency,
feature, manifest or lockfile change is present. `Endpoint::new` remains the
source-compatible legacy-unbounded constructor; callers receive C1 protection
only by selecting a bounded constructor.

### Test-only PKI fixtures

The three DER objects are byte-identical to the existing public I1 fixtures:

- `ca.cert.der`:
  `ea33add88bed4676c51baa4f8da9df33d04e99cecf7d0846a756e23b0f66461b`
- `server.cert.der`:
  `053a80b61f971f0601d83305ec6139fbcd7ed2f78c541078ac6e68a7e6da16bc`
- `server.key.der`:
  `1d02d7ec66886fc2bb2cc3104851e1c182d7980e946d8df2e8f0f3ae33c30436`

`SHA256SUMS` verifies all three and the certificate/key public keys correspond.
The fixture README labels them synthetic, public and test-only, explicitly
forbids deployed use, and records that they are not generated or logged at
runtime. Every binary has an adjacent `MIT OR Apache-2.0` REUSE sidecar. No
fixture bytes or private-key contents were printed during this review.

## Snapshot and provenance

Initial and final read-only snapshots were identical:

- branch: `teremoq/c1-bounded-handshakes-bf87128`, with no tracking branch;
- HEAD/base: `bf87128affd316463e5dcc7599a45001f222b6de`;
- base tree: `d76319009e815fb8923e21fc8319e17a0aaf8174`;
- stage: empty;
- SHA-256 of `git status --short --untracked-files=all`:
  `fc674e7161c60e0aae278ea478f6570a9606d706aa81dad0c60e2384d5e8d3f9`.

The exact delta is the two requested Rust files plus the eight files under
`moq-native-ietf/tests/data/c1/`. Root/native/transport/relay manifests,
`Cargo.lock`, transport setup, license texts, Git index/config/refs and remotes
are unchanged.

Binding inputs and corrected anchors matched:

- previous TP-SEC-PKI review:
  `d036859d5271c22f1b155fda2160ed21887db181db90792e96436da6c6d7ae34`;
- owner rereview:
  `8fe7ae3ede22f475a125eece900ddea7d93abe2955d179b7a16fe3064dd98ab6`;
- `quic.rs`:
  `b0c8dfb3e4963365a3a27f52a84d2fc54292cfc5a056a817a5a0d0a4f38b3723`;
- `quic_c1_tests.rs`:
  `0366d05cd35627bf160499db9146b45cac106d41d746e16fd16cfabdf4c262c2`.

## Validation evidence

Rust gates used
`teremoq-step7-lab:rust-1.93-full@sha256:ba076cf0a26aa41efdd2f0f80687ef97009d1526680751456c19cc944dff1d0b`
with network disabled, source mounted read-only, ephemeral target storage and
the lockfile enforced:

| Command | Result |
| --- | --- |
| `rustc --version` | `rustc 1.93.0 (254b59607 2026-01-19)` |
| `cargo check --locked --offline -p moq-native-ietf` | PASS |
| `cargo test --locked --offline -p moq-native-ietf c1_` | PASS: 25 passed, 0 failed, 1 filtered |
| `cargo test --locked --offline -p moq-native-ietf` | PASS: 26/26 unit tests and zero doctest failures |
| `cargo clippy --locked --offline --no-deps -p moq-native-ietf --tests -- -D warnings` | PASS |
| Rustfmt 1.93 focal `--check` on both C1 Rust files | PASS |
| `cargo check --locked --offline -p moq-transport --tests` | `BLOCKED_BY_BASELINE_E0308`: unchanged `moq-transport/src/serve/tracks.rs:501`, expected `TrackName`, found `&str` |
| `git diff --check`; `git diff --cached --check`; no-index checks for all nine new files | PASS; stage empty |
| exact path inventory and protected-file comparisons to HEAD | PASS |
| `sha256sum -c moq-native-ietf/tests/data/c1/SHA256SUMS` and independent cert/key public-key comparison | PASS |
| REUSE 5.1.1, image `fsfe/reuse:5.1.1@sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da` | PASS: 196/196, Apache-2.0 and MIT |
| Gitleaks 8.30.1, image `zricethezav/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f`, `--no-git --redact=100` | PASS: approximately 110.8 KB, zero findings |

One preliminary short-name invocation incorrectly combined a test-name filter
with `--exact` and selected zero tests; it is not counted as evidence. A full
`cargo test -p moq-transport` attempt was interrupted after prolonged
compilation during prior host resource contention and likewise supplies no
result. It was not repeated. The narrower independent `cargo check
--locked --offline -p moq-transport --tests` completed and reproduced the exact
unchanged E0308 above.

## Residual risks and scope gates

- **WR-03 remains `BLOCKED_BY_BASELINE_E0308`.** It is neither approved nor
  described as non-constructible. The failure is in unchanged transport test
  code and prevents a green transport test gate until the baseline is repaired
  in its own authorized scope.
- The source-compatible `Endpoint::new` remains intentionally unbounded. Product
  integration must select `new_bounded` or `new_bounded_with_admission`; this
  review does not claim that legacy callers inherit C1 automatically.
- This approval is only permission for the Master to consider a local C1
  commit. It does not approve C2, packaging, advisories, release, push or any
  publication.

## Verdict

APPROVE FOR LOCAL COMMIT
