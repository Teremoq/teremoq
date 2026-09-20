# Draft issue: expose verified peer evidence to relay authorization before scope resolution

> **NOT SUBMITTED.** Copy-ready design draft for maintainer review. The API names
> below are illustrative and have not been compiled.

## Problem

At
[`bf87128affd316463e5dcc7599a45001f222b6de`](https://github.com/cloudflare/moq-rs/commit/bf87128affd316463e5dcc7599a45001f222b6de),
the server can be configured through QUINN/rustls to verify a client
certificate, but the verified evidence does not reach relay authorization:

- [`moq-native-ietf::quic::Server::accept_session`](https://github.com/cloudflare/moq-rs/blob/bf87128affd316463e5dcc7599a45001f222b6de/moq-native-ietf/src/quic.rs#L434-L525)
  establishes a `quinn::Connection` but does not read
  [`Connection::peer_identity()`](https://docs.rs/quinn/0.11.11/quinn/struct.Connection.html#method.peer_identity).
- [`quic::ConnInfo`](https://github.com/cloudflare/moq-rs/blob/bf87128affd316463e5dcc7599a45001f222b6de/moq-native-ietf/src/quic.rs#L372-L401)
  contains socket/SNI metadata only.
- [`Coordinator::resolve_scope`](https://github.com/cloudflare/moq-rs/blob/bf87128affd316463e5dcc7599a45001f222b6de/moq-relay-ietf/src/coordinator.rs#L451-L487)
  receives a connection path and defaults it to read/write scope permissions.
- [`ConnectionTagger`](https://github.com/cloudflare/moq-rs/blob/bf87128affd316463e5dcc7599a45001f222b6de/moq-relay-ietf/src/session.rs#L145-L170)
  can classify address, local IP, SNI, and path, but none is cryptographic client
  identity.

A minimal reproduction is a server with a rustls client-certificate verifier and
two clients presenting different valid certificates. Both complete TLS, yet the
relay hook that resolves scope cannot distinguish their verified evidence. An
embedder must either authorize client-controlled metadata or replace the native
accept/relay path.

This affects any embedder that needs mTLS identity for per-namespace access. It
is not a request for `moq-rs` to define certificate naming, SPIFFE, roles, or
site policy.

## Required invariant

```text
verified certificate -> authenticated principal -> role -> operation -> exact namespace
```

Transport verification and application authorization are separate decisions.
A valid certificate with no matching authorization must receive no namespace
access.

## Proposed minimum contract

### 1. Capture connection-bound evidence after the handshake

After `Connecting` resolves to an established `quinn::Connection`, read
`Connection::peer_identity()` from that same connection. With the current rustls
backend, downcast the documented dynamic value to
`Vec<rustls::pki_types::CertificateDer<'static>>`. Keep owned evidence bound to
the accepted connection/session; return an explicit error for an unexpected
dynamic type in required mode.

Do not use a global map, connection ID correlation, task-local state, or
thread-local callbacks. Do not serialize this evidence into MoQT, HTTP headers,
queries, or setup parameters.

An additive native API could avoid changing the public fields of `ConnInfo`:

```rust
// Illustrative only; names and error types are open to maintainer preference.
#[non_exhaustive]
pub struct VerifiedPeerEvidence {
    certificates: Arc<[CertificateDer<'static>]>,
}

impl fmt::Debug for VerifiedPeerEvidence {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("VerifiedPeerEvidence")
            .field("present", &true)
            .finish_non_exhaustive()
    }
}

#[non_exhaustive]
pub struct AcceptedSession {
    pub session: web_transport::Session,
    pub info: ConnInfo,
    pub peer: Option<VerifiedPeerEvidence>,
}

impl Server {
    pub async fn accept_with_peer_evidence(&mut self)
        -> Option<anyhow::Result<AcceptedSession>>;
}
```

`Server::accept()` can retain its current source behavior by delegating and
discarding evidence. The new return type should be `#[non_exhaustive]`, expose
certificate bytes only through a deliberately named accessor, and implement a
manual redacted `Debug`. DER, PEM, subject, SAN, serial number, complete
principal, and roles must never be emitted by library events or formatting.

### 2. Add a required relay path without weakening legacy users

The relay needs an embedder hook before `Coordinator::resolve_scope` and before
Producer, Consumer, or namespace state is created. The hook should keep policy
outside `moq-rs` and support per-operation authorization. To keep the hook
object-safe, `AuthenticatedSession` is an upstream-owned concrete wrapper around
an embedder-owned, type-erased context:

```rust
// Illustrative only; names and error types are open to maintainer preference.
use std::{any::Any, fmt, sync::Arc};

#[derive(Clone)]
pub struct AuthenticatedSession {
    context: Arc<dyn Any + Send + Sync + 'static>,
}

impl AuthenticatedSession {
    pub fn new<T>(context: T) -> Self
    where
        T: Any + Send + Sync + 'static,
    {
        Self {
            context: Arc::new(context),
        }
    }

    pub fn downcast_ref<T>(&self) -> Option<&T>
    where
        T: Any + Send + Sync + 'static,
    {
        self.context.as_ref().downcast_ref::<T>()
    }
}

impl fmt::Debug for AuthenticatedSession {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("AuthenticatedSession(<redacted>)")
    }
}

#[async_trait]
pub trait SessionAuthorizer: Send + Sync + 'static {
    async fn authenticate(
        &self,
        peer: &VerifiedPeerEvidence,
    ) -> Result<AuthenticatedSession, AuthorizationError>;

    async fn resolve_scope(
        &self,
        session: &AuthenticatedSession,
        path: Option<&str>,
    ) -> Result<Option<ScopeInfo>, AuthorizationError>;

    async fn authorize(
        &self,
        session: &AuthenticatedSession,
        operation: Operation,
        namespace: &TrackNamespace,
    ) -> Result<(), AuthorizationError>;
}

#[non_exhaustive]
pub enum Operation {
    Publish,
    Subscribe,
    RelayPeer,
}

impl Relay {
    pub fn new_required(
        config: RelayConfig,
        authorizer: Arc<dyn SessionAuthorizer>,
    ) -> anyhow::Result<Self>;
}
```

The private field prevents accidental access outside the explicit constructor
and downcast API. `AuthenticatedSession::new` accepts only owned
`Send + Sync + 'static` values, and `downcast_ref` returns `None` on a type
mismatch. An authorizer must convert that mismatch into a denial/error; required
mode must not substitute an empty context or retry with legacy policy. Neither
method requires the embedder value to implement `Debug`, and the manual wrapper
implementation never formats the dynamic value, its type name, principal, or
roles.

The generic methods are inherent methods on the concrete wrapper, not methods on
`SessionAuthorizer`. The trait has no associated type or generic method, so its
receiver and concrete argument/return types remain usable behind
`Arc<dyn SessionAuthorizer>`. Cloning `AuthenticatedSession` only clones its
internal `Arc`; it does not clone or expose the embedder value. The relay carries
that connection-specific wrapper across tasks and passes references back to the
same authorizer for scope and operation checks.

`new_required` must be unambiguously fail-closed:

- absent evidence, empty certificate chain, unexpected identity type,
  authentication error, scope error, or authorization error rejects the session
  or operation;
- no fallback to path, SNI, IP address, or `ConnectionTagger` is permitted;
- exact-namespace authorization occurs before registration, lookup, forwarding,
  or other namespace mutation for `Publish`, `Subscribe`, and `RelayPeer`;
- the authenticated context is available before scope resolution and is carried
  with that one session across tasks without cross-connection sharing.

The existing `Relay::new` may remain legacy for source compatibility. A new
explicit `Relay::new_legacy`/builder spelling could make intent auditable while
the old constructor delegates to it. A startup warning should only fire when an
insecure combination is detectable, such as client-certificate verification
configured while the legacy relay path discards evidence; a blanket warning for
all unauthenticated public relays would be misleading.

The embedder decides the concrete context stored in `AuthenticatedSession` and
performs the checked downcast inside its authorizer implementation. `moq-rs`
owns only the wrapper and transports it to hooks; it does not inspect the value,
interpret SPIFFE, map certificate fields to principals, assign roles, or decide
policy.

## Ordering

1. Establish QUIC/TLS successfully.
2. Obtain verified evidence from that `quinn::Connection`.
3. In required mode, authenticate it into an opaque session context.
4. Resolve scope using authenticated context plus path.
5. Before every namespace-affecting action, authorize `(role, operation,
   exact namespace)`.
6. Only then create or mutate the relevant namespace state.

WebTransport CONNECT and raw QUIC select transport in the existing native path;
neither changes the identity source or sends identity on the wire.

## Alternatives rejected

- **IP address, SNI, URL/CLIENT_SETUP path, or `ConnectionTagger` as principal:**
  these are routing/classification inputs and are not verified client identity.
- **Parsing identity in rustls verification callbacks and correlating globally:**
  callback ordering and connection correlation are unnecessary because QUINN
  already binds peer identity to `Connection`.
- **Putting principal/roles in MoQT or WebTransport metadata:** changes trust and
  wire semantics and lets a peer assert authorization state.
- **Implementing SPIFFE or role policy in `moq-rs`:** too deployment-specific;
  the upstream contract only carries verified evidence and invokes hooks.
- **Treating successful certificate validation as authorization:** conflates two
  independent decisions and grants access to any trusted certificate.
- **Adding public fields directly to `ConnInfo` or `RelayConfig`:** breaks
  external struct literals and exhaustive patterns.
- **Making `SessionAuthorizer` generic through an associated context type:**
  this would prevent direct use as `Arc<dyn SessionAuthorizer>` and force
  `Relay`, its builders, or another boundary to become generic or add a second
  erasure layer. That larger source/semver surface is not the primary proposal;
  the concrete upstream wrapper keeps the existing relay type non-generic.

## Compatibility and semver

- Additive methods and new `#[non_exhaustive]` types can be a minor release if
  current signatures and public structs remain unchanged.
- Adding a field to `ConnInfo`, `RelayConfig`, or another constructible public
  struct is source-breaking. Adding a required method to `Coordinator` is also
  source-breaking. A companion authorizer trait avoids both.
- Rust does not promise a stable ABI for these crates; binary compatibility is
  not an upstream contract to rely on. Recompilation remains required.
- No new crate, Cargo feature, TLS backend, or wire parameter is needed.
- `AuthenticatedSession` is a new concrete additive type. Its private storage,
  inherent generic constructor/downcast, and manual `Debug` do not change the
  object safety of `SessionAuthorizer` or the type of `Relay`.
- Legacy behavior remains available only through a clearly documented path;
  names containing `required` must never fall back to legacy behavior.
- Draft-16, the existing raw-QUIC and WebTransport ALPNs, both transport routes,
  and MoQT Object behavior must remain byte-for-byte unaffected.

## Proposed tests

1. required mode rejects an absent client certificate before `resolve_scope`;
2. required mode rejects an unexpected `peer_identity()` dynamic type;
3. a valid certificate whose principal has no role is denied all namespaces;
4. scope failure creates no Producer, Consumer, registration, or lookup state;
5. publish, subscribe, and relay-peer are each checked against the exact
   namespace before state mutation;
6. two concurrent peers with different certificate chains never see each
   other's opaque authenticated context;
7. legacy construction preserves current behavior and required construction has
   no fallback;
8. WebTransport and raw QUIC both receive connection-bound evidence after their
   QUIC/TLS handshake without wire changes;
9. ALPN and draft-16 setup/Objects regressions remain covered;
10. errors, tracing events, metrics, and every `Debug` implementation contain no
    DER, PEM, subject, SAN, serial, full principal, or roles;
11. an `AuthenticatedSession` context downcast to the wrong embedder type returns
    `None`, is converted to a denial, and never falls back or panics.

Tests should configure the real QUINN/rustls server and generate distinct test
chains in test fixtures. They should not mock certificate identity at the relay
boundary for the end-to-end cases.

## Questions for maintainers

1. Would maintainers prefer an additive `AcceptedSession` return path or a new
   accessor on another connection/session-owned type?
2. Should the relay hook be a companion `SessionAuthorizer`, an authenticated
   variant of `Coordinator`, or another existing extension point?
3. Do maintainers prefer the proposed upstream-owned type-erased
   `AuthenticatedSession` wrapper, which preserves
   `Arc<dyn SessionAuthorizer>`, or a generic relay/authorizer with an associated
   context type and the resulting public type/semver changes?
4. Is preserving `Relay::new` as legacy and adding `new_required` acceptable, or
   should a builder become the only new API?
5. Which application error/code should represent authentication and
   authorization rejection on WebTransport and raw QUIC?
6. Given restricted issue creation, where should this design be discussed before
   a pull request is prepared?

This draft makes no production-readiness claim. It proposes a contract and tests;
it does not demonstrate deployed policy, operational capacity, or security.
