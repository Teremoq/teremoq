<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# C1 local review: bounded native handshake admission

Status: **LOCAL ONLY / NOT COMMITTED / NOT PUSHED**

Snapshot time: `2026-08-27T22:35:24Z`.

Owner: `TP-RUST-DIST`. Binding test-plan reviewer: `TP-PLATFORM-CHAOS`.
This implementation still requires formal reviewer and Master acceptance. It does
not implement C2, provide a product capacity claim, establish DoS resistance, or
make the relay production-ready.

## Findings

1. **Medium — five matrix cases remain intentionally unproven.** Exact
   mid-TLS cancellation, simultaneous deadline/success, simultaneous
   cancellation/error, the private QUINN pre-admission queue occupancy, and an
   end-to-end Objects regression cannot be made deterministic with the fixed
   public API and authorized hooks. They are recorded as `NOT-CONSTRUCTIBLE`
   below, with conservative alternatives. No UDP approximation or invented TLS
   stall was used.
2. **Medium — the existing `moq-transport` package test does not compile at the
   approved baseline.** Rust 1.93.0 reports the already documented E0308 at
   `moq-transport/src/serve/tracks.rs:501`: expected `TrackName`, found `&str`.
   C1 does not modify that file or crate. The focal draft-16 setup regression
   nevertheless passes through both bounded raw QUIC and WebTransport sessions.
3. **Low — REUSE must exclude generated Cargo output.** A direct lint included
   ignored `target/` artifacts and correctly failed on generated third-party
   files. An attempted temporary cross-filesystem move exhausted the small
   `/tmp` filesystem; the partial temporary copy was removed, `target/` remained
   present, and source/status hashes were unchanged. The corrected read-only
   source snapshot excluding `.git` and `target` passes REUSE 5.1.1 with
   196/196 files covered.

No high-severity implementation finding is open in the locally exercised C1
surface. This is not a review approval.

## Immutable base and isolation

- Worktree: `/home/jimbomilk/moq-rs-teremoq-c1-work`.
- Local branch: `teremoq/c1-bounded-handshakes-bf87128`.
- Base commit: `bf87128affd316463e5dcc7599a45001f222b6de`.
- Base tree: `d76319009e815fb8923e21fc8319e17a0aaf8174`.
- Tracking branch: none.
- Protected I1/I2 worktree was not edited.
- Remote verification after the implementation found only
  `refs/heads/teremoq/baseline-draft16-bf87128` at the approved base commit; no
  tag or C1 ref exists remotely.

## Final additive API

All symbols are in `moq-native-ietf::quic`:

- `ServerAdmissionConfig::new(max_buffered_incoming,
  max_pending_handshakes, handshake_timeout, capacity_policy)` validates two
  non-zero limits, a non-zero duration, and monotonic `checked_add` capacity.
- `HandshakeCapacityPolicy::{Refuse, Retry}` makes overload disposition
  explicit.
- `HandshakeAdmission::new` creates a controller local to one Server;
  `HandshakeAdmission::with_observer` adds a synchronous, backend-neutral,
  low-cardinality event callback.
- `Endpoint::new_bounded` creates the default per-Server controller.
- `Endpoint::new_bounded_with_admission` shares capacity only when the caller
  explicitly passes the same controller and rejects a limit mismatch.
- `Server::admission_mode` distinguishes `LegacyUnbounded` from `Bounded`.
- `Server::admission_snapshot` reports schema version 1, controller limit,
  pending phases, fixed counters, per-endpoint `max_buffered_incoming`, QUINN
  byte caps, and the reliable local `FuturesUnordered` length.

`Endpoint::new` and `Server::accept` retain their original signature and
unbounded legacy behavior. No public struct literal changed. Rust does not
promise a stable binary ABI; the source-compatible additive surface is a minor
API extension.

The bounded constructor explicitly applies:

- `quinn::ServerConfig::max_incoming(max_buffered_incoming)`;
- per-Incoming buffered cap `10 MiB`; and
- total Incoming buffered cap `100 MiB`.

The latter two are recorded separately and are explicitly applied rather than
inferred from a QUINN default.

## Ordering, ownership and terminal accounting

The implemented order is:

```text
Endpoint::accept() -> quinn::Incoming
  -> try_acquire_owned()
     -> unavailable: synchronous refuse or legal Retry; no await/spawn/push
     -> available: calculate one absolute deadline
        -> push exactly one owned accept future
        -> accept/accept_with -> TLS/ALPN -> conn.await
        -> H3 SETTINGS/WebTransport CONNECT when selected
        -> terminal accounting and release C1 permit
        -> return established native session
```

The private, non-clonable guard owns `OwnedSemaphorePermit`. `Drop` records
`Cancelled`; consuming `finish` records exactly one of `Completed`,
`TransportError`, or `Timeout`. The permit is released before the established
session is returned and is never retained for MoQT setup or session lifetime.
The pending gauge is derived from `limit - available_permits`, avoiding a
separate decrement path and underflow.

Cancelling only the outer `Server::accept` poll leaves its internally owned
future and permit intact. Dropping `Server` drops the collection, emits one
cancel terminal per owned phase, and returns all permits. Failed
`Incoming::retry()` recovers the value with `RetryError::into_incoming()` and
explicitly refuses it.

Production events contain only `schema_version=1` and a closed enum. Snapshots
contain counts/caps only. No IP, CID, SNI, path, namespace, certificate,
identity, peer error text, or payload was added to logs, labels, events, or
metrics. Test hooks are private under `cfg(test)` and carry only fixed stage
enums.

## Exact delta

The local snapshot contains one tracked modification and nine untracked files:

- `moq-native-ietf/src/quic.rs` — modified;
- `moq-native-ietf/src/quic_c1_tests.rs` — new;
- `moq-native-ietf/tests/data/c1/README.md` — new;
- `moq-native-ietf/tests/data/c1/SHA256SUMS` — new;
- `moq-native-ietf/tests/data/c1/ca.cert.der` and `.license` — new;
- `moq-native-ietf/tests/data/c1/server.cert.der` and `.license` — new; and
- `moq-native-ietf/tests/data/c1/server.key.der` and `.license` — new.

The three DER fixtures are byte-identical copies of the already reviewed I1
synthetic public fixtures. Their README warns that the private key is public,
test-only, non-production, and must never be reused. No certificate is generated
at runtime.

Final SHA-256 inventory:

| Path | SHA-256 |
| --- | --- |
| `moq-native-ietf/src/quic.rs` | `45d11ce77ea0e90e6480a48fdc3e5e2556500139985d20761f7fb7879df91172` |
| `moq-native-ietf/src/quic_c1_tests.rs` | `c182b102c91bbec1cf4a8376b822836b1672bc2f07b465d6372d29a741a691d0` |
| `tests/data/c1/README.md` | `717d3219aa203034fde416b6e17f291e21ab9344a15e258a92aaaf3812a14e10` |
| `tests/data/c1/SHA256SUMS` | `ba0f134515bdca4413dc9658d4016343a2180fd6c8f624e7e1b779f013696d64` |
| `tests/data/c1/ca.cert.der` | `ea33add88bed4676c51baa4f8da9df33d04e99cecf7d0846a756e23b0f66461b` |
| `tests/data/c1/server.cert.der` | `053a80b61f971f0601d83305ec6139fbcd7ed2f78c541078ac6e68a7e6da16bc` |
| `tests/data/c1/server.key.der` | `1d02d7ec66886fc2bb2cc3104851e1c182d7980e946d8df2e8f0f3ae33c30436` |
| each DER `.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |

`Cargo.lock`, every relevant `Cargo.toml`, `moq-transport`,
`moq-relay-ietf`, license texts, features, ALPN, draft-16 encoding, and Objects
source are byte-identical to the base. No dependency, feature, `unsafe`, wire
encoding, protocol parser, relay state, C2 state, or second transport was added.

## Test matrix

`PASS` means the local snapshot has deterministic evidence. `NOT-CONSTRUCTIBLE`
means the exact adversarial observation is unavailable with the fixed API; the
row does not count as passed.

| ID | State | Evidence or conservative alternative |
| --- | --- | --- |
| C1-01 ordering | PASS | `c1_stage_order_uses_incoming_before_permit_and_covers_connect` observes `incoming_received -> permit_acquired -> accept_started` on real raw and WebTransport peers. |
| C1-02 N/N+1 Refuse | PASS | `c1_n_plus_one_is_refused_without_pending_future_and_capacity_recovers`: N=2, pending remains 2, third refused before release, admitted remains 2. |
| C1-03 recovery after cancellation | PASS | `c1_cancelled_phase_releases_capacity_for_a_new_real_incoming` cancels one guarded real Incoming, admits a new real Incoming while the second remains occupied, and ends at zero. |
| C1-04 raw success | PASS | Bounded raw QUIC returns `RawQuic`, one completed terminal, pending zero while both sessions remain live. |
| C1-05 WebTransport success | PASS | Real H3/CONNECT reaches `webtransport_connect_waiting`, completes once, and releases C1. |
| C1-06 TLS/crypto error | PASS | Official rustls verifier with an empty trust store rejects the synthetic server; server records exactly one `TransportError`, no session, pending zero. |
| C1-07 pre-transport timeout | PASS | Absolute timeout wraps a deterministic `accept_started` barrier; exactly one timeout and permit recovery. |
| C1-08 CONNECT timeout | PASS | Real WebTransport reaches CONNECT waiting, remains blocked inside the same absolute deadline, then records timeout without completed. |
| C1-09 cancel every stage | NOT-CONSTRUCTIBLE | Server-drop subtests pass at `accept_started`, post-transport, and CONNECT waiting, but QUINN 0.11 exposes no stable public pause in the middle of TLS. Conservative alternative: keep the tested surrounding RAII boundaries and add a QUINN-owned packet seam only if upstream exposes one; do not label a synthetic stall TLS. |
| C1-10 cancel outer accept | PASS | Dropping only the polled `Server::accept` future leaves pending=1/no terminal; polling again completes the same owned phase. |
| C1-11 drop Server | PASS | N=2 blocked phases produce exactly two cancelled terminals and pending zero on Server drop. |
| C1-12 controller lifetime | PASS | Weak-Arc test proves external and first Server drops do not revoke shared capacity and the final Server drop leaves no cycle. |
| C1-13 Retry legal | PASS | Two real Incoming attempts from one client: capacity sends Retry on `may_retry=true`; after release, the token-bearing Incoming has `may_retry=false` and completes with no refuse. |
| C1-14 Retry illegal | PASS | Saturated token-bearing retry is counted not-applicable and explicitly refused; no retry loop or implicit drop. |
| C1-15 deadline/success race | NOT-CONSTRUCTIBLE | Stable public Tokio/QUINN APIs do not make both completion and the absolute deadline deterministically ready in one poll. Conservative alternative: retain consuming terminal guard and add a paused-clock seam in a separately approved test-only change. |
| C1-16 cancel/error race | NOT-CONSTRUCTIBLE | A deterministic simultaneous QUINN transport error and collection drop requires error injection outside the authorized stage hooks. Conservative alternative: preserve single-owner guard; existing independent error/drop tests each end with one terminal and zero pending. |
| C1-17 burst | PASS | Real QUINN burst N=2/M=32: pending never exceeds 2, 30 refusals occur before release, exactly two sessions succeed, final gauges zero. |
| C1-18 qlog/accept_with | PASS | Temporary qlog uses the `accept_with` path and produces the same single completed terminal and zero pending; cleanup is RAII. |
| C1-19 metrics/redaction | PASS | Closed schema-1 enums and allowlisted scalar snapshot fields cover admit/refuse/retry/not-applicable/completed/error/timeout/cancelled; Gitleaks and focal source scan find no peer material. |
| C1-20 QUINN queue cap | NOT-CONSTRUCTIBLE | Code and snapshot prove `max_incoming(2)` plus both explicit byte caps are applied, but QUINN exposes neither queue occupancy nor a public deterministic Initial-receipt barrier. Conservative alternative: inspect setter structurally and defer black-box queue depth to an approved QUINN socket-control harness; raw UDP is prohibited. |
| C1-ME-01 default local | PASS | Two separate controllers each reach pending=1 concurrently and complete independently. |
| C1-ME-02 shared explicit | PASS | One explicit shared N=1 controller lets A occupy capacity and immediately refuses B, then returns to zero. |
| C1-ME-03 no C2 retention | PASS | Raw and WebTransport tests keep established sessions alive with all C1 permits available; a later peer is admitted. |
| C1-ME-04 no relay state | PASS | Delta and test dependency closure remain inside `moq-native-ietf`; no Relay, Producer, Consumer, namespace, or C2 state is constructed. |
| C1-WR-01 both ALPNs | PASS | Bounded and legacy real peers pass on `h3`/WebTransport and `moqt-16`/raw QUIC. |
| C1-WR-02 draft-16 setup | PASS | `c1_moqt_setup_begins_only_after_c1_capacity_is_released` completes existing CLIENT_SETUP/SERVER_SETUP on both routes after pending reaches zero; `Version::DRAFT_16` remains `0xff000010`. |
| C1-WR-03 Objects | NOT-CONSTRUCTIBLE | The current baseline `moq-transport` test target stops at its unrelated E0308 before the existing Objects suite can run. Conservative alternative: after the owning baseline fix, run existing multi-Object/Subgroup regressions over this bounded acceptor without altering C1 or wire. |
| C1-WR-04 legacy | PASS | Existing constructor/call shape compiles; real legacy raw and WebTransport sessions retain behavior and report `LegacyUnbounded`. |

## Commands and results

Toolchain was the official Rust 1.93.0 image fixed at
`sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57`.
`clippy` and `rustfmt` were installed only inside the existing ephemeral
container. No host-global tool was installed.

| Command/gate | Result |
| --- | --- |
| `cargo check --locked -p moq-native-ietf` | PASS |
| `cargo test --locked -p moq-native-ietf c1_` | PASS, 23 C1 tests, greater than zero |
| `cargo test --locked -p moq-native-ietf` | PASS, 24/24 unit tests; 0 doctests |
| `cargo clippy --locked --no-deps -p moq-native-ietf --tests -- -D warnings` | PASS |
| Rustfmt 1.93 focal over the two C1 Rust files | PASS |
| `cargo test --locked -p moq-transport` | BASELINE BLOCKER, E0308 at `serve/tracks.rs:501`; no C1 delta in that crate |
| `git diff --check`; cached check | PASS; index empty |
| no-index whitespace checks | PASS for all nine untracked files; exit 1 only denoted content |
| manifests/lock/relay/transport/licenses comparison | PASS, byte-identical to `HEAD` |
| REUSE 5.1.1 image `fsfe/reuse@sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da` | PASS on source snapshot excluding `.git`/`target`: 196/196, MIT and Apache-2.0 |
| Gitleaks 8.30.1 image `zricethezav/gitleaks@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f` | PASS on focal crate with DER fixtures, `--redact=100`, zero findings |
| public derivative verifier | PASS; public independent repository, exact baseline commit/tree, controls intact |
| `git ls-remote --heads --tags origin` | PASS; exactly the approved baseline branch, no tags |
| branch/tracking/stage | PASS; exact local branch, no upstream, empty index |

The remote was only read. There was no fetch, commit, push, tag, release, PR,
issue, Discussion, settings change, or communication. C1 remains an unstaged
local review snapshot.

## Reviewer gate

The Master should now request formal `TP-PLATFORM-CHAOS` review of this exact
snapshot, with particular attention to the five `NOT-CONSTRUCTIBLE` rows and to
whether the explicit 10 MiB/100 MiB QUINN buffer caps are the desired policy.
The next authorization must be either targeted changes or a local C1 commit.
It must not authorize C2 or integration implicitly.
