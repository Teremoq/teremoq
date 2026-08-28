# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations

import unittest

from teremoq_control.config import ConfigError, load_config
from teremoq_control.engine import ControlPlane
from teremoq_control.model import MetricsSample, Tier

from support import CONFIG_PATH, raw_config, temporary_config


class ConfigTest(unittest.TestCase):
    def test_milestone_configuration_is_strict_and_digest_pinned(self) -> None:
        config = load_config(CONFIG_PATH)
        self.assertEqual(1, config.controller.replicas)
        self.assertEqual((10, 25, 50, 100), config.milestone.progressive_scenarios)
        self.assertTrue(config.image_digest.startswith("sha256:"))
        self.assertEqual(71, len(config.image_digest))
        self.assertEqual(0.0, config.cost.local_remote_infrastructure_cost)

    def test_unknown_configuration_key_is_rejected(self) -> None:
        value = raw_config()
        value["surprise"] = True
        with temporary_config(value) as path:
            with self.assertRaisesRegex(ConfigError, "unknown keys"):
                load_config(path)

    def test_floating_image_reference_is_rejected(self) -> None:
        value = raw_config()
        value["image_digest"] = "local-simulator:latest"
        with temporary_config(value) as path:
            with self.assertRaisesRegex(ConfigError, "immutable sha256"):
                load_config(path)

    def test_three_or_more_controllers_require_no_code_change(self) -> None:
        value = raw_config()
        value["controller"]["replicas"] = 5
        value["milestone"]["expected_controller_nodes"] = 5
        with temporary_config(value) as path:
            config = load_config(path)
        self.assertEqual(5, config.controller.replicas)

    def test_configuration_only_probe_has_no_named_scale_ceiling(self) -> None:
        value = raw_config()
        value["tiers"]["core"]["capacity_viewers_per_node"] = 37
        value["tiers"]["core"]["maximum_nodes"] = 987654
        value["controller"]["session_registry_limit"] = 432109
        with temporary_config(value) as path:
            config = load_config(path)
        plane = ControlPlane(config)
        sample = MetricsSample(
            sample_id="configuration-only-probe",
            partition="eu-south",
            sequence=1,
            observed_at=0,
            authorized_viewers=123457,
            active_sessions=123457,
            egress_mbps=1,
        )
        signal = plane._capacity_signal(sample, reserved=0)
        self.assertGreater(signal.required_nodes, 100)
        self.assertLess(signal.required_nodes, config.tiers[Tier.CORE].maximum_nodes)
        self.assertEqual({}, plane.nodes)
        self.assertEqual({}, plane.sessions)


if __name__ == "__main__":
    unittest.main()
