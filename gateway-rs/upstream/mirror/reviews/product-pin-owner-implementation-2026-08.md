<!-- SPDX-License-Identifier: Apache-2.0 -->

# Product identity, authorization and cache implementation owner review

Date: 2026-08-28

Owner: `TP-RUST-DIST`

Required security reviewer: `TP-SEC-PKI`

Status: **LOCAL COMMITS ONLY / NOT PUSHED / PUBLICATION BLOCKED**

## Findings

1. No code or commit was published. The derivative cache commit and the product
   commit are local, clean and have no tracking branch. Consequently the Git pin
   in the product commit is intentionally not consumable from GitHub until the
   Master separately authorizes publication of the derivative commit.
2. The authorized identity contract is implemented fail-closed. Only the leaf
   from connection-bound `VerifiedPeerEvidence` is parsed after rustls has
   completed verification. The chain is bounded to 8 certificates, the leaf to
   16 KiB and the total to 64 KiB before parsing.
3. The initial authorization policy accepts only
   `spiffe://teremoq.local/gateway/gateway-dev-1` and only `Publish` or
   `PublishNamespace` on the exact `teremoq/live` namespace. Relay peers,
   subscribe/discovery/track-status operations and every other identity are
   default-deny.
4. The required-bounded relay now has an additive cache-timeout constructor.
   Existing APIs retain the upstream 30-second default; the product calls the
   new API with exactly 5 seconds. Local and remote cache controllers receive
   the same explicit value.
5. No autoscaling work was started. There is no second transport, parser,
   transcode path or protocol encoding. MoQT draft-16, ALPN, Objects and
   Zero-Transcoding remain unchanged.

## Binding inputs

- `.cursorrules` SHA-256:
  `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2`.
- `TP-SEC-PKI` decision SHA-256:
  `6cd115983ec128213e4dcdb717af1c6c3035a00924d55605d05e5767afec9979`.
- `TP-PLATFORM-CHAOS` cache decision SHA-256:
  `9717c2e3e5125178c4aab5b0f4752792f5362341a4f214cde1aa0aec87cea137`.
- `TP-OSS-SC` parser decision SHA-256:
  `a67ff5bb3cb83b20478d7ee31042bccb3ec6be5cf181856c5d95a454453adb9b`.
- Integrated derivative base:
  `89cb1798644c32aef06cc625f097cd9acb203417`.

## Local commits and DCO

### Derivative cache API

- Branch: `codex/required-cache-ttl-89cb179` (no tracking).
- Commit: `4b50958c121edfa2d6778c0586b30a78ee3e6f83`.
- Tree: `c0668647d8d2d6836320bc9662fe8ae717192795`.
- Parent: `89cb1798644c32aef06cc625f097cd9acb203417`.
- Subject: `feat(relay): configure required cache timeout`.
- Author and committer: `Jose María
  <12586102+jimbomilk@users.noreply.github.com>`.
- DCO: exact `Signed-off-by` for the same identity.
- Paths:
  - `moq-relay-ietf/src/i2_tests.rs`;
  - `moq-relay-ietf/src/local.rs`;
  - `moq-relay-ietf/src/relay.rs`;
  - `moq-relay-ietf/src/remote.rs`.
- `Cargo.lock` remains byte-identical at
  `d6196fd8f31ea3b2cabbdb0e57546810643f344567f3e358ee3c000b3e2b59f5`.

### Product policy and pin candidate

- Branch: `codex/product-pin-auth-cache-local` (no tracking).
- Commit: `c719b84a11f3cdb185012d2a98633891a2d651d3`.
- Tree: `d0dd60264853b4308c5c74bd8ccae12041a00bb1`.
- Parent: `0faee5dec127e47649a08b82bade8f3faf69c8ab`.
- Subject: `feat(gateway): enforce federated identity policy`.
- Author and committer: `Jose María
  <12586102+jimbomilk@users.noreply.github.com>`.
- DCO: exact `Signed-off-by` for the same identity.
- Exact pathset:
  - `gateway-rs/Cargo.lock`;
  - `gateway-rs/Cargo.toml`;
  - `gateway-rs/DEPENDENCIES.md`;
  - `gateway-rs/deny.toml`;
  - `gateway-rs/examples/dev_mtls_moq_relay.rs`;
  - `gateway-rs/src/security/federated_identity.rs`;
  - `gateway-rs/src/security/mod.rs`;
  - `gateway-rs/tests/federation_concurrency.rs`;
  - `gateway-rs/tests/moq_derivative_contracts.rs`;
  - `gateway-rs/tests/support/pki.rs`.
- Pathset SHA-256 (ordered relative paths):
  `4863b4f78ef1a9bed99d1525b27a5abce5d74b5010827c5a08cad402a491035b`.
- Commit patch SHA-256:
  `aaf4a9dd8e25b21a44bbd881f6580c9a460d4b69de19d0f6dc2e4e6abfcf26bf`.
- Clean status SHA-256:
  `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.

## Dependency and lock evidence

`x509-parser` is declared exactly as:

```toml
x509-parser = { version = "=0.18.1", default-features = false }
```

- crates.io checksum:
  `d43b0f71ce057da06bc0851b23ee24f3f86190b07203dd8f567d0b706a185202`.
- VCS commit from `.cargo_vcs_info.json`:
  `33b15d2db5a19b15c17bb15fa57b08691316ee95`.
- License expression: `MIT OR Apache-2.0`.
- `LICENSE-MIT` SHA-256:
  `a5c61b93b6ee1d104af9920cf020ff3c7efe818e31fe562c72261847a728f513`.
- `LICENSE-APACHE` SHA-256:
  `a60eea817514531668d7e00765731449fe14d059d3249e0bc93b36de45f759f2`.
- Declared MSRV: Rust 1.67.1; crate source forbids unsafe code.
- Feature tree: direct `gateway-rs -> x509-parser`; neither `verify` nor
  `verify-aws` is activated.

The path-based validation lock and the final Git-pin lock contain the same 375
package records. They differ only in the four approved source fields for
`moq-api`, `moq-native-ietf`, `moq-relay-ietf` and `moq-transport`. The final
product lock SHA-256 is
`e1bc83a0d2f68ddcd05af9b22187cff6d90746ca1587ed3b4618f65cbe442e50`.

## Identity and authorization ordering

The product authorizer follows:

```text
C1 handshake admission
  -> I1 connection-bound verified evidence
  -> C2 session admission
  -> bounded leaf/SAN extraction
  -> minimal authenticated principal
  -> canonical requested path
  -> exact operation + namespace authorization
  -> scope/state/effect
```

The parser does not revalidate trust, signatures, validity or EKU. It requires
complete DER consumption, a unique SAN extension and exactly one canonical URI.
The retained context contains only role and node id; manual `Debug` is fully
redacted and parser errors are mapped to fixed low-cardinality values.

## Cache API

The derivative adds:

- `RelayConfig::build_required_bounded_with_cache_idle_timeout`;
- `Relay::new_required_bounded_with_cache_idle_timeout`.

The previous required-bounded constructors still select 30 seconds. The new
product call supplies `Duration::from_secs(5)`. Unit probes demonstrate that the
same duration is installed in both local and remote cache owners. Admission,
shutdown, queue bounds and the immediate N+1 rejection path are otherwise
unchanged.

## Validation

Toolchain and environment:

- Rust/Cargo `1.93.0` in local image
  `teremoq-step7-lab:rust-1.93-full@sha256:ba076cf0a26aa41efdd2f0f80687ef97009d1526680751456c19cc944dff1d0b`;
- Clippy/rustfmt 1.93.0 copied ephemerally from already audited image
  `sha256:f522c28d5beb21591f46e8c165030f70b32dd5b51107577ad196910e7147a007`;
- every Cargo run used `--locked --offline` and Docker `--network none`;
- source dependencies were read-only and build output used an external target.

Results:

- derivative focal cache test: PASS (1/1);
- `cargo test --locked -p moq-relay-ietf`: PASS (176 lib, 16 bin,
  10 integration; doctests 1 pass and 1 ignored);
- derivative Clippy `--tests -- -D warnings`: PASS;
- product identity unit tests: PASS (6/6), including chain/leaf/total limits,
  malformed DER, SAN ambiguity, strict URI grammar, default-deny and redaction;
- product composition tests: PASS (2/2), each over raw QUIC and WebTransport,
  including verified-but-unauthorized denial before scope and N/N+1 capacity;
- `cargo check --locked --offline --all-targets`: PASS;
- product Clippy `--all-targets -- -D warnings`: PASS;
- `cargo fmt --all -- --check`: PASS;
- complete product tests before the final operation-enum-only refinement: PASS:
  55 library, 2 federation concurrency, 4 media, 2 derivative-contract,
  2 relay interop; 1 hostile harness test remained intentionally ignored;
  8 mTLS tests; doc-tests PASS. After that typing-only refinement the final
  snapshot repeated the 6 identity tests, both raw/WT composition tests and
  Clippy over all targets: PASS;
- Zero-Transcoding/media regression: PASS (4/4);
- `cargo-deny 0.20.2` licenses/bans/sources: PASS; existing duplicate-version
  warnings and a path-lab unmatched-source warning are non-fatal;
- `cargo-audit 0.22.2` with frozen local database: zero vulnerabilities and two
  existing unmaintained warnings (`RUSTSEC-2024-0436`,
  `RUSTSEC-2025-0134`), neither introduced by `x509-parser`;
- Gitleaks `8.30.1` (MIT), image digest
  `sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f`:
  PASS, no leaks;
- `git diff-tree --check` for both commits: PASS;
- both worktrees: clean and without upstream/tracking branches.

The path-validation laboratory, both external Cargo targets, the ephemeral Cargo
home and the temporary Clippy/rustfmt Docker volume were removed after the
evidence was captured. No source-side `target` directory or temporary container
remains. These were disposable build artifacts; the two Git commits retain the
recoverable implementation state.

## Residual gates

- The derivative commit must not be pushed until the Master authorizes its
  publication. Until then the product Git pin cannot be fetched by a clean
  builder; path dependencies were used only in the isolated validation lab and
  do not appear in either commit.
- `TP-SEC-PKI` must review the final parser/policy snapshot before publication.
- Supply-chain review must confirm the direct inventory and final lock before
  product integration.
- These local commits do not claim production readiness, Zero-Trust completion,
  DoS resistance or autoscaling readiness.

No push, fetch, tag, release, issue, PR, email, message or remote mutation was
performed.
