<!--
SPDX-FileCopyrightText: 2026 Teremoq contributors
SPDX-License-Identifier: Apache-2.0
-->

# C2 formal TP-PLATFORM-CHAOS review

Date: `2026-08-28`

Mode: **READ-ONLY SNAPSHOT REVIEW / NO SOURCE EDIT / NO COMMIT / NO PUSH / NO PUBLICATION**

## Findings first

### HIGH — cancellation can leave unbounded empty `RemoteManager` cache slots

`RemoteManager::get_or_connect` inserts a new empty slot after the immediate
outbound permit succeeds at `moq-relay-ietf/src/remote.rs:803-824`. It then
moves the permit into `Remote::connect` and awaits connection/setup at
`remote.rs:850-886`. The empty slot is removed only on the ordinary `Err`
continuation at `remote.rs:887-893`.

Dropping or cancelling that future while `Remote::connect` is pending skips
the continuation. RAII correctly releases and accounts the permit, but no
owner removes the still-current empty slot from `RemoteManager::remotes`.
Repeating this sequence with distinct cache keys can therefore grow the
`HashMap` while never holding more than the configured outbound permits.

This violates the C2 cancellation/no-residue contract and means the outbound
root limit does not actually bound the network-fed cache-key collection. The
existing OUT-03 setup-error test cannot detect the defect because ordinary
error return executes the cleanup continuation; no test cancels a pending
distinct-key setup and then asserts slot removal.

Required correction: give each newly inserted slot a cancellation-safe RAII
reservation that removes only the same current empty slot on every drop path,
or move setup into an owned lifecycle future with equivalent exact cleanup.
Add a deterministic regression that repeatedly cancels pending setup for
distinct keys, proves the map returns to its previous cardinality after every
cancellation, observes one terminal per permit, and admits the next root.

### MEDIUM — the now-executable formatting and Clippy gates fail

The requested stopped-container inspection found a valid local Rust 1.93.0
toolchain with rustfmt and Clippy. With the source mounted read-only and Docker
networking disabled:

- focal `rustfmt --edition 2021 --check` failed on C2 paths;
- `cargo fmt --all -- --check` exited `1`, including formatting differences in
  `src/lib.rs`, `src/relay.rs`, `src/relay_c2_tests.rs`, `src/remote.rs`,
  `src/session_admission.rs`, and `tests/c2_session_admission.rs`;
- `cargo clippy --locked --offline --no-deps -p moq-relay-ietf --tests --
  -D warnings` exited `101` with C2-attributable diagnostics:
  `clippy::large_enum_variant` at `src/relay.rs:722-726` and
  `clippy::too_many_arguments` at `src/relay.rs:1220-1229`.

The wider formatting command also reports pre-existing differences in
unchanged `moq-transport` tests, but the focal C2 formatting failure is
independently sufficient. The owner report's tooling blocker is resolved; the
actual gates are failures, not unavailable checks.

### MEDIUM — the C2 tests do not put every logical wait under one absolute watchdog

The binding plan requires one absolute watchdog per test and forbids helper
deadline resets. The current tests leave these gaps:

- OUT-03 awaits the N+1 `get_or_connect` directly at
  `moq-relay-ietf/src/remote.rs:472`; a regression that accidentally waits for
  capacity can hang CI rather than trip the watchdog.
- The same test directly awaits the internal map mutex at `remote.rs:478`.
- `c2_shutdown_owned_manager` creates a fresh deadline at
  `remote.rs:238-245`; OUT-03, OUT-04, and OUT-05 therefore reset their test
  budget during cleanup instead of reusing their original deadline.
- The cross-thread release-order test performs an unbounded native thread
  `join` at `src/session_admission.rs:583-591`.

All polling loops inspected are inside `timeout_at`, and there are no sleeps in
the new C2 test files. Those positives do not close the waits above.

Required correction: pass the original absolute deadline through every helper,
wrap the immediate-capacity call and cleanup in that deadline, avoid an
unbounded thread join, and add a source-level regression ensuring no C2 helper
creates a second deadline.

### MEDIUM — RACE-01, RACE-02, and SD-08 are state-order tests, not deterministic races

The accept-versus-shutdown case uses a real barrier and is valid. In contrast,
`c2_close_and_admit_race_is_linearized_in_both_orders` at
`src/session_admission.rs:610-643` and
`c2_terminal_and_shutdown_race_is_exactly_once_in_both_orders` at
`src/session_admission.rs:646-665` execute their operations sequentially on one
thread. They demonstrate the two serial states but do not create competing
futures/threads, a same-poll seam, or a barrier-controlled interleaving.

Consequently the owner matrix overstates coverage of RACE-01, RACE-02, and
SD-08. The implementation's non-cloneable guard and `Option::take` make double
release unlikely, but the binding matrix requires executable deterministic
race evidence rather than static confidence alone.

Required correction: run both barrier-controlled interleavings for
close/admit and terminal/cancel-shutdown, assert the terminal equation and
underflow-free gauges after each ordering, and keep every wait under the same
absolute watchdog.

### Baseline blocker — WR-03 remains separate and unchanged

`moq-transport/src/serve/tracks.rs` remains byte-identical with SHA-256
`a8303c94925707a0a257923725bf84e4ec730b07d6bb2330fda5329b632fe0b7`.
The inherited mismatch is still at line 501. It remains exactly
`BLOCKED_BY_BASELINE_E0308`; it is neither a C2 pass nor a reason for the C2
findings above.

## Verdict

**CHANGES REQUIRED**

This verdict applies only to the frozen local C2 snapshot. It does not
authorize a commit, C3, integration, push, publication, release, deployment,
or any product-readiness claim.

## Binding and snapshot identity

| Item | Independently observed value |
| --- | --- |
| Worktree | `/home/jimbomilk/moq-rs-teremoq-c2-work` |
| Branch | `teremoq/c2-session-shutdown-ee22a10` |
| HEAD/base | `ee22a1079783e374371e0705775978790ddd6471` |
| Tree | `232e449945e877b024f2fc4223f0d2eea124b39b` |
| Staging area | empty |
| Full status inventory SHA-256 | `41969b3ff7d7ebcaaf891137a17519a2097319642b6753db144a0b5a000db614` |
| Owner report SHA-256 | `33e3fb8949f5107a0c8044a0169d8bc72628e91fa5677a3200a187b139308ffa` |
| TP-PLATFORM-CHAOS plan SHA-256 | `550e52ec87cb4d1c10a76ca61d640723eb2fb36e7a3438914184ad30ed6cf1ab` |
| TP-SEC-PKI plan SHA-256 | `9d3ba88aa9d0299ef9efc99927e28dfa6d7d31fc8b09095eb0436be38f00aa18` |

The inventory hash was reproduced from
`git status --short --untracked-files=all`. The tracked diff is four modified
relay files; eleven untracked C2 files complete the exact 15-path snapshot.
`git diff --check` passed for tracked changes, and individual
`git diff --no-index --check` checks passed for every untracked path.

## Exact 15-path inventory

| Path | SHA-256 |
| --- | --- |
| `moq-relay-ietf/src/lib.rs` | `7221542f360df88d2eb552198ce1c9ca37f7380c5229d2ccc76a22041eb0f0bf` |
| `moq-relay-ietf/src/relay.rs` | `07b48b84ca57bab60ca8e0cce9096eac5bde6aa94a544cc4a96f9e4317356e6c` |
| `moq-relay-ietf/src/relay_c2_tests.rs` | `f76ea25d9be4379ddf04fa063bb3d0ed1d91f738ede76c45d3a4bec7c10f2238` |
| `moq-relay-ietf/src/remote.rs` | `9a012fc2e698864f3e5286d97461010840f236fc25c4373f4efffd1b4727b7d8` |
| `moq-relay-ietf/src/session_admission.rs` | `1bb5f79e24d52ada9fd402d14eca6bd6bb8a50276d90931b04f7d1e1959cfd3d` |
| `moq-relay-ietf/src/upstream_namespaces.rs` | `7033823b66d5e3e82c0e6afdf2e4062080b908ed11c0aedb4550bd2f7cd775b9` |
| `moq-relay-ietf/tests/c2_session_admission.rs` | `eab3296eed7b97ec3987259298d20cacafabd96c7c633f07b46f7f40ced760bc` |
| `moq-relay-ietf/tests/data/c2/README.md` | `285e4e178ecd6a7c5cffe5409107bc11bdf096bba9ebc014e805c0b991c1ae72` |
| `moq-relay-ietf/tests/data/c2/SHA256SUMS` | `ccc4d9cbcc23c31cfd12e2ef5d0a57e6d0901c243f7a732fc6eba20a7c82c8fd` |
| `moq-relay-ietf/tests/data/c2/ca.cert.pem` | `c439d7428d418762e090e1ce0fdda1524473daa66f052da251e120d78555dfbb` |
| `moq-relay-ietf/tests/data/c2/ca.cert.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-relay-ietf/tests/data/c2/server.cert.pem` | `76fe11a03423308533516c61c8e06f994746293313ef8961091de0e87cbd2b09` |
| `moq-relay-ietf/tests/data/c2/server.cert.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-relay-ietf/tests/data/c2/server.key.pem` | `607642c80b7ec6e365ef877e24c526ca546542fb5c330ae191891a212b67aa35` |
| `moq-relay-ietf/tests/data/c2/server.key.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |

Protected inputs remain byte-identical to C1: workspace `Cargo.toml`,
`Cargo.lock`, relay/native/transport manifests, `moq-native-ietf/src/quic.rs`,
draft-16 setup modules, and transport session code. No dependency, feature,
lockfile, native transport, wire, ALPN, TLS, or Objects change is present.

## Independent implementation and matrix review

| Gate | Result | Evidence |
| --- | --- | --- |
| Incoming session admission ordering | PASS | `relay.rs:890-943` resolves native accept, checks shutdown, performs one immediate `try_admit`, disposes overload, and only then marks/creates a root. |
| Requeue ordering | PASS | Overload disposition precedes requeue at `relay.rs:913-931`; admitted ownership precedes requeue at `relay.rs:943-977`. |
| One global inbound limit | PASS | One `SessionAdmission` is constructed in `Relay::new_bounded` and shared by all endpoint accepts. Real two-endpoint raw/WebTransport test passed. |
| N/N+1 and M=32 | PASS | Reused frozen binaries independently passed raw/WT N/N+1 and the M=32 burst without releasing N; high-water mark remains N. |
| N+1 pre-MoQT/state effects | PASS | Static ordering places metrics, future creation, setup, tagger, coordinator, Producer/Consumer, and namespace work after permit. M=32 observes zero tagger/coordinator calls. |
| No capacity waiter | PASS for admission primitive | Only `try_acquire_owned` is used in `SessionAdmission::try_admit`; no async semaphore acquisition or permit waiter was added. The OUT-03 test watchdog defect remains open. |
| MAX/MAX+1 | PASS | Both limits validate before `Semaphore::new`; `MAX_PERMITS` is accepted and `MAX+1` returns typed errors without panic. |
| Permit RAII and terminal equation | PASS for implemented guard | Private, non-cloneable guard owns one `OwnedSemaphorePermit`; `Option::take` releases gauges and capacity before the Release terminal publication. Existing equation tests pass. |
| Setup/run panic | PASS | Test-only one-shot hooks are private; setup and run panics are caught, return non-success, and release one permit. Both focal tests passed. |
| Close/setup-error/owner-drop recovery | PASS for covered paths | Real raw/WT setup-error and close tests plus owner abort passed. Remote setup-error retry passed. Pending Remote cancellation remains defective. |
| Deterministic races | PARTIAL | Accept/shutdown has a real barrier. Close/admit and terminal/shutdown tests are sequential and do not satisfy RACE-01/RACE-02/SD-08. |
| C1 composition | PASS for public evidence | Two retained public C1 controllers report pending zero and a quiescent terminal equation after C2 shutdown. Exact mid-TLS remains unavailable through the pinned public API. |
| Announce ownership | PASS for covered paths | Pending and established real announce sessions run concurrently with inbound accepts, consume outbound capacity, and terminate under bounded shutdown. |
| RemoteManager root bound | FAIL | Immediate outbound capacity and same-key deduplication exist, but cancellation can retain an empty distinct-key slot as described in the HIGH finding. |
| Remote/background task ownership | PASS with disclosed child gaps | Bounded Remote roots/cleanup use an owned runner; upstream pulls are owned by the runner. The only added `tokio::spawn` is the explicit legacy branch. Per-session child collections remain outside the root bound and are disclosed. |
| One shutdown deadline | PASS for source path | `run_bounded` computes one absolute deadline, stops accepts, cancels roots/controls, drains under one `timeout_at`, then force-drops owned collections before checking gauges. No post-deadline await exists. |
| Watchdog discipline | FAIL | Direct async wait, reset cleanup deadlines, and unbounded thread join remain. |
| Raw QUIC/WebTransport/draft-16 | PASS for covered transport setup | Real raw QUIC and WebTransport tests pass; protected ALPN/draft/native sources are unchanged. |
| Objects regression WR-03 | `BLOCKED_BY_BASELINE_E0308` | Exact unchanged file/hash and line 501; no C2 attribution and no pass claim. |
| Child allocation honesty | PASS as disclosure only | `Remote::tracks`, Producer/Consumer collections, and the upstream unbounded command/deferred/maps are explicitly excluded from a process-memory/DoS claim. They remain follow-up gaps. |

## Tooling provenance and execution

All three requested stopped containers were inspected without starting them:

| Container | State | Base image | Relevant contents |
| --- | --- | --- | --- |
| `teremoq-u1-rust193-components` | exited, code 137 | `sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57` | Rust 1.93.0 plus rustfmt and Clippy files |
| `teremoq-u1-rust193` | exited, code 137 | same | Rust toolchain without added components |
| `teremoq-c1-r04-rust193` | exited, code 137 | same | rustfmt added, no Clippy |

The first container was committed locally, without network or push, as:

```text
tag:    teremoq-local-rust193-components:c2-review-20260828
image:  sha256:f522c28d5beb21591f46e8c165030f70b32dd5b51107577ad196910e7147a007
parent: sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57
```

The image carries local review provenance labels identifying the stopped
source container and parent. It reports:

```text
rustc 1.93.0 (254b59607 2026-01-19)
cargo 1.93.0 (083ac5135 2025-12-15)
rustfmt 1.8.0-stable (254b59607d 2026-01-19)
clippy 0.1.93 (254b59607d 2026-01-19)
```

An initial version probe through a login shell returned `rustc: not found`
because that shell replaced the configured PATH. Repeating with the immutable
absolute tool paths succeeded; this was a probe error, not a toolchain gate.

Every validation container used `--network none`; the source was bind-mounted
read-only. Clippy used external registry/git caches and a dedicated external
target volume. That target volume was removed after execution. No validation
container remains.

## Commands and results

| Validation | Result |
| --- | --- |
| HEAD/tree/branch/stage/status reconstruction | PASS; matches binding and owner inventory hash |
| SHA-256 of all 15 paths | PASS; all match the frozen owner inventory |
| Full tracked diff and all untracked contents inspected | PASS for scope; findings above apply |
| `git diff --check` | PASS |
| Per-untracked-path `git diff --no-index --check` | PASS |
| Focal `rustfmt --edition 2021 --check` | FAIL; C2 formatting differences |
| `cargo fmt --all -- --check` | FAIL, exit 1; C2 and inherited transport formatting differences |
| `cargo clippy --locked --offline --no-deps -p moq-relay-ietf --tests -- -D warnings` | FAIL, exit 101; two C2 warnings promoted to errors |
| Frozen C2 integration binary | PASS: 10/10 |
| Frozen C2 relay/unit binary | PASS: 17/17, 119 filtered |
| `moq-transport` WR-03 | `BLOCKED_BY_BASELINE_E0308`; not rebuilt |

The independently executed frozen binaries were:

```text
786491790c63fe98a55cebcbcef9db3fcd3e98b08b37e85a764ecd4fd53e4335  c2_session_admission-2b1a20e04e1900af
6a6213e5ce528ef38f3633003f37049d5d91c82e40cf92ced755089ff1649569  moq_relay_ietf-48648ac127c0eeb4
```

They cover real raw QUIC/WebTransport N/N+1, multi-endpoint sharing, M=32,
announce, RemoteManager setup/error/deduplication, C1 monitor composition,
panic paths, terminal accounting, owner drop, and forced deadline shutdown.
Passing these tests does not invalidate the uncovered cancellation path or the
test-design findings.

## Required rereview entry conditions

1. Make newly inserted Remote cache slots cancellation-safe and add the
   repeated distinct-key cancellation regression.
2. Use the original absolute test deadline for every wait and helper; eliminate
   the direct N+1 wait and unbounded thread join.
3. Replace the sequentially named race tests with barrier-controlled competing
   operations for both orderings and same-poll shutdown/terminal behavior.
4. Apply rustfmt without changing behavior and resolve both Clippy diagnostics
   without blanket warning suppression.
5. Re-run focal formatting, Clippy, 27 C2 tests, the relay package, C1 package,
   and the unchanged WR-03 classification on one new frozen inventory.
6. Preserve all current protected hashes and continue to disclose child-state
   limits; do not convert C2 root limits into process-memory, DDoS, production,
   Zero-Trust, or authorization claims.

## Final scope confirmation

This review created only this report under the Teremoq review directory. It did
not edit `/home/jimbomilk/moq-rs-teremoq-c2-work`, stage or commit files, modify
Git refs, fetch, push, publish, contact upstream, or mutate a remote service.
The only non-report artifact is the explicitly authorized local immutable
tooling image recorded above.

**CHANGES REQUIRED**
