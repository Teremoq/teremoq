# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations

import unittest

from teremoq_control.config import ConfigError, load_config
from teremoq_control.engine import ControlPlane

from support import raw_config, temporary_config


class CostTest(unittest.TestCase):
    def test_dated_tariffs_compute_egress_duration_and_viewer_hour(self) -> None:
        value = raw_config()
        value["cost"].update(
            {
                "rate_source": "unit-test-dated-tariff-fixture",
                "rate_as_of": "2031-04-05",
                "hourly_by_tier": {
                    "origin": 3.0,
                    "core": 2.0,
                    "regional": 0.0,
                    "viewer-edge": 0.0,
                },
                "controller_hourly": 1.0,
                "egress_per_gb": 0.5,
                "workload_mbps_per_viewer": 2.0,
                "protocol_overhead_ratio": 0.1,
                "maximum_hourly_cost": 1000.0,
            }
        )
        with temporary_config(value) as path:
            plane = ControlPlane(load_config(path))
        plane.bootstrap(now=0)
        report = plane.cost_report(viewers=10, duration_hours=2.0)
        self.assertAlmostEqual(22.0, report["billable_egress_mbps"])
        self.assertAlmostEqual(19.8, report["billable_egress_gb"])
        self.assertAlmostEqual(12.0, report["node_and_controller_cost"])
        self.assertAlmostEqual(9.9, report["egress_cost"])
        self.assertAlmostEqual(21.9, report["estimated_total_cost"])
        self.assertAlmostEqual(10.95, report["estimated_hourly_cost_at_workload"])
        self.assertAlmostEqual(1.095, report["estimated_cost_per_viewer_hour"])
        self.assertAlmostEqual(21.9, report["external_provider_estimate"])
        self.assertFalse(report["external_provider_tariff_required"])

    def test_tariff_date_must_be_iso_calendar_date(self) -> None:
        value = raw_config()
        value["cost"]["rate_as_of"] = "someday"
        with temporary_config(value) as path:
            with self.assertRaisesRegex(ConfigError, "ISO-8601"):
                load_config(path)


if __name__ == "__main__":
    unittest.main()
