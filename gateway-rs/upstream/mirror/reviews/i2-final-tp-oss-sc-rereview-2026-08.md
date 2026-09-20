# I2 final TP-OSS-SC publication-boundary re-review

Date: 2026-08-27

Profile: `TP-OSS-SC: Open Source & Software Supply Chain Engineer`

Reviewed checkout: `/home/jimbomilk/moq-rs-teremoq-work`

Base/HEAD: `05b41127ecbd48de4c59fe1626c43b1e423c33a9`

This is a read-only technical license and software supply-chain review. It is
not legal advice, a release approval, a push authorization, or evidence that
the unpublished working tree exists on any remote.

## Separate verdicts

**LOCAL COMMIT: APPROVE**

The exact 22-path I2 snapshot reviewed below is acceptable for local retention
and a local commit by its owning task. The copied fixtures are necessary to
make the relay crate package boundary self-contained; they preserve their I1
bytes, dual license, attribution and explicit test-only warning. I2 adds one
exact dev-dependency edge to an already locked package, no package version and
no normal/build feature or provider edge. This verdict does not stage or commit
the files and is invalid if the inventory or hashes change.

**PUBLICATION: NOT READY**

Publication remains blocked by the pre-existing RustSec set, the absence of an
approved `deny.toml`, and registry releases that do not yet contain the stacked
I1 peer-evidence API or the pending `moq-transport` accept API. No push,
publication, tag or release is authorized by the local-commit verdict.

## Scope integrity and exact inventory

`GIT_OPTIONAL_LOCKS=0` was used for Git inspection. HEAD remained the stated I1
commit, `git diff --cached --quiet` exited 0, and no index entry was staged.
The working snapshot comprises exactly seven modified tracked paths and fifteen
new untracked paths:

| State | Path | SHA-256 |
|---|---|---|
| modified | `Cargo.lock` | `13b9f1c54ccbe644dcf4f07542f610950cd013b291c928b6b3ad39ac1751ce80` |
| modified | `moq-relay-ietf/Cargo.toml` | `83185ddb3f1523a6d7d9c577abbf29010eb34d6043538c1b28ff1057bb888b11` |
| new | `moq-relay-ietf/src/authorization.rs` | `101fc1a0a8c1fc8d61453f43617cbfef1913a7db91767f29c9e59b9970d148c2` |
| modified | `moq-relay-ietf/src/consumer.rs` | `06f601e1f4efdb3c7f4bca99114d275db0abcdca436fece01c352f3fb13a256d` |
| new | `moq-relay-ietf/src/i2_tests.rs` | `595ac7f27b545c9370b22b8fbf483ac0c4de91e779413f93fc42643d6dca0e6f` |
| modified | `moq-relay-ietf/src/lib.rs` | `c3ccba4a249469e3926a5a6e8f92912694808c13e2fe9cd42e74c08dc9c34990` |
| modified | `moq-relay-ietf/src/producer.rs` | `8b9c723341ad93c77f94a57fc833323c695d45078edd541c0a42a80ea51e966e` |
| modified | `moq-relay-ietf/src/relay.rs` | `d224efb6055d10cfd853ac660df93dabda34e2d65424f84d5ecb3a1da29b9bbe` |
| new | `moq-relay-ietf/tests/data/i2/README.md` | `3f6ffc3096c54975fb75b795a06a7b5083c6bd3388a03c3a9023bc3a3ef54862` |
| new | `moq-relay-ietf/tests/data/i2/SHA256SUMS` | `97ed99bcd8d4144652bc729dd6f7e80a4e258f397f3b620a274d9c8b08e2bee9` |
| new | `moq-relay-ietf/tests/data/i2/ca.cert.der` | `ea33add88bed4676c51baa4f8da9df33d04e99cecf7d0846a756e23b0f66461b` |
| new | `moq-relay-ietf/tests/data/i2/ca.cert.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| new | `moq-relay-ietf/tests/data/i2/client-a.cert.der` | `e75cc0d4f020259b4b86d5b722762cbd7aba9b219a8d3234a8b5c5af3e214eb2` |
| new | `moq-relay-ietf/tests/data/i2/client-a.cert.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| new | `moq-relay-ietf/tests/data/i2/client-a.key.der` | `416263df93ab7f326f2d82f198fcdf9da850a55e5564ca964c3eceb7976bd288` |
| new | `moq-relay-ietf/tests/data/i2/client-a.key.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| new | `moq-relay-ietf/tests/data/i2/server.cert.der` | `053a80b61f971f0601d83305ec6139fbcd7ed2f78c541078ac6e68a7e6da16bc` |
| new | `moq-relay-ietf/tests/data/i2/server.cert.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| new | `moq-relay-ietf/tests/data/i2/server.key.der` | `1d02d7ec66886fc2bb2cc3104851e1c182d7980e946d8df2e8f0f3ae33c30436` |
| new | `moq-relay-ietf/tests/data/i2/server.key.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| modified | `moq-transport/src/session/mod.rs` | `5fa5a8a1c8d68faf86553146eb7b0d39a7ee9aea6a41b97e4abf261500115b00` |
| new | `moq-transport/tests/pending_accept.rs` | `7165d0bb033e8e0ffe180b384879b8d738235f9e021da57d4a8505567e6f2de1` |

The six hashes supplied to this re-review all match. The inventory was derived
by combining `git diff --name-status HEAD` with
`git ls-files --others --exclude-standard`; directory-collapsed status output
was not used as a file count.

## Findings by severity

### High -- publication blockers inherited from the baseline

1. Cargo Audit against the frozen official RustSec database returns 19
   vulnerable lock entries representing 15 unique advisory IDs and six warning
   entries. The I1 lock and I2 lock sets are exactly equal by advisory, package
   and version.
2. `cargo deny check licenses advisories` exits 5. Advisories fail, and the
   mirror has no reviewed `deny.toml`; cargo-deny's empty/default license policy
   reports 312 rejected-license diagnostics and cannot be treated as a license
   allowlist gate.
3. Full crate verification against registry dependencies exits 101 because
   published `moq-native-ietf 0.10.0` lacks the I1 peer-evidence API and
   published `moq-transport 0.16.1` lacks
   `Session::accept_pending_with_config`. Cargo emits 15 compiler diagnostics
   (two E0432, three E0425, two E0599 and eight consequent E0282) and warns that
   locked `bytes 1.6.0` is yanked.

These blockers prohibit publication, but they predate or sit below the local
I2 delta and do not make its now-self-contained fixture copy unsuitable for a
local commit.

### Medium -- deliberately public synthetic private keys

`client-a.key.der` and `server.key.der` are private-key encodings by design,
but they are public, synthetic test material copied from I1, not productive
secrets. Accidental deployment would still be unsafe. The adjacent README says
the keys are public test material and must never be used by a deployed
endpoint; each binary has a sidecar and a pinned checksum. Local retention is
acceptable only while that warning and the byte-for-byte provenance remain.

### Informational -- pre-existing scanner match outside I2

A no-suppression directory scan of the complete relay crate reports one
redacted `private-key` rule match at pre-existing `src/tls.rs:115`. Inspection
shows that line is only the literal PEM delimiter in a comment describing the
existing key parser; no key value is present or reported. The exact 22-path I2
focal bundle passes Gitleaks with zero findings. This distinction prevents an
unrelated baseline comment from being represented as an I2 secret and does not
hide the broad-scan result.

## Dependency, feature and provider boundary

The only manifest delta is this line under `moq-relay-ietf`
`[dev-dependencies]`:

```toml
rustls = { version = "=0.23.31", default-features = false, features = ["ring"] }
```

The only `Cargo.lock` delta is one dependency-list edge from
`moq-relay-ietf` to the existing `rustls 0.23.31` package. Cargo 1.93.0 locked
metadata reports `kind = "dev"`, exact requirement `=0.23.31`, default features
disabled and only `ring` requested. `cargo tree -e dev --invert
rustls@0.23.31` shows the direct dev edge. A byte comparison of
`cargo tree -e normal,build -p moq-relay-ietf` for I1 and I2 is identical.
No package, normal/build dependency, production provider or third Rustls
version is introduced.

The mTLS test constructs `rustls::crypto::ring::default_provider()` explicitly
and restricts both client and server builders to `rustls::version::TLS13`.
The five fixtures are referenced once through crate-internal
`include_bytes!("../tests/data/i2/...")` paths; no sibling-crate path remains.

The pending API source and its compile-time public API test add no manifest,
lock, third-party license or dependency change. New Teremoq source/test files
use `MIT OR Apache-2.0`. The relay crate remains `MIT OR Apache-2.0`; Rustls
remains separately licensed `Apache-2.0 OR ISC OR MIT`. No LICENSE, NOTICE or
copyright file changed, and no new NOTICE obligation was identified for the
non-vendored dev dependency. The development/test SBOM must nevertheless record
the direct dev relationship, exact version, features and provider.

## RustSec baseline comparison

Database evidence:

- origin: `https://github.com/RustSec/advisory-db.git`;
- commit: `6420e39260b3d771b049954cf5d52b57e2118da4`;
- I1 lock SHA-256:
  `b518a2fa4a6d7a0ffe0bdfe4b530f05196ac0f5e6f7ef51da9e5a83c0b0561c0`;
- I2 lock SHA-256:
  `13b9f1c54ccbe644dcf4f07542f610950cd013b291c928b6b3ad39ac1751ce80`.

Both `cargo audit --no-fetch --db <fixed-db> --file <lock>` runs exit 1 and
produce the same result:

- vulnerable entries: 19; unique IDs: 15;
- affected locked packages: `aws-lc-sys 0.30.0`, `bytes 1.6.0`,
  `crossbeam-epoch 0.9.18`, `h2 0.4.5`, `idna 0.5.0`,
  `quinn-proto 0.11.13`, `rustls-webpki 0.102.4`,
  `rustls-webpki 0.103.4` and `tracing-subscriber 0.3.18`;
- warnings: unmaintained `adler 1.0.2`, `paste 1.0.15` and
  `rustls-pemfile 2.1.2`; unsound `anyhow 1.0.85`, `rand 0.8.5` and
  `rand 0.9.2`.

No finding is removed by excluding the new dev edge because the affected
packages are baseline/runtime or other pre-existing paths. No advisory or
warning was ignored, allowed or suppressed.

## Fixture provenance, SPDX and secret boundary

`cmp` confirms that all five copied DER files are byte-for-byte equal to the
tracked I1 sources under `moq-native-ietf/tests/data`. Their five sidecars are
also byte-for-byte equal to the I1 sidecars and declare
`MIT OR Apache-2.0`. Running `sha256sum -c SHA256SUMS` succeeds for every copied
binary both in the checkout and in the extracted crate.

OpenSSL 3.5.5 parses the three certificates. Their subjects/issuer use only
`moq-native-ietf-test-ca`, `moq-native-ietf-client-a` and
`moq-native-ietf-server`; the server SAN is only `localhost` and `127.0.0.1`.
No customer identity, productive namespace or external address was found.

The official REUSE 5.1.1 image, fixed by digest, exits 0 against the entire
working tree: 209/209 files have copyright and license information, no bad,
deprecated, missing or unused license is reported, and the used licenses are
MIT and Apache-2.0.

Gitleaks 8.30.1, fixed by digest, scans the exact 22-path focal bundle with
`--redact=100`, no custom configuration, no allowlist and no suppression. It
exits 0 after scanning approximately 314 KB and reports no leak. No sensitive
value is reproduced in this report.

## Cargo package boundary

The requested inspection command
`cargo package --locked --offline -p moq-relay-ietf --list --allow-dirty`
exits 0 and lists 38 files. It includes:

- `src/i2_tests.rs`;
- all five DER files and all five adjacent `.license` sidecars;
- `tests/data/i2/README.md`; and
- `tests/data/i2/SHA256SUMS`.

`cargo package --locked --offline -p moq-relay-ietf --allow-dirty
--no-verify` exits 0 and produces a 38-file crate with SHA-256
`c6a9b80481aa4e716781039ee1d3652f88dad4bd5dcaf1787fe2e73155a34436`.
After extraction, all five `include_bytes!` targets resolve inside the package,
exist, and match the inventory. No reference escapes the crate root. This
closes the prior workspace-only fixture blocker and makes the copy acceptable
for a local commit.

The same package command with verification enabled exits 101 for the registry
API gaps described above, not for a missing fixture. It therefore remains a
publication blocker until releases are sequenced and the tarball is verified
again.

## Commands and reproducible results

The relevant read-only commands were equivalent to:

```bash
GIT_OPTIONAL_LOCKS=0 git rev-parse HEAD
GIT_OPTIONAL_LOCKS=0 git diff --cached --quiet
GIT_OPTIONAL_LOCKS=0 git diff --name-status HEAD
GIT_OPTIONAL_LOCKS=0 git ls-files --others --exclude-standard
sha256sum <each-of-the-22-paths>
git diff -- Cargo.lock moq-relay-ietf/Cargo.toml

cargo metadata --locked --offline --no-deps --format-version 1
cargo tree --locked --offline -p moq-relay-ietf -e normal,build
cargo tree --locked --offline -p moq-relay-ietf -e dev \
  --invert rustls@0.23.31
cargo audit --no-fetch --db <fixed-rustsec-db> --file <lock>
cargo deny --metadata-path <locked-metadata> --offline --locked \
  check licenses advisories

reuse lint
gitleaks dir --redact=100 --no-banner --no-color <exact-i2-bundle>
sha256sum -c SHA256SUMS
cargo package --locked --offline -p moq-relay-ietf --list --allow-dirty
cargo package --locked --offline -p moq-relay-ietf \
  --allow-dirty --no-verify
cargo package --locked --offline -p moq-relay-ietf --allow-dirty
```

| Tool | Fixed identity | License / purpose | Result |
|---|---|---|---|
| Rust/Cargo | Rust 1.93.0 image `sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57`; rustc `254b59607`; Cargo `083ac5135` | MIT OR Apache-2.0 toolchain; locked graph/package inspection | Graph and package-list gates completed; full registry verification blocked as documented |
| cargo-audit | 0.22.2; binary `sha256:66f9c8f530950d106c1869ce27ef5a4008bcea53c7716c3ed8117586337ee7d8` | MIT OR Apache-2.0; RustSec audit | I1/I2 sets identical; gate red |
| cargo-deny | 0.20.2; binary `sha256:b329e25933d01c36dd7c47d84ea5716694f9b7caf53a5003d45674703a8ed54a` | MIT OR Apache-2.0; advisory/license policy | Exit 5; policy and advisory gates red |
| REUSE | 5.1.1 image `sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da` | GPL-3.0-or-later tool kept outside artifacts | Exit 0; 209/209 |
| Gitleaks | 8.30.1 image `sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f` | MIT; redacted focal scan | Exact I2 bundle exit 0, no findings; broad baseline match documented |
| Git | 2.53.0 | GPL-2.0-only; read-only inventory | HEAD/stage/inventory confirmed |
| OpenSSL | 3.5.5 | Apache-2.0; DER certificate inspection | Three certificates parsed; synthetic identities only |

All containers mounted the derivative checkout read-only. Cargo homes, targets,
the I1 archive, reports and extracted tarballs were outside the checkout.

## Requirements before any publication review

1. Execute the already documented RustSec remediation batches under
   `TP-RUST-DIST` ownership and `TP-OSS-SC` review. Regenerate one attributable
   lock delta at a time and rerun protocol, provider, license and SBOM gates.
2. Add a reviewed `deny.toml` in a separately authorized change. Begin with no
   advisory ignores. Any future exception must name the exact advisory, owner,
   justification and expiry; the combined licenses/advisories command must pass.
3. Sequence registry releases. Because registry versions are immutable, first
   version and release the I1-capable `moq-native-ietf`, then version and release
   the pending-accept-capable `moq-transport`, then point/resolve
   `moq-relay-ietf` to those compatible releases and verify its clean tarball.
   Each release requires its own license, tests, SBOM, checksums and provenance
   gates. This report does not authorize any of those releases.
4. Repeat `cargo package --locked -p moq-relay-ietf` without
   `--allow-dirty`, compile/test the extracted crate in the approved toolchain,
   and demonstrate that registry dependency resolution no longer removes APIs
   required by I1/I2.
5. Update the publication-boundary inventory, `baseline.env` and verifier only
   after the exact commits and sequential releases are authorized. Do not infer
   remote readiness from this local snapshot.

## Final integrity and activity confirmation

After tool execution, HEAD, the six requested hashes, the 22-path inventory and
the empty stage were unchanged. Repository `git diff --check` exited 0. The
report-specific no-index whitespace check emitted no diagnostic, and the
case-insensitive whole-word scan for unfinished-document markers returned no
match. The two required verdict lines each occur exactly once.

The derivative clone was never checked out, branched, added, committed,
configured, cleaned or edited. No source, manifest, lock, Git metadata, prior
report or remote was modified. No email, message, issue, pull request, tag,
release, publication, push or other remote write was performed.

**LOCAL SUPPLY-CHAIN REREVIEW ONLY / NOT PUBLISHED / NO REMOTE MUTATION**
