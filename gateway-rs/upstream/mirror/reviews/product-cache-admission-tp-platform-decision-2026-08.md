<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# TP-PLATFORM-CHAOS decision brief: product cache and admission policy

Date: 2026-08-28

Role: `TP-PLATFORM-CHAOS`

Scope: local, independent, read-only analysis of the product-pin owner candidate

Decision: **PRESERVE 5 S THROUGH AN ADDITIVE REQUIRED-BOUNDED API FOR THE MVP**

This document is a decision recommendation, not an implementation, product-pin
approval, publication authorization, production-readiness claim, or change to
the C1/C2 derivative. No benchmark result or SLO is inferred here.

## Findings first

### High — silently changing 5 s to 30 s couples admission adoption to an unrelated cache policy

The current private relay laboratory calls
`RelayConfig::build_with_cache_idle_timeout(Duration::from_secs(5))`. The owner
candidate correctly replaces the legacy relay with `build_required_bounded`,
but that constructor reaches `Relay::new_inner` with
`DEFAULT_CACHE_IDLE_TIMEOUT`, currently 30 seconds. The public
`build_required_bounded` signature has no cache-timeout argument.

Required authorization and C2 admission must not be abandoned to retain 5
seconds. Equally, adopting required/bounded mode must not silently multiply a
separate operational grace period by six. The conservative MVP choice is a
small additive upstream constructor that preserves the existing 5-second
product behavior while retaining required authorization, C1, C2 and bounded
shutdown.

### High — neither 5 s nor 30 s bounds cache cardinality or retained bytes

The timeout governs pull-through entries with no downstream interest. Local
cache entries retain the key, reader, interest generation and upstream lease;
remote entries additionally retain an owned cleanup future and upstream
`SUBSCRIBE` until closure, cancellation or idle eviction. C1 bounds expensive
transport setup. C2 bounds inbound and outbound relay-session roots. Neither
controller limits the number of track keys, cache entries, Objects buffered by
those readers, or cache bytes.

Thirty seconds widens the idle-residence window by 25 seconds. Under a stable
arrival rate of unique, non-reused idle tracks, a queueing approximation would
add roughly `25 * arrival_rate` resident entries relative to five seconds.
That is a model, not a measurement: the current public snapshots expose no
cache-entry or cache-byte gauge with which to quantify it. Task 04/05 must not
convert the C1/C2 result into a bounded-memory or DoS-resistance claim.

### Medium — 30 s can reduce subscription churn, but is not offline storage

The derivative documents the intended benefit: a downstream subscriber that
returns within the grace window can reuse a warm entry rather than pay a new
upstream `SUBSCRIBE` round trip. Extending the window from 5 to 30 seconds can
therefore reduce `SUBSCRIBE`/`UNSUBSCRIBE` churn and cold-recovery latency for
short downstream disconnects or rendition switches while the upstream
subscription remains healthy.

It does not preserve media through an upstream failure. In the remote path,
`subscribe.closed()` and cancellation race the idle timer and release the
subscription immediately. The cache is not a recording, durable spool or
offline replay layer. A hostile partition that closes the upstream session
invalidates the warm-path assumption regardless of the configured grace
period. No Object, codec, ALPN or Zero-Transcoding behavior changes with either
timeout.

### Medium — the owner constants are not product configuration or capacity evidence

The owner patch uses constants of 32 buffered `Incoming`, 8 pending
handshakes, 16 inbound sessions, 4 outbound sessions, a 5-second handshake
deadline and a 10-second relay shutdown budget. Those values demonstrate API
composition. They have not been derived from a stated load, hardware, network
or soak duration and are not production capacity ratings.

The product already validates a separate process shutdown timeout in
`100..=30_000 ms`, with a 3-second default. A future in-process relay must not
quietly run a separate 10-second drain beneath a 3-second outer watchdog. A
standalone lab may own one relay deadline; an embedded service must prove that
the outer supervisor cannot abort the relay before its bounded report and zero
gauges are observed.

### Medium — the product candidate does not assert the exact public N+1 close

The candidate does exercise real raw QUIC and WebTransport routes and observes
one capacity rejection with no second authentication. It currently stores the
result of `extra.closed()` without decoding it. The derivative tests assert
the exact public behavior, but that does not replace a consumer test under the
gateway lock. The product test must independently require code `0x3`, reason
`relay session capacity reached`, zero second authentication/effect and exact
capacity recovery for both transports.

## Frozen local evidence

| Evidence | Binding |
| --- | --- |
| `.cursorrules` | `88d7c6d3c8366b242b0fb49c56751713bdebd6229b779dd336d4de3896f6e6d2` |
| Owner preflight | `80e4a31b5fa298a38bc040fcf513e019a20e5943f1824f71632711d253e8c017` |
| TP-PLATFORM-CHAOS product-pin preflight | `ccf93bc472a846f207a72cf3d48fffbb232b7a9f757b8c7cfa1f08b90c849c09` |
| TP-SEC-PKI product-pin preflight | `24daf315d0ec3e0d81cb5da699883dbca62a4b9c4ff5fe7ffb987bc5cfb7d43c` |
| TP-OSS-SC product-pin preflight | `6316de0f9d8a7c5f399528b9de84af228f756e1c35851e49ae1749214429a1bb` |
| Owner candidate patch | `03efa820f025ce378e2870d90d8af6e6c8a7384548f3b14fc7dd42d2471e3bab` |
| Derivative commit/tree | `89cb1798644c32aef06cc625f097cd9acb203417` / `cccd0d60c9ebfe191dca9d73e7ab8b27ae4d4ea5` |
| `moq-relay-ietf/src/relay.rs` | `8c0df50c59ca86c132272b573604e6a10657cd6781bb70f9ed384e1262c1b3e4` |
| `moq-relay-ietf/src/local.rs` | `ecacbe786afa98fbc75afbdf8cde57571a43b818662b946ee43db5c593ac2395` |
| `moq-relay-ietf/src/remote.rs` | `ed2c2c1759dff247ecac4582021938026572a301db29a44059459b6308b7f614` |
| `moq-relay-ietf/src/session_admission.rs` | `cc5c56db172f7fb13e1f5a1a8bea3957c096d869dd97ac3f9d9f753820f0c7ef` |
| `moq-native-ietf/src/quic.rs` | `92e94e527dce998543b050e1d4af0012b6c18df2b4e32c068ad9ebb46594934d` |

The evidence was inspected locally without running the owner candidate or
regenerating reports. Relevant exact seams are:

- product `examples/dev_mtls_moq_relay.rs:49`: explicit 5-second legacy cache;
- derivative `local.rs:31-38`: 30-second default and stated warm-reuse intent;
- derivative `relay.rs:166-175`: custom cache timeout exists only for legacy;
- derivative `relay.rs:199-215`: required/bounded builder lacks the cache knob;
- derivative `relay.rs:534-546`: bounded construction injects the 30-second default;
- derivative `relay.rs:606-635`: the same timeout is propagated to `Locals` and
  `RemoteManager`;
- derivative `local.rs:167-190`: eviction releases the upstream lease after
  the idle period;
- derivative `remote.rs:2042-2069`: upstream close, cancellation and idle
  eviction are distinct terminal paths;
- derivative `relay.rs:99-100`: fixed C2 close code and reason;
- derivative `session_admission.rs:17-61`: C2 nonzero/MAX_PERMITS/monotonic
  validation;
- derivative `quic.rs:86-116`: C1 nonzero and monotonic validation.

## Options and consequences

| Option | Availability and latency | State and memory | Churn and hostile networks | Compatibility | Decision |
| --- | --- | --- | --- | --- | --- |
| A. Accept the required-builder default of 30 s | Warm reuse extends across disconnects up to 30 s while upstream remains live; cold resubscribe can be avoided more often. No measured latency delta exists. | Idle state and upstream reception live up to 25 s longer than today. Cache cardinality/bytes remain unobservable and not logically capped by C1/C2. | Fewer upstream subscribe/unsubscribe cycles for short gaps; larger exposure to unique-track churn and bandwidth spent on unwatched tracks. No guaranteed recovery after upstream closure. | No derivative API work, but silently changes current product behavior. | Reject for MVP unless the Master explicitly accepts the behavior and its unmeasured retention risk. |
| B. Add a required/bounded constructor with explicit cache timeout and pass 5 s | Preserves the currently reviewed product grace period and existing reconnect behavior. Reuse beyond 5 s remains cold. | Minimizes the behavioral delta and reduces worst-case idle residence relative to 30 s. Still not a cache-cardinality bound. | More churn than 30 s for gaps in `(5 s, 30 s]`, but identical to the current product selection. Hostile behavior is easier to compare because admission and auth change without a simultaneous cache-policy change. | Additive API; existing legacy and default required/bounded callers remain source-compatible. | **Recommended conservative MVP.** |
| C. Fall back to `build_with_cache_idle_timeout(5 s)` | Preserves cache timing only. | Loses required authorization, C2 and owned bounded shutdown. | Restores the exact blocker that motivated the derivative. | Compiles through legacy API but violates ADR-0005/0006 intent. | Prohibited. |

## Recommended additive upstream seam

The minimal seam is an additive overload on both public construction levels,
named consistently with the existing legacy API, for example:

```text
RelayConfig::build_required_bounded_with_cache_idle_timeout(
    authorizer,
    max_inbound_sessions,
    max_outbound_sessions,
    shutdown_timeout,
    cache_idle_timeout,
)

Relay::new_required_bounded_with_cache_idle_timeout(
    config,
    authorizer,
    max_inbound_sessions,
    max_outbound_sessions,
    shutdown_timeout,
    cache_idle_timeout,
)
```

Required semantics:

1. It must execute the same required-endpoint validation and create the same
   inbound/outbound C2 controllers as `new_required_bounded`.
2. It must pass exactly one `cache_idle_timeout` to both `Locals` and
   `RemoteManager`; it must not alter C1, C2, authorization or shutdown.
3. Existing `build_required_bounded` remains source-compatible and retains the
   documented 30-second derivative default.
4. The upstream duration may retain the existing zero-means-disabled semantic
   for compatibility. The Teremoq product must reject zero fail-closed because
   it retains subscriptions for the session lifetime.
5. No second relay loop, forked `Relay::run`, direct QUINN endpoint, new
   dependency or product-specific policy belongs in this seam.

For the MVP, Teremoq should pass an explicit fixed 5 seconds. Do not expose the
cache timeout as an operator knob until the A/B matrix below measures a useful
trade-off. If it is later exposed, it needs its own product field, nonzero
validation, stated units and product-owned min/max; it must not reuse a QUIC
idle, handshake, reconnect or shutdown variable.

## Product-owned configuration without mixed domains

The owner constants are suitable only as provisional MVP ceilings. Expose
independent validated fields, with defaults equal to the candidate and with
configuration unable to exceed the reviewed ceiling until load evidence
supports a separate increase:

| Product field | MVP default | MVP accepted range | Consumer |
| --- | ---: | ---: | --- |
| `federation.max_buffered_incoming` | 32 | `1..=32` | QUINN pre-admission `Incoming` queue |
| `federation.max_pending_handshakes` | 8 | `1..=8` | one shared C1 `HandshakeAdmission` |
| `federation.handshake_timeout_ms` | 5,000 | `100..=5,000` | one absolute QUIC/TLS/WebTransport setup deadline |
| `federation.max_inbound_sessions` | 16 | `1..=16` | relay-global inbound C2 controller |
| `federation.max_outbound_sessions` | 4 | `1..=4` | shared `announce`/`RemoteManager` C2 controller |
| process `shutdown_timeout_ms` | existing 3,000 | existing `100..=30,000` | one lifecycle budget, not a capacity limit |
| pull-through `cache_idle_timeout_ms` | fixed 5,000 | fixed for MVP | local and remote cache policy only |

These ceilings are resource guardrails, not SLOs or throughput claims. Raising
one requires an explicit profile, hardware/network description, short matrix
and bounded soak. A value that Cargo/Tokio can represent is not automatically
a safe product value.

Validation and construction order must be fail-closed:

1. parse all values with bounded integer conversion;
2. reject zero, overflow, values outside the product range and monotonic
   durations that cannot be represented;
3. load and validate mTLS identity and authorization policy;
4. create one C1 controller and inject it into every endpoint in the private
   relay capacity domain;
5. create required/bounded C2 with independent inbound and outbound limits;
6. start listeners and media/data-plane tasks only after all prior steps pass.

Do not impose a synthetic cross-field equation such as `C1 >= C2`,
`inbound == outbound`, or `cache_idle <= shutdown`. These domains own different
state and release at different boundaries. The only structural constraints are:

- all private endpoints in one relay capacity domain share the same C1
  controller;
- a C1 permit ends before session lifetime, while C2 begins before
  authentication/MoQT state;
- outbound `announce` and `RemoteManager` share the outbound C2 controller but
  never consume inbound capacity;
- shutdown closes admission, cancels roots, drains and force-drops under one
  absolute monotonic deadline; cache timers never extend shutdown.

For a standalone private relay, the validated relay shutdown duration may own
that single deadline. If the relay becomes a task inside the existing gateway
supervisor, the owner must demonstrate that both use one process deadline or
add an absolute-deadline seam; two independently reset relative timeouts are
not acceptable. The outer supervisor must not abort `run_until` before the
`RelayShutdownReport` is observed.

## Limits and telemetry required for an honest MVP

### Admission and shutdown

Emit one schema-versioned startup event with the five effective admission
values, handshake deadline, shutdown budget, cache timeout and disposition
policy. Values are bounded numeric fields, not labels. Do not include client
IP, certificate data, identity, path, namespace or track.

Export the public snapshots without merging distributions or domains:

- C1: limit, pending handshakes, inflight futures, admitted, refused, retried,
  retry-not-applicable, completed, transport-error, timeout and cancelled;
- C2 inbound: limit, active, inflight, high-watermark, admitted, capacity
  rejected and each terminal reason;
- C2 outbound: the same schema independently;
- shutdown: state, deadline-elapsed, forced count and the final terminal
  equations.

Required terminal equations are:

```text
C1 admitted = completed + transport_error + timeout + cancelled
C2 admitted = clean_close + setup_error + run_error + cancelled + panicked + forced_shutdown
```

At a completed shutdown, C1 pending/inflight and both C2 active/inflight gauges
must be zero. Do not report an unavailable gauge as zero.

### Cache

The derivative already exposes
`moq_relay_cache_idle_evictions_total{source=local|remote}`. That counter alone
cannot distinguish successful reuse from retention pressure. Before choosing
30 seconds or making a bounded-memory claim, add low-cardinality observability
for:

- current pull-through cache entries by `source=local|remote`;
- current idle cache entries by source;
- cache hit/reuse and cold miss totals by source;
- upstream subscribe attempts and unsubscribes attributable to idle eviction;
- if publicly and cheaply measurable, retained cache bytes; otherwise report
  the metric as unavailable and measure process RSS separately.

The cache maps are network-keyed collections. A production claim also requires
a logical cap on active plus idle pull-through cache entries (and, if readers
buffer payload, a byte cap) with immediate, observable rejection/eviction. A
timeout is a residence policy, not that cap. This gap may remain visible for a
lab MVP, but the relay must remain non-production while it does.

## Required cache validation matrix

All test waits use one absolute watchdog per case. Synchronization uses paused
Tokio time, channels, barriers or observable counters; wall-clock sleeps are
not synchronization.

| Case | Deterministic mechanism | Required observation | Final state |
| --- | --- | --- | --- |
| Additive wiring | Build required/bounded with a test duration; paused clock on local and remote cache paths | Both paths receive the explicit value; the existing required/bounded constructor still selects 30 s | No task or lease remains after test cleanup |
| Five-second boundary | Drop the last interest guard, advance to immediately before and then to the absolute 5-second deadline | Entry exists before the boundary; eviction and upstream release occur once at/after it | Entry absent; eviction counter +1 |
| Reuse inside grace | Reattach interest before the same absolute deadline | Same generation/reader reused; no second upstream subscribe | Entry remains while watched, then evicts once after final idle period |
| Cold return outside grace | Advance past eviction, then reattach | New generation and exactly one new upstream subscribe | Old lease gone; no stale generation removes replacement |
| Upstream closes while idle | Close the real upstream subscription before the idle deadline | Closure wins immediately; no claim of offline recovery | Entry/cleanup future removed without waiting 5 or 30 s |
| Unique-track churn | Fixed seed and bounded rate/duration; compare 5 s and 30 s | Cache-entry/RSS/subscription peaks, evictions, hits, misses and recovery distributions reported separately | Gauges return to baseline or residual is declared |
| Hostile network | Baseline, delay/jitter, loss, reorder, bandwidth and bounded partition, same load/seed for both durations | Valid subscriber progress plus warm/cold recovery classified; no silent zero metrics | Tasks/sockets/C1/C2/cache gauges and qdisc/container cleanup verified |

The A/B comparison must report requested and consumed settings, initial/peak/
final RSS, stable-window slope for a bounded soak, cache entry peak/final,
upstream subscription churn and recovery distributions with sample counts. It
must not lower an assertion threshold to prefer either timeout. A passing short
sample does not prove leak freedom or productive capacity.

## Product-owned C2 N+1 wire test

Implement one parameterized product test that runs independently for
`moqt://` raw QUIC and `https://` WebTransport using the gateway-resolved lock.
It must use real QUINN/rustls/WebTransport/MoQT APIs already supplied by the
derivative; no arbitrary UDP, second endpoint implementation or direct QUINN
dependency is permitted.

### Preconditions

- C1 capacity is greater than one and its rejected counters start at zero, so
  the second transport can reach C2.
- C2 inbound capacity is exactly one.
- Required authorization uses a probe authorizer; coordinator/registration and
  any product effect use independent probes.
- One absolute watchdog is computed once for the complete route and passed to
  every connect, setup, barrier, close, recovery and shutdown wait.

### Sequence and assertions

1. Connect client A over the selected real route, complete MoQT setup, start
   `Session::run`, perform one authorized operation and hold the session at a
   deterministic barrier. Observe exactly one authentication and one intended
   effect. C2 shows admitted 1, active 1 and high-watermark 1.
2. Connect client B over the same route and initiate the normal MoQT setup path.
   Never wait on a capacity permit. Observe the public close through the
   connection API.
3. For raw QUIC, require an application close whose integer code is exactly
   `0x3` and whose reason bytes are exactly
   `relay session capacity reached`. For WebTransport, require the public
   WebTransport closed variant with code `0x3` and the identical UTF-8 reason.
   A generic error, EOF, timeout or merely “closed” is a failure.
4. While A remains held, require: authentication count still 1; scope,
   authorization, coordinator, namespace/registration, tagger, mlog and product
   effect probes unchanged; C2 admitted still 1, rejected-capacity exactly 1,
   active and inflight unchanged, high-watermark still 1. C1 capacity rejection
   remains zero. This is the product-observable proof that B created no second
   authenticated/session root or application effect.
5. Close A cleanly and wait by monitor transition, not sleep. Require active 0,
   inflight 0, available capacity 1 and the exact C2 terminal equation.
6. Connect client C, complete the same authorized setup and effect, and require
   admitted/authentication/effect counters to advance exactly once. This proves
   capacity recovery rather than only permit disappearance.
7. Close C, cancel the relay, await its bounded report before the same absolute
   watchdog, and require C1 pending/inflight plus C2 inbound/outbound
   active/inflight gauges to be zero and both terminal equations exact.

The consumer public API may not expose the derivative's crate-private hook that
proves a `SERVER_SETUP` read was observed `Pending`. The conservative product
alternative is to run the real `Session::connect_with_config` attempt for B
concurrently with exact public close observation and assert that it never
succeeds. The derivative retains the lower-level deterministic ordering proof;
the product test owns the consumer-lock wire value and zero-effect contract.
Do not add a public blocking callback solely for this assertion.

## Acceptance criteria

The cache/admission decision is ready for an owner revision only when all of
the following are true:

1. a reviewed additive required/bounded cache-timeout API exists and old public
   constructors retain their behavior;
2. the product passes exactly 5 seconds through that API and never falls back
   to legacy mode;
3. C1 buffered/pending/deadline, C2 inbound/outbound and shutdown values are
   parsed and validated as distinct fields before listener startup;
4. every private endpoint shares the intended C1 controller and all outbound
   relay roots share the outbound C2 controller;
5. cache, C1, C2 and shutdown telemetry are emitted as separate schemas with
   low-cardinality fields and honest unavailable values;
6. the raw QUIC and WebTransport N+1 product tests meet every exact assertion
   above under a single watchdog;
7. the paused-time cache matrix passes for local and remote paths, followed by
   the short hostile A/B matrix with cleanup;
8. the product report preserves the unresolved cache-cardinality/byte gap and
   makes no bounded-memory, DoS, complete Zero-Trust, external-interoperability
   or production-readiness claim;
9. the unpublished derivative, identity-policy and supply-chain blockers from
   the product-pin reviews remain visible and independently gated.

Reject the revision if it accepts 30 seconds silently, uses legacy mode to
retain 5 seconds, shares one number across C1/C2/cache/shutdown, resets shutdown
deadlines by phase, asserts only WebTransport, accepts a generic close instead
of the exact code/reason, or lacks zero-effect and recovery evidence.

## Consequence for the owner candidate

The owner candidate remains a useful local composition proof, but the two
operational gaps are not closed by its current patch. The recommended next
owner delta is narrowly scoped: add the upstream cache-timeout overload,
consume it with explicit 5 seconds, add fail-closed product configuration for
the independent admission/lifecycle domains, and strengthen the existing
product contract test with the exact close and recovery assertions.

This brief authorizes none of those edits, no dependency change, commit,
publication, push, issue, pull request, release, architecture change or remote
mutation.
