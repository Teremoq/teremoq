<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# TP-PLATFORM-CHAOS rereview of the local I1/I2 + C1/C2 source merge

Date: 2026-08-28

Reviewer: `TP-PLATFORM-CHAOS`

Reviewed source: `/home/jimbomilk/moq-rs-teremoq-integration-work`

State reviewed: staged, local, reversible, merge in progress, not committed

## Findings first

### HIGH

None attributable to staged tree
`d7f0c67f4c134adc4250885f6bc031aa2efcead6`.

### MEDIUM

None.

### LOW

None.

### INFO IC-14-P1 — positive composition is real on both transports

The two new positive tests at
`moq-relay-ietf/src/i2_tests.rs:898-1097` independently exercise raw QUIC and
WebTransport through `Relay::new_required_bounded`. Each route uses one absolute
Tokio deadline, completes transport and `SERVER_SETUP`, proves one C1 completion,
one connection-bound I1 authentication, required path/scope resolution, two
operation gates, PUBLISH/PUBLISH_OK and the first application-state effects.
They also prove zero legacy coordinator/tagger calls, zero C1 pending handshakes,
one C2 terminal, zero active sessions after shutdown and an empty required-mode
mlog directory. Independent execution passed 2/2.

### INFO IC-14-P2 — the combined N+1 oracle is discriminating

`moq-relay-ietf/src/i2_tests.rs:1269-1365` deterministically retains the first
authorized session at the scope semaphore with the C2 limit fully occupied. For
both raw QUIC and WebTransport the second real transport reaches C2 and observes
the public close asserted at `i2_tests.rs:865-887`:

- application close code exactly `0x3`;
- reason exactly `relay session capacity reached`.

Before release/shutdown, the oracle proves one authentication and one scope
resolution only, no second required effect, no coordinator or tagger call, no
mlog file or application state, C2 `admitted_total=1`,
`rejected_capacity_total=1`, `active_inbound_sessions=1`, and C1 two admitted,
two completed, zero pending. After shutdown it proves one terminal and zero
active C2 sessions. Independent exact execution passed 1/1; the single test
contains both transport cases.

### INFO C1/C2 — admission, ownership and shutdown remain separated

C1 remains in `moq-native-ietf/src/quic.rs`: `Endpoint::accept()` first yields
`Incoming`, then `try_admit()` uses `try_acquire_owned` without a waiter
(`quic.rs:1247-1279` and `1433-1467`). Capacity exhaustion consumes the
`Incoming` by immediate Refuse or legal Retry (`quic.rs:1306-1329`). Its one
absolute deadline covers QUIC/TLS/ALPN and WebTransport CONNECT.

C2 remains a distinct semaphore and monitor. `SessionAdmission::try_admit()` is
non-blocking (`moq-relay-ietf/src/session_admission.rs:228-249`). The relay
performs this admission immediately after accepted transport and before
authentication, CLIENT_SETUP, Producer, Consumer, coordinator state or session
task (`moq-relay-ietf/src/relay.rs:1483-1576`). Capacity N+1 is closed before
requeue at `relay.rs:1520-1534`.

`SessionPermitGuard` owns the permit by RAII, releases active/inflight gauges and
the permit before publishing exactly one terminal event
(`session_admission.rs:441-495`). Shutdown closes admission, drops accepts,
cancels owned roots, drains under one absolute deadline, force-drops at expiry
and checks both inbound and outbound capacity equations before returning
(`relay.rs:1593-1688`). The redaction correction did not change these seams.

### LIMITATION L-01 — Objects compatibility is structural, not an external payload interop run

The correction stages no `moq-transport` serializer, wire, ALPN, manifest or
lockfile change. Its source diff contains diagnostic redaction, required-mode
mlog suppression and tests; it adds no decoder, encoder, codec, pixel, PCM or
payload transformation. The full relay suite retains
`i2_does_not_change_wire_constants_or_object_types`, including
`setup::ALPN == b"moqt-16"` and construction of the upstream `Objects` type at
`i2_tests.rs:2185-2194`. The retained C1 and I1 suites exercise real raw QUIC,
WebTransport, draft-16 setup and both ALPNs.

The new composed positives publish a real Track and receive PUBLISH_OK, but do
not send media Object payload bytes end to end and are not an independent
implementation interoperability test. Therefore this rereview supports only
the conservative conclusion that the redaction delta does not modify Objects or
Zero-Transcoding code paths. It does not claim payload interop, transcoding
absence for a complete product pipeline or production compatibility.

### INHERITED — not merge findings

`cargo test --locked --offline -p moq-transport --lib` reproduces exactly one
protected error at `moq-transport/src/serve/tracks.rs:501`: `E0308`, expected
`TrackName`, found `&str`. `cargo fmt --all -- --check` reproduces only the two
protected baseline diffs at `moq-transport/src/serve/subgroup.rs:934` and
`moq-transport/src/serve/tracks.rs:304`.

Classification: `BLOCKED_BY_BASELINE_E0308`.

These inherited conditions are neither a merge failure nor a merge approval.
They still block a green workspace-wide gate and product pin until repaired by
their owning package.

## Verdict

**APPROVE**

Approval is limited to the frozen staged source snapshot in this report. It does
not authorize commit, product pin, dependency merge, publication, push, PR,
release, deployment or claims of production concurrency, DoS resistance,
memory boundedness, Zero-Trust completeness or Zero-Transcoding validation.

## Frozen identity reproduced at start and end

| Item | Expected | Initial | Final | Result |
| --- | --- | --- | --- | --- |
| `.cursorrules` SHA-256 | `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2` | match | match | PASS |
| `HEAD` / first parent | `59d9a8601885ef934cae29d89876abb7c7f73e89` | match | match | PASS |
| `MERGE_HEAD` / second parent | `b4ee3b68df58bbb6e7b865c2898d3f46ffbb7fd1` | match | match | PASS |
| Staged tree | `d7f0c67f4c134adc4250885f6bc031aa2efcead6` | match | match | PASS |
| Staged paths | 31 | 31 | 31 | PASS |
| Pathset SHA-256 | `5ca569098581750132c29f1e9b50d5bfefd52eee2f7d347811f27697109a7388` | match | match | PASS |
| Status-z SHA-256 | `b35e9c4f2ce80d4abd8b08e72fa8fa31b3370ad1517001ddf26cf11fc15fe426` | match | match | PASS |
| Unmerged entries | 0 | 0 | 0 | PASS |
| Unstaged paths | 0 | 0 | 0 | PASS |
| Tracking branch | none | none | none | PASS |
| Cached diff check | clean | clean | clean | PASS |
| Worktree diff check | clean | clean | clean | PASS |

The owner report SHA-256 independently matched
`531aa1e13a34a9999327c0708dbf7eab15b8597a14b9d5f0d57bb6b1fca318a7`.
The report was treated as a claim source only; bindings, diff, line ordering and
tests were reproduced independently.

## Corrective delta audited

Relative to the previously reviewed staged tree
`985f7f4ab4bad35c742f6c7028b1b8e6aec97e2b`, the current correction changes
exactly nine Rust paths: 782 insertions and 265 deletions.

| Path | Current SHA-256 | Review result |
| --- | --- | --- |
| `moq-relay-ietf/src/api.rs` | `aca75de5ecdc7e6eebca0064c72389afaa6020e24bf0e355f2c5fcdf2a1cfbda` | diagnostic resources removed; flow unchanged |
| `moq-relay-ietf/src/consumer.rs` | `311807c1b982ab9f72420e6c7fb5e4f4ce0b9bf7f1a8593626d92a1438dd7916` | resource/error Debug removed; authorization and task ownership unchanged |
| `moq-relay-ietf/src/i2_tests.rs` | `c69ffa190430cd8662f249c461be94fd74e10d9ceabe188b028c91e1f37413ec` | positive raw/WT, fixed N+1 oracle, redaction/canary coverage |
| `moq-relay-ietf/src/local.rs` | `ecacbe786afa98fbc75afbdf8cde57571a43b818662b946ee43db5c593ac2395` | low-cardinality diagnostics; cache locking/lifetime unchanged |
| `moq-relay-ietf/src/producer.rs` | `23b8ac2ea42987414aebc1f4b21c9eaf5dae182335fba00c3a2aadfd75238960` | diagnostics/error context redacted; gates and serving flow unchanged |
| `moq-relay-ietf/src/relay.rs` | `8c0df50c59ca86c132272b573604e6a10657cd6781bb70f9ed384e1262c1b3e4` | required mlog disabled; legacy mlog, C1/C2 ordering and shutdown retained |
| `moq-relay-ietf/src/remote.rs` | `ed2c2c1759dff247ecac4582021938026572a301db29a44059459b6308b7f614` | URL retained only where operationally required; diagnostics redacted; RAII/generation unchanged |
| `moq-relay-ietf/src/session.rs` | `9be32af612ae4cf7a3e3868432141adf17796eb07405d9bdb7d618570a36c60e` | request Debug removed; task semantics unchanged |
| `moq-relay-ietf/src/upstream_namespaces.rs` | `39dd2e657e511465e89fee2d24a53452ab30a9a4bb3b588d9888e98bd89f05f3` | URL/prefix/error diagnostics redacted; pull ownership/backoff unchanged |

No correction changes `moq-native-ietf`, `moq-transport`, manifests, lockfile,
protocol constants, PKI fixtures or dependency declarations. Eight non-100644
index modes are the existing `.license` symlinks; no executable or unexpected
source mode was introduced.

## Full staged inventory SHA-256

| Path | SHA-256 |
| --- | --- |
| `moq-native-ietf/src/quic.rs` | `92e94e527dce998543b050e1d4af0012b6c18df2b4e32c068ad9ebb46594934d` |
| `moq-native-ietf/src/quic_c1_tests.rs` | `610d8430315460db1652d99067002231d7ca4f2eaa48e8de2221966fa2cee8a9` |
| `moq-native-ietf/tests/data/c1/README.md` | `717d3219aa203034fde416b6e17f291e21ab9344a15e258a92aaaf3812a14e10` |
| `moq-native-ietf/tests/data/c1/SHA256SUMS` | `ba0f134515bdca4413dc9658d4016343a2180fd6c8f624e7e1b779f013696d64` |
| `moq-native-ietf/tests/data/c1/ca.cert.der` | `ea33add88bed4676c51baa4f8da9df33d04e99cecf7d0846a756e23b0f66461b` |
| `moq-native-ietf/tests/data/c1/ca.cert.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-native-ietf/tests/data/c1/server.cert.der` | `053a80b61f971f0601d83305ec6139fbcd7ed2f78c541078ac6e68a7e6da16bc` |
| `moq-native-ietf/tests/data/c1/server.cert.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-native-ietf/tests/data/c1/server.key.der` | `1d02d7ec66886fc2bb2cc3104851e1c182d7980e946d8df2e8f0f3ae33c30436` |
| `moq-native-ietf/tests/data/c1/server.key.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-relay-ietf/src/api.rs` | `aca75de5ecdc7e6eebca0064c72389afaa6020e24bf0e355f2c5fcdf2a1cfbda` |
| `moq-relay-ietf/src/consumer.rs` | `311807c1b982ab9f72420e6c7fb5e4f4ce0b9bf7f1a8593626d92a1438dd7916` |
| `moq-relay-ietf/src/i2_tests.rs` | `c69ffa190430cd8662f249c461be94fd74e10d9ceabe188b028c91e1f37413ec` |
| `moq-relay-ietf/src/lib.rs` | `833b732c738650c0ed6297c7094bdb8309da5953b9c51f950f58f1079f68b03c` |
| `moq-relay-ietf/src/local.rs` | `ecacbe786afa98fbc75afbdf8cde57571a43b818662b946ee43db5c593ac2395` |
| `moq-relay-ietf/src/producer.rs` | `23b8ac2ea42987414aebc1f4b21c9eaf5dae182335fba00c3a2aadfd75238960` |
| `moq-relay-ietf/src/relay.rs` | `8c0df50c59ca86c132272b573604e6a10657cd6781bb70f9ed384e1262c1b3e4` |
| `moq-relay-ietf/src/relay_c2_tests.rs` | `5ebccdf289a5b4183b28e78ee56dfad7f991a2c4c58eda27327c5e88f8033237` |
| `moq-relay-ietf/src/remote.rs` | `ed2c2c1759dff247ecac4582021938026572a301db29a44059459b6308b7f614` |
| `moq-relay-ietf/src/session.rs` | `9be32af612ae4cf7a3e3868432141adf17796eb07405d9bdb7d618570a36c60e` |
| `moq-relay-ietf/src/session_admission.rs` | `cc5c56db172f7fb13e1f5a1a8bea3957c096d869dd97ac3f9d9f753820f0c7ef` |
| `moq-relay-ietf/src/upstream_namespaces.rs` | `39dd2e657e511465e89fee2d24a53452ab30a9a4bb3b588d9888e98bd89f05f3` |
| `moq-relay-ietf/tests/c2_session_admission.rs` | `1b528da9ccd852d81085bad190e01ae9a5a84ca6724574ed6a7cd2904e7e0a0a` |
| `moq-relay-ietf/tests/data/c2/README.md` | `285e4e178ecd6a7c5cffe5409107bc11bdf096bba9ebc014e805c0b991c1ae72` |
| `moq-relay-ietf/tests/data/c2/SHA256SUMS` | `ccc4d9cbcc23c31cfd12e2ef5d0a57e6d0901c243f7a732fc6eba20a7c82c8fd` |
| `moq-relay-ietf/tests/data/c2/ca.cert.pem` | `c439d7428d418762e090e1ce0fdda1524473daa66f052da251e120d78555dfbb` |
| `moq-relay-ietf/tests/data/c2/ca.cert.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-relay-ietf/tests/data/c2/server.cert.pem` | `76fe11a03423308533516c61c8e06f994746293313ef8961091de0e87cbd2b09` |
| `moq-relay-ietf/tests/data/c2/server.cert.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-relay-ietf/tests/data/c2/server.key.pem` | `607642c80b7ec6e365ef877e24c526ca546542fb5c330ae191891a212b67aa35` |
| `moq-relay-ietf/tests/data/c2/server.key.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |

## Determinism, flakiness and lifecycle review

- Positive tests are `current_thread`, install a thread-local trace subscriber,
  derive one absolute deadline with `checked_add`, and wrap transport, setup,
  authorization observations, PUBLISH, PUBLISH_OK, relay shutdown and client task
  cleanup with `timeout_at`.
- The positive operation sequence uses semaphores as explicit barriers. It checks
  zero extraction/registration before each release and exactly one effect after
  both gates. No timing sleep or yield is used as synchronization.
- N+1 uses a scope semaphore to prove the first root owns the only C2 permit before
  the second transport begins. Every network/task wait is bounded by the same
  per-route absolute deadline. The two route iterations create fresh endpoints,
  admissions, counters and shutdown tokens.
- `TestMlogDir` uses process ID plus an atomic sequence, creates one isolated
  directory and removes that exact directory in `Drop`
  (`i2_tests.rs:94-116`). Runtime inspection found zero matching directories.
- Every Docker invocation used `--rm`, `--network none`, no published host port,
  read-only source and no privileged capability. Tests used only container
  loopback. No container survived.
- The external target volume was deleted after testing. No `target/` exists in
  the source worktree. No test process, host port or generated file survived.

The existing C1/C2 suites cover timeout, cancellation, server/controller drop,
setup error, run error, panic/unwind, clean close, forced shutdown, multi-endpoint
sharing, capacity recovery, terminal equations and gauges. No closed finding was
reopened because no new counterexample was observed.

## Toolchain and isolation

Local image:
`teremoq-local-rust193-components:c2-review-20260828`

Image ID:
`sha256:f522c28d5beb21591f46e8c165030f70b32dd5b51107577ad196910e7147a007`

Observed tools:

- `rustc 1.93.0 (254b59607 2026-01-19)`;
- `cargo 1.93.0 (083ac5135 2025-12-15)`;
- `rustfmt 1.8.0-stable`;
- `clippy 0.1.93`.

All Rust runs used `--network none`, source mounted `/src:ro`, local registry and
git caches mounted read-only, `--locked --offline`, and external target volume
`teremoq-integration-platform-rereview-target-20260828`. No dependency or tool
was downloaded or installed.

## Commands and independent results

The effective Docker template was:

```bash
docker run --rm --network none \
  -v /home/jimbomilk/moq-rs-teremoq-integration-work:/src:ro \
  -v teremoq-step7-cargo:/usr/local/cargo/registry:ro \
  -v teremoq-step7-git:/usr/local/cargo/git:ro \
  -v teremoq-integration-platform-rereview-target-20260828:/target \
  -w /src -e CARGO_TARGET_DIR=/target \
  teremoq-local-rust193-components:c2-review-20260828 sh -c '<command>'
```

| Command | Result |
| --- | --- |
| Focal `rustfmt --edition 2021 --check` on all nine corrected Rust paths | PASS |
| `cargo clippy --locked --offline --no-deps -p moq-native-ietf --tests -- -D warnings` | PASS |
| `cargo clippy --locked --offline --no-deps -p moq-relay-ietf --tests -- -D warnings` | PASS |
| `cargo test --locked --offline -p moq-relay-ietf required_bounded_positive_ -- --test-threads=1` | PASS 2/2: raw QUIC and WebTransport |
| `cargo test --locked --offline -p moq-relay-ietf i2_tests::bounded_required_capacity_rejects_n_plus_one_before_authentication -- --exact --test-threads=1` | PASS 1/1; both transport cases inside the test |
| `cargo test --quiet --locked --offline -p moq-native-ietf` | PASS 38/38: 32 library + 6 integration |
| `cargo test --quiet --locked --offline -p moq-relay-ietf` | PASS 202/202: 175 library + 16 binary + 10 integration + 1 doctest; 1 doctest ignored |
| `cargo fmt --all -- --check` | `BLOCKED_BY_BASELINE_E0308`: only protected `subgroup.rs:934` and `tracks.rs:304` formatting diffs |
| `cargo test --locked --offline -p moq-transport --lib` | `BLOCKED_BY_BASELINE_E0308`: exit 101, only protected `tracks.rs:501` E0308 |
| `git diff --cached --check` and `git diff --check` | PASS |
| Parent/tree/pathset/status/unmerged/unstaged/tracking checks | PASS initially and finally |

The first N+1 invocation used `--exact` without the `i2_tests::` module prefix
and therefore selected zero tests. It was not counted. The corrected fully
qualified invocation above executed 1/1.

A combined Clippy-plus-suite wrapper had a 240-second external watchdog. Both
Clippy gates completed and all suite summaries printed green, but the wrapper
expired with code 124 immediately after output. It was not accepted as final
suite evidence. Both complete suites were then rerun from cache under a fresh
60-second watchdog and returned exit 0 with the counts recorded above.

## Cleanup and mutation audit

| Resource/state | Final observation |
| --- | --- |
| Review containers | 0 |
| Published host ports | 0; no container published a port |
| `/tmp/moq-relay-i2-*` directories | 0 |
| Source-side `target/` | absent |
| External rereview target volume | removed |
| Source edits | none |
| Index edits | none |
| Merge-state edits | none |
| Manifest/lock/dependency/protocol/ADR/PKI edits | none |
| Commit/abort/fetch/push/issue/PR/release/remote mutation | none |

The only artifact created by this reviewer is this local report. Its final
SHA-256 is emitted after whitespace, placeholder, scope and frozen-identity
validation.
