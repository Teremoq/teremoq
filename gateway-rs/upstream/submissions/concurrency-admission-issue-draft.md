# Draft issue: bound pending handshakes and established relay sessions with immediate admission

> **NOT SUBMITTED.** Copy-ready design draft for maintainer review. The API names
> below are illustrative and have not been compiled.

## Problem

At
[`bf87128affd316463e5dcc7599a45001f222b6de`](https://github.com/cloudflare/moq-rs/commit/bf87128affd316463e5dcc7599a45001f222b6de),
two independent resource phases are unbounded:

- [`moq_native_ietf::quic::Server::accept`](https://github.com/cloudflare/moq-rs/blob/bf87128affd316463e5dcc7599a45001f222b6de/moq-native-ietf/src/quic.rs#L403-L432)
  obtains every `quinn::Incoming` and pushes its handshake/WebTransport work into
  a private `FuturesUnordered`.
- [`moq_relay_ietf::Relay::run`](https://github.com/cloudflare/moq-rs/blob/bf87128affd316463e5dcc7599a45001f222b6de/moq-relay-ietf/src/relay.rs#L278-L470)
  requeues acceptance and pushes every established connection into another
  `FuturesUnordered` before any session admission check.

An idle timeout and an active-connection gauge do not bound pending work. Under
slow or stalled QUIC/TLS/WebTransport establishment, the first collection can
grow. Under long-lived valid MoQT sessions, the second can grow. Waiting for a
semaphore permit after receipt would replace an unbounded future collection with
an unbounded waiter queue.

This affects generic embedders that need predictable memory/task bounds and
bounded shutdown. It is independent of any authentication scheme.

## Proposed minimum contract

### Phase 1: per-endpoint pending transport admission

The precise QUINN 0.11.11 order is important:

1. `Endpoint::accept().await` yields a [`quinn::Incoming`](https://docs.rs/quinn/0.11.11/quinn/struct.Incoming.html).
2. Immediately call a non-waiting admission operation such as
   `try_acquire_owned()`.
3. Only with a permit call `Incoming::accept()` or `accept_with()` and begin
   expensive per-connection work.
4. On saturation, consume the `Incoming` immediately with `refuse()`, or with
   `retry()` only when address validation state and configured policy make Retry
   applicable. Never enqueue a permit waiter.

It is not possible to acquire “before receiving `Incoming`”; the endpoint must
yield that object first. Admission still occurs before accepting it into a QUIC
connection.

The handshake permit covers one monotonic absolute deadline spanning:

- QUIC/TLS establishment and ALPN selection; and
- for WebTransport, H3 SETTINGS and CONNECT acceptance.

QUIC idle timeout does not replace this deadline. The permit remains live through
success, error, timeout, cancellation, and drop of the entire phase, and is
released exactly once by RAII.

An additive configuration surface could avoid fields on public config structs:

```rust
// Illustrative only; names and error types are open to maintainer preference.
#[non_exhaustive]
pub struct HandshakeAdmission {
    pub max_pending: NonZeroUsize,
    pub deadline: Duration,
    pub saturation: SaturationPolicy,
}

#[non_exhaustive]
pub enum SaturationPolicy {
    Refuse,
    RetryWhenUnvalidated,
}

impl Server {
    pub fn with_handshake_admission(
        self,
        config: HandshakeAdmission,
    ) -> BoundedServer;
}
```

`BoundedServer::accept` would own the semaphore and the in-flight collection so
the cap is structural. A missing/zero deadline must be rejected by the bounded
builder rather than silently selecting the legacy path.

Pseudocode for the critical sequence:

```rust
// Illustrative only.
let incoming = endpoint.accept().await?;
let permit = match pending.clone().try_acquire_owned() {
    Ok(permit) => permit,
    Err(_) => {
        disposition.apply(incoming); // refuse, or retry only when applicable
        metrics.handshake_rejected.increment(1);
        continue;
    }
};

let deadline = Instant::now()
    .checked_add(config.deadline)
    .ok_or(ConfigError::DeadlineOverflow)?;
handshakes.push(async move {
    let _permit = permit;
    timeout_at(deadline, accept_quic_tls_and_webtransport(incoming)).await
});
```

No task that waits for capacity is created.

### Phase 2: global established-session admission per relay

After native transport establishment, acquire a separate session permit with an
immediate attempt. This must occur before spawning/pushing any MoQT session task
or future. The permit covers MoQT setup and the established session and is held
until that whole task ends. It is therefore also acquired before Producer,
Consumer, registration, lookup, or namespace mutation. Saturated N+1 is
closed/rejected without an internal task or permit queue.

The session budget is global to one `Relay` across all configured endpoints. A
per-endpoint handshake budget is local to that endpoint. This avoids multiplying
the advertised relay session limit by the endpoint count. If a deployment needs
a global handshake budget, it should explicitly pass a shared admission
controller rather than relying on accidental semaphore cloning.

```rust
// Illustrative only.
#[non_exhaustive]
pub struct RelayAdmission {
    pub max_sessions: NonZeroUsize,
    pub shutdown_deadline: Duration,
}

impl Relay {
    pub fn new_bounded(
        config: RelayConfig,
        admission: RelayAdmission,
    ) -> anyhow::Result<BoundedRelay>;
}

impl BoundedRelay {
    pub async fn run_until(
        self,
        shutdown: CancellationToken,
    ) -> anyhow::Result<ShutdownReport>;
}
```

The exact cancellation primitive can use an existing dependency or internal
mechanism; this proposal does not require a new crate.

### Coordinated shutdown

On shutdown:

1. stop polling new accepts and close endpoint acceptance;
2. cancel pending handshake/WebTransport futures and active session tasks;
3. allow both collections to drain until one absolute monotonic deadline;
4. abort/drop any remainder at the deadline;
5. wait for endpoint idle only within the remaining budget; and
6. return only after pending-handshake and active-session gauges are zero.

Dropping the relevant futures must release permits by RAII. Shutdown must not
depend on peers cooperating, and one endpoint must not keep another alive past
the relay deadline.

### Metrics

Expose low-cardinality counters/gauges without remote address, certificate,
namespace, SNI, or connection ID labels. Suggested dimensions are fixed enums:

- `pending_handshakes` and `active_sessions` gauges;
- accepted, refused, retry-sent, timed-out, TLS-error, cancelled, and completed
  handshake counters;
- session accepted, rejected-capacity, closed, cancelled, and forced-shutdown
  counters.

Gauge guards and permit guards should have a single owner and release on drop.
After completed shutdown both gauges are zero.

## Alternatives rejected

- **`Semaphore::acquire().await` after receipt:** creates a waiter queue under
  overload and delays rejection.
- **Acquire before `Endpoint::accept()`:** there is no `Incoming` to disposition,
  and holding permits while no remote has arrived wastes capacity; the correct
  boundary is immediately after the endpoint yields `Incoming`.
- **Only QUIC idle timeout:** does not set an absolute deadline over TLS and
  WebTransport CONNECT and may reset with traffic.
- **Only QUINN transport limits:** stream/connection transport settings do not
  cap application-owned pending futures or established MoQT session tasks.
- **Only a relay session semaphore:** does not bound pre-session handshakes.
- **Only per-endpoint session limits:** silently multiplies total relay capacity
  as listeners are added.
- **Using metrics as admission:** observing a gauge does not make check-and-admit
  atomic.
- **Raw UDP in handshake tests:** arbitrary UDP packets do not exercise QUIC
  Incoming, TLS, Retry, ALPN, or WebTransport.

## Compatibility and semver

- Keep existing `Server::accept`, `Relay::new`, and public struct layouts for
  source compatibility. New bounded wrappers/builders and `#[non_exhaustive]`
  config types can be additive minor-release APIs.
- Adding fields to public `Config`/`RelayConfig` breaks external struct literals;
  changing the existing accept return type breaks callers. A major release would
  be required for those alternatives.
- Rust ABI stability is not promised; downstream binaries must be rebuilt.
- The legacy constructors retain current unbounded behavior and must be named and
  documented as legacy when selected explicitly. A constructor named `bounded`
  must reject missing/zero limits and cannot fall back.
- Emit a targeted startup warning/event when an explicitly configured production
  listener selects legacy unbounded admission, if that state is detectable;
  avoid claiming a universal safe default without migration evidence.
- No new dependency, Cargo feature, MoQT frame, ALPN, or protocol parameter is
  required.
- WebTransport and raw QUIC remain supported on draft-16 with their current ALPNs
  and MoQT Object behavior.

## Proposed tests

Use real QUINN/upstream endpoints. Packet control may delay/drop selected QUIC
handshake packets or WebTransport CONNECT progress; raw UDP alone is not a QUIC
handshake test.

1. with pending limit N, N real handshakes occupy permits and N+1 is refused
   immediately without a permit waiter;
2. permits return exactly once after success, TLS error, absolute timeout,
   explicit cancellation, and future/drop paths;
3. WebTransport CONNECT is inside the same absolute deadline as QUIC/TLS;
4. configurable Retry is sent only when `Incoming::retry()` is applicable, and
   validated Incoming falls back to the documented refusal policy;
5. with global session limit N, N established sessions are admitted across one
   or multiple endpoints and N+1 creates no session task or namespace state;
6. closing one session returns capacity and the next connection is admitted;
7. adding endpoints does not multiply the global relay session limit;
8. per-endpoint handshake limits are independent, while an explicit shared
   controller has documented global semantics;
9. shutdown with pending handshakes and active sessions cancels/drains within the
   configured deadline, releases all permits, and leaves both gauges at zero;
10. cancellation races and dropping the server/relay do not leak permits or
    double-decrement gauges;
11. metric labels remain in a fixed low-cardinality set and events contain no
    addresses or other sensitive metadata;
12. WebTransport/raw QUIC, both ALPNs, draft-16 setup, and MoQT Objects continue
    to pass their existing regression tests.

Tests should include deterministic synchronization points for “permit acquired”,
“transport established”, “session admitted”, and “namespace state touched” so
N+1 assertions do not depend on sleeps.

## Questions for maintainers

1. Should pending-handshake admission live on a `BoundedServer` wrapper, an
   endpoint builder, or inside the current `Server` behind an additive method?
2. Which raw-QUIC/WebTransport error codes and Retry policy should represent
   saturation without creating wire incompatibility?
3. Should the current `Relay::run` gain a cancellation parameter in a major
   release, or should an additive `run_until`/bounded wrapper preserve source
   compatibility?
4. Given restricted issue creation, where should this design be discussed before
   a pull request is prepared?

This draft makes no production capacity or denial-of-service resistance claim.
It proposes explicit bounds, lifecycle semantics, observability, and tests.
