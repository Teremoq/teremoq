# SPDX-License-Identifier: Apache-2.0
"""Small stdlib validators for the JSON state contracts.

These validators check serialized state objects. They do not implement a wire
protocol, authenticate principals, or verify cryptographic material.
"""

from __future__ import annotations

import json
from typing import Any


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


def _exact(value: Any, expected: set[str], path: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ContractError(f"{path}: expected object")
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        unknown = sorted(actual - expected)
        raise ContractError(f"{path}: missing={missing}, unknown={unknown}")
    return value


def _integer(value: Any, minimum: int, path: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ContractError(f"{path}: expected integer >= {minimum}")
    return value


def _string(value: Any, maximum: int, path: str) -> str:
    if not isinstance(value, str) or not value or len(value) > maximum:
        raise ContractError(f"{path}: expected string with length 1..{maximum}")
    return value


def _schema_one(value: dict[str, Any], path: str) -> None:
    if value["schema_version"] != 1:
        raise ContractError(f"{path}.schema_version: expected 1")


def validate_metrics_sample(value: Any) -> None:
    sample = _exact(value, METRICS_SAMPLE_KEYS, "metrics_sample")
    _schema_one(sample, "metrics_sample")
    _string(sample["sample_id"], 128, "metrics_sample.sample_id")
    _string(sample["partition"], 63, "metrics_sample.partition")
    for field in ("sequence", "observed_at", "authorized_viewers", "active_sessions", "egress_mbps"):
        _integer(sample[field], 0, f"metrics_sample.{field}")
    auth = _exact(sample["auth_context"], AUTH_CONTEXT_KEYS, "metrics_sample.auth_context")
    _string(auth["verification_id"], 128, "metrics_sample.auth_context.verification_id")
    _string(auth["principal_ref"], 128, "metrics_sample.auth_context.principal_ref")
    _integer(auth["verified_at"], 0, "metrics_sample.auth_context.verified_at")
    reservations = sample["reservations"]
    if not isinstance(reservations, list):
        raise ContractError("metrics_sample.reservations: expected array")
    for index, raw in enumerate(reservations):
        reservation = _exact(raw, RESERVATION_KEYS, f"metrics_sample.reservations[{index}]")
        _string(reservation["reservation_id"], 128, f"metrics_sample.reservations[{index}].reservation_id")
        _integer(reservation["viewers"], 0, f"metrics_sample.reservations[{index}].viewers")
        _integer(reservation["expires_at"], 0, f"metrics_sample.reservations[{index}].expires_at")
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


def validate_desired_state(value: Any) -> None:
    state = _exact(value, DESIRED_STATE_KEYS, "desired_state")
    _schema_one(state, "desired_state")
    _string(state["partition"], 63, "desired_state.partition")
    _integer(state["generation"], 1, "desired_state.generation")
    for field in ("image_digest", "config_digest"):
        digest = state[field]
        if not isinstance(digest, str) or len(digest) != 71 or not digest.startswith("sha256:"):
            raise ContractError(f"desired_state.{field}: expected sha256 digest")
        try:
            int(digest[7:], 16)
        except ValueError as error:
            raise ContractError(f"desired_state.{field}: expected lowercase hexadecimal") from error
        if digest[7:] != digest[7:].lower():
            raise ContractError(f"desired_state.{field}: expected lowercase hexadecimal")
    desired = _exact(state["desired_nodes"], TIER_KEYS, "desired_state.desired_nodes")
    for tier, count in desired.items():
        _integer(count, 0, f"desired_state.desired_nodes.{tier}")
    _json_safe(state, "desired_state")


def _json_safe(value: Any, path: str) -> None:
    try:
        json.dumps(value, allow_nan=False, sort_keys=True, separators=(",", ":"))
    except (TypeError, ValueError) as error:
        raise ContractError(f"{path}: not canonical JSON data") from error
