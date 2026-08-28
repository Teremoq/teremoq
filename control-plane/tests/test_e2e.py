# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations

import unittest

from teremoq_control.cli import run_demo
from teremoq_control.config import load_config

from support import CONFIG_PATH


class EndToEndTest(unittest.TestCase):
    def test_milestone_distribution_scale_replacement_recovery_and_cleanup(self) -> None:
        report = run_demo(load_config(CONFIG_PATH))
        self.assertEqual("pass", report["result"])
        self.assertEqual([10, 25, 50, 100], [item["viewers"] for item in report["scenarios"]])
        self.assertEqual(2, report["gate"]["distributor_nodes"])
        final_distribution = report["scenarios"][-1]["session_distribution"]
        self.assertEqual(100, sum(final_distribution.values()))
        self.assertLessEqual(max(final_distribution.values()), 60)
        self.assertEqual(100, report["failure_recovery"]["sessions_recovered"])
        self.assertEqual(1, len(report["failure_recovery"]["replacement_actions"]))
        self.assertEqual(0, report["cleanup"]["active_sessions"])
        self.assertFalse(report["gate"]["larger_scenario_executed"])
        self.assertIsNone(report["cost"]["external_provider_estimate"])
        self.assertEqual(0.0, report["cost"]["local_measured_remote_infrastructure_cost"])
        self.assertGreater(report["cost"]["billable_egress_gb"], 0.0)
        self.assertEqual(0.0, report["cost"]["estimated_cost_per_viewer_hour"])


if __name__ == "__main__":
    unittest.main()
