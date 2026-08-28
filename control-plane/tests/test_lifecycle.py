# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations

import unittest

from teremoq_control.config import load_config
from teremoq_control.engine import ControlPlane
from teremoq_control.model import Lifecycle, Tier

from support import CONFIG_PATH, raw_config, temporary_config


class LifecycleTest(unittest.TestCase):
    def setUp(self) -> None:
        self.plane = ControlPlane(load_config(CONFIG_PATH))
        self.plane.bootstrap(now=0)

    def test_bootstrap_reaches_ready_through_explicit_states(self) -> None:
        self.assertEqual(1, len(self.plane._ready_nodes(Tier.ORIGIN)))
        self.assertEqual(1, len(self.plane._ready_nodes(Tier.CORE)))
        state_changes = [event for event in self.plane.events_since(0) if event.event_type == "node_state_changed"]
        observed = {event.payload["to"] for event in state_changes}
        self.assertTrue(
            {"provisioning", "bootstrapping", "authenticated", "registered", "ready"}.issubset(observed)
        )

    def test_stale_generation_and_out_of_order_events_are_ignored(self) -> None:
        node = self.plane._ready_nodes(Tier.CORE)[0]
        self.assertFalse(
            self.plane.apply_lifecycle_event(node.node_id, node.generation - 1, Lifecycle.FAILED, now=1)
        )
        self.assertFalse(
            self.plane.apply_lifecycle_event(node.node_id, node.generation, Lifecycle.REGISTERED, now=1)
        )
        self.assertEqual(Lifecycle.READY, node.state)
        self.assertEqual(2, self.plane.counters["stale_events_ignored_total"])

    def test_snapshot_tampering_fails_closed(self) -> None:
        snapshot = self.plane.snapshot("safe", now=2)
        snapshot["payload"]["desired"]["core"] = 999
        with self.assertRaisesRegex(ValueError, "digest mismatch"):
            self.plane.rollback(snapshot, now=3)

    def test_shutdown_drains_and_terminates_every_node(self) -> None:
        self.plane.set_sessions(10, now=1)
        actions = self.plane.shutdown(now=2)
        self.assertEqual(2, len(actions))
        self.assertEqual({}, self.plane.sessions)
        self.assertTrue(all(node.state == Lifecycle.TERMINATED for node in self.plane.nodes.values()))

    def test_dry_run_plans_without_mutating_provider_state(self) -> None:
        value = raw_config()
        value["provider"]["mode"] = "dry-run"
        with temporary_config(value) as path:
            plane = ControlPlane(load_config(path))
        actions = plane.bootstrap(now=0)
        self.assertEqual(2, len(actions))
        self.assertEqual({}, plane.nodes)

    def test_event_history_is_bounded_and_expired_cursor_requires_snapshot(self) -> None:
        value = raw_config()
        value["controller"]["event_queue_limit"] = 16
        with temporary_config(value) as path:
            plane = ControlPlane(load_config(path))
        plane.bootstrap(now=0)
        for index in range(20):
            plane.snapshot(f"snapshot-{index}", now=index + 1)
        self.assertEqual(16, plane.metrics()["event_queue_depth"])
        with self.assertRaisesRegex(ValueError, "restore a snapshot"):
            plane.events_since(0)

    def test_provisioning_timeout_fails_and_replaces_capacity(self) -> None:
        old_node = self.plane._ready_nodes(Tier.CORE)[0]
        old_node.state = Lifecycle.PROVISIONING
        old_node.state_entered_at = 0
        timed_out = self.plane.enforce_timeouts(now=31)
        self.assertEqual((old_node.node_id,), timed_out)
        self.assertEqual(Lifecycle.TERMINATED, old_node.state)
        replacement = self.plane._ready_nodes(Tier.CORE)
        self.assertEqual(1, len(replacement))
        self.assertNotEqual(old_node.node_id, replacement[0].node_id)
        self.assertEqual(1, self.plane.counters["nodes_replaced_total"])


if __name__ == "__main__":
    unittest.main()
