<!--
SPDX-FileCopyrightText: 2026 Teremoq contributors
SPDX-License-Identifier: Apache-2.0
-->

# C2 third independent security rereview — TP-SEC-PKI

Date: 2026-08-28

Role: `TP-SEC-PKI`

Review mode: read-only security rereview

Source: `/home/jimbomilk/moq-rs-teremoq-c2-work`

Branch: `teremoq/c2-session-shutdown-ee22a10` (local, no tracking)

Base/HEAD: `ee22a1079783e374371e0705775978790ddd6471`

HEAD tree: `232e449945e877b024f2fc4223f0d2eea124b39b`

## Findings

### Blocking C2 findings

None.

The five defects that blocked the preceding TP-SEC-PKI and platform reviews
are closed in this bound snapshot. No defect was displaced into another cache
generation, shutdown ordering, test-only oracle, capacity label, TLS path, or
legacy fallback.

### Inherited blocker — not a C2 finding and not a pass

`C2-WR-03` remains exactly `BLOCKED_BY_BASELINE_E0308` at the unchanged
`moq-transport/src/serve/tracks.rs:501`. The protected file hash remains
`a8303c94925707a0a257923725bf84e4ec730b07d6bb2330fda5329b632fe0b7`.
This rereview does not repair, waive, call non-constructible, or otherwise
approve that workspace baseline failure. The relay-focused C2 gates below do
not conceal it.

### Residual advisories and scope boundaries

- C2 is post-handshake root-session capacity. It is not authentication,
  authorization, mTLS, pre-handshake admission, a complete memory bound, or a
  total DoS defense. It never converts IP, SNI, connection path, certificate,
  scope, or identity into authority.
- Exact C1 mid-TLS composition remains
  `UNTESTABLE_EXACT_MID_TLS_WITH_C1_PUBLIC_API` (`SD-07`). The public C1 monitor
  composition test passes, but this narrower residual is not promoted to a
  pass or hidden inside T21.
- The single Tokio deadline is a cooperative runtime deadline. It cannot
  promise a hard wall-clock bound during executor starvation, OOM/process
  abort, or an external synchronous destructor that blocks the runtime.
- Root limits do not bound every child request, map, protocol queue, payload,
  or host resource. Host/cgroup limits and network rate limiting remain
  separate controls.
- Advisory, package/release, publication, and product-pin decisions remain
  separate OSS/integration gates. This verdict authorizes none of them.

## Closure of the prior security findings

### 1. Same-key cancellation cannot publish an orphan Remote generation

PASS. `RemoteSlotReservation` owns both the Tokio `OwnedMutexGuard` and the
exact map generation (`remote.rs:204-219`). Its destructor takes the map lock,
compares the mapped `Arc` by pointer identity, and removes only that generation
(`remote.rs:273-287`). The owned slot guard is still alive throughout the
destructor body; Rust releases fields only after `Drop::drop` returns. Thus the
map entry is retired while the old slot remains locked, before a same-key
waiter can acquire it.

The waiter rechecks pointer identity after acquiring the slot
(`remote.rs:1431-1451`). If it waited on the cancelled generation, it observes
that the old slot is no longer current and retries against the map. A newer
generation cannot be removed by an older reservation because removal is
conditioned on `Arc::ptr_eq` (`remote.rs:281-286`). No clone implementation
exists for the reservation or permit guard.

The discriminating test uses capacity 2, a real loopback QUIC/MoQT creator and
a concurrent same-key waiter (`remote.rs:863-974`). It proves:

- the waiter actually reached the old slot lock;
- the cancelled generation disappeared before waiter completion;
- the replacement has a different `Arc` and contains the returned connection;
- exactly two intentional dials occurred (cancelled creator plus replacement),
  not a third/unindexed dial;
- one map entry and one owned Remote task remain while the replacement is live;
- accounting is one cancellation plus one active generation, followed by two
  total cancellations and full capacity after shutdown.

Independent execution of this exact test passed.

### 2. Productive panic boundary and `Closed` side effects

PASS. The former productive `expect()` is gone. Failure of the private,
unpublished slot lock invariant now returns the fixed typed and redacted
`RemoteCacheSlotInvariantError` (`remote.rs:44-50,1397-1406`), before map
insertion and without exposing key, URL, peer state, or lock details.

For a new slot, `try_admit` precedes map insertion (`remote.rs:1407-1426`). For
an existing empty or dead slot, the replacement admission decision precedes
reconnect counters, removal log, `Remote::shutdown`, slot mutation, dial log,
dial, or task construction (`remote.rs:1460-1501`). A `Closed` result returns
the fixed `RelayOutboundAdmissionClosedError` and does not increment admitted,
rejected-capacity, or terminal counters (`remote.rs:1466-1477`).

The empty/dead-slot test captures the map generation, dial count, reconnect
effect count, owned-task count, and full outbound snapshot before the call and
proves all remain unchanged after `Closed` (`remote.rs:633-775`). The separate
new-key stop-first case also proves an empty map, zero dial/task effects and
zero counters (`remote.rs:573-630`). Both passed independently.

No productive `expect()` remains in the C2 outbound boundary. Remaining
`expect`, `panic`, and `unwrap` matches in the seven C2 paths are test-only or
the pre-existing ignored documentation example; no `unsafe` was added.

### 3. Real wire proof before N+1 disposition

PASS. The test uses the official draft-16 `CLIENT_SETUP` encoder and writes the
real control stream (`relay_c2_tests.rs:201-227`). It then polls the control
stream read where `SERVER_SETUP` would arrive and signals only after the future
returns `Poll::Pending` (`relay_c2_tests.rs:228-245`). Only that signal releases
the post-accept gate (`relay_c2_tests.rs:263-269`). The close observer rejects
both received and buffered `SERVER_SETUP` bytes (`relay_c2_tests.rs:246-260`).

The N+1 connection is real for raw QUIC and WebTransport. Public transport
errors prove the exact constant code `0x3` and reason
`relay session capacity reached` in both cases (`relay_c2_tests.rs:275-302`).
The private N roots merely hold capacity; they are not used as the N+1 effect
oracle. Independent probes show zero inserted/active session roots, zero mlog,
zero scope/tagger calls, empty local namespaces/tracks, and no application
state (`relay_c2_tests.rs:726-833`). The root probe is incremented only at the
actual session-root insertion point (`relay.rs:1115-1135`). The test passed
independently.

### 4. Real scope and ordinary run errors recover capacity

PASS. `TestCoordinator::resolve_scope` returns the real typed
`CoordinatorError::NamespaceNotFound` when its fail flag is set
(`relay_c2_tests.rs:39-50`). The test sends a real client setup, observes one
setup terminal, capacity 1 restored, zero active root, zero tagger/registration,
and empty `Locals` (`relay_c2_tests.rs:405-461`).

The second real session completes setup and the peer closes the underlying
transport with an application error; the relay's ordinary `Session::run`
branch, not a panic hook or direct terminal call, produces `RunError`
(`relay_c2_tests.rs:463-507`; production branch `relay.rs:1599-1615`). It
again restores capacity, removes the independent root probe, leaves namespace
state empty, and publishes exactly one additional terminal. Independent
execution passed.

### 5. Platform stop-first/announce race

PASS. A token cancelled before the first poll is checked before destructuring
the relay or creating accept, control, announce, dial, or task roots
(`relay.rs:897-912`). During announce admission, the cancellation branch is
biased ahead of the admission future (`relay.rs:935-967`). Inside bounded
announce setup, cancellation is likewise biased ahead of connect/session setup
(`relay.rs:1287-1350`). Stop-first closes state with zero admission/root/dial;
admit-first transfers one owned permit and later terminalizes it.

The pre-cancelled test uses a real upstream accept probe and proves zero
outbound counters, zero root, zero dial and zero peer accept
(`relay_c2_tests.rs:576-633`). The two-order barrier test independently drives
stop-before-admit and admit-before-stop, with a root-owned signal only in the
second ordering (`relay_c2_tests.rs:635-724`). Both passed independently.

## Admission, lifecycle, ordering, and shutdown audit

- The only capacity acquisition is immediate
  `try_acquire_owned` (`session_admission.rs:228-249`). There is no capacity
  waiter and no separate check-then-act predicate.
- `Semaphore::close` is the stop linearization point
  (`session_admission.rs:255-269`). `Closed` changes no admitted, rejected, or
  terminal counter.
- Public limits reject 0, `MAX+1`, zero timeout and an overflowing monotonic
  deadline before `Semaphore::new`; `MAX` is accepted without panic
  (`session_admission.rs:23-79,301-320`). The unchecked controller constructor
  is crate-private and receives only validated limits from `Relay::new_bounded`.
- `SessionPermitGuard` is private and non-clonable. Its sole
  `Option<OwnedSemaphorePermit>` makes terminalization exactly once
  (`session_admission.rs:441-495`). Cancellation, unwind, owner drop and forced
  shutdown all converge on the same `Option::take` release path.
- Active/inflight are decremented and the semaphore permit is dropped before
  the selected terminal and `terminal_total` are published with Release
  (`session_admission.rs:459-484`). A snapshot loads `terminal_total` with
  Acquire before reading gauges (`session_admission.rs:338-365`). The two-order
  release/admit, stop/admit, terminal/shutdown and pre-started observer tests
  passed.
- Inbound admission is after native acceptance but before connection metrics,
  mlog path/session setup, coordinator, tagger, `SessionContext`,
  Producer/Consumer, namespace state, forwarding, or task insertion
  (`relay.rs:1055-1136`). N+1 is closed immediately and the endpoint is requeued
  only while the controller remains running.
- Both controllers close before accepts are dropped, cancellation is sent, or
  drain begins (`relay.rs:1168-1207`). One absolute `timeout_at(deadline, drain)`
  covers inbound sessions, control roots, announce, Remote roots/cleanup,
  namespace pulls, Remote shutdown, and coordinator shutdown
  (`relay.rs:1207-1250`). There is no per-task deadline reset or unbounded await
  after timeout.
- Bounded Remote roots and cleanup futures use `OwnedRemoteTasks`; only the
  explicitly legacy owner detaches (`remote.rs:52-164,1180-1231,1803-1855,
  1998-2047`). Namespace pulls moved from detached `tokio::spawn` handles into
  the runner-owned `FuturesUnordered` (`upstream_namespaces.rs:290-317,
  568-593`). Dropping the bounded owner at the shared deadline drops all of
  these futures and their guards synchronously.
- At return, both monitors must report active/inflight zero and all permits
  available; otherwise `run_bounded` returns an error
  (`relay.rs:1249-1264`). The forced non-cooperative root test proves the same
  single deadline and zero gauges.
- Admission, terminal and permit `Drop` use only semaphore/atomics; they do not
  call tracing, mlog, `metrics!`, a recorder, or arbitrary callbacks. Snapshot,
  Debug and errors expose only fixed aggregate fields. Remote generation Drop
  performs only exact map retirement while holding its owned slot guard; it
  does not log, dial, invoke policy, or drop the live Remote value.

## Identity, redaction, TLS, and compatibility audit

The capacity decision receives only semaphore capacity and shutdown state. It
does not receive or read IP, port, CID, SNI, connection path, endpoint,
certificate, DER/PEM, subject, SAN, serial, fingerprint, principal, role,
scope, namespace, URL, payload, or peer error. Capacity closures and typed
errors are fixed strings and do not disclose occupancy. No capacity metric or
snapshot label contains identity or peer-derived data.

The existing coordinator/tagger/authentication paths remain downstream and
separate. A permit is never converted into principal, role, relay-peer,
evidence, scope, or authorization. Successful capacity admission does not
authorize a session; C2 does not claim otherwise.

The seven Rust paths add no runtime dependency, feature, lockfile change,
`unsafe`, wire/draft/ALPN/Objects change, TLS/mTLS change, second transport, or
Teremoq-specific authorization policy. Raw QUIC and WebTransport share the
same inbound controller and retain their existing admitted flow. `Relay::new`
and `Relay::run` remain source-compatible legacy APIs; bounded construction and
`run_until` are additive, explicit, validated, and have no bounded-to-legacy
fallback.

The C2 PEM fixtures are deterministic encodings of the immutable C1 DER
fixtures. README and sidecars label the private key public, synthetic,
loopback-only, test-only material that must never be deployed. Decoded CA and
certificate DER hashes match C1; direct PEM-body decoding of the private key
matches the C1 key DER. Certificate/key public keys match at SHA-256
`6c4c590db18e4f3f73fc7deb40ee6f0c2ca0b31a41a968bead99a7d8af82cb1c`.
The certificate is limited to `localhost` and `127.0.0.1`, valid from
2026-08-26T21:23:11Z through 2036-08-23T21:23:11Z. No PEM or private-key
content was printed during review.

## C2 invariant matrix

| Invariant | Result | Independent conclusion |
| --- | --- | --- |
| C2-I01 global, non-blocking capacity | PASS | One shared inbound controller; immediate `try_acquire_owned`; no waiter/check-then-act. |
| C2-I02 N+1 before effects | PASS | Gate precedes all MoQT/app effects; real raw/WT test proves Pending read, fixed close and independent zero probes. |
| C2-I03 private non-clonable RAII / one terminal | PASS | One owned permit in `Option`; finish/Drop share `take`. |
| C2-I04 observable ordering | PASS | Gauges and permit release before terminal Release; snapshot Acquire; controlled races pass. |
| C2-I05 panic/cancel/drop | PASS | Inbound unwind, outbound cancellation, same-key handoff and forced owner drop recover exactly once. |
| C2-I06 0/MAX/MAX+1 without panic | PASS | Public validation precedes semaphore construction and deadline use. |
| C2-I07 one deadline / closed admission | PASS | Both controllers close before cancel/drain; one absolute deadline; zero gauges at return. |
| C2-I08 aggregated redacted observability | PASS | Capacity snapshots/errors/closures are fixed and identity-free; no recorder/log callback in admission/terminal/Drop. |
| C2-I09 capacity independent of identity | PASS | No identity/network/auth input reaches the decision; permit conveys no authority. |
| C2-I10 bounded fail-closed / legacy separate | PASS | Additive validated API, no fallback; legacy signatures remain. |
| C2-I11 minimal upstream surface | PASS | Exactly 15 relay-only paths; protected manifests/lock/TLS/wire/license inputs unchanged. |
| C2-I12 honest, owned outbound scope | PASS | Separate outbound capacity; announce, Remote roots/cleanup and pulls are owned under the same drain/deadline. |

## C2 test/review matrix

| Test criterion | Result | Evidence |
| --- | --- | --- |
| C2-T01 0/1/MAX/MAX+1 | PASS | Typed validation and catch-unwind tests. |
| C2-T02 N and N+1 one endpoint | PASS | N retained roots, immediate N+1 disposition, capacity unchanged until release. |
| C2-T03 global multi-endpoint/raw/WT | PASS | One monitor and limit shared across two endpoints/transports. |
| C2-T04 M=32 contenders | PASS | All finish under watchdog; max remains N; no capacity waiter. |
| C2-T05 client waiting SERVER_SETUP | PASS | Read polled to Pending before accept gate release. |
| C2-T06 independent pre-gate effects | PASS | Root probe, mlog, Locals, tagger/coordinator and namespaces all zero. |
| C2-T07 exact raw/WT overload close | PASS | Public errors expose only code `0x3` and the constant reason. |
| C2-T08 normal/setup recovery | PASS | Real setup failure and established close restore capacity. |
| C2-T09 scope/run errors | PASS | Real coordinator error and ordinary `Session::run` error; zero residual root/namespace. |
| C2-T10 cancel/drop | PASS | Distinct-key and real same-key cancellation; generation handoff and capacity recovery. |
| C2-T11 panic/unwind | PASS | Setup/run panics caught; one Panicked terminal and recovered permit. |
| C2-T12 natural/cancel/shutdown races | PASS | Controlled terminal vectors satisfy one-terminal equation without underflow. |
| C2-T13 cross-thread ordering | PASS | Observer starts before terminal and validates Release/Acquire visibility and reacquire. |
| C2-T14 identity/network variation | PASS | Structural decision has no such input; raw/WT and endpoint variation do not alter it. |
| C2-T15 cooperative shutdown | PASS | Controllers close, owned roots drain under one deadline, gauges zero. |
| C2-T16 non-cooperative session | PASS | Same deadline forces local drop; no post-deadline await. |
| C2-T17 accept/admit/shutdown | PASS | Inbound, new-key, empty/dead-slot and announce stop/admit orderings are discriminating. |
| C2-T18 hostile recorder | PASS | Admission/terminal/Drop structurally invoke no recorder, log, mlog, or callback. |
| C2-T19 outbound during inbound saturation | PASS | Controllers/gauges are independent; pending announce does not starve inbound. |
| C2-T20 complete owned lifecycle | PASS | Sessions, controls, announce, Remote roots/cleanup and pulls are owned and deadline-bound. |
| C2-T21 C1 composition | PASS | Public C1 monitors are zero at bounded return; exact mid-TLS SD-07 remains separately delimited. |
| C2-T22 legacy versus bounded | PASS | Legacy signatures compile; invalid/saturated bounded mode never falls back. |
| C2-T23 raw/WT regression | PASS | Admitted baseline flow and real N+1 pre-MoQT rejection pass on both transports. |
| C2-T24 redaction | PASS | Low-cardinality schema, fixed close/error, clean source scans; synthetic key finding is documented/redacted. |
| C2-T25 upstream surface | PASS | Relay-only diff; no manifest/lock/dependency/wire/TLS/unsafe change. |

No C2-I or C2-T row is `PARTIAL`. `WR-03` remains the sole inherited compiler
blocker and is recorded outside these matrices.

## Snapshot and hash reproduction

All owner-reported bindings and hashes were independently recomputed before
and after the review.

| Binding/input | Reproduced SHA-256 or value |
| --- | --- |
| `.cursorrules` | `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2` |
| Current owner report | `a15dd8989f3cffa234daf70bec33cc92e8d4e1243871ed41e0ca986d41d480bd` |
| Prior TP-SEC-PKI rereview | `cfbb03d91e406ca139696ed01c09307f6b94378258313915c4f14199ee61c47a` |
| Prior platform rereview | `3796be533ad5090c4fcdc8419610148caaf16b0ff81fd2996c4acb56fec0f477` |
| Prior OSS rereview | `c1c5b3a5f9e2b8a81265d1df131753b6bda458e0a984fbe8c504bb7245ef8f4d` |
| HEAD/base | `ee22a1079783e374371e0705775978790ddd6471` |
| HEAD tree | `232e449945e877b024f2fc4223f0d2eea124b39b` |
| Status inventory (porcelain v1, all untracked) | `41969b3ff7d7ebcaaf891137a17519a2097319642b6753db144a0b5a000db614` |
| Stage | empty (zero bytes from cached name inventory) |
| Changed paths | exactly 15 |

### Fifteen changed-path hashes

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

### Protected byte-identical inputs

| Input | SHA-256 |
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
| `REUSE.toml` | `afc7fd86e591a56078b11982ee4d039ea1dfe3f9d56a90e3e7fa9f84fbddb6cc` |
| Apache-2.0 text | `1248f876e0140942002b476a19c95d5b5b44c625e69c96611d23119ee87fa04e` |
| MIT text | `c7d191b5901a741f2e39c74bd7a7594014a81fbe2bc7d533d4c29ad4cfe4e057` |

Decoded fixture DER provenance also reproduced exactly:

- CA certificate: `ea33add88bed4676c51baa4f8da9df33d04e99cecf7d0846a756e23b0f66461b`;
- server certificate: `053a80b61f971f0601d83305ec6139fbcd7ed2f78c541078ac6e68a7e6da16bc`;
- server private-key container: `1d02d7ec66886fc2bb2cc3104851e1c182d7980e946d8df2e8f0f3ae33c30436`.

## Commands and independently observed results

The review read the complete C2 diff and all seven Rust source/test paths. No
source-side `target` was created. The only executed test artifacts were the
already-built binaries corresponding to this snapshot.

| Command/gate | Result |
| --- | --- |
| `git rev-parse HEAD`, `HEAD^{tree}`, branch/upstream checks | PASS: exact binding; no tracking. |
| `git status --porcelain=v1 --untracked-files=all` plus SHA/count | PASS: exact status SHA; 15 paths. |
| `git diff --cached --name-only` | PASS: stage empty. |
| `sha256sum` over owner reports, 15 paths and protected inputs | PASS: every owner hash reproduced. |
| `git diff --check`; `git diff --cached --check` | PASS. |
| Static search for productive `expect`/`unwrap`/`panic`, `unsafe`, spawns, tracing and metrics | PASS for the claimed boundary; matches were test-only, legacy-documented, or downstream of admission. |
| Six exact closure tests from the prebuilt library test binary | PASS: 6/6. |
| Prebuilt library test binary filtered by `c2_` | PASS: 27 passed, 0 failed, 119 filtered. |
| Prebuilt public `c2_session_admission` integration binary | PASS: 10 passed, 0 failed. |
| Focused Rust 2021 `rustfmt --check` over seven C2 Rust paths | PASS. |
| REUSE 5.1.1 | PASS: 204/204 files, Apache-2.0 and MIT, zero bad/missing licenses. |
| Gitleaks 8.30.1, each of seven C2 Rust paths | PASS: no findings. |
| Gitleaks 8.30.1, C2 fixture directory, `--redact --verbose` | EXPECTED: exit 1, exactly one `private-key` finding, exactly one redacted secret. |
| OpenSSL/DER hash and public-key comparison | PASS: C1 provenance and cert/key public-key match; no key material printed. |

Rust tests ran offline/read-only with `--network none`, a read-only root,
read-only source at `/work`, read-only target cache, and tmpfs `/tmp`, using
local image ID
`sha256:f522c28d5beb21591f46e8c165030f70b32dd5b51107577ad196910e7147a007`
(Rust/Cargo 1.93.0, rustfmt 1.8.0-stable, Clippy 0.1.93). No build, download,
installation, source write, or target write occurred.

One initial attempt to execute the prebuilt library binary directly on the
host was invalid because its compile-time `CARGO_MANIFEST_DIR` is `/work`; it
failed before test setup while resolving the synthetic certificate path. It
was discarded as infrastructure misuse, not counted as a code failure, and
was rerun in the read-only fixed image with `/work` mounted correctly. The
corrected exact test and the complete 27/10 C2 suites passed. No resource gate
was interrupted or retried through compilation.

Supply-chain validation used only local immutable images:

- Rust review image ID
  `sha256:f522c28d5beb21591f46e8c165030f70b32dd5b51107577ad196910e7147a007`;
- Gitleaks 8.30.1, MIT,
  `sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f`;
- REUSE 5.1.1, GPL-3.0-or-later,
  `sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da`.

The current owner additionally records PASS for offline relay check, complete
relay tests, Clippy `-D warnings`, C1 regression, package inventory, and the
same focal gates. Those results are corroborating evidence; the verdict above
does not treat the owner report alone as proof.

## Verdict and authorization boundary

The corrected snapshot closes the prior TP-SEC-PKI and platform findings,
satisfies C2-I01 through C2-I12 and C2-T01 through C2-T25, and introduces no
new C2 security finding. The approval allows the Master only to consider a
local commit of this exact snapshot. Any hash/status change requires a new
review.

This approval does not authorize C3, integration, fetch, push, publication,
package/release, remote mutation, or deployment. It does not waive WR-03,
SD-07, advisories, or later OSS/product gates.

`READ-ONLY SECURITY REVIEW / NO COMMIT / NO PUSH / NO FETCH / NO PUBLICATION / NO REMOTE MUTATION`

APPROVE FOR LOCAL COMMIT

The SHA-256 of this immutable review artifact is calculated after the file is
written and is supplied in the review handoff; it cannot be embedded in the
file itself without creating a circular digest.
