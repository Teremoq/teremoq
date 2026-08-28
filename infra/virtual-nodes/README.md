<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Task 10 local virtual-node laboratory

This directory owns a provider-neutral local topology for autoscaling and
lifecycle tests. The default is one origin, two distributors and one control
replica. It models placement and state; it is not the Teremoq control plane and
does not carry video.

## Topology and placement

| Service | Role | Tier | Provider | Region | Base simulated capacity |
| --- | --- | --- | --- | --- | ---: |
| `origin` | origin | origin | `local-a` | `eu-local-1` | not applicable |
| `distributor-a` | distributor | core | `local-a` | `eu-local-1` | 25 viewer units |
| `distributor-b` | distributor | regional | `local-b` | `eu-local-2` | 25 viewer units |
| `viewer-edge-template` | distributor template | viewer-edge | `local-b` | `eu-local-3` | 25 viewer units |
| `control` | control | control | `local-control` | `eu-local-control` | not applicable |

The adapter accepts future distributor templates with tier `viewer-edge` and
arbitrary validated provider/region tokens. The milestone Compose has exactly
one control identity. It deliberately does not use `docker compose --scale`,
because that would duplicate `NODE_ID=control` and create an unauthenticatable
topology. The state adapter can model additional controls as unique IDs such
as `control-r2`, but Task 09 must provide a versioned create decision with a
unique identity and generation before a future Compose overlay may instantiate
them. None of this proves consensus, registration, authentication or highly
available control.

## Container isolation

`compose.yaml` is self-contained and never modifies the root Compose file. It:

- uses one digest-pinned, locally pre-existing image with `pull_policy: never`;
- publishes no host ports and creates only project-scoped internal bridges;
- runs as UID/GID 65532 with read-only root filesystems and an 8 MiB tmpfs;
- drops all capabilities, enables `no-new-privileges` and never uses
  `privileged` or `NET_ADMIN`;
- limits every container to 0.25 CPU, 64 MiB memory and 32 PIDs;
- mounts only the hash-recorded node runtime read-only;
- labels containers and networks with owner, task and unique run ID;
- has no named or bind-mounted writable volume.

The runtime exposes only a local health sentinel and JSON lifecycle events. It
contains no certificate, credential, payload, transport or cloud endpoint.

## Provider adapter

`provider-adapter.sh` implements idempotent local
`plan/create/configure/health/sessions/stop-admit/fail/drain/destroy` in
`simulate` and `dry-run` modes.
Its state root must be an explicit absolute ephemeral path. See
`contract/v1/provider-adapter.md` for the executable response and the boundary
required from Task 09.

`action-envelope-consumer.py` binds the laboratory to the immutable
`control-plane` subtree `1ffd80a0b2135c86b5d11751aeca49ae791de53d` through
the calling harness. It imports the real Task 09 loader, action guard, enums
and serializer-compatible model from `control-plane/src`; it does not copy the
action-envelope schema. It preflights every selected action before invoking
the adapter, then records an explicit partial-apply result if an operational
provider call fails after an earlier call succeeded. Its `--label` is a
1--32-character lowercase token, so derived provider request IDs are always at
most 51 characters and remain below the adapter's 63-character bound.

The control-plane desired image value is currently a fixture identifier, not
the OCI image used by this lab. `contract/v1/image-map.tsv` is the explicit
versioned allow-list from that fixture to the separately pinned simulator OCI
and local image ID. An unmapped value is rejected before Docker is touched.
Production desired state still requires a real, inventoried OCI digest.

Example without Docker:

```bash
state_dir="$(mktemp -d /tmp/teremoq-provider-example.XXXXXX)"
infra/virtual-nodes/provider-adapter.sh \
  --contract-version 1 --mode simulate --operation plan \
  --request-id example-plan \
  --run-id t10-example --node distributor-a \
  --state-dir "${state_dir}" \
  --topology infra/virtual-nodes/topology/default.tsv
```

Do not point the state argument at a workspace root, home directory or shared
provider state. The autoscaling harness creates and removes its own root.

## Validation

```bash
bash -n infra/virtual-nodes/*.sh infra/virtual-nodes/tests/*.sh
infra/virtual-nodes/tests/provider-adapter-test.sh
infra/virtual-nodes/tests/action-envelope-consumer-test.sh
infra/virtual-nodes/tests/compose-policy-test.sh
```

The optional live-container smoke is owned by `chaos/autoscaling`; all runs
must finish with zero resources carrying their unique run label.
