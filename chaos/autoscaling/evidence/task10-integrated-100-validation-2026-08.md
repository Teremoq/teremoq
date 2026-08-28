<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Task 10 integrated milestone-100 validation evidence

Date: 2026-08-28. Scope: local Task 09 action-envelope consumption, simulated
provider state and disposable hardened Docker containers on Ubuntu/WSL2.
Remote cost was zero. This is not evidence of video capacity, MoQT sessions,
media continuity, authentication, registration, cloud provisioning or
production readiness.

## Findings

- The consumer used the real Task 09 configuration loader, action guard, model
  enums and CLI-produced `bootstrap`, `scenario-100-2`, `replacement` and
  `cleanup` artifacts. It was bound to control-plane subtree
  `1ffd80a0b2135c86b5d11751aeca49ae791de53d`, independently of the repository
  `HEAD`.
- Complete semantic preflight rejects a two-action envelope when its second
  action has altered capacity or an expired deadline, with zero nodes,
  generations or idempotency entries created. A separate operational-failure
  test returns the stable `partial_apply` status and exit code 3, retains the
  explicit applied result, and performs bounded lifecycle cleanup.
- `--label` accepts only 1--32 lowercase alphanumeric/hyphen characters. The
  maximum valid label generated request IDs no longer than 51 characters;
  uppercase, underscore, slash and a 33-character label failed before state.
- The adapter independently rejects unknown v1 reasons, create with
  `requires_drained=true`, destroy with `requires_drained=false`, and destroy
  carrying replacement linkage. These direct bypass tests did not create the
  provider state root.
- Docker started with one control, reached three containers after bootstrap,
  and reached four only after the scenario action created the second core.
  Replacement creation preceded simulated assignment transfer. Early destroy
  failed specifically with `destroy_requires_drain_ack`; the same destroy
  succeeded after stop-admit, zero assignments and drain acknowledgement.
- The normal, injected-failure and final evidence runs all ended with zero
  Task-10-labelled containers, networks and volumes. Provider nodes were also
  zero before the ephemeral state root was removed.

## Binding and supply-chain evidence

| Item | Value |
| --- | --- |
| Milestone config file SHA-256 | `d6eb34768e62a87a39ab9cc4ba25d915198a2dc559c5c7b30930e77e55044506` |
| Config digest | `sha256:68e94c063b6e3fb51225dd0a815b61e5e3b496d1619fadf5b509003e8be23fe6` |
| Desired Task 09 fixture identifier | `sha256:07265afea47294d8bac3e450fb16c8c06403e9e4b86575d5816210f76ed8dd0b` |
| Mapped local simulator OCI | `teremoq-step7-lab:rust-1.93-full@sha256:ba076cf0a26aa41efdd2f0f80687ef97009d1526680751456c19cc944dff1d0b` |
| Simulator runtime script SHA-256 | `b91762fb91e3cde47fdcb320b8bc30cb2ba4aab15743dc143b849b78cef0da29` |
| Consumer SHA-256 | `4c478a6bc5c3d8248e37b8921f84c6f51b0d50c352771dd3103bef5bfeb029ad` |
| Provider adapter SHA-256 | `c5abf4a2a3b6fce3e289cc8eceade2cab3ac95ed2e0c09176c0e3554aa9da0e7` |
| Image map SHA-256 | `ba0c5d3c2c18969a28df34cb8b5fc83eb8121ea24e09a0c2fbc844f8a467faff` |
| Integrated harness SHA-256 | `f734c374196f942f68e4c73862eca3cf33b68001488830e1f6b484976e4bed97` |
| Standalone harness SHA-256 | `ca8343186318ea1cd95783a2f0c3e53c4a5c07adbcb6cd2fd4b63349489d57c4` |
| Ignored source report SHA-256 | `fa04929576811d2d33b5bfe83f300bfe625b015885c81c6df486a2daab379c9c` |

The fixture identifier and simulator OCI are intentionally distinct. The
versioned mapping accepted exactly this pair before Docker access. Production
remains blocked on a real, inventoried OCI digest in desired state.

## Integrated sample

| Metric | Observed value |
| --- | ---: |
| Requested/consumed simulated viewers | 100 / 100 |
| Envelope action results observed | 10 |
| Unique/planned actions consumed | 8 |
| Create/destroy actions consumed | 4 / 4 |
| Idempotent replays | 1 |
| Lifecycle rejections | 1 |
| Containers after control/bootstrap/scale-out/replacement | 1 / 3 / 4 / 4 |
| Simulated assignments after replacement | 100 |
| Simulated lost assignments | 0 |
| Replacement time, one sample | 11,710 ms |
| Total duration | 56,880 ms |
| Cleanup containers/networks/volumes/provider nodes | 0 / 0 / 0 / 0 |

The four idle-container samples ranged from 0.37% to 4.75% CPU and from
1.777 MiB to 3.793 MiB of the configured 64 MiB cgroup limit, with two to
eight PIDs. Host `/proc` RSS was unavailable from this WSL/Docker boundary and
was reported as `unavailable`, not zero. These single samples cannot be
extrapolated to load or capacity.

## Commands and results

```text
bash -n infra/virtual-nodes/*.sh infra/virtual-nodes/tests/*.sh chaos/autoscaling/*.sh chaos/autoscaling/tests/*.sh
  PASS
infra/virtual-nodes/tests/provider-adapter-test.sh
  PASS, including direct action-context semantic bypass rejection
infra/virtual-nodes/tests/action-envelope-consumer-test.sh
  PASS, including replay, stale generation, tampering, deadline, atomic preflight,
  partial apply/cleanup, label/request-id bounds, dry-run and 101/1000 rejection
infra/virtual-nodes/tests/compose-policy-test.sh
  PASS
chaos/autoscaling/tests/harness-test.sh
  PASS: profiles 10/25/50/100, dry-run, unique control identities and safety ceiling
chaos/autoscaling/tests/compose-smoke.sh
  PASS: normal standalone Compose and cleanup zero
chaos/autoscaling/tests/cleanup-failure-test.sh
  PASS: bounded nonzero failure, report and cleanup zero
chaos/autoscaling/tests/integrated-compose-test.sh
  PASS: progressive 1/3/4/4 topology, exact lifecycle rejection and cleanup zero
chaos/autoscaling/tests/integrated-cleanup-failure-test.sh
  PASS: injected failure after bootstrap, nonzero result, report and cleanup zero
run-integrated.sh --mode dry-run --viewers 100
  PASS with no provider or Docker mutation
run-integrated.sh --mode dry-run --viewers 101|1000
  PASS gate: both rejected with exit code 2
PYTHONPATH=control-plane/src python3 -m unittest discover -s control-plane/tests -v
  PASS: 47/47 Task 09 tests
git diff --check -- infra/virtual-nodes chaos/autoscaling
  PASS
REUSE 5.1.1 lint over the owned snapshot and Apache-2.0 license text
  PASS: 28/28 files licensed; network disabled
scan for persisted owner absolute paths
  PASS: no matches
Task-10 label inventory after all runs
  PASS: containers 0, networks 0, volumes 0
shellcheck
  NOT RUN: executable unavailable; it was not installed
```

Tooling: Bash 5.3.9, Python 3.14.4, Docker client/server 28.3.3,
Docker Compose 2.39.2-desktop.1, Git 2.53.0 and Linux
6.18.33.2-microsoft-standard-WSL2. No package, dependency, image, port,
credential or remote resource was added.

## Remaining boundaries

- Every spectator and session is an integer in a deterministic model. No
  video, QUIC, MoQT subscriber, player or Zero-Transcoding data path ran.
- The replacement measurement includes only this local container/state flow;
  it omits image distribution, DNS/BGP, PKI, real registration and media setup.
- Task 09 artifacts are consumed from local files. No live authenticated
  control transport or replicated controller is claimed.
- The milestone gate of 100 is configuration-owned. Rejection of 101 and
  1,000 is not an architectural ceiling or evidence for a larger audience.
