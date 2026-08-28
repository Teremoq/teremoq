# Teremoq control-plane foundation

Task 09 provides a deterministic, local and provider-neutral simulator for the
desired-state control plane. It demonstrates the **configured** 100-viewer gate;
it does not forward media, create infrastructure, call providers or claim real
video capacity.

The implementation uses Python's standard library only. Every queue and state
registry is configured and bounded. Capacity is calculated from authorized
viewers, active sessions, valid unexpired reservations and egress together. An
invalid, stale, replayed or unauthenticated sample fails closed and cannot
create or delete capacity. Authentication is represented only by an opaque
`VerifiedAuthContext` created by the external PKI boundary; this code performs
no cryptography. Configurable initial-demand, rate-of-change, maximum-node and
dated-cost limits also fail closed without partial provider actions.

## Quick verification

From the repository root:

```bash
control-plane/bin/control-plane \
  --config control-plane/config/milestone-100.json validate
PYTHONPATH=control-plane/src \
  python3 -m unittest discover -s control-plane/tests -v
control-plane/bin/control-plane \
  --config control-plane/config/milestone-100.json \
  demo --report-dir control-plane/reports/latest
```

The demo directory also contains pure `actions-*.json` files conforming to
`contracts/action-envelope.schema.json`. They are reproducible local plans for
an external Platform adapter; writing them performs no apply, transport or
provider call.

Or run the complete gate:

```bash
control-plane/scripts/verify.sh
```

The example starts from one origin and one core distributor. Demand at the
configured 100-viewer gate plus 10% reserve causes a second distributor to be
created by the simulator. The final topology is one origin, two distributors
and one configured controller. The progressive 10, 25, 50 and 100 viewer
scenarios are the only load scenarios executed by the gate.

## Layout

- `config/milestone-100.json`: reproducible local gate; all topology and scale
  values are data, not global program constants.
- `src/teremoq_control/`: strict loader, domain model, provider interface,
  regional reconciler, snapshots, cost model and CLI.
- `contracts/`: JSON Schema state/event contracts matched to real serializers
  and checked by stdlib validators. They define payloads, not a new transport
  protocol.
- `tests/`: unit and fast local E2E coverage.
- `docs/`: architecture, external integration requirements and operations.
- `reports/`: generated measured evidence and SHA-256 manifest.

`controller.replicas` accepts 1..1024 and partitions are configured as data.
The local milestone intentionally uses one controller. Production replication,
leases and an authenticated store are explicit integration gates and are not
simulated as if they already existed.

## Safety and limits

Only `local-simulator` with `simulate` or `dry-run` is accepted. There is no
provider SDK, network client, subprocess execution, credential loader or remote
resource type. Images and configuration snapshots use SHA-256 identifiers.

Metrics and desired-state schemas impose a JSON-safe numeric ceiling and a
per-sample reservation cardinality ceiling before run-specific configuration
applies stricter limits. Action envelopes have separately configured action,
byte and idempotency-registry bounds. These are payload/memory safety limits,
not viewer, node-topology or commercial scale ceilings; larger deployments
converge through bounded partition-local batches.

The configured `forbidden_execution_viewers` prevents this milestone command
from accidentally running a 1,000-viewer scenario. A configuration-only unit
test changes capacity and controller replica values and calculates a larger
arbitrary demand without allocating nodes or sessions, demonstrating that the
algorithm contains no named 100/1,000/10,000/100,000 scale branch.
