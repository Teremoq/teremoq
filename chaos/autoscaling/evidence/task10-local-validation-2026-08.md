<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Task 10 local validation evidence

Date: 2026-08-28. Scope: local simulation and one isolated Compose smoke on
Ubuntu/WSL2. This evidence does not measure video delivery, MoQT throughput,
real viewer sessions, cloud provisioning, authentication, registration,
control-plane HA or production capacity.

## Findings

- The 10/25/50/100 profiles consumed exactly the requested number of simulated
  viewer counters and ended with zero simulated lost assignments.
- Capacity changes at 50 and 100 were `configure` calls against existing
  simulated nodes. They did not create capacity or consume a Task 09 `create`
  decision.
- Replacement used one harness-injected `create` with the distinct identity
  `distributor-a-r1`. Session continuity was only an integer invariant.
- The milestone Compose ran one uniquely identified control. Additional
  logical controls were tested separately as `control`, `control-r2`,
  `control-r3`, and `control-r4`; this is not a claim of HA.
- Normal and deliberately failed Compose runs both ended with zero resources
  carrying their run ID across containers, networks and volumes.

## Profile matrix

| Profile | Split A/B | Capacity config changes | Task 09 creates | Injected replacement creates | After replacement/drain | Lost |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10 | 5/5 | 0 | 0 | 1 | 10/10 | 0 |
| 25 | 13/12 | 0 | 0 | 1 | 25/25 | 0 |
| 50 | 25/25 | 2 | 0 | 1 | 50/50 | 0 |
| 100 | 50/50 | 2 | 0 | 1 | 100/100 | 0 |

The state-only single-sample replacement times were 340, 350, 420 and 460 ms
for profiles 10, 25, 50 and 100. These are local harness timings, not node boot
or recovery SLOs.

## Compose sample

The profile-100 Compose smoke passed with four containers, two internal
networks and no host ports. Its one resource observation was:

| Role | CPU sample | Memory sample | PIDs |
| --- | ---: | ---: | ---: |
| control | 6.60% | 1.992 MiB / 64 MiB | 2 |
| distributor A | 6.12% | 2.234 MiB / 64 MiB | 2 |
| distributor B | 5.41% | 1.863 MiB / 64 MiB | 2 |
| origin | 5.45% | 2.246 MiB / 64 MiB | 2 |

The distributor recreation took 9,080 ms; reassignment, drain and rollback
model transitions took 10, 440 and 0 ms. This is one idle-container sample and
cannot be extrapolated to real spectators. Cleanup reported containers 0,
networks 0 and volumes 0. The ignored source report SHA-256 was
`5480299785122a15fbe114a16d9d0fb4654f0bd9697bed752a0935ff5274a847`.

## Commands and outcomes

```text
bash -n infra/virtual-nodes/*.sh infra/virtual-nodes/tests/*.sh chaos/autoscaling/*.sh chaos/autoscaling/tests/*.sh
  PASS
infra/virtual-nodes/tests/provider-adapter-test.sh
  PASS
infra/virtual-nodes/tests/compose-policy-test.sh
  PASS
chaos/autoscaling/tests/harness-test.sh
  PASS (10/25/50/100, dry-run, four unique controls, configured ceiling rejection)
chaos/autoscaling/tests/compose-smoke.sh
  PASS (normal cleanup zero)
chaos/autoscaling/tests/cleanup-failure-test.sh
  PASS (nonzero failure preserved, report written, cleanup zero)
chaos/autoscaling/run.sh --profile {10,25,50,100} --mode simulate
  PASS for all profiles
chaos/autoscaling/run.sh --profile 100 --mode simulate --compose --control-replicas 1
  PASS
REUSE 5.1.1 lint over the owned snapshot plus repository Apache-2.0 text
  PASS: 22/22 files licensed (generated ignored reports excluded)
shellcheck
  NOT RUN: executable unavailable; it was not installed
```

Docker used the pre-existing immutable image
`teremoq-step7-lab:rust-1.93-full@sha256:ba076cf0a26aa41efdd2f0f80687ef97009d1526680751456c19cc944dff1d0b`
with `pull_policy: never`. No image, crate, package or dependency was added.

## Contract still required from Task 09

Task 09 must provide the versioned decision/action envelope described in
`infra/virtual-nodes/contract/v1/provider-adapter.md`. In particular, a real
scale-out needs an explicit `create` action with unique node ID and generation;
capacity configuration cannot stand in for creation. It must also own atomic
assignment generations, stop-admit/drain ordering, terminal acknowledgement,
replacement linkage, deadlines, idempotent retry/cancellation and bounded
low-cardinality telemetry. Until that contract is connected, every session,
failure, replacement and recovery result here remains simulated.
