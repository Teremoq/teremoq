<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# TP-OSS-SC rereview of the corrected local I1/I2 + C1/C2 source merge

Date: 2026-08-28 09:45:36 UTC

Profile: `TP-OSS-SC: Open Source & Software Supply Chain Engineer`

Scope: independent, read-only license, provenance, supply-chain and
reproducibility review of the uncommitted staged snapshot in
`/home/jimbomilk/moq-rs-teremoq-integration-work`.

State: **LOCAL STAGED SNAPSHOT ONLY / NOT COMMITTED / NOT PUBLISHED**

## Findings first

### HIGH / CRITICAL

None found within this review boundary.

### MEDIUM

None found within this review boundary.

### LOW — public synthetic private-key fixture remains intentionally distributable

`moq-relay-ietf/tests/data/c2/server.key.pem:1` is detected by Gitleaks as a
private key. This is the expected, redacted finding. It is a deterministic PEM
encoding of the already-public synthetic C1 test key, not production trust
material. The limitation and prohibition on deployed use are explicit at
`moq-relay-ietf/tests/data/c2/README.md:8-15`; its direct decoded payload is
byte-identical to the immutable C1 DER key. The residual risk is accidental
reuse or recurring secret-scanner false positives. Publication review must
continue to classify this exact path and hash explicitly; the fixture must
never be promoted into a deployed trust store.

### INFO — the five paths added by the correction preserve the upstream boundary

The correction adds these five paths to the staged pathset relative to the
previous reviewed tree; it does not add five new files to the repository:

| Path | Staged SHA-256 | License/copyright evidence |
| --- | --- | --- |
| `moq-relay-ietf/src/api.rs` | `aca75de5ecdc7e6eebca0064c72389afaa6020e24bf0e355f2c5fcdf2a1cfbda` | lines 1-2 retain upstream copyright and `MIT OR Apache-2.0` |
| `moq-relay-ietf/src/consumer.rs` | `311807c1b982ab9f72420e6c7fb5e4f4ce0b9bf7f1a8593626d92a1438dd7916` | lines 1-2 retain upstream copyright and `MIT OR Apache-2.0` |
| `moq-relay-ietf/src/local.rs` | `ecacbe786afa98fbc75afbdf8cde57571a43b818662b946ee43db5c593ac2395` | lines 1-2 retain upstream copyright and `MIT OR Apache-2.0` |
| `moq-relay-ietf/src/producer.rs` | `23b8ac2ea42987414aebc1f4b21c9eaf5dae182335fba00c3a2aadfd75238960` | lines 1-2 retain upstream copyright and `MIT OR Apache-2.0` |
| `moq-relay-ietf/src/session.rs` | `9be32af612ae4cf7a3e3868432141adf17796eb07405d9bdb7d618570a36c60e` | lines 1-2 retain upstream copyright and `MIT OR Apache-2.0` |

The complete correction from staged tree `985f7f4a...` to `d7f0c67f...`
modifies nine Rust paths: the five above plus `i2_tests.rs`, `relay.rs`,
`remote.rs` and `upstream_namespaces.rs`. It adds no manifest, crate, fixture,
license or generated artifact. Its binary patch SHA-256 is
`8701c84aeef7d827f087719d8a15d4d00a356930567f06789000d5456e1d635d`;
its nine-path list SHA-256 is
`221263bb27900927e56aa8dda901a73cbeedb2e2b8fce64a080f7f57f9a0f037`.
Gitleaks reports zero findings over those nine exact source files.

### INFO — inherited compilation and formatting blockers are not merge findings

The unchanged protected file `moq-transport/src/serve/tracks.rs` retains
SHA-256 `a8303c94925707a0a257923725bf84e4ec730b07d6bb2330fda5329b632fe0b7`.
The known `E0308` at line 501 and the two full-workspace rustfmt diffs at
`moq-transport/src/serve/subgroup.rs:934` and
`moq-transport/src/serve/tracks.rs:304` are classified exactly as
`BLOCKED_BY_BASELINE_E0308`. A pinned Rust 1.93.0 `cargo fmt --all -- --check`
reproduced only those two protected diffs; focal rustfmt over all nine
corrected sources passed. These inherited results are neither a failure nor an
approval of this staged merge.

### Tooling limitation — full dependency metadata could not be rematerialized

`cargo metadata --locked --offline --no-deps` passed for nine workspace
packages, all declaring `MIT OR Apache-2.0`, with output SHA-256
`9506420f2a7fd10f307a9936e2ce33a2fcbb6d66fe55add5cf933e15d81160d8`.
The full dependency form stopped because `android-tzdata 0.1.1` was not
materialized in the available read-only cache. Network use and installation
were forbidden, so this was not bypassed. No claim of a freshly resolved full
graph is made. The narrower no-change conclusion is independently supported
by every manifest, `Cargo.lock`, features and protected protocol artifacts
being byte-identical to I2, and by successful offline package lists using the
already-approved read-only cache volumes.

## Verdict

**APPROVE**

This verdict applies only to retaining and creating the exact local merge
commit from the frozen staged tree below. It does not authorize publication,
push, tags, Q, U1, T, product-pin changes or any remote action. A future merge
commit remains conditional on exactly two parents in order (I2 then C2), the
reviewed tree unchanged and a valid DCO `Signed-off-by` for its author.

## Frozen identity and preflight

| Item | Required and reproduced value |
| --- | --- |
| `.cursorrules` SHA-256 | `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2` |
| `.cursorrules` length | 488 lines; read completely |
| Branch | `teremoq/integration-draft16-bf87128-local` |
| Tracking branch | none |
| `HEAD` / proposed first parent | `59d9a8601885ef934cae29d89876abb7c7f73e89` |
| `MERGE_HEAD` / proposed second parent | `b4ee3b68df58bbb6e7b865c2898d3f46ffbb7fd1` |
| Staged tree | `d7f0c67f4c134adc4250885f6bc031aa2efcead6` |
| Staged path count | 31 |
| Pathset SHA-256 | `5ca569098581750132c29f1e9b50d5bfefd52eee2f7d347811f27697109a7388` |
| Porcelain status-z SHA-256 | `b35e9c4f2ce80d4abd8b08e72fa8fa31b3370ad1517001ddf26cf11fc15fe426` |
| Unmerged entries | 0 |
| Unstaged paths | 0 |
| Owner report SHA-256 | `531aa1e13a34a9999327c0708dbf7eab15b8597a14b9d5f0d57bb6b1fca318a7` |

`git diff-index --cached --quiet d7f0c67f... --` confirms that the index is
exactly the frozen tree without invoking the index-writing `git write-tree`.
The owner inventory contains 31 entries and an independent comparison found
zero path or content-hash mismatches.

The parents themselves each contain exactly one `Signed-off-by` line matching
their author email. The still-uncreated merge commit has no DCO evidence yet;
that is a post-condition, not inferred from the parents.

## Exact 31-path staged inventory

| Path | SHA-256 |
| --- | --- |
| `moq-native-ietf/src/quic.rs` | `92e94e527dce998543b050e1d4af0012b6c18df2b4e32c068ad9ebb46594934d` |
| `moq-native-ietf/src/quic_c1_tests.rs` | `610d8430315460db1652d99067002231d7ca4f2eaa48e8de2221966fa2cee8a9` |
| `moq-native-ietf/tests/data/c1/README.md` | `717d3219aa203034fde416b6e17f291e21ab9344a15e258a92aaaf3812a14e10` |
| `moq-native-ietf/tests/data/c1/SHA256SUMS` | `ba0f134515bdca4413dc9658d4016343a2180fd6c8f624e7e1b779f013696d64` |
| `moq-native-ietf/tests/data/c1/ca.cert.der` | `ea33add88bed4676c51baa4f8da9df33d04e99cecf7d0846a756e23b0f66461b` |
| `moq-native-ietf/tests/data/c1/ca.cert.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-native-ietf/tests/data/c1/server.cert.der` | `053a80b61f971f0601d83305ec6139fbcd7ed2f78c541078ac6e68a7e6da16bc` |
| `moq-native-ietf/tests/data/c1/server.cert.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-native-ietf/tests/data/c1/server.key.der` | `1d02d7ec66886fc2bb2cc3104851e1c182d7980e946d8df2e8f0f3ae33c30436` |
| `moq-native-ietf/tests/data/c1/server.key.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-relay-ietf/src/api.rs` | `aca75de5ecdc7e6eebca0064c72389afaa6020e24bf0e355f2c5fcdf2a1cfbda` |
| `moq-relay-ietf/src/consumer.rs` | `311807c1b982ab9f72420e6c7fb5e4f4ce0b9bf7f1a8593626d92a1438dd7916` |
| `moq-relay-ietf/src/i2_tests.rs` | `c69ffa190430cd8662f249c461be94fd74e10d9ceabe188b028c91e1f37413ec` |
| `moq-relay-ietf/src/lib.rs` | `833b732c738650c0ed6297c7094bdb8309da5953b9c51f950f58f1079f68b03c` |
| `moq-relay-ietf/src/local.rs` | `ecacbe786afa98fbc75afbdf8cde57571a43b818662b946ee43db5c593ac2395` |
| `moq-relay-ietf/src/producer.rs` | `23b8ac2ea42987414aebc1f4b21c9eaf5dae182335fba00c3a2aadfd75238960` |
| `moq-relay-ietf/src/relay.rs` | `8c0df50c59ca86c132272b573604e6a10657cd6781bb70f9ed384e1262c1b3e4` |
| `moq-relay-ietf/src/relay_c2_tests.rs` | `5ebccdf289a5b4183b28e78ee56dfad7f991a2c4c58eda27327c5e88f8033237` |
| `moq-relay-ietf/src/remote.rs` | `ed2c2c1759dff247ecac4582021938026572a301db29a44059459b6308b7f614` |
| `moq-relay-ietf/src/session.rs` | `9be32af612ae4cf7a3e3868432141adf17796eb07405d9bdb7d618570a36c60e` |
| `moq-relay-ietf/src/session_admission.rs` | `cc5c56db172f7fb13e1f5a1a8bea3957c096d869dd97ac3f9d9f753820f0c7ef` |
| `moq-relay-ietf/src/upstream_namespaces.rs` | `39dd2e657e511465e89fee2d24a53452ab30a9a4bb3b588d9888e98bd89f05f3` |
| `moq-relay-ietf/tests/c2_session_admission.rs` | `1b528da9ccd852d81085bad190e01ae9a5a84ca6724574ed6a7cd2904e7e0a0a` |
| `moq-relay-ietf/tests/data/c2/README.md` | `285e4e178ecd6a7c5cffe5409107bc11bdf096bba9ebc014e805c0b991c1ae72` |
| `moq-relay-ietf/tests/data/c2/SHA256SUMS` | `ccc4d9cbcc23c31cfd12e2ef5d0a57e6d0901c243f7a732fc6eba20a7c82c8fd` |
| `moq-relay-ietf/tests/data/c2/ca.cert.pem` | `c439d7428d418762e090e1ce0fdda1524473daa66f052da251e120d78555dfbb` |
| `moq-relay-ietf/tests/data/c2/ca.cert.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-relay-ietf/tests/data/c2/server.cert.pem` | `76fe11a03423308533516c61c8e06f994746293313ef8961091de0e87cbd2b09` |
| `moq-relay-ietf/tests/data/c2/server.cert.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| `moq-relay-ietf/tests/data/c2/server.key.pem` | `607642c80b7ec6e365ef877e24c526ca546542fb5c330ae191891a212b67aa35` |
| `moq-relay-ietf/tests/data/c2/server.key.pem.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |

All final staged modes are regular `100644`; the complete staged tree has zero
symlinks, gitlinks or other non-regular entries. There are zero conflict
markers in the 31 paths, and both `git diff --check` and
`git diff --cached --check` pass.

## Protected manifests, graph and protocol boundary

All ten workspace manifests have the same Git blob in I2 `HEAD` and the staged
tree. Their independently computed SHA-256 values are:

| Path | SHA-256 |
| --- | --- |
| `Cargo.toml` | `6665802c9ad7192d61521a62877454e25bde7072c611e617780a932f583aa48f` |
| `moq-api/Cargo.toml` | `e57efd615490c51f44dab2e5a9191dffd6905af6a62a80270ad48b6abef608aa` |
| `moq-catalog/Cargo.toml` | `2afbf9e80ff295e644b0a602aa8872519c58b1b9952706e7a6eee64bccf96163` |
| `moq-clock-ietf/Cargo.toml` | `8fe88445f6ca8440fe71253c0099d03ae941d8a20592355909b983d63455f0b0` |
| `moq-native-ietf/Cargo.toml` | `3180121a89c58071718236a408f36c1c87757d6f9ff81e899fb3b5814c8d4c8e` |
| `moq-pub/Cargo.toml` | `f83801032ce7e65efc1356c2e3b8a1b6976c4980eb51f8352c95efb6b0a63b63` |
| `moq-relay-ietf/Cargo.toml` | `83185ddb3f1523a6d7d9c577abbf29010eb34d6043538c1b28ff1057bb888b11` |
| `moq-sub/Cargo.toml` | `fa54e8740c06b459dac85ae931a90f7dba8a671041f925b3c2436434cb5a4515` |
| `moq-test-client/Cargo.toml` | `6d8d680dc98eeedaca9bbf355d4c827886397e13948558a4916c362c57b4d2d3` |
| `moq-transport/Cargo.toml` | `78f582c201082f7badece64f7fa65d215a6694412b7a7699332fa3bc9a4f3743` |

Additional protected SHA-256 values remain byte-identical to I2:

| Path | SHA-256 |
| --- | --- |
| `Cargo.lock` | `13b9f1c54ccbe644dcf4f07542f610950cd013b291c928b6b3ad39ac1751ce80` |
| `REUSE.toml` | `afc7fd86e591a56078b11982ee4d039ea1dfe3f9d56a90e3e7fa9f84fbddb6cc` |
| `LICENSES/MIT.txt` | `c7d191b5901a741f2e39c74bd7a7594014a81fbe2bc7d533d4c29ad4cfe4e057` |
| `LICENSES/Apache-2.0.txt` | `1248f876e0140942002b476a19c95d5b5b44c625e69c96611d23119ee87fa04e` |
| `moq-transport/src/setup/mod.rs` | `c49d71dcacd5e3f5eef7a673e11b9058d3fd701e1fb83331a737098894a2d750` |
| `moq-transport/src/setup/version.rs` | `384772b32812a0761fa55d16a9fd29e30595323ece1b3fca013ec3720eaec4ad` |
| `moq-transport/src/message/mod.rs` | `e5760f5ce2927b2437511b3e616fea2615d82e916d4b6036b7f5450ae0973352` |
| `moq-transport/src/session/mod.rs` | `5fa5a8a1c8d68faf86553146eb7b0d39a7ee9aea6a41b97e4abf261500115b00` |
| `moq-transport/src/serve/tracks.rs` | `a8303c94925707a0a257923725bf84e4ec730b07d6bb2330fda5329b632fe0b7` |

Therefore this correction introduces no crate, package version, dependency,
feature, cryptographic provider, wire change, ALPN/draft change, license or
product pin. Q, U1 and cryptographic batch T are not present in this snapshot.

## SPDX, copyright and fixture provenance

All staged Rust sources use `MIT OR Apache-2.0`. Fixture READMEs, checksum
inventories and sidecars use the same expression, and each of the six staged
DER/PEM payloads has an adjacent REUSE sidecar with SHA-256
`5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0`.
No upstream copyright or notice was removed from the five newly included
source files.

Independent provenance checks found:

- C1 `sha256sum -c` passes for all three DER payloads.
- Each C1 DER hash is also present in the immutable public I1 fixture set.
- The three C2 PEM hashes pass in place.
- Direct PEM payload decoding, without key reserialization, reproduces the
  three exact C1 DER hashes in `moq-relay-ietf/tests/data/c2/SHA256SUMS:9-11`.
- The server certificate and key derive the same public-key hash.
- Certificate metadata classifies as synthetic/test-only, contains no Teremoq
  or customer marker and uses no externally routable production identity.
- The expected failure of an unfiltered `sha256sum -c` in the C2 directory is
  limited to the three absent DER names: those lines are cross-crate provenance
  references, not duplicated files. Each was instead verified against the C1
  directory.

REUSE 5.1.1, run from the digest-pinned official image with `--network none`
and the source mounted read-only, passes with:

- bad, deprecated, missing and unused licenses: 0;
- read errors: 0;
- copyright information: 223/223;
- license information: 223/223; and
- used licenses only `Apache-2.0` and `MIT`.

This is a technical license review, not legal advice.

## Redacted secret and publication-boundary review

Gitleaks 8.30.1/MIT ran from
`zricethezav/gitleaks@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f`
with `--network none`, `--redact=100`, no suppressions and exact tree archives:

| Scope | Files / bytes | Result |
| --- | --- | --- |
| exact 31 staged paths | 31 / 668,342 | one expected `private-key`, C2 PEM line 1, value `REDACTED` |
| nine corrected source paths | 9 / 449,967 | zero findings |

Supplementary classification across the 31 paths found zero local Unix or
Windows user paths, emails, SPIFFE IDs, authenticated URLs, non-fixture PEM
private-key markers or Teremoq/customer certificate identities. URL and IP
literals are limited to loopback, RFC 1918 private addresses, RFC 5737
documentation addresses, `example.com` and `.invalid` canaries. None is an
externally routable customer endpoint or operational namespace.

There are no staged or source-side `target`, `.cache`, `__pycache__`, object,
shared-library, executable or temporary artifacts. Temporary scan directories
were created under an exact `/tmp/teremoq-oss-sc-*` prefix, mounted read-only
for scanning and deleted after each command. Ephemeral containers used
`--rm`; no review container remains.

## Offline package reproducibility

Rust and Cargo 1.93.0 ran from local image
`teremoq-local-rust193-components@sha256:f522c28d5beb21591f46e8c165030f70b32dd5b51107577ad196910e7147a007`
with `--network none`, source read-only, ephemeral target tmpfs and approved
Cargo registry/Git cache volumes mounted read-only.

| Command | Result |
| --- | --- |
| `cargo metadata --locked --offline --no-deps --format-version 1` | PASS; 9 packages, 9 dual-licensed packages |
| `cargo package --locked --offline -p moq-native-ietf --list --allow-dirty` | PASS; 32 entries; 0 forbidden paths |
| `cargo package --locked --offline -p moq-relay-ietf --list --allow-dirty` | PASS; 48 entries; 0 forbidden paths |
| focal `rustfmt --edition 2021 --check` over nine corrected paths | PASS |
| full `cargo fmt --all -- --check` | `BLOCKED_BY_BASELINE_E0308`; exactly the two inherited protected diffs |

The native package list contains all eight C1 README/checksum/payload/sidecar
entries and `src/quic_c1_tests.rs`. The relay package list contains all eight
C2 entries plus `src/i2_tests.rs`, `src/relay_c2_tests.rs` and
`src/session_admission.rs`. There are no absolute, parent-escaping, target,
cache or binary-artifact paths. Every focal `include_bytes!` path remains
inside its own package; C2's DER provenance is documentary and does not create
a cross-package compile-time path.

`--allow-dirty` is required because the merge is intentionally staged but not
committed. A future committed candidate must repeat package creation without
that allowance. No SBOM or release artifact was created, and this review is
not a release gate.

## Representative commands

All Git reads used `GIT_OPTIONAL_LOCKS=0`. Representative commands were:

```text
sha256sum /home/jimbomilk/teremoq/.cursorrules
git rev-parse HEAD MERGE_HEAD
git diff-index --cached --quiet d7f0c67f4c134adc4250885f6bc031aa2efcead6 --
git diff --cached --name-only
git status --porcelain=v1 -z --untracked-files=no
git ls-files -u
git diff --check
git diff --cached --check
git diff --name-status 985f7f4ab4bad35c742f6c7028b1b8e6aec97e2b d7f0c67f4c134adc4250885f6bc031aa2efcead6
sha256sum -c moq-native-ietf/tests/data/c1/SHA256SUMS
openssl x509 -outform DER
docker run --rm --network none --read-only fsfe/reuse@sha256:11eb8a... lint
docker run --rm --network none --read-only zricethezav/gitleaks@sha256:c00b6bd0... dir /scan --redact=100
cargo metadata --locked --offline --no-deps --format-version 1
cargo package --locked --offline -p moq-native-ietf --list --allow-dirty
cargo package --locked --offline -p moq-relay-ietf --list --allow-dirty
```

No tool was installed and no network operation was attempted.

## Remote and publication state

The branch has no upstream. The only locally cached remote ref remains
`origin/teremoq/baseline-draft16-bf87128` at
`bf87128affd316463e5dcc7599a45001f222b6de`; no I1, I2, C1, C2 or integration
ref is locally observed as published. This local observation is not future
authorization.

No source, manifest, lockfile, index entry, Git config/ref, ADR, PKI material
or prior report was edited by this review. No checkout, format, stage, restore,
commit, fetch, push, tag, issue, pull request, release, publication or remote
mutation was performed. The only persistent write is this TP-OSS-SC report.

The report SHA-256 is delivered externally after the final frozen-state check;
it is not self-embedded because that would make the digest circular.
