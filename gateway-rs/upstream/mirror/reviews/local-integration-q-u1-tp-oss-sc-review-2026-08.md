<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# TP-OSS-SC review of the local Q + U1 integration

Date: 2026-08-28 10:07:57 UTC

Profile: `TP-OSS-SC: Open Source & Software Supply Chain Engineer`

Scope: independent, read-only review of the uncommitted staged Q + U1 merge in
the local `moq-rs-teremoq` integration worktree.

State: **LOCAL STAGED LOCK MERGE ONLY / NOT COMMITTED / NOT PUBLISHED**

## Findings first

### HIGH — sixteen vulnerable entries remain after Q + U1

The combined lock removes three vulnerable entries but remains red. The fixed
local RustSec scan reports 16 vulnerable entries across 12 advisory IDs and six
warning entries across five advisory IDs. The remaining vulnerabilities are:

- `RUSTSEC-2024-0421` (`idna`);
- `RUSTSEC-2025-0055` (`tracing-subscriber`);
- `RUSTSEC-2026-0045`, `RUSTSEC-2026-0046`, `RUSTSEC-2026-0047` and
  `RUSTSEC-2026-0048` (`aws-lc-sys`);
- `RUSTSEC-2026-0049`, `RUSTSEC-2026-0098`, `RUSTSEC-2026-0099` and
  `RUSTSEC-2026-0104` (the two retained `rustls-webpki` lines where
  applicable);
- `RUSTSEC-2026-0204` (`crossbeam-epoch`); and
- `RUSTSEC-2026-0258` (`h2`).

Warnings remain for `RUSTSEC-2024-0436`, `RUSTSEC-2025-0056`,
`RUSTSEC-2025-0134`, `RUSTSEC-2026-0097` and `RUSTSEC-2026-0190`.
No finding is ignored or allowed by this review. Q + U1 is not total
remediation and does not make the derivative publication-ready.

### MEDIUM — full offline Cargo metadata is not reconstructible from the retained cache

`cargo metadata --locked --offline --format-version 1` exits 101 because
`android-tzdata 0.1.1`, unrelated to Q and U1, is absent from the available
read-only cache. Network access and installation were forbidden, so the cache
was not populated. The locked `--no-deps` form passes, both affected inverse
trees pass, the complete TOML comparison is deterministic, and the exact
archives for the two replacements are locally present and checksum-valid.

This limitation does not change the one-file local-merge conclusion, but it
blocks a claim of clean full-graph reconstruction and remains a publication
gate.

### INFO — no Q/U1-specific supply-chain defect found

The staged `Cargo.lock` contains exactly two version/checksum replacements:

- `quinn-proto 0.11.13 -> 0.11.15`; and
- `bytes 1.6.0 -> 1.11.1`.

Both registry sources and dependency arrays are unchanged. There are still 336
unique records. No package record is added or removed beyond those two direct
replacements; no manifest, source, fixture, feature, license, protocol or
provider file changes.

The fixed audit removes exactly:

- `RUSTSEC-2026-0007` on `bytes 1.6.0`;
- `RUSTSEC-2026-0037` on `quinn-proto 0.11.13`; and
- `RUSTSEC-2026-0185` on `quinn-proto 0.11.13`.

It adds zero vulnerable entries and changes zero warnings.

### INFO — T is explicitly absent

The combined lock retains, byte-for-byte relative to the first parent:

- `rustls 0.23.31` (and the pre-existing `0.22.4` line);
- `aws-lc-rs 1.13.3`;
- `aws-lc-sys 0.30.0`; and
- `rustls-webpki 0.102.4` and `0.103.4`.

The four `aws-lc-sys` advisories and the retained `rustls-webpki` advisories
therefore remain visible. The cryptographic batch T is not included or
implicitly approved.

### INFO — inherited compiler blocker does not decide this merge

`moq-transport/src/serve/tracks.rs` remains byte-identical to the first parent,
SHA-256 `a8303c94925707a0a257923725bf84e4ec730b07d6bb2330fda5329b632fe0b7`.
The known E0308 at line 501 remains classified solely as
`BLOCKED_BY_BASELINE_E0308`. This review neither treats it as a Q + U1 failure
nor uses it as evidence in favor of the merge.

## Verdict

**APPROVE**

This verdict is limited to creating the exact local merge commit from the
frozen tree below. It does not authorize a push, tag, release, publication,
product pin, later RustSec batch or remote action. The future merge commit must
retain exactly the reviewed tree, use the first parent followed by U1 as its
two parents, and carry a DCO 1.1 `Signed-off-by` matching its author.

## Frozen identity

The required state was reproduced before all substantive checks and again
after the report was created:

| Item | Frozen value |
| --- | --- |
| `.cursorrules` SHA-256 | `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2` |
| `.cursorrules` length | 488 lines; read completely |
| `HEAD` / proposed first parent | `1fc0d5b7d145863c96c25560190669a4c13d026b` |
| `MERGE_HEAD` / proposed second parent | `4547800088881cb4782c544ebfec0a1904ed1fab` |
| Q contained by U1 | `1e9d1ee62bde97145a0914e5992ab7f54fc909c4` |
| Q parent | `bf87128affd316463e5dcc7599a45001f222b6de` |
| U1 parent | exact Q commit above |
| Staged tree | `4696ae59a07ec1b3930a654e03e412221f9a8a5d` |
| Changed paths | exactly one: `Cargo.lock` |
| Pathset SHA-256 | `3e503ffd2d2f0c135bc5d8c97cba5aff82676478d90cb002333ed9583b92c5a0` |
| Status-z SHA-256 | `ce44e624498f3a799669efe577d41fb1e715ff857867d6f87cc84c94cfaf54da` |
| Combined lock SHA-256 | `d6196fd8f31ea3b2cabbdb0e57546810643f344567f3e358ee3c000b3e2b59f5` |
| Unmerged / unstaged | 0 / 0 |
| Tracking branch | none |

The staged tree comparison used read-only `git diff-index --cached --quiet`
rather than `git write-tree`. `Cargo.lock` remains regular mode `100644`, has
zero conflict markers, and both working-tree and cached `git diff --check`
pass.

The already-created first-parent integration commit, Q and U1 each contain one
`Signed-off-by` matching their respective author. Those trailers do not
pre-sign the future Q + U1 merge commit.

## Reviewed input reports

All four reports were read completely and treated as inputs rather than proof:

| Report | SHA-256 |
| --- | --- |
| Q owner review | `24ae0d3d537df1b4aa70a13c0afcdee22af9162d64dba877c7b96a362e9c1033` |
| Q TP-OSS-SC review | `bc3f3d9f020b1da7116510843e1de330331140e0affde164ac6b69cf6ecc702c` |
| U1 owner review | `358a31f643e93f9efb9eca29624c9ee6a4931e56264d29ee519824cd1ff2c8fb` |
| U1 TP-OSS-SC review | `48c053d703d4f07b4ce1bf52f5e4bcd2745812d613433d43bd1bc5d80b681ede` |

Identity, record comparison, archive checksums, metadata/tree queries and
RustSec results were independently repeated over the combined lock.

## Complete TOML record comparison

Python 3.14.4 `tomllib` parsed the exact first-parent and staged Git blobs
without writing either file.

| Property | First parent | Combined staged lock |
| --- | ---: | ---: |
| Lock SHA-256 | `13b9f1c54ccbe644dcf4f07542f610950cd013b291c928b6b3ad39ac1751ce80` | `d6196fd8f31ea3b2cabbdb0e57546810643f344567f3e358ee3c000b3e2b59f5` |
| Package records | 336 | 336 |
| Unique complete records | 336 | 336 |

Complete-record set comparison, including name, version, source, checksum and
dependency array, produced exactly two removals and two additions:

| Direction | Package | Registry checksum | Dependencies |
| --- | --- | --- | ---: |
| removed | `bytes 1.6.0` | `514de17de45fdb8dc022b1a7975556c53c86f9f0aa5f534b98977b171857c2c9` | 0 |
| added | `bytes 1.11.1` | `1e748733b7cbc798e1434b6ac524f0c1ff2ab456fe201501e6497c8417a4fc33` | 0 |
| removed | `quinn-proto 0.11.13` | `f1906b49b0c3bc04b5fe5d86a77925ae6524a19b816ae38ce1e426255f1d8a31` | 17 |
| added | `quinn-proto 0.11.15` | `4fcb935c5bec503c2f0e306bdd3e58bb9029dcb14fa8d9ac76e3a5256ac0763e` | 17 |

For each package, the only changed record keys are `version` and `checksum`;
the source remains
`registry+https://github.com/rust-lang/crates.io-index`, and dependency arrays
are identical. The textual diff is four insertions and four deletions. The
binary staged-patch SHA-256 is
`82e9752111798a4a77f90d85e06d901479149c391a81d1f753c826dc8533a9ea`.

`rustls 0.23.31` appears exactly once both before and after. The I2 test-only
edge is preserved; Q + U1 neither removes nor changes it.

## Provenance, archives, licenses and MSRV

The exact crates.io archives and extracted sources were present in the
approved local Cargo cache, mounted read-only. Their archive SHA-256 values
equal both the official registry checksums stored in `Cargo.lock`:

| Package | Archive/lock SHA-256 | Repository | License | MSRV |
| --- | --- | --- | --- | --- |
| `bytes 1.11.1` | `1e748733b7cbc798e1434b6ac524f0c1ff2ab456fe201501e6497c8417a4fc33` | `https://github.com/tokio-rs/bytes` | MIT | Rust 1.57 |
| `quinn-proto 0.11.15` | `4fcb935c5bec503c2f0e306bdd3e58bb9029dcb14fa8d9ac76e3a5256ac0763e` | `https://github.com/quinn-rs/quinn` | `MIT OR Apache-2.0` | Rust 1.85 |

Packaged license evidence is preserved:

- `bytes/LICENSE` SHA-256
  `45f522cacecb1023856e46df79ca625dfc550c94910078bd8aec6e02880b3d42`;
- `quinn-proto/LICENSE-APACHE` SHA-256
  `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4`;
  and
- `quinn-proto/LICENSE-MIT` SHA-256
  `4b2d0aca6789fa39e03d6738e869ea0988cceba210ca34ebb59c15c463e93a04`.

Both MSRVs are below the fixed Rust 1.93.0 review toolchain. MIT and
`MIT OR Apache-2.0` are compatible with the derivative boundary; neither crate
is relicensed. A future SBOM must replace both old coordinates and checksums.
No new source SPDX header or NOTICE entry is required for a lock-only version
replacement. This is a technical license review, not legal advice.

## Offline Cargo graph evidence

Rust/Cargo 1.93.0 ran from local image
`teremoq-local-rust193-components@sha256:f522c28d5beb21591f46e8c165030f70b32dd5b51107577ad196910e7147a007`
with `--network none`, source read-only, ephemeral target tmpfs and Cargo
registry/Git cache volumes read-only.

| Command | Result |
| --- | --- |
| `cargo metadata --locked --offline --no-deps --format-version 1` | PASS; 9 workspace packages, all `MIT OR Apache-2.0`; output SHA-256 `210870c0a152f87efb6f6c7492948f9d521fbafafecb581050100ebfd50daeed` |
| full `cargo metadata --locked --offline --format-version 1` | INCOMPLETE; exit 101, uncached `android-tzdata 0.1.1` |
| inverse normal/build tree for `bytes 1.11.1` | PASS; 132 lines; SHA-256 `2773a80d6b549564417ee1adf01485a38e5179221a5d94b9459693cfa70d8a53` |
| inverse normal/build tree for `quinn-proto 0.11.15` | PASS; 21 lines; SHA-256 `5896ec7849047cc718f926d664095092e401fe54103a49ecd53ed121da40718b` |
| relay feature tree | PASS; SHA-256 `00198191287d478cb544beab261f726e2250ed4aba0f8b3ceb5b03de85359933` |

The graph selects only `bytes/default` and `bytes/std`; the QUINN path retains
`quinn 0.11.9`, `web-transport-quinn 0.11.8` and
`quinn-proto 0.11.15`. Existing AWS-LC and ring provider feature selections
remain visible but are not changed by this staged lock delta.

## RustSec audit

The scanner was the already-inventoried `cargo-audit 0.22.2`, licensed
`MIT OR Apache-2.0`, executable SHA-256
`66f9c8f530950d106c1869ce27ef5a4008bcea53c7716c3ed8117586337ee7d8`.
Both scans used `--no-fetch`, no allow, ignore or suppression, and the clean
official local database snapshot:

| DB property | Value |
| --- | --- |
| Origin | `https://github.com/RustSec/advisory-db` |
| Commit | `a7bfe16948bf6f3ee25bdee4822209f87da21b80` |
| Tree | `1152ddcadf432f7bf97746e51fb7f2d9e5968c49` |
| Commit timestamp | `2026-08-24T22:42:17-04:00` |
| Worktree status | clean |

The earlier Q/U1 reports used commit
`6420e39260b3d771b049954cf5d52b57e2118da4`. That object is not retained in
the current shallow local DB, so this review does not falsely claim to have
rerun that exact object. The fixed local snapshot above is also official and
produces the same before/after counts and advisory set expected by the bound
reports. No fetch was used.

| Lock | Audit exit | Vulnerable entries / IDs | Warnings / IDs | JSON SHA-256 |
| --- | ---: | ---: | ---: | --- |
| first parent | 1 | 19 / 15 | 6 / 5 | `9acb15382523f9a97bdbcd806e54f70d32f115b03bab3f9a2e44e33861968b1a` |
| combined Q + U1 | 1 | 16 / 12 | 6 / 5 | `9fd2fe4ed24c7885cb266fb654491af01034cdbea1f98e39e98fb14701d80ec3` |

The nonzero combined exit is preserved as evidence; it is not hidden or
reclassified.

## Protected repository boundary

`git diff HEAD <staged-tree>` contains only `Cargo.lock`. Independent path
filters find zero differences in manifests, Rust source, tests/fixtures,
`REUSE.toml`, licenses and protected protocol files. Representative unchanged
SHA-256 values are:

| Path | SHA-256 |
| --- | --- |
| `Cargo.toml` | `6665802c9ad7192d61521a62877454e25bde7072c611e617780a932f583aa48f` |
| `moq-native-ietf/Cargo.toml` | `3180121a89c58071718236a408f36c1c87757d6f9ff81e899fb3b5814c8d4c8e` |
| `moq-relay-ietf/Cargo.toml` | `83185ddb3f1523a6d7d9c577abbf29010eb34d6043538c1b28ff1057bb888b11` |
| `moq-transport/Cargo.toml` | `78f582c201082f7badece64f7fa65d215a6694412b7a7699332fa3bc9a4f3743` |
| `REUSE.toml` | `afc7fd86e591a56078b11982ee4d039ea1dfe3f9d56a90e3e7fa9f84fbddb6cc` |
| `LICENSES/MIT.txt` | `c7d191b5901a741f2e39c74bd7a7594014a81fbe2bc7d533d4c29ad4cfe4e057` |
| `LICENSES/Apache-2.0.txt` | `1248f876e0140942002b476a19c95d5b5b44c625e69c96611d23119ee87fa04e` |
| `moq-transport/src/setup/mod.rs` | `c49d71dcacd5e3f5eef7a673e11b9058d3fd701e1fb83331a737098894a2d750` |
| `moq-transport/src/setup/version.rs` | `384772b32812a0761fa55d16a9fd29e30595323ece1b3fca013ec3720eaec4ad` |
| `moq-transport/src/message/mod.rs` | `e5760f5ce2927b2437511b3e616fea2615d82e916d4b6036b7f5450ae0973352` |
| `moq-transport/src/session/mod.rs` | `5fa5a8a1c8d68faf86553146eb7b0d39a7ee9aea6a41b97e4abf261500115b00` |
| `moq-native-ietf/src/quic.rs` | `92e94e527dce998543b050e1d4af0012b6c18df2b4e32c068ad9ebb46594934d` |

Consequently Q + U1 changes no manifest constraint, requested feature,
cryptographic provider, MoQT wire encoding, ALPN/draft-16 selection, fixture,
source, copyright notice or derivative license.

REUSE 5.1.1 from the digest-pinned official image, with network disabled and
the source mounted read-only, passes 223/223 files; zero bad, deprecated,
missing or unused licenses; only MIT and Apache-2.0.

## Commands and limits

Representative read-only commands were:

```text
git diff-index --cached --quiet 4696ae59a07ec1b3930a654e03e412221f9a8a5d --
git diff --cached --name-only
git status --porcelain=v1 -z --untracked-files=no
git show HEAD:Cargo.lock
git show :Cargo.lock
python3 -c '<tomllib complete-record comparison>'
cargo metadata --locked --offline --format-version 1
cargo tree --locked --offline -i bytes@1.11.1 -e normal,build
cargo tree --locked --offline -i quinn-proto@0.11.15 -e normal,build
cargo audit --json --no-fetch --db <fixed-local-db> --file <lock>
docker run --rm --network none --read-only fsfe/reuse@sha256:11eb8a... lint
git diff --check
git diff --cached --check
```

No full build was repeated: the delta is lock-only, the affected package
archives and graphs were independently verified, and the protected E0308 is
already bound outside this merge. No SBOM was generated; the two coordinate
replacements must be reflected in the eventual release SBOM.

No tool or dependency was installed, no network operation was used and no
remote was queried or mutated.

## Activity and handoff boundary

The reviewed worktree, index, lockfile, manifests, source, refs, configuration
and remotes were not modified. No checkout, format, stage, restore, commit,
fetch, push, tag, issue, pull request, release, publication, message or remote
mutation was performed. The only persistent write is this report.

The report SHA-256 is delivered externally after its final frozen-state check;
it is not self-embedded because that would make the digest circular.
