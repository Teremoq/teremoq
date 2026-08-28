# SPDX-License-Identifier: Apache-2.0
"""Bounded domain model for the control plane.

The model deliberately contains no media payload and no transport primitive.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from enum import StrEnum
from typing import Any


class Tier(StrEnum):
    ORIGIN = "origin"
    CORE = "core"
    REGIONAL = "regional"
    VIEWER_EDGE = "viewer-edge"


class ActionReason(StrEnum):
    CONFIGURED_MINIMUM = "configured_minimum"
    AUTOSCALE_OUT = "autoscale_out"
    AUTOSCALE_IN = "autoscale_in"
    FAILED_NODE_REPLACEMENT = "failed_node_replacement"
    FAILED_NODE_CLEANUP = "failed_node_cleanup"
    SAFE_SHUTDOWN = "safe_shutdown"


class Lifecycle(StrEnum):
    REQUESTED = "requested"
    PROVISIONING = "provisioning"
    BOOTSTRAPPING = "bootstrapping"
    AUTHENTICATED = "authenticated"
    REGISTERED = "registered"
    READY = "ready"
    DRAINING = "draining"
    TERMINATED = "terminated"
    FAILED = "failed"
    REPLACING = "replacing"


FORWARD_TRANSITIONS: dict[Lifecycle, frozenset[Lifecycle]] = {
    Lifecycle.REQUESTED: frozenset({Lifecycle.PROVISIONING, Lifecycle.FAILED}),
    Lifecycle.PROVISIONING: frozenset({Lifecycle.BOOTSTRAPPING, Lifecycle.FAILED}),
    Lifecycle.BOOTSTRAPPING: frozenset({Lifecycle.AUTHENTICATED, Lifecycle.FAILED}),
    Lifecycle.AUTHENTICATED: frozenset({Lifecycle.REGISTERED, Lifecycle.FAILED}),
    Lifecycle.REGISTERED: frozenset({Lifecycle.READY, Lifecycle.FAILED}),
    Lifecycle.READY: frozenset({Lifecycle.DRAINING, Lifecycle.FAILED}),
    Lifecycle.DRAINING: frozenset({Lifecycle.TERMINATED, Lifecycle.FAILED}),
    Lifecycle.FAILED: frozenset({Lifecycle.REPLACING, Lifecycle.TERMINATED}),
    Lifecycle.REPLACING: frozenset({Lifecycle.DRAINING, Lifecycle.TERMINATED}),
    Lifecycle.TERMINATED: frozenset(),
}


@dataclass(frozen=True, slots=True)
class Placement:
    provider: str
    region: str
    zone: str

    @property
    def partition(self) -> str:
        return f"{self.provider}/{self.region}"


@dataclass(slots=True)
class Node:
    node_id: str
    tier: Tier
    placement: Placement
    image_digest: str
    config_digest: str
    generation: int
    state: Lifecycle
    state_entered_at: int
    capacity_viewers: int
    capacity_egress_mbps: int
    sessions: set[str] = field(default_factory=set)
    replace_node_id: str | None = None

    def to_dict(self) -> dict[str, Any]:
        value = asdict(self)
        value["tier"] = self.tier.value
        value["state"] = self.state.value
        value["sessions"] = sorted(self.sessions)
        return value


@dataclass(frozen=True, slots=True)
class Reservation:
    reservation_id: str
    viewers: int
    expires_at: int
    authorization_id: str
    nonce: str

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True, slots=True)
class VerifiedAuthContext:
    """Opaque reference created only by the external authentication boundary."""

    verification_id: str
    principal_ref: str
    verified_at: int

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True, slots=True)
class MetricsSample:
    sample_id: str
    partition: str
    sequence: int
    observed_at: int
    authorized_viewers: int
    active_sessions: int
    egress_mbps: int
    reservations: tuple[Reservation, ...] = ()
    auth_context: VerifiedAuthContext | None = None

    def to_dict(self) -> dict[str, Any]:
        if self.auth_context is None:
            raise ValueError("verified external auth context is required for serialization")
        return {
            "schema_version": 1,
            "sample_id": self.sample_id,
            "partition": self.partition,
            "sequence": self.sequence,
            "observed_at": self.observed_at,
            "authorized_viewers": self.authorized_viewers,
            "active_sessions": self.active_sessions,
            "egress_mbps": self.egress_mbps,
            "reservations": [reservation.to_dict() for reservation in self.reservations],
            "auth_context": self.auth_context.to_dict(),
        }


@dataclass(frozen=True, slots=True)
class CapacitySignal:
    authorized_viewers: int
    active_sessions: int
    reserved_viewers: int
    egress_mbps: int
    required_nodes: int


@dataclass(frozen=True, slots=True)
class Action:
    operation: str
    node_id: str
    generation: int
    tier: Tier
    placement: Placement
    reason: ActionReason
    capacity_viewers: int
    capacity_egress_mbps: int
    deadline_at: int
    requires_drained: bool
    replaces_node_id: str | None = None

    def to_dict(self) -> dict[str, Any]:
        value = {
            "operation": self.operation,
            "node_id": self.node_id,
            "generation": self.generation,
            "tier": self.tier.value,
            "placement": asdict(self.placement),
            "reason": self.reason.value,
            "capacity_viewers": self.capacity_viewers,
            "capacity_egress_mbps": self.capacity_egress_mbps,
            "deadline_at": self.deadline_at,
            "requires_drained": self.requires_drained,
        }
        if self.replaces_node_id is not None:
            value["replaces_node_id"] = self.replaces_node_id
        return value


@dataclass(frozen=True, slots=True)
class Alert:
    code: str
    severity: str
    partition: str
    reason: str
    observed_at: int

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True, slots=True)
class Event:
    event_id: str
    partition: str
    sequence: int
    generation: int
    event_type: str
    observed_at: int
    payload: dict[str, Any]

    def to_dict(self) -> dict[str, Any]:
        return {"schema_version": 1, **asdict(self)}
