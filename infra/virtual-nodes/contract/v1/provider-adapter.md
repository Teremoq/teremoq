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
  --operation plan|create|configure|health|drain|destroy \
  --request-id <bounded-token> \
  --run-id <bounded-token> \
  --node <bounded-node-id> \
  --state-dir <absolute-ephemeral-directory> \
  --topology <versioned-tsv> \
  [--template-node <existing-topology-node>] \
  [--capacity <unsigned-integer>]
```

Every successful call prints exactly one JSON object. The stable envelope is:

```json
{"schema_version":1,"contract":"teremoq.virtual-node.provider","mode":"simulate","operation":"create","request_id":"r1-create-distributor-a","run_id":"t10-example","node_id":"distributor-a","result":"changed","state":"created","reason":"created","duration_ms":1}
```

`result` is one of `changed`, `unchanged`, `planned`; `state` is one of
`planned`, `created`, `configured`, `healthy`, `drained`, `absent`. Reasons are
bounded enums from the adapter. Provider errors return nonzero and never emit
credentials, raw external errors or unbounded labels.

## Semantics

- `dry-run` validates syntax and emits `planned`; it never creates the state
  directory or invokes Docker.
- `plan` validates that the desired node or template exists and performs no
  state mutation.
- `create`, `configure`, `health`, `drain` and `destroy` converge on desired
  state. Repeating an already-completed operation returns `unchanged`.
- A replacement uses a new node identity plus `--template-node`; the original
  identity is never silently reused in the provider state.
- `configure --capacity` changes a simulated capacity value on an existing
  node. It never creates a node and is not evidence of automatic scaling.
- `drain` is only a provider lifecycle transition. Task 09 must move sessions
  and prove zero assignments before invoking it.
- `destroy` is allowed only inside the explicit ephemeral state root. It does
  not delete Docker or cloud resources.

## Contract required from Task 09

Task 10 will later consume a versioned control-plane decision stream. Task 09
must define, without depending on this implementation:

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
Task 10 currently injects its replacement `create` locally; it reports that
separately and consumes zero Task 09 create actions.

Task 10 assumes session assignments are counts and generations, not media
payloads. It does not assume a database, queue, cloud vendor, consensus
protocol, leader-election library, HTTP endpoint or authentication mechanism.
Those remain owned by Task 09 and its security review.

## Compatibility rule

Additive v1 fields may be ignored only when explicitly optional. Removing or
retyping a field, changing an enum meaning or weakening drain ordering requires
a new contract version. Simulation success cannot be relabelled as actual node
provisioning, real viewer continuity or provider interoperability.
