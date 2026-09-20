<!--
SPDX-FileCopyrightText: 2026 Teremoq contributors
SPDX-License-Identifier: Apache-2.0
-->

# C2 formal TP-PLATFORM-CHAOS rereview

Date: `2026-08-28`

Mode: **READ-ONLY SNAPSHOT REVIEW / NO SOURCE EDIT / NO COMMIT / NO FETCH / NO PUSH / NO PUBLICATION**

## Findings first

### HIGH — an already observable shutdown can still admit the outbound `announce` root

`Relay::run_bounded` constructs the control owners and immediately performs
outbound admission for the optional `announce` root at
`moq-relay-ietf/src/relay.rs:804-865`. The first observation of the caller's
shutdown token does not occur until the main `tokio::select!` at
`relay.rs:899-903`; both admission controllers are closed only after leaving
that loop at `relay.rs:1022-1023`.

Consequently, a token cancelled before `BoundedRelay::run_until` is polled—or
cancelled concurrently by another runtime worker during that first poll—can
already be observable while the code still:

- obtains an outbound permit;
- increments admitted, active, and inflight accounting; and
- inserts the `announce` future into the owned control collection.

The later drain cancels and releases this root, so the final gauges can still
be zero. That does not repair the ordering violation: the binding plan requires
the first shutdown observation to atomically transition admission to
`Stopping`, and requires zero new admission after that point. At minimum the
observable history contains an admitted/cancelled outbound root that should
never have existed. In addition, the first poll of `run_bounded_announce` uses
an unbiased inner `tokio::select!` at `relay.rs:1160-1184`; when the drain first
polls an already-cancelled control future, its connect branch is eligible to be
polled before cancellation wins. The review therefore cannot use final-zero
gauges as proof of zero post-stop work or zero network side effects.

The corrected tests cover stop/admit linearization at the admission primitive,
RemoteManager stop-before-admit, and accept-completion versus shutdown. None
constructs a bounded relay with `announce`, passes an already-cancelled token,
and proves zero outbound admission/dial/task effects. The established and
pending announce tests cancel only after the announce root has intentionally
been admitted.

Required correction: observe the shutdown token and close both controllers
before any startup root can be admitted, with a linearized outcome for a
concurrent first-poll cancellation. Add deterministic cases for (a) a token
cancelled before `run_until` and (b) both barrier-controlled orders of
first-poll cancellation versus announce admission. The stop-first case must
show zero admitted/rejected/terminal counters, zero active/inflight gauges,
zero dial and task effects, and no peer accept; every wait must reuse one
absolute watchdog. This is a lifecycle ordering correction, not permission to
change limits or weaken shutdown assertions.

### Baseline blocker — WR-03 remains exactly `BLOCKED_BY_BASELINE_E0308`

`moq-transport/src/serve/tracks.rs` remains protected and byte-identical with
SHA-256
`a8303c94925707a0a257923725bf84e4ec730b07d6bb2330fda5329b632fe0b7`.
An independent Rust 1.93.0 run reproduced only the inherited mismatch at line
501 (`TrackName` versus `&str`) while compiling the package test. This is not a
C2 regression, not a pass, and not absorbed into the verdict above.

### Residual scope — C2 is not a process-memory or DoS bound

The inspected implementation bounds inbound and outbound session roots. It
does not bound `Remote::tracks`, Producer/Consumer request collections, or all
`UpstreamNamespaces` queues/maps. No memory, process-wide, DoS-resistance,
production-readiness, fairness, capacity, or SLO claim is approved by this
review.

## Verdict

**CHANGES REQUIRED**

The verdict applies only to the frozen local C2 snapshot. It does not authorize
a local commit, C3, integration, publication, push, release, deployment, or any
remote mutation.

## Binding and independently reproduced identity

All binding values and every owner-provided path hash were reproduced before
review. No divergence was found.

| Item | Independently observed value |
| --- | --- |
| Worktree | `/home/jimbomilk/moq-rs-teremoq-c2-work` |
| Branch | `teremoq/c2-session-shutdown-ee22a10` |
| HEAD/base | `ee22a1079783e374371e0705775978790ddd6471` |
| Base tree | `232e449945e877b024f2fc4223f0d2eea124b39b` |
| Staging area | empty (`0` output bytes) |
| Exact changed/untracked routes | `15` |
| Full status inventory SHA-256 | `41969b3ff7d7ebcaaf891137a17519a2097319642b6753db144a0b5a000db614` |
| Owner report SHA-256 | `1fdc354f8dc8818e853b17dd59318d1d2c90fe85e371cfda37f80a04bd1da0e2` |
| TP-PLATFORM-CHAOS plan SHA-256 | `550e52ec87cb4d1c10a76ca61d640723eb2fb36e7a3438914184ad30ed6cf1ab` |
| Previous TP-PLATFORM-CHAOS review SHA-256 | `f3d5bdf6eba57d67b8839e29072f36638c347ccbb4d67dc2762b4b3ad97b2f79` |
| Previous TP-SEC-PKI review SHA-256 | `c188c80b64fbfd65652ba6ec0f042f2deaf42d65e7dfe06f5e060547f89393ab` |

### Exact 15-path inventory

| Path | SHA-256 |
| --- | --- |
| `moq-relay-ietf/src/lib.rs` | `af994bc136fafa97b0a6faa15645811fc1f04b8d03851702f3fa48d38fbb0253` |
| `moq-relay-ietf/src/relay.rs` | `67dad064d0b13d39bb6bd8ef9b81557ce291f48db76cda98ff476f1b270735e4` |
| `moq-relay-ietf/src/relay_c2_tests.rs` | `713ac2151be6233ff3bc6b7a1cf68242f85d8812198c511f2fa3c64df1a403a5` |
| `moq-relay-ietf/src/remote.rs` | `f462286d1c8b9fc0b5eb3b478400c97ffc064d90270f899fea9bf80235114fdc` |
| `moq-relay-ietf/src/session_admission.rs` | `cc5c56db172f7fb13e1f5a1a8bea3957c096d869dd97ac3f9d9f753820f0c7ef` |
| `moq-relay-ietf/src/upstream_namespaces.rs` | `7033823b66d5e3e82c0e6afdf2e4062080b908ed11c0aedb4550bd2f7cd775b9` |
| `moq-relay-ietf/tests/c2_session_admission.rs` | `1b528da9ccd852d81085bad190e01ae9a5a84ca6724574ed6a7cd2904e7e0a0a` |
| `moq-relay-ietf/tests/data/c2/README.md` | `285e4e178ecd6a7c5cffe5409107bc11bdf096bba9ebc014e805c0b991c1ae72` |
| `moq-relay-ietf/tests/data/c2/SHA256SUMS` | `ccc4d9cbcc23c31cfd12e2ef5d0a57e6d0901c243f7a732fc6eba20a7c82c8fd` |
| `moq-relay-ietf/tests/data/c2/ca.cert.pem` | `c439d7428d418762e090e1ce0fdda1524473daa66f052da251e120d78555dfbb` |
| `moq-relay-ietf/tests/data/c2/ca.cert.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-relay-ietf/tests/data/c2/server.cert.pem` | `76fe11a03423308533516c61c8e06f994746293313ef8961091de0e87cbd2b09` |
| `moq-relay-ietf/tests/data/c2/server.cert.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-relay-ietf/tests/data/c2/server.key.pem` | `607642c80b7ec6e365ef877e24c526ca546542fb5c330ae191891a212b67aa35` |
| `moq-relay-ietf/tests/data/c2/server.key.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |

Protected workspace, manifests, lockfile, C1 native QUIC source, draft-16
setup/session source, Objects source, and license texts also reproduce their
owner hashes. No manifest, lockfile, dependency, ALPN, draft, native transport,
wire format, Object, or license change is present.

## Closure of the previous formal findings

| Previous finding | Rereview result | Independent evidence |
| --- | --- | --- |
| Empty `RemoteManager` slots survive cancellation | CLOSED | `RemoteSlotReservation` owns the exact newly published slot generation and removes it synchronously on drop only if `Arc::ptr_eq` still identifies that generation. Four distinct real pending setups are cancelled; cardinality, capacity, and one-terminal accounting recover after each, followed by successful setup. |
| Focal formatting and Clippy fail | CLOSED | Focal Rust 2021 rustfmt passes on all seven C2 Rust paths. Relay Clippy with tests and `-D warnings` passes. No `allow`/`expect` blanket lint attribute exists in the changed Rust paths. |
| Test waits lack one absolute watchdog | CLOSED | C2 helpers receive their caller's absolute deadline; polling loops and spawned-task joins are enclosed by `timeout_at`; the source guard forbids helper deadline reset. No timing sleep is used as C2 synchronization. |
| RACE-01/RACE-02/SD-08 are only serial state checks | CLOSED | The corrected tests use separate Tokio tasks plus one-shot ordering to force both controlled outcomes. Release/admit produces success only in release-first and immediate capacity only in admit-first; terminal/shutdown produces exactly one classified terminal in both orders. |
| Stop versus admission was not linearized | CLOSED for the admission primitive and established relay loop; new startup finding remains | `Semaphore::close` is the linearization point, `try_acquire_owned` returns typed `Closed`, and the accept/shutdown barrier prevents inbound admission after observed stop. The pre-main-loop `announce` path remains outside that protection as described above. |

## Full C2 matrix

| Gate | Result | Evidence or limitation |
| --- | --- | --- |
| Static inbound ordering | PASS | Native accept result, shutdown check, and one nonblocking `try_admit` precede metrics, root future, MoQT setup, mlog, tagger, Coordinator, Producer/Consumer, and namespace work. |
| Admission/requeue ordering | PASS | Capacity close occurs before endpoint requeue; admitted permit/root ownership occurs before requeue. No semaphore capacity await or permit waiter exists. |
| Global inbound N/N+1 | PASS | Real Raw QUIC and WebTransport tests retain N=2 and reject N+1 immediately; one controller is shared across endpoints. |
| Multiple endpoints | PASS | Two real endpoints share a single N=2 controller; excess Raw and WebTransport attempts do not multiply capacity. |
| Finite overload M=32 | PASS | N remains retained while all 32 excess real native connections reach capacity disposition; peak/high-watermark remains N and no state sentinel fires. |
| MAX/MAX+1 | PASS | Exact `Semaphore::MAX_PERMITS` is accepted; MAX+1 on either public limit returns a typed error before semaphore construction and without panic. |
| Permit ownership and terminal equation | PASS | The non-cloneable guard owns one permit; `Option::take` makes release exactly once; active/inflight and capacity release precede terminal publication. Mixed terminals satisfy the equation and zero gauges. |
| Setup/run error, cancellation, unwind, owner drop | PASS | Real setup failure/recovery, established close, cancellation/drop, injected setup/run panic, and forced drop release capacity once. Panic is non-success. |
| Remote reservation cancellation safety | PASS | Exact slot identity/generation is protected by RAII; repeated distinct-key cancellation restores original map cardinality and admits a later real setup. |
| No admission after `Stopping` | FAIL at startup `announce` seam | Closed semaphore behavior and post-accept barrier pass, but `announce` admission precedes the first shutdown-token observation. |
| Deterministic concurrency races | PASS for implemented race seams | Stop/admit, release/admit, terminal/shutdown, observer/terminal, and accept/shutdown have controlled orderings and shared watchdogs. The startup announce race is missing. |
| Real N+1 wire disposition | PASS | Official QUINN/WebTransport plus official MoQT CLIENT_SETUP encoder are used. Both routes observe exact code `0x3`, reason `relay session capacity reached`, and no SERVER_SETUP. No arbitrary UDP is used. |
| N+1 state-effect sentinels | PASS for saturated inbound seam | Isolated mlog stays empty; tagger/Coordinator counters remain zero; `Locals` namespace/track probes remain empty; admitted/root counts stay at N. This does not cover the new pre-cancelled announce seam. |
| Outbound global bound | PASS once bounded run is active | One separate global controller covers singleton announce and distinct Remote roots; same-key Remote callers share one permit/connection. No inbound/outbound capacity aliasing occurs. |
| Outbound lifecycle ownership | PASS once admitted | Pending/established announce, Remote roots, cleanup futures, and upstream pull futures are owned and drained/dropped by bounded mode. The only added detached spawn is confined to the explicitly legacy unbounded branch. |
| Shutdown deadline | PASS after the main loop observes shutdown; FAIL for first-observation ordering | One absolute deadline covers cancellation, cooperative drain, and forced drop with no post-deadline await. Startup work can precede the first token observation. |
| Final gauges/report | PASS for executed paths | Inbound/outbound active and inflight gauges are zero and capacity restored before successful return; terminal totals are exact in the exercised vectors. |
| Low-cardinality monitoring | PASS | Schema version is fixed; counters/gauges contain no peer IP, CID, SNI, URL, path, namespace, certificate, identity, principal, or raw remote error labels. |
| C1 retained composition | PASS | Both public C1 controllers return pending zero and satisfy their terminal equations after C2 shutdown; 25/25 C1 tests pass independently. |
| Raw QUIC/WebTransport/draft-16 | PASS for compatibility exercised | Real routes and MoQT setup execute; protected ALPN, draft-16 setup/session, native QUIC, and Objects sources are unchanged. |
| Exact mid-TLS C1 shutdown | `UNTESTABLE_EXACT_MID_TLS_WITH_C1_PUBLIC_API` | Retained accurately; no post-connect sleep or UDP substitute is claimed. |
| WR-03 Objects package regression | `BLOCKED_BY_BASELINE_E0308` | Protected hash matches and the independent package test reproduces only line-501 E0308. |
| Child allocation/process bound | GAP / NO CLAIM | Session-root capacity does not bound every child collection or process memory. |

## Tooling provenance

Only the authorized local image was used:

```text
tag:    teremoq-local-rust193-components:c2-review-20260828
image:  sha256:f522c28d5beb21591f46e8c165030f70b32dd5b51107577ad196910e7147a007
parent: sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57
```

Its immutable tool binaries report:

```text
rustc 1.93.0 (254b59607 2026-01-19)
cargo 1.93.0 (083ac5135 2025-12-15)
rustfmt 1.8.0-stable (254b59607d 2026-01-19)
clippy 0.1.93 (254b59607d 2026-01-19)
```

Every validation container used `--network none` and mounted the C2 source
read-only. Registry and git caches were mounted read-only. Build products went
to the dedicated external volume
`teremoq-c2-rereview-target-20260828`, removed after validation.

The first focal test invocation reached no C2 test: Cargo selected the rustup
proxy for `rustc`, which attempted a channel metadata sync and failed because
networking was disabled. The corrected invocation set `RUSTC` and `RUSTDOC`
to the already installed immutable 1.93.0 binaries. No download occurred, and
the corrected test run passed. This invocation error is not counted as a test
failure or a tooling blocker.

## Commands and independently observed results

| Validation | Result |
| --- | --- |
| `.cursorrules` and binding reports read completely | PASS; required hashes match |
| HEAD/tree/branch/stage/status reconstruction | PASS; exact binding reproduced |
| SHA-256 of all 15 paths | PASS; every owner hash reproduced |
| Protected source/manifests/lock/license hashes | PASS; C1 and baseline inputs unchanged |
| Full tracked diff plus every untracked path inspected | PASS for scope; HIGH finding applies |
| `git diff --check` | PASS |
| Per-untracked-file `git diff --no-index --check` | PASS |
| Search for blanket `#[allow(...)]`/`#[expect(...)]` in changed Rust | PASS; none found |
| Focal `rustfmt --edition 2021 --check` on seven C2 Rust paths | PASS |
| `cargo fmt --all -- --check` | Inherited-only FAIL: unchanged `moq-transport/src/serve/subgroup.rs:934` and `tracks.rs:304`; no C2 path reported |
| `cargo clippy --locked --offline --no-deps -p moq-relay-ietf --tests -- -D warnings` | PASS |
| `cargo test --locked --offline -p moq-relay-ietf c2_` | PASS: 22/22 unit plus 10/10 integration; 32/32 focal C2 |
| `cargo test --locked --offline -p moq-relay-ietf` | PASS: 141/141 library, 16/16 binary, 10/10 integration, 1/1 executed doc test; 1 doc test ignored; 0 failed |
| `cargo test --locked --offline -p moq-native-ietf c1_` | PASS: 25/25; 1 filtered |
| `cargo test --locked --offline -p moq-transport` | `BLOCKED_BY_BASELINE_E0308`, exit 101 at protected `tracks.rs:501` |

The full relay package therefore executed 168 passing tests, zero failures,
and one ignored doc test. The 32 focal C2 tests are a subset of that full run,
not additional unique tests.

## Cleanup and isolation

- No validation container named `teremoq-c2-rereview-*` remains.
- The dedicated target volume was removed and is absent.
- The source worktree remained read-only to all validation containers.
- Final HEAD, tree, empty stage, all 15 hashes, and status inventory SHA-256
  still match the binding after validation.
- No source, manifest, lockfile, fixture, existing report, service, remote,
  branch, stage, commit, tag, issue, pull request, or publication was mutated.

## Required next rereview entry condition

Close the pre-observed/concurrent startup shutdown versus `announce` admission
race, add both deterministic ordering regressions under one absolute watchdog,
and provide a newly frozen 15-path-or-explicitly-revised inventory. Preserve
WR-03 as `BLOCKED_BY_BASELINE_E0308` while its protected source remains
byte-identical. A later review must not infer process memory, DoS resistance,
or production readiness from the root-session limits.

The final SHA-256 of this report is computed after writing and supplied in the
review handoff; embedding a file's own full digest in that same file would be
self-referential.
