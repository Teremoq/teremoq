<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Virtual-node provider adapter contract v1

Status: local simulation contract for Task 10. It is not a cloud API, a
control-plane implementation or a promise that Task 09 already satisfies it.

## Invocation

The executable contract is:

```text
provider-adapter.sh \
  --contract-version 1 \
  --mode simulate|dry-run \
  --operation plan|create|configure|health|sessions|stop-admit|fail|drain|destroy \
  --request-id <bounded-token> \
  --run-id <bounded-token> \
  --node <bounded-node-id> \
  --state-dir <absolute-ephemeral-directory> \
  --topology <versioned-tsv> \
  [--template-node <existing-topology-node>] \
  [--capacity <unsigned-integer>]
```

Calls originating from an action envelope additionally carry the validated
partition and node generation, config and image digests, idempotency key,
registry limit, tier and placement, capacity pair, reason, drain requirement
and optional replacement identity. The adapter deliberately validates a
minimal v1 semantic boundary again, so bypassing the consumer cannot submit an
unknown reason or an invalid create/destroy combination. The accepted reasons
are `configured_minimum`, `autoscale_out`, `autoscale_in`,
`failed_node_replacement`, `failed_node_cleanup` and `safe_shutdown`.
`create` requires `requires_drained=false`; `destroy` requires
`requires_drained=true` and cannot carry `replaces_node_id`. Replacement
linkage is valid only on `create`.

Every successful call prints exactly one JSON object. The stable envelope is:

```json
{"schema_version":1,"contract":"teremoq.virtual-node.provider","mode":"simulate","operation":"create","request_id":"r1-create-distributor-a","run_id":"t10-example","node_id":"distributor-a","result":"changed","state":"created","reason":"created","duration_ms":1}
```

`result` is one of `changed`, `unchanged`, `planned`; `state` is one of
`planned`, `created`, `configured`, `healthy`, `failed`, `drained`, `absent`.
Reasons are
bounded enums from the adapter. Provider errors return nonzero and never emit
credentials, raw external errors or unbounded labels.

## Semantics

- `dry-run` validates syntax and emits `planned`; it never creates the state
  directory or invokes Docker.
- `plan` validates that the desired node or template exists and performs no
  state mutation.
- `create`, `configure`, `health`, `sessions`, `stop-admit`, `fail`, `drain`
  and `destroy` converge on desired state. Repeating an already-completed
  operation returns `unchanged`.
- A replacement uses a new node identity plus `--template-node`; the original
  identity is never silently reused in the provider state.
- `configure --capacity` changes a simulated capacity value on an existing
  node. It never creates a node and is not evidence of automatic scaling.
- `sessions` changes only the bounded simulated assignment count. A nonzero
  count requires a healthy node with open admissions and cannot exceed its
  configured viewer capacity.
- `drain` requires stopped admissions and zero assignments, then persists its
  acknowledgement. `destroy` additionally requires that acknowledgement; it
  cannot remove a node merely because a caller claims it was drained.
- `destroy` is allowed only inside the explicit ephemeral state root. It does
  not delete Docker or cloud resources.

The action context persists an idempotency ledger bounded by the configured
registry limit and a monotonic generation per partition. An exact replay is
`unchanged`; an unseen stale generation or changed config/image digest fails
closed. The consumer validates the complete selected envelope without a
subprocess before the first mutation. Operational failure during the later
apply phase is not called atomic: it returns `partial_apply`, identifies the
already-applied bounded results and requires harness cleanup.

## Contract required from Task 09

Task 10 consumes the versioned local CLI action artifacts from Task 09 for the
milestone demonstration. A future runtime transport remains outside this
contract. Task 09 defines, without depending on this implementation:

1. an immutable decision/operation ID and monotonic deadline;
2. desired node role, tier (`origin`, `core`, `regional`, `viewer-edge`),
   provider, region, generation and capacity units;
3. observed node generation, lifecycle/health and last transition reason;
4. total and per-distributor assigned sessions, including an atomic assignment
   generation;
5. a capacity-configuration request with current capacity, used capacity,
   requested capacity and bounded reason enum; this request is not `create`;
6. drain intent, stop-admit acknowledgement, sessions remaining and completed
   acknowledgement before destroy;
7. replacement linkage (`replaces_node_id`, old/new generation) without
   treating IP or container name as identity;
8. rollback target generation and terminal outcome;
9. low-cardinality alerts and snapshots suitable for exact terminal equations;
10. cancellation and retry semantics for an idempotent provider call.

To request actual replacement or scale-out, Task 09 must issue an explicit
versioned `create` action carrying at least operation ID, unique node ID,
template/role, generation, provider, region, capacity and absolute deadline.
The integrated harness consumes the Task 09 `bootstrap`, `scenario-100-2`,
`replacement` and `cleanup` artifacts in order. A standalone Task 10 harness
continues to model its own replacement and reports that separately.

Task 10 assumes session assignments are counts and generations, not media
payloads. It does not assume a database, queue, cloud vendor, consensus
protocol, leader-election library, HTTP endpoint or authentication mechanism.
Those remain owned by Task 09 and its security review.

## Compatibility rule

Additive v1 fields may be ignored only when explicitly optional. Removing or
retyping a field, changing an enum meaning or weakening drain ordering requires
a new contract version. Simulation success cannot be relabelled as actual node
provisioning, real viewer continuity or provider interoperability.
