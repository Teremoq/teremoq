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

The schemas in `contracts/` describe state payloads only. `audit-event` matches
`Event.to_dict()`, `metrics-sample` matches `MetricsSample.to_dict()`,
`desired-state` matches `ControlPlane.desired_state()` and the action envelope
matches `ControlPlane.action_envelope()`. The demo emits the latter as local
`actions-*.json` files. Stdlib validators reject
unknown/missing fields and structural divergence. Integration must use
an existing authenticated transport and serialization selected by ADR (for
example an existing HTTPS/gRPC or durable event-store interface); it must not
invent a Teremoq wire protocol. Payload size, request rate, authentication,
authorization and cardinality limits remain mandatory.

The schema-level JSON-safe numeric maxima and reservation/action cardinalities
are per-payload security limits. The validator additionally receives the
equal-or-smaller configured limits for a run. They are not viewer-count or
deployment-scale ceilings; partition reconcilers converge through bounded
batches.

## Security/PKI review gate

`VerifiedAuthContext` is only an opaque reference containing verification ID,
principal reference and verification time. Its presence means an external,
reviewed PKI adapter already verified the sample; the control plane does not
verify signatures or parse trust material. Before integration, `TP-SEC-PKI`
must define how that context is created and bound to the sample and reservation.
Raw certificates, keys, tokens, signatures and customer namespaces must never
enter events, metrics, reports or this repository. Missing/invalid context maps
to stable fail-closed rejection codes.

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

The version-1 local action envelope contains deployment/partition generation,
immutable image/config digests and a bounded action array. Every action carries
operation, node/generation fencing, neutral placement, requested viewer/egress
capacity, a low-cardinality versioned reason and an absolute logical
`deadline_at`. A create may carry `replaces_node_id`; a destroy always carries
`requires_drained=true`. The SHA-256 idempotency key covers canonical JSON for
all envelope context and action semantics. An adapter must persist the last
accepted generation per partition and accepted keys: an older generation fails
closed and a replay is a no-op. Registry saturation also fails closed; keys are
never evicted merely to accept work. The local `ActionEnvelopeGuard`
demonstrates those decisions without invoking a provider. Logical deadlines are
derived from bounded lifecycle/drain configuration and do not claim wall-clock
synchronization.

Replacement is ordered: create capacity, reach ready, drain assignments and
only then emit destroy for the old resource. An unresolved drain emits no
destroy, leaves the old node in `replacing`, preserves its assignments and is
retryable through `retry_replacement_cleanup()`. Final shutdown includes any
still-pending replacement cleanup after the explicit local session cleanup.

No real provider adapter, API request, credential, billing action or remote
resource is included in this foundation. Platform has not consumed or accepted
these files yet; transport, durable storage and execution remain review gates.

## Session capacity and unresolved drain

An assignment update is rejected before mutation unless the ready distributors
have enough aggregate and per-node viewer capacity. A drain plans all moves
before changing any assignment. Insufficient peer capacity leaves the original
assignments on the draining/replacing node and emits `node_drain_unresolved`;
it never emits `node_drained`. Timeout repeats the explicit unresolved alert and
preserves assignments. A future data-plane policy may authorize forced session
termination, but that policy is not invented or enabled by Task 09.

## Compose/infrastructure follow-up

The current `docker-compose.yml` uses floating images and publishes unrelated
services. Its owner must eventually add a digest-pinned, non-root control image,
read-only filesystem, internal network, health check, resource bounds and no
public port by default. Task 09 does not edit compose. The federated relay
admission blockers in ADR-0006 remain independent of container resource limits.
