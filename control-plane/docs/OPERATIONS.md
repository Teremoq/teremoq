# Local operations and evidence

## Structured metrics

`ControlPlane.metrics()` returns a bounded-cardinality snapshot with schema,
service, instance, generation, configured controllers, queue depth/capacity,
active sessions, desired nodes by tier, lifecycle nodes by state and counters.
Stable counters include accepted/rejected metrics, scale-out/scale-in, node
replacement, session reassignment and ignored stale events.

Events use stable `event_type` values and include event ID, partition, sequence,
generation, logical observation time and bounded payload. The main events are:

- `node_requested`, `node_state_changed`, `node_drained`;
- `sessions_reconciled`, `sessions_rebalanced`;
- `snapshot_created`, `snapshot_rolled_back`;
- `stale_event_ignored`, `out_of_order_event_ignored`;
- `alert_raised`, `control_plane_shutdown`.

Alerts are structured with `code`, `severity`, `partition`, `reason` and time:

- `invalid_metrics_fail_closed`;
- `node_limit_reached`;
- `spend_limit_reached`;
- `lifecycle_timeout`.

Provider/region/zone and node/session IDs are audit fields, not unbounded metric
labels. Production telemetry should export aggregates using an existing
OpenTelemetry/Prometheus integration owned by observability.

## Snapshot and rollback

Snapshots contain desired counts, node lifecycle, placement, sessions,
generation, image digest and configuration digest. The canonical JSON payload
is SHA-256 protected. Rollback rejects tampering or a different image/config,
advances generation to fence delayed events and restores deterministic state.
Snapshots do not contain media, credentials or provider secrets.

## Cost semantics

The milestone uses zero rates sourced as `local-simulation-measured` because it
creates no remote infrastructure. The report distinguishes:

- measured remote infrastructure cost of the local run: 0 EUR;
- calculated local hourly/per-viewer values using those zero local rates;
- external provider estimate: unavailable.

A non-local estimate is invalid unless all tier/controller tariffs have a
currency, named source and date. Cost guardrails are exercised by unit policy
and the same configured maximum applies before provider plan execution.
Billable egress is calculated in decimal GB from configured payload Mbps per
viewer, protocol overhead and duration. The report separates node/controller
cost, egress cost, total cost and cost per viewer-hour. The sample external
tariff test uses clearly labelled fixture values; they are not provider prices.

## Reproducibility

`scripts/verify.sh` validates configuration, compiles Python sources, runs the
unit/E2E suite, executes only 10/25/50/100 viewers, writes JSON/Markdown evidence
and creates `SHA256SUMS`. The JSON records measured wall runtime separately from
deterministic logical time. Timing can vary by host; control decisions, IDs,
distribution, snapshot digests and cleanup are deterministic for the same
configuration and interpreter semantics.

The report must retain its explicit limitation: all node creation, failure,
replacement, reassignment and cleanup are simulated control state. It is not a
real 100-viewer media load test.
