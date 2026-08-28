<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Task 10 autoscaling and virtual-node Chaos harness

The harness tests a finite state model for 10, 25, 50 and 100 simulated
spectators. A spectator is a counter and assignment generation, not a process,
QUIC connection, MoQT subscriber or media decoder. Results must never be used
as evidence that the relay can deliver video to that audience.

## Scenarios

Every `simulate` profile:

1. plans, creates, configures and health-checks one origin, two distributors
   and the requested logical control identities, including repeated
   idempotency calls;
2. splits the requested viewer count deterministically across both
   distributors;
3. requests a capacity configuration change when a distributor would exceed
   80% of its 25-unit base; this does not create a node;
4. injects failure of distributor A, creates a generation-distinct replacement
   and reassigns its simulated sessions;
5. moves remaining sessions before draining distributor B;
6. rejects a stale assignment to the drained node and restores the prior
   complete assignment;
7. drains/destroys state idempotently and proves zero run-labelled Docker
   resources after cleanup.

The 80% rule is a test alert threshold, not a product autoscaling policy or
SLO. Task 09 owns the real decision logic.

## Usage

Pure local state simulation, no containers:

```bash
chaos/autoscaling/run.sh --profile 10
chaos/autoscaling/run.sh --profile 25
chaos/autoscaling/run.sh --profile 50
chaos/autoscaling/run.sh --profile 100
```

Mutation-free adapter validation:

```bash
chaos/autoscaling/run.sh --profile 100 --mode dry-run
```

Optional local Compose smoke using only the already-present digest-pinned
image, with no pull and no host ports:

```bash
chaos/autoscaling/run.sh --profile 10 --compose --control-replicas 1
```

The integrated milestone flow consumes the four real Task 09 CLI artifacts.
It starts only one local control container, creates origin and the first core
from `bootstrap`, and creates the second core only after consuming
`scenario-100-2`. Replacement creates the new core and waits for local health
before transferring the simulated assignment counts; the old core is removed
only after stop-admit, zero assignments and drain acknowledgement.

```bash
chaos/autoscaling/run-integrated.sh --mode dry-run --viewers 100
chaos/autoscaling/run-integrated.sh --mode simulate --docker --viewers 100
```

The default binds to `control-plane` in the same repository and verifies its
immutable subtree rather than requiring a particular global `HEAD`. The
`TEREMOQ_CONTROL_REPO` override exists only for the owner laboratory. The
milestone configuration accepts exactly 100 simulated viewers and rejects 101
and 1,000; this is a run configuration gate, not a global architectural
ceiling. A future authorized configuration may raise it without changing the
consumer.

The milestone Compose accepts exactly one control replica because its single
service has one fixed unique identity. Pure `simulate`/`dry-run` can exercise
unique IDs `control`, `control-r2`, and so on. The run-local safety ceiling is
configured with `TEREMOQ_AUTOSCALING_MAX_CONTROL_REPLICAS` (default 8) and the
harness has a technical bound of 64 calls per run; neither is an architectural
control-plane limit. Profiles above 100 are rejected. There is no
1,000-viewer profile or soak mode.

## Reports and alerts

Generated reports are ignored under `reports/`. Each includes requested and
consumed profile, placement, capacity configuration changes, distinct injected
replacement creates, session-count invariants,
single-sample replacement/reassignment/drain/rollback times, one optional
Docker resource sample, alerts, immutable image/runtime hashes and cleanup
counts. Unavailable or inapplicable metrics are never converted to zero.

Stable alert events include:

- `capacity_configuration_requested` / `utilization_above_80_percent`;
- `node_unhealthy` / `injected_distributor_failure`;
- `rollback_complete` / `target_node_drained`;
- `cleanup_residue` / `cleanup_incomplete`.

The first two warnings/critical events are deliberately injected and must be
observable. `cleanup_residue` makes an otherwise successful run fail with a
nonzero exit. Reports contain no media, credentials, certificates, external
addresses or cloud identifiers.

## Validation

```bash
bash -n chaos/autoscaling/*.sh chaos/autoscaling/tests/*.sh
infra/virtual-nodes/tests/provider-adapter-test.sh
infra/virtual-nodes/tests/compose-policy-test.sh
chaos/autoscaling/tests/harness-test.sh
chaos/autoscaling/tests/compose-smoke.sh
chaos/autoscaling/tests/cleanup-failure-test.sh
chaos/autoscaling/tests/integrated-compose-test.sh
chaos/autoscaling/tests/integrated-cleanup-failure-test.sh
```

Run `shellcheck` when locally available. This Task adds no Rust, manifest,
lockfile, dependency or new image; Rust gates are therefore not applicable.

## Explicit limitations

- Session continuity and reassignment are integer invariants in a model, not
  physical media recovery or proof of no player interruption.
- Replacement has no cloud boot, image distribution, BGP/DNS, mTLS issuance,
  state replication or MoQT setup latency.
- The single Compose control is inert. Additional simulated control identities
  do not claim consensus, registration, authentication, leader election or HA.
- CPU/memory observations describe idle disposable node containers, not viewer
  load or video capacity.
- Provider/region labels prove placement neutrality of the harness only. No
  provider API or interoperability is exercised.
- The integrated flow consumes local serialized Task 09 decisions, but does
  not provide a live transport, consensus or remote provider execution.
- The Task 09 image digest is currently a fixture identifier. The lab maps it
  explicitly to a distinct local simulator OCI; production requires a real
  inventoried OCI digest in desired state.
