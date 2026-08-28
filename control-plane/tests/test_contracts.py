# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations

import json
import unittest

from teremoq_control.config import load_config
from teremoq_control.contracts import (
    AUDIT_EVENT_KEYS,
    DESIRED_STATE_KEYS,
    METRICS_SAMPLE_KEYS,
    ContractError,
    CONTRACT_MAX_RESERVATIONS,
    MAX_SAFE_JSON_INTEGER,
    validate_audit_event,
    validate_desired_state,
    validate_metrics_sample,
)
from teremoq_control.engine import ControlPlane
from teremoq_control.model import MetricsSample, Reservation, VerifiedAuthContext

from support import CONFIG_PATH, ROOT


class ContractTest(unittest.TestCase):
    def test_schema_root_keys_match_real_serializers(self) -> None:
        cases = (
            ("audit-event.schema.json", AUDIT_EVENT_KEYS),
            ("metrics-sample.schema.json", METRICS_SAMPLE_KEYS),
            ("desired-state.schema.json", DESIRED_STATE_KEYS),
        )
        for filename, expected in cases:
            with self.subTest(filename=filename):
                schema = json.loads((ROOT / "contracts" / filename).read_text(encoding="utf-8"))
                self.assertFalse(schema["additionalProperties"])
                self.assertEqual(expected, set(schema["required"]))
                self.assertEqual(expected, set(schema["properties"]))

    def test_schema_security_bounds_match_stdlib_validator_bounds(self) -> None:
        metrics_schema = json.loads(
            (ROOT / "contracts" / "metrics-sample.schema.json").read_text(encoding="utf-8")
        )
        self.assertEqual(
            CONTRACT_MAX_RESERVATIONS,
            metrics_schema["properties"]["reservations"]["maxItems"],
        )
        for field in ("sequence", "observed_at", "authorized_viewers", "active_sessions", "egress_mbps"):
            self.assertEqual(MAX_SAFE_JSON_INTEGER, metrics_schema["properties"][field]["maximum"])
        reservation_properties = metrics_schema["properties"]["reservations"]["items"]["properties"]
        self.assertEqual(MAX_SAFE_JSON_INTEGER, reservation_properties["viewers"]["maximum"])
        self.assertEqual(MAX_SAFE_JSON_INTEGER, reservation_properties["expires_at"]["maximum"])

        desired_schema = json.loads(
            (ROOT / "contracts" / "desired-state.schema.json").read_text(encoding="utf-8")
        )
        self.assertEqual(MAX_SAFE_JSON_INTEGER, desired_schema["properties"]["generation"]["maximum"])
        for field in ("origin", "core", "regional", "viewer-edge"):
            self.assertEqual(
                MAX_SAFE_JSON_INTEGER,
                desired_schema["properties"]["desired_nodes"]["properties"][field]["maximum"],
            )

    def test_real_metrics_serializer_matches_contract(self) -> None:
        sample = MetricsSample(
            sample_id="sample-1",
            partition="eu-south",
            sequence=1,
            observed_at=5,
            authorized_viewers=10,
            active_sessions=10,
            egress_mbps=9,
            reservations=(Reservation("reservation-1", 5, 20, "authz-1", "nonce-1"),),
            auth_context=VerifiedAuthContext("verification-1", "opaque-principal-ref", 5),
        )
        serialized = sample.to_dict()
        validate_metrics_sample(serialized)
        serialized["unexpected"] = True
        with self.assertRaises(ContractError):
            validate_metrics_sample(serialized)

    def test_run_specific_metrics_and_desired_state_limits_are_stric(self) -> None:
        sample = MetricsSample(
            sample_id="sample-1",
            partition="eu-south",
            sequence=1,
            observed_at=5,
            authorized_viewers=10,
            active_sessions=10,
            egress_mbps=9,
            reservations=(
                Reservation("reservation-1", 1, 20, "authz-1", "nonce-1"),
                Reservation("reservation-2", 1, 20, "authz-2", "nonce-2"),
            ),
            auth_context=VerifiedAuthContext("verification-1", "opaque-principal-ref", 5),
        )
        with self.assertRaisesRegex(ContractError, "at most 1"):
            validate_metrics_sample(sample.to_dict(), maximum_reservations=1)

        plane = ControlPlane(load_config(CONFIG_PATH))
        state = plane.desired_state("eu-south")
        limits = {tier: 0 for tier in ("origin", "core", "regional", "viewer-edge")}
        with self.assertRaisesRegex(ContractError, "desired_nodes.origin"):
            validate_desired_state(state, maximum_nodes_by_tier=limits)

    def test_missing_external_auth_context_fails_contract_and_reconcile(self) -> None:
        sample = MetricsSample("sample-1", "eu-south", 1, 1, 10, 10, 9)
        with self.assertRaisesRegex(ValueError, "auth context"):
            sample.to_dict()
        plane = ControlPlane(load_config(CONFIG_PATH))
        plane.bootstrap(now=0)
        result = plane.reconcile(sample, now=1)
        self.assertTrue(result.fail_closed)
        self.assertEqual("missing_verified_auth_context", result.reason)

    def test_reconcile_applies_contract_numeric_security_boundary(self) -> None:
        plane = ControlPlane(load_config(CONFIG_PATH))
        plane.bootstrap(now=0)
        sample = MetricsSample(
            sample_id="oversized-numeric",
            partition="eu-south",
            sequence=1,
            observed_at=1,
            authorized_viewers=MAX_SAFE_JSON_INTEGER + 1,
            active_sessions=0,
            egress_mbps=0,
            auth_context=VerifiedAuthContext("verification-1", "opaque-principal-ref", 1),
        )
        result = plane.reconcile(sample, now=1)
        self.assertTrue(result.fail_closed)
        self.assertEqual("invalid_metrics_contract", result.reason)

    def test_real_audit_and_desired_state_serializers_match_contracts(self) -> None:
        plane = ControlPlane(load_config(CONFIG_PATH))
        plane.bootstrap(now=0)
        for event in plane.events_since(0):
            validate_audit_event(event.to_dict())
        state = plane.desired_state("eu-south")
        validate_desired_state(state)
        self.assertEqual({"origin", "core", "regional", "viewer-edge"}, set(state["desired_nodes"]))


if __name__ == "__main__":
    unittest.main()
