# Proposal: expose authenticated peer identity to relay authorization

Status: draft for maintainer discussion; not filed upstream.

Target reviewed: Cloudflare `moq-rs`
`bf87128affd316463e5dcc7599a45001f222b6de` (2026-08-18), with
`moq-native-ietf 0.10.0`, `moq-transport 0.16.1`, and
`moq-relay-ietf 0.7.25`. License: MIT OR Apache-2.0.

## Problem

The relay can require and validate a client certificate through rustls, but the
verified peer identity is discarded before authorization:

- QUINN 0.11.11 exposes `Connection::peer_identity()` after the handshake. For
  the rustls session, it can be downcast to `Vec<CertificateDer>`.
- `moq-native-ietf::quic::Server::accept_session` owns the established
  `quinn::Connection`, but `ConnInfo` only retains CID, transport, remote
  address, local IP, and SNI.
- `moq-relay-ietf::ConnectionMeta` adds path, but no authenticated identity.
- `Coordinator::resolve_scope` receives only the path. `CoordinatorContext`
  derives an internal source from the inbound socket address.

Consequently, an embedder cannot safely implement certificate-bound
authorization for publish, subscribe, or relay-peer operations without copying
the relay accept loop or forking the crates. IP, SNI, and path are useful routing
metadata but are not an authenticated client principal.

## Goals

1. Preserve the current QUINN endpoint and WebTransport/raw-QUIC integration.
2. Preserve MoQT draft-16, its ALPN, and all current wire behavior.
3. Make rustls-authenticated peer evidence available before scope/permission
   resolution and before Producer or Consumer is enabled.
4. Let an embedder derive a principal/roles once per connection and authorize
   each namespace operation without global correlation state.
5. Keep certificate bytes in process memory only and redact all formatting.
6. Preserve source compatibility and behavior for current embedders while
   offering an unambiguous fail-closed mode.

## Non-goals

- No X.509, SPIFFE, chain, signature, validity, EKU, CRL, or OCSP parser in
  `moq-rs`.
- No certificate or principal serialization into MoQT, HTTP headers, query
  strings, qlog, mlog, metrics, or tracing.
- No role vocabulary or namespace policy owned by `moq-rs`.
- No classification of a relay as internal from certificate subject, IP, SNI,
  or path inside the transport crate.

## Minimal transport change

In `moq-native-ietf/src/quic.rs`, extract the identity from the fully established
QUINN connection before it is moved into WebTransport/raw QUIC:

```rust
#[derive(Clone)]
pub struct PeerIdentity {
    certificates: Arc<[CertificateDer<'static>]>,
}

pub struct ConnInfo {
    // Existing fields remain unchanged.
    pub peer_identity: Option<PeerIdentity>,
}
```

`PeerIdentity` needs a read-only certificate-chain accessor and a manual
`Debug` implementation that reports only presence and bounded chain length.

The extraction should:

1. happen only after `conn.await` succeeds;
2. call the official `conn.peer_identity()` API;
3. downcast only the documented rustls type;
4. treat an unexpected dynamic type as a local configuration/API error, not as
   an anonymous peer;
5. keep `None` for endpoints whose configured TLS policy legitimately allows no
   client certificate;
6. never derive or log subject, SAN, serial, fingerprint, PEM, or DER.

An alternative name such as `TlsPeerIdentity` is fine. The important property
is that the value is connection-owned authenticated evidence, not a client
claim and not a socket-derived identifier.

## Relay authorization hook

Add an optional, two-phase relay hook. The exact names are illustrative:

```rust
#[async_trait]
pub trait ConnectionAuthorizer: Send + Sync {
    async fn authenticate(
        &self,
        connection: &AuthenticatedConnection<'_>,
    ) -> Result<AuthorizedSession, AuthorizationError>;

    async fn authorize_operation(
        &self,
        session: &AuthorizedSession,
        operation: AuthorizationOperation<'_>,
    ) -> Result<(), AuthorizationError>;
}

#[non_exhaustive]
pub enum AuthorizationOperation<'a> {
    Publish { namespace: &'a TrackNamespace },
    Subscribe { namespace: &'a TrackNamespace },
    RelayPeer,
}
```

`AuthenticatedConnection` should contain a borrowed `PeerIdentity`, negotiated
transport, and the already available non-principal metadata/path. The
authorizer may use the certificate chain to derive an application principal;
the relay must not interpret the certificate itself.

`AuthorizedSession` should be an opaque, cloneable, connection-scoped value
created only by the trusted hook. It needs bounded/redacted access to a stable
principal identifier and application roles, or an embedder-owned typed context.
It must never accept values sent by the peer. A custom `Debug` implementation
must not expose principal, roles, or certificate data.

The relay should invoke `authenticate` before `Coordinator::resolve_scope` (or
replace that call with a new context-aware resolution method) and before
creating Producer/Consumer. It should invoke `authorize_operation` before each
peer-initiated namespace registration, publication, lookup, subscription, or
relay-peer operation. A rejection closes only that connection/session and must
not mutate shared namespace state.

The resulting `AuthorizedSession` should be retained in `SessionContext` and
made available, as a redacted/opaque authorization context, in every relevant
`CoordinatorContext`. Context-aware companion methods can default to existing
Coordinator methods so current implementations continue to compile.

## Compatibility and fail-closed behavior

Existing `RelayConfig::build*` paths may keep today's behavior when no
authorizer is configured. Add an explicit authenticated builder or mode, for
example:

```rust
relay_config
    .with_required_connection_authorizer(authorizer)
    .build()?;
```

In required mode:

- missing peer identity is an authorization error;
- missing authorizer/configuration is a build error;
- unexpected identity type is an accept error;
- authorizer rejection has no legacy `resolve_scope` fallback;
- `resolve_scope(None)` defaults cannot silently grant `ReadWrite`;
- inbound `relay-peer` status is granted only by the authorizer, never by
  `ConnectionTagger` alone.

This keeps compatibility explicit: legacy builders retain legacy behavior;
secure builders cannot accidentally downgrade to it.

## Data-flow ordering

```text
rustls verifies client chain
        |
QUINN established Connection::peer_identity()
        |
moq-native ConnInfo::peer_identity (memory only)
        |
required ConnectionAuthorizer::authenticate
        |
AuthorizedSession bound to this connection
        |
resolve scope / create Producer or Consumer
        |
authorize_operation(operation, exact namespace where applicable)
        |
coordinator registration or lookup
```

No stage may reconstruct the principal from IP, port, SNI, path, header, query,
or a MoQT value.

## Required tests

1. Server requires client authentication; a client presenting no certificate
   is rejected and the authorizer is not called with fabricated identity.
2. A valid TLS chain with an invalid SPIFFE URI is rejected by an example test
   authorizer before scope resolution and namespace state mutation.
3. A valid but unauthorized identity is rejected before publish/subscribe.
4. Publish authorization does not imply subscribe authorization.
5. Relay-peer classification requires an explicit authorization result even
   when `ConnectionTagger` marks the socket/SNI/path internal.
6. Two concurrent peers with different certificates never exchange identity,
   roles, authorization results, or coordinator context.
7. Authorization rejection affects only the rejected connection.
8. Existing legacy relay tests and draft-16 ALPN/WebTransport/raw-QUIC tests
   remain unchanged.
9. An authorized publisher and subscriber still exchange upstream MoQT Objects
   without payload changes or a second protocol implementation.
10. Debug/tracing tests confirm that certificate DER/PEM, subject, SAN, serial,
    principal, and roles are not emitted.

Test certificates may use `rcgen`; no generated private key should be committed.

## Security rationale

Calling `peer_identity()` on the established connection preserves the binding
created by the same rustls verifier that accepted the peer. Carrying the result
inside the connection/session data flow provides isolation naturally, including
under concurrent handshakes. A verifier callback plus global/thread-local map
does not provide that property and should not be used.

## Upstream search

Searches on 2026-08-25 for `peer_identity`, `client certificate`, `mTLS`,
`authenticated principal`, and `peer identity` found no existing issue or PR
covering this contract. PR
[#145](https://github.com/cloudflare/moq-rs/pull/145) plumbs connection path and
scope permissions but does not carry authenticated TLS identity. Issue
[#172](https://github.com/cloudflare/moq-rs/issues/172) concerns an expired
server certificate and is unrelated.

No issue or PR has been opened from this document.
