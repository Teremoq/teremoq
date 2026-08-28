# Control-plane architecture

## Boundary and invariants

The control plane owns desired state, node lifecycle, placement, capacity,
cost guardrails and audit state. It never proxies, terminates or forwards SRT,
QUIC, WebTransport, MoQT, Tracks, Groups, Objects or media payloads. A control
outage therefore leaves existing gateway/relay sessions on their last applied
data-plane state. New capacity changes pause fail closed until valid control
state returns; existing video sessions do not depend on a control request.

The local simulator is evidence about control decisions only. It is not
evidence for bandwidth, media concurrency, latency, relay admission or
production readiness. ADR-0005 and ADR-0006 remain blockers for authenticated
namespace authorization and bounded relay admission.

## Hierarchy and placement

Every configuration declares all tiers, even when a tier is disabled for a
milestone:

1. `origin`: ingress/source ownership and upstream fan-out.
2. `core`: principal distribution tier used by the local gate.
3. `regional`: optional region fan-out.
4. `viewer-edge`: optional viewer-adjacent delivery.

Each tier has a minimum, configurable maximum, viewer/egress capacity and an
ordered list of `{provider, region, zone}` placements. Placement rotates
deterministically across the ordered list. Adding providers, regions, zones or
enabling deeper tiers changes configuration, not the state machine or provider
interface.

## Partitioned reconciliation and replicated state

Metrics and events carry a partition. A production controller set assigns
regional partitions through a lease supplied by an existing replicated store;
each partition has one writer generation at a time. Controllers emit immutable,
ordered events and periodic snapshots. Followers apply only the same or a newer
generation and ignore delayed lifecycle events. If a bounded event cursor has
expired, a follower restores a digest-verified snapshot before consuming new
events.

The local gate runs one in-memory writer and explicitly does not claim high
availability. `controller.replicas` accepts three or more without code changes,
but production requires the lease/store contract in `INTEGRATION-CONTRACTS.md`.
No single global scheduler is required: each regional partition reconciles its
own capacity and state. Cross-region policy is declarative input and never a
per-viewer coordination point.

## Lifecycle and generations

The explicit lifecycle is:

```text
requested -> provisioning -> bootstrapping -> authenticated -> registered -> ready
ready -> draining -> terminated
any active provisioning/ready state -> failed -> replacing -> draining -> terminated
```

Each node is bound to image digest, configuration digest and generation.
Transitions are idempotent. Duplicate transitions are accepted as no-ops;
events from an older generation and backward transitions are ignored and
counted. Provisioning, bootstrap, authentication, registration, drain and
replacement have separate timeouts. A failed ready node enters `replacing`, its
replacement must reach `ready`, and only then are assignments drained within
per-node capacity before the old node terminates. If no ready peer has enough
capacity, assignments remain intact, `node_drain_unresolved` is raised and no
clean drain or termination is claimed.

## Provider boundary

`CapacityProvider` exposes `plan`, `apply` and `destroy`. This task implements
only `LocalSimulatorProvider`:

- `dry-run`: returns an auditable plan without mutating nodes.
- `simulate`: produces deterministic lifecycle events without I/O.

A future adapter must be reviewed separately, consume immutable image digests,
remain idempotent by node ID/generation, never accept credentials through this
repository and preserve dry-run. No provider-specific type enters scaling or
lifecycle policy.

## Deterministic autoscaling

For a target tier, the reconciler computes:

```text
viewer_demand = max(authorized_viewers, active_sessions + valid_reserved_viewers)
viewer_nodes = ceil(viewer_demand * (1 + reserve_ratio) / viewers_per_node)
egress_nodes = ceil(egress_mbps * (1 + reserve_ratio) / egress_mbps_per_node)
required = max(configured_minimum, viewer_nodes, egress_nodes)
```

If the result exceeds the configured node maximum or the dated tariff model
exceeds the configured hourly spend maximum, reconciliation fails closed: it
raises a critical alert, preserves current capacity and emits no provider
action. Scale-out and scale-in have independent cooldown and stability windows.
Scale-in additionally requires utilization below a configured hysteresis
threshold. No incoming-connection count is accepted as a capacity signal and
no AI participates in a capacity decision.

Samples require an opaque verified-auth context supplied by the external PKI
boundary, nondecreasing bounded sequence progression, freshness, nonnegative
values and unique bounded replay nonces. The control plane neither parses
certificates nor verifies signatures. Active sessions cannot exceed authorized
viewers plus live reservations. Expired reservations consume no capacity. Any
invalid sample produces a structured critical alert and preserves current
capacity without applying a plan. A configurable initial unreserved-demand
maximum protects an empty metrics history, and a configurable maximum aggregate
demand increase per second rejects later unreserved bursts. Reservations are
protected by ID and nonce replay records. Reobserving the same unchanged live
reservation is idempotent; changing its capacity, authorization, expiry or nonce
is rejected as replay/mutation.

## Bounded state

- Event and alert history: `controller.event_queue_limit`.
- Replay nonce history: the same bounded window.
- Reservations per metrics sample: `scaling.maximum_reservations_per_sample`.
- Live replay records: `scaling.reservation_registry_limit`. Only expired
  records are purged; saturation rejects new reservations fail closed.
- Provider actions per pass: `scaling.maximum_actions_per_reconcile`; larger
  changes converge in deterministic batches.
- Serialized actions and bytes per local action file: provider envelope limits;
  the schema also enforces a per-payload technical maximum.
- Metrics samples: schema `maxItems` plus the equal-or-smaller configured
  reservation limit; JSON numbers are interoperable safe integers.
- Snapshots: `controller.snapshot_limit`.
- Session registry: `controller.session_registry_limit`.
- Session assignments: sum of ready-node `capacity_viewers`; every node is also
  checked independently before an atomic assignment update.
- Nodes: tier `maximum_nodes`.
- No media buffers or payload queues exist in the control plane.

These payload and registry limits control memory and amplification. They do not
encode a 100/1,000/10,000/100,000 viewer or node ceiling. Viewer/node policy is
deployment configuration; large changes converge across bounded action batches
and regional partitions.
