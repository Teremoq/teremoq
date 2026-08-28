# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations

import unittest

from teremoq_control.config import load_config
from teremoq_control.engine import ControlPlane
from teremoq_control.model import MetricsSample, Reservation, Tier

from support import CONFIG_PATH, raw_config, temporary_config


def sample(
    sequence: int,
    now: int,
    authorized: int,
    active: int,
    egress: int,
    reservations: tuple[Reservation, ...] = (),
    signature_valid: bool = True,
) -> MetricsSample:
    return MetricsSample(
        sample_id=f"sample-{sequence}",
        partition="eu-south",
        sequence=sequence,
        observed_at=now,
        authorized_viewers=authorized,
        active_sessions=active,
        egress_mbps=egress,
        reservations=reservations,
        signature_valid=signature_valid,
    )


class ScalingTest(unittest.TestCase):
    def setUp(self) -> None:
        self.config = load_config(CONFIG_PATH)
        self.plane = ControlPlane(self.config)
        self.plane.bootstrap(now=0)

    def test_signal_combines_authorized_active_reserved_and_egress(self) -> None:
        reservation = Reservation("reservation-a", 40, 100, "authorization-a", "nonce-a")
        result = self.plane.reconcile(sample(1, 1, 30, 30, 250, (reservation,)), now=1)
        self.assertIsNotNone(result.signal)
        assert result.signal is not None
        self.assertEqual(40, result.signal.reserved_viewers)
        self.assertEqual(3, result.signal.required_nodes)

    def test_invalid_and_replayed_metrics_fail_closed_without_actions(self) -> None:
        invalid = self.plane.reconcile(sample(1, 1, 10, 11, 1), now=1)
        self.assertTrue(invalid.fail_closed)
        self.assertEqual((), invalid.actions)
        accepted = self.plane.reconcile(sample(2, 2, 10, 10, 1), now=2)
        self.assertTrue(accepted.accepted)
        replay = self.plane.reconcile(sample(2, 2, 10, 10, 1), now=2)
        self.assertTrue(replay.fail_closed)
        self.assertEqual("replayed_sequence", replay.reason)
        unsigned = self.plane.reconcile(sample(3, 3, 10, 10, 1, signature_valid=False), now=3)
        self.assertTrue(unsigned.fail_closed)

    def test_invalid_control_sample_does_not_cut_existing_sessions(self) -> None:
        before = self.plane.set_sessions(10, now=1)
        rejected = self.plane.reconcile(sample(1, 2, 10, 10, 8, signature_valid=False), now=2)
        self.assertTrue(rejected.fail_closed)
        self.assertEqual(before, self.plane.session_distribution())
        self.assertEqual(10, len(self.plane.sessions))

    def test_scale_out_requires_stability_then_creates_capacity(self) -> None:
        first = self.plane.reconcile(sample(1, 1, 100, 100, 80), now=1)
        self.assertEqual("scale_out_stability_pending", first.reason)
        second = self.plane.reconcile(sample(2, 11, 100, 100, 80), now=11)
        self.assertEqual("scaled_out", second.reason)
        self.assertEqual(1, len(second.actions))
        self.assertEqual(2, len(self.plane._ready_nodes(Tier.CORE)))

    def test_scale_in_hysteresis_and_independent_cooldown(self) -> None:
        self.plane.reconcile(sample(1, 1, 100, 100, 80), now=1)
        self.plane.reconcile(sample(2, 11, 100, 100, 80), now=11)
        pending = self.plane.reconcile(sample(3, 12, 10, 10, 8), now=12)
        self.assertEqual("scale_in_stability_pending", pending.reason)
        scaled = self.plane.reconcile(sample(4, 42, 10, 10, 8), now=42)
        self.assertEqual("scaled_in", scaled.reason)
        self.assertEqual(1, len(self.plane._ready_nodes(Tier.CORE)))

    def test_expired_reservation_does_not_consume_capacity(self) -> None:
        expired = Reservation("expired", 500, 0, "authorization", "nonce-expired")
        result = self.plane.reconcile(sample(1, 1, 10, 10, 8, (expired,)), now=1)
        self.assertIsNotNone(result.signal)
        assert result.signal is not None
        self.assertEqual(0, result.signal.reserved_viewers)
        self.assertEqual(1, result.signal.required_nodes)

    def test_duplicate_and_replayed_reservation_identity_fail_closed(self) -> None:
        duplicate_id = (
            Reservation("same-id", 1, 100, "auth-a", "nonce-a"),
            Reservation("same-id", 1, 100, "auth-b", "nonce-b"),
        )
        duplicate_result = self.plane.reconcile(sample(1, 1, 10, 10, 8, duplicate_id), now=1)
        self.assertTrue(duplicate_result.fail_closed)
        self.assertEqual("duplicate_reservation", duplicate_result.reason)

        valid = Reservation("reservation-valid", 1, 100, "auth-valid", "nonce-valid")
        accepted = self.plane.reconcile(sample(2, 2, 10, 10, 8, (valid,)), now=2)
        self.assertTrue(accepted.accepted)
        replayed_id = Reservation("reservation-valid", 1, 100, "auth-valid", "nonce-new")
        replay = self.plane.reconcile(sample(3, 3, 10, 10, 8, (replayed_id,)), now=3)
        self.assertTrue(replay.fail_closed)
        self.assertEqual("replayed_reservation_id", replay.reason)

    def test_duplicate_and_replayed_reservation_nonce_fail_closed(self) -> None:
        duplicate_nonce = (
            Reservation("reservation-a", 1, 100, "auth-a", "nonce-same"),
            Reservation("reservation-b", 1, 100, "auth-b", "nonce-same"),
        )
        duplicate_result = self.plane.reconcile(sample(1, 1, 10, 10, 8, duplicate_nonce), now=1)
        self.assertTrue(duplicate_result.fail_closed)
        self.assertEqual("duplicate_reservation", duplicate_result.reason)

        valid = Reservation("reservation-valid", 1, 100, "auth-valid", "nonce-valid")
        self.plane.reconcile(sample(2, 2, 10, 10, 8, (valid,)), now=2)
        replayed_nonce = Reservation("reservation-new", 1, 100, "auth-new", "nonce-valid")
        replay = self.plane.reconcile(sample(3, 3, 10, 10, 8, (replayed_nonce,)), now=3)
        self.assertTrue(replay.fail_closed)
        self.assertEqual("replayed_reservation", replay.reason)

    def test_same_live_reservation_can_be_reobserved_without_double_counting(self) -> None:
        reservation = Reservation("reservation-stable", 10, 100, "auth-stable", "nonce-stable")
        first = self.plane.reconcile(sample(1, 1, 10, 10, 8, (reservation,)), now=1)
        second = self.plane.reconcile(sample(2, 2, 10, 10, 8, (reservation,)), now=2)
        self.assertTrue(first.accepted)
        self.assertTrue(second.accepted)
        self.assertFalse(second.fail_closed)
        self.assertIsNotNone(second.signal)
        assert second.signal is not None
        self.assertEqual(10, second.signal.reserved_viewers)

    def test_fraudulent_demand_burst_fails_closed(self) -> None:
        baseline = self.plane.reconcile(sample(1, 1, 10, 10, 8), now=1)
        self.assertTrue(baseline.accepted)
        burst = self.plane.reconcile(sample(2, 2, 100, 100, 80), now=2)
        self.assertTrue(burst.fail_closed)
        self.assertEqual("demand_rate_exceeded", burst.reason)
        self.assertEqual((), burst.actions)

    def test_maximum_nodes_blocks_all_capacity_actions(self) -> None:
        value = raw_config()
        value["tiers"]["core"]["maximum_nodes"] = 1
        with temporary_config(value) as path:
            plane = ControlPlane(load_config(path))
        plane.bootstrap(now=0)
        blocked = plane.reconcile(sample(1, 1, 100, 100, 80), now=1)
        self.assertTrue(blocked.fail_closed)
        self.assertEqual("node_limit_fail_closed", blocked.reason)
        self.assertEqual((), blocked.actions)
        self.assertEqual(1, len(plane._ready_nodes(Tier.CORE)))

    def test_spend_maximum_including_egress_blocks_all_actions(self) -> None:
        value = raw_config()
        value["cost"]["egress_per_gb"] = 1.0
        value["cost"]["maximum_hourly_cost"] = 0.0
        value["cost"]["rate_source"] = "test-fixture-not-a-provider-price"
        with temporary_config(value) as path:
            plane = ControlPlane(load_config(path))
        plane.bootstrap(now=0)
        blocked = plane.reconcile(sample(1, 1, 100, 100, 80), now=1)
        self.assertTrue(blocked.fail_closed)
        self.assertEqual("spend_limit_fail_closed", blocked.reason)
        self.assertEqual((), blocked.actions)
        self.assertEqual(1, len(plane._ready_nodes(Tier.CORE)))


if __name__ == "__main__":
    unittest.main()
