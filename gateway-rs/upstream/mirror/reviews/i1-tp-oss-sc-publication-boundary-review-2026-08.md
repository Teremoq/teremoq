# TP-OSS-SC review: I1 publication boundary and supply chain

- Review date: 2026-08-27
- Reviewer: `TP-OSS-SC`
- Owner under review: Task 05 / `TP-RUST-DIST`
- Identity/privacy review: `TP-SEC-PKI`
- Read-only clone: `/home/jimbomilk/moq-rs-teremoq-work`
- Exact commit: `05b41127ecbd48de4c59fe1626c43b1e423c33a9`
- Approved baseline: `bf87128affd316463e5dcc7599a45001f222b6de`
- Scope: publication boundary and supply chain only; no code review ownership

This is a technical open-source and supply-chain review, not legal advice.

## Verdict

**APPROVE FOR LOCAL RETENTION**

**READY FOR PUBLICATION-BOUNDARY UPDATE**

The exact I1 commit has a reproducible Git boundary, compatible dual-license
metadata, complete REUSE coverage, a valid DCO trailer and no credible secret,
customer identity, productive namespace or operational-data finding. It may be
entered into a future local exact-ref inventory after Master acceptance of this
review.

This verdict is not authorization to change `baseline.env`, the verifier or
the remote. It is not authorization to push the commit or branch. An eventual
push requires a separate explicit authorization after the exact inventory and
fail-closed verifier changes described below have been implemented and reviewed.

## Review isolation

The clone was treated as read-only. All Git reads used optional locks disabled.
The reviewed source came from `git archive` of the exact commit into disposable
directories, not from the checkout's working tree. No checkout, branch, add,
commit, config, clean or file modification was performed in the clone.

At review time `HEAD` resolved to the I1 commit while the checkout's symbolic
branch name was `teremoq/i2-required-auth-bf87128`. No I2 working-tree content
was inspected or used. The local ref
`refs/heads/teremoq/i1-peer-evidence-bf87128` independently resolved to the
exact I1 commit and had no upstream/tracking ref.

The only persistent output of this review is this file. Existing I1, I2 and
Task 04 reports or artifacts were not edited.

## Commit identity, lineage and DCO

| Property | Verified value |
|---|---|
| Commit | `05b41127ecbd48de4c59fe1626c43b1e423c33a9` |
| Sole parent | `bf87128affd316463e5dcc7599a45001f222b6de` |
| Parent count | 1 |
| Tree | `eca64a72e148482fb82b963edc2f2c9af28803f2` |
| Subject | `feat(native-ietf): expose verified peer evidence` |
| Author | `Jose María <12586102+jimbomilk@users.noreply.github.com>` |
| Author time | `2026-08-27T21:07:26+02:00` |
| Committer | `Jose María <12586102+jimbomilk@users.noreply.github.com>` |
| Committer time | `2026-08-27T21:07:26+02:00` |
| DCO | one matching `Signed-off-by` trailer |
| Cryptographic commit signature | absent; not required by the current policy |

The author, committer and DCO identity match exactly. The public noreply
identity appears only as required Git provenance; it is not embedded in the I1
tree, certificates or test namespaces.

## Exact 17-path boundary

An independently sorted `git diff-tree` path set matched the expected list
exactly. Its newline-delimited SHA-256 is
`9f81fe7853d13bf3ad93446e9815862a914747106afb4953de7abb6f9abdec77`.

1. `moq-native-ietf/src/quic.rs`
2. `moq-native-ietf/tests/data/README.md`
3. `moq-native-ietf/tests/data/ca.cert.der`
4. `moq-native-ietf/tests/data/ca.cert.der.license`
5. `moq-native-ietf/tests/data/client-a.cert.der`
6. `moq-native-ietf/tests/data/client-a.cert.der.license`
7. `moq-native-ietf/tests/data/client-a.key.der`
8. `moq-native-ietf/tests/data/client-a.key.der.license`
9. `moq-native-ietf/tests/data/client-b.cert.der`
10. `moq-native-ietf/tests/data/client-b.cert.der.license`
11. `moq-native-ietf/tests/data/client-b.key.der`
12. `moq-native-ietf/tests/data/client-b.key.der.license`
13. `moq-native-ietf/tests/data/server.cert.der`
14. `moq-native-ietf/tests/data/server.cert.der.license`
15. `moq-native-ietf/tests/data/server.key.der`
16. `moq-native-ietf/tests/data/server.key.der.license`
17. `moq-native-ietf/tests/peer_evidence.rs`

All entries use Git mode `100644`. The delta is 859 insertions and 85 deletions.
`git diff --check` passed for the baseline-to-I1 commit range.

## Protected dependency, license and protocol boundary

The following baseline and I1 Git objects are byte-identical:

| Protected object | Git object |
|---|---|
| root `Cargo.toml` | `3fa211da7d06f6d02715d2fbf479b2bb5c4c4f56` |
| `Cargo.lock` | `bffb8f40a814b333c43c5a28c2cab074f32cd8fe` |
| root `REUSE.toml` | `39f45dc398c58993c3eab21d62c89d39b8b6fcd6` |
| `LICENSES/Apache-2.0.txt` | `55b366195e45a27ba1681037db12a9efe3cb3e6f` |
| `LICENSES/MIT.txt` | `a6443463f9756ac500af0f4b62ae276a096429b8` |
| `moq-native-ietf/Cargo.toml` | `56c7769c01889e96ef27597f77a50ce32375f5ce` |
| complete `moq-transport` tree | `217aba056a589e9730e5b1ed0ed09ee5b69d5e3c` |
| complete `moq-relay-ietf` tree | `a5ba97856468908be23de7aa78e3e4446c89626a` |
| `moq-transport/src/setup/mod.rs` | `6f673df7b6f022188c7ed0eb0d31abf0c7cbcbde` |

Therefore I1 changes no manifest, lockfile, dependency, Cargo feature, upstream
license, root REUSE policy, other crate or active product pin. No `unsafe` was
added. The path set contains no setup/wire file. Existing ALPN constants are
referenced rather than replaced, and the added regression asserts raw QUIC
`moqt-16`; the draft-16 setup object itself is unchanged. No Track, Group,
Object or serialized MoQT implementation changed.

The baseline and I1 trees contain no `NOTICE` or `COPYRIGHT` path to preserve.
Both upstream license texts and the existing Cloudflare/Luke Curley/Mike
English contributor header in `quic.rs` are retained. The source, new test and
fixture README all declare `MIT OR Apache-2.0`; the new test and README identify
`2026 Teremoq contributors`. This is compatible with the approved license for
new contributions in the controlled derivative and does not relicense upstream
material.

## SPDX and REUSE

REUSE 5.1.1 ran against a full archive of the exact I1 tree with the previously
approved official image pinned by digest. It passed REUSE Specification 3.3:

- 199/199 files had copyright information;
- 199/199 files had license information;
- zero bad, deprecated, missing or unused licenses; and
- only `MIT` and `Apache-2.0` were used.

Targeted verification also confirmed:

- `moq-native-ietf/src/quic.rs`: `MIT OR Apache-2.0`, existing upstream
  copyright retained;
- `moq-native-ietf/tests/peer_evidence.rs`: `2026 Teremoq contributors`,
  `MIT OR Apache-2.0`;
- fixture `README.md`: equivalent HTML SPDX declarations;
- seven DER binaries and exactly seven adjacent `.license` sidecars;
- every sidecar declares `2026 Teremoq contributors` and
  `MIT OR Apache-2.0`; and
- all seven sidecars are byte-identical, with SHA-256
  `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0`.

## Synthetic certificate and key provenance

The fixture README identifies OpenSSL 3.5.5 as the one-time generator, states
that the material is deliberately public and non-production, prohibits reuse,
records P-256/SHA-256 and provides an SHA-256 inventory for all seven DER files.
The inventory matched the commit bytes exactly:

| Fixture | SHA-256 |
|---|---|
| `ca.cert.der` | `ea33add88bed4676c51baa4f8da9df33d04e99cecf7d0846a756e23b0f66461b` |
| `client-a.cert.der` | `e75cc0d4f020259b4b86d5b722762cbd7aba9b219a8d3234a8b5c5af3e214eb2` |
| `client-a.key.der` | `416263df93ab7f326f2d82f198fcdf9da850a55e5564ca964c3eceb7976bd288` |
| `client-b.cert.der` | `f937ec8405325952b04b09a132b2070222e788b9d69be5e14d50dc0fa0e0c0d3` |
| `client-b.key.der` | `67269f66b312230be8eccf707bf86f5729f15dd9e002f5f6f329388408eda67a` |
| `server.cert.der` | `053a80b61f971f0601d83305ec6139fbcd7ed2f78c541078ac6e68a7e6da16bc` |
| `server.key.der` | `1d02d7ec66886fc2bb2cc3104851e1c182d7980e946d8df2e8f0f3ae33c30436` |

OpenSSL 3.5.5 independently parsed all four certificates and validated all
three unencrypted private keys. Each key's derived public key matched its
certificate. All certificates use `prime256v1` and ECDSA-with-SHA-256.

| Certificate | Subject / issuer | Serial | Validity (UTC) | SAN / purpose |
|---|---|---|---|---|
| CA | `CN=moq-native-ietf-test-ca` / self | `62FA5713AEE984925983F19339371B1DDA15A933` | 2026-08-26 21:23:11 to 2036-08-23 21:23:11 | no SAN; CA true |
| client A | `CN=moq-native-ietf-client-a` / test CA | `07D1` | 2026-08-26 21:23:11 to 2036-08-23 21:23:11 | no SAN; client authentication |
| client B | `CN=moq-native-ietf-client-b` / test CA | `07D2` | 2026-08-26 21:23:11 to 2036-08-23 21:23:11 | no SAN; client authentication |
| server | `CN=moq-native-ietf-server` / test CA | `03E9` | 2026-08-26 21:23:11 to 2036-08-23 21:23:11 | `localhost`, `127.0.0.1`; server authentication |

The names are generic test roles, the serials do not encode customer data, and
the only SAN values are local. There is no SPIFFE URI, Teremoq deployment
identity, external IP, customer name or productive namespace.

The exact committed bytes are reproducible through their Git objects and
SHA-256 inventory. The README does not include the complete generation command,
OpenSSL configuration or a generator-container digest, so deterministic
regeneration of the same random keys is neither claimed nor required for the
fixed-fixture tests. Recording that recipe and a pinned generation environment
would improve future fixture replacement provenance.

## Redacted secret and publication-boundary scan

Gitleaks 8.30.1 ran with `--redact=100` using the required local image digest:

```text
zricethezav/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f
```

Results:

| Input | Result |
|---|---|
| exact `moq-native-ietf` crate at I1 | 0 findings; about 73 KB scanned |
| exact baseline-to-I1 binary patch | 0 findings; about 46 KB scanned |
| full exact I1 commit archive | 1 finding; about 1.58 MB scanned |

The full-archive finding is the known `private-key` rule at
`moq-relay-ietf/src/tls.rs:115`. Redacted inspection classified it as a
comment-only PEM delimiter. Its Git blob
`f391ae7b21c976922d5b6543704866b7cfb2c27b` is identical in baseline and I1;
it is not secret material and is not part of the I1 delta.

Complementary text and X.509 checks found:

- no `/home/`, `/Users/` or Windows user path;
- no local username in the tree;
- no SPIFFE URI or productive namespace;
- no password, token, API key, cookie, credential assignment or authenticated
  URL;
- no customer data, operational evidence or trust material from a deployment;
- no external IP in added text; the only two added IP literals are loopback;
- only unauthenticated local `moqt://localhost/` and
  `https://localhost/` test URLs; and
- no PEM marker or key body in text.

The three `.key.der` files are actual unencrypted private-key objects, but they
are deliberately published synthetic test fixtures rather than undisclosed
secrets. Gitleaks not flagging binary DER does not change that classification.

## Findings by severity

### Critical

None.

### High

None.

### Medium

None.

### Low: deliberate publication of reusable synthetic private keys

Three valid unencrypted private keys are intentionally included. Public test
keys are not productive secrets, but they can trigger downstream scanners or
be copied by an operator who ignores the README. Existing mitigations are clear
synthetic names, localhost-only server SANs, a prominent non-production warning,
fixed hashes, individual REUSE sidecars and focused test-only paths.

Residual obligation: never add a broad scanner exclusion for DER or key paths.
If a scanner requires suppression, bind it narrowly to the seven reviewed blob
hashes and document that the exception expires when fixtures change. These keys
must never enter trust stores, deployments, examples presented as production,
release credentials or customer configuration.

### Low: generation recipe is not complete

The generator and version, cryptographic profile, validity window and exact
output hashes are recorded, which is sufficient to reproduce and verify the
committed byte set. Exact OpenSSL commands/configuration and a generator image
digest are absent. This does not make the fixed bytes non-reproducible, but it
limits independent audit of how replacement fixtures would be generated.

Before replacing or regenerating the fixtures, add the exact generation and
verification recipe using a pinned official environment, without adding that
tool to runtime dependencies. Do not claim deterministic regeneration of
random private keys.

### Informational: inherited Gitleaks pattern

The one full-tree Gitleaks match is an unchanged upstream comment, not a secret
and not an I1 addition. It requires no history rewrite or code change.

### Informational: commit is not cryptographically signed

The DCO gate passes. Current policy does not require a cryptographic commit
signature, so the absent signature is recorded but is not a blocker.

## Exact publication-boundary update required before an eventual push

Do not reuse the current baseline-only verifier unchanged. After Master accepts
this review, and before any separately authorized push, prepare and review a
single local governance change with all of the following.

### `baseline.env`

Keep the existing baseline, upstream, tree and license-object values. Add exact
I1 values equivalent to:

```text
MOQ_I1_REF=refs/heads/teremoq/i1-peer-evidence-bf87128
MOQ_I1_REV=05b41127ecbd48de4c59fe1626c43b1e423c33a9
MOQ_I1_PARENT=bf87128affd316463e5dcc7599a45001f222b6de
MOQ_I1_TREE=eca64a72e148482fb82b963edc2f2c9af28803f2
MOQ_I1_PATHSET_SHA256=9f81fe7853d13bf3ad93446e9815862a914747106afb4953de7abb6f9abdec77
```

The expected head inventory must then be exactly these two pairs:

```text
refs/heads/teremoq/baseline-draft16-bf87128 -> bf87128affd316463e5dcc7599a45001f222b6de
refs/heads/teremoq/i1-peer-evidence-bf87128 -> 05b41127ecbd48de4c59fe1626c43b1e423c33a9
```

No tag is allowed. No prefix, wildcard, minimum count, moving branch or
abbreviated SHA is acceptable.

### Live verifier

Extend the strict configuration parser to allow and require the five I1 keys,
reject duplicates/unknown keys and validate the full ref plus 40-hex objects.
Replace the baseline-only `branch_count == 1` test with equality of the complete
remote head-name/SHA map against the two expected pairs. Preserve `tag_count ==
0`, the baseline default branch and every existing repository-control gate.

For the I1 ref, require:

1. exact commit, sole parent and tree;
2. the sorted 17-path set and its SHA-256 above;
3. no path outside `moq-native-ietf`;
4. unchanged root/crate manifests, lockfile, REUSE and upstream license blobs;
5. unchanged `moq-transport`, `moq-relay-ietf` and setup/wire objects; and
6. the I1 ref absent or mismatched must fail closed.

Do not relax the verifier merely so it passes before the branch exists. The
updated live verifier is expected to report the I1 ref absent before an
authorized push, and to pass only after a later authorized non-force push plus
post-push verification.

### Verifier test inventory and mirror documentation

Update fixture tests to cover the exact two-ref positive state and negative
cases for missing I1, moved I1, wrong parent, wrong tree, wrong path set, an
extra branch, any tag and changed license/REUSE objects. Keep the baseline-only
remote snapshot as historical evidence. Update the current mirror README and
patch-series inventory to bind I1 to the reviewed full commit only when the
same governance change is authorized; do not rewrite earlier reports.

None of these future changes was made by this review.

## Tools, versions, pins and limitations

| Tool | Version or immutable identity | License | Purpose |
|---|---|---|---|
| Git | 2.53.0 | GPL-2.0-only | Read-only commit/object/diff evidence and archives |
| Gitleaks | 8.30.1; image digest `sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f` | MIT | Redacted crate, patch and exact-tree scans |
| REUSE | 5.1.1; official image digest `sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da` | GPL-3.0-or-later | SPDX/REUSE 3.3 gate |
| OpenSSL | 3.5.5 | Apache-2.0 | Read-only DER/X.509/key and pair verification |
| GitHub CLI/API | gh 2.54.0 | MIT | Selected read-only remote state |
| Docker Engine | 28.3.3 | Apache-2.0 | Execute already-present pinned tool images |

The local baseline configuration SHA-256 was
`17ad62456ff25bc462230d9ea7e96a727149cc580f3037f93cc9256c1d651a3d`;
the current live verifier SHA-256 was
`f10750693b91f8d9b80882621a5759113dd7c9f955eaac4fb12420bc82d9f382`.
The exact baseline-to-I1 binary patch SHA-256 was
`ad88296d0f13e958ff3add0da793391ca1ef023feafb0badf09407a7cabad8d3`.

This review did not compile or retest Rust behavior because that belongs to
`TP-RUST-DIST` and was already recorded in the I1 report. It independently
verified only the publication and supply-chain boundary. Gitleaks and pattern
scans are evidence, not proof that an undiscoverable secret cannot exist.

## Read-only remote state

The live baseline verifier exited 0. Read-only GitHub API evidence showed:

- repository `Teremoq/moq-rs-teremoq`: public, independent, `fork=false`;
- default and sole remote branch:
  `teremoq/baseline-draft16-bf87128` at the exact baseline;
- baseline commit present;
- zero tags;
- I1 branch absent; and
- I1 commit not resolvable remotely.

This state confirms non-publication at review time. It is not authorization for
future publication and must not be cited as one.

## Activity confirmation

No code, manifest, lockfile, fixture, I1/I2 report, Task 04 artifact,
`baseline.env` or verifier was modified. No checkout, branch, Git configuration,
stage, commit, clean, push, pull request, issue, tag, release, publication,
external communication or GitHub mutation was performed.

**LOCAL SUPPLY-CHAIN REVIEW ONLY / NOT PUBLISHED / NO REMOTE MUTATION**
