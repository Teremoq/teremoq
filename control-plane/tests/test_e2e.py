# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations

import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

from teremoq_control.cli import main, run_demo
from teremoq_control.config import load_config
from teremoq_control.contracts import validate_action_envelope

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
        self.assertEqual(
            ["create", "destroy"],
            [action["operation"] for action in report["failure_recovery"]["replacement_actions"]],
        )
        self.assertEqual(0, report["cleanup"]["active_sessions"])
        self.assertFalse(report["gate"]["larger_scenario_executed"])
        self.assertIsNone(report["cost"]["external_provider_estimate"])
        self.assertEqual(0.0, report["cost"]["local_measured_remote_infrastructure_cost"])
        self.assertGreater(report["cost"]["billable_egress_gb"], 0.0)
        self.assertEqual(0.0, report["cost"]["estimated_cost_per_viewer_hour"])

    def test_cli_writes_standalone_validated_action_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory, redirect_stdout(io.StringIO()):
            result = main(
                [
                    "--config",
                    str(CONFIG_PATH),
                    "demo",
                    "--report-dir",
                    directory,
                ]
            )
            self.assertEqual(0, result)
            action_files = sorted(Path(directory).glob("actions-*.json"))
            self.assertEqual(
                {
                    "actions-bootstrap.json",
                    "actions-cleanup.json",
                    "actions-replacement.json",
                    "actions-scenario-100-2.json",
                },
                {path.name for path in action_files},
            )
            for path in action_files:
                validate_action_envelope(json.loads(path.read_text(encoding="utf-8")))


if __name__ == "__main__":
    unittest.main()
