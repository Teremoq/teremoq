<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# TP-RUST-DIST owner preflight: future `gateway-rs` derivative pin

Date: 2026-08-28

Owner: `TP-RUST-DIST`

Required reviewers: `TP-SEC-PKI`, `TP-PLATFORM-CHAOS`, `TP-OSS-SC`

Scope: isolated local product candidate; no product integration, commit,
publication, push, fetch, release, issue, pull request, or remote mutation

State: **CHANGES REQUIRED**

## Findings first

### High — the exact derivative commit is not published and the final Git pin is not reproducible yet

The candidate targets the immutable commit
`89cb1798644c32aef06cc625f097cd9acb203417`, tree
`cccd0d60c9ebfe191dca9d73e7ab8b27ae4d4ea5`, at the public repository URL
`https://github.com/Teremoq/moq-rs-teremoq`. The commit exists only in the
reviewed local derivative checkout, whose branch is clean and has no tracking
branch. This task did not publish it or contact any remote.

The successful build used local `path` dependencies as a controlled API and
resolution oracle. The patch contains the future full-revision Git pin, but
Cargo cannot validate that Git source while the object is unpublished. The
predicted Git lock must therefore be regenerated and compared after an
explicitly authorized publication. A local path is not the final dependency
solution.

### High — the candidate demonstrates the required API ordering but does not implement Teremoq identity policy

The private relay example now rejects absent or malformed peer evidence and
uses required authorization, but its laboratory `PublishOnlyAuthorizer` maps
any non-empty rustls-verified client certificate chain to an opaque
`VerifiedFederatedPublisher` marker. It does not parse a SPIFFE URI, derive a
product principal or role, or restrict a publisher to a namespace derived from
that identity.

This is intentionally only an API-composition proof. A valid certificate is
not sufficient production authorization. No X.509 parser or other new
dependency was added because none was authorized. Before product integration,
`TP-SEC-PKI` must review a maintained parser and the exact fail-closed mapping:

`verified certificate -> authenticated principal -> role -> operation -> exact namespace`

The product policy must reject absent, malformed, ambiguous, multiple, or
foreign-trust-domain identities and must never derive identity from IP, SNI,
path, `ConnInfo`, or `ConnectionTagger`. It must retain only the minimal
principal/role context, never DER, PEM, subject, SAN, serial, or fingerprint.

### Medium — two product behavior decisions remain open

The example uses validated nonzero C1/C2 constants to exercise the APIs, but
the final product needs owned configuration and startup validation for separate
handshake, inbound-session, outbound-session, and shutdown limits.

The former legacy builder selected a 5-second cache idle timeout. The required
bounded builder currently uses the derivative default of 30 seconds. The
Master must either accept and document that behavior or authorize a small
additive upstream API that accepts the cache timeout; falling back to the
legacy builder is not acceptable.

The product N+1 test proves immediate close, zero second authentication, and
zero application effect for both raw QUIC and WebTransport. It does not itself
decode and assert the public close code `0x3` and fixed reason
`relay session capacity reached`; that exact wire assertion exists in the
reviewed derivative tests and should be repeated at product level before the
pin is accepted.

### Medium — publication and supply-chain gates remain visible

The derivative's own lock still has the 16 recorded RustSec vulnerability
entries and six warning entries. The consumer lock resolves later compatible
versions and reports zero vulnerabilities plus two existing unmaintained
warnings. These are separate gates; the clean consumer result does not make the
derivative publication-ready. Batch T remains explicitly absent and
unauthorized.

The future product change must also update authoritative third-party notices,
rerun the public derivative verifier and package inventory, and obtain a fresh
independent supply-chain review from the committed product tree. This
laboratory patch does not claim those publication outputs.

### Informational — one failed build was a harness-capacity failure, not a code failure

The first full test target was placed on a small temporary filesystem and
exhausted its capacity during linking. No candidate test had failed. The target
was moved to an external filesystem, the complete suite passed, and all
task-owned target files and temporary containers were removed.

## Frozen inputs and isolation

| Input | Verified value |
| --- | --- |
| `.cursorrules` SHA-256 | `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2` |
| product `Cargo.toml` SHA-256 | `1caa40574d12ebb4aa9cd03cc30d32f75edd8e9572e6d4876238f491c6e3f3de` |
| product `Cargo.lock` SHA-256 | `dd6ee5615630d788a351c4e3b395de0851fee41b34177823393d35d23a894316` |
| product `DEPENDENCIES.md` SHA-256 | `79c18078e22af74a4d3da682198b958337d0e018ec15d30c0d1617c877b1a535` |
| product `deny.toml` SHA-256 | `0059c35bc6e588cf99fe4b93025c4c767f3233fcbe67c4ec34a2a02c0212e2a3` |
| derivative commit | `89cb1798644c32aef06cc625f097cd9acb203417` |
| derivative tree | `cccd0d60c9ebfe191dca9d73e7ab8b27ae4d4ea5` |
| derivative `Cargo.lock` SHA-256 | `d6196fd8f31ea3b2cabbdb0e57546810643f344567f3e358ee3c000b3e2b59f5` |
| derivative status | clean; no upstream/tracking branch |

`.cursorrules` and ADR-0004 through ADR-0007 were read completely. Their
constraints on authenticated identity, fail-closed authorization, separate
admission domains, bounded shutdown, controlled public derivation,
Zero-Transcoding, and non-production claims remain binding.

The isolated laboratory was created from the frozen `gateway-rs` snapshot with
`.git`, `.teremoq-dev`, `target`, caches, Python bytecode, and runtime material
excluded. The initial 140-file inventory matched the product snapshot with
SHA-256
`da1487e5b92f63b05c3e29175cefa36c2710a3dc805864dfcfc6689f17b71d2c`.
The accidental first copy traversal into an unreadable runtime directory was
discarded before use; only the fresh excluded copy became the laboratory.

The authoritative product files listed above were rehashed after all work and
remain byte-identical. The derivative checkout also remains clean and exact.

## Final API mapping and laboratory composition

The candidate uses the actual reviewed APIs rather than illustrative proposal
snippets:

1. **C1 native admission:** `ServerAdmissionConfig::new` and
   `Endpoint::new_bounded` configure nonzero QUINN buffered-incoming and
   pending-handshake limits, immediate `Refuse`, and one absolute handshake /
   WebTransport CONNECT deadline. Admission occurs after `Incoming` exists and
   before `Incoming::accept`; its RAII permit ends before session lifetime.
2. **I1 peer evidence:** the bounded endpoint is consumed by the relay's stable
   evidence-aware acceptor. `VerifiedPeerEvidence` comes from the same
   established QUINN connection after handshake and is passed by borrow. The
   legacy accept path is not mixed into that server lifetime.
3. **C2 relay admission:** `build_required_bounded` applies independent inbound
   and outbound relay-global limits before authentication, MoQT setup, scope,
   coordinator, Producer, Consumer, registration, lookup, namespace state, or
   session task. N+1 is rejected immediately without a capacity waiter.
4. **I2 required authorization:** an object-safe `Arc<dyn SessionAuthorizer>`
   derives an upstream-owned `AuthenticatedSession`, treats
   `RequestedConnectionPath` only as a requested resource, accepts only the
   canonical `/publish` path, and authorizes only exact publish operations for
   namespace `teremoq/live`. Subscribe, relay-peer, other paths, other
   namespaces, and future operation variants fail closed.
5. **Owned shutdown:** `BoundedRelay::run_until` consumes a
   `CancellationToken`, stops both admission domains and returns a bounded
   report. The test requires inbound/outbound active and inflight gauges plus
   the C1 pending-handshake gauge to be zero after completion.

The dev example has one explicit bounded endpoint (`RelayConfig.bind = None`),
required mode, `mlog_dir = None`, and separate nonzero limits. The existing
browser/legacy laboratory remains separately named and is not represented as
authenticated or bounded.

The product-owned composition test uses real rustls/QUINN with the existing
synthetic PKI and executes both `moqt://` raw QUIC and `https://`
WebTransport. Independent policy and coordinator probes demonstrate this
ordering:

`C1 -> connection-bound I1 -> C2 -> I2 authenticate -> canonical path -> exact namespace operation -> first registration effect`

It observes exactly one authentication and zero legacy coordinator-scope
calls. With one live session retained, N+1 is closed before a second
authentication or application effect. A single absolute 15-second watchdog is
shared by each route; there are no sleeps.

No source implements certificate parsing, SPIFFE policy, a second endpoint or
transport stack, transcoding, wire serialization of identity, protocol changes,
or sensitive logging.

## Candidate patch and exact delta

The reproducible patch is:

`gateway-rs/upstream/mirror/reviews/product-pin-owner-candidate-2026-08.patch`

Patch SHA-256:
`03efa820f025ce378e2870d90d8af6e6c8a7384548f3b14fc7dd42d2471e3bab`

`git apply --check` succeeds against the frozen product snapshot. The patch has
574 insertions and 58 deletions across exactly seven paths:

1. `gateway-rs/Cargo.toml`;
2. `gateway-rs/Cargo.lock`;
3. `gateway-rs/DEPENDENCIES.md`;
4. `gateway-rs/deny.toml`;
5. `gateway-rs/examples/dev_mtls_moq_relay.rs`;
6. `gateway-rs/tests/federation_concurrency.rs`;
7. `gateway-rs/tests/moq_derivative_contracts.rs` (new).

There are no changes to runtime crates beyond the atomic dependency source
pin, no new crate or feature, no provider change, and no product PKI, Docker,
frontend, protocol, fixture, or Chaos change. Candidate file whitespace checks
pass; the patch itself contains ordinary unified-diff context lines and is
validated through `git apply --check` plus per-file no-index checks.

Final candidate file hashes:

| File | SHA-256 |
| --- | --- |
| `Cargo.toml` | `cbfe53220c13fcd45871090c2fb819e7bd686b171fd1f581ddd1c8f43e210100` |
| `Cargo.lock` | `6b49ed06266b739bbbc201b86abac19e220319b2223a0e2436e805cec2af7db4` |
| `DEPENDENCIES.md` | `27a7d57eba82d529acfe15720a2af0335de38051cf0318001d33732b19b520fc` |
| `deny.toml` | `ef51f8041d90d6d375ec5d65a5723886acbe22c930a34c9fed6ab28b88dc1f53` |
| `examples/dev_mtls_moq_relay.rs` | `7c72f3531e1a17f729675d0ee200a6206dc0acbd159f8ab958e96eaf51a29c99` |
| `tests/federation_concurrency.rs` | `58f8cc3e550fea00468e282ce2347a55213a7fa54335dc168377aec2357e2b1b` |
| `tests/moq_derivative_contracts.rs` | `f13cd533adcd1dc838631ddcfa8debc42c6a4f95d81c522c0da4cd97436c5a86` |

## Dependency and lock evidence

The reproducible path-mode `Cargo.lock` has SHA-256
`857889695a109c4315a3f1ea42ab530a3bd6b39e7d6920299c825579c60e4f9b`.
It contains the same 375 package records as the current product lock. The only
semantic differences are removal of the Git `source` field for the three
direct MoQ crates and transitive `moq-api`; versions, checksums, dependency
arrays, features, providers, and every other record are identical.

The final candidate converts those four records to:

`git+https://github.com/Teremoq/moq-rs-teremoq?rev=89cb1798644c32aef06cc625f097cd9acb203417#89cb1798644c32aef06cc625f097cd9acb203417`

It preserves 375 records and changes only the `source` field of:

- `moq-api 0.2.13`;
- `moq-native-ietf 0.10.0`;
- `moq-relay-ietf 0.7.25`;
- `moq-transport 0.16.1`.

The predicted final lock SHA-256 is
`6b49ed06266b739bbbc201b86abac19e220319b2223a0e2436e805cec2af7db4`.
This is an exact structural prediction from the validated path resolution, not
a claim that Cargo fetched the unpublished commit. The exact Teremoq repository
URL replaces the Cloudflare allow-list entry in `deny.toml`; there is no
wildcard, branch pin, abbreviated revision, or second MoQ checkout.

## Validation results

All Rust gates used Rust/Cargo 1.93.0, `--locked --offline`, `--network none`,
read-only source/caches during final execution, an external target, and an outer
watchdog. No dependency or component was downloaded or installed.

| Command or gate | Result |
| --- | --- |
| two independent `cargo generate-lockfile --offline` path resolutions | PASS; identical lock SHA |
| `cargo metadata --locked --offline --format-version 1 --no-deps` | PASS |
| semantic TOML comparison of current/path/future locks | PASS; 375 records, four source-only changes |
| `cargo fmt --all -- --check` | PASS |
| `cargo check --locked --offline --all-targets` | PASS |
| `cargo clippy --locked --offline --no-deps --all-targets -- -D warnings` | PASS |
| `cargo test --locked --offline` | PASS: 65 passed, 1 intentionally ignored, 0 failed |
| ignored hostile test executed explicitly with bounded duration | PASS: 1/1 |
| raw QUIC + WebTransport required/bounded composition test | PASS: 1 test, both routes |
| federation concurrency | PASS: 6 admitted; 2 completed; 4 transport errors; 0 timeout/cancel; pending gauge zero |
| `git apply --check` against the frozen product snapshot | PASS |
| per-file `git diff --no-index --check` | PASS; content exit only, no whitespace diagnostics |
| Gitleaks on candidate patch and owner report | PASS: zero findings |
| `cargo deny check licenses bans sources` on path resolution | PASS; no errors |
| fixed-database `cargo audit` on consumer lock | PASS: zero vulnerabilities; two unmaintained warnings |
| REUSE authoritative Teremoq and derivative roots | PASS |

Full product test accounting was: library 49, federation 2, media 4,
derivative-contract 1, relay interop 2 plus one ignored hostile case, mTLS 8,
and doctests 0. The explicitly executed hostile case retained draft-16,
ALPN `moqt-16`, nonzero Object delivery, recovery, and the existing
Zero-Transcoding media topology. It did not use external network access.

The two consumer warnings remain:

- `RUSTSEC-2024-0436` for `paste 1.0.15`;
- `RUSTSEC-2025-0134` for `rustls-pemfile 2.2.0`.

The derivative's 16 vulnerability entries and six warnings remain recorded as
a separate publication gate. Gitleaks over the complete copied review corpus
also identified four existing 64-hex review digests as generic-key-shaped data;
manual redacted classification confirmed they are hashes, not credentials. No
suppression was added.

## Hermetic tools

| Tool | Fixed evidence | License / role |
| --- | --- | --- |
| Rust build image | `teremoq-step7-lab:rust-1.93-full@sha256:ba076cf0a26aa41efdd2f0f80687ef97009d1526680751456c19cc944dff1d0b` | official Rust/container components; Rust/Cargo 1.93.0 and GStreamer 1.22 |
| rustfmt/Clippy image | `teremoq-local-rust193-components:c2-review-20260828@sha256:f522c28d5beb21591f46e8c165030f70b32dd5b51107577ad196910e7147a007` | Rust toolchain components; rustfmt 1.8.0, Clippy 0.1.93 |
| Gitleaks | `8.30.1`, image digest `sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f` | MIT; redacted secret scanning |
| cargo-audit | `0.22.2`, binary SHA-256 `507532dd8397f11d89cb2859964300519a8f6e34d2064792339774cfb9a6d27b` | MIT OR Apache-2.0; fixed official RustSec database |
| cargo-deny | `0.20.2`, binary SHA-256 `d76b81738fd7394334ea63e2ac5d5d55c7a78919ce62e7738a32a53eb900143c` | MIT OR Apache-2.0; license/source policy |
| REUSE | `5.1.1`, image digest `sha256:11eb8a423ea82776bc2890bb255b61736bec277ef6e2141f8c91d6d88864f9da` | Apache-2.0; SPDX/REUSE validation |

The cargo-audit cache was inspected read-only. Its normal Git locking operation
cannot run against a read-only Cargo home, so no Git configuration or cache was
changed; the fixed-database audit result was obtained with the already reviewed
database snapshot. No global tool was installed.

## Protocol, privacy, and compatibility invariants

- MoQT draft-16, raw QUIC ALPN `moqt-16`, WebTransport, MoQT Objects, and the
  existing four-track topology are unchanged.
- No transcoder, codec, second endpoint implementation, TLS stack, provider,
  wire field, header, query parameter, or identity serialization was added.
- `PeerEvidence` remains tied to and borrowed from the established connection.
- The authenticated context is upstream-owned/type-erased and has redacted
  `Debug`; the test policy stores no certificate material.
- Required-mode authorization precedes scope/state/effect; C1/C2 capacity never
  grants identity or authorization.
- Legacy paths remain explicit and are not described as safe, bounded, or
  Zero-Trust.
- No production key, certificate, identity, path, IP, URL credential, token, or
  secret was copied into the candidate or report.

Passing this laboratory matrix does not resolve Zero-Trust, make concurrency or
memory globally bounded, prove DoS resistance, establish external MoQT
conformance, or make the relay production/commercially ready.

## Cleanup, DCO, and required Master decision

All task-owned build targets, evidence scratch directories, Python bytecode,
temporary files, and containers were removed. The laboratory contains no
`target/`, cache, runtime PKI, or `.teremoq-dev` state. The product and
derivative bindings remain unchanged.

No commit was created, so DCO is not yet applicable. A future product commit
must be created only after review and must use `git commit --signoff` with the
authorized public contribution identity. This report and the patch do not
substitute for that trailer.

The Master must choose one of these concrete next actions:

1. **Request the required adjustments:** authorize selection and review of a
   maintained X.509/SPIFFE parser and exact Teremoq principal/role/namespace
   policy; decide the 5-second versus 30-second cache behavior; make limits
   product-configurable; and add the exact product-level N+1 close assertion.
   This is the recommended action while the state is `CHANGES REQUIRED`.
2. **Explicitly narrow the candidate to a non-production API demonstration:**
   accept that identity policy remains unresolved and separately authorize
   publication of exactly commit
   `89cb1798644c32aef06cc625f097cd9acb203417` to the controlled public
   derivative. Publication must be followed by read-only commit/tree/ref
   verification, Cargo regeneration of the Git lock, notice/package updates,
   and new formal reviews before applying this patch.

Neither option authorizes this task to publish, push, apply the patch, edit the
product, or begin any further integration automatically.
