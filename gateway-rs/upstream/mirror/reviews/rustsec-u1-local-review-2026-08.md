<!--
SPDX-FileCopyrightText: 2026 Teremoq contributors
SPDX-License-Identifier: Apache-2.0
-->

# RustSec Batch U1 local implementation review

Status: **READY FOR TP-OSS-SC REVIEW**  
Owner: `TP-RUST-DIST`  
Required independent reviewer: `TP-OSS-SC`  
Evidence captured: 2026-08-28T00:25:22Z

This report covers an isolated, local, uncommitted lockfile update. It is not
publication approval. It does not change source, manifests, product pins,
features, protocol behavior, I1, I2, C1, or any remote state.

## Findings

### High: publication remains blocked outside Batch U1

The frozen audit remains nonzero after U1: 16 vulnerability entries and six
allowed warnings belong to later remediation batches. The derivative also has
no reviewed `deny.toml`; a meaningful cargo-deny license gate therefore remains
unavailable. U1 must not be described as making the derivative publication
ready.

### Medium: full all-target gates retain an unchanged baseline compiler error

Workspace all-target check, test, and Clippy stop at the pre-existing E0308 in
`moq-transport/src/serve/tracks.rs:501`: the unchanged test compares a
`TrackName` with `&str`. `cargo test -p moq-transport` and
`cargo clippy -p moq-transport --tests` fail at the same line. The source file
has no U1 delta and this batch does not repair or absorb the failure.

Clippy over the other focal test targets additionally reports the unchanged
`clippy::items-after-test-module` finding in `moq-pub/src/main.rs:163`. Rustfmt
retains the two known baseline diffs in `moq-transport/src/serve/subgroup.rs`
and `moq-transport/src/serve/tracks.rs`.

### Low: two offline inventory gates lacked unrelated cached target sources

A full offline `cargo metadata` and cargo-deny attempt required the uncached
`android-tzdata 0.1.1` and `web-transport-wasm 0.5.7` source archives. No broad
fetch was performed to complete that cache. Locked metadata without dependency
source loading passed, normal/all-feature workspace compilation passed after
read-only registry downloads, and the exact lock record comparison below is
complete. `TP-OSS-SC` should execute its independently populated SBOM and
cargo-deny environment before any publication decision.

## Binding base and isolation

- Remediation plan SHA-256:
  `a36cf64bb336cd99fe8f0e2984e64a8eb20ec3a49da91fce6f3c146d4d7a4bf2`.
- Exact Q base commit:
  `1e9d1ee62bde97145a0914e5992ab7f54fc909c4`.
- Q tree: `4cf25aeea2eacd02394608c80c9677eaa001ef87`.
- Q parent: `bf87128affd316463e5dcc7599a45001f222b6de`.
- Local branch: `teremoq/rustsec-u1-1e9d1ee`, with no tracking branch.
- Q `Cargo.lock` SHA-256:
  `a249c6296affe18cdd726324539e52e6783718fbd2c1e63ec7ab4bdd95b27e9b`.
- U1 `Cargo.lock` SHA-256:
  `0b8ebcce6495ea65cc0acb0a94852e0067f78b06aa956dc8a368195bce626e19`.

The I1/I2 worktree and the Q worktree remained clean. The independent C1
worktree retained only its existing C1 source/test/fixture changes. U1 did not
edit any of them.

## Resolution and exact delta

The precise resolver command, using Cargo 1.93.0, was:

```text
cargo update -p bytes@1.6.0 --precise 1.11.1
```

The final diff is exactly four lockfile lines:

```text
bytes 1.6.0 -> 1.11.1
checksum 514de17de45fdb8dc022b1a7975556c53c86f9f0aa5f534b98977b171857c2c9
      -> 1e748733b7cbc798e1434b6ac524f0c1ff2ab456fe201501e6497c8417a4fc33
```

Both locks contain 336 package records. Removing only the `bytes` record from
each lock produces the identical SHA-256
`22e40645b132aaabb34abbd59ad2098cfdbf1a100dee889f1435b9f5628b6b3a`.
There is no addition, removal, provider change, or other version movement.

The direct `bytes = "1"` constraints in `moq-transport`, `moq-pub`, and
`moq-test-client` already accept 1.11.1; every manifest is byte-identical.
Before and after feature trees select only `bytes` features `default` and
`std`, with the same direct and transitive consumers. Those include the MoQT
transport, QUINN, WebTransport, Tokio, `http`, `http-body`, H2, Hyper, Redis,
MP4, publisher, and test client paths.

## Advisory, provenance, license, and safe fix analysis

The read-only official RustSec database was fixed at:

- origin: `https://github.com/RustSec/advisory-db.git`;
- commit: `6420e39260b3d771b049954cf5d52b57e2118da4`;
- tree: `01794d45488a521b322b760b6bfdcd6e9f28932b`;
- root license: CC0-1.0, with `RUSTSEC-2026-0007` marked CC-BY-4.0.

`cargo-audit 0.22.2`, `MIT OR Apache-2.0`, executable SHA-256
`66f9c8f530950d106c1869ce27ef5a4008bcea53c7716c3ed8117586337ee7d8`,
ran with `--no-fetch`, the fixed database, and no ignore or suppression:

| Snapshot | Exit | Vulnerability entries | Warnings | U1 advisory |
|---|---:|---:|---:|---|
| Q | 1 | 17 | 6 | `bytes 1.6.0` matched `RUSTSEC-2026-0007` |
| U1 | 1 | 16 | 6 | no finding against `bytes 1.11.1` |

The crate archive SHA-256 is
`1e748733b7cbc798e1434b6ac524f0c1ff2ab456fe201501e6497c8417a4fc33`,
exactly matching the lock and official sparse-index record. The record is not
yanked. Packaged metadata identifies `bytes 1.11.1`, repository
`https://github.com/tokio-rs/bytes`, license `MIT`, and MSRV Rust 1.57. The
packaged `LICENSE` SHA-256 is
`45f522cacecb1023856e46df79ca625dfc550c94910078bd8aec6e02880b3d42`.
No new package or license enters the graph.

The fixed `BytesMut` unique-reclaim path computes `new_cap + offset` with
`checked_add` and panics before allocation on overflow. The official
`bytes_mut_reserve_overflow` test passed. It starts with the small published
fixture and confirms the checked panic; it does not perform an allocation near
`usize::MAX`. No custom maximum-size allocation or hostile OOM experiment was
introduced.

## Protocol and source invariants

Only `Cargo.lock` differs. In particular:

- all `Cargo.toml` files and all Rust source files have no diff;
- `moq-transport/src/setup/mod.rs` remains SHA-256
  `c49d71dcacd5e3f5eef7a673e11b9058d3fd701e1fb83331a737098894a2d750`;
- `moq-native-ietf/src/quic.rs` remains SHA-256
  `eaa9b00e0ad8eba9ae24f59b14165b252edc1d3857d8fb0cc21649f60070c094`;
- `moq_transport::setup::ALPN` remains `b"moqt-16"`;
- draft-16, setup encoding, varints, frame sizes, MoQT Objects,
  WebTransport/raw QUIC selection, features, providers, and public APIs have no
  source or manifest delta;
- `LICENSES/Apache-2.0.txt`, `LICENSES/MIT.txt`, and `REUSE.toml` remain
  byte-identical, with SHA-256 values
  `1248f876e0140942002b476a19c95d5b5b44c625e69c96611d23119ee87fa04e`,
  `c7d191b5901a741f2e39c74bd7a7594014a81fbe2bc7d533d4c29ad4cfe4e057`,
  and `afc7fd86e591a56078b11982ee4d039ea1dfe3f9d56a90e3e7fa9f84fbddb6cc`.

The logical SBOM delta is one component replacement from `bytes 1.6.0` to
`1.11.1` with the same crates.io provider and consumer graph. A generated SBOM
comparison remains a required independent `TP-OSS-SC` gate.

## Toolchain and executed matrix

Rust ran from the official image fixed at
`rust:1.93.0-slim-bookworm@sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57`:

```text
rustc 1.93.0 (254b59607 2026-01-19)
cargo 1.93.0 (083ac5135 2025-12-15)
clippy 0.1.93 (254b59607d 2026-01-19)
rustfmt 1.8.0-stable (254b59607d 2026-01-19)
```

Clippy and rustfmt were installed only in the ephemeral container. Source was
mounted read-only and Cargo output used an external volume.

| Command or gate | Result |
|---|---|
| `cargo metadata --locked --offline --format-version 1 --no-deps` | PASS |
| full offline metadata | INCOMPLETE; uncached unrelated `android-tzdata 0.1.1` |
| before/after inverse and feature trees for `bytes` | PASS; same graph and features, version only |
| relay normal/build and all-feature trees | PASS; hashes recorded, `bytes 1.11.1`, `quinn-proto 0.11.15` |
| focal locked check: transport, API, publisher, test client | PASS |
| `cargo check --locked --workspace --all-features` | PASS |
| workspace all-target/all-feature check | BASELINE FAIL; E0308 at unchanged `tracks.rs:501` |
| official `bytes` overflow regression | PASS; 1/1, checked panic before allocation |
| official `bytes` buffer suites | PASS; 820 `Buf`, 23 `BufMut`, 115 `BytesMut` tests |
| API/publisher/test-client tests | PASS; 2 passed, zero failed |
| native and relay tests | PASS; 1 native, 119 relay lib, 16 relay bin, 1 relay doctest; one doctest ignored |
| `moq-transport` doctests | PASS; one ignored, zero failed |
| full `moq-transport` tests | BASELINE FAIL; E0308 at unchanged `tracks.rs:501` |
| workspace all-feature tests | BASELINE FAIL; same E0308 |
| focal Clippy, normal targets, `-D warnings` | PASS |
| focal/Workspace Clippy all test targets | BASELINE FAIL; E0308; separate unchanged `moq-pub` ordering lint observed |
| `cargo fmt --all -- --check` | BASELINE FAIL; two known unchanged formatting diffs |
| frozen cargo-audit comparison | PASS for U1; exactly one vulnerability entry removed |
| cargo-deny offline attempt | INCOMPLETE; unrelated target sources absent; no reviewed license policy exists |
| `cargo package --locked -p moq-relay-ietf --list --allow-dirty` | PASS; 23 paths |
| REUSE 5.1.1 fixed image | PASS; 190/190, MIT and Apache-2.0 |
| Gitleaks 8.30.1 fixed image over `Cargo.lock` | PASS; zero findings, output redacted |
| `git diff --check` and cached diff check | PASS |
| stage, tracking, and changed-path inventory | PASS; empty stage, no tracking, only `Cargo.lock` |

The authoritative Gitleaks run used image
`zricethezav/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f`,
licensed MIT. A first invocation used the obsolete `--no-git` flag and exited
before scanning; the corrected `dir` invocation passed. REUSE used
`fsfe/reuse:5.1.1@sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da`,
licensed GPL-3.0-or-later and kept outside project artifacts.

## Rollback, review boundary, and state

Rollback is exactly restoration of the Q lock SHA-256 above. That would
deliberately restore `RUSTSEC-2026-0007` and is not an acceptable steady state.
No source or manifest change accompanies either the update or rollback.

The next authorized step is independent `TP-OSS-SC` review of this exact
lock-only snapshot, including its generated SBOM/current-database and policy
gates. It is not authorization to combine U1 with T, H, U2, I1, I2, or C1.

**READY FOR TP-OSS-SC REVIEW / LOCAL ONLY / NOT COMMITTED / NOT PUSHED / NOT PUBLICATION READY**

No Git fetch, commit, stage, push, tag, release, PR, issue, remote ref, or
remote-setting mutation occurred. Cargo and crates.io index/archive access was
read-only and did not change any remote state.
