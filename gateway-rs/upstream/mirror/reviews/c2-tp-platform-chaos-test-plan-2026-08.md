<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# C2 TP-PLATFORM-CHAOS formal test plan

Status: **LOCAL TEST PLAN ONLY / C2 NOT IMPLEMENTED / NOT AUTHORIZATION**

Date: `2026-08-28`.

This is the binding concurrency, lifecycle, and real-transport review plan for
C2. It does not edit or authorize an implementation, commit, branch, push,
publication, issue, pull request, integration pin, C2 claim, or remote action.
It does not approve production capacity, denial-of-service resistance,
Zero-Trust completion, or relay readiness.

## Findings from the immutable source

### High — the current inbound relay session collection is unbounded

At the immutable C1 base, `moq-relay-ietf/src/relay.rs:193` creates a
`FuturesUnordered` used for relay-owned work. Each accepted transport is
requeued at lines 303-310 and a new connection future is pushed at lines
337-469. There is no immediate established-session admission check. The future
is created before MoQT setup at line 347 and lives through `Session::run` at
line 450. C1 bounds transport establishment in `moq-native-ietf`; it does not
bound this separate relay phase.

### High — outgoing session ownership is outside the inbound accept loop

Two outgoing paths bypass any inbound C2 admission point:

1. `RelayConfig::announce` creates zero or one operator-configured connection
   at `relay.rs:206-271`, performs QUIC and MoQT setup before inbound accepts
   start, creates Producer and Consumer, and pushes its session into the relay
   task collection.
2. `RemoteManager` stores one slot per `(Url, Option<SocketAddr>)` in an
   unbounded `HashMap` (`remote.rs:23-28,48-56,417-475`). Each distinct key can
   establish a full bidirectional relay session, then `Remote::connect` starts a
   detached Tokio task at `remote.rs:680-714`. No explicit maximum or owned join
   handle exists.

C2 cannot call a limit “relay-global” or claim all relay sessions/process tasks
bounded unless these paths either share an explicit global controller or have
separate, explicit, tested bounds and shutdown ownership. If the implementation
leaves `RemoteManager` unchanged, it must publish
`C2-GAP-OUTBOUND-REMOTE-UNBOUNDED` and use names such as
`active_inbound_sessions`; the full relay-global C2 contract then remains
`CHANGES REQUIRED` unless the Master explicitly accepts that narrowed scope.

### Medium — child work remains a distinct, pre-existing bound problem

`Session::run` creates a finite root set per session, but Producer and Consumer
each maintain request-driven `FuturesUnordered` collections. `Remote::tracks`
and local caches are keyed by peer-controlled names. `UpstreamNamespaces` uses
an unbounded MPSC channel plus `HashMap`/`VecDeque` state
(`upstream_namespaces.rs:63-72,127-149,294-308`). The Consumer has a 1024
inbound-PUBLISH-track semaphore, but that does not bound every namespace,
subscribe, remote-key, or deferred-command path.

A global session root limit is still valuable, but it does not prove memory or
task boundedness inside one malicious admitted session. C2 tests must not make
that broader claim. These collections require separate limits or recorded gaps
under their owning follow-up scope; thresholds must not be weakened to hide
them.

### Medium — exact C1 mid-handshake shutdown remains unavailable to C2 tests

C1's deterministic stage hook is private under `cfg(test)` inside
`moq-native-ietf`; it is not available when that crate is a dependency of
`moq-relay-ietf`. The pinned public client cannot deterministically pause at an
exact mid-QUIC/TLS instruction. C2 must not add a public native callback, a
direct QUINN dependency, or raw UDP to fake this state.

The conservative composition evidence is: retain explicit C1 admission
controllers in the C2 fixture, drop every relay-owned native Server/accept
future on shutdown, assert all observable C1 gauges are zero afterward, and
cite C1's independent Server-drop tests. A black-box connect/shutdown race is
useful additional evidence but is not labelled an exact mid-TLS test.

## Immutable base

C2 starts only from this reviewed C1 commit:

```text
commit ee22a1079783e374371e0705775978790ddd6471
tree   232e449945e877b024f2fc4223f0d2eea124b39b
parent bf87128affd316463e5dcc7599a45001f222b6de
title  feat(native): bound pending handshakes
```

The C1 commit contains exactly its reviewed ten `moq-native-ietf` paths and no
relay delta. A C2 implementation must be reviewed as a delta from the full C1
commit ID, never from a moving branch name. Rebase, baseline rewrite, manifest,
lockfile, `moq-transport`, `moq-native-ietf`, wire, fixture, license, or new
dependency changes invalidate this plan.

Relevant immutable source hashes:

| Path at C1 | SHA-256 |
| --- | --- |
| `moq-relay-ietf/src/relay.rs` | `e0dd6c18b0d5c80dd73dafe4e7366495f4c9fbe2efee9138f210392c48604b9b` |
| `moq-relay-ietf/src/remote.rs` | `79a4c54811b0dbafb05f12578ccc210bcebafbcc1e1cebcbe067307f7fa7a63a` |
| `moq-relay-ietf/src/session.rs` | `62f162dc54808d6859629862dd22a33c41312466f6d7a0bdf1b9e0a4f2ce5fb2` |
| `moq-relay-ietf/src/producer.rs` | `4f4c5015a84077e3bbe27526e85e53ffe0cf36a45616ffe5d1acb5db47634951` |
| `moq-relay-ietf/src/consumer.rs` | `3cac7ec17f0d34352a099f5d3a288adcbce567c5b5f3ef99e075b6ac216a1a44` |
| `moq-relay-ietf/src/upstream_namespaces.rs` | `91c7e29ee95eea9425b792d197ac95c67bea9b9e77c4ef20022737a08e8f89fc` |
| `moq-relay-ietf/Cargo.toml` | `c88726b7739c35c4fcb42fd511bfe608e478b5d2489729081821fc84cd1b318d` |
| `Cargo.lock` | `b518a2fa4a6d7a0ffe0bdfe4b530f05196ac0f5e6f7ef51da9e5a83c0b0561c0` |

The final C1 reviews approve only the exact C1 commit. C1-WR-03 remains
`BLOCKED_BY_BASELINE_E0308` at unchanged
`moq-transport/src/serve/tracks.rs:501`; C2 must keep that baseline failure
separate from any C2 regression.

## Required C2 contract

### Additive API and configuration

Names are illustrative; ownership and behavior are binding. Preserve public
`RelayConfig` struct literals and existing `Relay::new`/`Relay::run` behavior.
Add a bounded constructor/wrapper rather than a required field:

```text
RelayAdmissionConfig::new(max_sessions, shutdown_timeout) -> Result
Relay::new_bounded(config, admission_config) -> Result<BoundedRelay>
BoundedRelay::run_until(shutdown_token) -> Result<ShutdownReport>
```

The bounded constructor fails closed for zero timeout, monotonic deadline
overflow, zero limits, a session limit above
`tokio::sync::Semaphore::MAX_PERMITS`, or inconsistent shared controllers. It
must never silently choose the legacy path. Existing Tokio, tokio-util,
futures, and metrics dependencies are sufficient; no manifest/feature change
is permitted.

`MAX_PERMITS` is accepted without allocating one object per permit.
`MAX_PERMITS + 1` returns a typed, non-sensitive configuration error from every
public construction route and never reaches Tokio's panicking semaphore
constructor.

### Exact inbound admission seam

For every result yielded by the existing fixed-size per-endpoint accept set:

1. recover the accepted `(web_transport::Session, quic::ConnInfo)`;
2. immediately call a non-waiting operation equivalent to
   `try_acquire_owned` on the one relay-global inbound controller;
3. on saturation, close that existing transport with an already legal
   application-close mechanism and a fixed non-sensitive code/reason;
4. do not push/spawn a future, start MoQT `Session::accept`, create an mlog
   session path, call the coordinator, construct Producer/Consumer, register or
   look up a namespace/track, mutate Locals, or touch forwarding state;
5. only after admission create one owned session-root future; and
6. move one non-cloneable RAII permit/gauge guard into that future before MoQT
   setup, retaining it through setup, authorization/scope work, Producer and
   Consumer lifetime, `Session::run`, terminal classification, cancellation,
   unwind, and drop.

Requeuing one accept future per endpoint remains bounded by endpoint count and
is not a session waiter. Once shutdown is observed, no accept is requeued and
any simultaneously delivered connection is closed without admission.

No `Semaphore::acquire().await`, `acquire_owned().await`, retry loop, channel,
task, or future may wait for session capacity. Saturation is an immediate
terminal outcome.

### Session-root ownership

Keep inbound session roots in a dedicated owned collection, separate from the
fixed endpoint accepts, the singleton upstream-namespace runner, announce, and
outgoing remotes. A direct owned `FuturesUnordered` is acceptable and makes
forced drop synchronous. A `JoinSet` is acceptable only if the implementation
proves that abort and join complete inside the same shutdown deadline and that
no detached task can retain a permit.

One session guard publishes exactly one terminal reason:

```text
clean_close | setup_error | run_error | cancelled | panicked | forced_shutdown
```

Permit release and gauge decrement happen before the terminal counter becomes
observable. A terminal bit prevents double release/counting. An unwind must
drop the guard. A panic may remain a fatal local invariant that initiates relay
shutdown; C2 does not require continuing after corrupted local state, but it
does require zero leaked capacity and a non-success result.

### Snapshot and metrics

Expose a schema-versioned snapshot backed by atomics/controller state, not by a
public callback:

```text
schema_version
limit
active_inbound_sessions
inflight_inbound_futures
admitted_total
rejected_capacity_total
clean_close_total
setup_error_total
run_error_total
cancelled_total
panicked_total
forced_shutdown_total
shutdown_state
```

The terminal invariant after quiescence is:

```text
admitted_total = clean_close_total + setup_error_total + run_error_total
               + cancelled_total + panicked_total + forced_shutdown_total
active_inbound_sessions = 0
inflight_inbound_futures = 0
```

During execution, the right-hand terminal sum plus active sessions equals
admitted total. Rejected capacity never increments admitted or any admitted
terminal.

Metric/event labels are fixed enums only. Do not use remote/local address,
connection ID, URL, path, namespace, SNI, certificate, identity, role,
principal, coordinator error text, or raw peer error as a label. Do not expose
an embedder callback that can block or panic the accept loop. Existing logging
is outside this new metric contract; new C2 events use fixed reasons and
redacted text.

### One absolute shutdown deadline

When the caller's shutdown token first resolves, calculate exactly one
`tokio::time::Instant` deadline from the validated duration and transition
atomically from `running` to `stopping`:

1. stop and drop every endpoint accept future/Server so no new transport can be
   admitted and C1 RAII can release pending handshakes;
2. close/cancel active inbound sessions and all relay-owned background/outbound
   work in the declared C2 ownership scope;
3. drain cooperative completions while always using the original absolute
   deadline;
4. at that deadline mark the remaining roots forced and synchronously
   abort/drop their futures and guards;
5. perform endpoint-idle, announce, RemoteManager, and other cleanup only
   inside the remaining time, never by starting another timeout budget; and
6. return only after every owned lifecycle/session gauge is zero and the
   `ShutdownReport` records clean, cancelled, and forced counts.

If a collection or detached task cannot be joined/dropped under this contract,
it is a blocker or a named gap; the implementation must not return success with
an `unknown` or stale gauge. Peer cooperation is never required for shutdown.

## Deterministic test seam

Tests live in the relay crate and use real `moq_native_ietf` QUIC clients over
loopback with port `0`. Raw QUIC uses the existing MoQT ALPN; WebTransport uses
the existing WebTransport ALPN. No arbitrary UDP, direct QUINN dependency,
packet reimplementation, new crate, external network, Docker, or sleep-based
synchronization is allowed.

A private `cfg(test)` hook may expose fixed stages:

```text
transport_received
session_permit_acquired
moqt_setup_started
moqt_setup_completed
coordinator_started
producer_created
consumer_created
session_run_started
session_terminal
shutdown_observed
accepts_stopped
drain_started
force_drop_started
shutdown_complete
```

The hook is absent from public/production APIs. Stage delivery uses a bounded
channel with `try_send`, or fixed atomics/Notify; it never blocks the relay and
never retains transport/session/payload objects. Test barriers use a semaphore
or one-shot release owned by the harness. No public synchronous callback or
unbounded event channel is acceptable.

Every logical test wait, including event receive, snapshot polling, connection,
MoQT setup, task join, close observation, cancellation, drain, and cleanup, is
wrapped by one generous absolute `timeout_at(test_deadline, ...)`. A helper must
reuse the same deadline across unexpected events or polling iterations. Nested
relative timeouts cannot reset the budget. `tokio::time::sleep` is forbidden as
synchronization. Paused Tokio time plus explicit `advance` may drive a pure
deadline test only after a deterministic barrier proves the state being timed.

Real clients can deterministically occupy C2 capacity without pretending to be
slow TLS: complete `moq_native_ietf::Client::connect`, retain the returned raw
or WebTransport session, and deliberately do not begin MoQT setup. This is
named **delayed MoQT setup**, not pending QUIC/TLS.

## Core test matrix

For every row, any wait not explicitly described still uses the shared absolute
test watchdog.

| ID | Precondition | Deterministic mechanism | Required event/assertion | Final state | Bug prevented |
| --- | --- | --- | --- | --- | --- |
| C2-CFG-01 | Bounded config with zero/overflow shutdown duration | Construct directly; no network | Typed fail-closed error; Relay not started | All gauges/counters zero | Legacy fallback or unusable deadline |
| C2-CFG-02 | Session limit exactly `Semaphore::MAX_PERMITS` | Construct controller/config and bounded Relay | Construction succeeds without panic or per-permit allocation | Limit snapshot equals MAX; active zero | Off-by-one rejection |
| C2-CFG-03 | Session limit `MAX_PERMITS + 1` | `catch_unwind` around every public construction route | Typed excessive-limit error, never panic | No controller/task/socket retained | Tokio semaphore panic |
| C2-ADM-01 | One endpoint, inbound N=2, Raw QUIC | Two real clients finish native connect and stop before MoQT setup; wait for two permit events; start N+1 | N+1 capacity rejection occurs before setup/task/state events | Active=N, inflight=N, rejected=1; no waiter | Unbounded root future or hidden waiter |
| C2-ADM-02 | One endpoint, inbound N=2, WebTransport | Same as ADM-01 over existing WebTransport client path | Same immediate rejection and unchanged ALPN/CONNECT | Active=N, inflight=N; N+1 closed | Transport-specific admission bypass |
| C2-ADM-03 | Two endpoints, one relay-global N=2 | Occupy one slot through each endpoint, then attempt N+1 on both in controlled order | Both excess attempts reject; endpoint count does not multiply limit | Peak active exactly 2; inflight exactly 2 | Per-endpoint session semaphore accident |
| C2-ADM-04 | Mixed Raw/WT across three endpoints | Barrier after N permit events; burst M>N | All M-N reject before any task/setup event and before barrier release | Waiter count structurally zero; peak never >N | Select bias, queue, or transport starvation |
| C2-ORD-01 | N admitted clients held before setup plus N+1 | Test hook and coordinator/Locals sentinels keyed by test ordinal | Rejected ordinal has no `moqt_setup_started`, coordinator, Producer, Consumer, run, or namespace event | Only N admitted roots exist | Admission placed after expensive/stateful work |
| C2-ORD-02 | Saturated relay still accepting endpoints | Keep N roots blocked, submit finite burst, observe all rejection counters before release | One fixed accept future per endpoint continues; no rejection waits | Accept collection equals endpoint count | Accept starvation or collection growth |
| C2-REC-01 | One fully established session and one queued attempt made only after close | Complete draft-16 setup, then perform clean client close | `clean_close` published after permit release; next client admitted | Active returns 0 then 1; exactly one clean terminal | Permit leak on normal close |
| C2-REC-02 | Admitted transport paused before MoQT setup | Close/drop real native client session, then release server setup barrier | `setup_error` once; no coordinator/Producer/Consumer | Active/inflight zero; next client progresses | Setup-error leak/state touch |
| C2-REC-03 | Draft-16 setup complete, session running | Use existing application close with non-graceful legal code or test-owned typed run failure after run barrier | `run_error` once and capacity immediately reusable | Active/inflight zero | Run-error leak or misclassification |
| C2-REC-04 | Admitted root blocked before setup | Cancel that root through relay-owned token | `cancelled` once, no later setup/state event | Active/inflight zero; next client progresses | Cancellation before first await leaks |
| C2-REC-05 | Established root blocked in run | Cancel after `session_run_started` | Run future dropped, `cancelled` once | Active/inflight zero | Steady-session cancellation leak |
| C2-REC-06 | Test-only panic after permit at setup and run barriers | Wrap relay run future at test boundary with `FutureExt::catch_unwind`, or inspect tracked Join error if implementation isolates tasks | Panic is non-success; guard releases before `panicked` observation; no double terminal | Every owned gauge zero after unwind/drop | Permit leak or silent panic success |
| C2-REC-07 | Active setup and run roots; external owner retained for snapshots | Drop the Relay run future/BoundedRelay without shutdown completion | All root futures and permits drop synchronously | Active/inflight zero; weak ownership has no cycle | Detached root/task after owner drop |
| C2-RACE-01 | N full and one close can race one N+1 arrival | Gate close terminal and capacity attempt on explicit one-shot order, run both orders | Exactly one deterministic outcome per order; at most N active | Terminal equation holds; no underflow | Check-then-act admission race |
| C2-RACE-02 | Setup/run terminal races cancellation | Release both branches through test-controlled poll seam, repeat finite cases | One terminal wins; loser cannot increment or release again | Active zero; admitted equation exact | Double decrement/double counter |
| C2-RACE-03 | Accept completion races first shutdown observation | Hold at `transport_received`, signal shutdown, then release | No permit/task/setup created after stopping; connection closed | Active/inflight zero | Session admitted after shutdown |
| C2-WAIT-01 | N full, finite overload M=32 | Observe all M-N rejections while N barrier stays closed | Rejections complete without releasing N and without elapsed-time success threshold | Active=N, inflight=N, rejected=M-N | Semaphore waiter queue disguised as cap |
| C2-MET-01 | Exercise all terminal/rejection reasons | Snapshot after each barrier and capture metric keys/labels | Fixed schema/reasons; release-before-terminal; terminal equation at every quiescent point | All gauges zero at end | Sensitive/high-cardinality labels or underflow |

## Shutdown matrix

| ID | Precondition | Deterministic mechanism | Required event/assertion | Final state | Bug prevented |
| --- | --- | --- | --- | --- | --- |
| C2-SD-01 | Bounded relay idle on multiple endpoints | Signal token after `running` snapshot | `shutdown_observed -> accepts_stopped -> shutdown_complete` in order | Accept/session/background gauges zero | Idle shutdown hang |
| C2-SD-02 | N clients held in delayed MoQT setup | Signal shutdown after N permit events | Accepts stop, roots cancel/drop before one deadline, no coordinator/state touch | C1 observable pending zero; C2 active/inflight zero | Setup peers blocking shutdown |
| C2-SD-03 | N established Raw/WT sessions, cooperative clients | Signal shutdown then let clients observe close | Cooperative sessions drain within the original deadline | Clean/cancel counts exact; gauges zero | Deadline reset per session |
| C2-SD-04 | One session-root future remains `Pending` after cancellation | Pure lifecycle seam; paused time, barrier, advance exactly to absolute deadline | `force_drop_started`; future/guard synchronously dropped; report forced=1 | Active/inflight zero before return | Non-cooperative peer/task outliving shutdown |
| C2-SD-05 | Mix setup error, run close, cancellation, and forced root | Release terminal barriers in explicit order around shutdown | Each admitted root gets one terminal, never rejection terminal | Terminal equation exact; all gauges zero | Race-dependent double terminal |
| C2-SD-06 | Accept future owns each native Server; explicit C1 controllers retained | Start real connect attempts, observe only public C1 snapshots, signal C2 shutdown | Relay drops accepts/Servers; any observable C1 pending returns zero | All retained C1 controller gauges zero | Native Server leaked by relay shutdown |
| C2-SD-07 | Exact mid-TLS state requested | Inspect pinned public API; do not add a substitute | Record `UNTESTABLE_EXACT_MID_TLS_WITH_C1_PUBLIC_API`; cite C1 drop coverage | No false pass; cleanup zero | Raw UDP/post-connect sleep mislabelled TLS |
| C2-SD-08 | Shutdown and terminal occur at same test poll seam | Run both deterministic orderings with one absolute deadline | Either terminal or shutdown reason wins exactly once | No underflow; all zero | Same-poll ownership race |
| C2-SD-09 | Drop bounded relay before run and after failed startup | Constructor failure/test owner drop | No background task, endpoint, permit, or map outlives owner | All lifecycle gauges zero | Failed-start task leak |

## Outgoing inventory and tests

The implementation report must include this inventory even if no outgoing code
is changed:

| Source | Immutable behavior | Required C2 disposition |
| --- | --- | --- |
| `RelayConfig::announce` | `Option<Url>` gives cardinality 0/1; QUIC/MoQT setup occurs before inbound accept loop; session is placed in general tasks | Own it under shutdown. Prefer one shared outbound controller with RemoteManager. If separate, expose `active_announce_sessions` and prove max 1, cancellation during QUIC/setup/run, and zero before shutdown returns. |
| `RemoteManager::remotes` | Unbounded distinct-key `HashMap`; same key serialized by slot lock; each connected Remote starts a detached task | Add an explicit relay-global outbound limit with non-waiting acquisition before `Remote::connect`, deduplicate same key, retain owned join/drop handles, and test shutdown; otherwise declare `C2-GAP-OUTBOUND-REMOTE-UNBOUNDED` and reject any all-session/global-process claim. |
| `Remote::tracks` cleanup | Per-remote key map and cleanup task per track | Out of core session-root C2 unless explicitly bounded. Record as child-work gap; never use session N as proof this is bounded. |
| `UpstreamNamespaces` | Singleton runner but unbounded command channel/deferred/maps and spawned pull tasks | Own/cancel runner in shutdown; record channel/state gap unless separately bounded. No process-wide bounded-memory claim. |
| Producer/Consumer request futures | Request-driven collections below one admitted session | Session-root count does not bound per-session children. Record exact existing limits and missing limits; no C2 capacity claim for them. |

Outgoing test cases:

| ID | Precondition | Deterministic mechanism | Required event/assertion | Final state | Bug prevented |
| --- | --- | --- | --- | --- | --- |
| C2-OUT-01 | Announce configured, peer holds QUIC/MoQT setup | Real upstream endpoint plus setup barrier; signal shutdown | Startup/setup observes same shutdown deadline; no inbound accept starvation or indefinite await | Announce/lifecycle gauge zero | Announce blocks shutdown/start forever |
| C2-OUT-02 | Announce established | Complete real draft-16 session then shutdown | Owned announce root closes/drains/forces within same deadline | Announce gauge zero | General task collection hides outbound root |
| C2-OUT-03 | Outbound limit N and N distinct Remote keys | Deterministic coordinator returns N+1 real loopback relay destinations | N roots connect; N+1 returns typed capacity error without waiter/connect/task/cache residue | Outbound active=N; rejected=1 | Distinct-key Remote flood |
| C2-OUT-04 | Concurrent callers request the same Remote key | Gate slot creation/connect and interleave callers | Exactly one outbound session/permit; callers share result | Active outbound=1 | Duplicate connect race |
| C2-OUT-05 | Outbound setup/run error and cache removal | Real peer closes at each barrier | Permit releases once, slot/map removed, reconnect later progresses | Outbound active zero | Dead slot retains permit/map entry |
| C2-OUT-06 | Active announce plus Remote roots during relay shutdown | Signal once, hold one non-cooperative test root | All use original deadline; remainder forced/dropped; no detached tasks | Every declared outbound gauge zero | Outbound work survives successful shutdown |

If OUT-03 through OUT-06 cannot be constructed because outbound admission and
ownership remain outside C2, the implementation report marks them `GAP`, not
`PASS`. The formal reviewer returns `CHANGES REQUIRED` for a relay-global
session/shutdown claim.

## Wire and compatibility matrix

| ID | Precondition/mechanism | Required assertion | Final state / blocker distinction |
| --- | --- | --- | --- |
| C2-WR-01 | Legacy and bounded relay, real Raw QUIC client | Existing `moq_transport::setup::ALPN` and draft-16 setup unchanged | Sessions close; gauges zero |
| C2-WR-02 | Legacy and bounded relay, real WebTransport client | Existing `web_transport_quinn::ALPN`, H3/CONNECT, and setup unchanged | Sessions close; gauges zero |
| C2-WR-03 | Publish and subscribe multiple Objects through each bounded transport | Group/Subgroup/Object bytes, order, close/reset behavior unchanged | If the unchanged transport lib test hits E0308 at tracks.rs:501, report `BLOCKED_BY_BASELINE_E0308`, never C2 failure or pass |
| C2-WR-04 | Saturate bounded relay | Only existing transport/application close semantics are emitted; no new MoQT frame, parameter, header, query, or ALPN | Rejected clients leave no state |
| C2-WR-05 | Multiple endpoints mixed Raw/WT | Both share one inbound session controller without sharing or multiplying C1's default per-endpoint handshake controllers | Every controller/gauge returns zero |
| C2-WR-06 | Existing legacy constructor/source examples | Public `RelayConfig`, `Relay::new`, and `Relay::run` remain source-compatible and explicitly legacy-unbounded | No silent behavior change |

No test may mutate encoded media, introduce transcoding, or present synthetic
audio/telemetry as real media.

## Validation commands for a future implementation

Use Rust `1.93.0` from the already reviewed image digest
`sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57`.
Use `--locked --offline`, an ephemeral target directory, and an external command
watchdog. Do not install tools or dependencies.

```bash
git rev-parse HEAD
git merge-base HEAD ee22a1079783e374371e0705775978790ddd6471
git diff --name-status ee22a1079783e374371e0705775978790ddd6471
git diff --check
git diff --cached --check

rustfmt --edition 2021 --check \
  moq-relay-ietf/src/relay.rs \
  moq-relay-ietf/src/relay_c2_tests.rs

cargo check --locked --offline -p moq-relay-ietf
cargo test --locked --offline -p moq-relay-ietf c2_
cargo test --locked --offline -p moq-relay-ietf
cargo clippy --locked --offline --no-deps -p moq-relay-ietf --tests -- -D warnings
cargo test --locked --offline -p moq-native-ietf c1_
cargo test --locked --offline -p moq-native-ietf
cargo test --locked --offline -p moq-transport
```

The final transport command is expected to remain
`BLOCKED_BY_BASELINE_E0308` only while the exact unchanged baseline line and
hash match. Any different error, any relay/native regression, or any new
failure is attributed to C2 until proven otherwise. Full-workspace success is
not claimed while that blocker remains.

No large build, container, Cargo command, network access, or test execution was
performed while writing this plan.

## Acceptance criteria

A formal C2 reviewer may issue `APPROVE FOR LOCAL COMMIT` only when all of the
following are true for one immutable delta:

1. The parent is exactly C1 commit `ee22a107…6471` and scope stays within
   `moq-relay-ietf` source, focused tests, and necessary documentation.
2. One global inbound limit covers setup plus established session lifetime
   across all endpoints; N+1 rejects immediately before task/setup/state.
3. There is no async permit acquisition, waiter channel, spawned waiter, hidden
   future, or per-endpoint multiplication.
4. MAX and MAX+1 are fallible and panic-free on every public route.
5. Clean close, setup error, run error, cancellation at every stage,
   panic/unwind, owner/future drop, and deterministic races release exactly
   once and admit the next peer.
6. One shutdown deadline stops accepts, cancels, drains, forces drop, and
   returns with every declared owned gauge at zero.
7. All test waits use absolute watchdogs and all state ordering uses explicit
   barriers/events rather than sleep or elapsed-time thresholds.
8. Raw QUIC and WebTransport are real, retain both ALPNs and draft-16, and add
   no direct QUINN dependency or raw-UDP substitute.
9. Snapshot/counter schemas are low-cardinality, redacted, underflow-safe, and
   satisfy the terminal equation.
10. Announce and RemoteManager are separately bounded/owned, or every gap is
    explicit and the API/claims are narrowed. Without explicit Master
    acceptance of a narrowed inbound-only scope, an unbounded/detached
    RemoteManager is `CHANGES REQUIRED` for full C2.
11. C1 tests remain passing and C1 production is unchanged.
12. WR-03 is kept as the exact inherited E0308 blocker and not used to hide a
    C2 failure.
13. No manifest, lockfile, dependency, feature, wire, transport, native,
    license, unsafe, transcoding, product identity, or sensitive test material
    change exists.

## Mandatory `CHANGES REQUIRED` conditions

Return `CHANGES REQUIRED` if any remote connection can:

- await capacity or create a waiter/task/future before admission;
- begin MoQT setup, coordinator work, Producer/Consumer construction, or state
  mutation before its permit exists;
- multiply the intended inbound limit by endpoint count;
- retain a permit/gauge after any terminal or publish two terminals;
- survive successful shutdown inside the declared ownership scope;
- restart a timeout budget during shutdown or a test wait;
- cause a public synchronous callback, unbounded observability channel, raw
  error/identity label, underflow, panic from a public limit, or detached task;
- change draft-16, ALPN, Objects, manifests, lockfile, dependencies,
  `moq-transport`, or `moq-native-ietf`; or
- support a global/process-bounded claim while announce, RemoteManager, or
  child request work remains unbounded and undisclosed.

## Risk register

| Risk | Test/review control | Residual statement |
| --- | --- | --- |
| Inbound clients starve an essential relay peer | Separate outbound controller/reserve and mixed-load tests | No fairness or production sizing claim without measured policy |
| Endpoint count multiplies capacity | Multi-endpoint N/N+1 with one controller identity | C1 handshakes remain per-endpoint unless explicitly shared |
| Shutdown accepts one last session | Deterministic accept/shutdown barrier and stopping-state check | Scheduler order is not inferred from timing |
| Permit released after observable terminal | Cross-thread snapshot/reacquire test and release/acquire ordering | Metrics are evidence only when ordering holds |
| Detached Remote task outlives Relay | Owned handle/drop test and zero outbound gauge | Existing detached design is a blocker for full shutdown claim |
| Non-yielding work defeats Tokio abort | Prefer directly owned futures and synchronous force-drop; pure pending-future test | CPU-blocking code is separately prohibited and not simulated with `spawn_blocking` |
| Test hook changes production behavior | `cfg(test)`, bounded `try_send`, fixed stages, no payload ownership | Public hooks/callbacks are rejected |
| Real QUIC tests become timing-flaky | Port 0, explicit stages, bounded clients, absolute watchdogs | Watchdog expiry is failure, never synchronization |
| Child request collections grow inside one session | Explicit source inventory and no broad bounded-memory claim | Separate follow-up limits remain necessary |
| Exact mid-TLS shutdown cannot be paused | Public C1 snapshots plus independent C1 drop tests; mark exact case unavailable | No raw UDP or delayed-MoQT setup is relabelled TLS |
| WR-03 obscures a C2 regression | Exact file/hash/diagnostic classification | Only the known E0308 is baseline-blocked |
| Passing small N is sold as capacity | No latency/SLO/DoS/product claim; report load, N, endpoints, transport, duration | Chaos/soak and product sizing remain later integration work |

## Reviewer verdict rubric

`APPROVE FOR LOCAL COMMIT` means only that the exact local C2 delta satisfies
this contract on the immutable C1 base. `CHANGES REQUIRED` means at least one
ordering, ownership, bound, watchdog, shutdown, wire, scope, or evidence gate is
open. Neither verdict authorizes publication, integration, a product pin, C2
deployment, C3, push, or any remote action.

**LOCAL TEST PLAN ONLY / NO SOURCE EDIT / NO BUILD / NO COMMIT / NO PUSH / NO PUBLICATION / NO REMOTE MUTATION**
