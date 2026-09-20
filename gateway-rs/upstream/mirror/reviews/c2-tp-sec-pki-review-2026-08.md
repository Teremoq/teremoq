<!--
SPDX-FileCopyrightText: 2026 Teremoq contributors
SPDX-License-Identifier: Apache-2.0
-->

# C2 formal security review — TP-SEC-PKI

Date: `2026-08-28`  
Role: `TP-SEC-PKI`  
Review mode: `READ-ONLY SECURITY REVIEW / NO COMMIT / NO PUSH / NO PUBLICATION / NO REMOTE MUTATION`

## Findings first

### HIGH — Admission remains open after the controller enters `Stopping`

`SessionAdmission::try_admit` always calls `try_acquire_owned` and, on success,
increments the active/admitted counters without consulting `shutdown_state` at
`moq-relay-ietf/src/session_admission.rs:228-248`. Both
`begin_shutdown` and `begin_forced_shutdown` only store state flags; neither
closes the semaphore nor otherwise prevents a later acquisition
(`session_admission.rs:254-264`).

This is reachable from production outbound code, not only from a synthetic
unit seam. `RemoteManager::get_or_connect` calls the same open admission path at
`moq-relay-ietf/src/remote.rs:806-824` and `remote.rs:849-869` without an
`is_running` check or a closed-controller result. During bounded shutdown,
`run_bounded` first marks both controllers `Stopping` at
`moq-relay-ietf/src/relay.rs:1006-1012`, but then drains the still-live session
and control futures concurrently with `RemoteManager::shutdown` at
`relay.rs:1014-1055`. A pending upstream-namespace or session future can
therefore reserve a new outbound permit, insert a cache slot and begin
QUIC/MoQT setup after shutdown has been observed. Closing the task owner later
does not prevent that setup: submission is checked only after transport and
MoQT setup at `remote.rs:1106-1219`.

The test suite positively demonstrates the broken state transition:
`c2_cancellation_drop_and_forced_drop_are_exactly_once` calls
`begin_forced_shutdown()` and then expects a new `try_admit()` to succeed at
`session_admission.rs:594-606`. I independently executed that exact existing
test binary and it passed.

Impact:

- C2-I07 fails: shutdown does not atomically close admission.
- C2-I09 fails in its shutdown-state dimension, although identity independence
  itself is preserved.
- C2-T17 fails for outbound roots: the implementation does not prove that no
  root is admitted after shutdown begins.
- The single absolute deadline still bounds owned future polling, but new
  network/setup effects can start inside that budget after the stop boundary.

Required correction for `TP-RUST-DIST`:

1. Make the transition to `Stopping` part of the non-waiting admission
   linearization. Use an official close-aware semaphore operation or equivalent
   atomic state machine; do not add a waiter, queue or check-then-act window.
2. Return a distinct internal `Stopping/Closed` disposition. It must not
   increment `admitted_total` or `rejected_capacity_total`, create a slot, dial,
   spawn/submit a future, log peer data or invoke a callback.
3. Close both inbound and outbound controllers before cancelling/draining their
   owners. A permit linearized before close remains an existing owned root; an
   acquisition for which close wins must fail immediately.
4. Change the current forced-drop unit test so the permit is acquired before
   forced shutdown, then dropped after the transition.
5. Add deterministic two-order tests for outbound `admit-before-stop` and
   `stop-before-admit`, including a real `RemoteManager` probe that observes no
   cache entry, transport accept, task, active/inflight gauge or admitted count
   in the latter order.

### MEDIUM — N+1 tests do not prove the required wire rejection contract

The production source uses fixed code `0x3` and fixed reason
`relay session capacity reached` at `moq-relay-ietf/src/relay.rs:47-50` and
`relay.rs:913-931`, and it places that close before requeue and session-root
construction. Static ordering is good.

The integration test does not, however, test the contract it claims. In
`c2_inbound_n_plus_one_is_immediate_for_raw_and_webtransport`, N+1 only calls
the native `client.connect`, stores an `anyhow::Result`, and immediately drops
it at `moq-relay-ietf/tests/c2_session_admission.rs:278-305`. It never starts a
client MoQT setup, never demonstrates that the client is waiting for
SERVER_SETUP, and never inspects the transport application-close code or
reason. The M=32 test repeats the same native-only oracle at
`c2_session_admission.rs:375-435`.

The coordinator/tagger counters are useful independent probes, but the tests do
not enable mlog or inspect `Locals`/namespace state. Consequently C2-T05 and
C2-T07 are unproved, C2-T06 is only partially proved, and the overload half of
C2-T23 is unproved. The owner report's statement that the matrix has no
`PARTIAL` rows is therefore not supported by the test source.

Required correction:

1. For both raw QUIC and WebTransport, hold N roots, start an actual N+1 MoQT
   client setup and establish deterministically that it is waiting for
   SERVER_SETUP before observing the application close.
2. Assert the exact constant code and reason through the public transport API;
   do not assert `Debug` output or dump peer/certificate material.
3. Configure an isolated mlog directory and independent relay-state probes.
   Assert zero files, zero tagger/coordinator calls, no local/namespace mutation
   and no session-root handle for N+1.
4. Retain watchdogs only as failure bounds; use channels/barriers, not time or
   C2's own counters, to establish ordering.

### MEDIUM — Ordering and race tests are not discriminating

The implementation order in `SessionPermitGuard::release_and_record` is
correct by inspection: active/inflight are decremented, the owned permit is
dropped, the terminal-class counter is incremented, and only then
`terminal_total` is published with `Release` at
`moq-relay-ietf/src/session_admission.rs:445-469`. Snapshot reads
`terminal_total` with `Acquire` before gauges/capacity at
`session_admission.rs:324-350`.

The corresponding cross-thread test calls `guard.finish` before spawning the
observer thread (`session_admission.rs:575-591`). Thread creation itself
orders all preceding writes, so the test would still pass if the terminal
publication did not provide the claimed Release/Acquire synchronization. The
tests named as close/admit and terminal/shutdown races execute the two orders
sequentially in one thread at `session_admission.rs:609-665`; they do not create
a concurrent race.

This leaves C2-T12 and C2-T13 only partially demonstrated despite the source
currently implementing the intended order.

Required correction:

1. Start the observer before terminal publication, signal readiness with a
   barrier/channel, and have it wait until an Acquire snapshot first observes
   the terminal; only then assert active/inflight zero and full availability.
2. Add deterministic concurrent terminal-vs-shutdown and release-vs-admit
   interleavings. Assert the quiescent equation and exactly one terminal using
   state independent from the branch being tested.
3. Do not add sleeps or a new dependency merely to name a race test.

### MEDIUM — Mandatory immutable-toolchain gates remain unavailable

The binding owner report records that the exact required Rust 1.93.0 image does
not contain Clippy or rustfmt, so `cargo clippy ... -D warnings` and
`cargo fmt --all -- --check` were not executable
(`c2-local-review-2026-08.md:49-59,327-328,351-355`). No alternative image was
authorized and I did not install a component or repeat a large build.

This is a reproducibility/quality gate blocker independent of the security
findings above. It may be closed only by an approved immutable Rust 1.93.0
image containing the required components and exact reruns against an unchanged
snapshot.

## Snapshot binding and integrity

- Worktree: `/home/jimbomilk/moq-rs-teremoq-c2-work`
- Branch: `teremoq/c2-session-shutdown-ee22a10`
- Tracking branch: none observed
- HEAD/base: `ee22a1079783e374371e0705775978790ddd6471`
- Tree: `232e449945e877b024f2fc4223f0d2eea124b39b`
- Stage: empty
- Status inventory: exactly 15 paths
- `git status --porcelain=v1 --untracked-files=all` SHA-256:
  `41969b3ff7d7ebcaaf891137a17519a2097319642b6753db144a0b5a000db614`
- TP-SEC-PKI plan SHA-256:
  `9d3ba88aa9d0299ef9efc99927e28dfa6d7d31fc8b09095eb0436be38f00aa18`
- Owner report SHA-256:
  `33e3fb8949f5107a0c8044a0169d8bc72628e91fa5677a3200a187b139308ffa`
- `.cursorrules` SHA-256:
  `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2`
- ADR-0007 SHA-256:
  `0085bdaa37cd3645a4a2c5a3163b0b096453b84f66635514fce6015d6bed25d8`

Changed-path hashes independently verified:

| Path | SHA-256 |
|---|---|
| `moq-relay-ietf/src/lib.rs` | `7221542f360df88d2eb552198ce1c9ca37f7380c5229d2ccc76a22041eb0f0bf` |
| `moq-relay-ietf/src/relay.rs` | `07b48b84ca57bab60ca8e0cce9096eac5bde6aa94a544cc4a96f9e4317356e6c` |
| `moq-relay-ietf/src/remote.rs` | `9a012fc2e698864f3e5286d97461010840f236fc25c4373f4efffd1b4727b7d8` |
| `moq-relay-ietf/src/upstream_namespaces.rs` | `7033823b66d5e3e82c0e6afdf2e4062080b908ed11c0aedb4550bd2f7cd775b9` |
| `moq-relay-ietf/src/relay_c2_tests.rs` | `f76ea25d9be4379ddf04fa063bb3d0ed1d91f738ede76c45d3a4bec7c10f2238` |
| `moq-relay-ietf/src/session_admission.rs` | `1bb5f79e24d52ada9fd402d14eca6bd6bb8a50276d90931b04f7d1e1959cfd3d` |
| `moq-relay-ietf/tests/c2_session_admission.rs` | `eab3296eed7b97ec3987259298d20cacafabd96c7c633f07b46f7f40ced760bc` |
| `moq-relay-ietf/tests/data/c2/README.md` | `285e4e178ecd6a7c5cffe5409107bc11bdf096bba9ebc014e805c0b991c1ae72` |
| `moq-relay-ietf/tests/data/c2/SHA256SUMS` | `ccc4d9cbcc23c31cfd12e2ef5d0a57e6d0901c243f7a732fc6eba20a7c82c8fd` |
| `moq-relay-ietf/tests/data/c2/ca.cert.pem` | `c439d7428d418762e090e1ce0fdda1524473daa66f052da251e120d78555dfbb` |
| `moq-relay-ietf/tests/data/c2/ca.cert.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-relay-ietf/tests/data/c2/server.cert.pem` | `76fe11a03423308533516c61c8e06f994746293313ef8961091de0e87cbd2b09` |
| `moq-relay-ietf/tests/data/c2/server.cert.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-relay-ietf/tests/data/c2/server.key.pem` | `607642c80b7ec6e365ef877e24c526ca546542fb5c330ae191891a212b67aa35` |
| `moq-relay-ietf/tests/data/c2/server.key.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |

The snapshot remained stable during review. The target worktree was never
written and its stage remained empty.

## I01-I12 result

| Invariant | Result | Security evidence |
|---|---|---|
| I01 global/non-waiting | PASS | One inbound controller is shared across endpoint accepts; `try_acquire_owned` is the only acquisition primitive. No waiter or availability check precedes it. |
| I02 N+1 before effects | SOURCE PASS / TEST GAP | `relay.rs:891-962` closes capacity before requeue, metrics, mlog, callbacks and session roots. T05/T07 wire proof is absent. |
| I03 private RAII guard | PASS | Guard is crate-private, non-`Clone`, owns one `Option<OwnedSemaphorePermit>`, exposes neither semaphore nor permit, and uses no `unsafe`. |
| I04 release ordering | SOURCE PASS / TEST GAP | `session_admission.rs:445-469,324-350` implements the required Release/Acquire order; T13 is non-discriminating. |
| I05 terminal/drop safety | PASS WITH COVERAGE GAP | `Option::take` prevents double terminal; setup/run/cancel/panic/drop/forced paths retain the guard. Concurrent T12 evidence is incomplete. |
| I06 MAX/MAX+1 validation | PASS | Public bounded constructors validate zero, Tokio `MAX_PERMITS`, MAX+1 and timeout before `Semaphore::new`; no panic/clamp/fallback found. |
| I07 single deadline/closed admission | FAIL | One `timeout_at` deadline exists, but admission is not closed at `Stopping`; see HIGH finding. |
| I08 redacted capacity observability | PASS | Snapshot and report contain only fixed aggregate fields. Admission, terminal and permit `Drop` contain no logging, metrics backend or callback. |
| I09 identity independence | PARTIAL / FAIL | Admission does not read IP/SNI/path/cert/identity/scope/auth, but it also ignores shutdown state, contrary to the capacity-plus-shutdown contract. |
| I10 bounded vs legacy | PASS | Additive bounded constructors fail typed; legacy signatures remain separate and no bounded-to-legacy fallback was found. |
| I11 minimal upstream scope | PASS | Exactly 15 paths, all under `moq-relay-ietf`; no manifest, lock, dependency, feature, TLS, draft, ALPN, Objects or `unsafe` delta. |
| I12 outbound delimitation/ownership | PASS WITH I07 CAVEAT | Inbound/outbound capacities are separate; announce, Remote roots/cleanup and namespace pulls are owned and force-dropped. Post-stop outbound acquisition remains open. |

## T01-T25 result

| Test | Result | Review conclusion |
|---|---|---|
| T01 configuration extremes | PASS | Unit/source evidence covers 0, MAX and MAX+1 without panic; timeout is checked. |
| T02 N/N+1 one endpoint | PASS | Real raw and WebTransport transport accepts plus M=32 overload; capacity never exceeds N. |
| T03 global multi-endpoint | PASS | Two endpoints/routes share one inbound monitor and one limit. |
| T04 contenders | PASS | M=32 finishes while N remains retained; no permit waiter observed. |
| T05 N+1 waiting for SERVER_SETUP | NOT PROVED | N+1 never starts MoQT setup. |
| T06 independent pre-gate effects | PARTIAL | Tagger/coordinator are independent; mlog, `Locals`, namespace and handle probes are absent. |
| T07 exact raw/WT close | NOT PROVED | Constants are statically fixed; client-side code/reason are not asserted. |
| T08 normal/setup recovery | PASS | Real setup error and established close restore capacity. |
| T09 scope/run error recovery | PARTIAL | Source retains RAII; no real scope-denial/run-error recovery test independent of manually selected terminal enums. |
| T10 cancellation/drop | PASS | Owner abort and RAII source prove synchronous recovery; no detached bounded root found. |
| T11 panic/unwind | PASS | Actual setup/run barriers are caught and terminalized once. |
| T12 natural/cancel/shutdown race | PARTIAL | Both orders are asserted sequentially, not raced. |
| T13 cross-thread ordering | PARTIAL | Observer starts after `finish`, so thread-start synchronization masks the ordering under test. |
| T14 identity independence | PASS BY SOURCE | Admission occurs before `ConnInfo` destructuring and reads no identity/network signal. |
| T15 cooperative shutdown | PASS | Owned collections drain under one deadline and report zero C2 gauges. |
| T16 forced shutdown | PASS | Non-cooperative owned Remote root is dropped at the same deadline with zero gauges. |
| T17 accept/admit/shutdown race | FAIL | Inbound post-accept barrier passes; shared/outbound admission still succeeds after `Stopping`. |
| T18 hostile metrics recorder | PASS BY STRUCTURE | Admission/finish/guard Drop use only atomics and official semaphore operations. |
| T19 outbound independence | PASS | Separate controller; pending announce does not consume inbound capacity or starve accepts. |
| T20 full owned lifecycle | PASS WITH I07 CAVEAT | Announce, Remote roots/cleanup and namespace pulls are owned; no bounded detached task found. |
| T21 C1 composition | PASS | Retained public C1 monitors reach zero after C2 shutdown; exact mid-TLS remains unavailable through the public C1 API. |
| T22 legacy separation | PASS | Existing constructor/run surface remains and bounded errors do not invoke legacy. |
| T23 raw/WT regression | PARTIAL | Admitted routes are real; overload-before-SERVER_SETUP wire behavior is not tested. |
| T24 redaction | PARTIAL | Capacity schema/Debug/constants pass static review; no capture-based tracing/mlog/close test exists. |
| T25 upstream surface | PASS | Scope and protected hashes are exact; no dependency or protocol surface changed. |

## Security properties that do pass

- The inbound `try_acquire_owned` call is before requeue, application metrics,
  mlog, `Coordinator`, `ConnectionTagger`, MoQT setup and state construction.
- N+1 performs no wait, retry, backoff, queue insertion or per-connection spawn.
- Capacity close and shutdown close use constant codes/reasons and contain no
  peer fields.
- `SessionPermitGuard` is non-clonable and terminalizes exactly once through an
  owned `Option` on the inspected paths.
- No IP, CID, SNI, path, certificate, identity, principal, role, namespace,
  URL, payload or peer error is present in C2 capacity snapshots/labels.
- Capacity is not used as authentication, authorization, mTLS evidence or
  relay-peer classification.
- Bounded production paths do not call `tokio::spawn`; the only production
  spawn remains behind `RemoteTaskOwner::DetachedLegacy` at
  `remote.rs:42-56`.
- One checked monotonic `Instant` and one `timeout_at` govern the drain.
- The implementation does not claim pre-handshake protection, total DoS
  resistance, process-wide memory bounds, authentication or production
  readiness.

## Fixtures and trust material

The three PEM fixtures are test-only deterministic encodings of the immutable
C1 synthetic material. `README.md:6-15` labels the private key public and
non-production, and each PEM has an SPDX sidecar.

Independent checks, without displaying PEM/key content, confirmed:

- C2 CA decoded DER SHA-256:
  `ea33add88bed4676c51baa4f8da9df33d04e99cecf7d0846a756e23b0f66461b`
- C2 server certificate decoded DER SHA-256:
  `053a80b61f971f0601d83305ec6139fbcd7ed2f78c541078ac6e68a7e6da16bc`
- Those hashes exactly match `moq-native-ietf/tests/data/c1`.
- The server certificate and test key public-key hashes match:
  `436244f693828dc19410df2c62bf5db3842b7318852c7cb0af55d25dc823e277`.
- The public certificate is for loopback test use (`localhost`, `127.0.0.1`),
  expires in 2036, and is not represented as production identity.
- No test generates certificates at runtime or prints PEM/key content.

The owner Gitleaks result is consistent with this inventory: changed source
has no finding and the documented public fixture key produces the single
expected `private-key` signature. That expected fixture signature is not a
production secret waiver.

## Commands and validation evidence

Independently executed read-only checks:

```text
sha256sum .cursorrules c2-tp-sec-pki-review-plan-2026-08.md c2-local-review-2026-08.md
git rev-parse HEAD^{commit} HEAD^{tree}
git status --porcelain=v1 --untracked-files=all | sha256sum
git diff --cached --name-only
git diff --check ee22a1079783e374371e0705775978790ddd6471 --
git diff --cached --check
git diff --name-only ee22a1079783e374371e0705775978790ddd6471 --
sha256sum moq-relay-ietf/src/lib.rs moq-relay-ietf/src/relay.rs \
  moq-relay-ietf/src/remote.rs moq-relay-ietf/src/upstream_namespaces.rs \
  moq-relay-ietf/src/relay_c2_tests.rs moq-relay-ietf/src/session_admission.rs \
  moq-relay-ietf/tests/c2_session_admission.rs moq-relay-ietf/tests/data/c2/*
rg <admission, semaphore, spawn, unsafe, logging, identity and lifecycle scans>
openssl x509/pkey <fixture provenance, metadata and public-key match only>
```

Results:

- Binding hashes, HEAD/tree, 15-path inventory and empty stage: PASS.
- `git diff --check`, cached diff check and untracked text/conflict scan: PASS.
- Protected manifests/lock/native QUIC/TLS/transport setup/session are
  byte-identical to base: PASS.
- Forbidden primitives scan: no `unsafe`, waiter acquisition,
  `ManuallyDrop`, `forget` or `add_permits`; PASS.
- Fixture provenance/public-key comparison: PASS.

Focal execution without rebuilding:

```text
target/debug/deps/moq_relay_ietf-48648ac127c0eeb4 \
  --exact session_admission::tests::c2_cancellation_drop_and_forced_drop_are_exactly_once \
  --nocapture
```

- Existing binary SHA-256:
  `6a6213e5ce528ef38f3633003f37049d5d91c82e40cf92ced755089ff1649569`.
- Result: PASS, `1 passed; 135 filtered out`. This confirms the HIGH finding
  because the test successfully acquires after forced shutdown.

I also attempted the existing fixture-dependent
`c2_race_03_accept_completion_before_shutdown_never_admits_after_observation`
directly. It did not execute its logic: the binary had been built inside the
owner container and its baked manifest fixture path was unavailable on the
host, causing fixture open failure at `relay_c2_tests.rs:67`. This is not
reported as a C2 source failure. Per instruction, I did not rebuild or rerun it;
the owner pinned-container PASS remains recorded as supplied evidence.

Owner evidence accepted after snapshot/hash verification:

- Rust/Cargo 1.93.0 pinned image, `--network none`, `--locked --offline`.
- 27 focal C2 tests: PASS.
- Complete relay suite: 136 library, 16 binary, 10 integration and doctest:
  PASS.
- C1 native tests: PASS.
- `RUSTFLAGS=-D warnings cargo check ... --tests`: PASS.
- REUSE 5.1.1 source-only: PASS.
- Gitleaks 8.30.1: source PASS; one expected documented public fixture-key
  finding.
- Clippy: BLOCKED, component absent from the mandated image.
- rustfmt: BLOCKED, component absent from the mandated image.
- `moq-transport` WR-03: exact inherited E0308 at unchanged
  `moq-transport/src/serve/tracks.rs:501`; still
  `BLOCKED_BY_BASELINE_E0308`, not a C2 pass or C2 regression.

No large build, dependency installation, image download, network access, fetch,
commit, push, tag, publication or remote mutation was performed in this review.

## Residual boundaries

- C2 begins only after `Server::accept`; C1 remains the pre-handshake control.
- C2 is capacity/lifecycle, not authentication or authorization. It does not
  establish mTLS, identity, principal, role or relay-peer trust.
- The root limits do not bound child maps, request futures, the existing
  unbounded upstream command channel, process memory or network-level DoS.
- A Tokio deadline is cooperative; it cannot promise hard wall-clock return if
  the executor or arbitrary external synchronous `Drop`/callback blocks.
- Legacy path/SNI/IP classification remains baseline behavior and is neither
  consumed nor endorsed by C2 admission.
- WR-03 and future OSS/advisory/release gates remain separate from a local C2
  security correction.

## Verdict

CHANGES REQUIRED

This verdict does not authorize a local commit, C3, integration, push,
publication, release or production use.

Confirmation: `READ-ONLY SECURITY REVIEW / NO COMMIT / NO PUSH / NO PUBLICATION / NO REMOTE MUTATION`.
