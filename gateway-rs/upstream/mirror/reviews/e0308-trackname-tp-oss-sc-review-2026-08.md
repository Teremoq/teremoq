<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# TP-OSS-SC review of the staged E0308 TrackName repair

Date: 2026-08-28 10:53:05 UTC

Profile: `TP-OSS-SC: Open Source & Software Supply Chain Engineer`

Scope: independent, read-only license, provenance, supply-chain and
reproducibility review of the staged E0308 package in the isolated local
`moq-rs-teremoq` worktree.

State: **LOCAL STAGED SOURCE PACKAGE / NOT COMMITTED / NOT PUBLISHED**

## Findings first

### HIGH — inherited RustSec findings remain unchanged

The source-only test repair cannot remediate the dependency findings already
present in the base lock. The fixed local RustSec scan reports the same 16
vulnerable entries across 12 advisory IDs and six warnings across five IDs
before and after the staged change. No finding is ignored or suppressed.

This inherited state blocks publication but is not a regression introduced by
the two test-only source paths.

### MEDIUM

None attributable to this package.

### INFO — all three hunks are confined to existing test modules

The two files each contain one `#[cfg(test)] mod tests` that runs to the final
closing brace:

| Path | Test boundary | Staged hunk ranges |
| --- | --- | --- |
| `moq-transport/src/serve/subgroup.rs` | `#[cfg(test)]` line 636; module line 637 through EOF line 1029 | new lines 937-938 |
| `moq-transport/src/serve/tracks.rs` | `#[cfg(test)]` line 283; module line 284 through EOF line 710 | new lines 307-308 and 499 |

There is no hunk before either `#[cfg(test)]`, no code after either test module,
and no added public symbol, API, import, `unsafe`, FFI or production branch.

The semantic hunk at staged `tracks.rs:499` is exactly:

```text
assert_eq!(track_writer.name, TrackName::from(track_name));
```

It uses the existing upstream `impl From<&str> for TrackName` at
`moq-transport/src/coding/track_namespace.rs:164`. No new conversion, trait or
type is introduced.

### INFO — the remaining two hunks are reproducibly rustfmt-only

Using fixed rustfmt 1.8.0 and Rust 1.93.0:

- formatting the base `subgroup.rs` produces SHA-256
  `30d401d94aba88cf89e828ee348db2ac1bbc521bdc8ec5c3f282ee12e4b200d7`,
  exactly the staged blob; and
- applying the one unique typed assertion replacement to base `tracks.rs`,
  then formatting it, produces SHA-256
  `412a2fc82c143eb6c1f0040b44f66794d4cd9fed8c3e63db5d6a2e8635ef0bec`,
  exactly the staged blob.

The base contains exactly one occurrence of the untyped assertion. This
reconstruction proves that no unreported semantic edit is hidden in either
formatting hunk.

### Validation limitation — large compiled suites were not repeated

The owner report, bound by SHA-256 below, records passing transport, native and
relay test/Clippy matrices on this exact staged tree. This independent
supply-chain review did not repeat those multi-gigabyte builds. It instead
reconstructed the blobs from the base, verified the existing conversion API,
ran full offline metadata, package, rustfmt, REUSE, secret and RustSec gates,
and preserved the owner's build evidence as attributed evidence rather than
claiming it as independently executed.

## Verdict

**APPROVE**

This verdict is limited to a future local commit containing exactly the frozen
two-path staged tree below. It does not authorize push, publication, tags,
releases, product pins, T or any remote action. The future commit must retain
the reviewed tree and carry a DCO 1.1 `Signed-off-by` matching its author.

## Frozen identity

The required state was reproduced before substantive inspection and again
after this report was created:

| Item | Frozen value |
| --- | --- |
| `.cursorrules` SHA-256 | `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2` |
| `HEAD` / base | `afeaa94cb41491a07ce55010ff00a88d5e8716a9` |
| Base tree | `4696ae59a07ec1b3930a654e03e412221f9a8a5d` |
| Staged tree | `cccd0d60c9ebfe191dca9d73e7ab8b27ae4d4ea5` |
| Staged paths | exactly 2 |
| Pathset SHA-256 | `37546925cd09e15789c286e450c705bdf0db51781cb2a28f3ce9f2731b797799` |
| Status-z SHA-256 | `3e66c5d217fdb0ec2f11fa3816a276857afbef697a587d9e980a936189ad1000` |
| `Cargo.lock` SHA-256 | `d6196fd8f31ea3b2cabbdb0e57546810643f344567f3e358ee3c000b3e2b59f5` |
| Unmerged / unstaged | 0 / 0 |
| Tracking branch | none |
| Owner report SHA-256 | `f47f559a169d1a10ca30a00c1f26c56f676f66beabbe234c5d4b029f0d9e9ffd` |

The owner report was read completely and used as an input, not as proof. The
staged tree comparison used read-only `git diff-index --cached --quiet`, not an
index-writing command.

The base is the already committed local Q + U1 integration. It has exactly two
parents and one `Signed-off-by` matching its author. That trailer does not
pre-sign the future E0308 commit.

## Exact staged inventory and diff

| Path | Base SHA-256 | Staged SHA-256 | Diff |
| --- | --- | --- | --- |
| `moq-transport/src/serve/subgroup.rs` | `f5c21e89c18dd21f8900d491920ad3b378653df3d4d5bfe0f176d928cf972382` | `30d401d94aba88cf89e828ee348db2ac1bbc521bdc8ec5c3f282ee12e4b200d7` | 2 insertions, 1 deletion; formatting only |
| `moq-transport/src/serve/tracks.rs` | `a8303c94925707a0a257923725bf84e4ec730b07d6bb2330fda5329b632fe0b7` | `412a2fc82c143eb6c1f0040b44f66794d4cd9fed8c3e63db5d6a2e8635ef0bec` | 3 insertions, 5 deletions; typed test assertion plus formatting |

Total: five insertions and six deletions. The standard staged patch SHA-256
(`git diff --cached --binary`) is
`2e1090c4b991b25abcaad81cca670075ad471c2a5ce54dd0bb08f07285debb22`.
With explicit `--full-index`, the representation SHA-256 is
`ec744613f1183ace86c16f0647f770478f13e48868762c72efb7637d2894f967`.
The difference is only Git's textual index-line representation, not content.

Both final modes are regular `100644`. There are zero conflict markers and no
staged symlink, gitlink, generated file, target, cache or binary artifact.
`git diff --check` and `git diff --cached --check` pass.

## License and copyright boundary

Both staged files retain their upstream copyright notices and the exact SPDX
expression `MIT OR Apache-2.0` at their file headers. No notice, license text or
third-party attribution is removed or added. The conversion implementation is
existing upstream code and is not copied into the changed files.

Protected license/configuration hashes remain:

| Path | SHA-256 |
| --- | --- |
| `REUSE.toml` | `afc7fd86e591a56078b11982ee4d039ea1dfe3f9d56a90e3e7fa9f84fbddb6cc` |
| `LICENSES/MIT.txt` | `c7d191b5901a741f2e39c74bd7a7594014a81fbe2bc7d533d4c29ad4cfe4e057` |
| `LICENSES/Apache-2.0.txt` | `1248f876e0140942002b476a19c95d5b5b44c625e69c96611d23119ee87fa04e` |

REUSE 5.1.1 from the fixed official image, with network disabled and source
read-only, passes 223/223 files; zero bad, deprecated, missing or unused
licenses; only MIT and Apache-2.0. This is a technical review, not legal advice.

## Dependency, T and protocol boundary

`Cargo.lock` is the exact same Git blob in the base and staged tree. TOML parsing
finds 336 records before and after with complete record-array equality. All
manifests, requested features, providers, fixtures and Rust files other than
the two test modules are byte-identical.

Selected versions remain:

- `bytes 1.11.1`;
- `quinn-proto 0.11.15`;
- `rustls 0.22.4` and `0.23.31`;
- `aws-lc-rs 1.13.3` and `aws-lc-sys 0.30.0`; and
- `rustls-webpki 0.102.4` and `0.103.4`.

T is absent. Representative protected files remain:

| Path | SHA-256 |
| --- | --- |
| `moq-transport/Cargo.toml` | `78f582c201082f7badece64f7fa65d215a6694412b7a7699332fa3bc9a4f3743` |
| `moq-transport/src/setup/mod.rs` | `c49d71dcacd5e3f5eef7a673e11b9058d3fd701e1fb83331a737098894a2d750` |
| `moq-transport/src/setup/version.rs` | `384772b32812a0761fa55d16a9fd29e30595323ece1b3fca013ec3720eaec4ad` |
| `moq-transport/src/message/mod.rs` | `e5760f5ce2927b2437511b3e616fea2615d82e916d4b6036b7f5450ae0973352` |
| `moq-transport/src/session/mod.rs` | `5fa5a8a1c8d68faf86553146eb7b0d39a7ee9aea6a41b97e4abf261500115b00` |
| `moq-native-ietf/src/quic.rs` | `92e94e527dce998543b050e1d4af0012b6c18df2b4e32c068ad9ebb46594934d` |

Consequently there is no dependency, manifest, feature, provider, ALPN,
draft-16, setup, wire, Track/Group/Object, fixture or production API change.

## Offline reproducibility and package boundary

Rust/Cargo 1.93.0 and rustfmt 1.8.0 ran from
`teremoq-local-rust193-components@sha256:f522c28d5beb21591f46e8c165030f70b32dd5b51107577ad196910e7147a007`
with `--network none`, source read-only, ephemeral target tmpfs and Cargo
registry/Git caches read-only.

| Gate | Result |
| --- | --- |
| `cargo fmt --all -- --check` | PASS |
| metadata `--locked --offline --no-deps` | PASS; SHA-256 `9506420f2a7fd10f307a9936e2ce33a2fcbb6d66fe55add5cf933e15d81160d8` |
| Linux metadata `--locked --offline --filter-platform x86_64-unknown-linux-gnu` | PASS; 233 packages and 233 nodes; SHA-256 `eb53c61a1da95491aef4884b7e9a98840d26c0bff7cf8ed9c25bd33f6e7795a7` |
| `cargo package --locked --offline -p moq-transport --list --allow-dirty` | PASS; 97 entries; zero forbidden paths; both changed sources included |

`--allow-dirty` is required because the package is intentionally staged and
uncommitted. A future committed candidate must repeat package creation without
that allowance.

Gitleaks 8.30.1/MIT ran from
`zricethezav/gitleaks@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f`
over the complete `moq-transport` crate with `--redact=100`, network disabled
and source read-only: 764,075 bytes, zero findings. No source-side `target`,
temporary directory, cache, compiled binary or secret was found.

## RustSec equivalence

`cargo-audit 0.22.2`, executable SHA-256
`66f9c8f530950d106c1869ce27ef5a4008bcea53c7716c3ed8117586337ee7d8`,
ran with `--no-fetch`, no suppression, and the clean official local DB at:

- commit `a7bfe16948bf6f3ee25bdee4822209f87da21b80`;
- tree `1152ddcadf432f7bf97746e51fb7f2d9e5968c49`.

Both base and staged audit JSON have SHA-256
`9fd2fe4ed24c7885cb266fb654491af01034cdbea1f98e39e98fb14701d80ec3`.
Each exits 1 with 16 vulnerable entries / 12 IDs and six warnings / five IDs.
The source-only test fix therefore removes and introduces no advisory.

## Activity and handoff boundary

Only read-only Git, parsing, fixed offline containers and hashing were used.
No tool or dependency was installed and no network operation was attempted.
The reviewed worktree, index, source, lock, manifests, refs, configuration and
remotes were not modified. No checkout, format, stage, restore, commit, fetch,
push, issue, pull request, tag, release, publication, message or remote
mutation was performed. The only persistent write is this report.

The report SHA-256 is delivered externally after the final frozen-state check;
it is not self-embedded because that would make the digest circular.
