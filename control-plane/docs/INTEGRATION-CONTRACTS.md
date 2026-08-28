# External integration requirements

This document records required changes outside `control-plane/**`. Task 09 does
not implement or authorize them.

## Gateway/data-plane contract

The Gateway owner must expose a bounded control adapter outside the media path:

- A snapshot containing authorized viewer count, active session count, measured
  egress Mbps and valid capacity reservations for one regional partition.
- `sample_id`, monotonically increasing `sequence`, UTC observation time and a
  verified authenticated principal supplied by the PKI/security boundary.
- Reservations with unique ID, viewer capacity, expiry, authorization ID and
  replay nonce. Expired or replayed reservations must not be renewed implicitly.
- Node heartbeats with node ID, desired generation, image digest, configuration
  digest and lifecycle state.
- Drain acknowledgment only after new admissions stop and sessions reach zero
  or the configured drain deadline. On deadline, the data-plane owner decides
  session termination policy; control must not silently claim a clean drain.

The Gateway must retain last-known routing/configuration locally so existing
sessions continue when controllers are unavailable. It must never synchronously
query the control plane for an Object, Group, Track or per-packet decision.

The schemas in `contracts/` describe state payloads only. Integration must use
an existing authenticated transport and serialization selected by ADR (for
example an existing HTTPS/gRPC or durable event-store interface); it must not
invent a Teremoq wire protocol. Payload size, request rate, authentication,
authorization and cardinality limits remain mandatory.

## Security/PKI review gate

`signature_valid` in the local model is test input, not cryptography. Before
integration, `TP-SEC-PKI` must define how the authenticated node/principal is
bound to the sample and reservation before reconciliation. Raw certificates,
keys, tokens and customer namespaces must never enter events, metrics, reports
or this repository. Authentication failure must map to a stable rejection code.

ADR-0005 still blocks authenticated SPIFFE-to-namespace authorization in the
pinned relay. This task does not weaken that boundary or infer identity from IP,
SNI, path or peer-declared fields.

## Replicated state and controller lease gate

A multi-controller deployment needs an existing, reviewed replicated store with:

- compare-and-swap partition lease containing owner, generation and monotonic
  expiry;
- append-only event order per partition and snapshot storage by SHA-256 digest;
- fencing of an expired writer before another generation mutates desired state;
- bounded compaction with a snapshot-required response for expired cursors;
- quorum and recovery behavior documented for 3 or more replicas;
- encryption, access control, backup/restore and audit retention owned outside
  this task.

No controller coordinates every viewer. Only partition desired state and
aggregate capacity signals are replicated. A local single controller is the
declared Task 09 limitation.

## Provider adapter gate

A real adapter must implement idempotent `plan/apply/destroy`, support dry-run,
use immutable images by digest, tag every operation with node ID and generation,
and return provider events without leaking credentials or raw error strings.
It must validate quota, budget, region and zone before apply. Prices require an
explicit currency, source and `as_of` date supplied by the cost owner; missing
tariffs produce `external_provider_estimate=null`, never an invented value.

No real provider adapter, API request, credential, billing action or remote
resource is included in this foundation.

## Compose/infrastructure follow-up

The current `docker-compose.yml` uses floating images and publishes unrelated
services. Its owner must eventually add a digest-pinned, non-root control image,
read-only filesystem, internal network, health check, resource bounds and no
public port by default. Task 09 does not edit compose. The federated relay
admission blockers in ADR-0006 remain independent of container resource limits.
