# Proposal: bounded QUIC handshake and relay session admission

Status: draft for maintainer discussion; not filed upstream.

Target reviewed: Cloudflare `moq-rs`
`bf87128affd316463e5dcc7599a45001f222b6de` (2026-08-18), with
`moq-native-ietf 0.10.0`, `moq-transport 0.16.1`, and
`moq-relay-ietf 0.7.25`. License: MIT OR Apache-2.0.

## Problem

`moq_native_ietf::quic::Server::accept` accepts every QUINN `Incoming` and
pushes `accept_session` into a private, unbounded `FuturesUnordered`.
`moq_relay_ietf::Relay::run` pushes every established session into another
unbounded `FuturesUnordered`. An embedder can observe neither boundary soon
enough to reject overload, cannot force QUIC address validation, and cannot
separate pending-handshake capacity from established-session capacity.

QUIC's 10-second idle timeout is not an absolute handshake deadline. Limiting a
container does not provide protocol-level rejection or protect healthy peers
from an in-process resource flood.

## Goals

1. Bound pending QUIC/TLS/WebTransport handshakes per endpoint.
2. Bound established MoQT sessions per relay independently.
3. Reject overload immediately; never await a semaphore permit for an already
   arrived remote connection.
4. Optionally require QUIC Retry before allocating handshake state.
5. Expose low-cardinality outcomes and gauges without client addresses.
6. Preserve WebTransport/raw QUIC, draft-16, ALPN and existing builders.
7. Compose with the authenticated-peer authorization proposal.

## Non-goals

- No application queue in front of admission.
- No per-IP identity, quota or authorization policy.
- No replacement for cgroup/firewall/DDoS protection.
- No protocol reimplementation or dependency on a particular metrics backend.

## Minimal native endpoint API

The exact naming is illustrative. The necessary property is that admission is
decided while `quinn::Incoming` can still be refused/retried and that the
handshake permit lives until `accept_session` finishes.

```rust
#[derive(Clone, Copy, Debug)]
pub struct ServerLimits {
    pub max_pending_handshakes: NonZeroUsize,
    pub handshake_timeout: Duration,
    pub require_address_validation: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AdmissionRejection {
    HandshakeCapacity,
    HandshakeTimeout,
    AddressValidation,
    SessionCapacity,
}
```

`ServerLimits` should be an optional companion builder/config to preserve source
compatibility. A production-oriented builder should require explicit limits.

The accept algorithm should:

1. call `try_acquire_owned()` before accepting an `Incoming`;
2. on saturation, call `Incoming::refuse()` (or a documented overload close)
   immediately and increment an enumerable outcome;
3. when address validation is required and legal, call `Incoming::retry()`;
4. wrap the complete QUIC/TLS/H3 CONNECT acceptance in a monotonic timeout;
5. release the permit on success, error, timeout, future drop and endpoint close;
6. keep polling completed handshakes even during a receive flood so a valid peer
   cannot be starved by select-branch bias.

The API should expose a bounded/redacted snapshot or callback:

```rust
pub struct ServerAdmissionSnapshot {
    pub pending_handshakes: usize,
    pub accepted_total: u64,
    pub rejected_capacity_total: u64,
    pub timed_out_total: u64,
}
```

It must not expose IP addresses as metric labels.

## Minimal maintained test hook

At the pinned revision, the public client `connect` future covers QUIC, TLS and
WebTransport CONNECT as one operation. The configurable socket wrapper exposes
QUINN types, so an embedder cannot build a standards-compliant client that
pauses a real TLS handshake without adding a direct QUINN dependency.

Please provide an upstream-owned, feature-gated test utility that starts a
standards-compliant QUIC client and can pause before transport authentication
completes. It should return an RAII handle with bounded `resume`, `cancel`, and
deadline operations, and expose no raw packet-construction API. The utility can
use QUINN internally and must be tested together with `ServerAdmissionSnapshot`.
This is sufficient for downstream black-box admission tests without making
QUINN part of the downstream contract. Until such a maintained hook exists,
downstream should report this condition as
`untestable_with_pinned_public_api`, not simulate it with a post-connect sleep.

## Minimal relay API

Add either `RelayLimits` or an admission trait invoked after authenticated peer
evidence is available and before MoQT session task creation:

```rust
#[derive(Clone, Copy, Debug)]
pub struct RelayLimits {
    pub max_sessions: NonZeroUsize,
}

#[async_trait]
pub trait SessionAdmission: Send + Sync {
    fn try_admit(
        &self,
        connection: &AuthenticatedConnection<'_>,
    ) -> Result<SessionPermit, AdmissionRejection>;
}
```

`SessionPermit` must be connection-owned RAII and non-cloneable. Rejection must
close just that connection with a stable, non-sensitive overload code/reason.
The relay must not push a rejected session into its task collection. Waiting on
`Semaphore::acquire` is not acceptable because it creates the hidden queue the
limit is meant to prevent.

If identity support lands separately, admission may inspect only opaque,
authenticated context. IP/SNI/path must not silently become principal or
relay-peer authorization.

## Shutdown contract

Endpoint close must stop accepting, cancel pending handshakes, close active
sessions, drain owned tasks within a caller-supplied deadline, then abort any
non-cooperative remainder. Snapshots must reach zero after the returned shutdown
future completes. Dropping a builder or failed startup must not leave tasks.

## Required tests

1. With handshake limit N, N upstream QUIC clients hold real handshakes pending;
   N+1 is refused without increasing pending count or an internal waiter count.
2. One permit is released on handshake success, TLS failure, timeout, client
   cancellation, server cancellation and future drop.
3. A valid peer completes within the test profile while invalid and delayed
   QUIC peers occupy the other permitted slots.
4. QUIC Retry is sent only when configured and legal; a retried client can
   subsequently progress.
5. With session limit N, N established sessions run; N+1 is closed before a
   relay session task or namespace mutation is created.
6. Closing one session admits a new peer immediately without restarting relay.
7. Session setup cancellation and steady-session cancellation recover the
   permit exactly once.
8. Multiple endpoints have explicit documented global-versus-per-endpoint
   semantics and cannot multiply an intended global limit accidentally.
9. A reconnect storm never creates concurrent duplicate outbound sessions for
   one configured upstream.
10. Existing WebTransport/raw QUIC, draft-16 ALPN, Objects, authorization and
    relay tests remain unchanged.
11. A bounded load test reports pending/active peaks equal to configured limits,
    enumerable rejections, RSS windows and cleanup to zero; it must not infer
    leak freedom from a single sample.

Tests for incomplete TLS must use the upstream-maintained QUINN/moq-native test
utility and controlled packet loss/delay, not raw UDP labelled as QUIC.

## Compatibility

Legacy builders may retain current behavior with a prominent unbounded default
warning. A separate fail-closed builder should require both limits. Adding
fields directly to public struct literals would be breaking, so companion
builders are preferable unless a major release is planned.

## Security and operational rationale

Separating handshake and session capacity prevents expensive unauthenticated
work from consuming all established-session slots. Early `try_acquire` avoids a
memory queue proportional to attacker input. QUIC Retry validates return
routability but is not authentication, authorization or a substitute for a
capacity limit.

No issue or PR has been opened from this document.
