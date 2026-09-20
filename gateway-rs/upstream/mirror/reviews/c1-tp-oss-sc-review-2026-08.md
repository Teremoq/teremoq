<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# C1 TP-OSS-SC local supply-chain review

Date: 2026-08-28

Profile: `TP-OSS-SC: Open Source & Software Supply Chain Engineer`

Reviewed worktree: `/home/jimbomilk/moq-rs-teremoq-c1-work`

## Findings

1. **High, inherited publication blocker — no C1 line introduced it.** The
   byte-identical base/C1 `Cargo.lock` still resolves 19 vulnerable entries
   representing 15 RustSec advisory IDs and six warnings against the fixed
   database described below. The derivative also still has no `deny.toml`.
   These global gates keep publication red, but comparison by advisory,
   package and version proves that C1 introduced none of them.
2. **Low, deliberate public test-key risk —
   `moq-native-ietf/tests/data/c1/README.md:8-15` and
   `moq-native-ietf/src/quic_c1_tests.rs:19-21`.** C1 intentionally retains one
   private-key DER whose bytes are already public synthetic I1 test material.
   The README says it is test-only and must never be deployed; the source loads
   it only in the `#[cfg(test)]` module linked at
   `moq-native-ietf/src/quic.rs:1355-1357`. Accidental reuse in a real endpoint
   would be unsafe, but the documented, checksum-pinned copy is acceptable for
   local tests and a local commit.
3. **No actionable C1 supply-chain finding.** No extra path, dependency,
   feature, package version, incompatible license, notice loss, secret,
   productive identity, local-user path, external address, new `unsafe`, second
   transport or wire crate change was found in the exact snapshot.

No finding above authorizes publication, a remote branch, a product pin, C2 or
integration.

## Verdict

**APPROVE FOR LOCAL COMMIT**

This verdict applies only to the exact ten-path inventory and hashes recorded
below. It permits the owning task to retain and locally commit that snapshot
after Master review. It does not stage or commit files and does not imply that
the snapshot is ready for push or publication.

Publication state: **NOT READY**. The known global RustSec, cargo-deny policy,
repository/release and sequential-integration gates remain open.

## Governing boundary

The review used the complete project `.cursorrules` and the applicable accepted
decisions:

- `ADR-0004-FEDERATED-MTLS.md`, which identifies the pre-C1 unbounded native
  handshake gap and preserves the existing QUINN/rustls/MoQT stack;
- `ADR-0006-FEDERATION-CONCURRENCY.md`, which records that the approved upstream
  baseline has no effective pending-handshake bound; and
- `ADR-0007-CONTROLLED-MOQ-MIRROR.md`, which fixes the derivative baseline/tree,
  requires `MIT OR Apache-2.0`, separates C1 from C2, prohibits wire/draft/ALPN
  drift and makes publication a separate authorization.

This is a technical supply-chain and license review, not legal advice and not a
review of C1's concurrency semantics. Functional ownership remains with
`TP-RUST-DIST`; chaos/admission test design remains with
`TP-PLATFORM-CHAOS`.

## Git identity and exact inventory

Read-only Git inspection used `GIT_OPTIONAL_LOCKS=0` and independently found:

- branch: `teremoq/c1-bounded-handshakes-bf87128`;
- HEAD/base: `bf87128affd316463e5dcc7599a45001f222b6de`;
- HEAD/base tree: `d76319009e815fb8923e21fc8319e17a0aaf8174`;
- stage: empty; and
- delta: exactly one modified tracked path plus nine new untracked paths.

The complete ten-path inventory is:

| State | Path | SHA-256 |
|---|---|---|
| modified | `moq-native-ietf/src/quic.rs` | `45d11ce77ea0e90e6480a48fdc3e5e2556500139985d20761f7fb7879df91172` |
| new | `moq-native-ietf/src/quic_c1_tests.rs` | `c182b102c91bbec1cf4a8376b822836b1672bc2f07b465d6372d29a741a691d0` |
| new | `moq-native-ietf/tests/data/c1/README.md` | `717d3219aa203034fde416b6e17f291e21ab9344a15e258a92aaaf3812a14e10` |
| new | `moq-native-ietf/tests/data/c1/SHA256SUMS` | `ba0f134515bdca4413dc9658d4016343a2180fd6c8f624e7e1b779f013696d64` |
| new | `moq-native-ietf/tests/data/c1/ca.cert.der` | `ea33add88bed4676c51baa4f8da9df33d04e99cecf7d0846a756e23b0f66461b` |
| new | `moq-native-ietf/tests/data/c1/ca.cert.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| new | `moq-native-ietf/tests/data/c1/server.cert.der` | `053a80b61f971f0601d83305ec6139fbcd7ed2f78c541078ac6e68a7e6da16bc` |
| new | `moq-native-ietf/tests/data/c1/server.cert.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| new | `moq-native-ietf/tests/data/c1/server.key.der` | `1d02d7ec66886fc2bb2cc3104851e1c182d7980e946d8df2e8f0f3ae33c30436` |
| new | `moq-native-ietf/tests/data/c1/server.key.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |

`git diff --name-status <base>` plus
`git ls-files --others --exclude-standard` was used instead of relying on the
directory-collapsed short status. The resulting set equals the permitted C1
set exactly.

## Base equivalence and dependency boundary

Direct blob comparison against the base found zero mismatch across 14 critical
files comprising `Cargo.lock`, every `Cargo.toml`, the REUSE configuration and
license objects. The ten-manifest path/blob inventory has the same aggregate
SHA-256 in base and C1:
`28b665653f8124b7a2d26b1b5ae7c28b34dcd77fcc72ada77bacae28174fff3a`.
Both base and current `Cargo.lock` have SHA-256
`b518a2fa4a6d7a0ffe0bdfe4b530f05196ac0f5e6f7ef51da9e5a83c0b0561c0`.

Consequences verified from those byte identities and the path diff:

- no manifest or lock edge changed;
- no dependency, package version, feature or provider was added;
- `moq-native-ietf/Cargo.toml:1-9` retains upstream copyright/SPDX and
  `license = "MIT OR Apache-2.0"`;
- all wire/protocol crates outside the two allowed C1 Rust paths are
  byte-identical to the base;
- no LICENSE, NOTICE or REUSE policy file changed; and
- no added line in the `quic.rs` delta changes an ALPN, draft identifier or
  wire constant.

The production delta uses only existing standard-library, Tokio and QUINN
surfaces already resolved by the base. The test module uses already resolved
rustls/Tokio APIs; it adds no dev-dependency.

## Fixture provenance, SPDX and secret boundary

The source of comparison was the previously reviewed local I1 commit
`05b41127ecbd48de4c59fe1626c43b1e423c33a9`, tree
`eca64a72e148482fb82b963edc2f2c9af28803f2`, paths under
`moq-native-ietf/tests/data/`. Without displaying binary/key values:

- all three C1 DER files are byte-for-byte equal to their I1 sources;
- all three `.license` sidecars are byte-for-byte equal to the I1 sidecars;
- every sidecar declares `MIT OR Apache-2.0` at lines 1-2; and
- `sha256sum -c SHA256SUMS` passes all three entries.

OpenSSL 3.5.5 parses the certificates. The CA/issuer and server subjects are
`moq-native-ietf-test-ca` and `moq-native-ietf-server`; the only server SANs are
`localhost` and `127.0.0.1`. No customer, Teremoq production identity, external
IP, productive namespace or real trust material appears. The key is not a
secret because it is intentionally public test material, but it remains unsafe
for any deployment.

New C1 Rust, README and checksum inventory use
`MIT OR Apache-2.0`. Binary files use adjacent REUSE sidecars rather than syntax
breaking headers. The official REUSE 5.1.1 image fixed at
`sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da`
ran against a read-only source snapshot excluding only `.git` and generated
`target/`. It exited 0: 196/196 files have copyright and license information,
zero license/read errors were reported, and only MIT and Apache-2.0 are used.

Gitleaks 8.30.1, MIT, fixed at
`sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f`
scanned a bundle containing exactly the ten delta paths with `--redact=100`, no
custom configuration, no allowlist and no suppression. It scanned about 91 KB,
exited 0 and found no leak. A complementary textual scan found no credentials,
authenticated URL, private local path, SPIFFE ID, customer marker or productive
namespace. No sensitive value is reproduced here.

## RustSec comparison

The local cargo-audit 0.22.2 binary, MIT OR Apache-2.0, has SHA-256
`66f9c8f530950d106c1869ce27ef5a4008bcea53c7716c3ed8117586337ee7d8`.
It ran with `--no-fetch` against the official RustSec database origin
`https://github.com/RustSec/advisory-db.git` at exact commit
`6420e39260b3d771b049954cf5d52b57e2118da4`.

Both the base-extracted and current lock runs exit 1 with identical sets:

- 19 vulnerable lock entries and 15 unique advisory IDs;
- six warnings; and
- affected packages `aws-lc-sys 0.30.0`, `bytes 1.6.0`,
  `crossbeam-epoch 0.9.18`, `h2 0.4.5`, `idna 0.5.0`,
  `quinn-proto 0.11.13`, `rustls-webpki 0.102.4`,
  `rustls-webpki 0.103.4` and `tracing-subscriber 0.3.18`.

Equality was checked by advisory ID, package and version; warnings were checked
by category, package and version. No advisory was ignored or suppressed. C1
therefore adds no vulnerable package/version, but it cannot turn the known
baseline into a passing publication gate.

## Independently executed tests

The worktree was mounted read-only into the official Rust 1.93.0 image fixed at
`sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57`.
Cargo home and target output were external temporary paths. The observed
toolchain was rustc `1.93.0 (254b59607)` and Cargo
`1.93.0 (083ac5135)`.

| Command | Result |
|---|---|
| `cargo check --locked --offline -p moq-native-ietf` | PASS, exit 0 |
| `cargo test --locked --offline -p moq-native-ietf c1_` | PASS, 23 passed, 0 failed, 1 filtered |
| `cargo test --locked --offline -p moq-native-ietf` | PASS, 24/24 unit tests and 0 doctest failures |
| `cargo package --locked --offline -p moq-native-ietf --list --allow-dirty` | PASS, 16 files; C1 test source and all eight C1 data/license artifacts included |
| `git diff --check <base>` | PASS, exit 0 |
| no-index whitespace check for each of nine new files | PASS, no diagnostic; exit 1 denotes content difference |

The pinned base image does not contain the rustfmt component. `rustfmt
--version` reported that the component is absent; no installation was performed
and no independent rustfmt result is claimed in this review. That tooling
limitation does not negate the passing compilation/tests or whitespace gates,
but formatting remains evidence owned by the implementation review rather than
this TP-OSS-SC approval.

## Local commit versus publication

The exact snapshot is acceptable for a local commit because its delta is
closed, attributable, dual-licensed, REUSE-complete, secret-clean, package
self-contained and dependency-neutral. The synthetic key risk is explicit and
unchanged from I1.

Publication remains separately blocked until the existing RustSec remediation
batches, a reviewed `deny.toml`, complete release/SBOM/provenance gates, exact
remote-ref inventory changes and all other Master-owned gates pass. This review
does not update `baseline.env`, the verifier or any remote state. It neither
reviews nor authorizes C2.

## Activity confirmation

After all commands, branch, HEAD, base tree, empty stage, ten-path inventory and
all recorded hashes remained unchanged. The C1 worktree, source, manifests,
lock, Git configuration/index and prior reports were not edited. No fetch,
push, publication, tag, release, issue, pull request, Discussion, message,
email, service change or other remote action occurred.

**LOCAL SUPPLY-CHAIN REVIEW ONLY / NOT PUBLISHED / NO REMOTE MUTATION / NO C2**
