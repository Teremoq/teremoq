<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# C1 TP-SEC-PKI final focal review: C1-R04

Status: **READ-ONLY SECURITY REVIEW / NO COMMIT / NO PUSH / NO PUBLICATION / NO C2**

Review date: `2026-08-28`.

Reviewer: `TP-SEC-PKI`. Code owner: `TP-RUST-DIST`.

## Findings

No open security finding was identified in C1-R04.

### C1-R04 accepted — the correction is test-only and fails closed

Location: `moq-native-ietf/src/quic_c1_tests.rs:1111-1149`, with the exact
change at lines `1132-1143`.

C1-R04 wraps the existing paired draft-16
`Session::accept`/`Session::connect` `tokio::join!` in one
`tokio::time::timeout_at(watchdog_deadline(), async { ... })`. The two setup
futures remain polled concurrently, with the same arguments and the same
success assertions. The absolute monotonic deadline is created once for the
whole logical wait; it is not restarted per future, message or poll.

On expiry, the timeout drops the joined setup future and the test fails through
the fixed string `draft-16 setup watchdog elapsed`. It cannot treat a hang as a
pass, continue with partial handles or weaken the prior fail-closed assertions.
The only added `expect` is inside `#[cfg(test)]` code and creates a deterministic
test failure, not a production panic path.

## Independent isolation proof

Binding anchors matched:

- worktree: `/home/jimbomilk/moq-rs-teremoq-c1-work`;
- branch: `teremoq/c1-bounded-handshakes-bf87128`, without tracking branch;
- HEAD/base: `bf87128affd316463e5dcc7599a45001f222b6de`;
- tree: `d76319009e815fb8923e21fc8319e17a0aaf8174`;
- stage: empty;
- production `moq-native-ietf/src/quic.rs` SHA-256:
  `b0c8dfb3e4963365a3a27f52a84d2fc54292cfc5a056a817a5a0d0a4f38b3723`;
- corrected `moq-native-ietf/src/quic_c1_tests.rs` SHA-256:
  `610d8430315460db1652d99067002231d7ca4f2eaa48e8de2221966fa2cee8a9`;
- owner report SHA-256:
  `a7cca70bc0d926739ca109cacdef1648e200255ad9c82cb33e2b521e0d2b7626`;
- status-path inventory SHA-256:
  `fc674e7161c60e0aae278ea478f6570a9606d706aa81dad0c60e2384d5e8d3f9`.

I reversed only lines 1132-1143 in an in-memory stream, without writing a
file. The resulting complete test module has SHA-256
`0366d05cd35627bf160499db9146b45cac106d41d746e16fd16cfabdf4c262c2`,
exactly the prior formally approved test snapshot. The resulting unified diff
contains only the timeout wrapper, its fixed failure assertion and rustfmt's
argument layout for the unchanged `Session::connect` call. This independently
confirms that the new hash does not conceal another source adjustment.

The delta remains exactly ten paths: `quic.rs`, `quic_c1_tests.rs`, and the
same eight fixture/provenance files under `moq-native-ietf/tests/data/c1/`.
There is no additional tracked or untracked path.

## Security impact assessment

- **No data leak:** the added code contains no logging, tracing, formatting,
  metrics, qlog/mlog output or assertion value derived from the peer. It cannot
  expose IP, CID, SNI, path, identity, certificate, key, subject, SAN, serial,
  fingerprint, payload or peer error. Its only diagnostic is a constant.
- **No dependency or feature:** `Cargo.lock`, root `Cargo.toml`,
  `moq-native-ietf/Cargo.toml`, transport and relay manifests, and both license
  texts remain byte-identical to HEAD. The correction reuses the already
  imported Tokio test API.
- **No production hook:** `quic_c1_tests.rs` is included solely by
  `#[cfg(test)]` at `quic.rs:1353-1355`. C1-R04 adds no callback, channel,
  semaphore, task, queue, observer, public API or production state.
- **No mTLS/QUIC change:** production `quic.rs`, transport setup, draft-16/ALPN,
  rustls configuration and fixture bytes are unchanged. The same established
  test sessions enter the same two MoQT setup calls.
- **No new panic boundary:** the timeout assertion can panic only in the test
  harness with a fixed message. It is absent from production builds and does
  not execute in admission, permit release, cancellation or `Drop`.
- **No fail-closed regression:** a stalled bilateral setup now has one bounded
  failure path. Successful setup must still complete on both sides before
  handles are accepted, and the pre-existing assertions still prove that C1
  capacity was released before MoQT setup begins and remains released after it.

The prior TP-SEC-PKI production approval remains valid: its production anchor
is byte-identical, its observer-removal, semaphore-bound, RAII, release/acquire,
Retry, deadline and redaction conclusions are unaffected. C1-R04 strengthens
only the liveness of the test evidence.

## Validation and owner evidence

No large build was repeated for this focal review. Independent read-only checks
performed here produced:

| Check | Result |
| --- | --- |
| Binding HEAD/tree/branch/stage and three requested SHA-256 anchors | PASS |
| In-memory reversal of only C1-R04 | PASS: exact prior SHA-256 `0366d05c…` |
| Exact changed-path inventory | PASS: ten paths |
| `git diff --check`, cached diff check and no-index check of the test module | PASS |
| Protected manifests, lockfile, setup and license comparisons to HEAD | PASS: unchanged |
| Static scan of the C1-R04 block for sensitive output, hooks, tasks, queues and `unsafe` | PASS: none |

The binding owner report records the post-C1-R04 focused evidence:

- focal rustfmt check: PASS;
- `cargo test --locked --offline -p moq-native-ietf c1_` under an external
  watchdog: PASS, 25 passed, 0 failed, 1 filtered;
- full native package tests: PASS, 26/26 unit tests and zero doctest failures;
- no-index whitespace check of the corrected test module: PASS.

Those owner executions are supporting evidence and are not represented as
independent reruns by this reviewer.

## Residual gate

C1-WR-03 remains `BLOCKED_BY_BASELINE_E0308` at unchanged
`moq-transport/src/serve/tracks.rs:501`. C1-R04 neither touches nor approves
that baseline failure. The local-commit approval below does not authorize C2,
integration, package/release gates, push, publication or remote mutation.

## Verdict

APPROVE FOR LOCAL COMMIT
