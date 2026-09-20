<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# TP-OSS-SC preflight for the future `gateway-rs` derivative pin

Date: 2026-08-28

Scope: independent supply-chain and publication-boundary review

Disposition: read-only product and derivative review; isolated path simulation
only

State: **SUPPLY_CHAIN_READY_AFTER_PUBLICATION**

This is a technical open-source and supply-chain review, not legal advice. It
does not authorize a product change, a dependency update, publication, push,
tag, release, architecture change, T batch, or use of a floating branch.

## Findings first

### Medium — the reviewed commit is not yet a usable Git pin

The proposed derivative object exists locally as commit
`89cb1798644c32aef06cc625f097cd9acb203417`, tree
`cccd0d60c9ebfe191dca9d73e7ab8b27ae4d4ea5`. The local repository has no
remote-tracking branch or tag containing that commit and its current branch has
no upstream. The only locally recorded `origin` branch remains the approved
baseline at `bf87128affd316463e5dcc7599a45001f222b6de`.

Consequently, the exact future Git declarations shown later cannot resolve
from the public derivative today. A separately authorized publication and a
post-publication read-only comparison of commit, tree and ref inventory are
mandatory before changing the consumer. Local object existence and this path
simulation are not publication evidence.

### Medium — the future Git source requires an atomic policy update

The current `deny.toml` allows only the Cloudflare Git source. The path
simulation passes all cargo-deny checks, but the full candidate check reports
one `unmatched-source` warning because the Cloudflare source is absent from the
path graph. A real pin to `https://github.com/Teremoq/moq-rs-teremoq` would
instead fail the `unknown-git = "deny"` policy unless its exact repository URL
is reviewed and added atomically.

At the pin commit, replace the Cloudflare allow entry with the exact Teremoq
repository URL if no active dependency still resolves from Cloudflare. Retain
both only if the final lock demonstrates a genuine need for both. Do not add a
wildcard, branch, abbreviated revision or organization-wide allowance.

### Medium — final package evidence must be taken from the committed product tree

The current consumer `cargo package --list` contains two already-known Python
bytecode paths under `tests/preview/__pycache__/`. They remain physically in the
working tree while the main repository index records their deletion. The
isolated snapshot intentionally excluded caches and its 138-path package list
contains neither file, `target`, `.teremoq-dev`, another cache, nor an absolute
path.

The owner must rerun the package list from the eventual committed product tree
and prove both generated files are absent. This report neither edits nor
removes them. A package or release must not be produced from the present dirty
tree merely because the deletion is staged elsewhere.

### Low — dual cryptographic-provider activation is pre-existing and unchanged

Both current and candidate metadata resolve one `rustls 0.23.43` and one
`rustls-webpki 0.103.15`, with both `ring` and `aws-lc-rs` features active. The
resolved provider packages remain `ring 0.17.14`, `aws-lc-rs 1.18.0` and
`aws-lc-sys 0.44.0`. The complete feature map is identical before and after the
path substitution.

This preflight does not approve changing providers, enabling FIPS, or applying
batch T. The consumer already resolved these coordinates before the proposed
pin; the pin neither adds nor removes a provider. Any provider simplification
or T work remains a separate high-impact decision with its own PKI/QUIC review.

### Low — two maintenance warnings remain in the consumer

Using the fixed RustSec database, both consumer locks report zero vulnerability
entries and the same two unmaintained warnings:

- `RUSTSEC-2024-0436`, `paste 1.0.15`;
- `RUSTSEC-2025-0134`, `rustls-pemfile 2.2.0`.

The current `deny.toml` contains advisory-specific reasons for both and
`cargo deny check licenses advisories` passes. These are not silently closed by
the derivative pin. They must remain owned, reviewed and visible until their
actual graph edges are removed.

### Informational — the derivative lock and consumer lock are different gates

The derivative's own lock
`d6196fd8f31ea3b2cabbdb0e57546810643f344567f3e358ee3c000b3e2b59f5`
still produces 16 vulnerability entries across the previously recorded
RustSec findings and six warning entries. This is a derivative/release gate;
it is not concealed or reclassified here.

Cargo does not inherit a Git dependency repository's workspace lock. The
consumer resolves the derivative manifests inside the consumer graph. Its
current and candidate locks both select, among other coordinates:

- `bytes 1.12.1`;
- `quinn-proto 0.11.17`;
- `rustls 0.23.43`;
- `rustls-webpki 0.103.15`;
- `aws-lc-rs 1.18.0` and `aws-lc-sys 0.44.0`.

Therefore the derivative's Q coordinates (`quinn-proto 0.11.15`) and U1
coordinate (`bytes 1.11.1`) do not move the consumer lock: the consumer already
selects later compatible versions. Likewise, the consumer's later TLS/AWS-LC
coordinates are pre-existing consumer resolution, not an implicit approval or
integration of batch T.

### Informational — secret-scan findings are bounded and redacted

Gitleaks ran with 100% redaction and no suppression.

- The isolated consumer snapshot produced four `generic-api-key` findings in
  existing review documents. Each detected token is structurally a 64-hex
  SHA-256 digest, not a credential. No value is reproduced here.
- The derivative produced two `private-key` findings: the documented public,
  synthetic C2 test fixture, and a source comment containing PEM delimiter
  examples used by the key parser. No product trust material was identified.

The synthetic private key remains intentionally public test material and must
never be accepted as deployment identity. The residual risk is confusion or
accidental reuse, so its provenance warning, sidecar and test-only boundary
must remain intact. A clean Gitleaks exit is not claimed: both scans exited 1
because no suppression was used.

### Informational — REUSE passes only in the authoritative roots

REUSE 5.1.1 passes the complete Teremoq root at 250/250 files and the derivative
at 223/223 files. The detached gateway laboratory fails at 45/137 licensed and
40/137 copyright-annotated files because it deliberately lacks the parent
repository's `LICENSES/` and `REUSE.toml` annotations and contains copied
governance evidence normally covered by that parent configuration.

The detached failure is a limitation of the artificial subtree, not evidence
to replace either authoritative pass. The consumer must continue to be
released from the governed Teremoq root, with root LICENSE/NOTICE/third-party
materials bundled according to the release policy.

## Frozen inputs and isolation

The following requested bindings were verified before the simulation and again
before writing this report:

| Object | SHA-256 or Git object |
| --- | --- |
| `.cursorrules` | `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2` |
| product `Cargo.toml` | `1caa40574d12ebb4aa9cd03cc30d32f75edd8e9572e6d4876238f491c6e3f3de` |
| product `Cargo.lock` | `dd6ee5615630d788a351c4e3b395de0851fee41b34177823393d35d23a894316` |
| product `DEPENDENCIES.md` | `79c18078e22af74a4d3da682198b958337d0e018ec15d30c0d1617c877b1a535` |
| product `deny.toml` | `0059c35bc6e588cf99fe4b93025c4c767f3233fcbe67c4ec34a2a02c0212e2a3` |
| derivative commit | `89cb1798644c32aef06cc625f097cd9acb203417` |
| derivative tree | `cccd0d60c9ebfe191dca9d73e7ab8b27ae4d4ea5` |
| derivative `Cargo.lock` | `d6196fd8f31ea3b2cabbdb0e57546810643f344567f3e358ee3c000b3e2b59f5` |

The laboratory was created only because it did not exist. The copy excluded
`.git`, `target`, `.teremoq-dev`, `.cache`, `__pycache__` and Python bytecode.
The product and derivative were mounted or inspected read-only. The laboratory
was the only place where `Cargo.toml` and `Cargo.lock` changed. A temporary
`target/CACHEDIR.TAG` created by `cargo package` was removed after confirming it
was the only target residue.

The laboratory substitutions were exactly these three direct edges, preserving
the exact versions and every other manifest field:

- `moq-native-ietf =0.10.0` to the local derivative crate path;
- `moq-transport =0.16.1` to the local derivative crate path;
- development-only `moq-relay-ietf =0.7.25` to the local derivative crate path.

No product source was adapted. Laboratory hashes after substitution and offline
resolution are:

| Laboratory object | SHA-256 |
| --- | --- |
| `Cargo.toml` | `f44fafb4d4c9101c67440af73780e07076c9a50bba4ea6ad0d9e7b4b5a759384` |
| `Cargo.lock` | `857889695a109c4315a3f1ea42ab530a3bd6b39e7d6920299c825579c60e4f9b` |

## Semantic lock comparison

Cargo 1.93.0 regenerated the lock with `--offline` from the fixed local registry
cache. Both lockfiles contain 375 records including the root package:

| Property | Current | Path candidate |
| --- | ---: | ---: |
| records | 375 | 375 |
| crates.io records | 370 | 370 |
| Git records | 4 | 0 |
| path/workspace records | 1 | 5 |
| records with registry checksum | 370 | 370 |

The exact set difference is four source identities, without a coordinate or
dependency-record change:

- `moq-native-ietf 0.10.0`: Cloudflare baseline Git source to local path;
- `moq-transport 0.16.1`: Cloudflare baseline Git source to local path;
- `moq-relay-ietf 0.7.25`: Cloudflare baseline Git source to local path;
- transitive `moq-api 0.2.13`: the same checkout source change to local path.

All 371 shared exact records have identical dependency arrays and checksums.
There are zero feature-map differences across all 375 resolved packages and
zero license/MSRV-map differences. The differing raw `cargo tree` outputs are
fully explained by printing the Git URL versus the local path; the dependency
and feature edges are otherwise unchanged.

The highest declared dependency MSRV is 1.92 for the GStreamer 0.25 family;
the root declares 1.93. Cargo reported that it locked to versions compatible
with Rust 1.93. Ninety-seven packages do not declare a `rust-version`, which is
a metadata limitation rather than proof of a higher MSRV. No dependency in the
resolved candidate declares an MSRV above 1.93.

## License, provenance and DCO

The three derivative crates declare `MIT OR Apache-2.0`. The derivative retains
the upstream license texts:

- `LICENSES/Apache-2.0.txt` SHA-256
  `1248f876e0140942002b476a19c95d5b5b44c625e69c96611d23119ee87fa04e`;
- `LICENSES/MIT.txt` SHA-256
  `c7d191b5901a741f2e39c74bd7a7594014a81fbe2bc7d533d4c29ad4cfe4e057`.

`cargo deny check licenses advisories` passes identically for current and
candidate: zero errors, zero warnings, four advisory notes, and 288 license
notes. The one metadata package without an SPDX `license` field is
`webpki 0.22.4`; the existing policy clarifies ISC against its exact LICENSE
file hash. No copyright, license, NOTICE or dependency license expression is
changed by the proposed source substitution.

The baseline is an ancestor of the reviewed derivative commit. The range
`bf87128affd316463e5dcc7599a45001f222b6de..89cb1798644c32aef06cc625f097cd9acb203417`
contains nine commits, including the two reviewed merge commits. Every one of
the nine messages contains `Signed-off-by:`. The future consumer pin commit is
a new contribution and must independently carry a valid DCO 1.1 sign-off; this
report cannot satisfy that future obligation.

## RustSec and policy evidence

The fixed database was the official RustSec `advisory-db` origin at:

- commit `a7bfe16948bf6f3ee25bdee4822209f87da21b80`;
- tree `1152ddcadf432f7bf97746e51fb7f2d9e5968c49`;
- clean working state;
- primarily CC0-1.0, with repository-documented exceptions preserved.

`cargo audit --no-fetch --db <fixed-db> --file <lock> --json` produced
byte-identical JSON for the current and candidate consumer locks, SHA-256
`174d03c737fb6f5232bec9704408c6c8375e3532f5b6b2e52f671f975d31d7a1`:
zero vulnerabilities and the two unmaintained warnings listed above.

The derivative audit used its own lock and exited 1 with 16 vulnerability
entries and six warnings. Its unresolved set covers the already inventoried
`aws-lc-sys`, `crossbeam-epoch`, `h2`, `idna`, `rustls-webpki` and
`tracing-subscriber` vulnerability findings, plus unmaintained/unsound
warnings. That result remains governed by the separate RustSec remediation
plan and publication gates.

Full `cargo deny check` exits 0 for both graphs. Each reports 14 duplicate-crate
warnings. The set is unchanged and includes `core-foundation`, `getrandom`,
`openssl-probe`, `rand`, `rand_core`, `rustls-native-certs`,
`security-framework`, `socket2`, `syn`, `thiserror`, `thiserror-impl`, `tower`,
`untrusted` and `windows-sys`. The candidate's additional source-policy warning
is the expected unused Cloudflare allowance described above.

## Package and publication boundary

`cargo package --locked --offline --list --allow-dirty` succeeds for the
isolated candidate and lists 138 files. It contains the manifest, regenerated
lock, dependency policy/documentation, source, tests and fixture license. It
does not contain runtime trust material, `.teremoq-dev`, target output, caches,
Python bytecode, absolute paths or the derivative source tree. Git dependencies
are separately resolved components; their files are not embedded into the
gateway source package by this command.

Cargo warns that the unpublished root manifest lacks description,
documentation, homepage or repository metadata. `publish = false` remains in
force, so this is not an npm/crates.io publication approval. If a source package
is ever made a release artifact, its metadata and root LICENSE/NOTICE bundle
require a separate artifact review.

## Exact future pin and atomic owner changes

Only after the exact commit is published and independently verified may the
owner propose these three declarations in one consumer commit:

```toml
moq-native-ietf = { git = "https://github.com/Teremoq/moq-rs-teremoq", rev = "89cb1798644c32aef06cc625f097cd9acb203417", version = "=0.10.0" }
moq-transport = { git = "https://github.com/Teremoq/moq-rs-teremoq", rev = "89cb1798644c32aef06cc625f097cd9acb203417", version = "=0.16.1" }
moq-relay-ietf = { git = "https://github.com/Teremoq/moq-rs-teremoq", rev = "89cb1798644c32aef06cc625f097cd9acb203417", version = "=0.7.25" }
```

The last declaration must remain in `[dev-dependencies]`. The owner must not
copy the path-mode lock verbatim. Regenerate `Cargo.lock` from the published
Git commit with `--locked` follow-up verification; the final four MoQ records
must use the exact Teremoq Git source and full commit fragment rather than a
local path.

The same future consumer commit must update or produce:

1. `deny.toml`: exact reviewed Teremoq Git URL, without a wildcard; remove an
   unused Cloudflare allowance unless another final edge needs it.
2. `DEPENDENCIES.md`: make the derivative active, record commit/tree, the three
   direct edges, transitive `moq-api`, dual license, DCO/provenance, rollback,
   consumer-resolved versions and both residual RustSec warnings.
3. `THIRD_PARTY_NOTICES.md`: preserve Cloudflare/upstream attribution while
   identifying the Teremoq derivative and exact commit. Do not present the
   dependency as original Teremoq Apache-2.0 code.
4. `NOTICE`: preserve the existing Teremoq NOTICE. No new NOTICE term was found
   merely from switching a non-vendored MIT OR Apache-2.0 Git source; recheck
   the exact published tree and artifact bundle before release.
5. `Cargo.lock`: regenerate offline-capable evidence from the published Git
   object and compare semantically to this path oracle.
6. Artifact-specific SPDX or CycloneDX SBOMs for normal, build, development and
   all-feature views, recording sources, checksums, features, provider edges,
   licenses, relationship type, commit and tree. No fixed SBOM generator was
   inventoried in this package, so no generated SBOM pass is claimed here.
7. The controlled-mirror integration inventory and read-only verifier: add the
   immutable integration ref/commit/tree only after publication and verify the
   complete remote branch/tag inventory. Keep `baseline.env` baseline-only; do
   not rewrite or move the approved baseline.
8. Final package list, REUSE, cargo-deny, cargo-audit, redacted Gitleaks,
   checksum, provenance and rollback evidence from clean committed trees.

## Reproducible commands and results

The commands below use task-local variables so the public report does not
publish a local account name:

```bash
sha256sum .cursorrules \
  gateway-rs/Cargo.toml gateway-rs/Cargo.lock \
  gateway-rs/DEPENDENCIES.md gateway-rs/deny.toml

git -C "$MOQ_DERIVATIVE_WORKTREE" rev-parse HEAD 'HEAD^{tree}'
git -C "$MOQ_DERIVATIVE_WORKTREE" status --porcelain=v1 -uno
git -C "$MOQ_DERIVATIVE_WORKTREE" branch -r --contains \
  89cb1798644c32aef06cc625f097cd9acb203417

cargo generate-lockfile --offline
cargo metadata --locked --offline --format-version 1
cargo tree --locked --offline -e features -p gateway-rs
cargo tree --locked --offline -e features -i rustls@0.23.43
cargo tree --locked --offline -e features -i aws-lc-rs@1.18.0
cargo tree --locked --offline --duplicates

cargo-deny --offline --locked check --show-stats
cargo-audit audit --no-fetch --db "$FIXED_RUSTSEC_DB" \
  --file Cargo.lock --json
reuse lint
gitleaks dir "$SCAN_ROOT" --redact=100 --no-banner \
  --report-format json --report-path "$REDACTED_REPORT"
cargo package --locked --offline --list --allow-dirty
```

Key machine-readable output hashes retained during the review:

| Evidence | Current SHA-256 | Candidate SHA-256 |
| --- | --- | --- |
| Cargo metadata JSON | `3a51498e17948265cb6aa21974155dd790aa5667f92762a5e8a9ce7006d55155` | `b6dcb1a7755b1791e2057681e28da92cf4a4324625222c8c8560d4204de55efc` |
| cargo-audit JSON | `174d03c737fb6f5232bec9704408c6c8375e3532f5b6b2e52f671f975d31d7a1` | `174d03c737fb6f5232bec9704408c6c8375e3532f5b6b2e52f671f975d31d7a1` |
| cargo-deny license/advisory stats | `0660dc8a814a8548ea9d7d228bec8fc1c2e2f5ef1a0d80cbcb6cccb08b213bb9` | `0660dc8a814a8548ea9d7d228bec8fc1c2e2f5ef1a0d80cbcb6cccb08b213bb9` |
| candidate package list | — | `63fed64060beb412e9c0642e20309d6cd2b556d409ae8ee103d7ed45b5bd6e51` |

## Tool inventory and limitations

| Tool | Fixed version/object | License | Purpose |
| --- | --- | --- | --- |
| Rust and Cargo | 1.93.0; official local image `sha256:d0a4aa3ca2e1088ac0c81690914a0d810f2eee188197034edf366ed010a2b382` | Rust toolchain MIT OR Apache-2.0 | offline resolution, metadata, tree and package list |
| cargo-deny | 0.20.2; binary SHA-256 `b329e25933d01c36dd7c47d84ea5716694f9b7caf53a5003d45674703a8ed54a` | MIT OR Apache-2.0 | license, advisory, source and duplicate policy |
| cargo-audit | 0.22.2; binary SHA-256 `66f9c8f530950d106c1869ce27ef5a4008bcea53c7716c3ed8117586337ee7d8` | MIT OR Apache-2.0 | fixed-database lock audit |
| RustSec advisory-db | commit/tree recorded above | CC0-1.0 with repository exceptions | advisory data |
| REUSE | 5.1.1; official image `sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da` | GPL-3.0-or-later | SPDX/REUSE lint outside the artifact |
| Gitleaks | 8.30.1; official image `sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f` | MIT | redacted directory scan |

No network, install, fetch, compile, test, SBOM generation or remote query was
performed. Cargo metadata/tree/package and policy checks are not substitutes
for the separately owned platform, protocol, PKI and test matrices. Remote
absence is established from the frozen local `origin` refs; after an authorized
publication, the owner must verify the live remote read-only before pinning.

## Gate decision

**SUPPLY_CHAIN_READY_AFTER_PUBLICATION** means only that the isolated path
oracle introduces no incidental coordinate, checksum, feature, provider,
license, MSRV or consumer-RustSec change, and that an exact future Git pin has a
bounded atomic update plan. It is conditional on all eight owner changes above,
an authorized publication of the exact commit/tree, final remote verification,
clean package evidence, SBOMs and the separately owned test gates.

It does **not** mean `PUBLICATION: READY`, does not authorize publication or a
pin, and does not approve T. Apart from this report and the explicitly
authorized isolated laboratory, no product code, manifest, lock, existing
document, derivative, Git ref, remote, service, architecture, license or
dependency was modified by this review.
