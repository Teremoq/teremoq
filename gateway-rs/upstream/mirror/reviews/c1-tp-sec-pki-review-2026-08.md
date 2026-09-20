<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# C1 TP-SEC-PKI security review: bounded native handshakes

Status: **READ-ONLY SECURITY REVIEW / NO COMMIT / NO PUSH / NO REMOTE MUTATION**

Review date: `2026-08-28`.

Reviewer: `TP-SEC-PKI`. Code owner: `TP-RUST-DIST`.

This review is intentionally limited to exhaustion resistance, permit ownership,
trust boundaries, redaction and the test-only PKI fixtures. It does not duplicate
the complete functional review, authorize publication, or authorize C2.

## Findings

### HIGH — the synchronous observer can retain C1 capacity indefinitely and can abort the process

Locations: `moq-native-ietf/src/quic.rs:117`, `:180`, `:226-244`, `:278-315`,
`:842-865`.

`HandshakeAdmissionObserver` is an arbitrary public synchronous callback. On the
admission path, `try_admit` acquires the `OwnedSemaphorePermit` at line 236 and
calls the observer at line 243 before returning the guard, before inserting the
future, and before the absolute deadline is calculated at lines 848-849. A
blocking observer therefore holds scarce C1 capacity for an unbounded duration,
stops the single `Server::accept` poller, and runs outside the advertised
handshake deadline. Expensive QUIC/TLS work has not started yet, but the bounded
service can still be made permanently unavailable and the bounded QUINN queue can
fill behind it.

The cancellation path has a second ordering defect. `HandshakePermitGuard::drop`
increments `cancelled` and invokes the observer at lines 310-315 while
`self.permit` is still `Some`; Rust drops that field only after `drop` returns. A
blocked cancellation observer consequently prevents capacity recovery during
future cancellation or `Server` drop. The successful/error/timeout path does the
right thing at line 283 by taking and dropping the permit before notification,
but cancellation does not.

Panic behavior is also fail-open for process availability. `emit` has no panic
containment. A panic on `Admitted` unwinds while the local guard is live; its
destructor then emits `Cancelled` to the same callback. A callback that panics for
both events causes a second panic during unwinding and can abort the process. A
terminal callback panic occurs after permit release, but still escapes through
the accept task. There is no documented or enforced non-blocking/no-panic
contract and no independent failure accounting.

Required, verifiable correction for `TP-RUST-DIST`:

1. Remove arbitrary synchronous embedder code from the admission and destructor
   critical paths; the conservative solution is to retain the atomic snapshot
   and remove the callback. If event delivery remains required, use a strictly
   bounded, non-blocking delivery primitive with an explicit dropped-event
   policy; do not spawn an unbounded task per event.
2. In every cancellation destructor, mark the terminal state and
   `take`/drop the permit before counters or any notification. Capacity recovery
   must not depend on observer progress.
3. Demonstrate behavior with an independent test where notification is stalled
   after cancellation and another thread observes the permit already available.
   If callbacks remain, add subprocess-safe panic tests proving that neither an
   admission panic nor cancellation during unwind can abort the test process or
   strand capacity. Documentation alone is insufficient for a bounded admission
   API.

### MEDIUM — the tests neither exercise the observer failure boundary nor bound all waits

Locations: `moq-native-ietf/src/quic_c1_tests.rs:146-155`, `:387-395`,
`:440-517`, `:561-645`, `:780-785`, `:918-926`, `:1022-1029`.

The only observer used by the suite immediately sends to an unbounded test
channel. Cancellation and server-drop tests instead construct
`HandshakeAdmission::new`, so they cannot detect the release-after-callback bug
or either panic path. Passing counter assertions are therefore not independent
evidence for the observer/RAII boundary.

Four progress loops poll counters with `yield_now()` and no enclosing watchdog.
If refusal/Retry accounting regresses, the test process can wait forever instead
of failing. This contradicts the C1 plan's rule that every wait has a broad
watchdog and weakens CI evidence for immediate overload disposition.

Required correction: add the independent stalled/panicking observer coverage
above if that API remains, and wrap each polling loop in a finite watchdog whose
failure message contains only the expected fixed event/counter name. Do not use
sleep-based timing or print peer errors, certificates, addresses, CIDs or qlog
content.

## Controls independently confirmed

- The initial and final snapshots were identical: branch
  `teremoq/c1-bounded-handshakes-bf87128`, no tracking branch, HEAD
  `bf87128affd316463e5dcc7599a45001f222b6de`, tree
  `d76319009e815fb8923e21fc8319e17a0aaf8174`, empty stage, and status SHA-256
  `fc674e7161c60e0aae278ea478f6570a9606d706aa81dad0c60e2384d5e8d3f9`.
- The delta is exactly `moq-native-ietf/src/quic.rs`,
  `moq-native-ietf/src/quic_c1_tests.rs`, and the eight requested files under
  `moq-native-ietf/tests/data/c1/`. No manifest, lockfile, license text,
  `moq-transport`, `moq-relay-ietf`, Git metadata or remote ref changed.
- Production ordering is `Endpoint::accept` -> `Incoming` ->
  `try_acquire_owned` -> `accept`/`accept_with`. Lines 832-865 do no expensive
  QUIC/TLS accept work before the permit. The only pre-permit production work is
  receipt of `Incoming` and inexpensive `Arc` clones.
- Saturation takes no semaphore waiter and creates no future/task. Lines 882-905
  synchronously refuse or request Retry. QUINN 0.11.9's official source confirms
  that `retry(self)` returns ownership through `RetryError::into_incoming()` on
  failure; the implementation then explicitly refuses it. A token-bearing
  `Incoming` has `may_retry=false`, so the server does not create a Retry loop.
- Apart from the observer gap, one `timeout_at` at lines 916-934 covers
  `accept`/`accept_with`, TLS/ALPN, the established QUIC connection, H3 SETTINGS
  and WebTransport CONNECT. Successful, transport-error and timeout terminals
  release the permit before returning a session or notifying the observer.
- The bounded constructor applies QUINN's separate
  `max_incoming`, 10 MiB per-Incoming buffer cap and 100 MiB total Incoming buffer
  cap. These are configuration values, not a claimed observable queue gauge.
- Admission events carry only `schema_version=1` plus a closed enum. Snapshots
  carry only counts and caps. The C1 delta adds no IP, CID, SNI, path, identity,
  certificate, payload or peer-error string to observers, counters, labels,
  tracing, qlog or mlog. Existing legacy `ConnInfo` and qlog behavior is unchanged.
- The Retry, raw QUIC, WebTransport, qlog/`accept_with`, TLS error, timeout,
  cancellation, shared/local controller and draft-16 setup tests use real QUINN
  endpoints. The suite does not use arbitrary UDP or sleep-based success
  assertions.
- `Cargo.lock` remains at QUINN `0.11.9`, `quinn-proto 0.11.13`,
  `quinn-udp 0.5.14`, Tokio `1.48.0` and `web-transport-quinn 0.11.8`. No
  dependency, feature, `unsafe`, ALPN, draft, frame, Object, second transport or
  C2 state was added. The legacy constructor and `Server::accept` signature are
  source-compatible.

## Fixture review

The three DER files are byte-identical to the already public synthetic I1
fixtures. Their README labels the key public, test-only and forbidden for
deployment; tests include the files at compile time and do not generate or log
certificate material. Every binary has an adjacent `MIT OR Apache-2.0` REUSE
sidecar and `SHA256SUMS` verifies.

Public fixture SHA-256 values:

| File | SHA-256 |
| --- | --- |
| `ca.cert.der` | `ea33add88bed4676c51baa4f8da9df33d04e99cecf7d0846a756e23b0f66461b` |
| `server.cert.der` | `053a80b61f971f0601d83305ec6139fbcd7ed2f78c541078ac6e68a7e6da16bc` |
| `server.key.der` | `1d02d7ec66886fc2bb2cc3104851e1c182d7980e946d8df2e8f0f3ae33c30436` |

OpenSSL independently confirmed that the server certificate public key matches
the fixture private key, the SAN is limited to `localhost` and `127.0.0.1`, and
the synthetic certificate validity is `2026-08-26` through `2036-08-23`. This is
test provenance, not a production identity or PKI recommendation.

## Source hashes reviewed

| Path | SHA-256 |
| --- | --- |
| `moq-native-ietf/src/quic.rs` | `45d11ce77ea0e90e6480a48fdc3e5e2556500139985d20761f7fb7879df91172` |
| `moq-native-ietf/src/quic_c1_tests.rs` | `c182b102c91bbec1cf4a8376b822836b1672bc2f07b465d6372d29a741a691d0` |
| `moq-native-ietf/tests/data/c1/README.md` | `717d3219aa203034fde416b6e17f291e21ab9344a15e258a92aaaf3812a14e10` |
| `moq-native-ietf/tests/data/c1/SHA256SUMS` | `ba0f134515bdca4413dc9658d4016343a2180fd6c8f624e7e1b779f013696d64` |
| each DER `.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |

## Commands and results

Rust gates used the fixed local image
`teremoq-step7-lab:rust-1.93-full@sha256:ba076cf0a26aa41efdd2f0f80687ef97009d1526680751456c19cc944dff1d0b`
with the source mounted read-only, target on tmpfs, cached crates, and Cargo
offline. `rustc -Vv` reported `1.93.0 (254b59607 2026-01-19)`.

| Gate | Result |
| --- | --- |
| `cargo check --locked --offline -p moq-native-ietf` | PASS |
| `cargo test --locked --offline -p moq-native-ietf` | PASS: 24/24 unit tests, 0 doctests |
| `cargo clippy --locked --offline --no-deps -p moq-native-ietf --tests -- -D warnings` | PASS |
| Rustfmt 1.93 `--check` over both C1 Rust files | PASS |
| `git diff --check`, cached check and no-index checks for all untracked files | PASS; stage empty |
| exact changed-path allowlist and protected-file comparisons | PASS |
| `sha256sum -c moq-native-ietf/tests/data/c1/SHA256SUMS` | PASS: 3/3 |
| REUSE 5.1.1 at `sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da` | PASS: 196/196 files, Apache-2.0 and MIT |
| Gitleaks 8.30.1 at `sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f` over the focal crate including DER | PASS: zero findings, output redacted |
| OpenSSL DER metadata and cert/key public-key comparison | PASS |

Clippy and rustfmt were downloaded only inside a disposable container; nothing
was installed on the host. Two preliminary Rust invocations were not gates: the
first lacked the approved Cargo cache mount and failed offline on
`web-transport`, and the second used a non-executable target tmpfs and failed to
run a build script. The corrected read-only command above passed. An initial
REUSE snapshot copy also exhausted a 512 MiB tmpfs by copying ignored `target/`;
the corrected tar snapshot excluded `.git` and `target` before copying and
passed. All containers were removed and none of these setup failures changed the
source/status hash.

## Residual scope and risk

- QUINN's private pre-admission queue occupancy remains unobservable; source and
  configuration prove a cap, not its instantaneous depth or full flood behavior.
- Deterministic mid-TLS cancellation and simultaneous completion/deadline races
  remain outside the fixed public seam. Existing single-owner design is useful
  evidence but does not close the observer finding.
- The known baseline `moq-transport` E0308 and the full Objects gate were not
  reclassified or hidden; they are outside this security-focused delta and still
  require their owning baseline/package gate.
- C1 bounds pending native establishment only. It does not bound established
  sessions, prove production capacity or comprehensive DoS resistance, or make
  C2/identity/authorization complete.

## Veredicto

CHANGES REQUIRED

This verdict authorizes no commit, push, publication, remote change, C2 work or
product claim. The reviewed worktree remained read-only throughout this review.
