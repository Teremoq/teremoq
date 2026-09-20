<!--
SPDX-FileCopyrightText: 2026 Teremoq contributors
SPDX-License-Identifier: Apache-2.0
-->

# RustSec Batch Q local implementation review

Status: **READY FOR TP-OSS-SC REVIEW**  
Owner: `TP-RUST-DIST`  
Required independent reviewer: `TP-OSS-SC`  
Evidence captured: 2026-08-27T23:07:57Z

This report covers a local, uncommitted dependency-resolution batch only. It is
not a publication approval and does not alter I1, I2, C1, product pins, protocol
source, or any remote repository state.

## Binding inputs

- Remediation plan SHA-256:
  `a36cf64bb336cd99fe8f0e2984e64a8eb20ec3a49da91fce6f3c146d4d7a4bf2`.
- Upstream baseline commit:
  `bf87128affd316463e5dcc7599a45001f222b6de`.
- Baseline tree: `d76319009e815fb8923e21fc8319e17a0aaf8174`.
- Local branch: `teremoq/rustsec-q-bf87128`, with no upstream/tracking ref.
- Baseline `Cargo.lock` SHA-256:
  `b518a2fa4a6d7a0ffe0bdfe4b530f05196ac0f5e6f7ef51da9e5a83c0b0561c0`.
- Current `Cargo.lock` SHA-256:
  `a249c6296affe18cdd726324539e52e6783718fbd2c1e63ec7ab4bdd95b27e9b`.

The isolated worktree started at the exact baseline commit and tree. The
protected I2 checkout was clean at its reviewed local commit before this batch;
the separate C1 worktree retained its pre-existing local C1 changes. Neither
was edited.

## Resolution and exact delta

The resolver command was:

```text
cargo update -p quinn-proto@0.11.13 --precise 0.11.15
```

Cargo 1.93.0 initially also normalized the unrelated `libloading 0.8.3`
dependency reference from `windows-targets 0.48.5` to `0.52.6`. That movement
was not transitively required by `quinn-proto`. The baseline reference was
restored, after which both `cargo metadata --locked` and the downstream locked
build accepted the minimal lock. The final diff contains exactly:

```text
quinn-proto 0.11.13 -> 0.11.15
checksum f1906b49b0c3bc04b5fe5d86a77925ae6524a19b816ae38ce1e426255f1d8a31
      -> 4fcb935c5bec503c2f0e306bdd3e58bb9029dcb14fa8d9ac76e3a5256ac0763e
```

`Cargo.lock` has two removed and two added lines. Package-coordinate
inventories contain 336 entries both before and after; their only difference is
the version replacement above. No package, provider, build script, manifest,
feature, API, source file, fixture, or license file was added or removed.

`cargo tree --locked -i quinn-proto` before and after showed the same chain:

```text
quinn-proto 0.11.13/0.11.15
└── quinn 0.11.9
    ├── moq-native-ietf 0.10.0
    └── web-transport-quinn 0.11.8
```

Normal/build and all-feature trees for `moq-relay-ietf` continue to select
`quinn 0.11.9`, `quinn-udp 0.5.14`, `web-transport-quinn 0.11.8`, and the single
`quinn-proto 0.11.15` package. The selected crypto-provider feature graph is
unchanged.

## Advisory comparison

The frozen primary RustSec database was used read-only:

- origin: `https://github.com/RustSec/advisory-db.git`;
- commit: `6420e39260b3d771b049954cf5d52b57e2118da4`;
- tree: `01794d45488a521b322b760b6bfdcd6e9f28932b`;
- default license CC0-1.0, with individually marked CC-BY-4.0 imports.

The audited executable was `cargo-audit 0.22.2`, `MIT OR Apache-2.0`, SHA-256
`66f9c8f530950d106c1869ce27ef5a4008bcea53c7716c3ed8117586337ee7d8`.
Both runs used `audit --no-fetch --db <frozen-db> --file <lock>` with no
allowlist, ignore, or suppression.

| Snapshot | Exit | Vulnerabilities | Allowed warnings | Batch Q result |
|---|---:|---:|---:|---|
| Baseline lock | 1 | 19 | 6 | `quinn-proto 0.11.13` matched both Q advisories |
| Updated lock | 1 | 17 | 6 | no `quinn-proto` advisory reported |

The exact Batch Q advisories are:

- `RUSTSEC-2026-0037` / CVE-2026-31812 / GHSA-6xvm-j4wr-6v98:
  invalid QUIC transport parameters can panic an endpoint; fixed in
  `quinn-proto >=0.11.14`.
- `RUSTSEC-2026-0185` / CVE-2026-25800 / GHSA-4w2j-m93h-cj5j:
  unbounded out-of-order stream-reassembly gaps can exhaust receiver memory;
  fixed in `quinn-proto >=0.11.15`.

The global audit remains red because 17 vulnerability entries and six warnings
belong to other planned remediation batches. The audit client also warned that
its crates.io index was unavailable, but it completed against the explicitly
pinned local database and both lockfiles. A then-current database scan was not
performed: Git fetch was outside this package's authorization and the existing
non-frozen cache did not contain a usable Git object graph. `TP-OSS-SC` must
repeat a current-database scan before any publication decision.

## Provenance and licenses

The registry archive SHA-256 is
`4fcb935c5bec503c2f0e306bdd3e58bb9029dcb14fa8d9ac76e3a5256ac0763e`,
exactly the checksum stored in the lock. Its normalized primary metadata says:

- crate: `quinn-proto 0.11.15`;
- repository: `https://github.com/quinn-rs/quinn`;
- license: `MIT OR Apache-2.0`;
- MSRV: Rust 1.85.

The packaged notices are preserved:

- `LICENSE-APACHE` SHA-256
  `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4`;
- `LICENSE-MIT` SHA-256
  `4b2d0aca6789fa39e03d6738e869ea0988cceba210ca34ebb59c15c463e93a04`.

The derivative's license files and `REUSE.toml` remain byte-identical to the
baseline. Source-only REUSE 5.1.1, GPL-3.0-or-later, image
`fsfe/reuse@sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da`
passed 190/190 files with only MIT and Apache-2.0. An initial direct scan also
included generated `target/` output and was intentionally discarded; rerunning
with that generated directory hidden produced the authoritative source result.

## Protocol and source invariants

The sole changed path is `Cargo.lock`. In particular:

- every `Cargo.toml` hash is unchanged;
- `moq-transport/src/setup/mod.rs` remains SHA-256
  `c49d71dcacd5e3f5eef7a673e11b9058d3fd701e1fb83331a737098894a2d750`;
- `moq-native-ietf/src/quic.rs` remains SHA-256
  `eaa9b00e0ad8eba9ae24f59b14165b252edc1d3857d8fb0cc21649f60070c094`;
- `moq_transport::setup::ALPN` remains the literal `b"moqt-16"`;
- draft-16 encoding, WebTransport/raw QUIC selection, Objects, fixtures,
  manifests, features, and runtime APIs have no diff.

No I1, I2, C1, or C2 source was copied or modified in this worktree.

## Rust toolchain and validation

Rust ran in the official image fixed at
`rust@sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57`:

```text
rustc 1.93.0 (254b59607 2026-01-19)
cargo 1.93.0 (083ac5135 2025-12-15)
```

Clippy and rustfmt were installed only inside that ephemeral container for the
same `1.93.0` toolchain.

| Command/gate | Result |
|---|---|
| `cargo metadata --locked --format-version 1 --no-deps` | PASS |
| normal/build and all-feature `cargo tree` inventories | PASS; same graph, `quinn-proto 0.11.15` |
| `cargo test --locked -p moq-native-ietf --verbose` | PASS; 1 unit, 0 doctests |
| locked check of `moq-native-ietf`, `moq-transport`, `moq-relay-ietf` | PASS |
| `cargo clippy --locked --no-deps -p moq-native-ietf --tests -- -D warnings` | PASS |
| `cargo test --locked -p moq-relay-ietf` | PASS; 119 lib, 16 bin, 1 doctest; 1 doctest ignored |
| `cargo test --locked -p moq-transport` | BASELINE FAIL; E0308 at unchanged `src/serve/tracks.rs:501` |
| workspace check/test/clippy, all targets/features | BASELINE FAIL; same E0308 at unchanged line 501 |
| `cargo fmt --all -- --check` | BASELINE FAIL; only the two known unchanged diffs in `serve/subgroup.rs` and `serve/tracks.rs` |
| `git diff --check` and cached diff check | PASS |
| `cargo package --locked -p moq-relay-ietf --list --allow-dirty` | PASS; package inventory generated |
| source-only REUSE 5.1.1 | PASS; 190/190 |

The exact published `quinn-proto 0.11.15` crate was also tested using the
`Cargo.lock` packaged with that crate and a separate ephemeral target:

- full unit suite: 265 passed, zero failed;
- doctests: 3 passed, zero failed;
- assembler filter: 21 passed, zero failed;
- `transport_parameters::test::read_semantic_validation`: 1 passed;
- package self-check and Clippy with every optional feature: not executable in
  the fixed image because the optional AWS-LC FIPS build requires `cmake`, which
  is absent. The deployed moq-rs feature graph does not enable that FIPS feature;
  the locked downstream normal graph compiled and tested as recorded above.

The crate's upstream suite validates its transport-parameter semantic checks
and assembler behavior. This batch does not claim an additional independent
hostile-network interoperability or slow-client isolation result beyond those
tests. Such evidence remains part of the later integration/chaos gate.

## Remaining gates and rollback

This snapshot is suitable for independent `TP-OSS-SC` review, not for release:

- the 17 unrelated vulnerability entries and six RustSec warnings remain;
- the full workspace test/check/Clippy gate retains the documented baseline
  E0308 failure;
- rustfmt retains the two documented baseline diffs;
- the derivative has no reviewed cargo-deny license policy;
- a current RustSec database scan, generated SBOM comparison, independent
  WebTransport/MoQT interoperability, and fault/slow-client isolation still
  require their authorized gates.

Rollback is a one-file reversal to the baseline lock SHA, which would
deliberately restore vulnerable `quinn-proto 0.11.13`; it is not an acceptable
steady state. No source change must be retained or removed with that rollback
because this batch contains no source change.

## State boundary

**LOCAL ONLY / NOT COMMITTED / NOT PUSHED / NOT PUBLICATION READY**

There was no Git fetch, commit, stage, push, tag, release, PR, issue, remote ref,
or remote-setting mutation. Registry access was read-only and limited to Cargo
resolution and test inputs. The next authorized action is an independent
`TP-OSS-SC` review of this exact lock-only snapshot; no later remediation batch
may absorb or rewrite its lock delta before that review.
