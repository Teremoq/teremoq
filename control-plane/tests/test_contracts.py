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

    def test_missing_external_auth_context_fails_contract_and_reconcile(self) -> None:
        sample = MetricsSample("sample-1", "eu-south", 1, 1, 10, 10, 9)
        with self.assertRaisesRegex(ValueError, "auth context"):
            sample.to_dict()
        plane = ControlPlane(load_config(CONFIG_PATH))
        plane.bootstrap(now=0)
        result = plane.reconcile(sample, now=1)
        self.assertTrue(result.fail_closed)
        self.assertEqual("missing_verified_auth_context", result.reason)

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
