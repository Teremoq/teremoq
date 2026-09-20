<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# TP-PLATFORM-CHAOS review: E0308 TrackName package

Date: 2026-08-28  
Scope: independent read-only review of the staged package in `/home/jimbomilk/moq-rs-teremoq-e0308-work`  
Owner evidence: `e0308-trackname-owner-review-2026-08.md`, SHA-256 `f47f559a169d1a10ca30a00c1f26c56f676f66beabbe234c5d4b029f0d9e9ffd`

## Findings

No Critical, High, Medium, or Low finding is attributable to staged tree `cccd0d60c9ebfe191dca9d73e7ab8b27ae4d4ea5`.

### Informational — the inherited E0308 is reproduced and closed by one test-only type correction

An immutable `git archive` of base commit `afeaa94cb41491a07ce55010ff00a88d5e8716a9` reproduced exactly one compiler diagnostic when running the `moq-transport` library tests:

```text
error[E0308]: mismatched types
  --> moq-transport/src/serve/tracks.rs:501:43
expected `TrackName`, found `&str`
```

The base command exited `101` before tests ran. The staged assertion is:

```rust
assert_eq!(track_writer.name, TrackName::from(track_name));
```

It is inside the existing `#[cfg(test)] mod tests` and uses the existing public `impl From<&str> for TrackName` at `moq-transport/src/coding/track_namespace.rs:164`. The staged `moq-transport` all-target/all-feature check, tests, and Clippy pass, and the focused `tracks_subscribe_round_trip` regression passes 1/1 while reading all five Objects.

### Informational — the other two hunks are exact rustfmt output

Running rustfmt 1.8.0 in check mode against the immutable base produced exactly two diffs:

- wrapping `result.expect(...)` in `moq-transport/src/serve/subgroup.rs`;
- compacting the `obj.read_all().await.expect(...)` chain in `moq-transport/src/serve/tracks.rs`.

Those diffs are byte-for-byte the two non-semantic staged hunks. A full staged `cargo fmt --all -- --check` produces no diff. No source was formatted in place during this review.

### Informational — no production or protocol surface changed

All three staged hunks are within existing test modules. There is no staged manifest or lockfile change, and no production statement, API, wire constant, ALPN, draft-16 setup/message, Track/Group/Object path, encoded payload path, admission controller, task, timeout, cancellation, shutdown, or lifecycle implementation changed.

The unchanged native and relay packages pass their complete all-target/all-feature check, test, and Clippy gates with real raw QUIC and WebTransport test paths. Existing I1, I2, C1, C2, N+1, deadline, RAII, recovery, and shutdown tests remain green.

## Verdict

APPROVE

This verdict is restricted to the frozen local staged package identified below. It does not authorize a commit, publication, product pin, remote mutation, or later dependency batch, and it is not a claim of external interoperability or production readiness.

## Frozen binding

The complete binding was checked before review execution and again after tests and cleanup:

| Item | Observed value |
|---|---|
| `.cursorrules` SHA-256 | `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2` |
| `HEAD` / base commit | `afeaa94cb41491a07ce55010ff00a88d5e8716a9` |
| base tree | `4696ae59a07ec1b3930a654e03e412221f9a8a5d` |
| staged tree | `cccd0d60c9ebfe191dca9d73e7ab8b27ae4d4ea5` |
| staged paths | `moq-transport/src/serve/subgroup.rs`; `moq-transport/src/serve/tracks.rs` |
| staged path count | `2` |
| newline pathset SHA-256 | `37546925cd09e15789c286e450c705bdf0db51781cb2a28f3ce9f2731b797799` |
| `git status --short -z` SHA-256 | `3e66c5d217fdb0ec2f11fa3816a276857afbef697a587d9e980a936189ad1000` |
| `Cargo.lock` SHA-256 | `d6196fd8f31ea3b2cabbdb0e57546810643f344567f3e358ee3c000b3e2b59f5` |
| unmerged paths | `0` |
| unstaged paths | `0` |
| upstream tracking | none |
| cached binary diff SHA-256 | `2e1090c4b991b25abcaad81cca670075ad471c2a5ce54dd0bb08f07285debb22` |

`git diff --cached --check` passes. The final status contains only the two expected staged modifications.

## Exact delta audit

| Path | Base SHA-256 | Staged SHA-256 | Independent classification |
|---|---|---|---|
| `moq-transport/src/serve/subgroup.rs` | `f5c21e89c18dd21f8900d491920ad3b378653df3d4d5bfe0f176d928cf972382` | `30d401d94aba88cf89e828ee348db2ac1bbc521bdc8ec5c3f282ee12e4b200d7` | rustfmt only; 2 insertions, 1 deletion |
| `moq-transport/src/serve/tracks.rs` | `a8303c94925707a0a257923725bf84e4ec730b07d6bb2330fda5329b632fe0b7` | `412a2fc82c143eb6c1f0040b44f66794d4cd9fed8c3e63db5d6a2e8635ef0bec` | one typed test assertion plus rustfmt; 3 insertions, 5 deletions |

The staged diff totals five insertions and six deletions. Zero manifest/lock path is present. The `#[cfg(test)]` modules begin at `subgroup.rs:636` and `tracks.rs:283`; every changed line is below the applicable marker.

## Hermetic environment

All Rust validation used the pre-existing local image:

```text
teremoq-local-rust193-components:c2-review-20260828
sha256:f522c28d5beb21591f46e8c165030f70b32dd5b51107577ad196910e7147a007
```

Observed tools:

```text
rustc 1.93.0 (254b59607 2026-01-19)
cargo 1.93.0 (083ac5135 2025-12-15)
rustfmt 1.8.0-stable (254b59607d 2026-01-19)
clippy 0.1.93 (254b59607d 2026-01-19)
```

Containers used `--network none`; sources were mounted read-only; the existing Cargo registry and Git caches were mounted read-only; Cargo used `--locked --offline`; and build output was isolated in the dedicated external volume `teremoq-e0308-platform-review-target-20260828`. Commands were bounded by outer watchdogs of 300, 600, or 900 seconds. No package or tool was downloaded or installed.

## Commands and results

| Command | Result |
|---|---|
| Base: `cargo fmt --all -- --check` | Expected exit 1; exactly the two staged rustfmt-only hunks |
| Staged: `cargo fmt --all -- --check` | PASS; zero diff |
| Base: `cargo test --locked --offline -p moq-transport --lib` | Expected exit 101; exact E0308 at `tracks.rs:501`, no other compiler diagnostic |
| `cargo check --locked --offline -p moq-transport --all-targets --all-features` | PASS |
| `cargo test --locked --offline -p moq-transport --all-targets --all-features` | PASS: 270 library + 1 integration = 271 passed, 0 failed |
| `cargo clippy --locked --offline -p moq-transport --all-targets --all-features -- -D warnings` | PASS |
| `cargo test --locked --offline -p moq-transport --all-features serve::tracks::tests::tracks_subscribe_round_trip -- --exact` | PASS: 1/1 focused typed round-trip; duplicate of the full suite and not added to the unique total |
| `cargo check --locked --offline -p moq-native-ietf -p moq-relay-ietf --all-targets --all-features` | PASS |
| `cargo test --locked --offline -p moq-native-ietf -p moq-relay-ietf --all-targets --all-features` | PASS: native 32 library + 6 integration; relay 175 library + 16 binary + 10 integration; 239 passed, 0 failed |
| `cargo clippy --locked --offline -p moq-native-ietf -p moq-relay-ietf --all-targets --all-features -- -D warnings` | PASS |
| `cargo test --locked --offline -p moq-native-ietf -p moq-relay-ietf --all-features --doc` | PASS: native 0 doctests; relay 1 passed and 1 ignored |

Unique executed tests across the three package suites and relay doctests: 511 passed, 0 failed, 1 ignored. The focused round-trip rerun is intentionally excluded from that total.

## Compatibility and runtime evidence

- **Objects and TrackName:** `tracks_subscribe_round_trip` validates typed name equality and then drains five Objects. The full transport suite also passes subgroup Object encoding/decoding, status, forwarding, reset, finish, multi-group, and multi-object cases.
- **MoQT draft-16 and wire:** `draft16_wire_layouts_for_changed_control_messages`, `draft_16_version_constant`, `c1_wire_constants_are_unchanged`, and `i2_does_not_change_wire_constants_or_object_types` pass.
- **Raw QUIC and WebTransport:** native peer-evidence coverage passes both transports; C1 raw/WebTransport completion and legacy compatibility pass; relay required/bounded positive and exact N+1 tests pass for both transports.
- **I1/I2/C1/C2:** the full suites pass connection-bound evidence, fail-closed authorization ordering, distinct handshake/session admission, immediate N+1, shared limits, permit recovery, and zero-effect rejection cases.
- **Lifecycle:** cancellation, absolute deadlines, setup/run errors, panic containment, owner drop, cooperative/forced shutdown, and final zero-gauge tests pass unchanged.
- **Zero-Transcoding:** no production or encoded-payload path changed. This proves absence of a new transcoding path in this package, not end-to-end media conformance.

Because the delta is test-only, the passing runtime matrix is a regression check for the unchanged product behavior rather than evidence that the package introduced or improved those behaviors.

## Cleanup and residue

Every test container used `--rm`; no host port, Docker network, qdisc, or `NET_ADMIN` capability was created. After validation:

- review containers: `0`;
- dedicated target volumes: `0`;
- review Cargo processes: `0`;
- immutable base archive directory: removed;
- worktree-local `target/`: absent;
- source/index binding: unchanged.

## Limitations

- These are local self-regressions against the pinned implementation. They do not establish interoperability with an external MoQT/WebTransport implementation or browser.
- No Chaos, load, soak, packet impairment, memory-slope, or production-capacity run was authorized or needed for this test-only repair.
- Passing raw QUIC/WebTransport and Object regressions does not by itself certify a deployment, SLO, DoS bound, or end-to-end Zero-Transcoding media pipeline.
- This review does not authorize a commit, publication, remote action, dependency update, product pin, or C1/C2 production claim.

