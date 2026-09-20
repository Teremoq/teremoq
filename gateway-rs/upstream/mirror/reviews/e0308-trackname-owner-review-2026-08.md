<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# E0308 TrackName baseline repair owner review

Date: 2026-08-28 10:42:32 UTC

Owner: `TP-RUST-DIST`

State: **READY FOR FORMAL REVIEW**

LOCAL STAGED PACKAGE / NOT COMMITTED / NOT PUSHED / NO REMOTE MUTATION

## Findings first

### Closed: inherited `BLOCKED_BY_BASELINE_E0308`

The approved base reproducibly failed its `moq-transport` library test build at
`moq-transport/src/serve/tracks.rs:501`. The test's expected track name was a
`&str`, while `TrackWriter::name` is the upstream `TrackName` newtype. Rust does
not provide cross-type `PartialEq<str>` for this newtype, so `assert_eq!`
produced E0308 before any test ran.

The minimal semantic repair uses the existing, public and already used
`impl From<&str> for TrackName`:

```rust
assert_eq!(track_writer.name, TrackName::from(track_name));
```

This is inside the existing `#[cfg(test)]` module. It changes no production
path, type, API, wire encoding, Track/Group/Object behavior or dependency. The
existing `tracks_subscribe_round_trip` test is the focused regression: it now
compiles, receives the typed name created by `TracksReader::subscribe`, checks
exact equality and completes its object round trip. A second test would merely
duplicate that same path and was not added.

### Closed: two inherited rustfmt-only hunks

The base `cargo fmt --all -- --check` reported exactly two diffs:

- wrapping the long `result.expect(...)` expression at
  `moq-transport/src/serve/subgroup.rs:934`;
- compacting the chained `obj.read_all().await.expect(...)` expression at
  `moq-transport/src/serve/tracks.rs:304`.

Only those exact rustfmt transformations were applied. A post-change full
workspace rustfmt check passes and no additional file or hunk was produced.

### No remaining owner finding in this package

All required local gates pass. This does not constitute independent review,
publication approval, a product pin, production readiness or approval of later
RustSec batches.

## Binding base and isolation

| Item | Value |
| --- | --- |
| `.cursorrules` SHA-256 | `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2` |
| Base commit | `afeaa94cb41491a07ce55010ff00a88d5e8716a9` |
| Base tree | `4696ae59a07ec1b3930a654e03e412221f9a8a5d` |
| Base and final lock SHA-256 | `d6196fd8f31ea3b2cabbdb0e57546810643f344567f3e358ee3c000b3e2b59f5` |
| Isolated worktree | `/home/jimbomilk/moq-rs-teremoq-e0308-work` |
| Local branch | `teremoq/fix-baseline-trackname-e0308` |
| Tracking branch | none |
| Integrated base worktree | clean and unchanged at the base commit/tree/lock above |

The relevant architectural constraints were reread from ADR-0004 through
ADR-0007. Their SHA-256 values were respectively
`6bbf8b43e8227e09673cca8e7f832a0c4b5d1e9f8df7dc2c9f2abc697b600689`,
`8b4b9bb58f399e0a999343af78d61fdd85ea59a95cfa7d42dc96047882257a53`,
`ca08d106e10b3e903cecd45292ce8b75d80e77c06c1c451d97d021306623baf3`
and `0085bdaa37cd3645a4a2c5a3163b0b096453b84f66635514fce6015d6bed25d8`.

## Reproduction before repair

The base was mounted read-only in the Rust 1.93 container with local read-only
Cargo caches, an external target and `--network none`. This command exited 101:

```text
cargo test --locked --offline -p moq-transport --lib
```

The only compiler diagnostic was:

```text
error[E0308]: mismatched types
  --> moq-transport/src/serve/tracks.rs:501:43
expected `TrackName`, found `&str`
```

The compiler's suggested `track_name.into()` and the source inventory both
confirmed that the existing upstream conversion is the correct boundary. The
explicit `TrackName::from(track_name)` form was selected because the expected
type remains visible in the regression assertion and matches two nearby tests
already present in the same module.

## Exact staged delta

| Path | Base SHA-256 | Staged SHA-256 | Delta |
| --- | --- | --- | --- |
| `moq-transport/src/serve/subgroup.rs` | `f5c21e89c18dd21f8900d491920ad3b378653df3d4d5bfe0f176d928cf972382` | `30d401d94aba88cf89e828ee348db2ac1bbc521bdc8ec5c3f282ee12e4b200d7` | rustfmt only, 2 insertions / 1 deletion |
| `moq-transport/src/serve/tracks.rs` | `a8303c94925707a0a257923725bf84e4ec730b07d6bb2330fda5329b632fe0b7` | `412a2fc82c143eb6c1f0040b44f66794d4cd9fed8c3e63db5d6a2e8635ef0bec` | one typed assertion plus rustfmt, 3 insertions / 5 deletions |

The staged binary diff SHA-256 is
`2e1090c4b991b25abcaad81cca670075ad471c2a5ce54dd0bb08f07285debb22`.
There are five insertions and six deletions in total, all inside existing test
modules. No production logic or documentation within the derivative changed.

## Frozen staged state

| Item | Value |
| --- | --- |
| `HEAD` | `afeaa94cb41491a07ce55010ff00a88d5e8716a9` |
| `HEAD^{tree}` | `4696ae59a07ec1b3930a654e03e412221f9a8a5d` |
| Staged tree (`git write-tree`) | `cccd0d60c9ebfe191dca9d73e7ab8b27ae4d4ea5` |
| Staged paths | the two paths listed above, exactly |
| Pathset SHA-256 | `37546925cd09e15789c286e450c705bdf0db51781cb2a28f3ce9f2731b797799` |
| Status-z SHA-256 | `3e66c5d217fdb0ec2f11fa3816a276857afbef697a587d9e980a936189ad1000` |
| Unmerged entries | zero |
| Unstaged paths | zero |
| Tracking branch | none |

`git diff --check` before staging and `git diff --cached --check` after staging
both pass.

## Dependency, provider and protocol invariants

`Cargo.lock` remains byte-identical and contains 336 package records. All ten
tracked Cargo manifests and every feature declaration are unchanged. Selected
security/transport versions remain:

- `bytes 1.11.1`;
- `quinn 0.11.9` and `quinn-proto 0.11.15`;
- `rustls 0.22.4` and `0.23.31`;
- `rustls-webpki 0.102.4` and `0.103.4`;
- `aws-lc-rs 1.13.3` and `aws-lc-sys 0.30.0`.

Therefore Batch T is absent: neither AWS-LC nor rustls-webpki moved. There is no
new package, license, provider, feature, parser, API, `unsafe`, second
transport, TLS/mTLS/identity/authorization/concurrency/logging change, or
change to draft-16, ALPN, setup, serialization, Tracks, Groups or Objects.

## Toolchain and hermetic validation

Final validation mounted the source read-only, used an external target, mounted
the pre-existing Cargo registry and Git caches read-only, disabled networking
with Docker `--network none`, and bounded Cargo commands with `timeout`.

| Tool/gate | Result |
| --- | --- |
| Reproduction image `teremoq-step7-lab:rust-1.93-full`, ID `sha256:ba076cf0a26aa41efdd2f0f80687ef97009d1526680751456c19cc944dff1d0b` | Rust 1.93.0 / Cargo 1.93.0; reproduced exact E0308 |
| Final image `teremoq-local-rust193-components:c2-review-20260828`, ID `sha256:f522c28d5beb21591f46e8c165030f70b32dd5b51107577ad196910e7147a007` | Rust/Cargo 1.93.0, rustfmt 1.8.0, Clippy 0.1.93 |
| `cargo fmt --all -- --check` | PASS; zero diff |
| `cargo check --locked --offline -p moq-transport` | PASS |
| `cargo test --locked --offline -p moq-transport` | PASS: 270 library + 1 integration; one doctest ignored |
| `cargo clippy --locked --offline --no-deps -p moq-transport --tests -- -D warnings` | PASS |
| Transport `check/test/clippy` repeated with `--all-targets --all-features` and `-D warnings` | PASS; 271 tests executed |
| `cargo test --locked --offline -p moq-native-ietf` | PASS: 32 library + 6 integration; raw QUIC, WebTransport, I1 and C1 covered |
| `cargo test --locked --offline -p moq-relay-ietf` | PASS: 175 library + 16 binary + 10 integration + 1 doctest; one separate doctest ignored; I2/C2/raw/WebTransport covered |
| Native + relay Clippy test targets with `-D warnings` | PASS |
| Objects/draft regressions | PASS in transport suite: object encode/decode/status, subgroup forwarding/reset/finish, typed track round trip and draft-16 layouts |
| Locked metadata without deps | PASS; JSON SHA-256 `9506420f2a7fd10f307a9936e2ce33a2fcbb6d66fe55add5cf933e15d81160d8` |
| Locked Linux metadata with dependencies | PASS: 233 packages/nodes; JSON SHA-256 `e9b3fedb56f92e20f2f67cfff3fbe8163666023811a1c407dfa72979f509175c` |
| REUSE 5.1.1, image ID `sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da` | PASS: 223/223 files, MIT and Apache-2.0, zero errors |
| Gitleaks 8.30.1/MIT, image ID `sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f` | PASS: 764,075 bytes scanned in `moq-transport`, zero findings, fully redacted |

Both Cargo metadata commands completed and produced the hashes above. The final
auxiliary in-container JSON-count command was unavailable because that minimal
image contains no Python; the same immutable JSON was parsed read-only by host
Python and yielded 233 packages and 233 resolve nodes. No tool was installed.

## Cleanup and handoff

The 4.36 GB external validation target was removed after the gates. The source
worktree has no `target/`; no validation container or process remains. The
approved integration-base worktree remains clean. No commit, fetch, push, tag,
issue, pull request, release, network communication or remote mutation occurred.

The exact next gate is independent formal review of staged tree
`cccd0d60c9ebfe191dca9d73e7ab8b27ae4d4ea5`. A later explicit authorization is
required before creating a local commit, publishing anything or changing a
product pin.
