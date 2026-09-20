# I1 local review: connection-bound verified peer evidence

- Status: **LOCAL ONLY / NOT PUSHED / NOT COMMITTED**
- Review snapshot: 2026-08-26T21:32:07Z
- Owner: `TP-RUST-DIST`
- Required identity/privacy reviewer: `TP-SEC-PKI`
- Scope: I1 in `moq-native-ietf` only
- I2/C1/C2: not started

## Baseline and local boundary

The separate local checkout remains on branch
`teremoq/i1-peer-evidence-bf87128`. Its `HEAD` is still the approved upstream
baseline commit `bf87128affd316463e5dcc7599a45001f222b6de`, with tree
`d76319009e815fb8923e21fc8319e17a0aaf8174`. I1 exists only as unstaged working
tree content. The local branch has no upstream/tracking branch and no commit
beyond the baseline. The only cached remote branch is the approved baseline.

No push, pull request, issue, Discussion, release, tag, remote ref, repository
setting or maintainer communication was created or changed. The active Teremoq
dependency pins were not changed.

## Finding and API implemented for review

The baseline supports an additive, source-compatible I1 path without a new
dependency, feature, wire value or crypto backend. The implementation obtains
`quinn::Connection::peer_identity()` only after the same `quinn::Connection`
has completed its handshake and before that connection is moved into either
the WebTransport or raw-QUIC session.

The proposed local API is:

- `VerifiedPeerEvidence`: owns the rustls chain as
  `Arc<[CertificateDer<'static>]>`; the deliberately named `certificates()`
  accessor exposes opaque DER to the embedder without interpretation;
- `PeerEvidence`: distinguishes `Absent` from `Rustls(...)`;
- `PeerEvidenceError`: distinguishes an empty rustls chain from an unexpected
  dynamic crypto-backend type using fixed, non-sensitive messages;
- `AcceptedSession`: privately owns the accepted session, existing `ConnInfo`
  and `Result<PeerEvidence, PeerEvidenceError>`, with borrow accessors and an
  explicit consuming `into_parts()`;
- `Server::accept_with_peer_evidence()`: additive acceptance path returning
  `AcceptedSession`; and
- `Server::accept()`: retains its exact public signature and delegates to the
  new path while deliberately discarding evidence for legacy callers.

No certificate is parsed into SPIFFE, principal, role or authorization policy.
There is no global/task-local/thread-local correlation and no use of IP, SNI,
path or connection tags as identity. I2 required authorization remains a
separate, unimplemented gate.

`VerifiedPeerEvidence`, `PeerEvidence` and `PeerEvidenceError` compile as
`Send + Sync`; `AcceptedSession` compiles as `Send` for ownership transfer into
a Tokio task. Evidence and session state are owned, with no borrowed handshake
lifetime.

## Redaction review

`VerifiedPeerEvidence`, `PeerEvidence` and `AcceptedSession` have manual fixed
`Debug` output. Neither certificate bytes nor chain length are formatted.
`PeerEvidenceError` has fixed manual `Debug` and `Display` text and does not
include the dynamic type name. No I1 code passes evidence to tracing, errors,
metrics, qlog, mlog, HTTP/WebTransport metadata, query strings or MoQT.

The real-connection test checks exact redacted strings. Test command output was
also inspected: it contains test names and pass/fail state only, with no DER,
PEM, subject, SAN, serial, certificate length or complete identity.

## Tests and results

The integration tests use actual QUINN 0.11.9 and rustls 0.23.31 handshakes over
the existing `moq-native-ietf` endpoint. They do not send arbitrary UDP as a
handshake. Fixed DER fixtures provide a deliberately public test CA, one server
and two client identities. Test keys are non-production, are documented as
public, and have individual REUSE sidecars under `MIT OR Apache-2.0`.

| Gate | Result |
|---|---|
| Public derivative live verifier before work | pass; exact repository, baseline commit/tree and license |
| Preliminary `cargo check --locked -p moq-native-ietf` | pass |
| `cargo test --locked -p moq-native-ietf` | pass; 4 unit + 5 integration + 0 doctests, zero failures |
| `cargo test --locked -p moq-native-ietf --test peer_evidence` | pass; 5/5 |
| `cargo clippy --locked --no-deps -p moq-native-ietf -- -D warnings` | pass |
| Additional clippy with `--tests` | pass |
| `rustfmt --check` limited to both I1 Rust files | pass |
| `cargo fmt --all -- --check` | expected baseline failure only: the two previously recorded diffs in `moq-transport/src/serve/subgroup.rs:934` and `serve/tracks.rs:304` |
| `git diff --check` plus no-index checks for new text files | pass |

Coverage includes:

1. no client certificate produces explicit `PeerEvidence::Absent`;
2. an unexpected dynamic identity type produces the fixed typed error;
3. an empty rustls chain produces a distinct fixed typed error;
4. a verified client chain is returned over both raw QUIC and WebTransport;
5. two concurrent real mTLS connections retain the certificate matching each
   connection's distinct socket without cross-contamination;
6. legacy `Server::accept()` retains its tuple shape and raw-QUIC result;
7. manual `Debug`, fixed errors, `Send`/`Sync`, `moqt-16` and draft-16 constant
   regressions; and
8. existing unit coverage, including the socket-wrapper path.

The unexpected dynamic type is tested at the typed extractor boundary. A real
rustls connection always returns the documented rustls type; adding a second
QUINN crypto backend solely to create a different `Any` value would violate the
single-stack and no-dependency boundary.

## Toolchain and fixture tooling

- official `rust:1.93.0` image at digest
  `sha256:776861219cd851131c1cec3bbd7cbeb16b99a794048097eb69ad9682a8ed0d57`;
- `rustc 1.93.0` commit `254b59607d4417e9dffbc307138ae5c86280fe4c`;
- Cargo 1.93.0 commit `083ac5135f967fd9dc906ab057a2315861c7a80d`;
- rustfmt 1.8.0-stable and clippy 0.1.93 for that exact toolchain, installed
  only inside disposable containers;
- Rust components: `MIT OR Apache-2.0`; and
- OpenSSL 3.5.5, Apache-2.0, used once locally to generate the fixed public
  DER test fixtures; OpenSSL is not a build or test dependency.

## Delta audit

Only `moq-native-ietf/src/quic.rs` and new content under
`moq-native-ietf/tests/` differ locally. Workspace `Cargo.toml`, `Cargo.lock`,
all three relevant crate manifests, root `REUSE.toml`, both upstream license
texts and `moq-transport/src/setup/mod.rs` are byte-identical to the baseline.
No feature, crate, `unsafe`, wire frame, draft, ALPN, setup, Track, Group or
Object implementation changed. `moq-transport` and `moq-relay-ietf` are
untouched.

The source and generated test material retain `MIT OR Apache-2.0`; upstream
license and notice objects remain unchanged. The fixed test fixture SHA-256
inventory is recorded beside the fixtures.

The known full-workspace E0308 test compile failure and two formatting diffs
belong to the unchanged baseline. They were not corrected or mixed into I1.

## Review gate

`TP-SEC-PKI` must review evidence ownership, the public certificate accessor,
the three-state result, fixed redaction, test-only public keys and the absence of
policy/fallback before any commit is authorized. The Master must then choose
one of: request I1 adjustments, authorize a local signed I1 commit plus the
pre-publication exact-ref inventory update, or reject the API. No commit or
remote action follows automatically, and I2/C1/C2 remain unauthorized.

## Second iteration and local-commit gate — 2026-08-27

This append-only section supersedes the API description and review gate above
for the corrected second iteration; it does not erase the first implementation
or its initial rejection. `TP-SEC-PKI` recorded **APPROVE FOR LOCAL COMMIT** in
`i1-tp-sec-pki-review-2026-08.md` after confirming that all four findings were
closed.

The corrected API uses a lifetime-stable opt-in acceptor:

- a clean `Server` can be consumed by `Server::with_peer_evidence()` to obtain
  a separate `PeerEvidenceServer` with its own pending set;
- legacy `Server::accept()` keeps its original return type and its capture mode
  never invokes `Connection::peer_identity()`;
- `PeerEvidenceServer::accept()` returns
  `Option<Result<AcceptedSession, PeerEvidenceError>>`;
- `AcceptedSession` contains a successfully converted `PeerEvidence`, never an
  evidence error; an extraction error drops the established connection before
  WebTransport/raw-QUIC application session creation and exposes no session
  handle; and
- `VerifiedPeerEvidence` and `PeerEvidence` are not `Clone`; certificate access
  is borrowed and manual `Debug` implementations remain fully redacted.

The non-blocking reviewer note was also corrected without changing semantics:
the `AcceptanceAlreadyStarted` variant now documents that legacy acceptance
has been polled even when no connection future is pending.

The completed second-iteration validation immediately preceding approval used
the official `rust:1.93.0` image at the pinned digest already recorded above:

| Gate | Result |
|---|---|
| Focused `peer_evidence` integration test | pass; 6/6 |
| `cargo test --locked -p moq-native-ietf` | pass; 7 unit + 6 integration + 0 doctests |
| `cargo clippy --locked --no-deps -p moq-native-ietf --tests -- -D warnings` | pass |
| Focused rustfmt check for the two I1 Rust files | pass |
| Full workspace rustfmt check | expected baseline exit `1`; only the recorded `subgroup.rs:934` and `tracks.rs:304` diffs |
| `git diff --check` and no-index checks for new files | pass |
| Protected manifest, lock, setup/wire, REUSE and license hashes | byte-identical to baseline |

At `2026-08-27T19:00:37Z`, the mandatory pre-commit identity/privacy gate found
no effective Git author or committer name and no effective email in the local
clone. A DCO sign-off therefore cannot be generated. No identity was invented
and no local or global Git configuration was changed. In accordance with the
Master's stop condition, the validation suite was not repeated after the final
documentation-only comment adjustment, no paths were staged and no commit was
created.

Current state remains **LOCAL ONLY / NOT PUSHED / NOT COMMITTED**. I1 source and
tests remain unstaged for review. The Master must provide or authorize use of a
pre-existing contribution identity whose email is intended for public DCO
records; configuration of that identity is a separate privacy decision. I2,
C1, C2, product pins and every remote action remain unauthorized.

## Local commit closure — 2026-08-27

At `2026-08-27T19:08:37Z`, the Master explicitly authorized the public
contribution identity and closure of I1 as one local commit. The identity was
written only to this derivative clone's local Git configuration. Global Git
configuration was not changed.

Commit evidence:

- commit: `05b41127ecbd48de4c59fe1626c43b1e423c33a9`;
- tree: `eca64a72e148482fb82b963edc2f2c9af28803f2`;
- sole parent: `bf87128affd316463e5dcc7599a45001f222b6de`;
- subject: `feat(native-ietf): expose verified peer evidence`;
- author and committer: the exact public identity authorized by the Master;
- DCO trailer:
  `Signed-off-by: Jose María <12586102+jimbomilk@users.noreply.github.com>`;
- cryptographic commit signature: not added; none was configured or required;
- branch: `teremoq/i1-peer-evidence-bf87128`, with no upstream/tracking branch;
  and
- state: clean working tree and index after the commit.

The commit contains exactly 17 paths: `moq-native-ietf/src/quic.rs`,
`moq-native-ietf/tests/peer_evidence.rs`, the test fixture README, seven fixed
DER fixtures and their seven REUSE sidecars. It contains no build output,
report, manifest, lockfile, feature, product pin or file outside
`moq-native-ietf`.

Post-commit validation used the same official Rust 1.93.0 image and pinned
digest recorded above:

| Gate | Result |
|---|---|
| `cargo test --locked -p moq-native-ietf` | pass; 7 unit + 6 integration + 0 doctests |
| `cargo clippy --locked --no-deps -p moq-native-ietf --tests -- -D warnings` | pass |
| Focused rustfmt check for `quic.rs` and `peer_evidence.rs` | pass |
| `git diff --check HEAD^ HEAD` | pass |
| Exact file-set, sole-parent, author/committer and DCO assertions | pass |
| Fixture SHA-256 inventory and all seven REUSE sidecars | pass |
| Focused private-path, external-IP, common-secret and sensitive-output scan | pass; only documented loopback/wildcard test addresses exist |
| Manifest, lock, feature, setup/wire, REUSE and upstream-license delta | none |

The previously fixed Gitleaks executable/image was not present in the current
environment, so it was not replaced with an unpinned tool and was not rerun.
The prior second-iteration Gitleaks result remains recorded in the independent
`TP-SEC-PKI` review; the focused post-commit scans above found no secret or
private/product identity material.

Final state for this phase is **LOCAL COMMIT ONLY / NOT PUSHED**. No tracking
branch, tag, release, pull request, issue or remote mutation was created. I2,
C1, C2 and product dependency pins remain unchanged and unauthorized.
