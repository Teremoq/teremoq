# TP-OSS-SC review: I2 direct Rustls test dependency

- Review date: 2026-08-27
- Reviewer: `TP-OSS-SC`
- Owner under review: Task 05 / `TP-RUST-DIST`
- Security owner: `TP-SEC-PKI`; its formal report was not edited
- Read-only checkout: `/home/jimbomilk/moq-rs-teremoq-work`
- Checkout HEAD during review: `05b41127ecbd48de4c59fe1626c43b1e423c33a9`
- Checkout branch during review: `teremoq/i2-required-auth-bf87128`
- Scope: proposed direct test-only dependency on `rustls 0.23.31`

This is a technical license and software supply-chain review, not legal advice.

## Verdict

**APPROVE TEST-ONLY DIRECT DEPENDENCY**

The approved manifest form is exactly:

```toml
rustls = { version = "=0.23.31", default-features = false, features = ["ring"] }
```

It must remain under `moq-relay-ietf` `[dev-dependencies]`. This approval is
conditional on the exact delta and post-change gates below. It does not approve
a normal/runtime dependency, another Rustls version, default features, another
crypto provider, a production TLS change or any remote/public action.

## Read-only and parallel-review boundary

The checkout was never edited by this reviewer. Git reads used optional locks
disabled; tool runs mounted the checkout read-only and wrote only to disposable
locations outside it. No checkout, branch, add, commit, config, clean, source,
manifest or lockfile modification was performed by `TP-OSS-SC`.

Task 05 implemented the proposed two-line dependency/lock delta in parallel
during this review. The manifest and lock hashes consequently changed between
the first and later read-only observations. This report evaluates the proposal
and the observed minimal shape; it is not a final attestation of Task 05's
eventual complete I2 delta. The Master must compare the final files and rerun
the commands in this report.

At the later observation, the targeted delta was exactly:

- one manifest line adding the approved direct dev-dependency; and
- one `Cargo.lock` line adding `"rustls 0.23.31"` to the local
  `moq-relay-ietf` package dependency list.

There was no new Rustls package, version, source or checksum. Targeted
`git diff --check` passed at that observation.

## Version, source and integrity

The existing lock already contained both `rustls 0.22.4` and `rustls 0.23.31`.
The proposed exact pin selects the existing 0.23.31 package and cannot resolve
to 0.22.4 or a later 0.23 release.

Locally cached crates.io metadata for 0.23.31 records:

| Property | Evidence |
|---|---|
| Package | `rustls 0.23.31` |
| Registry source | crates.io index |
| Official repository/homepage | `https://github.com/rustls/rustls` |
| Published | 2025-07-29T18:12:18Z |
| Yanked in the local index snapshot | false |
| MSRV | Rust 1.71 |
| License expression | `Apache-2.0 OR ISC OR MIT` |
| Crate checksum | `c0ebcbd2f03de0fc1122ad9bb24b127a5a6cd51d72604a3f3c50ac459762b6cc` |

The cached `.crate` SHA-256, local crates.io index checksum and `Cargo.lock`
checksum match exactly. The cached source includes `LICENSE-APACHE`,
`LICENSE-ISC` and `LICENSE-MIT`; the README identifies active project
maintainers. No `NOTICE` or `COPYRIGHT` file is shipped in the crate.

The local index evidence was current as of the review workspace, but it is not
a substitute for an up-to-date advisory database or a future registry check.

## License compatibility and obligations

Rustls offers Apache-2.0, ISC and MIT alternatives. Each is permissive and
compatible with use by the dual-licensed `MIT OR Apache-2.0` derivative and an
Apache-2.0 Teremoq integration. Rustls remains a separately licensed dependency;
its code must not be represented as Teremoq code or relicensed.

The change adds no source file, so it requires no new per-file SPDX header or
REUSE sidecar. The existing `moq-relay-ietf/Cargo.toml` already declares
`MIT OR Apache-2.0`, and the generated `Cargo.lock` remains covered by the
upstream REUSE policy. REUSE must still pass after the complete I2 delta.

No project `NOTICE` change is required for a non-vendored test-only dependency
whose crate has no NOTICE file. If Rustls source or license material is later
vendored or redistributed, preserve the applicable upstream license text and
attribution. Do not copy the Rustls implementation into I2.

The development/test SBOM and direct-dependency inventory must record Rustls as
a direct dev-dependency of `moq-relay-ietf`, with exact version, checksum,
official repository, license, purpose, owner and update policy. A release SBOM
must follow the actual normal/runtime artifact graph. This new edge must not be
misclassified as runtime merely because Rustls 0.23.31 is already transitively
present through `moq-native-ietf`.

## Feature and cryptographic-provider analysis

Rustls 0.23.31 defaults enable `aws_lc_rs`, `logging`,
`prefer-post-quantum`, `std` and `tls12`. Its optional `ring` feature enables a
second built-in provider. The existing `moq-native-ietf` declaration uses
Rustls defaults plus `ring`, while `web-transport-quinn` requests Rustls with
defaults disabled and the ring provider. The existing lock entry therefore
already lists both `aws-lc-rs` and `ring`.

The proposed direct edge uses `default-features = false` and asks only for
`ring`. It does not activate a provider or package that is absent from the
current graph, and it does not itself request logging, post-quantum preference,
TLS 1.2 or `aws-lc-rs`. Cargo feature unification means it also cannot remove
the features already activated through `moq-native-ietf`.

Because both provider features are present in the unified graph, Rustls cannot
always infer a process default. The I2 test must construct configurations with
the explicit existing ring provider, for example through
`rustls::crypto::ring::default_provider()` and
`builder_with_provider`, and must select TLS 1.3 for QUIC. It must not call a
plain builder that relies on ambiguous automatic provider selection and must
not install or mutate a process-global provider merely to make the test pass.

Do not add `std`, `tls12`, `logging`, `aws_lc_rs`, default features or another
provider to this direct edge unless the final compiler/feature evidence proves
it necessary and `TP-OSS-SC` reviews the expanded request. The existing normal
dependency graph already supplies `std`; the test-only edge need not duplicate
that request.

## Lockfile and Rust 1.93 impact

Rustls 0.23.31 declares MSRV 1.71 and is already compiled in the locked graph.
It is therefore compatible with the approved Rust 1.93.0 toolchain. An exact
direct dev edge does not change the minimum compiler or require a new registry
download when the pinned crate is cached.

The only acceptable `Cargo.lock` delta is the observed local package edge:

```text
 "rustls 0.23.31",
```

No package stanza, checksum, version, dependency list for Rustls, or unrelated
package may move. If Cargo changes anything else, stop and return the delta for
review. The lock must remain versioned and all final commands must use
`--locked`.

Read-only `cargo metadata --locked --offline --no-deps` with Rust/Cargo 1.93.0
accepted the observed manifest and lock and reported one direct Rustls edge
with kind `dev`, requirement `=0.23.31`, defaults false and feature `ring`.

A complete offline feature-tree run could not finish because the disposable
local cache lacked `byteorder 1.5.0`; no network fetch was allowed. This is an
environment/cache limitation, not evidence that the dependency fails to
resolve. The complete feature and build gates remain mandatory after Task 05
finishes its delta.

## Advisory and maintenance risk

The already available `cargo-audit 0.22.2` executable could not perform a
valid offline audit because no local RustSec advisory database was present. No
database was fetched and no claim of zero advisories is made.

Locally verifiable risk is limited as follows:

- 0.23.31 is already in the exact runtime/test lock graph;
- the crates.io index snapshot records it as not yanked;
- archive, index and lock checksums agree;
- the new edge is dev-only and selects no new package; and
- Rustls is maintained at its official project repository.

This means the direct edge does not introduce a new version-level advisory
surface, but direct use still requires an up-to-date RustSec decision. A final
advisory scan against a recorded database revision is a condition of this
approval. Any Rustls, ring or provider advisory applicable to the test graph
must be assessed rather than ignored merely because the edge is dev-only.

## Reuse of existing public fixtures

The I1 DER fixtures are deliberately public, synthetic, non-production and
licensed `MIT OR Apache-2.0` through their individual REUSE sidecars. Reusing
their exact bytes for the integrated mTLS test is license-compatible and does
not make the keys productive secrets.

Conditions:

1. Prefer one source of truth; do not silently duplicate the seven DER files.
2. If a copy is unavoidable for Cargo package isolation, copy the README,
   individual sidecars and SHA-256 inventory, retain the test-only warning and
   rerun REUSE/Gitleaks against the copied paths.
3. Never add a blanket scanner exclusion for `.der`, key names or test data.
   Any suppression must be narrow, hash-bound and reviewed.
4. Never use the fixtures in a trust store, deployed endpoint, product example,
   customer configuration or release credential.
5. If the test references a sibling crate path with `include_bytes!`, run the
   package boundary gate below; a workspace-relative test that disappears from
   the packaged crate is not reproducible packaging evidence.

Synthetic private-key bytes may still trigger secret scanners. Such a match
must be classified by file, hash and provenance without printing key material;
it is not permission to suppress future unknown keys.

## Conditions on the final Task 05 delta

Approval remains valid only if all of the following hold:

1. The manifest line is exactly the approved test-only declaration.
2. The lock delta is exactly the single local dependency edge described above.
3. No normal dependency, runtime source, protocol, ALPN, draft, feature,
   production provider or unrelated package changes because of this request.
4. Test code explicitly selects the ring provider and TLS 1.3.
5. Existing public fixtures retain their hashes, licenses and non-production
   boundary; any new copy meets the obligations above.
6. License, REUSE, advisory, feature-tree, compile, test and clippy gates pass.
7. The final report records the advisory database revision and any ignored or
   allowed advisory with a reason and owner.

If any condition differs, the dependency review returns to `CHANGES REQUIRED`
until `TP-OSS-SC` reviews the new evidence.

## Required post-change verification

Run from the derivative checkout with the approved pinned Rust 1.93.0
environment and project-approved, non-global tools. Set `rustsec_db` to the
absolute path of the existing reviewed RustSec database checkout and record its
commit before running the block:

```bash
git diff --check
git diff --unified=0 HEAD -- moq-relay-ietf/Cargo.toml Cargo.lock

cargo metadata --locked --format-version=1
cargo tree --locked -p moq-relay-ietf -e normal,build
cargo tree --locked -p moq-relay-ietf -e all
cargo tree --locked -i rustls@0.23.31 -e features
cargo tree --locked -d

cargo check --locked -p moq-relay-ietf --all-targets --all-features
cargo test --locked -p moq-relay-ietf --all-targets --all-features
cargo clippy --locked --no-deps -p moq-relay-ietf --all-targets \
  --all-features -- -D warnings

cargo deny check licenses advisories
cargo audit --no-fetch --db "$rustsec_db" \
  --file Cargo.lock

cargo package --locked -p moq-relay-ietf --list
reuse lint
```

Before accepting the outputs:

- record the RustSec database commit instead of using an unversioned result;
- confirm the normal/build tree is unchanged from the I1 base;
- confirm the all-edge tree contains the direct dev edge at exactly 0.23.31;
- confirm no third Rustls version or new provider appears;
- inspect `Cargo.lock` rather than relying only on command exit status; and
- verify that package contents include every fixture needed by packaged tests,
  or document that those tests are workspace-only and are not a package gate.

No tool should be installed globally. If the advisory database is unavailable,
the advisory gate is incomplete and must be reported as such.

## Tools and immutable evidence

| Tool or source | Version / identity | License | Use |
|---|---|---|---|
| Rust container | 1.93.0; `sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57` | Rust toolchain MIT OR Apache-2.0; image packages separate | Read-only metadata attempt |
| Cargo | 1.93.0 (`083ac5135`) | MIT OR Apache-2.0 | Locked metadata and graph gate |
| rustc | 1.93.0 (`254b59607`) | MIT OR Apache-2.0 | MSRV target |
| cargo-audit | 0.22.2; binary SHA-256 `66f9c8f530950d106c1869ce27ef5a4008bcea53c7716c3ed8117586337ee7d8` | MIT OR Apache-2.0 | Available advisory client; no database available |
| cargo-deny | 0.20.2; binary SHA-256 `b329e25933d01c36dd7c47d84ea5716694f9b7caf53a5003d45674703a8ed54a` | MIT OR Apache-2.0 | Required license/advisory gate |
| Rustls crate archive | 0.23.31; SHA-256 `c0ebcbd2f03de0fc1122ad9bb24b127a5a6cd51d72604a3f3c50ac459762b6cc` | Apache-2.0 OR ISC OR MIT | Package metadata/source/license evidence |

## Activity confirmation

The only persistent reviewer output is this report. `TP-OSS-SC` did not edit
the derivative checkout, I2 source, either manifest, `Cargo.lock`, fixtures or
the formal security report. No email, issue, pull request, message, tag,
release, publication, push or remote mutation was performed.

**LOCAL TEST-DEPENDENCY REVIEW ONLY / NO REMOTE MUTATION**

## Final appendix: I2 snapshot closure on 2026-08-27

### Final verdict

**CHANGES REQUIRED**

This appendix supersedes the earlier conditional verdict for the final I2
publication boundary. The direct dependency is still correctly scoped and
license-compatible in isolation, but the mandatory advisory and package gates
do not pass. This verdict does not reject the test-only Rustls declaration; it
rejects publication readiness of the reviewed snapshot.

### Exact snapshot and dependency delta

The read-only checkout still had HEAD
`05b41127ecbd48de4c59fe1626c43b1e423c33a9`. The final files matched the hashes
provided by the Master:

| File | SHA-256 |
|---|---|
| `Cargo.lock` | `13b9f1c54ccbe644dcf4f07542f610950cd013b291c928b6b3ad39ac1751ce80` |
| `moq-relay-ietf/Cargo.toml` | `83185ddb3f1523a6d7d9c577abbf29010eb34d6043538c1b28ff1057bb888b11` |

`git diff --unified=0 HEAD -- Cargo.lock moq-relay-ietf/Cargo.toml` contained
exactly two additions and no removal:

- one manifest line under `[dev-dependencies]`, with exact requirement
  `=0.23.31`, defaults disabled and only `ring`; and
- one local `moq-relay-ietf` lock dependency edge to `rustls 0.23.31`.

It added no package stanza, checksum, source or Rustls version. Locked metadata
reported 325 packages and nine workspace members. The direct Rustls dependency
was `kind = dev`, `uses_default_features = false`, and `features = ["ring"]`.
The only Rustls versions remained 0.22.4 and 0.23.31.

The current and I1 `cargo tree --locked -p moq-relay-ietf -e normal,build`
outputs were byte-identical after replacing their different absolute checkout
roots. Both normalized outputs had SHA-256
`7ca755ffe755c0d6a8bd822afbe976a57f94a873c9d8ca5a0d535c7c413f98d8`.
Therefore the dependency request added no normal/build package or feature.

The all-edge tree placed `rustls feature "ring"` under the relay's
`[dev-dependencies]`. The inverse feature tree showed that `ring` was already
enabled by `moq-native-ietf`, while Rustls default, `aws_lc_rs`, `std` and
`tls12` remained enabled through pre-existing normal dependencies. The new
edge did not request or newly activate those features.

The I2 source calls `rustls::crypto::ring::default_provider()` once, passes the
provider explicitly to both client and server builders, and restricts both to
`rustls::version::TLS13`. It references exactly five existing I1 fixture files
from `moq-native-ietf/tests/data`: the CA certificate, server certificate and
key, and client A certificate and key. No DER, PEM or key file exists below
`moq-relay-ietf`; the fixture bytes were referenced rather than duplicated in
the workspace snapshot.

### RustSec and cargo-audit gate

The official public database was cloned into a disposable directory and used
read-only:

- origin: `https://github.com/RustSec/advisory-db.git`;
- commit: `6420e39260b3d771b049954cf5d52b57e2118da4`;
- commit timestamp: `2026-08-27T14:01:44+02:00`;
- database content: CC0-1.0 by default, with explicitly marked CC-BY-4.0
  imported advisories where applicable.

The local `cargo-audit 0.22.2` binary, SHA-256
`66f9c8f530950d106c1869ce27ef5a4008bcea53c7716c3ed8117586337ee7d8`
and license `MIT OR Apache-2.0`, ran equivalently to:

```bash
cargo audit --no-fetch --db "$rustsec_db" --file Cargo.lock
```

The standalone binary requires its `audit` subcommand, so the actual invocation
was `cargo-audit audit --no-fetch --db ... --file ... --json`. It exited 1 and
reported 19 vulnerable lock entries:

| Package | Version | RustSec advisories |
|---|---:|---|
| `aws-lc-sys` | 0.30.0 | RUSTSEC-2026-0045, -0046, -0047, -0048 |
| `bytes` | 1.6.0 | RUSTSEC-2026-0007 |
| `crossbeam-epoch` | 0.9.18 | RUSTSEC-2026-0204 |
| `h2` | 0.4.5 | RUSTSEC-2026-0258 |
| `idna` | 0.5.0 | RUSTSEC-2024-0421 |
| `quinn-proto` | 0.11.13 | RUSTSEC-2026-0037, -0185 |
| `rustls-webpki` | 0.102.4 | RUSTSEC-2026-0049, -0098, -0099, -0104 |
| `rustls-webpki` | 0.103.4 | RUSTSEC-2026-0049, -0098, -0099, -0104 |
| `tracing-subscriber` | 0.3.18 | RUSTSEC-2025-0055 |

It also emitted all six informational warnings present in the lock:

- unmaintained: `adler 1.0.2` / RUSTSEC-2025-0056,
  `paste 1.0.15` / RUSTSEC-2024-0436 and `rustls-pemfile 2.1.2` /
  RUSTSEC-2025-0134; and
- unsound: `anyhow 1.0.85` / RUSTSEC-2026-0190 and both `rand 0.8.5` and
  `rand 0.9.2` / RUSTSEC-2026-0097.

No advisory was ignored, allowed or suppressed. No advisory targets the
`rustls 0.23.31` package entry itself, but several affect its selected provider
or certificate-validation graph. Dev-only classification does not turn those
findings into a passing publication gate.

### cargo-deny gate and limitation

`cargo-deny 0.20.2`, local binary SHA-256
`b329e25933d01c36dd7c47d84ea5716694f9b7caf53a5003d45674703a8ed54a`
and license `MIT OR Apache-2.0`, was run against locked Cargo 1.93.0 metadata
and a disposable RustSec checkout at the same exact database commit. The
requested combined check did not pass: exit code 5, 18 vulnerability
diagnostics, two unsound diagnostics and three unmaintained diagnostics. The
different diagnostic counts from cargo-audit are presentation differences:
cargo-audit reports separate affected lock versions where applicable.

The mirror has no `deny.toml`. Cargo-deny therefore used its empty default
license allowlist and produced 312 `rejected` license diagnostics plus one
missing-license-field warning. That is not a meaningful approved license
policy and cannot be reported as a license pass. The offline host-side fallback
also produced 303 index-query warnings because no host `cargo` executable was
available to resolve its sparse-index URL, even though all crate sources and
locked metadata had been populated through the pinned container. Cargo-audit
against the explicitly pinned database remains the complete advisory result;
cargo-deny independently confirms that both the advisory and configured-license
gates are currently red.

Before publication review can pass, the derivative needs a reviewed
`deny.toml` with the accepted upstream license expressions and justified
exceptions, followed by a clean `cargo deny check licenses advisories` in the
pinned environment. This appendix does not create that policy or suppress any
finding.

### REUSE/SPDX gate

The official REUSE 5.1.1 image, fixed at
`sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da`
and licensed GPL-3.0-or-later, ran read-only against the final checkout. Its OCI
metadata identifies upstream revision
`ba42a0ba0a9ada6e89660cb8363fcf01181f1675`. `reuse lint` exited 0:

- 201/201 files had copyright information;
- 201/201 files had license information;
- zero bad, deprecated, missing or unused licenses; and
- only MIT and Apache-2.0 were used.

The direct Rustls edge remains compatible with the derivative's
`MIT OR Apache-2.0` license. It adds no vendored source and creates no new
NOTICE obligation. Rustls must remain a separately licensed direct development
dependency in the development/test SBOM and dependency inventory.

### Cargo package and workspace-only fixture boundary

The exact requested command
`cargo package --locked -p moq-relay-ietf --list` exited 101 because the final
I2 snapshot is an uncommitted working tree with seven changed or new relay
files. Repeating only for inspection with `--allow-dirty` exited 0 and listed
26 package files. The list includes `src/i2_tests.rs` but no DER file and no
`tests/data` path.

`cargo package --locked -p moq-relay-ietf --allow-dirty --no-verify` produced
a 26-file `.crate` with SHA-256
`12a70a94add9b05c92915c9f5cddcda2414913f1c6b963b2ba87d0a8ae59bf61`.
After extraction, all five `include_bytes!("../../moq-native-ietf/tests/data/..." )`
references resolved outside the package root and every resolved path was
absent. The I2 tests are therefore workspace-only in this snapshot; the
packaged test source is not self-contained and cannot reproduce the integrated
mTLS tests.

A full dirty-package verification also failed, independently of the missing
test fixtures. Cargo correctly rewrote the sibling path dependency to the
published `moq-native-ietf 0.10.0`; that registry release lacks the new I1 peer
evidence API. Compilation ended with 13 errors for absent I1 types and methods,
and Cargo reported `failed to verify package tarball`. The same run warned that
locked `bytes 1.6.0` is yanked. No warning or error was suppressed.

Publication reproducibility is blocked by both boundaries:

1. Put the five required synthetic fixtures inside the package boundary, with
   their individual REUSE sidecars, test-only warning, provenance and hash
   inventory, then update the five `include_bytes!` paths. A dedicated
   publishable test-fixture crate is acceptable but is a larger change. Rerun
   REUSE, redacted secret scanning and the TP-SEC-PKI synthetic-key review; the
   copied private keys remain deliberately public test material but retain
   false-secret and accidental-reuse risk.
2. Publish or otherwise version the compatible I1 `moq-native-ietf` API before
   packaging the relay, and make the relay depend on that exact compatible
   release. If crates.io publication is intentionally out of scope, mark and
   document `moq-relay-ietf` as non-publishable instead of presenting
   `cargo package` as a passing release gate.
3. Resolve or explicitly risk-accept the RustSec findings through the proper
   owners, update the lock without unrelated drift, add the reviewed cargo-deny
   policy and rerun both advisory tools. This review grants no suppression.

After those changes, rerun the exact package list from a committed clean tree,
extract the `.crate`, prove all five paths stay inside it, and run tests from
the extracted package in addition to normal package verification.

### Commands, environment and integrity controls

All Cargo commands used Rust/Cargo 1.93.0 in the already-present image fixed at
`sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57`.
The derivative checkout was mounted read-only; Cargo homes, targets, extracted
packages and both advisory database checkouts lived only below disposable
`/tmp` directories. No tool or dependency was installed globally.

The final validation block covered:

```bash
sha256sum Cargo.lock moq-relay-ietf/Cargo.toml
git diff --unified=0 HEAD -- Cargo.lock moq-relay-ietf/Cargo.toml
cargo metadata --locked --format-version=1
cargo tree --locked -p moq-relay-ietf -e normal,build
cargo tree --locked -p moq-relay-ietf -e all
cargo tree --locked -i rustls@0.23.31 -e features
cargo audit --no-fetch --db "$rustsec_db" --file Cargo.lock
cargo deny check licenses advisories
reuse lint
cargo package --locked -p moq-relay-ietf --list
cargo package --locked -p moq-relay-ietf --allow-dirty
git diff --check
```

The final manifest and lock hashes and the checkout's pre-existing status were
unchanged after the review. `TP-OSS-SC` edited no source, manifest, lockfile,
fixture, Git metadata or formal security report. The only persistent reviewer
change was this dated appendix. No checkout, branch, add, commit, config, clean,
push, pull request, issue, tag, release, publication, message, email or remote
write occurred.

Final document validation passed: repository `git diff --check` exited 0; the
report-specific no-index whitespace check emitted no error; and a
case-insensitive whole-word scan found zero unfinished-document markers. The
report remains an untracked local review artifact for Master integration; it
was not added to the index.

**LOCAL SUPPLY-CHAIN REVIEW ONLY / NOT PUBLISHED / NO REMOTE MUTATION**
