<!--
SPDX-FileCopyrightText: 2026 Teremoq contributors
SPDX-License-Identifier: Apache-2.0
-->

# Independent TP-OSS-SC review of RustSec Batch Q

- Date: 2026-08-28
- Profile: `TP-OSS-SC`
- Scope: local, uncommitted Batch Q snapshot only
- Reviewed worktree: `/home/jimbomilk/moq-rs-teremoq-rustsec-q-work`
- Publication authority: none

## Findings

### High — inherited publication blockers remain

The frozen RustSec scan remains red after Batch Q: `17` vulnerable entries
covering `13` distinct advisory IDs and `6` informational warning entries
covering `5` distinct advisory IDs remain in `Cargo.lock`. These are the same
non-Q findings planned in the other remediation batches. Batch Q does not add
any advisory, package, version, manifest edge or source change, but it cannot
make the derivative publication-ready by itself.

Release remains additionally blocked by the absent reviewed `deny.toml`
policy, final normal/all-feature SBOM reconciliation, full clean release gates,
the known baseline build/format failures, current-database RustSec evidence and
sequential completion of the remaining remediation batches.

### Medium — clean offline reconstruction is a publication gate, not a Q delta

The authorized local registry cache contains the official sparse-index record
for `quinn-proto 0.11.15`, but not its `.crate` source archive. Consequently,
an independent `cargo tree --locked --offline` clean reconstruction stopped
before resolution output with `failed to download quinn-proto v0.11.15`; no
network fallback or fetch was attempted. A clean rebuild and full Cargo tree
must therefore be repeated from a separately authorized, checksum-verified
source cache before publication.

This does not make the lock-only local commit unsafe to retain: the exact
coordinate and dependency-record comparison, official index constraint and
checksum checks, current build fingerprints, compiled-artifact version check,
independently executed focal test binaries and frozen RustSec comparison all
agree on the same Q result. It does limit this review: it does not claim a new
clean-build or interoperability result.

### Informational — no Batch Q supply-chain defect found

At `Cargo.lock:1684-1688`, the only change is `quinn-proto 0.11.13` to
`0.11.15` and its registry checksum. The dependency list below that record is
byte-identical. No manifest, feature request, provider package, source, wire,
fixture, license or notice file changed. The update removes exactly
`RUSTSEC-2026-0037` and `RUSTSEC-2026-0185` from the frozen audit and introduces
no new finding.

## Local-commit verdict

**APPROVE FOR LOCAL COMMIT**

This verdict is limited to retaining and committing this exact one-file local
delta. It does not authorize staging by this reviewer, a push, a tag, a release,
publication, a product pin change or a later remediation batch.

## Publication status

**PUBLICATION: NOT READY**

The remaining advisories and warnings, policy/SBOM/release gates, clean rebuild,
current RustSec database scan and independent QUINN/WebTransport/MoQT fault and
interoperability evidence remain required. Public visibility of the baseline
repository is not authorization to publish this branch or commit.

## Binding inputs and identity

The required documents were read in full. Their SHA-256 values were:

| Input | SHA-256 |
|---|---|
| `.cursorrules` | `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2` |
| `ADR-0007-CONTROLLED-MOQ-MIRROR.md` | `0085bdaa37cd3645a4a2c5a3163b0b096453b84f66635514fce6015d6bed25d8` |
| RustSec remediation plan | `a36cf64bb336cd99fe8f0e2984e64a8eb20ec3a49da91fce6f3c146d4d7a4bf2` |
| Batch Q local review | `24ae0d3d537df1b4aa70a13c0afcdee22af9162d64dba877c7b96a362e9c1033` |

The last value matches the expected binding hash. That report was treated as
an input, not as proof: all identity, delta, lock, RustSec and focal-test checks
below were repeated independently.

Read-only Git inspection established:

- branch: `teremoq/rustsec-q-bf87128`;
- `HEAD`: `bf87128affd316463e5dcc7599a45001f222b6de`;
- `HEAD^{tree}`: `d76319009e815fb8923e21fc8319e17a0aaf8174`;
- base tree: `d76319009e815fb8923e21fc8319e17a0aaf8174`;
- staged delta: empty;
- untracked paths: none;
- worktree delta: only `M Cargo.lock`;
- diff size: two additions and two deletions;
- base lock SHA-256:
  `b518a2fa4a6d7a0ffe0bdfe4b530f05196ac0f5e6f7ef51da9e5a83c0b0561c0`;
- Q lock SHA-256:
  `a249c6296affe18cdd726324539e52e6783718fbd2c1e63ec7ab4bdd95b27e9b`.

`git diff --quiet <base> -- . ':(exclude)Cargo.lock'` exited `0`; the
manifest-only comparison also exited `0`. Thus every manifest, Rust source,
feature declaration, license, fixture and protocol file is byte-identical to
the base.

## Exact lock and graph review

Python 3.14.4 parsed both TOML lockfiles without modifying them. Both contain
exactly `336` unique package records. Full-record set comparison, including
name, version, source, checksum and dependency list, produced one removal and
one addition:

| Direction | Package | Registry checksum | Dependencies |
|---|---|---|---:|
| removed | `quinn-proto 0.11.13` | `f1906b49b0c3bc04b5fe5d86a77925ae6524a19b816ae38ce1e426255f1d8a31` | 17 |
| added | `quinn-proto 0.11.15` | `4fcb935c5bec503c2f0e306bdd3e58bb9029dcb14fa8d9ac76e3a5256ac0763e` | 17 |

There is no other package-coordinate or record delta. The locked path remains:

```text
moq-relay-ietf 0.7.25
└── moq-native-ietf 0.10.0
    ├── quinn 0.11.9
    │   └── quinn-proto 0.11.15
    └── web-transport-quinn 0.11.8
        └── quinn 0.11.9
```

The locally cached official index entry for `quinn 0.11.9` requires
`quinn-proto ^0.11.12`, so `0.11.15` is within the declared compatible range.
The current lock still selects `quinn 0.11.9`, `quinn-udp 0.5.14`,
`web-transport-quinn 0.11.8` and the same Rustls/provider packages.

The official index records for `quinn-proto 0.11.13` and `0.11.15` have the
same normal dependency requirements and feature definitions except for a new,
unselected `__rustls-post-quantum-test` feature in `0.11.15`. Current and
baseline build fingerprints expose the same two selected feature sets:

```text
aws-lc-rs,bloom,platform-verifier,rustls-aws-lc-rs
aws-lc-rs,bloom,log,platform-verifier,qlog,ring,
rustls-aws-lc-rs,rustls-ring
```

The dependency-name sets in those fingerprints are identical. No new crypto
provider is selected. Current `libquinn_proto` artifacts embed version
`0.11.15`; the independently run native and relay test artifacts were created
after the Q lock and link against that current target set.

## Official provenance, checksum, license and MSRV

The official locally cached crates.io sparse-index record says:

- crate/version: `quinn-proto 0.11.15`;
- checksum:
  `4fcb935c5bec503c2f0e306bdd3e58bb9029dcb14fa8d9ac76e3a5256ac0763e`;
- yanked: `false`;
- `rust_version`: `1.85`.

The checksum is identical in the index and reviewed lock. Official docs.rs
package metadata independently records repository
`https://github.com/quinn-rs/quinn`, license expression
`MIT OR Apache-2.0`, `build = false`, Rust `1.85`, packaged
`LICENSE-APACHE` and `LICENSE-MIT`, and package VCS commit
`a7499b8439e393a6299330111d9c8564cd96c464`. The official Quinn release for
`quinn-proto-0.11.15` identifies the same signed release commit and describes
the bounded reassembly fix.

The dual license is compatible with the derivative's
`MIT OR Apache-2.0` policy. The dependency coordinate adds no derivative
copyright claim and requires no relicensing. No new `NOTICE` obligation was
observed; the packaged license files remain the upstream notices to preserve.
Rust 1.85 is below the approved Rust 1.93.0 toolchain, whose fixed image was:

```text
rust@sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57
rustc 1.93.0 (254b59607 2026-01-19)
cargo 1.93.0 (083ac5135 2025-12-15)
```

Because no source, manifest, license or distributable inventory file changed,
Batch Q creates no new SPDX header or REUSE annotation. It does change the
dependency version represented in future SBOMs; those SBOMs must replace
`quinn-proto 0.11.13` with `0.11.15` and retain the same graph relationship.

## RustSec comparison

The read-only advisory database was:

- origin: `https://github.com/RustSec/advisory-db.git`;
- commit: `6420e39260b3d771b049954cf5d52b57e2118da4`;
- tree: `01794d45488a521b322b760b6bfdcd6e9f28932b`;
- root license: CC0-1.0;
- worktree status: clean.

The scanner was `cargo-audit 0.22.2`, `MIT OR Apache-2.0`, executable SHA-256
`66f9c8f530950d106c1869ce27ef5a4008bcea53c7716c3ed8117586337ee7d8`.
Both commands used `--no-fetch`, the exact database and no allow, ignore or
suppression:

```text
cargo audit --json --no-fetch --db <frozen-db> --file <base-lock>
cargo audit --json --no-fetch --db <frozen-db> --file <Q-lock>
```

| Snapshot | Exit | Vulnerable entries | Warning entries |
|---|---:|---:|---:|
| base | 1 | 19 | 6 |
| Batch Q | 1 | 17 | 6 |

Set comparison removed exactly:

- `RUSTSEC-2026-0037` on `quinn-proto 0.11.13`;
- `RUSTSEC-2026-0185` on `quinn-proto 0.11.13`.

It added zero vulnerable entries, changed zero warning entries and reports no
Q advisory against `quinn-proto 0.11.15`. The nonzero Q exit is retained as a
release blocker rather than hidden or reclassified.

## Protocol and focal-test evidence

Only `Cargo.lock` differs, so QUINN call sites, WebTransport selection, MoQT
encoding and draft selection remain byte-identical. In particular:

- `moq-transport/src/setup/mod.rs` SHA-256 is
  `c49d71dcacd5e3f5eef7a673e11b9058d3fd701e1fb83331a737098894a2d750`
  in both snapshots;
- `moq-native-ietf/src/quic.rs` SHA-256 is
  `eaa9b00e0ad8eba9ae24f59b14165b252edc1d3857d8fb0cc21649f60070c094`
  in both snapshots;
- `moq_transport::setup::ALPN` remains `b"moqt-16"` at
  `moq-transport/src/setup/mod.rs:23`;
- WebTransport/raw-QUIC branch selection remains unchanged at
  `moq-native-ietf/src/quic.rs:519-550`;
- there is no diff in Objects, Tracks, Groups, setup messages, ALPN, draft,
  QUIC configuration, relay API or runtime feature declarations.

Independent execution of the current, post-lock compiled test binaries passed:

| Artifact | SHA-256 | Result |
|---|---|---|
| `moq_native_ietf-55add04dd0555b99` | `b62a35aa930072e8bdd4b659a2ef79aecf86361d119a569857a5b23a7214de51` | 1 passed, 0 failed |
| `moq_relay_ietf-d0dd651f0d14500c` | `e66536ca6830d56cb7c21e23b097c6ae8c995bba493781ff5ea73f866c331d29` | 119 passed, 0 failed |
| `moq_relay_ietf-0252970d2378f4cb` | `84da245ecb339fbf8bae9b0d7e8e3365ebfa0f759a6423b9ac30301ba4a6a6cb` | 16 passed, 0 failed |

These tests are regression evidence for the unchanged native and relay code;
they are not a substitute for the pending hostile transport-parameter,
out-of-order reassembly, slow-client, WebTransport/MoQT interoperability and
soak gates.

## SPDX/REUSE and validation

REUSE 5.1.1 ran from the previously approved official image fixed at
`fsfe/reuse@sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da`
with network disabled, the worktree mounted read-only and generated `target/`
hidden from the source scan. Result: `190/190` files had copyright and license
information; zero bad, deprecated, missing or unused licenses; only MIT and
Apache-2.0 were used.

Other reproducible checks:

| Check | Result |
|---|---|
| `cargo metadata --locked --offline --no-deps --format-version 1` | PASS; 9 workspace packages, all `MIT OR Apache-2.0` |
| complete TOML lock record-set comparison | PASS; one version replacement only |
| cached crates.io index checksum/constraint/yanked/MSRV check | PASS |
| base/current selected feature fingerprint comparison | PASS; identical sets |
| `git diff --check <base>` | PASS |
| cached/staged diff | PASS; empty |
| focal compiled tests | PASS; 136 total, zero failed |
| full clean `cargo tree --locked --offline` | INCOMPLETE; source archive absent and fetch prohibited |

Tools used read-only were Git 2.53.0, Python 3.14.4, Docker 28.3.3, the fixed
Rust 1.93.0 image, cargo-audit 0.22.2 and REUSE 5.1.1. The sparse index and
official package/release pages were consulted read-only; no Git or Cargo fetch
was executed.

## Boundaries, rollback and activity confirmation

Rollback is exactly restoration of the baseline `Cargo.lock`; it would also
restore both Q vulnerabilities and is not an acceptable long-term state. No
source or manifest rollback accompanies this batch.

The reviewed worktree was never checked out, branched, staged, configured,
cleaned or modified by this reviewer. Its final branch, HEAD, tree, empty stage,
single-path diff and lock hash remained identical to the binding state after
all checks. Only this report was created in the Teremoq repository.

No commit, fetch, push, tag, release, pull request, issue, publication, email,
message, remote ref change or remote service mutation was performed. No tool or
dependency was installed globally. This review does not authorize C1, C2, a
product pin, remote upload or publication.

**LOCAL SUPPLY-CHAIN REVIEW ONLY / NOT PUBLISHED / NO REMOTE MUTATION**
