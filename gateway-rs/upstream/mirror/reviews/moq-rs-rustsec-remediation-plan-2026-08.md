# moq-rs RustSec baseline remediation plan

- Date: 2026-08-27
- Profile: `TP-OSS-SC`
- Implementation owner: `TP-RUST-DIST`
- Supply-chain reviewer: `TP-OSS-SC`
- Scope: planning for the inherited I1/I2 dependency graph only
- Status: documentary plan; no dependency or remote change is authorized

This is a technical security and software supply-chain assessment, not legal
advice. It does not approve an advisory exception, a dependency update, a
provider change, a release or any remote action.

## Frozen evidence and reproducibility

The plan uses the official RustSec advisory database at exactly:

- origin: `https://github.com/RustSec/advisory-db.git`;
- commit: `6420e39260b3d771b049954cf5d52b57e2118da4`;
- commit timestamp: `2026-08-27T14:01:44+02:00`.

The database is the primary source for affected ranges, patched ranges,
categories, CVSS vectors and exploitation conditions. Compatibility evidence
comes from the locked Cargo graph, the repository manifests and the locally
cached official crates.io sparse-index records. Source-use checks cover the
read-only derivative checkout. No finding is downgraded merely because its
specific trigger was not found in local source.

The two audited locks were:

| Snapshot | Lock SHA-256 | Result against the frozen database |
|---|---|---|
| I1, extracted from HEAD `05b41127ecbd48de4c59fe1626c43b1e423c33a9` | `b518a2fa4a6d7a0ffe0bdfe4b530f05196ac0f5e6f7ef51da9e5a83c0b0561c0` | 19 vulnerable entries, 6 informational warnings |
| I2 working snapshot | `13b9f1c54ccbe644dcf4f07542f610950cd013b291c928b6b3ad39ac1751ce80` | 19 vulnerable entries, 6 informational warnings |

The vulnerable and warning sets are identical by advisory, package and
version. Every finding therefore predates the I2 direct dev edge. I2 added
only a dependency edge from `moq-relay-ietf` to an already locked and already
runtime-reachable `rustls 0.23.31`; it introduced no affected package or
version.

Excluding dev edges removes none of the findings below. All are reachable from
normal/build edges of the relay except `crossbeam-epoch`, which is retained by
the optional normal feature `metrics-prometheus`. It is absent from the
default relay graph but present in `Cargo.lock` and in the all-features graph.
This distinction must be represented in SBOMs; it is not an advisory waiver.

## Vulnerability inventory

“Direct introducer” below names the closest dependency controlled by a
workspace manifest, not only the immediate transitive parent. “Minimum” is the
minimum fixed version recorded by the frozen RustSec database. A planned
bundle may intentionally select a later minimum when needed to remove another
affected line.

| Advisory | Locked package | Minimum fixed version | Direct introducer and scope | Teremoq relevance and expected compatibility |
|---|---|---|---|---|
| RUSTSEC-2026-0048 | `aws-lc-sys 0.30.0` | 0.39.0 | `rustls 0.23.31` and `quinn-proto` through `moq-native-ietf`, `hyper-serve`, `web-transport` and `moq-api`; runtime provider | Network crypto failure with high confidentiality/integrity impact, high attack complexity. Trigger requires CRL checking with partitioned CRLs and IDP extensions; current Rustls/webpki verification does not prove this AWS-LC X509 path unreachable. `aws-lc-rs 1.16.2` is the first cached non-yanked release requiring `aws-lc-sys ^0.39.0`; both require Rust 1.71 and fit Rust 1.93. |
| RUSTSEC-2026-0047 | `aws-lc-sys 0.30.0` | 0.38.0 | Same runtime provider path | Network, low-complexity PKCS7 signature-validation bypass with high integrity impact. MoQT TLS does not normally process PKCS7 objects, but the linked provider remains affected. The consolidated provider bundle must use at least 0.39.0 because of RUSTSEC-2026-0048. |
| RUSTSEC-2026-0046 | `aws-lc-sys 0.30.0` | 0.38.0 | Same runtime provider path | Network, low-complexity PKCS7 certificate-chain bypass with high integrity impact. The current relay has no identified PKCS7 call, but absence of a local call is not proof for all transitive or future provider uses. Consolidate at 0.39.0 or later. |
| RUSTSEC-2026-0045 | `aws-lc-sys 0.30.0` | 0.38.0 | Same runtime provider path | Network timing side channel in AES-CCM tag verification, high attack complexity and high integrity impact. QUIC uses TLS/QUIC AEAD suites rather than the affected EVP CCM interfaces, but the provider package must still be updated. Consolidate at 0.39.0 or later. |
| RUSTSEC-2026-0007 | `bytes 1.6.0` | 1.11.1 | Direct `bytes = "1"` in `moq-transport`, `moq-pub` and `moq-test-client`, plus HTTP/QUIC users; runtime | Memory corruption/undefined behavior after a wrapping `BytesMut::reserve` capacity calculation. Exploitation needs a near-`usize::MAX` reserve and wrapping overflow, but Teremoq processes attacker-influenced network lengths and must not rely on that precondition. The fixed release is non-yanked, MSRV 1.57 and fits every direct `"1"` constraint. |
| RUSTSEC-2026-0204 | `crossbeam-epoch 0.9.18` | 0.9.20 | Optional `metrics-exporter-prometheus 0.16.2` -> `metrics-util 0.19.1`; all-features runtime only | Invalid-pointer dereference occurs when pointer formatting dereferences a null/invalid `Atomic` or `Shared`. No direct local formatting call was found. The fixed release is non-yanked, MSRV 1.61 and fits `metrics-util`'s `^0.9` requirement. The finding disappears only when the optional metrics exporter is absent, not when dev edges are excluded. |
| RUSTSEC-2026-0258 | `h2 0.4.5` | 0.4.16 | `hyper 1.4.1`, reached through direct `axum`, `hyper-serve` and `moq-api`/`reqwest`; runtime HTTP/2 | RustSec calls the issue low severity, but a remote peer can queue unlimited empty DATA frames when streams are not drained, causing unbounded memory or panic. This is relevant to any exposed HTTP/2 control endpoint or outbound peer. `hyper` accepts `h2 ^0.4.2`, so a precise lock update is expected to be API-compatible; MSRV remains 1.63. |
| RUSTSEC-2024-0421 | `idna 0.5.0` | 1.0.0; RustSec recommends 1.0.3 | Direct `url = "2"` in relay/native/API/transport crates; runtime | Punycode labels can compare equal after one implementation's IDNA processing while appearing different elsewhere. Privilege escalation requires hostname comparison in an authorization decision plus DNS/TLS control, but relay URLs and trust boundaries make canonicalization security-relevant. Plan `url >=2.5.4`, which requires `idna ^1.0.3`. This can add IDNA adapter/Unicode-data packages and intentionally tightens malformed-host behavior, so the SBOM and hostname tests must be reviewed. |
| RUSTSEC-2026-0185 | `quinn-proto 0.11.13` | 0.11.15 | `quinn 0.11.9` through `moq-native-ietf` and `web-transport-quinn`; runtime data plane | CVSS 3.1 network, low complexity, high availability impact. A remote peer can create many gaps in out-of-order stream reassembly and exhaust receiver memory. Directly relevant to the UDP QUIC relay. `quinn 0.11.9` accepts `quinn-proto ^0.11.12`; 0.11.15 is non-yanked and MSRV 1.85, but transport behavior and resource limits require focused interoperability and fault tests. |
| RUSTSEC-2026-0037 | `quinn-proto 0.11.13` | 0.11.14 | Same QUINN runtime path | CVSS 4.0 network, low complexity, high availability impact. Invalid QUIC transport parameters can panic an endpoint before application authorization. Directly relevant to every listener. The consolidated QUINN bundle must use at least 0.11.15 because of RUSTSEC-2026-0185. |
| RUSTSEC-2026-0104 | `rustls-webpki 0.102.4` and 0.103.4 | 0.103.13 | 0.102.4: `moq-api` -> `reqwest 0.12.4` -> Rustls 0.22; 0.103.4: Rustls 0.23 paths in native relay, QUINN, Hyper and Redis; runtime | A syntactically valid, unsigned-yet CRL can trigger panic before signature verification. Applications not using CRLs are unaffected, but future private PKI policy can enable CRLs. 0.103.13 fits Rustls 0.23's `^0.103.4`; no fixed 0.102 release exists, so the Rustls 0.22 path must be removed. |
| RUSTSEC-2026-0099 | `rustls-webpki 0.102.4` and 0.103.4 | 0.103.12 | Same two runtime validation paths | A constrained CA can incorrectly authorize a certificate asserting a wildcard outside its permitted DNS subtree. Exploitation requires certificate misissuance after valid signature verification, but this is an identity-boundary failure. Consolidate at 0.103.13 and remove 0.102. |
| RUSTSEC-2026-0098 | `rustls-webpki 0.102.4` and 0.103.4 | 0.103.12 | Same two runtime validation paths | URI name constraints were ignored and accepted. Exploitation requires a signed chain using those constraints. Teremoq's current fixture identities do not use URI SANs, but future SPIFFE-style identities make this relevant. Consolidate at 0.103.13 and remove 0.102. |
| RUSTSEC-2026-0049 | `rustls-webpki 0.102.4` and 0.103.4 | 0.103.10 | Same two runtime validation paths | Faulty distribution-point matching can skip a relevant CRL. With permissive unknown-status policy this can accept a revoked credential; even with the safer default it can cause denial. Consolidate at 0.103.13 and remove 0.102. |
| RUSTSEC-2025-0055 | `tracing-subscriber 0.3.18` | 0.3.20 | Workspace `tracing-subscriber = "0.3"`, directly used by relay and binaries; runtime observability | Attacker-controlled ANSI sequences in logged input can poison terminal output and can compound terminal-emulator flaws. Teremoq logs network-derived peer, namespace and error data, so exposure is plausible even if JSON sinks reduce display effects. 0.3.20 is non-yanked, MSRV 1.65 and fits the existing constraint. |

## Informational soundness and maintenance inventory

These are not to be hidden because RustSec labels them informational. Two are
soundness defects in safe Rust APIs; the other three leave build/runtime paths
without upstream maintenance.

| Advisory | Locked package | Fixed/replacement path | Direct introducer and scope | Condition, compatibility and action |
|---|---|---|---|---|
| RUSTSEC-2026-0190 | `anyhow 1.0.85` | 1.0.103 | Direct `anyhow = "1"` with backtrace in relay/native and tools; runtime | UB requires adding context and later calling `Error::downcast_mut`. No such call was found locally, but safe API unsoundness remains. 1.0.103 is non-yanked, MSRV 1.68 and fits existing manifests. |
| RUSTSEC-2026-0097 | `rand 0.8.5` | 0.8.6 | Direct `rand = "0.8"` in `moq-native-ietf`; runtime, with `thread_rng` used in QUIC setup | UB requires a custom logger that re-enters thread RNG during reseeding with relevant logging enabled. The repository uses tracing and no custom `log` logger was found, but the runtime call exists. 0.8.6 fits the direct constraint. |
| RUSTSEC-2026-0097 | `rand 0.9.2` | 0.9.3 | `quinn-proto ^0.9`/`fastbloom`; runtime | Same re-entrant custom-logger condition. 0.9.3 is non-yanked, MSRV 1.63 and fits both transitive constraints. Keep it a separate precise update from QUINN so the resulting lock delta remains attributable. |
| RUSTSEC-2025-0056 | `adler 1.0.2` | No patched release; use `adler2` | `anyhow` backtrace -> `backtrace 0.3.71` -> `miniz_oxide 0.7.3`; runtime support path | Unmaintained rather than a known exploit. `backtrace 0.3.74` switches to `miniz_oxide ^0.8`, which uses `adler2`; it is non-yanked, MSRV 1.65 and fits Anyhow's `backtrace ^0.3.51` requirement. Confirm the old package leaves the lock. |
| RUSTSEC-2024-0436 | `paste 1.0.15` | No patched release; remove or replace | Direct `paste = "1"` in `moq-transport`; proc-macro/build-time only | The archived proc macro expands two local macro sites. Prefer a small source refactor with explicit identifiers so no replacement dependency is introduced. If `pastey` or another crate is proposed, it needs explicit user approval, provenance/license review and macro-output tests. |
| RUSTSEC-2025-0134 | `rustls-pemfile 2.1.2` | No patched release; use `rustls-pki-types` `PemObject` API available since 1.9 | Direct in `moq-native-ietf`; also retained by `hyper-serve 0.6.2`, old `reqwest` and `rustls-native-certs 0.7`; runtime config parsing | Migrate direct PEM parsing to already present `rustls-pki-types 1.12.0`, move native cert loading to `rustls-native-certs >=0.8`, and use `reqwest >=0.12.16`. The latest cached `hyper-serve` is still 0.6.2 and hard-depends on `rustls-pemfile ^2.1`; complete removal therefore requires replacing or patching that server integration and is a real blocker requiring user decision. |

## Conservative remediation batches

Every implementation batch is owned by `TP-RUST-DIST`. `TP-OSS-SC` reviews
the dependency diff, license, provenance, RustSec result and SBOM before the
batch can be accepted. No batch below is implemented by this plan.

### Batch Q: QUINN transport safety

- Target: `quinn-proto >=0.11.15`, initially through a precise lock update
  compatible with `quinn 0.11.9`.
- Findings: RUSTSEC-2026-0037 and RUSTSEC-2026-0185.
- Probable files: `Cargo.lock` only. If resolution requires changing `quinn`,
  `web-transport-quinn` or their features, stop and return a new scoped design.
- Gates: normal/all-feature trees; QUIC malformed-transport-parameter
  regression; bounded out-of-order reassembly; relay acceptance/rejection;
  draft-16 ALPN and wire invariants; WebTransport/MoQT interoperability;
  slow-client isolation; check, test and clippy for all targets/features;
  RustSec, cargo-deny, REUSE and SBOM delta.
- Rollback: revert only this lock batch and restore the previous lock as a
  temporary known-vulnerable state; do not keep protocol source changes while
  rolling back the patched transport.
- High-impact decision: not required for a lock-only semver-compatible patch.
  Required if the resolver forces a Quinn/WebTransport API, feature, provider,
  draft or wire change.

### Batch U1: core buffer memory safety

- Target: `bytes >=1.11.1` with no unrelated package movement.
- Finding: RUSTSEC-2026-0007.
- Probable files: `Cargo.lock` only; existing direct `bytes = "1"` constraints
  already accept the fixed release.
- Gates: all buffer/varint/frame-size limits; hostile maximum lengths; reserve
  failure without allocation blow-up; MoQT object and HTTP body tests; full
  workspace check/test/clippy; RustSec, license and SBOM diff.
- Rollback: revert the isolated lock delta. Reopening a memory-corruption
  advisory is not an acceptable steady state.
- High-impact decision: no, unless compilation exposes a behavior/API change
  requiring source edits.

### Batch T: Rustls validation and AWS-LC provider

- Targets: `rustls-webpki >=0.103.13`, `aws-lc-rs >=1.16.2` and
  `aws-lc-sys >=0.39.0` for the existing Rustls 0.23 runtime path.
- Findings: RUSTSEC-2026-0045 through -0049 and RUSTSEC-2026-0098,
  -0099 and -0104 for the 0.103 line.
- Probable files: `Cargo.lock` only for the first attempt. Do not combine this
  with provider-feature cleanup or with elimination of Rustls 0.22.
- Gates: exact provider feature tree; no unexpected third provider; explicit
  ring-provider I2 tests; TLS 1.3; client/server certificate chains; mTLS
  positive and negative identity cases; constrained-name and CRL fixtures when
  available; native build on approved Rust 1.93 images; full tests/clippy;
  RustSec, cargo-deny licenses, REUSE and crypto SBOM.
- Rollback: revert the provider/webpki lock batch as one unit and re-open all
  associated advisories; never retain a mixed sys/wrapper pair.
- High-impact decision: yes. Even a semver-compatible AWS-LC C-provider update
  changes security-critical native code. A separate user decision is required
  for disabling AWS-LC defaults or standardizing on ring-only operation.

### Batch H: HTTP, URL and old Rustls path

- Targets: `reqwest >=0.12.16`, `hyper-rustls >=0.27`,
  `tokio-rustls >=0.26`, removal of Rustls 0.22 and
  `rustls-webpki 0.102.4`, `h2 >=0.4.16`, `url >=2.5.4` and
  `idna >=1.0.3`.
- Findings: the four webpki advisories on 0.102.4, RUSTSEC-2026-0258 and
  RUSTSEC-2024-0421. `reqwest 0.12.5` is the first cached release using the
  Rustls 0.23 stack; 0.12.16 is selected because it also drops its direct
  `rustls-pemfile` dependency.
- Probable files: `Cargo.lock`; `moq-api/Cargo.toml` only if a lower bound must
  be made explicit. Do not alter protocol crates in this batch.
- Gates: HTTP/1 and HTTP/2 API behavior; empty-DATA-frame memory bound;
  outbound API client TLS; hostname allow/deny and malformed Punycode cases;
  URL serialization stability; native/public CA verification; proof that
  Rustls 0.22 and webpki 0.102 leave normal and all-feature graphs; package
  verification; full workspace tests/clippy; license and SBOM review for the
  IDNA/Unicode dependency expansion.
- Rollback: revert the HTTP/URL lock batch together; do not restore only the old
  Rustls subgraph while retaining a reqwest version that expects 0.23.
- High-impact decision: no for a tested lock-only update within declared
  0.12/2.x constraints. Required if hostname authorization semantics, public
  API, TLS features or manifest contracts must change.

### Batch U2: observability and optional metrics utilities

- Targets: `tracing-subscriber >=0.3.20` and
  `crossbeam-epoch >=0.9.20`.
- Findings: RUSTSEC-2025-0055 and RUSTSEC-2026-0204.
- Probable files: `Cargo.lock` only.
- Gates: JSON and terminal log escaping with attacker-controlled ANSI input;
  event schema stability; default and `metrics-prometheus` builds; exporter
  scrape/recency/registry behavior; all-target/all-feature tests; RustSec,
  license and normal-versus-optional SBOMs.
- Rollback: each precise update can be reverted independently, but the lock is
  regenerated once per reviewed batch.
- High-impact decision: no unless logging output contracts or metrics source
  APIs require code changes.

### Batch S: soundness-only precise updates

- Targets: `anyhow >=1.0.103`, `rand 0.8.6` and `rand 0.9.3`.
- Findings: RUSTSEC-2026-0190 and both locked applications of
  RUSTSEC-2026-0097.
- Probable files: `Cargo.lock` only.
- Gates: error context/downcast tests, backtrace behavior, QUIC randomness and
  collision tests, tracing/log integration without re-entrant logger behavior,
  complete feature trees, Miri where already supported, RustSec and SBOM.
- Rollback: revert each exact package update if it alone causes regression;
  document that rollback restores an unsound safe-API version.
- High-impact decision: no for precise updates within existing major/minor
  constraints.

### Batch M1: remove the unmaintained Adler path

- Target: `backtrace >=0.3.74` -> `miniz_oxide >=0.8` -> `adler2`, with
  `adler 1.0.2` absent.
- Finding: RUSTSEC-2025-0056.
- Probable files: `Cargo.lock` only; Anyhow already accepts the Backtrace patch
  line.
- Gates: release/debug backtraces, symbolization and error paths; license and
  SBOM review for `adler2`; proof that `adler` leaves all graphs.
- Rollback: revert this isolated transitive chain.
- High-impact decision: no if lock-only.

### Batch M2: remove the archived Paste proc macro

- Target: remove `paste 1.0.15` without adding a replacement when a small
  explicit source refactor can preserve the generated identifiers.
- Finding: RUSTSEC-2024-0436.
- Probable files: `moq-transport/Cargo.toml` and
  `moq-transport/src/serve/track.rs`; `Cargo.lock` regenerated only after source
  review.
- Gates: expanded macro behavior, track serve/read/write APIs, public API and
  semver diff, rustdoc, full transport and relay tests, Rustfmt/clippy, REUSE,
  license and SBOM proof that Paste is absent.
- Rollback: revert source and manifest together, then regenerate the old lock.
- High-impact decision: not required for a no-new-dependency internal refactor.
  Required before adding `pastey` or another third-party replacement.

### Batch M3: remove rustls-pemfile

- Target phase 1: migrate direct native PEM parsing to the existing
  `rustls-pki-types` API, use `rustls-native-certs >=0.8`, and use
  `reqwest >=0.12.16` from Batch H.
- Target phase 2: remove the final transitive edge held by
  `hyper-serve 0.6.2`.
- Finding: RUSTSEC-2025-0134.
- Probable phase-1 files: `moq-native-ietf/Cargo.toml`,
  `moq-native-ietf/src/tls.rs` and `Cargo.lock`. Phase 2 likely touches
  `moq-relay-ietf/Cargo.toml`, `moq-relay-ietf/src/web.rs` and server/TLS tests.
- Gates: PEM certificate chains; PKCS#8, SEC1 and malformed keys; native root
  loading on supported platforms; no trust-store or provider drift; web API
  TLS startup/reload; package verification; mTLS tests; REUSE, licenses and
  normal/all-feature SBOM proof that `rustls-pemfile` is absent.
- Rollback: revert each phase atomically with its manifest/lock. Do not leave
  both old and new parsers active as fallback.
- High-impact decision: yes for phase 2. The cached official index has no
  `hyper-serve` release newer than 0.6.2, and that release directly requires
  `rustls-pemfile ^2.1`. Replacing the server integration, carrying a patch or
  selecting a maintained alternative changes a security-sensitive dependency
  boundary and needs explicit user approval.

## Recommended order

1. Reproduce both audits at the frozen DB and also at the then-current DB.
2. Apply Batch Q first because both QUINN findings are unauthenticated remote
   availability failures on the primary UDP data plane.
3. Apply Batch U1 next because Bytes is pervasive and the finding is memory
   corruption, even though its triggering size is extreme.
4. Apply Batch T under explicit crypto-provider approval.
5. Apply Batch H to remove the second Rustls/webpki line and close HTTP/URL
   findings.
6. Apply Batches U2 and S as independent, low-conflict precise updates.
7. Apply Batch M1, then the source-bearing M2 and M3 migrations. M3 phase 2
   remains blocked until the server-integration decision is made.
8. Regenerate final normal, build, dev and all-feature SBOMs; rerun all release
   gates against the final combined lock without squashing evidence from the
   individual batches.

The order is risk-based, not permission to implement. A newly published
critical advisory supersedes it.

## Parallel work and lock serialization

Security analysis, upstream API review and test design for Q, T, H, U and M
can proceed in parallel because they are read-only. Source preparation for M2
and M3 phase 1 touches different crates and can also proceed independently
after authorization.

Actual dependency resolution cannot proceed in parallel in one checkout:
every batch writes the shared root `Cargo.lock`. One integrator must regenerate
and review the lock sequentially in the recommended order. Batch H and M3 also
overlap around Reqwest/Rustls PEM dependencies and must not edit their
manifests concurrently. Batch Q must finish before any later batch is allowed
to absorb Quinn-related transitive movement.

Each batch should record before/after package sets and reject unrelated lock
drift. Analysis branches may be compared independently; final lock generation
and integration remain serialized.

## Proposed cargo-deny policy plan

The derivative currently has no `deny.toml`; cargo-deny therefore cannot
provide a meaningful project license allowlist. A later authorized governance
change should create a reviewed policy with these properties:

1. Use the official RustSec DB URL and require a recorded commit for release
   evidence. CI also checks the current DB and fails if it is stale.
2. Start with `advisories.ignore = []`. Vulnerable, unsound, unmaintained and
   yanked packages fail the gate for normal, build, dev and all-feature graphs.
3. Permit licenses only after extracting the actual SPDX expressions and
   source/license files from the resolved artifacts. Do not use a blanket
   “all OSI licenses” switch.
4. Scope any license exception to an exact crate/version and reviewed license
   expression. Record provenance, redistribution obligations and the internal
   owner.
5. A future advisory exception, if explicitly authorized, must name the exact
   RustSec ID and affected package/version. Its machine-readable `reason`
   string must contain the owner, expiry date, exploitation analysis,
   compensating control and removal issue. An exception without every field
   fails review. No exception is proposed by this plan.
6. Reject wildcard Git sources, unknown registries and unpinned revisions.
   Keep direct dev dependencies visible rather than excluding them from the
   supply-chain inventory.
7. Run license/advisory checks separately for the default runtime artifact and
   all features, then reconcile them with matching SBOMs. Optional metrics and
   dev-only I2 edges must be labeled rather than silently omitted.

Policy introduction itself needs `TP-OSS-SC` review and a clean baseline. The
configuration must not be used to convert the current red findings to green by
classification alone.

## Common gates for every implementation batch

Run with the approved Rust 1.93.0 environment and locked inputs:

```bash
git diff --check
cargo metadata --locked --format-version=1
cargo tree --locked -p moq-relay-ietf -e normal,build
cargo tree --locked -p moq-relay-ietf -e all
cargo check --locked --workspace --all-targets --all-features
cargo test --locked --workspace --all-targets --all-features
cargo clippy --locked --workspace --all-targets --all-features -- -D warnings
cargo audit --no-fetch --db "$rustsec_db" --file Cargo.lock
cargo deny check licenses advisories
reuse lint
cargo package --locked -p moq-relay-ietf --list
```

Additionally:

- compare the batch lock diff with its declared package allow-set;
- confirm MSRV and Rust 1.93 compatibility from primary package metadata;
- inventory changed build scripts, native code, features and providers;
- update development and release SBOMs with relationship type and feature
  reachability;
- preserve `MIT OR Apache-2.0` for derivative code and every upstream license;
- run redacted secret scanning when fixture/package boundaries move;
- verify no protocol draft, ALPN, wire encoding, runtime Docker, PKI/trust
  material or production configuration changed incidentally; and
- repeat package verification from the produced archive, not only workspace
  compilation.

## Exit criteria

The baseline remediation is complete only when:

- the frozen and current RustSec scans report zero vulnerable entries for the
  resolved lock;
- unsound and unmaintained warnings listed here are eliminated, or a later
  explicitly authorized, owner-bound and unexpired exception is visible and
  machine-checkable;
- cargo-deny licenses and advisories pass under the reviewed project policy;
- default, normal/build, dev and all-feature graphs are documented and their
  SBOMs match the candidate artifacts;
- every batch-specific functional, security, interoperability and rollback
  test passes;
- no affected/yanked version, duplicate obsolete TLS line or unmaintained
  replacement remains unexpectedly in `Cargo.lock`;
- REUSE/SPDX, notices and third-party inventory pass without relicensing; and
- the final diff contains only reviewed manifests/source plus attributable
  lock movement.

No check may be represented as passing when it could not execute.

## Real blockers and decisions

- No fixed `rustls-webpki` 0.102 line exists in the frozen DB. Reqwest's Rustls
  0.22 stack must be removed rather than pinned within 0.102.
- Fixing all four AWS-LC findings requires at least `aws-lc-sys 0.39.0`, which
  in the cached official index first arrives through `aws-lc-rs 1.16.2`.
- `paste` and `rustls-pemfile` have no patched releases; they require removal,
  not a version-only update.
- `hyper-serve 0.6.2` is the latest cached release and directly retains
  `rustls-pemfile`. Complete removal requires an explicit server dependency
  decision.
- IDNA 1.0.3 can expand the Unicode-data dependency graph and changes invalid
  hostname handling by design; authentication and SBOM review are mandatory.
- The shared lock prevents concurrent implementation batches even when source
  analysis is independent.
- A newer advisory DB may add findings or raise the minimum safe versions. The
  frozen commit is reproducibility evidence, not a permanent safety claim.

## Activity confirmation

This plan made no checkout, source, manifest, lockfile, Git configuration,
dependency, exception or remote change. No tool was installed globally. No
email, message, issue, pull request, tag, release, publication, push or remote
mutation was performed.

Document validation passed: repository `git diff --check` exited 0; the
report-specific no-index whitespace check emitted no error; the
case-insensitive whole-word unfinished-marker scan found zero matches; all 20
expected RustSec IDs are present; and both reviewed I2 manifest/lock hashes
remained unchanged. The report is an untracked local artifact awaiting Master
review and was not added to the index.

**REMEDIATION PLAN ONLY / NO DEPENDENCY CHANGE / NO REMOTE MUTATION**
