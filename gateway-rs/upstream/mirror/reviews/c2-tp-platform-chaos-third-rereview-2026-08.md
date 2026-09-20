<!--
SPDX-FileCopyrightText: 2026 Teremoq contributors
SPDX-License-Identifier: Apache-2.0
-->

# C2 third formal rereview — TP-PLATFORM-CHAOS

Review date: `2026-08-28`

Verdict: **APPROVE FOR LOCAL COMMIT**

Scope: independent read-only rereview of the frozen, uncommitted C2 snapshot in
`/home/jimbomilk/moq-rs-teremoq-c2-work`. This verdict permits only a local
commit of the exact 15-path inventory and hashes recorded below. It does not
authorize integration, a product pin, C3, publication, push, tag, release,
issue, pull request, or any remote mutation.

## Findings first

### No C2-blocking finding

The complete 15-path delta, the corrected concurrency seams, and the retained
test matrix were reviewed independently. I found no new correctness,
concurrency, shutdown, wire-compatibility, or test-watchdog defect that blocks
a local commit of this exact snapshot.

The prior platform findings are closed at these source boundaries:

- pre-cancel and announce first-poll linearization:
  `moq-relay-ietf/src/relay.rs:897-970` and
  `moq-relay-ietf/src/relay.rs:1287-1340`;
- same-key generation ownership and cancellation-safe retirement:
  `moq-relay-ietf/src/remote.rs:204-289` and
  `moq-relay-ietf/src/remote.rs:1387-1450`;
- typed, fallible unpublished-slot invariant:
  `moq-relay-ietf/src/remote.rs:1397-1406`;
- `Closed` before existing-slot mutation, logging, shutdown, dial, or task
  creation: `moq-relay-ietf/src/remote.rs:1431-1515`;
- official CLIENT_SETUP/SERVER_SETUP wire ordering and independent root probe:
  `moq-relay-ietf/src/relay_c2_tests.rs:198-297` and
  `moq-relay-ietf/src/relay_c2_tests.rs:727-834`;
- real scope and ordinary `Session::run` error recovery:
  `moq-relay-ietf/src/relay_c2_tests.rs:406-520`.

### High, inherited baseline blocker: WR-03 is not a C2 pass

`cargo test --locked --offline -p moq-transport` independently reproduces the
unchanged baseline error:

```text
error[E0308]: mismatched types
  --> moq-transport/src/serve/tracks.rs:501:43
expected `TrackName`, found `&str`
```

The protected file remains byte-identical, SHA-256
`a8303c94925707a0a257923725bf84e4ec730b07d6bb2330fda5329b632fe0b7`.
Classification remains exactly **`C2-WR-03: BLOCKED_BY_BASELINE_E0308`**. It is
neither evidence against this C2 delta nor a passing Objects regression.

### Medium, explicit scope limitation: no process-memory or DoS bound

C2 bounds relay-global inbound and outbound session roots. It does not by
itself bound every child allocation: `Remote::tracks`, Producer/Consumer
request collections, and the `UpstreamNamespaces` command/routing state remain
separate capacity domains. Bounded mode owns the namespace runner and pull
futures, but that lifecycle ownership is not a queue or memory bound.

Accordingly this rereview makes no memory, DoS-resistance, fairness, sizing,
latency, production-readiness, Zero-Trust, or all-process-concurrency claim.

### Low, inherited formatting debt outside C2

Focused rustfmt passes for all seven changed C2 Rust paths. Global
`cargo fmt --all -- --check` reports only pre-existing protected-source
differences at `moq-transport/src/serve/subgroup.rs:934` and
`moq-transport/src/serve/tracks.rs:304`. No C2 path appears in that output.

## Frozen evidence and binding

The required review inputs were read and their hashes reproduced before the
source review:

| Evidence | Required and observed SHA-256 |
| --- | --- |
| Current owner report, `c2-local-review-2026-08.md` | `a15dd8989f3cffa234daf70bec33cc92e8d4e1243871ed41e0ca986d41d480bd` |
| Previous TP-PLATFORM-CHAOS rereview | `3796be533ad5090c4fcdc8419610148caaf16b0ff81fd2996c4acb56fec0f477` |
| Previous TP-SEC-PKI rereview | `cfbb03d91e406ca139696ed01c09307f6b94378258313915c4f14199ee61c47a` |
| Previous TP-OSS-SC rereview | `c1c5b3a5f9e2b8a81265d1df131753b6bda458e0a984fbe8c504bb7245ef8f4d` |
| Formal C2 TP-PLATFORM-CHAOS plan | `550e52ec87cb4d1c10a76ca61d640723eb2fb36e7a3438914184ad30ed6cf1ab` |

The snapshot was bound both before and after validation:

| Property | Independently observed value |
| --- | --- |
| Worktree | `/home/jimbomilk/moq-rs-teremoq-c2-work` |
| Local branch | `teremoq/c2-session-shutdown-ee22a10` |
| `HEAD` / base | `ee22a1079783e374371e0705775978790ddd6471` |
| `HEAD^{tree}` | `232e449945e877b024f2fc4223f0d2eea124b39b` |
| Staged bytes | `0` |
| Status paths | `15` |
| Status inventory SHA-256 | `41969b3ff7d7ebcaaf891137a17519a2097319642b6753db144a0b5a000db614` |
| Branch upstream | none |

No hash diverged from the owner binding; therefore the mandatory fail-closed
condition was not triggered.

## Exact 15-path inventory

| Path | SHA-256 |
| --- | --- |
| `moq-relay-ietf/src/lib.rs` | `af994bc136fafa97b0a6faa15645811fc1f04b8d03851702f3fa48d38fbb0253` |
| `moq-relay-ietf/src/relay.rs` | `903be07defdbdcfd5a6ef02e192520bd793d6ef7cb8a238ee3b697262c7273be` |
| `moq-relay-ietf/src/remote.rs` | `5a5a30536280fe946db0df969b1ae81099186838ec69904128a15e0ff15cf8a4` |
| `moq-relay-ietf/src/upstream_namespaces.rs` | `7033823b66d5e3e82c0e6afdf2e4062080b908ed11c0aedb4550bd2f7cd775b9` |
| `moq-relay-ietf/src/relay_c2_tests.rs` | `5ebccdf289a5b4183b28e78ee56dfad7f991a2c4c58eda27327c5e88f8033237` |
| `moq-relay-ietf/src/session_admission.rs` | `cc5c56db172f7fb13e1f5a1a8bea3957c096d869dd97ac3f9d9f753820f0c7ef` |
| `moq-relay-ietf/tests/c2_session_admission.rs` | `1b528da9ccd852d81085bad190e01ae9a5a84ca6724574ed6a7cd2904e7e0a0a` |
| `moq-relay-ietf/tests/data/c2/README.md` | `285e4e178ecd6a7c5cffe5409107bc11bdf096bba9ebc014e805c0b991c1ae72` |
| `moq-relay-ietf/tests/data/c2/SHA256SUMS` | `ccc4d9cbcc23c31cfd12e2ef5d0a57e6d0901c243f7a732fc6eba20a7c82c8fd` |
| `moq-relay-ietf/tests/data/c2/ca.cert.pem` | `c439d7428d418762e090e1ce0fdda1524473daa66f052da251e120d78555dfbb` |
| `moq-relay-ietf/tests/data/c2/ca.cert.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-relay-ietf/tests/data/c2/server.cert.pem` | `76fe11a03423308533516c61c8e06f994746293313ef8961091de0e87cbd2b09` |
| `moq-relay-ietf/tests/data/c2/server.cert.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-relay-ietf/tests/data/c2/server.key.pem` | `607642c80b7ec6e365ef877e24c526ca546542fb5c330ae191891a212b67aa35` |
| `moq-relay-ietf/tests/data/c2/server.key.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |

Tracked diff scope is four files with `2438` insertions and `100` deletions;
the remaining eleven paths are new tests/fixtures. The index stayed empty.

## Adversarial concurrency rereview

### Startup, admission, and first-poll ordering

`run_bounded` observes a pre-cancelled token before destructuring the Relay or
constructing accept, control, announce, dial, or task roots
(`relay.rs:897-921`). `finish_unstarted_bounded_shutdown` closes both admission
controllers and returns their quiescent snapshots (`relay.rs:876-895`).

Announce startup uses one biased cancellation-first select around one
nonblocking `try_admit` (`relay.rs:937-967`). The deterministic tests force both
orders: stop-first produces zero accept/control/announce/dial/task/peer effects;
admit-first transfers exactly the already-owned root into bounded lifecycle
ownership. The inner setup select is also cancellation-first. No synchronous
public callback or blocking substitute was introduced.

Inbound ordering remains: receive an accepted transport, cross the private
deterministic gate, recheck shutdown/controller state, call `try_admit`, then
and only then mark/start the MoQT session root (`relay.rs:1053-1135`). Capacity
rejection closes/requeues without a permit waiter, admission task, Producer,
Consumer, coordinator, namespace, Locals, tagger, or mlog effect.

### RAII, terminal accounting, and shutdown

The non-cloneable admission guard owns its semaphore permit. Every terminal
path releases capacity before incrementing the exactly-once terminal counter.
Drop covers cancellation/unwind/forced teardown, and the quiescent equation is
checked across mixed terminals. `MAX_PERMITS` is accepted while `MAX+1` is a
typed construction error, not a panic (`session_admission.rs:36-48` and
`session_admission.rs:520-564`). No permit acquisition awaits; admission uses
`try_acquire_owned`.

On shutdown the code closes controllers, stops accepts, cancels owned roots and
uses one checked monotonic absolute deadline for the entire drain
(`relay.rs:1168-1247`). At expiry, the remaining root owners are synchronously
dropped and the final snapshots must have zero active/inflight/root gauges
before return. No wait or join resets the deadline.

### Remote same-key and `Closed` behavior

`RemoteSlotReservation` indivisibly owns the `OwnedMutexGuard` and exact map
generation. Its `Drop` removes only that exact generation under the map lock
while the per-key slot remains locked; Rust then drops the fields and unlocks
the slot (`remote.rs:204-289`). Thus a pending same-key waiter cannot adopt an
orphan generation after creator cancellation.

The real-QUINN regression uses capacity `>=2`, blocks the creator before MoQT
setup, observes a pending waiter, cancels the creator, proves old-generation
retirement, and creates one current replacement. It observes exactly two
intentional dials, one replacement root/task, no orphan, and a terminal
equation with restored capacity (`remote.rs:864-976`).

For an existing empty or dead slot, `Closed` is returned before reconnect
effects, logging, shutdown, mutation, dial, or task submission. The tests keep
the exact generation pointer and all independent effect probes unchanged
(`remote.rs:634-777`). Productive slot construction contains no `expect`; an
impossible lock invariant returns fixed, redacted
`RemoteCacheSlotInvariantError` (`remote.rs:46-52`, `remote.rs:1397-1406`).

### Wire ordering and real error routes

The N+1 wire test encodes the official MoQT CLIENT_SETUP, polls the official
SERVER_SETUP read to `Poll::Pending`, signals that exact state, and only then
releases accept. An independent root probe—not the admission counter—remains
zero. Raw QUIC and WebTransport clients observe application code `0x3`, reason
`relay session capacity reached`, and no SERVER_SETUP bytes.

The ordinary-error regression drives a real coordinator scope failure and a
separate established session whose peer produces an ordinary non-graceful
`Session::run` error. Each route releases once, recovers capacity, leaves the
root probe at zero, and leaves no namespace/session residue. The setup/run panic
paths remain test-only unwind injections; no production panic callback or
blanket allow was added.

## Complete C2 matrix

| Plan row(s) | Result | Independent evidence / exact limitation |
| --- | --- | --- |
| CFG-01..03 | PASS | Zero and invalid timeout/limits fail typed and closed; MAX succeeds; MAX+1 never reaches semaphore construction or panic. |
| ADM-01..04 | PASS | Real raw and WebTransport N/N+1; one relay-global controller across endpoints; mixed transport; peak never exceeds N. |
| ORD-01..02 | PASS | Rejection precedes MoQT/root/state effects and does not grow accept roots. |
| WAIT-01 | PASS | M=32 overload completes while admitted N remains held; no semaphore waiter queue/task/sleep threshold. |
| REC-01..07 | PASS | Clean close, setup error, ordinary run error, cancellation, owner drop, setup/run unwind, forced drop, and exact recovery. |
| RACE-01..03 | PASS | Both controlled orders for release/admit, terminal/shutdown, and accept/shutdown; no post-`Stopping` admission or underflow. |
| MET-01 | PASS | Versioned low-cardinality counters; release-before-counter; exact terminal equation; zero final gauges; no peer/IP/identity labels. |
| SD-01..06, SD-08..09 | PASS | Idle/active/mixed/forced teardown, one absolute deadline, deterministic same-poll races, drop-before-run, and retained C1 zero. |
| SD-07 | `UNTESTABLE_EXACT_MID_TLS_WITH_C1_PUBLIC_API` | Public C1/QUINN seam cannot construct exact mid-TLS. Real transport/drop coverage is conservative evidence, not a pass. |
| OUT-01..06 | PASS | Pending/established announce ownership, global outbound N/N+1, same/distinct key, cancellation/error recovery, one deadline, no detached bounded root. |
| WR-01..02 | PASS | Real raw QUIC and WebTransport paths retain their existing ALPN, H3/CONNECT, and draft-16 setup behavior. |
| WR-03 | `BLOCKED_BY_BASELINE_E0308` | Unchanged `tracks.rs:501`; Objects package test cannot compile and is not claimed passing. |
| WR-04..06 | PASS | Exact existing application close, multi-endpoint shared C2 controller, retained per-endpoint C1 behavior, and legacy source-compatible explicitly unbounded API. |
| Child collections | EXPLICIT GAP | Session-root limits do not bound Remote tracks, Producer/Consumer work, or all namespace queue/map state. |

No row uses an elapsed-time success threshold or arbitrary UDP as QUIC. All
logical test waits—including event receives, polling loops, connection/setup,
close observation, task joins, shutdown, and cleanup—are enclosed by a
caller-owned absolute `timeout_at` watchdog. Helpers receive/reuse that same
deadline; no C2 test uses `sleep` as synchronization.

## Toolchain and commands executed

Only the locally supplied image was used:

```text
teremoq-local-rust193-components:c2-review-20260828
sha256:f522c28d5beb21591f46e8c165030f70b32dd5b51107577ad196910e7147a007
```

Image provenance inspected locally; no pull occurred. Tool versions were
`rustc 1.93.0`, `cargo 1.93.0`, `rustfmt 1.8.0-stable`, and `clippy 0.1.93`.
Every compiling invocation used `--network none`, `--locked --offline`, the
source mounted read-only, Cargo registry/git caches mounted read-only, and one
external target volume.

| Gate | Independent result |
| --- | --- |
| `git diff --check` plus cached and no-index new-file whitespace checks | PASS; stage empty. |
| Focused Rust 2021 rustfmt on all seven C2 Rust paths | PASS. |
| `cargo fmt --all -- --check` | C2 paths clean; only inherited protected diffs at `subgroup.rs:934` and `tracks.rs:304`. |
| `cargo check --locked --offline -p moq-relay-ietf --tests` | PASS. |
| `cargo test --locked --offline -p moq-relay-ietf c2_` | PASS: 27 unit/private plus 10 integration C2 tests; 37/37. |
| `cargo test --locked --offline -p moq-relay-ietf` | PASS: 146 library + 16 binary + 10 integration + 1 executed doctest = 173 passed; 0 failed; 1 doctest ignored. |
| `cargo clippy --locked --offline --no-deps -p moq-relay-ietf --tests -- -D warnings` | PASS. |
| `cargo test --locked --offline -p moq-native-ietf c1_` | PASS: 25/25 retained C1 tests. |
| `cargo test --locked --offline -p moq-native-ietf` | PASS: 26/26 plus zero doctests. |
| `cargo test --locked --offline -p moq-transport` | Exit 101, exactly `BLOCKED_BY_BASELINE_E0308` at protected `tracks.rs:501`. |

Two non-evidentiary invocation mistakes were kept distinct from product
results: one offline check was attempted without the local cache mount and
stopped at dependency lookup; one Clippy attempt incorrectly pointed `RUSTC`
at `clippy-driver` and stopped before analysis. Both were rerun with the frozen
cache/toolchain configuration above. A first WR-03 command used a nonexistent
absolute rustc path and did not execute rustc; the corrected, otherwise
identical command produced the exact E0308 shown above. No source state changed.

## Protected inputs

The following independently reproduced hashes remain byte-identical to
`HEAD`; C2 did not edit manifests, lockfiles, transport/native source, wire
constants, or licenses:

| Protected input | SHA-256 |
| --- | --- |
| Workspace `Cargo.toml` | `6665802c9ad7192d61521a62877454e25bde7072c611e617780a932f583aa48f` |
| `Cargo.lock` | `b518a2fa4a6d7a0ffe0bdfe4b530f05196ac0f5e6f7ef51da9e5a83c0b0561c0` |
| Relay `Cargo.toml` | `c88726b7739c35c4fcb42fd511bfe608e478b5d2489729081821fc84cd1b318d` |
| Native `Cargo.toml` | `3180121a89c58071718236a408f36c1c87757d6f9ff81e899fb3b5814c8d4c8e` |
| Transport `Cargo.toml` | `78f582c201082f7badece64f7fa65d215a6694412b7a7699332fa3bc9a4f3743` |
| Native QUIC source | `b0c8dfb3e4963365a3a27f52a84d2fc54292cfc5a056a817a5a0d0a4f38b3723` |
| Setup ALPN module | `c49d71dcacd5e3f5eef7a673e11b9058d3fd701e1fb83331a737098894a2d750` |
| Setup version module | `384772b32812a0761fa55d16a9fd29e30595323ece1b3fca013ec3720eaec4ad` |
| Transport session module | `8e8992e1bb75d77c2475499014509a9362b965162d86156bdf6068a16b3cd2ea` |
| Transport tracks module | `a8303c94925707a0a257923725bf84e4ec730b07d6bb2330fda5329b632fe0b7` |
| `REUSE.toml` | `afc7fd86e591a56078b11982ee4d039ea1dfe3f9d56a90e3e7fa9f84fbddb6cc` |
| Apache-2.0 license | `1248f876e0140942002b476a19c95d5b5b44c625e69c96611d23119ee87fa04e` |
| MIT license | `c7d191b5901a741f2e39c74bd7a7594014a81fbe2bc7d533d4c29ad4cfe4e057` |

No dependency, feature, manifest, lockfile, ALPN, draft-16 wire input, Object
encoding, or active Teremoq product pin changed in this review.

## Cleanup and mutation boundary

- Review containers matching `teremoq-c2-third-rereview`: `0` after tests.
- External target volume
  `teremoq-c2-third-rereview-target-20260828`: removed and verified absent.
- Worktree-local `target/`: absent before and after validation.
- Worktree binding after validation: unchanged HEAD/tree, empty stage, 15 paths,
  same status-inventory hash and same 15 content hashes.
- Network: disabled for every validation container; no download or install.
- Source/worktree edits: none.
- Remote actions: none.

## Final decision

**APPROVE FOR LOCAL COMMIT**

This approval is valid only for the exact frozen 15-path inventory and hashes
in this report. `C2-WR-03` remains `BLOCKED_BY_BASELINE_E0308`, exact mid-TLS
remains untestable through the pinned public API, child-work capacity remains a
separate gap, and no C2 integration, product, publication, or production claim
is authorized.
