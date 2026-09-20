# Official upstream discovery — 2026-08-26

## Decision

**Route B: the complete contracts remain absent.** The fixed Teremoq revision is
still the official `main` head:
[`bf87128affd316463e5dcc7599a45001f222b6de`](https://github.com/cloudflare/moq-rs/commit/bf87128affd316463e5dcc7599a45001f222b6de).
The result was reproduced with:

```text
git ls-remote https://github.com/cloudflare/moq-rs refs/heads/main refs/heads/draft-18-dev
bf87128affd316463e5dcc7599a45001f222b6de refs/heads/main
5a3e5ffe833f00df6e39277b7b1258dd907fc036 refs/heads/draft-18-dev
```

The development branch is not a release and is not used to claim compatibility.
At current `main`, verified peer evidence is not carried out of the native QUIC
accept path, `resolve_scope` receives only a client-controlled path, transport
handshakes and relay sessions are accumulated without independent admission
caps, and shutdown has no bounded cancel-and-drain contract. Because any missing
contract forces Route B, partial facilities are not an adoption route.

## Release and revision baseline

| Component | Latest relevant official release inspected | Immutable target | Published | Conclusion |
|---|---|---|---|---|
| `moq-native-ietf` | [`v0.10.0`](https://github.com/cloudflare/moq-rs/releases/tag/moq-native-ietf-v0.10.0) | tag object `14a2c60185dafda51cb1ed1a6af226c2cd7a0b7a`, commit `ebb757a558511cdbcce628c5c0aec49729ec41bf` | 2026-07-20 | Older than current `main`; no complete authenticated-evidence or pending-handshake contract. |
| `moq-transport` | [`v0.16.1`](https://github.com/cloudflare/moq-rs/releases/tag/moq-transport-v0.16.1) | tag object `f6a3a3460678c6ba65c06cee6aecc3f27f518f25`, commit `dda6bb40ff8f15fb6cce9cf9773cafcd51ef7b73` | 2026-07-31 | Draft-16 transport release; no relay admission/identity context contract. |
| `moq-relay-ietf` | [`v0.7.25`](https://github.com/cloudflare/moq-rs/releases/tag/moq-relay-ietf-v0.7.25) | tag object `38b20e810a0aa30a80bbe97ef007d18555555f50`, commit `dda6bb40ff8f15fb6cce9cf9773cafcd51ef7b73` | 2026-07-31 | Older than current `main`; no complete authorization-before-scope or session-cap contract. |
| Current `main` | no newer release used for adoption | `bf87128affd316463e5dcc7599a45001f222b6de` | commit 2026-08-18; checked 2026-08-26 | Still missing at least one required contract in each blocker. |

Annotated tags were dereferenced through the official GitHub Git API. All
`moq-rs` code inspected declares `MIT OR Apache-2.0` via SPDX. No code was copied
or vendored.

## Exact current symbols and gaps

### Authenticated evidence and authorization

- [`moq-native-ietf/src/quic.rs`, `ConnInfo` and `Server::accept`](https://github.com/cloudflare/moq-rs/blob/bf87128affd316463e5dcc7599a45001f222b6de/moq-native-ietf/src/quic.rs#L372-L438)
  expose connection ID, transport, socket address, local IP, and SNI, but no
  verified peer identity.
- [`Server::accept_session`](https://github.com/cloudflare/moq-rs/blob/bf87128affd316463e5dcc7599a45001f222b6de/moq-native-ietf/src/quic.rs#L434-L525)
  establishes QUIC and then enters WebTransport or raw QUIC without calling
  `quinn::Connection::peer_identity()`.
- [`CoordinatorContext`](https://github.com/cloudflare/moq-rs/blob/bf87128affd316463e5dcc7599a45001f222b6de/moq-relay-ietf/src/coordinator.rs#L300-L341)
  carries interface and an optional peer derived from the inbound socket address;
  it does not carry authenticated connection evidence.
- [`Coordinator::resolve_scope`](https://github.com/cloudflare/moq-rs/blob/bf87128affd316463e5dcc7599a45001f222b6de/moq-relay-ietf/src/coordinator.rs#L415-L487)
  receives only the WebTransport URL or CLIENT_SETUP path. Its default maps a
  present path to `ReadWrite`, while no path is unscoped and allows both sides.
- [`Relay::run`](https://github.com/cloudflare/moq-rs/blob/bf87128affd316463e5dcc7599a45001f222b6de/moq-relay-ietf/src/relay.rs#L312-L448)
  completes the MoQT setup before `resolve_scope`, derives internal peer identity
  from address-based tagging, and only then constructs Producer/Consumer state.
  This ordering cannot enforce authentication before scope/session state.
- [`ConnectionMeta` and `ConnectionTagger`](https://github.com/cloudflare/moq-rs/blob/bf87128affd316463e5dcc7599a45001f222b6de/moq-relay-ietf/src/session.rs#L34-L170)
  intentionally use address, local IP, SNI, and path. These signals may classify
  an interface but cannot be an authenticated principal.

### Bounded admission and lifecycle

- [`Server::accept`](https://github.com/cloudflare/moq-rs/blob/bf87128affd316463e5dcc7599a45001f222b6de/moq-native-ietf/src/quic.rs#L403-L432)
  receives `quinn::Incoming` and unconditionally pushes `accept_session` into a
  private `FuturesUnordered`; no cap or immediate refusal exists.
- [`accept_session`](https://github.com/cloudflare/moq-rs/blob/bf87128affd316463e5dcc7599a45001f222b6de/moq-native-ietf/src/quic.rs#L434-L525)
  calls `Incoming::accept()`/`accept_with()` and waits for QUIC/TLS plus
  WebTransport SETTINGS/CONNECT without an absolute handshake-phase deadline.
  The configured QUIC idle timeout is not such a deadline.
- [`Relay::run`](https://github.com/cloudflare/moq-rs/blob/bf87128affd316463e5dcc7599a45001f222b6de/moq-relay-ietf/src/relay.rs#L278-L470)
  immediately requeues endpoint acceptance and pushes every established
  connection into another `FuturesUnordered`. The active-connection gauge is
  observation, not admission; there is no global relay session cap.
- The run loop owns accept/session futures privately and exposes no coordinated
  shutdown API with a monotonic drain deadline and postcondition that gauges are
  zero.

### Wording correction returned to and completed by the Task 04 owner

The original Task 04 wording described acquiring a permit before accepting an
`Incoming`. The incidence was returned to its owning Task, and Task 04 corrected
its current proposal. The corrected QUINN 0.11.11 sequence is:

1. await `Endpoint::accept()` to obtain `quinn::Incoming`;
2. attempt the admission permit immediately;
3. on success, call `Incoming::accept()` or `accept_with()`; on saturation,
   consume the `Incoming` through `refuse()` or, when legal and configured,
   `retry()`.

The corrected Task 04 document now uses this order explicitly. No product or
Task 04 source was modified by this submission-package correction.

## Related official issues and pull requests

The following official GitHub searches were checked on 2026-08-26, across open
and closed items:

- [identity/authentication issue search](https://github.com/cloudflare/moq-rs/issues?q=is%3Aissue+%28peer_identity+OR+%22client+certificate%22+OR+mTLS+OR+%22authenticated+identity%22+OR+principal+OR+authorization+OR+CoordinatorContext+OR+resolve_scope%29)
- [identity/authentication PR search](https://github.com/cloudflare/moq-rs/issues?q=is%3Apr+%28peer_identity+OR+%22client+certificate%22+OR+mTLS+OR+%22authenticated+identity%22+OR+principal+OR+authorization+OR+CoordinatorContext+OR+resolve_scope%29)
- [admission/limit issue search](https://github.com/cloudflare/moq-rs/issues?q=is%3Aissue+%28max_pending_handshakes+OR+%22handshake+timeout%22+OR+%22Incoming%3A%3Aretry%22+OR+%22Incoming%3A%3Arefuse%22+OR+admission+OR+%22max+connections%22+OR+%22session+limit%22+OR+FuturesUnordered+OR+shutdown+OR+%22connection+metrics%22%29)
- [admission/limit PR search](https://github.com/cloudflare/moq-rs/issues?q=is%3Apr+%28max_pending_handshakes+OR+%22handshake+timeout%22+OR+%22Incoming%3A%3Aretry%22+OR+%22Incoming%3A%3Arefuse%22+OR+admission+OR+%22max+connections%22+OR+%22session+limit%22+OR+FuturesUnordered+OR+shutdown+OR+%22connection+metrics%22%29)

No item found by those searches supplies the two complete contracts. The related
items are:

| Item | Status and relevance |
|---|---|
| [PR #145, path plumbing and scope](https://github.com/cloudflare/moq-rs/pull/145) | Merged 2026-03-27 as `f0962bfb1f01fa54e4b91c6bba098d0e35318eab`. It added `Transport`, connection path plumbing, `Coordinator::resolve_scope`, and scope permissions. It explicitly defaults path scopes to `ReadWrite`; it does not authenticate a TLS client. It demonstrates that maintainers accept focused cross-crate API work and documented breaking trait changes. |
| [PR #170, draft-16 migration](https://github.com/cloudflare/moq-rs/pull/170) | Merged 2026-07-08 as `e53dbe6fbf6aa6eff9a779cf32cb1e134856a70b`. It is relevant to wire-regression coverage, not to client identity or admission. |
| [PR #156, subgroup/track tests](https://github.com/cloudflare/moq-rs/pull/156) | Merged 2026-08-18 as current HEAD `bf87128affd316463e5dcc7599a45001f222b6de`. It adds transport tests, not either required contract. |
| [Issue #172, expired interop relay certificate](https://github.com/cloudflare/moq-rs/issues/172) | Open since 2026-06-02; server-certificate operational incident. It does not expose or authorize verified client certificates. |

The repository's [`.github` tree at the reviewed commit](https://github.com/cloudflare/moq-rs/tree/bf87128affd316463e5dcc7599a45001f222b6de/.github)
contains workflows and an image, but no issue/PR templates. No repository-local
`CONTRIBUTING.md` or compatibility policy was found at this commit. The GitHub
issues UI states that issue creation is restricted. Therefore this package must
not assume an outsider can open either draft as an issue; the maintainers must
first identify an accepted design channel.

## QUINN and rustls contracts actually available

Teremoq's resolved dependency graph uses QUINN 0.11.11 and rustls 0.23.43.

- [QUINN 0.11.11 `Connection::peer_identity`](https://docs.rs/quinn/0.11.11/quinn/struct.Connection.html#method.peer_identity)
  returns `Option<Box<dyn Any>>`; for the default rustls session the value can be
  downcast to `Vec<rustls::pki_types::CertificateDer>`. It is connection-bound
  cryptographic evidence and is only read after the connection is established.
- [QUINN 0.11.11 `Endpoint::accept`](https://docs.rs/quinn/0.11.11/quinn/struct.Endpoint.html#method.accept)
  yields an `Incoming`; there is no object on which to acquire/refuse before that
  yield.
- [QUINN 0.11.11 `Incoming`](https://docs.rs/quinn/0.11.11/quinn/struct.Incoming.html)
  provides `accept`, `accept_with`, `refuse`, and `retry`. `retry` is fallible for
  an already validated incoming connection, so it must be policy-controlled and
  used only when applicable.
- [rustls 0.23.43 `WebPkiClientVerifier`](https://docs.rs/rustls/0.23.43/rustls/server/struct.WebPkiClientVerifier.html)
  is the official client-certificate verification facility; verification policy
  remains in server TLS configuration. Extracting a chain after the completed
  handshake must not be represented as a second verification step.

QUINN declares `MIT OR Apache-2.0`. rustls declares
`Apache-2.0 OR ISC OR MIT`. These are existing resolved dependencies; the
proposal adds no crate or feature.

## Wire and compatibility conclusion

Current `main` and the relevant releases use MoQT draft-16. The native endpoint
advertises both `web_transport_quinn::ALPN` and `moq_transport::setup::ALPN`, and
supports WebTransport and raw QUIC. Both proposed contracts are local API and
lifecycle behavior only: they must not add certificate/principal/role data to
MoQT, HTTP headers, query parameters, or setup frames, and must retain draft-16,
both ALPN routes, and MoQT Object behavior.

## Local blocker evidence reviewed

The latest combined hostile report,
`chaos/federation/reports/hostile-combined-20260826T123557Z-seed-20260826.md`,
records a finite passing run but explicitly reports both relay handshake and
session capacity as `unenforced`, a truly pending QUIC/TLS handshake as
`untestable_with_pinned_public_api`, and pending handshake/relay task counts as
unobservable. Its media case is video-only and states that the run is not proof
of a production bound or leak freedom. This supports the concurrency blocker; it
does not establish capacity.

The current mTLS tests prove rustls/QUINN certificate rejection and successful
MoQT setup for trusted peers. The federation concurrency test likewise labels
itself finite progress/isolation rather than a capacity proof and records
unauthorized SPIFFE policy as unavailable until the authorization blocker is
resolved. These are Task 03/04 findings to preserve, not gaps repaired by this
document package.

## Source register

All entries were consulted on 2026-08-26. “Repository license” means the license
of code/content being evaluated; GitHub status/search metadata itself has no
software license assertion.

| Primary source | Exact version | License | Conclusion |
|---|---|---|---|
| [`moq-rs` commit](https://github.com/cloudflare/moq-rs/commit/bf87128affd316463e5dcc7599a45001f222b6de) and [README](https://github.com/cloudflare/moq-rs/blob/bf87128affd316463e5dcc7599a45001f222b6de/README.md) | `bf87128affd316463e5dcc7599a45001f222b6de` | MIT OR Apache-2.0 | Official current main, draft-16, WebTransport/raw QUIC; relay described for testing/development rather than production optimization. |
| [`quic.rs`](https://github.com/cloudflare/moq-rs/blob/bf87128affd316463e5dcc7599a45001f222b6de/moq-native-ietf/src/quic.rs) | same commit | MIT OR Apache-2.0 | No peer evidence, cap, or absolute handshake deadline. |
| [`coordinator.rs`](https://github.com/cloudflare/moq-rs/blob/bf87128affd316463e5dcc7599a45001f222b6de/moq-relay-ietf/src/coordinator.rs) | same commit | MIT OR Apache-2.0 | Path-based scope/permissions, no authenticated principal before scope. |
| [`session.rs`](https://github.com/cloudflare/moq-rs/blob/bf87128affd316463e5dcc7599a45001f222b6de/moq-relay-ietf/src/session.rs) | same commit | MIT OR Apache-2.0 | Tagging is non-cryptographic metadata and cannot be promoted to identity. |
| [`relay.rs`](https://github.com/cloudflare/moq-rs/blob/bf87128affd316463e5dcc7599a45001f222b6de/moq-relay-ietf/src/relay.rs) | same commit | MIT OR Apache-2.0 | Unbounded task collection, late scope resolution, no bounded shutdown. |
| [Official releases](https://github.com/cloudflare/moq-rs/releases) and the three tag pages above | exact tag objects/commits listed above | MIT OR Apache-2.0 | No newer released API closes the gaps. |
| [Official issues](https://github.com/cloudflare/moq-rs/issues) and [pull requests](https://github.com/cloudflare/moq-rs/pulls) | state observed 2026-08-26 | repository code MIT OR Apache-2.0; metadata N/A | Searches and related items do not close the gaps; issue creation is restricted. |
| [QUINN 0.11.11 API](https://docs.rs/quinn/0.11.11/quinn/) | `0.11.11` | MIT OR Apache-2.0 | Supplies connection identity and immediate Incoming disposition primitives. |
| [rustls 0.23.43 API](https://docs.rs/rustls/0.23.43/rustls/) | `0.23.43` | Apache-2.0 OR ISC OR MIT | Supplies configured client-certificate verification; policy remains with embedder/server config. |

## Reproducibility and workspace state

Read-only discovery used Git 2.53.0 (GPL-2.0-only), curl 8.18.0 (curl license),
and ripgrep 15.2.0 (MIT OR Unlicense); nothing was installed. Git metadata is
present at the workspace root. Current status contains the pre-existing Task 04
wording correction in `gateway-rs/upstream/moq-rs-concurrency-limits-proposal.md`
plus this untracked `gateway-rs/upstream/submissions/` directory. This Task 05
correction edited only the submissions directory, and `git diff --check` reports
no errors. Manifests, lockfile, policy, dependency documentation, code, examples,
tests, PKI, and ADRs remain outside its edit scope.
