<!--
SPDX-FileCopyrightText: 2026 Teremoq contributors
SPDX-License-Identifier: Apache-2.0
-->

# C2 local owner review snapshot

Status: **READY FOR FORMAL REREVIEW**

Implementation state: **LOCAL ONLY / NOT COMMITTED / NOT PUSHED**

Snapshot time: `2026-08-28T07:01:37Z`

Owner: `TP-RUST-DIST`

Required independent reviewers: `TP-PLATFORM-CHAOS`, `TP-SEC-PKI`, and
`TP-OSS-SC` for publication and supply-chain gates.

This report replaces the preceding owner snapshot. The formal review reports
remain unchanged. It records owner evidence only and does not declare C2
approved.

## Findings first

### High: WR-03 remains blocked by the inherited baseline E0308

The unchanged `moq-transport` test target still fails at
`moq-transport/src/serve/tracks.rs:501` with the inherited `E0308` mismatch
between `TrackName` and `&str`. The file SHA-256 is still
`a8303c94925707a0a257923725bf84e4ec730b07d6bb2330fda5329b632fe0b7`,
byte-identical to C1 commit
`ee22a1079783e374371e0705775978790ddd6471`.

This remains exactly `C2-WR-03: BLOCKED_BY_BASELINE_E0308`. C2 did not repair,
absorb, suppress, or relabel the failure.

### Residual scope: C2 is not a process-memory or DoS bound

C2 bounds and owns distinct relay-global inbound and outbound session roots.
It does not bound every child allocation. In particular:

- `Remote::tracks` remains a per-remote child map;
- Producer and Consumer retain their existing request-scoped collections;
- `UpstreamNamespaces` retains its existing command queue and routing maps,
  although bounded mode owns and terminates its runner and pull futures;
- no production sizing, fairness, latency, memory, or DoS-resistance claim is
  supported by this local implementation.

These residual limits require later capacity analysis. This snapshot does not
make the relay production-ready or establish Zero-Trust readiness.

### Publication and approval remain out of scope

The owner-visible findings from the second formal review round now have local
code and deterministic evidence, but new independent review is still required.
The `TP-OSS-SC` verdict covers the frozen supply-chain scope and does not make
the derivative publication-ready. No commit, publication, product pin, or
integration is authorized by this report.

### Global rustfmt still reports only inherited non-C2 differences

Focused rustfmt passes on all seven C2 Rust paths. `cargo fmt --all -- --check`
continues to report only unchanged baseline formatting at:

- `moq-transport/src/serve/subgroup.rs:934`;
- `moq-transport/src/serve/tracks.rs:304`.

Neither file is part of C2 and neither was edited.

## Frozen inputs and provenance

The required inputs were read completely and their SHA-256 values matched:

| Evidence | SHA-256 |
| --- | --- |
| Previous owner snapshot | `1fdc354f8dc8818e853b17dd59318d1d2c90fe85e371cfda37f80a04bd1da0e2` |
| `TP-PLATFORM-CHAOS` rereview | `3796be533ad5090c4fcdc8419610148caaf16b0ff81fd2996c4acb56fec0f477` |
| `TP-SEC-PKI` rereview | `cfbb03d91e406ca139696ed01c09307f6b94378258313915c4f14199ee61c47a` |
| `TP-OSS-SC` rereview approval | `c1c5b3a5f9e2b8a81265d1df131753b6bda458e0a984fbe8c504bb7245ef8f4d` |

Precondition and final C2 worktree state:

- worktree: `/home/jimbomilk/moq-rs-teremoq-c2-work`;
- local branch: `teremoq/c2-session-shutdown-ee22a10`;
- base and current `HEAD`:
  `ee22a1079783e374371e0705775978790ddd6471`;
- base tree: `232e449945e877b024f2fc4223f0d2eea124b39b`;
- branch tracking: none;
- staging area: empty;
- exact inventory: 15 paths;
- status inventory SHA-256:
  `41969b3ff7d7ebcaaf891137a17519a2097319642b6753db144a0b5a000db614`;
- locally observed remote-tracking inventory remains only
  `origin/teremoq/baseline-draft16-bf87128` at
  `bf87128affd316463e5dcc7599a45001f222b6de`.

No fetch, commit, push, tag, release, issue, pull request, publication, remote
setting change, or other remote mutation occurred.

## Second-round corrections

### 1. Startup shutdown is linearized before announce admission

`BoundedRelay::run_until` now handles an already-cancelled token before it
constructs an accept, control, announce, dial, or task root. It closes both
admission controllers and returns a quiescent zero-effect report. The startup
announce boundary uses a biased cancellation-first select around the single
outbound `try_admit` operation:

- stop-first: zero admitted, rejected-capacity, terminal, active, inflight,
  root, dial, task, or peer-accept effects;
- admit-first: exactly the already-owned announce root survives into bounded
  lifecycle ownership and terminates exactly once.

The inner announce select is also cancellation-first. A cancellation already
observable there cannot poll the connect future. Private `cfg(test)` gates and
independent root/dial probes force both first-poll orderings without sleeps.

### 2. Same-key Remote generations have an indivisible handoff

The non-cloneable `RemoteSlotReservation` owns the Tokio
`OwnedMutexGuard<Option<Remote>>` and the optional exact map-generation
reservation together. On cancellation or failure, `Drop` removes that exact
generation while the slot remains locked; only field drop then releases the
mutex. A same-key waiter that acquired the old slot must therefore observe it
as stale and retry against the current map rather than adopting an orphaned
generation.

The deterministic real-QUINN regression uses outbound capacity two, blocks a
creator during real setup, queues a same-key waiter, cancels the creator, and
then establishes the replacement. It proves:

- old generation absent before retry;
- exactly one current slot and connection;
- one dial for each intentional generation and no duplicate generation dial;
- one terminal per permit;
- no orphan root or task;
- full capacity restoration after shutdown.

No detached cleanup task, capacity waiter, retry delay, callback, global, or
unsafe block was introduced.

### 3. Production Remote cache invariant failure is typed and redacted

The formerly infallible unpublished-slot lock boundary no longer uses
`expect()`. An impossible `try_lock_owned` failure returns the fixed private
`RemoteCacheSlotInvariantError` before inserting or poisoning shared state.
Its text contains no URL, address, peer, path, namespace, certificate,
identity, or dynamic error text. Remaining `expect()` occurrences in
`remote.rs` are confined to the `cfg(test)` module.

### 4. Closed admission has zero effects for existing slots

For existing empty or dead cache generations, outbound `try_admit` now occurs
before log, URL formatting, `remote.shutdown`, slot mutation, dial, map
replacement, or task submission. `Closed` leaves the exact slot generation
untouched and changes neither admitted, rejected-capacity, nor terminal
counters.

Tests cover both a pre-existing empty slot and a real connected slot made dead.
Independent cache identity, dial, reconnect-effect, task-owner, and admission
probes remain unchanged when stop wins.

### 5. Real N+1 wire ordering is observed before release

The raw QUIC and WebTransport rejection test writes the official CLIENT_SETUP,
polls the official SERVER_SETUP read to `Pending`, signals that observation,
and only then releases the server accept gate. The public client APIs observe
exactly:

- application code `0x3`;
- reason `relay session capacity reached`;
- no SERVER_SETUP.

A separate private `cfg(test)` root-insertion guard records both insertion and
active-root lifetime independently of admission counters. For N+1 both remain
zero. Independent mlog, tagger, Coordinator, Locals, namespace, and track
probes also remain zero.

### 6. Ordinary scope and session-run errors release ownership

A real inbound path now exercises two non-panic error classes:

1. `Coordinator::resolve_scope` deterministically returns a real
   `NamespaceNotFound` error after MoQT setup;
2. a second real session passes scope, then the peer closes the established
   native session with a fixed non-zero application code so `Session::run`
   returns an ordinary non-graceful error.

Each path releases capacity, publishes exactly one terminal, leaves the
independent root probe at zero, permits immediate reacquisition, and leaves no
registered namespace or residual session task.

## Preserved closures and ownership invariants

The additive bounded surface remains:

```rust
RelayConfig::build_bounded(
    self,
    max_inbound_sessions: usize,
    max_outbound_sessions: usize,
    shutdown_timeout: Duration,
) -> Result<BoundedRelay, BoundedRelayBuildError>

Relay::new_bounded(
    config: RelayConfig,
    max_inbound_sessions: usize,
    max_outbound_sessions: usize,
    shutdown_timeout: Duration,
) -> Result<BoundedRelay, BoundedRelayBuildError>

BoundedRelay::run_until(
    self,
    shutdown: CancellationToken,
) -> anyhow::Result<RelayShutdownReport>
```

Limits reject zero, duration zero/overflow, and values above
`tokio::sync::Semaphore::MAX_PERMITS` before semaphore construction; exact
`MAX_PERMITS` is accepted. Inbound and outbound controllers are separate and
relay-global. Admission uses `try_acquire_owned` only. There is no permit
waiter, check-then-increment, per-connection spawn, or public callback.

Each non-cloneable guard spans MoQT setup and the entire owned session root.
Capacity is released before exactly one low-cardinality terminal is published.
Snapshots use schema version 1 and contain no IP, CID, SNI, URL, connection
path, namespace, certificate, identity, principal, role, or remote error text.

`run_until` uses one monotonic shutdown deadline, closes inbound and outbound
admission first, stops acceptance, cancels all bounded-mode owners, drains
inside the remaining budget, drops non-cooperative roots at that deadline, and
returns only with C2 gauges at zero. Retained public C1 monitors are also
observed quiescent.

All test waits use a caller-owned absolute watchdog. Existing controlled races
for close/admit, release/admit, terminal/shutdown, observer/terminal, and
accept/shutdown remain discriminating and exactly-once. The M=32 burst retains
N roots and rejects excess connections without creating session effects.

Legacy `Relay::new`, `RelayConfig::build`, struct literals, and `Relay::run`
remain source-compatible and explicitly unbounded.

## Test matrix

| Area | Result | Evidence or limitation |
| --- | --- | --- |
| Rereview F1: startup/announce | PASS | Pre-cancelled token has zero effects; controlled stop-first and admit-first first-poll orderings; inner connect select is cancellation-first. |
| Rereview F2: same-key handoff | PASS | Real setup creator cancellation retires the locked generation before waiter retry; one replacement slot/root and exact terminal equation. |
| Rereview F3: production panic removal | PASS | Fixed typed invariant error; no production `expect()` at slot construction; no insertion on failure. |
| Rereview F4: existing-slot Closed | PASS | Empty and real dead slots remain generation-identical with zero log/dial/mutation/task/admission effects. |
| Rereview F5: wire ordering/root seam | PASS | Official SERVER_SETUP read reaches `Pending` before accept release; exact raw/WebTransport close and zero independent root insertions. |
| Rereview F6: ordinary errors | PASS | Real `resolve_scope` failure and ordinary non-graceful `Session::run` error each release and terminate once with no residual root/namespace. |
| CFG-01..03 | PASS | Zero/MAX/MAX+1/timeout validation is typed and panic-free. |
| ADM-01..04, ORD-01/02, WAIT-01 | PASS | N/N+1, shared multi-endpoint controller, M=32 burst, and zero pre-admission effects. |
| REC-01..07 | PASS | Setup/run error, clean close, cancellation/drop, injected setup/run unwind, forced shutdown, and recovery. |
| RACE-01..03, SD-08 | PASS | Both controlled interleavings preserve exactly one terminal, no underflow, release-before-terminal, and no post-stop admission. |
| MET-01 | PASS | Schema 1, redacted Debug, quiescent equation, and zero final gauges. |
| SD-01..06, SD-09 | PASS | Idle/active/forced shutdown, mixed terminals, owner drop, announce/Remote ownership, and retained C1 monitors. |
| SD-07 | `UNTESTABLE_EXACT_MID_TLS_WITH_C1_PUBLIC_API` | Explicit gap; C1 real transport/drop coverage is conservative evidence, not a C2 pass. |
| OUT-01..06 | PASS | Pending/established announce, distinct/same-key Remote behavior, setup failure/cancellation cleanup, and owned forced shutdown. |
| WR-01/02/04..06 | PASS | Raw/WebTransport, stable close, unchanged ALPN/draft/Objects inputs, and legacy compatibility. |
| WR-03 | `BLOCKED_BY_BASELINE_E0308` | Exact unchanged compiler failure at `tracks.rs:501`. |

There are no unjustified `PARTIAL` rows. `SD-07` and `WR-03` remain explicit
gaps rather than being presented as passes.

## Exact 15-path inventory and SHA-256

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

The decoded PEM hashes match immutable C1 DER provenance:
`ea33add88bed4676c51baa4f8da9df33d04e99cecf7d0846a756e23b0f66461b`,
`053a80b61f971f0601d83305ec6139fbcd7ed2f78c541078ac6e68a7e6da16bc`,
and `1d02d7ec66886fc2bb2cc3104851e1c182d7980e946d8df2e8f0f3ae33c30436`.
The private key is documented public synthetic non-production material.

## Protected byte-identical inputs

| Input | SHA-256 |
| --- | --- |
| Workspace `Cargo.toml` | `6665802c9ad7192d61521a62877454e25bde7072c611e617780a932f583aa48f` |
| `Cargo.lock` | `b518a2fa4a6d7a0ffe0bdfe4b530f05196ac0f5e6f7ef51da9e5a83c0b0561c0` |
| Relay `Cargo.toml` | `c88726b7739c35c4fcb42fd511bfe608e478b5d2489729081821fc84cd1b318d` |
| Native `Cargo.toml` | `3180121a89c58071718236a408f36c1c87757d6f9ff81e899fb3b5814c8d4c8e` |
| Transport `Cargo.toml` | `78f582c201082f7badece64f7fa65d215a6694412b7a7699332fa3bc9a4f3743` |
| Native QUIC source | `b0c8dfb3e4963365a3a27f52a84d2fc54292cfc5a056a817a5a0d0a4f38b3723` |
| Setup ALPN module (`setup/mod.rs`) | `c49d71dcacd5e3f5eef7a673e11b9058d3fd701e1fb83331a737098894a2d750` |
| Setup version module | `384772b32812a0761fa55d16a9fd29e30595323ece1b3fca013ec3720eaec4ad` |
| Transport session module | `8e8992e1bb75d77c2475499014509a9362b965162d86156bdf6068a16b3cd2ea` |
| `REUSE.toml` | `afc7fd86e591a56078b11982ee4d039ea1dfe3f9d56a90e3e7fa9f84fbddb6cc` |
| Apache-2.0 text | `1248f876e0140942002b476a19c95d5b5b44c625e69c96611d23119ee87fa04e` |
| MIT text | `c7d191b5901a741f2e39c74bd7a7594014a81fbe2bc7d533d4c29ad4cfe4e057` |

These paths are byte-identical to `HEAD`. No manifest, lockfile, dependency,
feature, `moq-native-ietf`, `moq-transport`, draft-16, `moqt-16`, WebTransport
ALPN, Objects encoding, TLS fixture, license, or active product pin changed.

## Toolchain and validation results

Rust validation used only the local image
`teremoq-local-rust193-components:c2-review-20260828`, image ID
`sha256:f522c28d5beb21591f46e8c165030f70b32dd5b51107577ad196910e7147a007`.
It contains Rust/Cargo 1.93.0, rustfmt 1.8.0-stable, and Clippy 0.1.93.
Every build container used `--network none`, read-only source and Cargo
registry/git caches where compilation permitted, and an external target.

| Command or gate | Result |
| --- | --- |
| `cargo check --locked --offline -p moq-relay-ietf --tests` | PASS. |
| `cargo test --locked --offline -p moq-relay-ietf c2_` | PASS: 27 unit/private C2 tests and 10 integration C2 tests. |
| `cargo test --locked --offline -p moq-relay-ietf` | PASS: 146 library, 16 binary, 10 integration, 1 doctest; 1 doctest intentionally ignored. |
| `cargo clippy --locked --offline --no-deps -p moq-relay-ietf --tests -- -D warnings` | PASS. |
| Focused Rust 2021 rustfmt over all seven C2 Rust paths | PASS. |
| `cargo fmt --all -- --check` | Only the two inherited non-C2 diffs recorded above. |
| `cargo test --locked --offline -p moq-native-ietf c1_` | PASS: 25 C1 tests. |
| `cargo test --locked --offline -p moq-native-ietf` | PASS: 26 tests plus doctests. |
| `cargo test --locked --offline -p moq-transport` | Expected `BLOCKED_BY_BASELINE_E0308` at unchanged `tracks.rs:501`. |
| `git diff --check`, cached check, and no-index checks for every new file | PASS; stage empty. |
| Protected-path comparison to `HEAD` | PASS: manifests, lock, native, transport, wire inputs, REUSE, and licenses unchanged. |
| `cargo package --list --allow-dirty --locked --offline -p moq-relay-ietf` | PASS: 34 entries; all C2 tests, fixtures, inventory, and sidecars are within package root. |
| REUSE 5.1.1 | PASS: 204/204 files; MIT and Apache-2.0; no bad or missing licenses. |
| Gitleaks 8.30.1 on each changed C2 Rust/test path | PASS: no findings. |
| Gitleaks fixture scan | EXPECTED: exactly one fully redacted `private-key` finding for the documented public synthetic test key. |
| C2 fixture PEM and decoded-DER hashes | PASS: all six expected hashes matched. |

A broader, non-gating scan of the full relay `src` directory reports one
inherited marker-only finding in unchanged `src/tls.rs` test documentation.
It is outside the C2 inventory. The exact changed paths were each scanned
separately and are clean.

Supply-chain tools were already present and used without download:

- REUSE `5.1.1`, GPL-3.0-or-later, image digest
  `sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da`;
- Gitleaks `8.30.1`, MIT, image digest
  `sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f`;
- OpenSSL `3.5.5`, Apache-2.0, used only to compare fixture provenance
  without printing key material.

No tool, image, component, crate, or dependency was downloaded or installed.

## Cleanup and final boundary

The worktree contains no source-side `target/`. Validation used `--rm`; no
container based on the C2 review image remains. Temporary command outputs were
removed after extracting redacted gate results.

Only the 15 paths in the inventory above differ in the C2 worktree. In the
Teremoq checkout, the owner replaced only this report. No I1, I2, Q, U1, C1,
product source, dependency, PKI, protocol, or remote state was changed.

## Next gate

Request fresh independent `TP-PLATFORM-CHAOS`, `TP-SEC-PKI`, and applicable
`TP-OSS-SC` review against the exact hashes in this report. Do not commit,
publish, integrate, change product pins, or claim C2/relay readiness before
those reviews and a separate Master authorization.

Final state: **LOCAL ONLY / NOT COMMITTED / NOT PUSHED / READY FOR FORMAL REREVIEW**.
