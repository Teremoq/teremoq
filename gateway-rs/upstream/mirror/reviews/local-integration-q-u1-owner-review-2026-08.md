<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Local Q + U1 integration owner review

Date: 2026-08-28 10:17:40 UTC

Owner: `TP-RUST-DIST`

State: **READY FOR FORMAL REVIEW**

LOCAL MERGE REVIEW ONLY / NOT COMMITTED / NOT PUSHED / NO REMOTE MUTATION

## Findings first

### No Q/U1 integration finding

The frozen staged merge is the exact semantic union expected by the reviewed Q
and U1 batches. Relative to the first parent, only `quinn-proto 0.11.13` is
replaced by `0.11.15` and `bytes 1.6.0` by `1.11.1`. A TOML record comparison
found no other package record or dependency change. Both focal crates compile,
their complete tests pass, and their test targets pass Clippy with warnings
denied.

### Inherited blocker: `BLOCKED_BY_BASELINE_E0308`

`cargo test --locked --offline -p moq-transport --lib` exits 101 with the one
protected baseline error at `moq-transport/src/serve/tracks.rs:501`: expected
`TrackName`, found `&str`. The file remains byte-identical with SHA-256
`a8303c94925707a0a257923725bf84e4ec730b07d6bb2330fda5329b632fe0b7`.
This is not a Q/U1 regression, is not counted as a pass, and still blocks a
green full Objects/workspace gate until separately repaired.

### Offline metadata limitation

Target-filtered Linux metadata and metadata without dependency source loading
pass. Unfiltered all-target metadata cannot complete offline because the local
cache lacks the unrelated target archive `android-tzdata 0.1.1`; Cargo refused
the attempted HTTP access under `--offline`. No download or installation was
performed. This limitation does not affect the complete Linux native and relay
build/test/Clippy evidence below, but the formal supply-chain review should use
its independently complete all-target cache.

## Frozen merge identity

| Item | Frozen value |
| --- | --- |
| `.cursorrules` SHA-256 | `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2` |
| `HEAD` / first parent candidate | `1fc0d5b7d145863c96c25560190669a4c13d026b` |
| `MERGE_HEAD` / U1 | `4547800088881cb4782c544ebfec0a1904ed1fab` |
| U1 parent / Q | `1e9d1ee62bde97145a0914e5992ab7f54fc909c4` |
| Q occurrences in U1 ancestry | exactly one |
| Staged tree | `4696ae59a07ec1b3930a654e03e412221f9a8a5d` |
| Staged path | `Cargo.lock` only |
| Pathset SHA-256 | `3e503ffd2d2f0c135bc5d8c97cba5aff82676478d90cb002333ed9583b92c5a0` |
| Status-z SHA-256 | `ce44e624498f3a799669efe577d41fb1e715ff857867d6f87cc84c94cfaf54da` |
| Combined lock SHA-256 | `d6196fd8f31ea3b2cabbdb0e57546810643f344567f3e358ee3c000b3e2b59f5` |
| First-parent lock SHA-256 | `13b9f1c54ccbe644dcf4f07542f610950cd013b291c928b6b3ad39ac1751ce80` |
| U1 lock SHA-256 | `0b8ebcce6495ea65cc0acb0a94852e0067f78b06aa956dc8a368195bce626e19` |
| Unmerged / unstaged | zero / zero |
| Tracking branch | none |

The preflight and final snapshot produced the same values. `git diff --check`
and `git diff --cached --check` both pass. No source-side `target/` directory
was created.

## Semantic lock reproduction

Python 3 `tomllib` parsed `HEAD:Cargo.lock`, `MERGE_HEAD:Cargo.lock`, and the
staged working lock as package-record maps keyed by `(name, version, source)`.
Each contains exactly 336 unique package records. Comparing the first parent to
the combined lock produced:

| Removed | Added | Old checksum | New checksum |
| --- | --- | --- | --- |
| `quinn-proto 0.11.13` | `quinn-proto 0.11.15` | `f1906b49b0c3bc04b5fe5d86a77925ae6524a19b816ae38ce1e426255f1d8a31` | `4fcb935c5bec503c2f0e306bdd3e58bb9029dcb14fa8d9ac76e3a5256ac0763e` |
| `bytes 1.6.0` | `bytes 1.11.1` | `514de17de45fdb8dc022b1a7975556c53c86f9f0aa5f534b98977b171857c2c9` | `1e748733b7cbc798e1434b6ac524f0c1ff2ab456fe201501e6497c8417a4fc33` |

There are zero changed records among identities common to the first parent and
combined lock. The old and new `quinn-proto` dependency arrays are identical;
only version and checksum change. Cached `.crate` SHA-256 values match the two
new lock checksums exactly.

Compared with U1, the combined lock has the same 336 package coordinates. Its
only same-coordinate record difference is the intentional I2 dev edge from
`moq-relay-ietf 0.7.25` to the already locked `rustls 0.23.31`; the manifest
still pins `=0.23.31` with feature `ring`. There is exactly one
`rustls 0.23.31` record.

The replacement crates retain reviewed provenance:

- `bytes 1.11.1`: crates.io checksum above, `MIT`, MSRV 1.57, upstream
  repository `https://github.com/tokio-rs/bytes`, packaged `LICENSE` present;
- `quinn-proto 0.11.15`: crates.io checksum above, `MIT OR Apache-2.0`, MSRV
  1.85, upstream repository `https://github.com/quinn-rs/quinn`, packaged
  `LICENSE-MIT` and `LICENSE-APACHE` present.

## Excluded changes and Batch T proof

`git diff HEAD` contains only `Cargo.lock` (four insertions and four deletions).
All ten tracked manifests, every feature declaration, source file, test,
fixture, protocol constant, and license file are identical to the first parent.
Consequently there is no source, provider, API, draft, ALPN, wire, Objects, or
test change in this merge.

The provider/security packages remain at their first-parent versions:

- `aws-lc-rs 1.13.3`;
- `aws-lc-sys 0.30.0`;
- `rustls-webpki 0.102.4` and `0.103.4`;
- `rustls 0.22.4` and `0.23.31`;
- `quinn 0.11.9`.

Therefore Batch T (`rustls-webpki`/AWS-LC provider remediation) has not been
incorporated. Q is present exactly once as the direct parent of U1, and U1 is
present exactly once as `MERGE_HEAD`.

## Toolchain and validation

All Cargo commands used `--locked --offline`, local caches, an external target,
a read-only source mount, and Docker `--network none`.

| Gate | Result |
| --- | --- |
| Rust/Cargo image `teremoq-step7-lab:rust-1.93-full`, ID `sha256:ba076cf0a26aa41efdd2f0f80687ef97009d1526680751456c19cc944dff1d0b` | `rustc 1.93.0 (254b59607)`; `cargo 1.93.0 (083ac5135)` |
| Clippy image `teremoq-local-rust193-components:c2-review-20260828`, ID `sha256:f522c28d5beb21591f46e8c165030f70b32dd5b51107577ad196910e7147a007` | `clippy 0.1.93 (254b59607d)` |
| `cargo metadata --locked --offline --format-version 1 --no-deps` | PASS; JSON SHA-256 `9506420f2a7fd10f307a9936e2ce33a2fcbb6d66fe55add5cf933e15d81160d8` |
| Metadata with `--filter-platform x86_64-unknown-linux-gnu` | PASS; 233 packages and 233 resolve nodes; JSON SHA-256 `e9b3fedb56f92e20f2f67cfff3fbe8163666023811a1c407dfa72979f509175c` |
| Unfiltered all-target metadata | BLOCKED offline only by absent cached `android-tzdata 0.1.1`; no network access |
| `cargo tree --locked --offline -i quinn-proto@0.11.15` | PASS; one `quinn-proto`, through `quinn 0.11.9` into native/WebTransport users |
| `cargo tree --locked --offline -i bytes@1.11.1` | PASS; one `bytes` across QUIC, MoQT and HTTP users |
| `cargo tree --locked --offline -i rustls@0.23.31` | PASS; I2 dev edge retained and runtime graph unchanged |
| `cargo check --locked --offline -p moq-native-ietf` | PASS |
| `cargo check --locked --offline -p moq-relay-ietf` | PASS |
| `cargo test --locked --offline -p moq-native-ietf` | PASS: 32 unit + 6 integration; doctests 0 |
| `cargo test --locked --offline -p moq-relay-ietf` | PASS: 175 library + 16 binary + 10 integration + 1 doctest; one separate doctest ignored |
| `cargo clippy --locked --offline --no-deps -p moq-native-ietf -p moq-relay-ietf --tests -- -D warnings` | PASS |
| `cargo test --locked --offline -p moq-transport --lib` | `BLOCKED_BY_BASELINE_E0308`; exact protected line 501 only |
| TOML record comparison; crate archive checksums/licenses | PASS |
| Final parent/tree/pathset/status/lock hashes | PASS; unchanged from preflight |

The first Clippy attempt used the Rust 1.93 base image, which lacks the Clippy
component, and failed before compilation. No component was installed. The gate
was then executed successfully with the pre-existing fixed local Clippy image
listed above.

## Scope and handoff

No file in the frozen integration worktree was edited or staged. No commit,
fetch, push, tag, issue, pull request, release, installation, network access, or
remote mutation occurred. The sole local output of this owner review is this
report outside that worktree.

The exact next gate is independent formal review of staged tree
`4696ae59a07ec1b3930a654e03e412221f9a8a5d`. This Q/U1 lock merge is ready for
that review, but it is not publication approval and does not waive the inherited
Objects E0308 or authorize Batch T.
