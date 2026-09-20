<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# C1 TP-PLATFORM-CHAOS formal rereview

Verdict: **CHANGES REQUIRED**

Review date: `2026-08-28`.

Scope: read-only formal rereview of the local, uncommitted C1 snapshot in
`/home/jimbomilk/moq-rs-teremoq-c1-work`. This verdict does not authorize a
commit, C2, publication, push, issue, PR, tag, release, product integration, or
any other remote action.

## Findings

### Medium — C1-R04 remains open: one logical test wait has no watchdog

`moq-native-ietf/src/quic_c1_tests.rs:1132-1135` awaits the server and client
draft-16 setup futures directly with `tokio::join!`:

```rust
let (server_setup, client_setup) = tokio::join!(
    moq_transport::session::Session::accept(...),
    moq_transport::session::Session::connect(...),
);
```

Neither future is wrapped by `timeout` or `timeout_at`, and no outer per-test
watchdog is configured by the normal `cargo test` invocation. The preceding
`accept_n` and `join_client` calls have their own ten-second watchdogs, but those
deadlines have already completed before this new logical wait begins. The MoQT
setup futures can wait for bidirectional stream/setup messages; a regression
that leaves only one side progressing can therefore hang CI indefinitely.

This violates the binding test-plan requirement at
`c1-tp-platform-chaos-test-plan-2026-08.md:230-231` that every test wait have a
watchdog. The current run passing in `0.61s` is not a substitute for a bound.

Required change: wrap the whole paired setup wait in one generous absolute
monotonic `timeout_at(watchdog_deadline(), async { ... })`. The deadline must not
reset for each side or setup message. Preserve the current simultaneous polling
and draft-16 assertions.

The rereview separately checked the waits previously named in C1-R04:

- `next_stage` reuses one absolute deadline across every received stage;
- all `wait_for_snapshot` polling loops, including N/N+1, burst, timeout,
  transport error, and illegal Retry, are inside one absolute `timeout_at`;
- the three explicit `Server::accept`/stage loops are inside one absolute
  `timeout_at`;
- direct awaits of tasks running `accept_n` are transitively bounded because
  each finite accept in that helper has a watchdog; and
- each client task is consumed through the bounded `join_client` helper.

No other unbounded network or event wait was found. The synchronous thread join
at `quic_c1_tests.rs:309-324` contains no wait, loop, I/O, lock acquisition, or
async operation in its thread body; it is not a logical network wait.

### Medium, inherited — C1-WR-03 remains `BLOCKED_BY_BASELINE_E0308`

The classification in `c1-local-rereview-2026-08.md` is now correct and remains
explicitly unpassed. The exact baseline and current tree have the same
`moq-transport/src/serve/tracks.rs` SHA-256:
`a8303c94925707a0a257923725bf84e4ec730b07d6bb2330fda5329b632fe0b7`.
At line 501 the unchanged library test compares `TrackName` with `&str` even
though the pinned `TrackName` derives only same-type `PartialEq`; this is the
known E0308 build blocker before the Objects assertion can execute.

An independent compile reproduction was attempted after the C1 tests. The
shared Rust container disappeared during that command and returned `137`.
Fresh exclusive containers, with the source mounted read-only and networking
disabled, then stopped at offline dependency resolution because the pinned
image itself does not contain the prior Cargo registry cache. No dependency was
downloaded and this environmental failure is not presented as the E0308
reproduction. The byte-identical baseline source and type boundary independently
confirm that WR-03 belongs to the baseline and is not constructible as a passing
C1 Objects test until its owner fixes that baseline test. WR-03 remains blocked,
not passed and not waived.

No Critical or High finding was identified in the corrected C1 admission logic.

## Closure of the prior binding findings

| ID | Rereview state | Evidence |
| --- | --- | --- |
| C1-R01 | CLOSED | The admission observer, public admission events, callback field, and synchronous emission sites are absent. Production observability is atomic snapshots only. The private `cfg(test)` stage hook is not compiled into production and is not a replacement product callback. The pre-existing `SocketWrapperFn` remains baseline endpoint-construction behavior, not C1 admission instrumentation. |
| C1-R02 | CLOSED | Both public limit constructors validate against `Semaphore::MAX_PERMITS` before `Semaphore::new`. `MAX_PERMITS` succeeds; `MAX_PERMITS + 1` returns `HandshakeAdmissionConfigError::TooManyPendingHandshakes` without panic. `Endpoint::new_bounded` propagates the typed source through its fallible boundary. The focused test passed. |
| C1-R03 | CLOSED | `finish` and `Drop` take and drop the owned permit before publishing a terminal counter with release ordering. Snapshots acquire terminal counters before reading availability. The guard's terminal bit prevents a second terminal, and the cross-thread recovery test passed. |
| C1-R04 | OPEN | Polling/select loops are fixed, but the direct draft-16 setup `tokio::join!` at lines 1132-1135 has no watchdog. |
| C1-R05 | CLOSED | WR-03 is labelled `BLOCKED_BY_BASELINE_E0308`, not `NOT-CONSTRUCTIBLE`, and remains explicitly unpassed. |

## Admission and ownership review

The corrected bounded path has the required order:

1. `self.quic.accept().await` yields one owned `quinn::Incoming` at
   `quic.rs:830-831`;
2. `admission.try_admit()` performs only `try_acquire_owned` at
   `quic.rs:240-249` and is called immediately afterward at line 841;
3. the no-capacity branch disposes that same `Incoming` synchronously at line
   842 and creates no future, waiter, task, or hidden permit queue;
4. only the admitted branch computes one absolute deadline and pushes exactly
   one owned future at lines 846-863; and
5. `Incoming::accept` or `accept_with` is first invoked inside that admitted
   future at lines 974-979.

Refuse consumes the received `Incoming` immediately. Retry is attempted only
when the configured policy is Retry and `Incoming::may_retry()` is true. If the
Retry operation still returns an error, ownership is recovered with
`into_incoming()` and refused. Token-bearing overload takes the explicit
retry-not-applicable/refuse path. The legal and illegal real-QUINN tests passed
and keep their outcomes separately observable through low-cardinality counters.

One `HandshakePermitGuard` owns each admitted phase. Normal completion,
transport error, timeout, future cancellation, `FuturesUnordered` drop, and
`Server` drop all release through RAII. An externally cancelled poll of
`Server::accept` does not drop the server-owned `FuturesUnordered`, so its phase
and permit remain live until the server resumes or is dropped. The corrected
tests cover cancellation before transport, every exposed stage, recovery, and
server drop with final pending gauge zero.

The deadline is computed once immediately after admission and one
`timeout_at(deadline, ...)` covers `Incoming::accept`/`accept_with`, QUIC/TLS and
ALPN establishment, H3 SETTINGS, WebTransport CONNECT request/response, success,
error, timeout, and cancellation of the owned future. The permit is finished
before an established session is returned, so C1 capacity is not held across
MoQT setup or session lifetime and does not become C2.

## Capacity semantics and observability

`Endpoint::new_bounded` creates a controller local to that endpoint by default.
Capacity is shared only through the explicit
`new_bounded_with_admission` constructor, which rejects a controller/config
limit mismatch. Both the local and shared real-endpoint tests passed; dropping
all owners also proves there is no controller Arc cycle.

The QUINN pre-admission settings are actually applied on the bounded server
configuration:

- configurable `max_incoming` from `max_buffered_incoming`;
- fixed `incoming_buffer_size = 10 MiB`; and
- fixed `incoming_buffer_size_total = 100 MiB`.

The 10 MiB per-Incoming cap and 100 MiB aggregate cap are coherent as two
different defenses: the aggregate cap can constrain the queue before every
entry reaches its individual maximum. They are not a measured SLO or a claim
about live memory. Their configured values are exposed in the schema-1 snapshot
and asserted by tests. QUINN 0.11.x still exposes no live incoming-queue
occupancy, so actual occupancy remains unobservable rather than reported as
zero.

Admission counters and gauges have schema version 1 and no peer IP, CID, SNI,
identity, namespace, certificate, or raw error as a metric label. Pending is
derived with `saturating_sub`, permit ownership is private, and terminal
publication happens after release; no numerical underflow or double terminal
was found. `inflight_futures` reports the server-owned collection length.

## Compatibility, C2 isolation, and remaining public-seam gaps

Real raw QUIC and WebTransport routes passed for bounded and legacy endpoints.
The WebTransport test reaches the existing H3/CONNECT path, raw QUIC retains the
existing MoQT ALPN, and the wire test keeps `moqt-16` and draft version
`0xff00_0010`. The draft-16 setup test also passed functionally, subject to the
C1-R04 watchdog finding above.

No change exists in `moq-transport`, `moq-relay-ietf`, Objects, sessions,
namespaces, manifests, lockfile, dependencies, features, or wire constants. C1
therefore remains isolated from C2.

The following four cases remain honestly outside the pinned public/test seams:

1. an exact deterministic pause in the middle of TLS;
2. exact success and absolute-deadline expiry in the same scheduler poll;
3. exact cancellation and QUINN error in the same scheduler poll; and
4. live occupancy of QUINN 0.11.x's internal incoming queue.

Surrounding real-QUINN ownership and terminal behavior is tested, but none of
these four cases is labelled a pass. No raw-UDP substitute, new dependency, or
new production hook was introduced.

## Snapshot, scope, and hashes

- Branch: `teremoq/c1-bounded-handshakes-bf87128`.
- Base and HEAD: `bf87128affd316463e5dcc7599a45001f222b6de`.
- Base and HEAD tree: `d76319009e815fb8923e21fc8319e17a0aaf8174`.
- Status inventory SHA-256:
  `fc674e7161c60e0aae278ea478f6570a9606d706aa81dad0c60e2384d5e8d3f9`.
- Index: empty.
- Prior TP-PLATFORM-CHAOS review SHA-256:
  `5f21e69920449c05c6be62e967841d8f12d996a2342111fcb298b733f3321ed5`.
- Local correction report SHA-256:
  `8fe7ae3ede22f475a125eece900ddea7d93abe2955d179b7a16fe3064dd98ab6`.

The exact permitted ten-path inventory remains one modified source, one new
test module, and eight unchanged fixture/provenance files:

| Path | SHA-256 |
| --- | --- |
| `moq-native-ietf/src/quic.rs` | `b0c8dfb3e4963365a3a27f52a84d2fc54292cfc5a056a817a5a0d0a4f38b3723` |
| `moq-native-ietf/src/quic_c1_tests.rs` | `0366d05cd35627bf160499db9146b45cac106d41d746e16fd16cfabdf4c262c2` |
| `moq-native-ietf/tests/data/c1/README.md` | `717d3219aa203034fde416b6e17f291e21ab9344a15e258a92aaaf3812a14e10` |
| `moq-native-ietf/tests/data/c1/SHA256SUMS` | `ba0f134515bdca4413dc9658d4016343a2180fd6c8f624e7e1b779f013696d64` |
| `moq-native-ietf/tests/data/c1/ca.cert.der` | `ea33add88bed4676c51baa4f8da9df33d04e99cecf7d0846a756e23b0f66461b` |
| `moq-native-ietf/tests/data/c1/ca.cert.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-native-ietf/tests/data/c1/server.cert.der` | `053a80b61f971f0601d83305ec6139fbcd7ed2f78c541078ac6e68a7e6da16bc` |
| `moq-native-ietf/tests/data/c1/server.cert.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-native-ietf/tests/data/c1/server.key.der` | `1d02d7ec66886fc2bb2cc3104851e1c182d7980e946d8df2e8f0f3ae33c30436` |
| `moq-native-ietf/tests/data/c1/server.key.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |

Protected files remain byte-identical to the base, including `Cargo.toml`,
`Cargo.lock`, `moq-native-ietf/Cargo.toml`, `moq-transport/Cargo.toml`,
`moq-relay-ietf/Cargo.toml`, and `moq-transport/src/setup/mod.rs`. No Task 05,
I1, I2, Q, relay, transport, manifest, lockfile, dependency, or fixture change
was made by this rereview.

## Independent validation

Rust commands used Rust `1.93.0` from image
`sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57`,
with Cargo `1.93.0`, rustfmt `1.8.0-stable`, `--locked --offline`, and an
external command timeout. The source was not edited. A copied compilation cache
was used only to overcome severe host contention; Cargo validated the current
snapshot and all executed tests ran from an ephemeral target.

| Validation | Result |
| --- | --- |
| `cargo check --locked --offline -p moq-native-ietf` | PASS on a fresh ephemeral target |
| `cargo test --locked --offline -p moq-native-ietf c1_` | PASS: 25 passed, 0 failed, 1 filtered; 0.61s test execution |
| `cargo test --locked --offline -p moq-native-ietf` | PASS: 26 passed, 0 failed; doctests 0/0; 0.61s unit-test execution |
| `cargo clippy --locked --offline --no-deps -p moq-native-ietf --tests -- -D warnings` | PASS |
| focal `rustfmt --edition 2021 --check` on `quic.rs` and `quic_c1_tests.rs` | PASS |
| `cargo test --locked --offline -p moq-transport --no-run` | NOT COMPLETED in this rereview: shared container vanished with exit 137; exclusive offline container lacked registry cache. WR-03 remains independently classified from exact baseline source and is not called a pass. |
| `git diff --check` and `git diff --cached --check` | PASS; index empty |
| `git diff --no-index --check /dev/null <new-file>` | PASS for all nine untracked files |
| branch, HEAD/tree, status inventory, ten hashes, protected-file comparison | PASS |

Two initial from-scratch test-build attempts hit their external compilation
timeout under host contention before executing any test. They are environmental
timeouts, not hidden passes or C1 test failures. The subsequent focal and full
test executions completed with the results above.

## Approval gate

C1 cannot be approved for a local commit until C1-R04 is corrected and the
focused/full tests are rerun with the draft-16 setup wait demonstrably guarded
by one absolute watchdog. WR-03 must remain
`BLOCKED_BY_BASELINE_E0308` and unpassed until its owning baseline change is
available; C1 must not absorb that unrelated fix.

**CHANGES REQUIRED**

**LOCAL REREVIEW ONLY / NO C1 SOURCE EDIT / NO COMMIT / NO C2 / NO REMOTE MUTATION**
