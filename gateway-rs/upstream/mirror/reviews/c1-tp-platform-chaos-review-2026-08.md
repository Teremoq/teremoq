<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# C1 TP-PLATFORM-CHAOS formal review

Date: 2026-08-28

Profile: `TP-PLATFORM-CHAOS`

Reviewed worktree: `/home/jimbomilk/moq-rs-teremoq-c1-work`

## Findings

### High — C1-R01: the public synchronous observer can stop or panic the accept loop

Locations:

- `moq-native-ietf/src/quic.rs:117`
- `moq-native-ietf/src/quic.rs:226-244`
- `moq-native-ietf/src/quic.rs:247-262`
- `moq-native-ietf/src/quic.rs:843-865`
- `moq-native-ietf/src/quic.rs:882-905`

`HandshakeAdmissionObserver` accepts arbitrary embedder code as a synchronous
`Fn`. On the admitted path, `try_admit` first obtains the permit at line 236 and
then calls the observer at line 243. Control does not return to
`Server::accept` to calculate the absolute deadline or insert the single
handshake future until that callback returns. A blocking callback therefore
holds both the received `Incoming` and one scarce permit without a deadline;
subsequent valid peers cannot progress through that server. The reject paths
also call the same arbitrary callback in the accept loop. The protocol
disposition happens first there, but a blocked callback still prevents later
`Incoming` values from being polled.

A callback panic unwinds the task polling `Server::accept`. A panic while a
different unwind is dropping a guard can abort the process. Because remote
traffic selects and drives these event sites, an embedder instrumentation bug
becomes a remotely triggerable availability failure. A documentation contract
that asks callers not to block or panic cannot enforce the C1 isolation
invariant.

Required before approval: remove arbitrary synchronous embedder work from the
admission critical path or replace it with a mechanism non-blocking by
construction, such as bounded `try_send`/atomic observation with explicit drop
accounting. Do not add an unbounded event queue, a task per event or an async
wait in the `Incoming` path. Add focused evidence for a saturated event sink
and for observer failure without letting either stall admission.

### High — C1-R02: an accepted public limit can panic during semaphore construction

Locations:

- `moq-native-ietf/src/quic.rs:54-78`
- `moq-native-ietf/src/quic.rs:175-189`
- `moq-native-ietf/src/quic_c1_tests.rs:210-229`

`ServerAdmissionConfig::new` calls itself validated but checks only the timeout.
`HandshakeAdmission::{new,with_observer}` are infallible and pass any
`NonZeroUsize` directly to `Semaphore::new`. Tokio 1.48.0 panics when the value
exceeds `Semaphore::MAX_PERMITS` (`usize::MAX >> 3`). The configuration test
does not exercise this boundary.

The reviewer reproduced the production panic against the exact compiled Tokio
1.48.0 dependency using
`Semaphore::new(Semaphore::MAX_PERMITS + 1)`. It exited 101 with:

```text
a semaphore may not have more than MAX_PERMITS permits (2305843009213693951)
```

Required before approval: validate the upper bound before constructing the
semaphore and return a typed/fallible configuration error. The bounded
constructor must fail closed rather than panic. Add boundary tests for
`MAX_PERMITS` and `MAX_PERMITS + 1`; do not alter a production threshold merely
to satisfy the test.

### High — C1-R03: `Cancelled` is observed before its permit is released

Locations:

- `moq-native-ietf/src/quic.rs:272-317`
- `moq-native-ietf/src/quic_c1_tests.rs:561-645`

The explicit success/error/timeout path is correctly ordered: `finish` marks
the guard terminal and takes/drops the permit before updating and emitting the
terminal. `Drop`, however, increments `cancelled` and invokes the observer
without first taking `self.permit`. Rust drops the struct fields only after the
`Drop::drop` body returns. Consequently a `Cancelled` observer sees
`pending_handshakes` still occupied; if that observer blocks, the cancellation
permit is never returned.

The server-drop tests inspect a snapshot only after `drop(server)` has fully
returned, so they do not detect the event-ordering bug. This does not underflow
the derived gauge, but it violates the required lifecycle contract that
capacity is released before the terminal event becomes observable.

Required before approval: take/drop the permit before incrementing/emitting
`Cancelled`, preserving exactly-one terminal ownership, and add an observer
test that snapshots capacity from the cancellation event and sees the permit
already available. The test must also prove final gauge zero.

### Medium — C1-R04: several C1 waits can hang CI without a watchdog

Locations:

- `moq-native-ietf/src/quic_c1_tests.rs:157-182`
- `moq-native-ietf/src/quic_c1_tests.rs:387-395`
- `moq-native-ietf/src/quic_c1_tests.rs:533-543`
- `moq-native-ietf/src/quic_c1_tests.rs:576-587`
- `moq-native-ietf/src/quic_c1_tests.rs:615-625`
- `moq-native-ietf/src/quic_c1_tests.rs:780-785`
- `moq-native-ietf/src/quic_c1_tests.rs:918-926`
- `moq-native-ietf/src/quic_c1_tests.rs:1022-1029`
- `gateway-rs/upstream/mirror/reviews/c1-tp-platform-chaos-test-plan-2026-08.md:230-231`

The four snapshot-polling loops for N/N+1, shared capacity, illegal Retry and
the burst use `loop { ... yield_now().await }` with no deadline. If the expected
counter never changes, no other layer exits those loops. The three
`Server::accept`/stage `select!` loops also lack a timeout; after an internal
handshake error, `Server::accept` consumes the error and continues waiting, so
the select branch is not itself a reliable upper bound. `next_stage` and
`next_event` time out each individual `recv`, but restart a fresh wall-clock
timeout after every unexpected event rather than applying one absolute
watchdog to the whole wait.

`accept_n` and `join_client` do provide watchdogs for their own awaits, so
direct joins whose inner operation uses those helpers are transitively bounded.
That does not bound the loops listed above. The reviewer's outer GNU `timeout`
while running one binary is a diagnostic guard, not a substitute for a
per-test watchdog in normal `cargo test` CI.

Required before approval: wrap every logical wait or whole test body in one
generous monotonic watchdog, preferably through a shared helper with an
absolute deadline. Keep barriers/events as the pass criterion; do not replace
them with sleeps or timing thresholds.

### Medium — C1-R05: C1-WR-03 is blocked, not proven non-constructible

Locations:

- `gateway-rs/upstream/mirror/reviews/c1-local-review-2026-08.md:158-190`
- `gateway-rs/upstream/mirror/reviews/c1-tp-platform-chaos-test-plan-2026-08.md:288-295`
- `moq-native-ietf/src/quic_c1_tests.rs:969-999`
- `moq-transport/src/serve/tracks.rs:501`

The five recorded limitations do not all have the same status:

1. C1-09's exact mid-TLS pause is genuinely unavailable through the pinned
   public QUINN high-level API. The tests correctly cover the surrounding
   pre-accept, post-transport and WebTransport CONNECT stages and do not label
   a synthetic sleep as TLS.
2. C1-15 cannot make QUINN completion and a Tokio absolute deadline
   deterministically ready in the same poll with the authorized hooks/features.
   The consuming terminal guard is the conservative structural alternative.
3. C1-16 lacks a public deterministic QUINN transport-error injection seam.
   Separate error and drop tests are a conservative alternative, but not a
   simultaneous-race test.
4. C1-20 cannot read QUINN's private incoming-queue occupancy. Structural
   setter inspection is valid limited evidence; a black-box packet/socket seam
   needs separate authorization and must not use arbitrary UDP presented as
   QUIC.
5. C1-WR-03 is different: the existing `moq-transport` test target is stopped
   by the unrelated baseline E0308. That is a compile blocker, not evidence
   that an Objects regression cannot be built through the public APIs. The C1
   snapshot proves draft-16 setup on both transports, but publishes and drains
   no Objects over the bounded acceptor.

Required before approval: label C1-WR-03 `BLOCKED_BY_BASELINE_E0308`, not
`NOT-CONSTRUCTIBLE`, and keep it explicitly unpassed. After the owning baseline
fix, run the existing multi-Object/Subgroup regression through the bounded
acceptor, or demonstrate the exact public API obstruction and provide the
conservative replacement required by the plan. No C2 implementation is
authorized by this requirement.

## Concurrency seam review

Subject to the findings above, the core seam has the intended shape:

- `Server::accept` receives `quinn::Incoming` at `quic.rs:832-833` before it
  calls non-blocking `try_acquire_owned` through `try_admit` at lines 843 and
  235-236.
- With a permit, exactly one future containing the `Incoming` and its RAII guard
  is pushed at lines 855-865. `accept`/`accept_with` occurs only inside that
  future at lines 951-980.
- Without capacity, `dispose_capacity` consumes the `Incoming` in the same
  synchronous iteration. It performs no `await`, `spawn`, waiter insertion or
  future `push`.
- `Refuse` is explicit. `Retry` is attempted only for configured Retry policy
  and `may_retry=true`; an error recovers ownership with `into_incoming()` and
  explicitly refuses it. The real-QUINN legal and token-bearing illegal paths
  pass.
- One `tokio::time::Instant` is calculated before the future is inserted and
  passed to one `timeout_at`. It wraps `Incoming::accept`/`accept_with`, TLS
  handshake data and ALPN, `Connecting`, H3 SETTINGS/WebTransport CONNECT and
  response. It is not reset per subphase. C1-R01 must move instrumentation out
  of the undelimited interval before this calculation.
- The `FuturesUnordered` is a `Server` field. Cancelling only an outer
  `Server::accept` poll leaves owned futures intact; dropping `Server` drops the
  collection and its guards. No detached handshake task was introduced.
- `Endpoint::new_bounded` creates local per-endpoint capacity.
  `new_bounded_with_admission` shares capacity only when the caller explicitly
  supplies the same controller and rejects a mismatched limit.
- Normal completed/error/timeout paths release the C1 permit before returning a
  session. Tests keep sessions alive, complete draft-16 setup and observe zero
  C1 pending capacity, so C1 does not retain capacity into MoQT/C2.

No C2 session admission, relay authorization, publisher/subscriber policy or
product integration is reviewed or authorized here.

## QUINN pre-admission limits

`quic.rs:33-34` defines 10 MiB per `Incoming` and 100 MiB total, and
`quic.rs:643-647` explicitly applies all three setters to the same
`quinn::ServerConfig` later used to create the endpoint:

- `max_incoming(max_buffered_incoming)`;
- `incoming_buffer_size(10 MiB)`; and
- `incoming_buffer_size_total(100 MiB)`.

The byte values are internally coherent (`total >= per-Incoming`) and match the
pinned QUINN 0.11.9 defaults, but are explicit rather than implicit. They bound
buffered bytes only under QUINN's documented semantics; they exclude each first
packet and do not bound TLS/session/application memory. They are not a product
SLO or production capacity claim.

The snapshot returned at `quic.rs:1086-1094` repeats the configured constants;
QUINN 0.11.x exposes no public live queue gauge or config readback. Static
inspection proves that the setters are applied to the endpoint's config, while
C1-20 remains behaviorally unobservable with the authorized seam.

## Test evidence and gaps

The focused tests use real QUINN clients, rustls, both existing ALPNs and the
existing WebTransport implementation. No arbitrary UDP generator, direct new
QUINN dependency, second endpoint stack or sleep-based handshake surrogate was
added.

Observed coverage:

| Area | Reviewer result |
| --- | --- |
| Incoming -> permit -> one future ordering | PASS by source and stage test |
| N/N+1 immediate Refuse and recovery | PASS in bounded real-QUINN case; watchdog finding remains |
| legal Retry and illegal/token-bearing fallback | PASS |
| absolute pre-transport and CONNECT deadlines | PASS |
| external accept cancellation and Server drop | PASS final-state checks; Cancelled event-order finding remains |
| local versus explicitly shared capacity | PASS |
| raw QUIC and WebTransport | PASS |
| draft-16 setup and permit release before MoQT | PASS |
| Objects over the bounded acceptor | NOT RUN / BLOCKED_BY_BASELINE_E0308 |
| exact mid-TLS pause | UNOBSERVABLE_WITH_PINNED_PUBLIC_API |
| exact simultaneous deadline/success race | UNCONSTRUCTIBLE_WITH_AUTHORIZED_HOOKS |
| exact simultaneous cancellation/error race | UNCONSTRUCTIBLE_WITH_AUTHORIZED_HOOKS |
| live QUINN pre-admission queue occupancy | UNOBSERVABLE_WITH_QUINN_0_11_X |

Passing 23 focused tests is functional evidence for their exercised finite
cases. It is not evidence that the synchronous callback cannot block, that an
out-of-range configuration cannot panic, or that CI cannot hang on an
unreached event.

## Exact snapshot and delta

Read-only Git inspection independently found:

- branch: `teremoq/c1-bounded-handshakes-bf87128`;
- HEAD/base: `bf87128affd316463e5dcc7599a45001f222b6de`;
- HEAD/base tree: `d76319009e815fb8923e21fc8319e17a0aaf8174`;
- merge-base with the authorized base: exact;
- upstream tracking branch: none;
- index: empty; and
- delta: exactly one modified tracked path and nine untracked paths.

| State | Path | SHA-256 |
| --- | --- | --- |
| modified | `moq-native-ietf/src/quic.rs` | `45d11ce77ea0e90e6480a48fdc3e5e2556500139985d20761f7fb7879df91172` |
| new | `moq-native-ietf/src/quic_c1_tests.rs` | `c182b102c91bbec1cf4a8376b822836b1672bc2f07b465d6372d29a741a691d0` |
| new | `moq-native-ietf/tests/data/c1/README.md` | `717d3219aa203034fde416b6e17f291e21ab9344a15e258a92aaaf3812a14e10` |
| new | `moq-native-ietf/tests/data/c1/SHA256SUMS` | `ba0f134515bdca4413dc9658d4016343a2180fd6c8f624e7e1b779f013696d64` |
| new | `moq-native-ietf/tests/data/c1/ca.cert.der` | `ea33add88bed4676c51baa4f8da9df33d04e99cecf7d0846a756e23b0f66461b` |
| new | `moq-native-ietf/tests/data/c1/ca.cert.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| new | `moq-native-ietf/tests/data/c1/server.cert.der` | `053a80b61f971f0601d83305ec6139fbcd7ed2f78c541078ac6e68a7e6da16bc` |
| new | `moq-native-ietf/tests/data/c1/server.cert.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| new | `moq-native-ietf/tests/data/c1/server.key.der` | `1d02d7ec66886fc2bb2cc3104851e1c182d7980e946d8df2e8f0f3ae33c30436` |
| new | `moq-native-ietf/tests/data/c1/server.key.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |

`Cargo.toml`, `Cargo.lock`, every non-C1 source path, relay code, transport code,
license policy and existing tests are byte-identical to base. No dependency,
feature, wire constant, draft version or ALPN changed. Gitleaks 8.30.1 scanned
the focal crate with full redaction and found no leak. The DER key is documented
public synthetic test-only material and remains unsafe for deployment.

## Independently executed validation

Rust compilation used rustc 1.93.0 (`254b59607`) and Cargo 1.93.0
(`083ac5135`) from the fixed official image
`rust:1.93.0-slim-bookworm@sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57`.
Cargo ran with `CARGO_NET_OFFLINE=true`; each compile used a `mktemp` target
outside the worktree and removed it with a trap.

| Command/gate | Result |
| --- | --- |
| `cargo check --locked -p moq-native-ietf` | PASS |
| `cargo test --locked -p moq-native-ietf` | PASS, 24/24 unit tests; 0 doctests |
| direct focal binary with outer 180 s diagnostic timeout and `c1_` filter | PASS, 23/23 C1 tests; 1 filtered |
| `cargo clippy --locked --no-deps -p moq-native-ietf --tests -- -D warnings` | PASS |
| Rustfmt 1.93 `--check` over `quic.rs` and `quic_c1_tests.rs` | PASS |
| `cargo fmt --all --check` | BASELINE FAIL outside C1 at `moq-transport/src/serve/subgroup.rs:934` and `tracks.rs:304`; both paths are byte-identical to base |
| Tokio `Semaphore::MAX_PERMITS + 1` boundary reproduction | EXPECTED PANIC, exit 101; confirms C1-R02 |
| `git diff --check`; `git diff --cached --check` | PASS; index empty |
| exact path inventory and SHA-256 recalculation | PASS; matches table |
| Gitleaks 8.30.1 fixed digest, focal crate, `--no-git --redact=100` | PASS, zero findings |

The passing run duration was approximately 1.2 seconds after compilation. No
latency, throughput, memory or production-capacity inference is made from this
small local matrix. The C1 worktree hashes and status remained unchanged after
validation.

## Verdict

**CHANGES REQUIRED**

The exact snapshot is not approved for a local commit because C1-R01 through
C1-R04 violate binding admission-safety or test-gate requirements, and
C1-WR-03 is not validly classified as non-constructible. A follow-up review
must use a new exact hash inventory after the owning implementer addresses
these findings.

This verdict does not authorize a commit, branch operation, push, publication,
issue, pull request, C2 work, relay integration or any remote mutation.

**LOCAL FORMAL REVIEW ONLY / NO SOURCE EDIT / NO REMOTE MUTATION / NO C2**
