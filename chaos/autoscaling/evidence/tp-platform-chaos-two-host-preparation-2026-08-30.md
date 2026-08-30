<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# TP-PLATFORM-CHAOS binding and two-host preparation evidence

Date: 2026-08-30. Base commit:
`538203cc5fb5fedb9698c756ec63c0462ed4b222`; base tree:
`c0c1fac5e54fc9519a2a2d0e54d49649cb81f715`. Work was local to the delegated
worktree, with no remote execution, publication, push, credential access,
provider selection or cost.

## Findings

1. The initial action-envelope consumer failed closed with
   `control-plane subtree binding changed`. The repository already contained
   control-plane tree `55f5faf0458e50bd684dd5a5f1646b255606aab2`; only the
   recorded binding still named the pre-license-metadata tree.
2. The subtree and unchanged milestone configuration hash are now centralized
   in one immutable contract file and consumed by a shared verifier. The
   consumer test creates a real temporary Git repository with a different
   control-plane tree and proves rejection before testing the accepted tree.
3. The two-host material is planning-only and fail-closed. The unresolved
   inventory rejects itself. A policy test proves digest-only OCI enforcement,
   distinct mTLS service identities/credential paths and rejection of unknown
   fields. No productive image, provider, endpoint, certificate, secret or cost
   appears in the repository.
4. Host A is fixed to origin plus distributor A; Host B is fixed to control plus
   distributor B. Origin and control remain SPOFs and the topology is not HA.
5. The progressive 10/25/50/100 plan requires authorized real spectators, real
   MoQT sessions/reservations, measured egress, a real capacity creation,
   correlated audiovisual recovery, drain and deletion. Existing harnesses are
   explicitly counter/container simulations and cannot satisfy those gates.
   A 1,000-viewer trial remains blocked.
6. No obsolete hash remains in the three owned pathsets. One historical
   reference remains in `supervisor-web/TASK-12-OPERATIONS-DASHBOARD-REPORT.md`;
   it is not an active binding and was not changed because `supervisor-web/**`
   is explicitly outside TP-PLATFORM-CHAOS ownership for this delegation.

## Binding and artifact hashes

| Artifact | SHA-256 |
| --- | --- |
| control-plane binding | `2270b970015d0a9d45e67dea51843217028858955e551f0e2fb1c13774e8fe4c` |
| binding verifier | `c7e1e90ae9a2fd680faa25ce535f4f29557805aeebb2ad0b1a155cc0912906b3` |
| action-envelope consumer test | `d6673e096fcf351851ea361283597909aef2eafc440e02cfc194dabcf8bed396` |
| integrated harness | `fdcfb64bd0005d9bd6e56e5a1da5fbd6b8fddd5ca5ba72bca91ce5f11bb7b499` |
| two-host inventory template | `996640141566ff54b919ecae31ca4e43d6c93c0db0de336eb5430eefdc43d1c5` |
| two-host inventory validator | `de74786b29ff57f9a371f5870233a81a3555cc0f42cf3fb4614dc4f0461a9d47` |
| two-host runbook | `63243a833be00c7e449dcb7308af95b454320274e56c589d64916b089acd89f1` |
| inventory policy test | `57ef457030cd057a132ca44556e594176f106b48238fe597021ceb66f983b272` |
| progressive real-trial gate | `44aef4a1b3f59079794f0297234e81f753257dc481290ad103a8977d316eac62` |

The accepted milestone configuration SHA-256 remains
`d6eb34768e62a87a39ab9cc4ba25d915198a2dc559c5c7b30930e77e55044506`.

## Commands and observed results

```text
bash -n (all 16 shell files under the three owned pathsets)
  PASS
infra/deployment/two-host/tests/inventory-policy-test.sh
  PASS: unresolved, tag-only, duplicate-identity and unknown-field rejection
infra/virtual-nodes/tests/provider-adapter-test.sh
  PASS
infra/virtual-nodes/tests/action-envelope-consumer-test.sh
  PASS: accepted tree plus distinct real Git subtree rejection
infra/virtual-nodes/tests/compose-policy-test.sh
  PASS
chaos/autoscaling/tests/harness-test.sh
  PASS: profiles 10/25/50/100 and dry-run/control identity gates
chaos/autoscaling/run-integrated.sh --mode dry-run --viewers 100
  PASS
chaos/autoscaling/run-integrated.sh --mode dry-run --viewers 101|1000
  PASS gate: both rejected with exit code 2
chaos/autoscaling/tests/integrated-compose-test.sh
  PASS
chaos/autoscaling/tests/cleanup-failure-test.sh
  PASS
chaos/autoscaling/tests/integrated-cleanup-failure-test.sh
  PASS
chaos/autoscaling/tests/compose-smoke.sh
  PASS
git diff --check over owned paths; obsolete subtree-hash scan over owned paths
  PASS; no old hash remains in the authorized pathsets
final teremoq.owner=TP-PLATFORM-CHAOS label inventory
  PASS: containers 0, networks 0, volumes 0
shellcheck
  NOT RUN: executable unavailable; no installation attempted
```

Tooling: Bash 5.3.9, Python 3.14.4, Git 2.53.0, Docker client/server
28.3.3, Docker Compose 2.39.2-desktop.1 and Linux
6.18.33.2-microsoft-standard-WSL2.

## Real deployment gate still pending

No two-host command was executed. Bootstrap remains blocked on a private
validated inventory; productive inventoried OCI digests; selected host/provider
coordinates; distinct issued mTLS credentials; numeric kernel/clock/UDP and
capacity preflight; default-deny firewall evidence; reviewed existing runtime,
service and real-viewer command bindings; authorized spectator manifests; and
approved audiovisual/session/egress thresholds. None may be inferred from the
passing simulation.
