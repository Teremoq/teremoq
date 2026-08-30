<!-- SPDX-FileCopyrightText: 2026 Teremoq contributors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Two-host deployment preparation

This directory is a provider-neutral, planning-only boundary for a first real
two-host deployment. It neither selects a provider nor provisions, pulls,
starts, registers or deletes anything remotely. `inventory.example.tsv`
contains no usable endpoint, image, identity, certificate or key. A copied
inventory fails validation until every `REQUIRED_*` value is resolved outside
the repository.

## Architecture and limits

| Host | Fixed services | Configurable placement |
| --- | --- | --- |
| Host A | origin, distributor A | host ID, provider, region, zone, address |
| Host B | control, distributor B | host ID, provider, region, zone, address |

Each of the four services has a distinct mTLS identity and distinct certificate
and key paths. Sharing a service identity or credential path is rejected. The
trust bundle may be common, but trust material and private keys remain mounted
runtime inputs outside Git. SRT source authentication/encryption is a separate
ingress concern; calling SRT mTLS would be inaccurate.

Every OCI coordinate must end in `@sha256:<64 lowercase hex>`. Tags alone,
floating channels and the Task 09 simulator fixture are rejected. This
preparation deliberately contains no claim about a productive Teremoq image:
the real inventoried origin, distributor and control digests remain an external
release gate.

Two hosts do **not** provide high availability. Origin remains a single point
of failure on Host A; control remains a single point of failure on Host B. A
host failure also removes its colocated distributor. This topology proves
neither origin replication, controller consensus/failover nor HA. The current
`infra/virtual-nodes` and `chaos/autoscaling` laboratory uses inert containers
and simulated integer counters; it carries no video and opens no real MoQT
viewer sessions.

## Validation and immutable inventory

Create the real inventory outside the repository and restrict its permissions.
The validator only parses data; it never sources the file or executes a value.

```bash
cp infra/deployment/two-host/inventory.example.tsv /ABSOLUTE/PRIVATE/PATH/inventory.tsv
# Resolve all non-secret coordinates and paths manually.
infra/deployment/two-host/validate-inventory.sh \
  --inventory /ABSOLUTE/PRIVATE/PATH/inventory.tsv
```

Validation is necessary but not authorization to deploy. Before bootstrap,
record the inventory checksum, the three resolved OCI digests, the release
inventory approval, the four certificate fingerprints/identity URIs and the
operator/change authorization. Never copy certificate or key contents into a
report.

## Ports and firewall intent

The final rules must be generated from the validated inventory and default to
deny. No management plane is made public by this preparation.

| Source | Destination | Protocol/port | Required policy |
| --- | --- | --- | --- |
| explicitly authorized SRT senders | Host A / origin | UDP / `srt_ingest_udp_port` (default template 9000) | source allow-list, SRT Stream ID authorization, encryption; deny all others |
| origin on Host A | distributors A and B | UDP / `moqt_udp_port` (default template 4433) | service identity/namespace authorization and mTLS/QUIC trust |
| explicitly authorized viewers/probes | distributors A and B | UDP / `moqt_udp_port` | viewer identity and namespace authorization, limits; deny all others |
| origin and both distributors | control on Host B | TCP / `control_api_tcp_port` | service mTLS only; port is unresolved in the template |
| operator network | both hosts | operator-selected management channel | out of band, source allow-listed; no port is invented here |

Health endpoints remain loopback or service-network only. TCP/4433 is not
opened merely because UDP/4433 is used. Firewall evidence must include the
rendered rules, counters during the test and a negative connection check from
an unauthorized source.

## Mandatory preflight

Run these checks locally on **each** target host; this repository does not use
SSH or a provider API. Every threshold comes from the resolved inventory or an
approved trial plan, not from this template.

1. **Kernel:** compare `uname -r` to `minimum_kernel`; confirm required QUIC/UDP
   buffers, cgroup and container-runtime features. Fail on an unknown or older
   release.
2. **Clock:** use the approved time source to record synchronization state and
   measured offset. Require absolute offset no greater than
   `maximum_clock_offset_ms`; a boolean “synchronized” without numeric evidence
   is insufficient for audiovisual recovery measurements.
3. **UDP/firewall:** prove SRT ingress to Host A and MoQT/QUIC reachability to
   each distributor in both permitted paths, then prove an unauthorized source
   is denied. A local `ss` listing alone is not reachability evidence.
4. **Capacity:** record physical/logical CPU, available memory, writable scratch
   capacity, NIC link, sustained permitted egress and current reservations.
   Compare Host A and B independently with their `host_*_minimum_*` values.
5. **Supply chain:** verify already-staged image bytes against each inventory
   digest and review provenance/license inventory. Do not substitute the local
   virtual-node image.
6. **Identity:** verify file ownership/mode, validity window, trust chain,
   revocation policy and exact service identity for all four credentials.

Missing tools, unavailable numeric clock offset, an unresolved placeholder or
an untested UDP direction blocks bootstrap. Save only non-secret output in the
trial evidence directory.

## Lifecycle runbook

All steps are fail-closed and require a new health/identity check before the
next step. Commands named below are pending integration with the selected,
already-existing runtime and real service CLIs; this freeze does not invent a
provider adapter or a viewer generator.

1. **Bootstrap:** apply default-deny firewall first; stage verified digest-bound
   images; mount four separate identities read-only; start control, origin and
   distributors with read-only roots, non-root UIDs, limits and bounded restart
   policy. Capture service/image/host identity, never secret values.
2. **Health:** require process, local dependency, mTLS peer, transport and media
   readiness independently. A running container is not healthy and an idle
   healthcheck is not media capacity evidence.
3. **Registration:** register origin and both distributors with control using
   their own identity. Require expected deployment, namespace, provider,
   region, zone, host and image digest; reject duplicate or stale identities.
4. **Traffic admission:** admit only the authorized source and progressive
   viewer manifest after all entry gates in
   `chaos/autoscaling/real-two-host-trial.md` pass.
5. **Drain:** stop new admissions, move sessions, wait for active sessions and
   reservations to reach zero, preserve critical data only within its bounded
   deadline, then record drain acknowledgement. Never destroy before it.
6. **Substitution:** reserve capacity on the surviving distributor, bootstrap a
   generation-distinct replacement from an approved digest, validate identity,
   health and registration, transfer admissions, measure media recovery, then
   drain the old instance. With only two hosts, replacement on the same failed
   host is impossible until that host returns and is not HA.
7. **Rollback:** freeze new admission, restore the last complete digest-bound
   configuration and routing generation, validate health/registration and move
   only authorized sessions back. Do not roll back onto a drained/unhealthy
   target or discard the evidence from the failed generation.
8. **Cleanup:** after zero sessions/reservations and drain acknowledgement,
   remove run-labelled service instances, ephemeral networks/state and firewall
   rules. Retain only approved non-secret evidence; prove zero resources by the
   unique run label on both hosts.
9. **Kill switch:** first deny new viewer/source admission and control actions,
   then close external ingress while leaving evidence and bounded graceful
   drain available. Destruction is a separate, explicit operator action after
   session accounting. The kill switch must work when control is unavailable;
   host-local commands remain pending on the chosen runtime.

Required command bindings before any real run are:
`RUNTIME_INSPECT_IMAGE_CMD`, `RUNTIME_START_SERVICE_CMD`,
`SERVICE_HEALTH_CMD`, `SERVICE_REGISTER_CMD`, `SERVICE_STOP_ADMIT_CMD`,
`SERVICE_DRAIN_CMD`, `SERVICE_SESSION_COUNT_CMD`,
`SERVICE_RESERVATION_COUNT_CMD`, `RUNTIME_REMOVE_BY_RUN_LABEL_CMD`,
`FIREWALL_APPLY_CMD`, `FIREWALL_ROLLBACK_CMD` and `HOST_KILL_SWITCH_CMD`.
They must point to reviewed existing tooling, use argument arrays rather than
string evaluation, and be recorded in the private change plan. Until every
binding and preflight result exists, bootstrap is blocked.

## Local policy validation

The policy test proves that the unresolved template fails, a complete
non-production fixture passes, and tag-only images, duplicate mTLS identities
and unknown fields fail closed.

```bash
bash -n infra/deployment/two-host/*.sh \
  infra/deployment/two-host/tests/*.sh
infra/deployment/two-host/tests/inventory-policy-test.sh
```
