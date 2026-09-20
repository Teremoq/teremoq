<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# C1 local correction for formal rereview

Status: **READY FOR FORMAL REREVIEW — C1-R04 CORRECTED**

Snapshot time: `2026-08-28T00:28:43Z`.

Owner: `TP-RUST-DIST`. Required rereviewers: `TP-SEC-PKI` and
`TP-PLATFORM-CHAOS`.

This correction responds to the binding reviews:

- `c1-tp-sec-pki-review-2026-08.md`, SHA-256
  `d036859d5271c22f1b155fda2160ed21887db181db90792e96436da6c6d7ae34`;
- `c1-tp-platform-chaos-review-2026-08.md`, SHA-256
  `5f21e69920449c05c6be62e967841d8f12d996a2342111fcb298b733f3321ed5`;
  and
- the unchanged supply-chain approval
  `c1-tp-oss-sc-review-2026-08.md`, SHA-256
  `3ee4bb9e6c52d6d1895fe7704f7d5bf4c244db4956440eac7e6441d4baa5a3b6`.

It also responds to the subsequent `TP-PLATFORM-CHAOS` rereview
`c1-tp-platform-chaos-rereview-2026-08.md`, SHA-256
`4ea32c55223e4e9d9f1aa697ca9f63e37fd2561b3fb568e66298bdcf858392c2`,
which kept C1-R04 open for the unbounded paired draft-16 setup wait.

The formal reviews and `c1-local-review-2026-08.md` remain unchanged historical
evidence. This document does not supersede either formal verdict; it presents a
new local snapshot for independent rereview.

## Findings

1. **Medium, inherited blocker — C1-WR-03 remains unapproved.** The exact
   baseline still fails the `moq-transport` library-test build with E0308 at
   `moq-transport/src/serve/tracks.rs:501` (`TrackName` versus `&str`). C1 does
   not modify that crate. The row is now classified
   `BLOCKED_BY_BASELINE_E0308`, not `NOT-CONSTRUCTIBLE`.
2. **Medium, residual observability limits — four exact cases remain outside
   the fixed public seams.** Mid-TLS pause, simultaneous deadline/success,
   simultaneous cancellation/error, and live QUINN incoming-queue occupancy
   remain unobservable or unconstructible with the pinned APIs and authorized
   hooks. Their conservative evidence remains explicit below; none is called a
   pass.
3. **High review findings corrected locally, not yet approved.** The public
   synchronous observer and events are absent, all public paths reaching
   `Semaphore::new` reject values above `Semaphore::MAX_PERMITS`, cancellation
   releases capacity before publishing its terminal counter, and every
   formerly unbounded logical wait uses an absolute monotonic watchdog. Formal
   rereview is still required before any commit.
4. **Inherited publication blockers remain.** The byte-identical lockfile and
   lack of a completed publication gate remain governed by the accepted
   supply-chain review. This correction neither remediates RustSec findings nor
   makes C1 publication-ready.

No C2, product-capacity, comprehensive DoS-resistance, relay-readiness, or
commercial-readiness claim follows from this local result.

## Immutable base and isolation

- Worktree: `/home/jimbomilk/moq-rs-teremoq-c1-work`.
- Local branch: `teremoq/c1-bounded-handshakes-bf87128`.
- Base/HEAD: `bf87128affd316463e5dcc7599a45001f222b6de`.
- Base tree: `d76319009e815fb8923e21fc8319e17a0aaf8174`.
- Snapshot status SHA-256 from `git status --porcelain=v1 -uall`:
  `fc674e7161c60e0aae278ea478f6570a9606d706aa81dad0c60e2384d5e8d3f9`.
- Tracking branch: none. Stage: empty.
- Cached `origin` refs remain baseline-only:
  `refs/remotes/origin/teremoq/baseline-draft16-bf87128` at the exact base.
  No network query or remote mutation was performed during this correction.
- I1, I2, Q, other worktrees, and their local commits were not edited.

## Corrections applied

### Observer removal

`HandshakeAdmissionObserver`, `HandshakeAdmissionEvent`,
`HandshakeAdmissionEventKind`, `with_observer`, the observer field, and every
synchronous emission site were removed. Production observability is limited to
the existing low-cardinality atomic counters and `schema_version=1` snapshots.
No replacement callback, queue, channel, task, spawn, backend, or dependency was
introduced. The existing stage channel remains private under `cfg(test)` only.

### Fallible semaphore boundary

The additive public `HandshakeAdmissionConfigError` has fixed, non-sensitive
variants for zero timeout, out-of-range monotonic timeout, and an excessive
pending-handshake count. Both `ServerAdmissionConfig::new` and
`HandshakeAdmission::new` validate
`max_pending_handshakes <= tokio::sync::Semaphore::MAX_PERMITS` before any
`Semaphore::new`. `HandshakeAdmission::new` is now fallible, and
`Endpoint::new_bounded` propagates that typed source error through its existing
`anyhow::Result` boundary.

The boundary test accepts exactly `MAX_PERMITS`, rejects `MAX_PERMITS + 1` from
both public constructors without panic, and constructs the otherwise-private
invalid server configuration in the same-module test to prove that
`Endpoint::new_bounded` returns the downcastable typed error rather than
reaching Tokio's panic.

### RAII and observable ordering

`HandshakePermitGuard::drop` now marks the terminal, takes and drops its
`OwnedSemaphorePermit`, and only then increments `cancelled`. Completed,
transport-error, timeout, and cancellation counters use release stores;
snapshots acquire terminal counters before reading available permits. A
cross-thread test observes `cancelled=1` with `pending=0`, immediately reacquires
the only permit, drops it, and observes exactly one additional cancellation and
a final zero gauge.

### Absolute test watchdogs

`next_stage` receives one absolute `tokio::time::Instant` and reuses it across
unexpected stages. Event helpers and event-driven tests were removed. The four
counter loops use a shared `wait_for_snapshot` helper with one absolute deadline
per logical wait. The three `Server::accept`/stage select loops are wrapped by a
single absolute `timeout_at`. No sleep, per-event timeout reset, timing success
threshold, raw-UDP substitute, or unbounded wait remains in C1 tests.

The C1-R04 correction additionally wraps the whole paired draft-16
`Session::accept`/`Session::connect` `tokio::join!` in one
`timeout_at(watchdog_deadline(), async { ... })`. Both futures remain polled
simultaneously; the deadline is calculated once for that logical wait and is
not restarted per side or setup message. Existing capacity and draft-16
success assertions are unchanged.

## Exact delta and hashes

The permitted ten-path inventory is unchanged: one modified production file,
one new test module, and the same eight fixture/provenance files.

| State | Path | SHA-256 |
| --- | --- | --- |
| modified | `moq-native-ietf/src/quic.rs` | `b0c8dfb3e4963365a3a27f52a84d2fc54292cfc5a056a817a5a0d0a4f38b3723` |
| new | `moq-native-ietf/src/quic_c1_tests.rs` | `610d8430315460db1652d99067002231d7ca4f2eaa48e8de2221966fa2cee8a9` |
| new, unchanged | `moq-native-ietf/tests/data/c1/README.md` | `717d3219aa203034fde416b6e17f291e21ab9344a15e258a92aaaf3812a14e10` |
| new, unchanged | `moq-native-ietf/tests/data/c1/SHA256SUMS` | `ba0f134515bdca4413dc9658d4016343a2180fd6c8f624e7e1b779f013696d64` |
| new, unchanged | `moq-native-ietf/tests/data/c1/ca.cert.der` | `ea33add88bed4676c51baa4f8da9df33d04e99cecf7d0846a756e23b0f66461b` |
| new, unchanged | `moq-native-ietf/tests/data/c1/ca.cert.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| new, unchanged | `moq-native-ietf/tests/data/c1/server.cert.der` | `053a80b61f971f0601d83305ec6139fbcd7ed2f78c541078ac6e68a7e6da16bc` |
| new, unchanged | `moq-native-ietf/tests/data/c1/server.cert.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| new, unchanged | `moq-native-ietf/tests/data/c1/server.key.der` | `1d02d7ec66886fc2bb2cc3104851e1c182d7980e946d8df2e8f0f3ae33c30436` |
| new, unchanged | `moq-native-ietf/tests/data/c1/server.key.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |

`quic.rs` is 541 insertions and 7 deletions against the immutable baseline. The
fixture hashes exactly match both prior formal reviews. The following protected
hashes remain byte-identical:

- `Cargo.lock`:
  `b518a2fa4a6d7a0ffe0bdfe4b530f05196ac0f5e6f7ef51da9e5a83c0b0561c0`;
- root `Cargo.toml`:
  `6665802c9ad7192d61521a62877454e25bde7072c611e617780a932f583aa48f`;
- `moq-native-ietf/Cargo.toml`:
  `3180121a89c58071718236a408f36c1c87757d6f9ff81e899fb3b5814c8d4c8e`;
  and
- `moq-transport/src/setup/mod.rs`:
  `c49d71dcacd5e3f5eef7a673e11b9058d3fd701e1fb83331a737098894a2d750`.

All manifests, the lockfile, `moq-transport`, `moq-relay-ietf`, license texts,
features, draft-16/ALPN setup, and Objects source have zero delta from the base.

## Matrix and gaps

| ID | State | Current evidence |
| --- | --- | --- |
| C1-01 | PASS | Real raw/WebTransport stages preserve Incoming before permit before accept. |
| C1-02 | PASS | Real N=2/N+1 refusal is immediate; watchdog is absolute and recovery succeeds. |
| C1-03 | PASS | Cancellation releases capacity before the terminal snapshot; real recovery and cross-thread reacquisition pass. |
| C1-04 | PASS | Bounded raw QUIC completes once and releases before session lifetime. |
| C1-05 | PASS | Bounded WebTransport covers H3 SETTINGS/CONNECT and releases once. |
| C1-06 | PASS | Official rustls verification failure records one transport error and zero pending. |
| C1-07 | PASS | One production absolute deadline times out at the pre-transport seam. |
| C1-08 | PASS | The same production deadline covers WebTransport CONNECT. |
| C1-09 | UNOBSERVABLE_WITH_PINNED_PUBLIC_API | Exact mid-TLS pause is unavailable; surrounding real-QUINN RAII stages pass and no synthetic stall is called TLS. |
| C1-10 | PASS | Cancelling only the external `accept` poll keeps the Server-owned future and permit alive. |
| C1-11 | PASS | Server drop cancels N owned phases exactly once and leaves zero pending. |
| C1-12 | PASS | Shared-controller weak ownership proves no Arc cycle. |
| C1-13 | PASS | Legal Retry and validated follow-up use real QUINN Incoming ownership. |
| C1-14 | PASS | Token-bearing overload is retry-not-applicable and explicitly refused. |
| C1-15 | UNCONSTRUCTIBLE_WITH_AUTHORIZED_HOOKS | No deterministic same-poll deadline/success seam; consuming terminal ownership is retained. |
| C1-16 | UNCONSTRUCTIBLE_WITH_AUTHORIZED_HOOKS | No deterministic simultaneous QUINN error/drop seam; independent terminals remain exactly once. |
| C1-17 | PASS | Real N=2/M=32 burst never exceeds N and rejects M-N under an absolute watchdog. |
| C1-18 | PASS | qlog `accept_with` path follows the same lifecycle and releases capacity. |
| C1-19 | PASS | Atomic schema-1 snapshots contain only counters/caps; public callbacks/events are absent; scans are clean. |
| C1-20 | UNOBSERVABLE_WITH_QUINN_0_11_X | Exact setters/caps are applied, but QUINN does not expose live incoming-queue occupancy. |
| C1-ME-01 | PASS | Separate controllers remain per-endpoint. |
| C1-ME-02 | PASS | Shared capacity occurs only with the explicitly shared controller. |
| C1-ME-03 | PASS | Permits are free while established sessions remain live; C1 does not become C2. |
| C1-ME-04 | PASS | No relay/session/namespace state or crate delta was added. |
| C1-WR-01 | PASS | Raw QUIC and WebTransport legacy/bounded routes pass with unchanged ALPNs. |
| C1-WR-02 | PASS | Existing draft-16 setup succeeds only after the C1 permit is released; the paired accept/connect wait now has one absolute watchdog. |
| C1-WR-03 | BLOCKED_BY_BASELINE_E0308 | `moq-transport` lib test fails before Objects execution at unchanged `serve/tracks.rs:501`; explicitly not approved. |
| C1-WR-04 | PASS | Legacy constructor, accept signature, raw QUIC, and WebTransport behavior remain source-compatible and unbounded. |

## Toolchain and validation

Rust gates used the official Rust 1.93.0 image fixed at
`sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57`.
Observed versions were `rustc 1.93.0 (254b59607)`, Cargo
`1.93.0 (083ac5135)`, and rustfmt `1.8.0-stable (254b59607d)`.
All Cargo commands used `--locked --offline`.

| Gate | Result |
| --- | --- |
| `cargo check -p moq-native-ietf` | PASS |
| focused excessive-limit test | PASS, one test; MAX accepted and MAX+1 rejected without panic, including endpoint propagation |
| `cargo test -p moq-native-ietf c1_` under external 900-second watchdog | PASS, 25 passed, 0 failed, 1 filtered; 0.28s test execution |
| `cargo test -p moq-native-ietf` under external 900-second watchdog | PASS, 26/26 unit tests and 0 doctest failures; 0.27s unit-test execution |
| `cargo clippy --no-deps -p moq-native-ietf --tests -- -D warnings` | PASS |
| Rustfmt focal `--check` on both C1 Rust files | PASS |
| `cargo test -p moq-transport` | `BLOCKED_BY_BASELINE_E0308` at unchanged `serve/tracks.rs:501` |
| `git diff --check`; `git diff --cached --check` | PASS; index empty |
| `git diff --no-index --check /dev/null <file>` | PASS for all nine new files; exit 1 denoted content and emitted no whitespace diagnostic |
| exact ten-path inventory and SHA-256 | PASS |
| manifests/lock/transport/relay/license comparison to base | PASS, byte-identical |
| REUSE 5.1.1, GPL-3.0-or-later, image `fsfe/reuse:5.1.1@sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da` | PASS on the read-only source with generated `target/` hidden by an ephemeral tmpfs: 196/196, MIT and Apache-2.0 |
| Gitleaks 8.30.1, MIT, image `zricethezav/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f` | PASS on the focal crate including DER, `--no-git --redact=100`, about 111 KB, zero findings |

No secret, production identity, certificate content, peer address, CID, SNI,
path, namespace, error text, or product data was added to counters, snapshots,
logs, metrics, tests, or this report. The DER fixtures remain synthetic public
test material with their warning, provenance, checksums, and REUSE sidecars.

## C1-R04 targeted correction evidence

The formal rereview input had test-module SHA-256
`0366d05cd35627bf160499db9146b45cac106d41d746e16fd16cfabdf4c262c2`.
The sole C1-R04 source adjustment changes it to
`610d8430315460db1652d99067002231d7ca4f2eaa48e8de2221966fa2cee8a9`.
The production `quic.rs` hash remains
`b0c8dfb3e4963365a3a27f52a84d2fc54292cfc5a056a817a5a0d0a4f38b3723`,
and all eight fixture/provenance hashes remain exactly as listed above.

The status-path inventory SHA-256 remains
`fc674e7161c60e0aae278ea478f6570a9606d706aa81dad0c60e2384d5e8d3f9`
because no path was added or removed. HEAD/tree remain the immutable baseline,
the stage is empty, and the branch still has no tracking ref. `git diff
--check`, cached diff check, focal rustfmt, the 25-test C1 filter, and the full
26-test native package all passed. The no-index whitespace check for the
untracked test module returned the expected content exit 1 with no diagnostic.
No check, Clippy, transport test, or unrelated build was rerun for this targeted
correction; C1-WR-03 remains `BLOCKED_BY_BASELINE_E0308` exactly as the formal
rereview required.

## Rereview gate

The exact next action is formal `TP-SEC-PKI` and `TP-PLATFORM-CHAOS` rereview of
the ten-path snapshot and hashes above. A later Master decision may authorize a
local C1 commit or require targeted changes. It must not implicitly authorize
C2, integration, a product pin, push, publication, or any remote action.

**LOCAL ONLY / NOT COMMITTED / NOT PUSHED / NO REMOTE MUTATION / NO C2**
