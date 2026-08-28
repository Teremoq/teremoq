# SPDX-License-Identifier: Apache-2.0
"""Small stdlib validators for the JSON state contracts.

These validators check serialized state objects. They do not implement a wire
protocol, authenticate principals, or verify cryptographic material.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from typing import Any

from .model import Action, ActionReason


class ContractError(ValueError):
    """A serialized control-plane state object diverges from its contract."""


AUDIT_EVENT_KEYS = {
    "schema_version",
    "event_id",
    "partition",
    "sequence",
    "generation",
    "event_type",
    "observed_at",
    "payload",
}
METRICS_SAMPLE_KEYS = {
    "schema_version",
    "sample_id",
    "partition",
    "sequence",
    "observed_at",
    "authorized_viewers",
    "active_sessions",
    "egress_mbps",
    "reservations",
    "auth_context",
}
AUTH_CONTEXT_KEYS = {"verification_id", "principal_ref", "verified_at"}
RESERVATION_KEYS = {"reservation_id", "viewers", "expires_at", "authorization_id", "nonce"}
DESIRED_STATE_KEYS = {
    "schema_version",
    "partition",
    "generation",
    "image_digest",
    "config_digest",
    "desired_nodes",
}
TIER_KEYS = {"origin", "core", "regional", "viewer-edge"}
ACTION_ENVELOPE_KEYS = {
    "schema_version",
    "deployment_id",
    "partition",
    "generation",
    "image_digest",
    "config_digest",
    "actions",
}
ACTION_KEYS = {
    "operation",
    "node_id",
    "generation",
    "tier",
    "placement",
    "reason",
    "capacity_viewers",
    "capacity_egress_mbps",
    "deadline_at",
    "requires_drained",
    "idempotency_key",
}
ACTION_OPTIONAL_KEYS = {"replaces_node_id"}
PLACEMENT_KEYS = {"provider", "region", "zone"}
ACTION_REASON_VALUES = {reason.value for reason in ActionReason}
MAX_SAFE_JSON_INTEGER = (1 << 53) - 1
# Per-payload security bounds, not topology or commercial scale ceilings.
CONTRACT_MAX_RESERVATIONS = 4096
CONTRACT_MAX_ACTIONS = 1024
CONTRACT_MAX_ACTION_ENVELOPE_BYTES = 4 * 1024 * 1024


def _exact(value: Any, expected: set[str], path: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ContractError(f"{path}: expected object")
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        unknown = sorted(actual - expected)
        raise ContractError(f"{path}: missing={missing}, unknown={unknown}")
    return value


def _integer(value: Any, minimum: int, path: str, maximum: int = MAX_SAFE_JSON_INTEGER) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise ContractError(f"{path}: expected integer in [{minimum}, {maximum}]")
    return value


def _string(value: Any, maximum: int, path: str) -> str:
    if not isinstance(value, str) or not value or len(value) > maximum:
        raise ContractError(f"{path}: expected string with length 1..{maximum}")
    return value


def _schema_one(value: dict[str, Any], path: str) -> None:
    if value["schema_version"] != 1:
        raise ContractError(f"{path}.schema_version: expected 1")


def validate_metrics_sample(
    value: Any,
    *,
    maximum_reservations: int = CONTRACT_MAX_RESERVATIONS,
    maximum_numeric_value: int = MAX_SAFE_JSON_INTEGER,
) -> None:
    if not 0 <= maximum_reservations <= CONTRACT_MAX_RESERVATIONS:
        raise ContractError("metrics_sample: invalid configured reservation limit")
    if not 0 <= maximum_numeric_value <= MAX_SAFE_JSON_INTEGER:
        raise ContractError("metrics_sample: invalid configured numeric limit")
    sample = _exact(value, METRICS_SAMPLE_KEYS, "metrics_sample")
    _schema_one(sample, "metrics_sample")
    _string(sample["sample_id"], 128, "metrics_sample.sample_id")
    _string(sample["partition"], 63, "metrics_sample.partition")
    for field in ("sequence", "observed_at", "authorized_viewers", "active_sessions", "egress_mbps"):
        _integer(sample[field], 0, f"metrics_sample.{field}", maximum_numeric_value)
    auth = _exact(sample["auth_context"], AUTH_CONTEXT_KEYS, "metrics_sample.auth_context")
    _string(auth["verification_id"], 128, "metrics_sample.auth_context.verification_id")
    _string(auth["principal_ref"], 128, "metrics_sample.auth_context.principal_ref")
    _integer(auth["verified_at"], 0, "metrics_sample.auth_context.verified_at", maximum_numeric_value)
    reservations = sample["reservations"]
    if not isinstance(reservations, list) or len(reservations) > maximum_reservations:
        raise ContractError(
            f"metrics_sample.reservations: expected array with at most {maximum_reservations} items"
        )
    for index, raw in enumerate(reservations):
        reservation = _exact(raw, RESERVATION_KEYS, f"metrics_sample.reservations[{index}]")
        _string(reservation["reservation_id"], 128, f"metrics_sample.reservations[{index}].reservation_id")
        _integer(
            reservation["viewers"], 0, f"metrics_sample.reservations[{index}].viewers", maximum_numeric_value
        )
        _integer(
            reservation["expires_at"], 0, f"metrics_sample.reservations[{index}].expires_at", maximum_numeric_value
        )
        _string(reservation["authorization_id"], 128, f"metrics_sample.reservations[{index}].authorization_id")
        _string(reservation["nonce"], 128, f"metrics_sample.reservations[{index}].nonce")
    _json_safe(sample, "metrics_sample")


def validate_audit_event(value: Any) -> None:
    event = _exact(value, AUDIT_EVENT_KEYS, "audit_event")
    _schema_one(event, "audit_event")
    _string(event["event_id"], 128, "audit_event.event_id")
    _string(event["partition"], 128, "audit_event.partition")
    _integer(event["sequence"], 1, "audit_event.sequence")
    if isinstance(event["generation"], bool) or not isinstance(event["generation"], int):
        raise ContractError("audit_event.generation: expected integer")
    _string(event["event_type"], 128, "audit_event.event_type")
    _integer(event["observed_at"], 0, "audit_event.observed_at")
    if not isinstance(event["payload"], dict) or len(event["payload"]) > 32:
        raise ContractError("audit_event.payload: expected object with at most 32 properties")
    _json_safe(event, "audit_event")


def validate_desired_state(
    value: Any,
    *,
    maximum_nodes_by_tier: dict[str, int] | None = None,
) -> None:
    state = _exact(value, DESIRED_STATE_KEYS, "desired_state")
    _schema_one(state, "desired_state")
    _string(state["partition"], 63, "desired_state.partition")
    _integer(state["generation"], 1, "desired_state.generation")
    for field in ("image_digest", "config_digest"):
        _digest(state[field], f"desired_state.{field}")
    desired = _exact(state["desired_nodes"], TIER_KEYS, "desired_state.desired_nodes")
    limits = maximum_nodes_by_tier or {tier: MAX_SAFE_JSON_INTEGER for tier in TIER_KEYS}
    if set(limits) != TIER_KEYS or any(
        isinstance(limit, bool) or not isinstance(limit, int) or not 0 <= limit <= MAX_SAFE_JSON_INTEGER
        for limit in limits.values()
    ):
        raise ContractError("desired_state: invalid configured tier limits")
    for tier, count in desired.items():
        _integer(count, 0, f"desired_state.desired_nodes.{tier}", limits[tier])
    _json_safe(state, "desired_state")


def _digest(value: Any, path: str) -> str:
    if not isinstance(value, str) or len(value) != 71 or not value.startswith("sha256:"):
        raise ContractError(f"{path}: expected sha256 digest")
    try:
        int(value[7:], 16)
    except ValueError as error:
        raise ContractError(f"{path}: expected lowercase hexadecimal") from error
    if value[7:] != value[7:].lower():
        raise ContractError(f"{path}: expected lowercase hexadecimal")
    return value


def _canonical_bytes(value: Any, path: str) -> bytes:
    try:
        return json.dumps(value, allow_nan=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise ContractError(f"{path}: not canonical JSON data") from error


def _idempotency_key(envelope: dict[str, Any], action: dict[str, Any]) -> str:
    semantic_action = {
        key: action[key]
        for key in (ACTION_KEYS | ACTION_OPTIONAL_KEYS) - {"idempotency_key"}
        if key in action
    }
    material = {
        "schema_version": envelope["schema_version"],
        "deployment_id": envelope["deployment_id"],
        "partition": envelope["partition"],
        "generation": envelope["generation"],
        "image_digest": envelope["image_digest"],
        "config_digest": envelope["config_digest"],
        "action": semantic_action,
    }
    return f"sha256:{hashlib.sha256(_canonical_bytes(material, 'action_idempotency_material')).hexdigest()}"


def serialize_action_envelope(
    *,
    deployment_id: str,
    partition: str,
    generation: int,
    image_digest: str,
    config_digest: str,
    actions: tuple[Action, ...],
    maximum_actions: int = CONTRACT_MAX_ACTIONS,
    maximum_bytes: int = CONTRACT_MAX_ACTION_ENVELOPE_BYTES,
) -> dict[str, Any]:
    """Serialize a local provider-neutral plan; this is not a transport."""

    envelope: dict[str, Any] = {
        "schema_version": 1,
        "deployment_id": deployment_id,
        "partition": partition,
        "generation": generation,
        "image_digest": image_digest,
        "config_digest": config_digest,
        "actions": [],
    }
    for action in actions:
        if not isinstance(action, Action) or not isinstance(action.reason, ActionReason):
            raise ContractError("action_envelope.actions: invalid internal action")
        serialized = action.to_dict()
        serialized["idempotency_key"] = _idempotency_key(envelope, serialized)
        envelope["actions"].append(serialized)
    validate_action_envelope(envelope, maximum_actions=maximum_actions, maximum_bytes=maximum_bytes)
    return envelope


def validate_action_envelope(
    value: Any,
    *,
    maximum_actions: int = CONTRACT_MAX_ACTIONS,
    maximum_bytes: int = CONTRACT_MAX_ACTION_ENVELOPE_BYTES,
) -> None:
    if not 1 <= maximum_actions <= CONTRACT_MAX_ACTIONS:
        raise ContractError("action_envelope: invalid configured action limit")
    if not 1 <= maximum_bytes <= CONTRACT_MAX_ACTION_ENVELOPE_BYTES:
        raise ContractError("action_envelope: invalid configured byte limit")
    envelope = _exact(value, ACTION_ENVELOPE_KEYS, "action_envelope")
    _schema_one(envelope, "action_envelope")
    _string(envelope["deployment_id"], 63, "action_envelope.deployment_id")
    _string(envelope["partition"], 63, "action_envelope.partition")
    _integer(envelope["generation"], 1, "action_envelope.generation")
    _digest(envelope["image_digest"], "action_envelope.image_digest")
    _digest(envelope["config_digest"], "action_envelope.config_digest")
    actions = envelope["actions"]
    if not isinstance(actions, list) or not 1 <= len(actions) <= maximum_actions:
        raise ContractError(f"action_envelope.actions: expected array with 1..{maximum_actions} items")
    seen_keys: set[str] = set()
    for index, raw in enumerate(actions):
        path = f"action_envelope.actions[{index}]"
        if not isinstance(raw, dict):
            raise ContractError(f"{path}: expected object")
        actual_keys = set(raw)
        if not ACTION_KEYS <= actual_keys or actual_keys - ACTION_KEYS - ACTION_OPTIONAL_KEYS:
            raise ContractError(
                f"{path}: missing={sorted(ACTION_KEYS - actual_keys)}, "
                f"unknown={sorted(actual_keys - ACTION_KEYS - ACTION_OPTIONAL_KEYS)}"
            )
        action = raw
        if not isinstance(action["operation"], str) or action["operation"] not in {"create", "destroy"}:
            raise ContractError(f"{path}.operation: expected create or destroy")
        _string(action["node_id"], 128, f"{path}.node_id")
        action_generation = _integer(action["generation"], 1, f"{path}.generation")
        if action_generation > envelope["generation"]:
            raise ContractError(f"{path}.generation: exceeds envelope generation")
        if not isinstance(action["tier"], str) or action["tier"] not in TIER_KEYS:
            raise ContractError(f"{path}.tier: invalid tier")
        placement = _exact(action["placement"], PLACEMENT_KEYS, f"{path}.placement")
        for field in PLACEMENT_KEYS:
            _string(placement[field], 63, f"{path}.placement.{field}")
        if not isinstance(action["reason"], str) or action["reason"] not in ACTION_REASON_VALUES:
            raise ContractError(f"{path}.reason: invalid action reason")
        capacity_viewers = _integer(action["capacity_viewers"], 0, f"{path}.capacity_viewers")
        capacity_egress = _integer(action["capacity_egress_mbps"], 0, f"{path}.capacity_egress_mbps")
        _integer(action["deadline_at"], 1, f"{path}.deadline_at")
        if not isinstance(action["requires_drained"], bool):
            raise ContractError(f"{path}.requires_drained: expected boolean")
        replacement = action.get("replaces_node_id")
        if replacement is not None:
            _string(replacement, 128, f"{path}.replaces_node_id")
        if action["operation"] == "create":
            if capacity_viewers < 1 or capacity_egress < 1 or action["requires_drained"]:
                raise ContractError(f"{path}: invalid create capacity or drain semantics")
        elif replacement is not None:
            raise ContractError(f"{path}.replaces_node_id: only valid for create")
        if action["operation"] == "destroy" and not action["requires_drained"]:
            raise ContractError(f"{path}.requires_drained: destroy requires drain precondition")
        key = _digest(action["idempotency_key"], f"{path}.idempotency_key")
        if key != _idempotency_key(envelope, action):
            raise ContractError(f"{path}.idempotency_key: does not match action semantics")
        if key in seen_keys:
            raise ContractError(f"{path}.idempotency_key: duplicate in envelope")
        seen_keys.add(key)
    if len(_canonical_bytes(envelope, "action_envelope")) > maximum_bytes:
        raise ContractError(f"action_envelope: exceeds configured {maximum_bytes}-byte limit")


@dataclass(frozen=True, slots=True)
class ActionEnvelopeDecision:
    status: str
    actions: tuple[dict[str, Any], ...]


class ActionEnvelopeGuard:
    """Bounded local fencing/replay guard; it never invokes a provider."""

    def __init__(self, *, maximum_actions: int, maximum_bytes: int, registry_limit: int) -> None:
        if registry_limit < 1:
            raise ValueError("idempotency registry limit must be positive")
        self.maximum_actions = maximum_actions
        self.maximum_bytes = maximum_bytes
        self.registry_limit = registry_limit
        self._seen_keys: set[str] = set()
        self._partition_generation: dict[str, int] = {}

    def evaluate(self, value: Any) -> ActionEnvelopeDecision:
        validate_action_envelope(
            value, maximum_actions=self.maximum_actions, maximum_bytes=self.maximum_bytes
        )
        envelope = value
        partition = envelope["partition"]
        generation = envelope["generation"]
        previous_generation = self._partition_generation.get(partition, 0)
        if generation < previous_generation:
            raise ContractError("action_envelope: stale partition generation")
        unseen = tuple(action for action in envelope["actions"] if action["idempotency_key"] not in self._seen_keys)
        if not unseen:
            return ActionEnvelopeDecision("idempotent_replay", ())
        if len(self._seen_keys) + len(unseen) > self.registry_limit:
            raise ContractError("action_envelope: idempotency registry full")
        for action in unseen:
            key = action["idempotency_key"]
            self._seen_keys.add(key)
        self._partition_generation[partition] = generation
        return ActionEnvelopeDecision("accepted", unseen)


def _json_safe(value: Any, path: str) -> None:
    _canonical_bytes(value, path)
