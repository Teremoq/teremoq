<!--
SPDX-FileCopyrightText: 2026 Teremoq contributors
SPDX-License-Identifier: Apache-2.0
-->

# Independent TP-OSS-SC review of RustSec Batch U1

Review date: 2026-08-28

Reviewer: `TP-OSS-SC`
Scope: local, uncommitted `bytes` lockfile remediation only

This is a technical open-source and software-supply-chain review. It is not
legal advice, a release gate, push authorization, or publication authorization.

## Findings

### High — the derivative remains unsuitable for publication

Batch U1 removes one vulnerable lockfile entry, but the frozen RustSec result
still contains 16 vulnerable entries across 12 advisory IDs and six
informational warning entries. The derivative also lacks the reviewed
`deny.toml`, generated SBOM comparison, sequential release inventory, and full
publication gates required by the remediation plan and ADR-0007.

This is inherited risk, not a regression introduced by U1. It prevents a
publication verdict but does not prevent retaining this narrowly scoped local
remediation.

### Medium — full offline metadata is not reproducible from the retained cache

`cargo metadata --locked --offline --format-version 1` exits 101 because the
unrelated target package `android-tzdata 0.1.1` is absent from the local Cargo
cache. The locked, no-dependency form passes, and both requested inverse trees
pass offline. No network access or broad cache population was used to conceal
this limitation.

### Medium — broad compilation remains subject to documented baseline failures

The owner evidence records passing normal/all-feature compilation and focused
tests, while all-target test and Clippy gates retain the unchanged E0308 at
`moq-transport/src/serve/tracks.rs:501`. Rustfmt and one separate `moq-pub`
Clippy finding are likewise inherited. These failures are outside the
lock-only U1 delta.

Large builds were not repeated during this independent review because the
owner's fixed-toolchain evidence is complete for the affected path and the host
was already under memory pressure. The two pre-existing U1 review containers
subsequently exited with status 137 during lightweight inventory queries; this
review did not restart them or create a replacement build environment.

### No U1-specific blocking finding

The exact U1 delta is a non-yanked, checksum-verified, MIT-licensed update to
the minimum version RustSec marks as patched. It adds no package, dependency
edge, feature, build script, manifest change, source change, provider change,
or protocol change.

## Verdicts

**APPROVE FOR LOCAL COMMIT**

Conditions:

1. The local commit must contain only the reviewed `Cargo.lock` delta and carry
   a DCO 1.1 `Signed-off-by` trailer. U1 is currently uncommitted, so that
   condition cannot yet be demonstrated.
2. The lockfile must retain SHA-256
   `0b8ebcce6495ea65cc0acb0a94852e0067f78b06aa956dc8a368195bce626e19`.
3. U1 must not be combined silently with another RustSec batch, I1, I2, C1,
   C2, a manifest edit, or a feature change.
4. The residual advisories and publication gates below remain explicit; this
   approval cannot be reused as release or push authorization.

**PUBLICATION: NOT READY**

No push, tag, release, pull request, issue, or other remote action is authorized
by this review.

## Bound snapshot and repository isolation

The worktree was inspected without checkout, staging, configuration, ref, or
file mutation:

| Property | Independently observed value |
|---|---|
| Worktree | `/home/jimbomilk/moq-rs-teremoq-rustsec-u1-work` |
| Branch | `teremoq/rustsec-u1-1e9d1ee` |
| Tracking branch | none |
| `HEAD` | `1e9d1ee62bde97145a0914e5992ab7f54fc909c4` |
| `HEAD^{tree}` | `4cf25aeea2eacd02394608c80c9677eaa001ef87` |
| `HEAD^` | `bf87128affd316463e5dcc7599a45001f222b6de` |
| `HEAD^^{tree}` | `d76319009e815fb8923e21fc8319e17a0aaf8174` |
| Stage | empty |
| Worktree status | only ` M Cargo.lock` |
| Changed path set | exactly `Cargo.lock` |

`HEAD` is the already committed Batch Q snapshot. U1 is the sole unstaged
lockfile change layered on that commit. `git diff --check HEAD` passes.

The Batch Q commit contains one DCO trailer. That fact does not pre-sign the
future U1 commit; its own sign-off remains mandatory.

## Exact lockfile resolution

| Property | Q / `HEAD` | U1 worktree |
|---|---:|---:|
| `Cargo.lock` SHA-256 | `a249c6296affe18cdd726324539e52e6783718fbd2c1e63ec7ab4bdd95b27e9b` | `0b8ebcce6495ea65cc0acb0a94852e0067f78b06aa956dc8a368195bce626e19` |
| Package records | 336 | 336 |
| `bytes` version | `1.6.0` | `1.11.1` |
| `bytes` checksum | `514de17de45fdb8dc022b1a7975556c53c86f9f0aa5f534b98977b171857c2c9` | `1e748733b7cbc798e1434b6ac524f0c1ff2ab456fe201501e6497c8417a4fc33` |

The textual diff is exactly two insertions and two deletions in
`Cargo.lock:291-296`: the version and checksum above. A TOML record comparison
finds exactly one removed record and one added record. After removing the
`bytes` record, the two ordered package-record arrays are byte-for-byte equal
under deterministic JSON serialization, both with SHA-256
`6b50316edf8227775e6968d0f1ca217394a05d81be0320fa411c91f67b9d6a91`.

There are no other package-coordinate, source, checksum, or dependency-edge
changes. `git diff HEAD -- '**/Cargo.toml' Cargo.toml` is empty, as is the
complete non-lockfile diff.

## Dependency graph and feature review

The three direct workspace constraints remain byte-identical and compatible:

- `moq-transport/Cargo.toml`: `bytes = "1"`;
- `moq-pub/Cargo.toml`: `bytes = "1"`; and
- `moq-test-client/Cargo.toml`: `bytes = "1"`.

Lockfile parsing identifies the same 26 direct lock-record consumers before
and after U1. The set includes the three workspace packages plus the existing
Tokio, QUINN, HTTP/H2/Hyper, WebTransport, Redis, MP4, Axum, and utility paths.
No consumer is added or removed.

Both crate archives declare precisely:

```text
default = ["std"]
std = []
```

The U1 package declares `build = false`; it introduces no build script.
Independent offline inverse trees pass for normal/build edges and features.
The feature tree selects only the existing `bytes/default` and `bytes/std`
features. It also continues to show the already established QUINN provider
features; U1 makes no provider selection.

Commands and outcomes:

| Command | Result |
|---|---|
| `cargo metadata --locked --offline --format-version 1 --no-deps` | pass, Cargo 1.93.0 |
| `cargo metadata --locked --offline --format-version 1` | incomplete, exit 101: uncached `android-tzdata 0.1.1` |
| `cargo tree --locked --offline -i bytes@1.11.1 -e normal,build` | pass |
| `cargo tree --locked --offline -i bytes@1.11.1 -e features` | pass; `default` and `std` |

The queries used the pre-existing official image
`rust@sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57`
with `rustc 1.93.0` and `cargo 1.93.0`, a read-only bind of the reviewed
worktree, offline mode, and an external target volume.

## Provenance, checksum, license, and MSRV

The cached crates.io archive, current official sparse-index record, and U1
lockfile all contain the same SHA-256/checksum:

```text
1e748733b7cbc798e1434b6ac524f0c1ff2ab456fe201501e6497c8417a4fc33
```

The sparse-index record identifies `bytes 1.11.1` and is not yanked. By
contrast, the currently cached index marks the removed `bytes 1.6.0` record as
yanked. The packaged metadata identifies:

- crate: `bytes 1.11.1`;
- repository: `https://github.com/tokio-rs/bytes`;
- packaged VCS commit: `417dccdeff249e0c011327de7d92e0d6fbe7cc43`;
- license: `MIT`;
- MSRV: Rust 1.57;
- edition: Rust 2021; and
- build script: disabled.

Rust 1.57 is below the reviewed Rust 1.93 toolchain. The packaged MIT license
file has SHA-256
`45f522cacecb1023856e46df79ca625dfc550c94910078bd8aec6e02880b3d42`,
identical to the removed archive's license file. MIT is compatible with the
upstream derivative's `MIT OR Apache-2.0` licensing model. This dependency
update does not relicense `bytes` or Teremoq code.

The derivative's license objects remain unchanged:

| File | SHA-256 |
|---|---|
| `LICENSES/Apache-2.0.txt` | `1248f876e0140942002b476a19c95d5b5b44c625e69c96611d23119ee87fa04e` |
| `LICENSES/MIT.txt` | `c7d191b5901a741f2e39c74bd7a7594014a81fbe2bc7d533d4c29ad4cfe4e057` |
| `REUSE.toml` | `afc7fd86e591a56078b11982ee4d039ea1dfe3f9d56a90e3e7fa9f84fbddb6cc` |

A lockfile-only version replacement needs no new source SPDX header or NOTICE
entry. The generated SBOM must nevertheless replace the old package coordinate
and checksum before any release candidate.

## RustSec verification

The authoritative frozen database for the remediation series is the official
`RustSec/advisory-db` repository at commit
`6420e39260b3d771b049954cf5d52b57e2118da4`, tree
`01794d45488a521b322b760b6bfdcd6e9f28932b`. The owner ran
`cargo-audit 0.22.2 --no-fetch` against that database with no ignore or
suppression. The binary is `MIT OR Apache-2.0`, SHA-256
`66f9c8f530950d106c1869ce27ef5a4008bcea53c7716c3ed8117586337ee7d8`.

Independent closure was checked from three bound pieces of evidence:

1. the exact Q and U1 lock records and archive checksums above;
2. the retained frozen audit row for `RUSTSEC-2026-0007`, whose patched range is
   `>=1.11.1`, and whose vulnerable Q package is exactly `bytes 1.6.0`; and
3. the owner's no-fetch before/after result, which changes only from 17 to 16
   vulnerable entries while warnings remain six.

The prior frozen audit JSON used for the advisory-row cross-check has SHA-256
`4717f6dde7681f6c98bc15ba6d6d8f1e80fc7cd937214701663c1f0974725b65`.
The independent Batch Q review has SHA-256
`bc3f3d9f020b1da7116510843e1de330331140e0affde164ac6b69cf6ecc702c`.
The U1 owner report has SHA-256
`358a31f643e93f9efb9eca29624c9ee6a4931e56264d29ee519824cd1ff2c8fb`.

The frozen database checkout was no longer retained locally at this review's
final pass, and network/fetch was prohibited. Therefore this reviewer did not
claim a second fresh full `cargo audit` execution. The exact patched-range,
coordinate, checksum, and owner no-fetch comparison are sufficient to verify
closure of the single U1 advisory without overstating a complete refreshed
audit.

### Advisory removed by U1

- `RUSTSEC-2026-0007` / `bytes`: the affected unique reclaim path in
  `BytesMut::reserve` can overflow an addition in release mode. RustSec marks
  `1.11.1` as the minimum patched version. U1 selects exactly that version.

No advisory entry or warning is added by the replacement.

### Residual vulnerable entries, outside U1

The 16 entries cover these 12 advisory IDs:

- `RUSTSEC-2024-0421` (`idna`);
- `RUSTSEC-2025-0055` (`tracing-subscriber`);
- `RUSTSEC-2026-0045`, `RUSTSEC-2026-0046`, `RUSTSEC-2026-0047`, and
  `RUSTSEC-2026-0048` (`aws-lc-sys`);
- `RUSTSEC-2026-0049`, `RUSTSEC-2026-0098`, `RUSTSEC-2026-0099`, and
  `RUSTSEC-2026-0104` (two locked `rustls-webpki` lines where applicable);
- `RUSTSEC-2026-0204` (`crossbeam-epoch`); and
- `RUSTSEC-2026-0258` (`h2`).

The six warnings are unchanged:

- unmaintained: `RUSTSEC-2025-0056` (`adler`), `RUSTSEC-2024-0436`
  (`paste`), and `RUSTSEC-2025-0134` (`rustls-pemfile`); and
- unsound: `RUSTSEC-2026-0190` (`anyhow`) plus two locked `rand` versions
  reported under `RUSTSEC-2026-0097`.

These findings remain remediation work; none is allowed or ignored by this
review.

## Protocol and behavior boundary

Because every tracked source and manifest is byte-identical to `HEAD`, U1
cannot change MoQT framing, draft selection, ALPN, WebTransport behavior,
QUINN/rustls provider selection, public API, or runtime feature declarations.
As direct corroboration,
`moq-transport/src/setup/mod.rs` remains SHA-256
`c49d71dcacd5e3f5eef7a673e11b9058d3fd701e1fb83331a737098894a2d750`
and continues to declare `b"moqt-16"`.

The owner evidence reports the official `bytes_mut_reserve_overflow` regression
passing 1/1, the `bytes` buffer suites passing, normal/all-feature workspace
checks passing, and the focal API/publisher/client/native/relay tests passing.
This reviewer accepts those results as supporting evidence bound to owner
report SHA-256 above and does not misrepresent them as independently rerun
builds.

## Rollback and remaining gates

The mechanical rollback is restoration of Q lock SHA-256
`a249c6296affe18cdd726324539e52e6783718fbd2c1e63ec7ab4bdd95b27e9b`.
That rollback would restore vulnerable, now-yanked `bytes 1.6.0`, so it is not a
safe steady state.

Before publication, the separately owned remediation batches must address the
residual findings, a reviewed `deny.toml` must provide enforceable license and
advisory policy, a generated SBOM must be compared, baseline build failures
must be resolved or formally bounded, and release branches must be assembled
and reviewed sequentially under the exact inventory/ruleset process. U1 does
not authorize those changes.

## Commands and final state checks

The independent review used read-only Git queries, Python 3.12.3 `tomllib` for
lock-record comparison, Cargo 1.93.0 offline metadata/tree queries, SHA-256,
and read-only extraction of the two cached crates.io archives and sparse-index
records. No tool was installed.

Final checks required after writing this report:

```text
git -C /home/jimbomilk/moq-rs-teremoq-rustsec-u1-work status --short
git -C /home/jimbomilk/moq-rs-teremoq-rustsec-u1-work diff --check HEAD
sha256sum /home/jimbomilk/moq-rs-teremoq-rustsec-u1-work/Cargo.lock
git -C /home/jimbomilk/teremoq diff --check
```

Only this review document was added to the Teremoq workspace. The reviewed
worktree, its index, refs, configuration, remotes, manifests, lockfile, and
source were not modified by `TP-OSS-SC`. No fetch, commit, push, tag, release,
pull request, issue, message, or remote mutation occurred.

**LOCAL SUPPLY-CHAIN REVIEW ONLY / NOT PUBLISHED / NO REMOTE MUTATION**
