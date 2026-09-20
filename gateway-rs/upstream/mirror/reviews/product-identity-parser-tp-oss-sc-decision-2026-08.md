<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# TP-OSS-SC decision: product identity parser and source-publication boundary

Date: 2026-08-28

Scope: independent, read-only supply-chain review

Disposition: **RECOMMEND MINIMUM DIRECT `rustls-webpki` EDGE; SOURCE-ONLY
DISCLOSURE IS CONDITIONAL; RELEASE IS NOT READY**

This is a technical open-source and supply-chain review, not legal advice. It
does not authorize implementation, Batch T, a dependency change, publication,
push, tag, release, product pin, provider change or remote mutation.

## Findings first

### High — identity must be extracted only from the leaf already verified by TLS

The TP-SEC-PKI preflight has not selected a parser. It requires a fail-closed
application policy over the verified peer evidence: inspect only the verified
leaf, accept exactly one valid URI SAN in the approved SPIFFE trust domain and
path grammar, retain only the minimum principal/role, and reject absent,
malformed, foreign, duplicated or ambiguous identity. It expressly forbids an
ad-hoc X.509 parser and retention or logging of certificate DER.

A parsing library must therefore be an extractor, not a second trust engine.
It must not rebuild or relax the chain, reselect trust anchors, accept a leaf
before the rustls verifier succeeds, infer identity from SNI/IP/path, or turn
URI decoding into an authorization decision. The Teremoq layer still owns the
strict SPIFFE policy and redacted errors.

### High — the smallest reviewed delta is the already-resolved webpki parser

The product lock already resolves and the normal feature graph already
activates `rustls-webpki 0.103.15` through `rustls 0.23.43`, QUINN and the
platform verifier. Its public crate name is `webpki`; it exports `Cert` and
`EndEntityCert`, implements parsing from borrowed `CertificateDer`, and
`Cert::valid_uri_names()` returns borrowed URI SAN strings. The method performs
only UTF-8 validation, so it is suitable as the extraction boundary but not as
the SPIFFE policy.

The conservative owner proposal is a direct, exact dependency on that same
package/version, with defaults disabled and no new crypto feature, for example:

```toml
webpki = { package = "rustls-webpki", version = "=0.103.15", default-features = false }
```

This declaration is illustrative, not an implemented change. Because Cargo
features are additive, the final metadata must prove that the direct edge does
not add or remove `ring`, `aws-lc-rs`, `std`, TLS, QUINN or provider features.
The expected semantic lock delta is one new direct root edge and zero package,
version, source, checksum or feature-coordinate changes; the actual owner delta
must be regenerated and reviewed rather than assumed.

### High — parser propio is incompatible with the approved engineering policy

Hand-written ASN.1/DER, SAN or URI extraction would duplicate maintained
security-sensitive code and violate `.cursorrules`. Even a small parser would
create non-canonical length/tag handling, malformed-input, fuzzing, review,
unsafe and maintenance obligations at the identity boundary. It is rejected.

A small Teremoq *policy* function is different and remains required: consume
the library's URI SAN iterator, require exactly one element, parse it with the
already direct `url 2.5.8`, and validate the approved scheme, trust domain,
path segments and role. It must reject userinfo, query, fragment, unexpected
port/authority forms, empty or percent-encoded ambiguous identifiers and every
extra URI SAN. That function must not parse X.509 itself.

### High — commit `89cb179…` is not release-ready while its own lock is vulnerable

The derivative commit
`89cb1798644c32aef06cc625f097cd9acb203417`, tree
`cccd0d60c9ebfe191dca9d73e7ab8b27ae4d4ea5`, retains lock SHA-256
`d6196fd8f31ea3b2cabbdb0e57546810643f344567f3e358ee3c000b3e2b59f5`.
The fixed audit already recorded 16 vulnerability entries and six warning
entries. Several are runtime-relevant crypto/X.509 or network-stack findings,
not merely test tooling. A banner or disclaimer cannot remediate them.

Consequently the snapshot must not be tagged, released, packaged as a binary or
image, recommended for deployment, promoted as production-ready, or used to
claim a clean supply chain. Batch T is mandatory before any such release state,
but T alone is insufficient: its expected eight removals leave eight
vulnerability entries and six warnings for the other owned batches.

### Medium — source-only disclosure can be separated from release readiness

Cargo does not inherit a Git dependency repository's workspace lock. The
consumer resolves the derivative manifests in its own graph. The reviewed
product path simulation retained zero vulnerability entries and two explicit
unmaintained warnings, selecting patched coordinates including
`rustls-webpki 0.103.15`, `aws-lc-rs 1.18.0` and `aws-lc-sys 0.44.0`.

That separation makes a narrowly controlled, non-release source disclosure
technically possible before T if publication of the exact Git object is needed
for an independently audited consumer pin. It does not make the derivative
lock clean. Such disclosure is acceptable only under every condition in
“Source-only disclosure gate” below and an explicit maintainer risk decision.
This report does not make or authorize that decision.

If any condition cannot be met, Batch T and the remaining RustSec batches must
precede publication. Even when the conditions are met, the consumer pin remains
blocked on its own identity/admission implementation and final lock audit.

### Medium — a full SPIFFE library is not justified by the current requirement

No official Rust SPIFFE SDK/source/archive was available in the authorized
local caches or reports. Under the no-network constraint, no exact candidate
could be certified for version, maintainer, license, checksum, MSRV, unsafe,
transitive graph or RustSec status. No such facts are invented here.

The current requirement is only to extract and validate one SPIFFE URI SAN from
a rustls-verified leaf. A full SPIFFE library commonly represents a wider
architectural concern—Workload API, SVID acquisition/rotation, trust bundles or
JWT identity—but no such scope is approved here. Selecting one without a
separate need would enlarge runtime, trust and update surfaces. Reconsider this
class only if Teremoq later requires those capabilities, with an independently
fetched and fixed official candidate review.

### Medium — `x509-parser` is a viable fallback, but activates a broader parser graph

The official cached `x509-parser 0.18.1` package is maintained on the
non-yanked 0.18 line, dual-licensed `MIT OR Apache-2.0`, declares Rust 1.67.1,
forbids unsafe code in its crate, and exposes borrowed X.509/SAN parsing with
`GeneralName::URI`. Its default feature set is empty.

However, using it directly would activate parser dependencies such as
`asn1-rs`, `der-parser`, `nom`, `oid-registry`, `rusticata-macros`, `time` and
support crates. Their coordinates are present in the consumer lock because
`rcgen` records an optional path to `x509-parser`, but the normal inverse tree
does not currently show `x509-parser` as an active product edge. Presence in a
lock is not equivalent to active runtime use.

If the preferred webpki API proves unusable in the real owner implementation,
the only reviewed fallback is exact `x509-parser =0.18.1` with
`default-features = false`. Do not enable `verify` or `verify-aws`: those
features add crypto providers and would duplicate rustls verification.

### Low — policy and notice files need an atomic update even for a zero-coordinate edge

`ISC` is already allowed by `gateway-rs/deny.toml`, crates.io is an allowed
source, and `rustls-webpki 0.103.15` is already included in cargo-deny/audit and
the consumer SBOM graph. A direct dependency still changes responsibility and
must be recorded atomically:

- exact direct edge and purpose in `gateway-rs/DEPENDENCIES.md`;
- exact package/version/checksum/repository/license in the artifact SBOM;
- direct third-party attribution in `THIRD_PARTY_NOTICES.md` or the artifact
  notice inventory, preserving the upstream ISC license text;
- regenerated `Cargo.lock` and semantic comparison, even if bytes do not move;
- cargo-deny license/advisory/source checks with no new ignore; and
- REUSE lint for Teremoq-authored source. REUSE annotations must not relicense
  the registry dependency.

The root Teremoq `NOTICE` does not automatically acquire a new copyright claim
from a non-vendored ISC dependency, but the final distributed artifact notice
bundle must be reviewed. If source is vendored later, its license and copyright
materials must be retained verbatim.

## Frozen inputs

| Evidence | Object |
| --- | --- |
| `.cursorrules` | SHA-256 `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2` |
| TP-OSS-SC product-pin preflight | SHA-256 `6316de0f9d8a7c5f399528b9de84af228f756e1c35851e49ae1749214429a1bb` |
| TP-OSS-SC Batch T decision brief | SHA-256 `3ba24d7069ef4982effa766501836690e5cbf4073c243ffff88b82c9b7935cab` |
| TP-SEC-PKI product-pin preflight | SHA-256 `24daf315d0ec3e0d81cb5da699883dbca62a4b9c4ff5fe7ffb987bc5cfb7d43c` |
| Product `Cargo.toml` | SHA-256 `1caa40574d12ebb4aa9cd03cc30d32f75edd8e9572e6d4876238f491c6e3f3de` |
| Product `Cargo.lock` | SHA-256 `dd6ee5615630d788a351c4e3b395de0851fee41b34177823393d35d23a894316` |
| Product `deny.toml` | SHA-256 `0059c35bc6e588cf99fe4b93025c4c767f3233fcbe67c4ec34a2a02c0212e2a3` |
| Product `DEPENDENCIES.md` | SHA-256 `79c18078e22af74a4d3da682198b958337d0e018ec15d30c0d1617c877b1a535` |
| Root `THIRD_PARTY_NOTICES.md` | SHA-256 `ec648abe05a879304855c67ae372a1f8de953da9d0b5a64dd20bdc77e18fde02` |
| Root `REUSE.toml` | SHA-256 `318d262ce0e385d2a4dec3e5753b4d33bdad092cb2f6e703045dc953f9c7dc07` |
| Derivative commit/tree | `89cb1798644c32aef06cc625f097cd9acb203417` / `cccd0d60c9ebfe191dca9d73e7ab8b27ae4d4ea5` |
| Derivative lock | SHA-256 `d6196fd8f31ea3b2cabbdb0e57546810643f344567f3e358ee3c000b3e2b59f5` |

## Candidate comparison

| Class | Candidate/evidence | Net supply-chain delta | Decision |
| --- | --- | --- | --- |
| Existing X.509 parser | Direct `rustls-webpki =0.103.15` as crate `webpki` | Expected root edge only; package and features already active | **Recommended** |
| General X.509 parser | `x509-parser =0.18.1`, no defaults or verify features | Activates a parser subgraph already recorded but not active normally | Reviewed fallback only |
| Full SPIFFE library | No fixed official Rust candidate locally available | Unknown until separately fetched/reviewed; likely wider trust/runtime scope | Defer; not approved |
| Own parser | Teremoq ASN.1/DER/SAN implementation | New security-critical code and indefinite maintenance | Reject |

## Preferred candidate evidence

The cached registry source for `rustls-webpki 0.103.15` records:

| Property | Evidence |
| --- | --- |
| Official registry checksum | `f3c3cf1d8b1e7d4927e2d154c3fcb02979afb9939629c62cd9048d4f07b60ac2` |
| Repository | `https://github.com/rustls/webpki` |
| Packaged VCS commit | `c14836d8de33c0ad0ac7dcb28fe9aade20831a4d` |
| License | `ISC` |
| License file SHA-256 | `5b698ca13897be3afdb7174256fa1574f8c6892b8bea1a66dd6469d3fe27885a` |
| Declared MSRV | Rust `1.71` |
| Packaged manifest SHA-256 | `828ab5e8a7973ba0eef93956128a41ac135479367ed10ddaeaec44616d395355` |
| URI API source SHA-256 | `cert.rs` `1a4da3c745a72f61e8e95f222fc5847cb4779a4de524f4d6d09ae1d25b27c001` |
| DER conversion source SHA-256 | `end_entity.rs` `dcd6176df075627bbd38881bb1b729462721ecb53e7968d56b116a8532043c42` |
| Unsafe scan | No `unsafe` token in packaged Rust source; this is not a transitive proof |
| Local index state | `0.103.15` present, non-yanked, latest cached stable 0.103 record |

Rust 1.71 is below the approved Rust 1.93 toolchain. The fixed RustSec files
mark the 0.103 line patched at `>=0.103.13` for the newest applicable listed
finding; 0.103.15 is above all locally listed fixed minima. The prior fixed-DB
audit of the product lock returned zero vulnerability entries. This is evidence
against that frozen database, not a guarantee against later advisories.

The feature tree confirms that this exact coordinate already has `std`,
`ring` and `aws-lc-rs` enabled through existing product/upstream consumers.
The identity edge must not request either crypto feature. A future provider
simplification is a separate high-impact decision and must not be smuggled into
the parser change.

## Fallback candidate evidence

The cached registry source for `x509-parser 0.18.1` records:

| Property | Evidence |
| --- | --- |
| Official registry checksum | `d43b0f71ce057da06bc0851b23ee24f3f86190b07203dd8f567d0b706a185202` |
| Repository | `https://github.com/rusticata/x509-parser.git` |
| Packaged VCS commit | `33b15d2db5a19b15c17bb15fa57b08691316ee95` |
| License | `MIT OR Apache-2.0` |
| Apache license SHA-256 | `a60eea817514531668d7e00765731449fe14d059d3249e0bc93b36de45f759f2` |
| MIT license SHA-256 | `a5c61b93b6ee1d104af9920cf020ff3c7efe818e31fe562c72261847a728f513` |
| Declared MSRV | Rust `1.67.1` |
| Packaged manifest SHA-256 | `59b5f4f148244b4a7ad53750338abbc2c065ebfc4410b6931e62ced3eac57823` |
| Crate root SHA-256 | `c5a50594cf307e041b499b1c5a45da028e7a99487b71b7b715adb5ec36b9dc72` |
| Unsafe policy | `#![forbid(unsafe_code)]` |
| Local index state | `0.18.1` present and non-yanked after 0.18.0/0.17.0 |

No `x509-parser` advisory file exists in the fixed local RustSec database. That
is a bounded database result, not proof that the parser or every transitive
crate is defect-free. If selected, all activated dependencies require a fresh
normal/build/dev/all-features metadata, cargo-deny and audit comparison.

## Required identity behavior

The owner implementation and independent PKI review must demonstrate:

1. the evidence originates only after rustls successfully authenticates the
   peer and identifies the leaf deterministically;
2. `webpki` parsing borrows the leaf DER and the application retains no DER,
   certificate chain, subject string or raw SAN after the decision;
3. exactly one URI SAN exists; zero, two or more all fail closed;
4. the URI parser accepts only the approved `spiffe` scheme, trust domain,
   canonical absolute path and explicitly enumerated gateway role;
5. userinfo, query, fragment, port, unexpected host form, empty segment,
   dot-segment, invalid percent encoding and ambiguous normalization fail;
6. DNS SAN, CN, source IP, SNI, URL path and self-declared metadata never
   become a fallback identity;
7. errors, tracing and metrics expose only constant reason codes and counts,
   never URI, DER, subject, peer address or customer data;
8. the authorization principal has a bounded lifetime and is erased when the
   session ends; and
9. negative fixtures cover malformed DER/SAN, invalid UTF-8 URI, foreign trust
   domain, duplicate/multiple URI SAN and valid-chain/wrong-identity cases.

## Parser-change supply-chain gate

Before accepting the future owner delta:

- bind clean product and derivative commits; require DCO on every new commit;
- add only the exact direct webpki edge and identity policy/tests; stop on any
  unrelated source, manifest, feature, provider, protocol or lock movement;
- regenerate the lock with Rust/Cargo 1.93 and compare every package record,
  source, checksum and feature set;
- run `cargo metadata --locked`, normal/build/dev/all-feature inverse trees for
  webpki, rustls, ring and AWS-LC, and prove zero new provider activation;
- run cargo-deny license/advisory/source/bans with no new ignore or wildcard;
- run cargo-audit against both the fixed DB and an authorized current pinned DB;
- run REUSE, artifact-specific SBOM/notice generation, redacted Gitleaks,
  package list/extraction and the full mTLS identity negative matrix;
- preserve exact versioning; no Git parser dependency, floating semver, fork,
  vendoring or patched source; and
- update `DEPENDENCIES.md`, third-party inventory and SBOM atomically.

Stop if the direct edge changes the crypto provider graph, requires unsafe,
pulls a second TLS/QUIC stack, creates an advisory, weakens URI rejection, or
cannot distinguish the verified leaf from unverified peer input.

## Source-only disclosure gate for `89cb179…`

Publishing the source object before T is a risk exception, not the preferred
release state. Every item below is required for it to be technically
responsible:

1. publish only an immutable, non-release source ref to the exact commit/tree;
   no tag `v*`, GitHub Release, package, binary, OCI image, model or SBOM claim;
2. do not make it the advertised stable/default production line or describe it
   as deployable, secure, complete, supported, SLA-backed or release-ready;
3. place a prominent public security status adjacent to the repository entry
   point, before or atomically with exposure, stating the exact fixed audit DB,
   16 vulnerability entries, six warnings, affected package classes and owned
   remediation batches without publishing secrets or exploit material;
4. state explicitly that dependency-repository `Cargo.lock` is not inherited by
   Git consumers, but any direct checkout/build of the derivative remains
   subject to its own vulnerable lock;
5. keep Private Vulnerability Reporting, Secret Scanning, Push Protection,
   read-only default workflow token, no workflow PR approval and full-SHA
   action policy enabled; do not substitute public issues for vulnerability
   reporting;
6. protect the exact ref against deletion/force-push according to the reviewed
   safe ruleset rollout, retain DCO evidence and verify remote commit/tree after
   the authorized write;
7. publish the remediation plan and named owners/review gates; do not add
   RustSec ignores or suppressions to obtain green status;
8. before any consumer pin, independently regenerate and audit the consumer
   lock, demonstrate zero new vulnerability entries, preserve the two explicit
   warnings, update dependency provenance/NOTICE/SBOM and verify the exact Git
   object;
9. keep the product identity/admission change blocked until TP-SEC-PKI and
   TP-PLATFORM-CHAOS gates pass; the source ref alone proves no product policy;
10. withdraw the source-ready claim if a current pinned DB adds a new finding,
    the remote object diverges, protections are absent, or the disclosure
    cannot remain clearly non-release.

The preferred ordering remains to complete T and the remaining remediation
batches before broad public promotion. T need not be a hard predecessor to the
narrow source-only exception because it does not make the derivative clean and
the audited consumer resolves its own patched graph. It is a hard predecessor,
together with the other vulnerability batches, to any release or production
claim.

## Reproducible evidence commands

Commands used were read-only and local:

```bash
sha256sum .cursorrules \
  gateway-rs/Cargo.toml gateway-rs/Cargo.lock \
  gateway-rs/deny.toml gateway-rs/DEPENDENCIES.md \
  THIRD_PARTY_NOTICES.md REUSE.toml

rg -n 'rustls|webpki|x509|url\s*=' gateway-rs/Cargo.toml
rg -n 'pub use .*Cert|valid_uri_names|TryFrom.*CertificateDer' \
  "$CACHED_WEBPKI_SOURCE/src"
rg -n '\bunsafe\b|unsafe_code' \
  "$CACHED_WEBPKI_SOURCE/src" "$CACHED_X509_PARSER_SOURCE/src"

cargo tree --locked --offline -e features \
  -i rustls-webpki@0.103.15
rg -l 'rustls-webpki|x509-parser' "$FIXED_RUSTSEC_DB/crates"
```

The feature-tree command ran in the already-present official Rust 1.93.0 image
`sha256:d0a4aa3ca2e1088ac0c81690914a0d810f2eee188197034edf366ed010a2b382`,
with network disabled, product and Cargo cache mounted read-only, and a
container-local disposable target. An initial invocation without fixed
`RUSTUP_TOOLCHAIN=1.93.0` attempted a rustup channel check and failed because
network was disabled; the corrected invocation performed no download and
succeeded. No result from the failed invocation is treated as evidence.

The fixed RustSec working copy advertises official origin
`https://github.com/RustSec/advisory-db.git` and ref
`a7bfe16948bf6f3ee25bdee4822209f87da21b80`; its Git commit object is not
present in that read-only cache, so this review does not newly claim a clean Git
tree. Advisory-file contents and the prior fixed-DB cargo-audit evidence remain
usable. Batch T's separate decision is bound to DB commit
`6420e39260b3d771b049954cf5d52b57e2118da4` as recorded in its memo.

## Limitations

- No network, web search, download, install, resolver change, build, test,
  manifest edit, lock edit, Git write or remote query was performed.
- No full Rust SPIFFE SDK candidate was locally available; that class is
  unverified rather than rejected on invented metadata.
- The proposed direct webpki edge was not implemented or resolved. Zero package
  movement is an evidence-based expectation that still requires review of the
  real delta.
- Unsafe scanning covered the two packaged parser crates, not every transitive
  crate or native provider.
- Maintenance evidence is bounded to official cached registry records,
  non-yanked release sequence, packaged repository/VCS metadata and current
  product use; no current remote maintainer activity is claimed.
- This report does not supersede TP-SEC-PKI's identity decision, Batch T's
  high-impact provider authorization, or release governance.

## Decision

**Identity parser:** recommend an exact direct dependency on the already active
`rustls-webpki 0.103.15`, used only to extract URI SAN from the rustls-verified
leaf. Keep `x509-parser 0.18.1` as the reviewed no-verify fallback. Defer a full
SPIFFE SDK until Workload API/SVID/bundle scope exists. Reject a custom X.509
parser.

**Derivative publication:** `89cb179…` is **NOT RELEASE READY**. A narrowly
controlled source-only disclosure may precede T only through the explicit risk
gate above; it is neither publication authorization nor a clean-supply-chain
claim. Batch T plus all remaining vulnerability batches, deny/SBOM/release
gates and independent verification must precede any tag, artifact, deployment
recommendation or production claim.

**DECISION REVIEW ONLY / NO IMPLEMENTATION / NO PUBLICATION / NO REMOTE MUTATION**
