<!--
SPDX-FileCopyrightText: 2026 Teremoq contributors
SPDX-License-Identifier: Apache-2.0
-->

# C1 corrected snapshot TP-OSS-SC differential rereview

- Date: 2026-08-28
- Profile: `TP-OSS-SC: Open Source & Software Supply Chain Engineer`
- Reviewed worktree: `/home/jimbomilk/moq-rs-teremoq-c1-work`
- Scope: local supply-chain, provenance and local-commit boundary only
- Remote or publication authority: none

## Findings

### High — inherited publication blockers remain unchanged

The byte-identical base/C1 `Cargo.lock` still reports `19` vulnerable entries
covering `15` distinct RustSec advisory IDs and `6` informational warnings
against the fixed database recorded below. The derivative still lacks a
reviewed `deny.toml`, completed normal/all-feature SBOM reconciliation and the
remaining release and sequential-integration gates. C1 introduces none of
these findings, but this local correction cannot make publication ready.

### Low — deliberately public synthetic test private key remains

`moq-native-ietf/tests/data/c1/server.key.der` is byte-for-byte identical to
the already public I1 synthetic test key. Its README calls it public test
material, limits it to tests and prohibits deployment. It is loaded only from
the C1 test module. It is not productive trust material or an undisclosed
secret, but accidental deployment would be unsafe. This accepted residual risk
is unchanged from the prior TP-OSS-SC approval.

### Low — complete offline workspace metadata remains a publication limitation

The focal package compiled and tested offline, and the complete lock was
independently parsed and compared. A separate full-workspace
`cargo metadata --locked --offline` attempt stopped because `ahash 0.8.12`,
which is unrelated to the C1 delta, was absent from the authorized local source
cache. No fetch or network fallback was used. `--no-deps` metadata for all nine
workspace packages passed. This cache limitation does not invalidate the
byte-identical package graph or the passing focal build, but a clean complete
release reconstruction remains required before publication.

### No actionable C1 supply-chain finding

The corrected snapshot contains exactly the authorized ten paths. It adds no
manifest, lock edge, dependency, package coordinate, feature, provider,
backend, production callback, production channel/task, crate, wire constant,
license or notice change. The only channel and spawned tasks are confined to
`cfg(test)` hooks and the new test module; the normal artifact adds no runtime
channel, callback, worker or backend.

## Local-commit verdict

**APPROVE FOR LOCAL COMMIT**

This verdict is bound to the exact ten paths and hashes below. It permits the
owning task to retain and locally commit this snapshot after Master review. It
does not stage or commit any path, and it does not authorize C2, integration, a
product pin, push, tag, release or publication.

## Publication status

**PUBLICATION: NOT READY**

Global RustSec remediation, a reviewed cargo-deny policy, final SBOM and
provenance evidence, clean complete release gates, exact remote-ref inventory
changes and Master authorization remain required. Public baseline visibility
does not authorize publication of this C1 snapshot.

## Binding documents

The project `.cursorrules` and both required reviews were read in full. Their
SHA-256 values were:

| Input | SHA-256 | Result |
|---|---|---|
| `.cursorrules` | `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2` | read completely |
| prior TP-OSS-SC approval | `3ee4bb9e6c52d6d1895fe7704f7d5bf4c244db4956440eac7e6441d4baa5a3b6` | matches required hash |
| `c1-local-rereview-2026-08.md` | `8fe7ae3ede22f475a125eece900ddea7d93abe2955d179b7a16fe3064dd98ab6` | matches required hash |

The reports were treated as binding inputs, not substituted for independent
inspection. Git identity, paths, hashes, lock/package sets, fixtures, RustSec,
SPDX/REUSE, Gitleaks and focal tests were repeated by this reviewer.

## Git identity and exact inventory

All Git commands used `GIT_OPTIONAL_LOCKS=0`. Read-only inspection found:

- branch: `teremoq/c1-bounded-handshakes-bf87128`;
- HEAD/base: `bf87128affd316463e5dcc7599a45001f222b6de`;
- HEAD tree/base tree: `d76319009e815fb8923e21fc8319e17a0aaf8174`;
- stage: empty;
- status inventory SHA-256:
  `fc674e7161c60e0aae278ea478f6570a9606d706aa81dad0c60e2384d5e8d3f9`;
- tracked delta: one modified path, `541` insertions and `7` deletions; and
- untracked delta: exactly nine permitted paths.

The complete ten-path set is:

| State | Path | SHA-256 |
|---|---|---|
| modified | `moq-native-ietf/src/quic.rs` | `b0c8dfb3e4963365a3a27f52a84d2fc54292cfc5a056a817a5a0d0a4f38b3723` |
| new | `moq-native-ietf/src/quic_c1_tests.rs` | `0366d05cd35627bf160499db9146b45cac106d41d746e16fd16cfabdf4c262c2` |
| new, unchanged | `moq-native-ietf/tests/data/c1/README.md` | `717d3219aa203034fde416b6e17f291e21ab9344a15e258a92aaaf3812a14e10` |
| new, unchanged | `moq-native-ietf/tests/data/c1/SHA256SUMS` | `ba0f134515bdca4413dc9658d4016343a2180fd6c8f624e7e1b779f013696d64` |
| new, unchanged | `moq-native-ietf/tests/data/c1/ca.cert.der` | `ea33add88bed4676c51baa4f8da9df33d04e99cecf7d0846a756e23b0f66461b` |
| new, unchanged | `moq-native-ietf/tests/data/c1/ca.cert.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| new, unchanged | `moq-native-ietf/tests/data/c1/server.cert.der` | `053a80b61f971f0601d83305ec6139fbcd7ed2f78c541078ac6e68a7e6da16bc` |
| new, unchanged | `moq-native-ietf/tests/data/c1/server.cert.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |
| new, unchanged | `moq-native-ietf/tests/data/c1/server.key.der` | `1d02d7ec66886fc2bb2cc3104851e1c182d7980e946d8df2e8f0f3ae33c30436` |
| new, unchanged | `moq-native-ietf/tests/data/c1/server.key.der.license` | `5d2fcf02dc5b8f21a5043a42c27229b7dbacdc9fc7c897b0a141f3f25daff7b0` |

`git diff --name-status <base>` plus the complete sorted untracked inventory
equals this set exactly. No additional source, generated file or local artifact
is present in the C1 delta.

## Dependency, feature, package and wire boundary

Direct comparison to the immutable base produced zero difference for all ten
`Cargo.toml` files, `Cargo.lock`, `REUSE.toml`, license objects,
`moq-transport` and `moq-relay-ietf`. The manifest inventory contains ten
entries and has the same independently calculated aggregate SHA-256 in both
snapshots:
`839c48f1ab217b60d500b97e449437f45241af9f0f703374b602776f917f2aaa`.

Protected hashes remain:

| Object | SHA-256 |
|---|---|
| `Cargo.lock` | `b518a2fa4a6d7a0ffe0bdfe4b530f05196ac0f5e6f7ef51da9e5a83c0b0561c0` |
| root `Cargo.toml` | `6665802c9ad7192d61521a62877454e25bde7072c611e617780a932f583aa48f` |
| `moq-native-ietf/Cargo.toml` | `3180121a89c58071718236a408f36c1c87757d6f9ff81e899fb3b5814c8d4c8e` |
| `moq-transport/src/setup/mod.rs` | `c49d71dcacd5e3f5eef7a673e11b9058d3fd701e1fb83331a737098894a2d750` |

TOML parsing found `336` package records in base and C1. Complete record sets,
including name, version, source, checksum and dependency list, are identical.
No direct or transitive package, build script, crypto provider or feature
coordinate changed. Locked `--no-deps` metadata found nine workspace members,
all declaring `MIT OR Apache-2.0`.

Added-line and whole-file scans found no new observer/callback/backend API,
external crate, `unsafe`, ALPN, draft or wire constant. The test-stage
`mpsc::UnboundedSender` is under `#[cfg(test)]` at
`moq-native-ietf/src/quic.rs:748-787`; `tokio::spawn`, `JoinHandle` and the
remaining channels occur only in `quic_c1_tests.rs`. The non-test artifact uses
only dependencies and QUINN/Tokio surfaces already present in the base.

Because `moq-transport` is byte-identical, draft-16 encoding, setup messages,
Tracks, Groups, Objects and ALPN remain unchanged. In particular,
`moq_transport::setup::ALPN` remains `b"moqt-16"` at the unchanged
`moq-transport/src/setup/mod.rs:23`.

## Fixture provenance, identity and package boundary

All three DER files and all three sidecars compare byte-for-byte equal to the
corresponding already reviewed I1 public fixtures. They also have exactly the
same hashes as the prior TP-OSS-SC approval. `sha256sum -c SHA256SUMS` passed
all three entries.

Every DER has an adjacent REUSE sidecar with
`SPDX-FileCopyrightText: 2026 Teremoq contributors` and
`SPDX-License-Identifier: MIT OR Apache-2.0`. The README and checksum inventory
carry the same dual license. The corrected Rust source preserves the upstream
`MIT OR Apache-2.0` header; the new test module uses the derivative-compatible
same expression. No existing upstream copyright or notice changed.

OpenSSL 3.5.5 independently parsed the fixtures. The CA and server subjects are
`moq-native-ietf-test-ca` and `moq-native-ietf-server`; the server SANs are only
`localhost` and `127.0.0.1`. They do not represent a customer, external host,
productive namespace or Teremoq deployment identity.

`cargo package --locked --offline -p moq-native-ietf --list --allow-dirty`
passed and listed exactly `16` package files. It includes `quic.rs`,
`quic_c1_tests.rs`, README, checksum inventory, all three DERs and all three
sidecars. Every `include_bytes!` target remains inside the packaged crate.

## SPDX/REUSE and secret boundary

REUSE 5.1.1, GPL-3.0-or-later, ran from the official image fixed at
`fsfe/reuse@sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da`.
The source was mounted read-only, generated `target/` was hidden, and network
was disabled. It passed `196/196` files with copyright and license information,
zero missing/bad/deprecated/unused licenses, zero read errors, and only MIT and
Apache-2.0 in use.

Gitleaks 8.30.1, MIT, ran from
`zricethezav/gitleaks@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f`
against the focal crate with `--no-git --redact=100`, no custom config,
allowlist or suppression, network disabled and source read-only. It scanned
approximately `110804` bytes and found zero leaks.

A complementary redacted text-boundary scan reported zero local paths, SPIFFE
IDs, authenticated URLs or credential markers in the new textual artifacts.
No sensitive value is reproduced in this report.

## RustSec differential

The scanner was cargo-audit 0.22.2, `MIT OR Apache-2.0`, executable SHA-256
`66f9c8f530950d106c1869ce27ef5a4008bcea53c7716c3ed8117586337ee7d8`.
It used `--no-fetch`, no ignore/allow/suppression and the official RustSec DB:

- origin: `https://github.com/RustSec/advisory-db.git`;
- commit: `6420e39260b3d771b049954cf5d52b57e2118da4`;
- tree: `01794d45488a521b322b760b6bfdcd6e9f28932b`.

| Snapshot | Exit | Vulnerable entries | Unique IDs | Warnings |
|---|---:|---:|---:|---:|
| base-extracted lock | 1 | 19 | 15 | 6 |
| corrected C1 lock | 1 | 19 | 15 | 6 |

Set comparison by advisory, package and version is identical; warning sets by
category, advisory, package and version are also identical. Both added and
removed sets are empty. C1 therefore introduces no vulnerable package/version,
but the nonzero result remains a publication blocker.

## Independent focal compilation and tests

The corrected worktree was mounted read-only into the official Rust image:

```text
rust@sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57
rustc 1.93.0 (254b59607 2026-01-19)
cargo 1.93.0 (083ac5135 2025-12-15)
```

Network was disabled. Cargo registry and target directories were external
temporary copies, so compilation and tests could not write the C1 worktree.
All Cargo commands used `--locked --offline`.

| Command | Result |
|---|---|
| `cargo check -p moq-native-ietf` | PASS, exit 0 |
| `cargo test -p moq-native-ietf c1_` | PASS, 25 passed, 0 failed, 1 filtered |
| `cargo test -p moq-native-ietf` | PASS, 26 unit tests and 0 doctest failures |
| `cargo package -p moq-native-ietf --list --allow-dirty` | PASS, 16 files and complete fixture inventory |
| `cargo metadata --no-deps` | PASS, 9/9 workspace packages dual-licensed |
| complete offline workspace metadata | INCOMPLETE, unrelated cached source absent; no fetch attempted |
| `git diff --check <base>` | PASS |
| staged diff check | PASS; stage empty |
| no-index whitespace checks for all nine new paths | PASS; zero diagnostics |

The focal C1 tests cover unchanged wire constants, raw QUIC and WebTransport,
bounded admission/recovery, deadline, cancellation, Retry/refusal, TLS failure,
shared/local capacity, qlog and release-before-session behavior. This
supply-chain rereview does not convert those tests into a broad DoS,
interoperability, C2 or production-readiness claim.

## Validation and activity confirmation

After all checks, branch, HEAD/tree, status hash, empty stage, ten-path set and
every recorded hash remained unchanged. Repository `git diff --check` passed;
the report-specific no-index whitespace check and unfinished-marker scan are
recorded after document creation.

The C1 worktree, source, manifests, lock, target, Git configuration/index and
all existing reports were not edited. Only this report was created in the
Teremoq repository. Temporary Cargo/target evidence was outside both
repositories and was removed after validation.

No checkout, branch, add, commit, fetch, push, tag, release, pull request,
issue, publication, email, message, remote ref or service mutation occurred.
No tool or dependency was installed globally.

**LOCAL SUPPLY-CHAIN REREVIEW ONLY / NOT PUBLISHED / NO REMOTE MUTATION / NO C2**
