# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations

import copy
import json
import unittest
from dataclasses import replace

from teremoq_control.config import load_config
from teremoq_control.contracts import (
    ACTION_ENVELOPE_KEYS,
    ACTION_KEYS,
    ACTION_OPTIONAL_KEYS,
    ACTION_REASON_VALUES,
    ActionEnvelopeGuard,
    ContractError,
    serialize_action_envelope,
    validate_action_envelope,
)
from teremoq_control.engine import ControlPlane
from teremoq_control.model import Tier

from support import CONFIG_PATH, ROOT


class ActionEnvelopeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.config = load_config(CONFIG_PATH)

    def _guard(self) -> ActionEnvelopeGuard:
        return ActionEnvelopeGuard(
            maximum_actions=self.config.provider.action_envelope_max_actions,
            maximum_bytes=self.config.provider.action_envelope_max_bytes,
            registry_limit=self.config.provider.idempotency_registry_limit,
        )

    def test_schema_matches_real_serializer_and_rejects_unknown_fields(self) -> None:
        schema = json.loads(
            (ROOT / "contracts" / "action-envelope.schema.json").read_text(encoding="utf-8")
        )
        self.assertFalse(schema["additionalProperties"])
        self.assertEqual(ACTION_ENVELOPE_KEYS, set(schema["required"]))
        self.assertEqual(ACTION_ENVELOPE_KEYS, set(schema["properties"]))
        action_schema = schema["properties"]["actions"]["items"]
        self.assertFalse(action_schema["additionalProperties"])
        self.assertEqual(ACTION_KEYS, set(action_schema["required"]))
        self.assertEqual(ACTION_KEYS | ACTION_OPTIONAL_KEYS, set(action_schema["properties"]))
        self.assertEqual(1024, schema["properties"]["actions"]["maxItems"])
        self.assertEqual(ACTION_REASON_VALUES, set(action_schema["properties"]["reason"]["enum"]))

        plane = ControlPlane(self.config)
        bootstrap_actions = plane.bootstrap(now=0)
        envelope = plane.action_envelope(bootstrap_actions)
        validate_action_envelope(envelope)
        envelope["unknown"] = True
        with self.assertRaisesRegex(ContractError, "unknown"):
            validate_action_envelope(envelope)

    def test_create_destroy_and_replacement_semantics_are_complete(self) -> None:
        plane = ControlPlane(self.config)
        bootstrap = plane.action_envelope(plane.bootstrap(now=0))
        for action in bootstrap["actions"]:
            self.assertEqual("create", action["operation"])
            self.assertGreater(action["capacity_viewers"], 0)
            self.assertGreater(action["capacity_egress_mbps"], 0)
            self.assertGreater(action["deadline_at"], 0)
            self.assertFalse(action["requires_drained"])
            self.assertNotIn("replaces_node_id", action)

        failed = plane._ready_nodes(Tier.CORE)[0]
        replacement = plane.action_envelope(plane.fail_and_replace(failed.node_id, now=1))
        self.assertEqual(failed.node_id, replacement["actions"][0]["replaces_node_id"])
        self.assertEqual(["create", "destroy"], [action["operation"] for action in replacement["actions"]])
        self.assertEqual("failed_node_cleanup", replacement["actions"][1]["reason"])
        self.assertTrue(replacement["actions"][1]["requires_drained"])

        destroyed = plane.action_envelope(plane.shutdown(now=2))
        self.assertTrue(destroyed["actions"])
        for action in destroyed["actions"]:
            self.assertEqual("destroy", action["operation"])
            self.assertTrue(action["requires_drained"])
            self.assertLessEqual(action["generation"], destroyed["generation"])
            self.assertNotIn("replaces_node_id", action)

    def test_deterministic_idempotency_replay_and_stale_generation_fencing(self) -> None:
        plane = ControlPlane(self.config)
        bootstrap_actions = plane.bootstrap(now=0)
        first = plane.action_envelope(bootstrap_actions)
        repeated_serialization = plane.action_envelope(bootstrap_actions)
        self.assertEqual(first, repeated_serialization)

        guard = self._guard()
        accepted = guard.evaluate(first)
        self.assertEqual("accepted", accepted.status)
        replay = guard.evaluate(copy.deepcopy(first))
        self.assertEqual("idempotent_replay", replay.status)
        self.assertEqual((), replay.actions)

        failed = plane._ready_nodes(Tier.CORE)[0]
        second = plane.action_envelope(plane.fail_and_replace(failed.node_id, now=1))
        self.assertEqual("accepted", guard.evaluate(second).status)
        with self.assertRaisesRegex(ContractError, "stale partition generation"):
            guard.evaluate(first)

    def test_action_cardinality_size_registry_and_semantic_tampering_fail_closed(self) -> None:
        plane = ControlPlane(self.config)
        bootstrap_actions = plane.bootstrap(now=0)
        envelope = plane.action_envelope(bootstrap_actions)
        with self.assertRaisesRegex(ContractError, "1..1"):
            validate_action_envelope(envelope, maximum_actions=1)
        with self.assertRaisesRegex(ContractError, "byte limit"):
            validate_action_envelope(envelope, maximum_bytes=1)

        tampered = copy.deepcopy(envelope)
        tampered["actions"][0]["capacity_viewers"] += 1
        with self.assertRaisesRegex(ContractError, "idempotency_key"):
            validate_action_envelope(tampered)

        unknown_serialized_reason = copy.deepcopy(envelope)
        unknown_serialized_reason["actions"][0]["reason"] = "provider-error-text"
        with self.assertRaisesRegex(ContractError, "invalid action reason"):
            validate_action_envelope(unknown_serialized_reason)

        unknown_reason = replace(bootstrap_actions[0], reason="provider-error-text")  # type: ignore[arg-type]
        with self.assertRaisesRegex(ContractError, "invalid internal action"):
            serialize_action_envelope(
                deployment_id=self.config.deployment_id,
                partition=self.config.controller.partitions[0],
                generation=plane.generation,
                image_digest=self.config.image_digest,
                config_digest=self.config.config_digest,
                actions=(unknown_reason,),
            )

        invalid_create = replace(bootstrap_actions[0], requires_drained=True)
        with self.assertRaisesRegex(ContractError, "create capacity or drain semantics"):
            serialize_action_envelope(
                deployment_id=self.config.deployment_id,
                partition=self.config.controller.partitions[0],
                generation=plane.generation,
                image_digest=self.config.image_digest,
                config_digest=self.config.config_digest,
                actions=(invalid_create,),
            )

        small_guard = ActionEnvelopeGuard(
            maximum_actions=self.config.provider.action_envelope_max_actions,
            maximum_bytes=self.config.provider.action_envelope_max_bytes,
            registry_limit=1,
        )
        with self.assertRaisesRegex(ContractError, "registry full"):
            small_guard.evaluate(envelope)


if __name__ == "__main__":
    unittest.main()
