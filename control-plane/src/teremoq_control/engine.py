# SPDX-License-Identifier: Apache-2.0
"""Deterministic regional reconciler, autoscaler, snapshots, and audit state."""

from __future__ import annotations

import hashlib
import json
import math
from collections import deque
from dataclasses import asdict, dataclass
from typing import Any, Iterable

from .config import Config
from .contracts import (
    ContractError,
    serialize_action_envelope,
    validate_audit_event,
    validate_desired_state,
    validate_metrics_sample,
)
from .model import (
    FORWARD_TRANSITIONS,
    Action,
    ActionReason,
    Alert,
    CapacitySignal,
    Event,
    Lifecycle,
    MetricsSample,
    Node,
    Placement,
    Reservation,
    Tier,
)
from .provider import LocalSimulatorProvider


@dataclass(frozen=True, slots=True)
class ReconcileResult:
    accepted: bool
    fail_closed: bool
    signal: CapacitySignal | None
    desired_nodes: int
    actions: tuple[Action, ...]
    alerts: tuple[Alert, ...]
    reason: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "accepted": self.accepted,
            "fail_closed": self.fail_closed,
            "signal": asdict(self.signal) if self.signal is not None else None,
            "desired_nodes": self.desired_nodes,
            "actions": [action.to_dict() for action in self.actions],
            "alerts": [alert.to_dict() for alert in self.alerts],
            "reason": self.reason,
        }


class ControlPlane:
    """One regional/partitioned reconciler instance.

    Multiple instances replicate the bounded event stream and compete for an
    externally supplied partition lease. This local foundation deliberately
    runs a single process and never participates in video forwarding.
    """

    def __init__(self, config: Config, instance_id: str = "control-1") -> None:
        self.config = config
        self.instance_id = instance_id
        self.provider = LocalSimulatorProvider(config.provider.mode)
        self.generation = 1
        self.nodes: dict[str, Node] = {}
        self.sessions: dict[str, str] = {}
        self.desired: dict[Tier, int] = {
            tier: (item.minimum_nodes if item.enabled else 0)
            for tier, item in config.tiers.items()
        }
        self._node_counter = 0
        self._event_sequence = 0
        self._events: deque[Event] = deque(maxlen=config.controller.event_queue_limit)
        self._alerts: deque[Alert] = deque(maxlen=config.controller.event_queue_limit)
        self._seen_nonces: deque[str] = deque(maxlen=config.controller.event_queue_limit)
        self._seen_nonce_set: set[str] = set()
        self._last_metrics_sequence: dict[str, int] = {}
        self._last_demand: dict[str, tuple[int, int]] = {}
        self._reservation_order: deque[str] = deque()
        self._reservation_records: dict[str, tuple[int, int, str, str]] = {}
        self._reservation_nonce_owner: dict[str, str] = {}
        self._pending_direction: str | None = None
        self._pending_since: int | None = None
        self._pending_desired: int | None = None
        self._last_scale_out_at: int | None = None
        self._last_scale_in_at: int | None = None
        self._snapshots: dict[str, dict[str, Any]] = {}
        self.counters: dict[str, int] = {
            "metrics_accepted_total": 0,
            "metrics_rejected_total": 0,
            "scale_out_total": 0,
            "scale_in_total": 0,
            "nodes_replaced_total": 0,
            "sessions_reassigned_total": 0,
            "drain_unresolved_total": 0,
            "stale_events_ignored_total": 0,
        }

    def bootstrap(self, now: int = 0) -> tuple[Action, ...]:
        actions: list[Action] = []
        for tier in Tier:
            actions.extend(
                self._plan_delta(tier, self.desired[tier], now, ActionReason.CONFIGURED_MINIMUM)
            )
        self._execute(tuple(actions), now)
        return tuple(actions)

    def _next_node_id(self, tier: Tier) -> str:
        self._node_counter += 1
        return f"{self.config.deployment_id}-{tier.value}-{self._node_counter:06d}"

    def _placement_for(self, tier: Tier, ordinal: int) -> Placement:
        placements = self.config.tiers[tier].placements
        return placements[ordinal % len(placements)]

    def _create_deadline_at(self, now: int) -> int:
        stages = ("provisioning", "bootstrapping", "authenticated", "registered")
        return now + sum(self.config.lifecycle.timeouts[stage] for stage in stages)

    def _live_nodes(self, tier: Tier | None = None) -> list[Node]:
        terminal = {Lifecycle.TERMINATED, Lifecycle.FAILED, Lifecycle.REPLACING}
        return sorted(
            (
                node
                for node in self.nodes.values()
                if node.state not in terminal and (tier is None or node.tier == tier)
            ),
            key=lambda node: node.node_id,
        )

    def _ready_nodes(self, tier: Tier) -> list[Node]:
        return sorted(
            (node for node in self.nodes.values() if node.tier == tier and node.state == Lifecycle.READY),
            key=lambda node: node.node_id,
        )

    def _plan_delta(self, tier: Tier, target: int, now: int, reason: ActionReason) -> list[Action]:
        current = self._live_nodes(tier)
        actions: list[Action] = []
        if len(current) < target:
            for offset in range(target - len(current)):
                node_id = self._next_node_id(tier)
                actions.append(
                    Action(
                        operation="create",
                        node_id=node_id,
                        generation=self.generation,
                        tier=tier,
                        placement=self._placement_for(tier, len(current) + offset),
                        reason=reason,
                        capacity_viewers=self.config.tiers[tier].capacity_viewers_per_node,
                        capacity_egress_mbps=self.config.tiers[tier].capacity_egress_mbps_per_node,
                        deadline_at=self._create_deadline_at(now),
                        requires_drained=False,
                    )
                )
        elif len(current) > target:
            removable = sorted(current, key=lambda node: (len(node.sessions), node.node_id), reverse=False)
            for node in removable[: len(current) - target]:
                actions.append(
                    Action(
                        operation="destroy",
                        node_id=node.node_id,
                        generation=node.generation,
                        tier=node.tier,
                        placement=node.placement,
                        reason=reason,
                        capacity_viewers=node.capacity_viewers,
                        capacity_egress_mbps=node.capacity_egress_mbps,
                        deadline_at=now + self.config.scaling.drain_timeout_seconds,
                        requires_drained=True,
                    )
                )
        return actions

    def _execute(self, actions: tuple[Action, ...], now: int) -> None:
        creates = tuple(action for action in actions if action.operation == "create")
        destroys = tuple(action for action in actions if action.operation == "destroy")
        self.provider.plan(actions)
        if self.config.provider.mode == "dry-run":
            return
        for action in creates:
            tier_config = self.config.tiers[action.tier]
            self.nodes[action.node_id] = Node(
                node_id=action.node_id,
                tier=action.tier,
                placement=action.placement,
                image_digest=self.config.image_digest,
                config_digest=self.config.config_digest,
                generation=action.generation,
                state=Lifecycle.REQUESTED,
                state_entered_at=now,
                capacity_viewers=tier_config.capacity_viewers_per_node,
                capacity_egress_mbps=tier_config.capacity_egress_mbps_per_node,
            )
            self._emit(action.placement.region, action.generation, "node_requested", now, action.to_dict())
        for transition in self.provider.apply(creates):
            self.apply_lifecycle_event(transition.node_id, transition.generation, transition.state, now)
        unresolved_drains: set[str] = set()
        for transition in self.provider.destroy(destroys):
            if transition.state == Lifecycle.DRAINING:
                if not self.apply_lifecycle_event(
                    transition.node_id, transition.generation, transition.state, now
                ) or not self._drain_node(transition.node_id, now):
                    unresolved_drains.add(transition.node_id)
            elif transition.node_id not in unresolved_drains:
                self.apply_lifecycle_event(
                    transition.node_id, transition.generation, transition.state, now
                )

    def apply_lifecycle_event(self, node_id: str, generation: int, state: Lifecycle, now: int) -> bool:
        node = self.nodes.get(node_id)
        if node is None or generation != node.generation:
            self.counters["stale_events_ignored_total"] += 1
            self._emit("unknown", generation, "stale_event_ignored", now, {"node_id": node_id, "state": state.value})
            return False
        if state == node.state:
            return True
        if state not in FORWARD_TRANSITIONS[node.state]:
            self.counters["stale_events_ignored_total"] += 1
            self._emit(node.placement.region, generation, "out_of_order_event_ignored", now, {"node_id": node_id, "from": node.state.value, "to": state.value})
            return False
        previous = node.state
        node.state = state
        node.state_entered_at = now
        self._emit(node.placement.region, generation, "node_state_changed", now, {"node_id": node_id, "from": previous.value, "to": state.value})
        return True

    def _remember_nonce(self, nonce: str) -> None:
        if len(self._seen_nonces) == self._seen_nonces.maxlen and self._seen_nonces:
            removed = self._seen_nonces.popleft()
            self._seen_nonce_set.discard(removed)
        self._seen_nonces.append(nonce)
        self._seen_nonce_set.add(nonce)

    def _remember_reservation(self, reservation: Reservation) -> None:
        if reservation.reservation_id in self._reservation_records:
            return
        if len(self._reservation_records) >= self.config.scaling.reservation_registry_limit:
            raise RuntimeError("reservation registry capacity invariant violated")
        self._reservation_order.append(reservation.reservation_id)
        self._reservation_records[reservation.reservation_id] = (
            reservation.viewers,
            reservation.expires_at,
            reservation.authorization_id,
            reservation.nonce,
        )
        self._reservation_nonce_owner[reservation.nonce] = reservation.reservation_id

    def _purge_expired_reservations(self, now: int) -> None:
        retained: deque[str] = deque()
        for reservation_id in self._reservation_order:
            record = self._reservation_records.get(reservation_id)
            if record is None:
                continue
            if record[1] <= now:
                self._reservation_records.pop(reservation_id, None)
                self._reservation_nonce_owner.pop(record[3], None)
            else:
                retained.append(reservation_id)
        self._reservation_order = retained

    def _validate_metrics(self, sample: MetricsSample, now: int) -> tuple[str | None, int]:
        if sample.partition not in self.config.controller.partitions:
            return "unknown_partition", 0
        if sample.auth_context is None:
            return "missing_verified_auth_context", 0
        if (
            not sample.auth_context.verification_id
            or not sample.auth_context.principal_ref
            or sample.auth_context.verified_at < 0
            or sample.auth_context.verified_at > sample.observed_at
        ):
            return "invalid_verified_auth_context", 0
        if sample.observed_at > now or now - sample.observed_at > self.config.scaling.metrics_max_age_seconds:
            return "stale_or_future_metrics", 0
        if min(sample.sequence, sample.authorized_viewers, sample.active_sessions, sample.egress_mbps) < 0:
            return "negative_metric", 0
        previous = self._last_metrics_sequence.get(sample.partition)
        if previous is not None:
            if sample.sequence <= previous:
                return "replayed_sequence", 0
            if sample.sequence - previous > self.config.scaling.maximum_sequence_gap:
                return "sequence_gap_exceeded", 0
        if sample.sample_id in self._seen_nonce_set:
            return "replayed_sample", 0
        if len(sample.reservations) > self.config.scaling.maximum_reservations_per_sample:
            return "reservation_limit_exceeded", 0
        try:
            validate_metrics_sample(
                sample.to_dict(),
                maximum_reservations=self.config.scaling.maximum_reservations_per_sample,
            )
        except (ContractError, ValueError):
            return "invalid_metrics_contract", 0
        self._purge_expired_reservations(now)
        reservation_nonces: set[str] = set()
        reservation_ids: set[str] = set()
        live_reservation_ids: set[str] = set()
        reserved = 0
        for reservation in sample.reservations:
            if (
                reservation.viewers < 0
                or reservation.expires_at < 0
                or not reservation.reservation_id
                or not reservation.authorization_id
                or not reservation.nonce
            ):
                return "invalid_reservation", 0
            if reservation.reservation_id in reservation_ids or reservation.nonce in reservation_nonces:
                return "duplicate_reservation", 0
            record = (
                reservation.viewers,
                reservation.expires_at,
                reservation.authorization_id,
                reservation.nonce,
            )
            previous_reservation = self._reservation_records.get(reservation.reservation_id)
            if previous_reservation is not None and previous_reservation != record:
                return "replayed_reservation_id", 0
            nonce_owner = self._reservation_nonce_owner.get(reservation.nonce)
            if nonce_owner is not None and nonce_owner != reservation.reservation_id:
                return "replayed_reservation", 0
            reservation_ids.add(reservation.reservation_id)
            reservation_nonces.add(reservation.nonce)
            if reservation.expires_at > now:
                reserved += reservation.viewers
                live_reservation_ids.add(reservation.reservation_id)
        new_reservation_ids = live_reservation_ids - self._reservation_records.keys()
        if (
            len(self._reservation_records) + len(new_reservation_ids)
            > self.config.scaling.reservation_registry_limit
        ):
            return "reservation_registry_full", 0
        if sample.active_sessions > sample.authorized_viewers + reserved:
            return "sessions_exceed_authorized_demand", 0
        aggregate_demand = max(sample.authorized_viewers, sample.active_sessions)
        previous_demand = self._last_demand.get(sample.partition)
        if previous_demand is None:
            allowed_initial = self.config.scaling.maximum_initial_unreserved_demand + reserved
            if aggregate_demand > allowed_initial:
                return "initial_demand_exceeded", 0
        elif aggregate_demand > previous_demand[1]:
            elapsed = sample.observed_at - previous_demand[0]
            if elapsed <= 0:
                return "demand_rate_unmeasurable", 0
            rate = (aggregate_demand - previous_demand[1]) / elapsed
            if rate > self.config.scaling.maximum_demand_increase_per_second:
                return "demand_rate_exceeded", 0
        self._last_metrics_sequence[sample.partition] = sample.sequence
        self._last_demand[sample.partition] = (sample.observed_at, aggregate_demand)
        self._remember_nonce(sample.sample_id)
        for reservation in sorted(sample.reservations, key=lambda item: item.reservation_id):
            if reservation.expires_at > now:
                self._remember_reservation(reservation)
        return None, reserved

    def _capacity_signal(self, sample: MetricsSample, reserved: int) -> CapacitySignal:
        tier_config = self.config.tiers[self.config.scaling.target_tier]
        reserve_multiplier = 1.0 + self.config.scaling.reserve_ratio
        viewer_demand = max(sample.authorized_viewers, sample.active_sessions + reserved)
        viewer_nodes = math.ceil((viewer_demand * reserve_multiplier) / tier_config.capacity_viewers_per_node)
        egress_nodes = math.ceil((sample.egress_mbps * reserve_multiplier) / tier_config.capacity_egress_mbps_per_node)
        required = max(tier_config.minimum_nodes, viewer_nodes, egress_nodes)
        return CapacitySignal(
            authorized_viewers=sample.authorized_viewers,
            active_sessions=sample.active_sessions,
            reserved_viewers=reserved,
            egress_mbps=sample.egress_mbps,
            required_nodes=required,
        )

    def _hourly_cost_for(self, target_tier: Tier, target_count: int, egress_mbps: float = 0.0) -> float:
        total = self.config.cost.controller_hourly * self.config.controller.replicas
        for tier in Tier:
            count = target_count if tier == target_tier else self.desired[tier]
            total += self.config.cost.hourly_by_tier[tier] * count
        hourly_egress_gb = egress_mbps * 3600.0 / 8.0 / 1000.0
        total += hourly_egress_gb * self.config.cost.egress_per_gb
        return total

    def reconcile(self, sample: MetricsSample, now: int) -> ReconcileResult:
        target_tier = self.config.scaling.target_tier
        current = self.desired[target_tier]
        alert_start = len(self._alerts)
        error, reserved = self._validate_metrics(sample, now)
        if error is not None:
            self.counters["metrics_rejected_total"] += 1
            alert = self._alert("invalid_metrics_fail_closed", "critical", sample.partition, error, now)
            return ReconcileResult(False, True, None, current, (), (alert,), error)
        self.counters["metrics_accepted_total"] += 1
        signal = self._capacity_signal(sample, reserved)
        tier_config = self.config.tiers[target_tier]
        desired = min(signal.required_nodes, tier_config.maximum_nodes)
        if signal.required_nodes > tier_config.maximum_nodes:
            alert = self._alert("node_limit_reached", "critical", sample.partition, "required_nodes_exceed_maximum", now)
            return ReconcileResult(True, True, signal, current, (), (alert,), "node_limit_fail_closed")
        if self._hourly_cost_for(target_tier, desired, sample.egress_mbps) > self.config.cost.maximum_hourly_cost:
            alert = self._alert("spend_limit_reached", "critical", sample.partition, "estimated_hourly_cost_exceeds_maximum", now)
            return ReconcileResult(True, True, signal, current, (), (alert,), "spend_limit_fail_closed")

        direction: str | None = None
        stability = 0
        cooldown_ok = True
        if desired > current:
            direction = "out"
            stability = self.config.scaling.scale_out_stability_seconds
            cooldown_ok = self._last_scale_out_at is None or now - self._last_scale_out_at >= self.config.scaling.scale_out_cooldown_seconds
        elif desired < current:
            total_capacity = max(1, current * tier_config.capacity_viewers_per_node)
            utilization = max(signal.authorized_viewers, signal.active_sessions + signal.reserved_viewers) / total_capacity
            if utilization <= self.config.scaling.scale_in_utilization_threshold:
                direction = "in"
                stability = self.config.scaling.scale_in_stability_seconds
                cooldown_ok = self._last_scale_in_at is None or now - self._last_scale_in_at >= self.config.scaling.scale_in_cooldown_seconds

        if direction is None:
            self._pending_direction = None
            self._pending_since = None
            self._pending_desired = None
            return ReconcileResult(True, False, signal, current, (), tuple(list(self._alerts)[alert_start:]), "stable")
        if self._pending_direction != direction or self._pending_desired != desired:
            self._pending_direction = direction
            self._pending_desired = desired
            self._pending_since = now
            if stability > 0:
                return ReconcileResult(True, False, signal, current, (), tuple(list(self._alerts)[alert_start:]), f"scale_{direction}_stability_pending")
        if self._pending_since is None or now - self._pending_since < stability:
            return ReconcileResult(True, False, signal, current, (), tuple(list(self._alerts)[alert_start:]), f"scale_{direction}_stability_pending")
        if not cooldown_ok:
            return ReconcileResult(True, False, signal, current, (), tuple(list(self._alerts)[alert_start:]), f"scale_{direction}_cooldown")

        delta = min(abs(desired - current), self.config.scaling.maximum_actions_per_reconcile)
        applied_desired = current + delta if direction == "out" else current - delta
        if applied_desired != desired:
            self._alert("reconcile_batch_limited", "warning", sample.partition, "additional_reconcile_required", now)
        self.generation += 1
        self.desired[target_tier] = applied_desired
        reason = ActionReason.AUTOSCALE_OUT if direction == "out" else ActionReason.AUTOSCALE_IN
        actions = tuple(self._plan_delta(target_tier, applied_desired, now, reason))
        self._execute(actions, now)
        if direction == "out":
            self._last_scale_out_at = now
            self.counters["scale_out_total"] += len(actions)
        else:
            self._last_scale_in_at = now
            self.counters["scale_in_total"] += len(actions)
        self._pending_direction = None
        self._pending_since = None
        self._pending_desired = None
        return ReconcileResult(
            True,
            False,
            signal,
            applied_desired,
            actions,
            tuple(list(self._alerts)[alert_start:]),
            f"scaled_{direction}",
        )

    def set_sessions(self, count: int, now: int) -> dict[str, int]:
        if count < 0:
            raise ValueError("session count cannot be negative")
        if count > self.config.controller.session_registry_limit:
            raise ValueError("session count exceeds bounded registry limit")
        nodes = self._ready_nodes(self.config.scaling.target_tier)
        if count and not nodes:
            raise RuntimeError("no ready distributor capacity")
        ready_ids = {node.node_id for node in nodes}
        if any(node_id not in ready_ids for node_id in self.sessions.values()):
            raise RuntimeError("unresolved session assignments must be drained before reconciliation")
        total_capacity = sum(node.capacity_viewers for node in nodes)
        if count > total_capacity:
            raise ValueError("session count exceeds ready distributor capacity")
        target_ids = tuple(f"viewer-{index:09d}" for index in range(1, count + 1))
        assignments, planned = self._plan_assignments(target_ids, nodes)
        for node in nodes:
            node.sessions = planned[node.node_id]
        self.sessions = assignments
        self._emit("global", self.generation, "sessions_reconciled", now, {"active_sessions": count})
        return self.session_distribution()

    def session_distribution(self) -> dict[str, int]:
        return {
            node.node_id: len(node.sessions)
            for node in self._ready_nodes(self.config.scaling.target_tier)
        }

    def _plan_assignments(
        self, session_ids: tuple[str, ...] | list[str], nodes: list[Node]
    ) -> tuple[dict[str, str], dict[str, set[str]]]:
        if len(session_ids) > sum(node.capacity_viewers for node in nodes):
            raise ValueError("session assignments exceed ready distributor capacity")
        planned = {node.node_id: set() for node in nodes}
        assignments: dict[str, str] = {}
        for session_id in sorted(session_ids):
            eligible = [
                node
                for node in nodes
                if len(planned[node.node_id]) < node.capacity_viewers
            ]
            if not eligible:
                raise RuntimeError("capacity planning invariant violated")
            target = min(eligible, key=lambda item: (len(planned[item.node_id]), item.node_id))
            planned[target.node_id].add(session_id)
            assignments[session_id] = target.node_id
        return assignments, planned

    def _drain_node(self, node_id: str, now: int) -> bool:
        node = self.nodes.get(node_id)
        if node is None:
            return False
        peers = [candidate for candidate in self._ready_nodes(node.tier) if candidate.node_id != node_id]
        available = sum(max(0, peer.capacity_viewers - len(peer.sessions)) for peer in peers)
        if len(node.sessions) > available:
            self.counters["drain_unresolved_total"] += 1
            self._alert(
                "node_drain_unresolved",
                "critical",
                node.placement.region,
                "insufficient_ready_peer_capacity",
                now,
            )
            return False
        planned_additions = {peer.node_id: set() for peer in peers}
        for session_id in sorted(node.sessions):
            eligible = [
                peer
                for peer in peers
                if len(peer.sessions) + len(planned_additions[peer.node_id])
                < peer.capacity_viewers
            ]
            if not eligible:
                raise RuntimeError("drain capacity invariant violated")
            target = min(
                eligible,
                key=lambda item: (
                    len(item.sessions) + len(planned_additions[item.node_id]),
                    item.node_id,
                ),
            )
            planned_additions[target.node_id].add(session_id)
        moved = len(node.sessions)
        for peer in peers:
            for session_id in planned_additions[peer.node_id]:
                peer.sessions.add(session_id)
                self.sessions[session_id] = peer.node_id
        node.sessions.clear()
        self.counters["sessions_reassigned_total"] += moved
        self._emit(
            node.placement.region,
            node.generation,
            "node_drained",
            now,
            {"node_id": node_id, "sessions_reassigned": moved},
        )
        return True

    def _replacement_destroy_action(self, node: Node, now: int) -> Action:
        return Action(
            operation="destroy",
            node_id=node.node_id,
            generation=node.generation,
            tier=node.tier,
            placement=node.placement,
            reason=ActionReason.FAILED_NODE_CLEANUP,
            capacity_viewers=node.capacity_viewers,
            capacity_egress_mbps=node.capacity_egress_mbps,
            deadline_at=now + self.config.scaling.drain_timeout_seconds,
            requires_drained=True,
        )

    def fail_and_replace(self, node_id: str, now: int) -> tuple[Action, ...]:
        node = self.nodes.get(node_id)
        if node is None or node.state != Lifecycle.READY:
            raise ValueError("only a ready node can fail")
        if not self.apply_lifecycle_event(node_id, node.generation, Lifecycle.FAILED, now):
            raise RuntimeError("failed transition rejected")
        return self._replace_failed_node(node, now)

    def _replace_failed_node(self, node: Node, now: int) -> tuple[Action, ...]:
        if node.state != Lifecycle.FAILED:
            raise ValueError("replacement requires a failed node")
        self.apply_lifecycle_event(node.node_id, node.generation, Lifecycle.REPLACING, now)
        self.generation += 1
        replacement_id = self._next_node_id(node.tier)
        node.replace_node_id = replacement_id
        action = Action(
            "create",
            replacement_id,
            self.generation,
            node.tier,
            node.placement,
            ActionReason.FAILED_NODE_REPLACEMENT,
            node.capacity_viewers,
            node.capacity_egress_mbps,
            self._create_deadline_at(now),
            False,
            node.node_id,
        )
        self._execute((action,), now)
        cleanup = self.retry_replacement_cleanup(node.node_id, now)
        return (action, *cleanup)

    def retry_replacement_cleanup(self, node_id: str, now: int) -> tuple[Action, ...]:
        """Emit deferred destroy only after replacement capacity can drain safely."""

        node = self.nodes.get(node_id)
        if node is None or node.state != Lifecycle.REPLACING:
            raise ValueError("replacement cleanup requires a replacing node")
        replacement = self.nodes.get(node.replace_node_id or "")
        if replacement is None or replacement.state != Lifecycle.READY:
            self.counters["drain_unresolved_total"] += 1
            self._alert(
                "node_drain_unresolved",
                "critical",
                node.placement.region,
                "replacement_not_ready",
                now,
            )
            return ()
        peers = [candidate for candidate in self._ready_nodes(node.tier) if candidate.node_id != node_id]
        available = sum(max(0, peer.capacity_viewers - len(peer.sessions)) for peer in peers)
        if len(node.sessions) > available:
            self._drain_node(node.node_id, now)
            return ()
        destroy = self._replacement_destroy_action(node, now)
        self._execute((destroy,), now)
        if node.state != Lifecycle.TERMINATED:
            raise RuntimeError("replacement cleanup did not terminate drained node")
        self.counters["nodes_replaced_total"] += 1
        return (destroy,)

    def enforce_timeouts(self, now: int) -> tuple[str, ...]:
        failed: list[str] = []
        timeout_candidates = sorted(
            (
                node
                for node in self.nodes.values()
                if node.state not in {Lifecycle.TERMINATED, Lifecycle.FAILED}
            ),
            key=lambda node: node.node_id,
        )
        for node in timeout_candidates:
            timeout = self.config.lifecycle.timeouts.get(node.state.value)
            if timeout is not None and now - node.state_entered_at > timeout:
                timed_out_state = node.state
                if timed_out_state in {Lifecycle.DRAINING, Lifecycle.REPLACING} and node.sessions:
                    failed.append(node.node_id)
                    self._alert(
                        "lifecycle_timeout",
                        "critical",
                        node.placement.region,
                        f"{timed_out_state.value}_sessions_unresolved",
                        now,
                    )
                    node.state_entered_at = now
                    continue
                target_state = Lifecycle.TERMINATED if timed_out_state in {
                    Lifecycle.DRAINING,
                    Lifecycle.REPLACING,
                } else Lifecycle.FAILED
                if self.apply_lifecycle_event(node.node_id, node.generation, target_state, now):
                    failed.append(node.node_id)
                    self._alert("lifecycle_timeout", "critical", node.placement.region, timed_out_state.value, now)
                    if target_state == Lifecycle.FAILED:
                        self._replace_failed_node(node, now)
        return tuple(failed)

    def snapshot(self, name: str, now: int) -> dict[str, Any]:
        if not name or len(name) > 64:
            raise ValueError("snapshot name must contain 1..64 characters")
        payload = {
            "schema_version": 1,
            "name": name,
            "created_at": now,
            "generation": self.generation,
            "node_counter": self._node_counter,
            "desired": {tier.value: self.desired[tier] for tier in Tier},
            "nodes": [node.to_dict() for node in sorted(self.nodes.values(), key=lambda item: item.node_id)],
            "sessions": dict(sorted(self.sessions.items())),
            "config_digest": self.config.config_digest,
            "image_digest": self.config.image_digest,
        }
        canonical = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        envelope = {"digest": f"sha256:{hashlib.sha256(canonical).hexdigest()}", "payload": payload}
        if len(self._snapshots) >= self.config.controller.snapshot_limit and name not in self._snapshots:
            oldest = next(iter(self._snapshots))
            del self._snapshots[oldest]
        self._snapshots[name] = envelope
        self._emit("global", self.generation, "snapshot_created", now, {"name": name, "digest": envelope["digest"]})
        return envelope

    def rollback(self, envelope: dict[str, Any], now: int) -> None:
        payload = envelope.get("payload")
        digest = envelope.get("digest")
        if not isinstance(payload, dict) or not isinstance(digest, str):
            raise ValueError("invalid snapshot envelope")
        canonical = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        if digest != f"sha256:{hashlib.sha256(canonical).hexdigest()}":
            raise ValueError("snapshot digest mismatch")
        if payload.get("config_digest") != self.config.config_digest or payload.get("image_digest") != self.config.image_digest:
            raise ValueError("snapshot configuration or image digest mismatch")
        self.generation += 1
        self._node_counter = max(self._node_counter, int(payload.get("node_counter", 0)))
        self.desired = {Tier(key): int(value) for key, value in payload["desired"].items()}
        restored: dict[str, Node] = {}
        for raw in payload["nodes"]:
            placement = Placement(**raw["placement"])
            restored[raw["node_id"]] = Node(
                node_id=raw["node_id"],
                tier=Tier(raw["tier"]),
                placement=placement,
                image_digest=raw["image_digest"],
                config_digest=raw["config_digest"],
                generation=self.generation,
                state=Lifecycle(raw["state"]),
                state_entered_at=now,
                capacity_viewers=int(raw["capacity_viewers"]),
                capacity_egress_mbps=int(raw["capacity_egress_mbps"]),
                sessions=set(raw["sessions"]),
                replace_node_id=raw["replace_node_id"],
            )
        self.nodes = restored
        self.sessions = {str(key): str(value) for key, value in payload["sessions"].items()}
        self._emit("global", self.generation, "snapshot_rolled_back", now, {"snapshot_digest": digest})

    def shutdown(self, now: int) -> tuple[Action, ...]:
        self.sessions.clear()
        for node in self.nodes.values():
            node.sessions.clear()
        actions: list[Action] = []
        actions.extend(
            self._replacement_destroy_action(node, now)
            for node in sorted(self.nodes.values(), key=lambda item: item.node_id)
            if node.state == Lifecycle.REPLACING
        )
        for tier in Tier:
            self.desired[tier] = 0
            actions.extend(self._plan_delta(tier, 0, now, ActionReason.SAFE_SHUTDOWN))
        result = tuple(actions)
        self._execute(result, now)
        self._emit("global", self.generation, "control_plane_shutdown", now, {"remaining_sessions": 0})
        return result

    def cost_report(self, viewers: int, duration_hours: float = 1.0) -> dict[str, Any]:
        if duration_hours <= 0:
            raise ValueError("cost duration must be positive")
        node_hourly = self._hourly_cost_for(
            self.config.scaling.target_tier, self.desired[self.config.scaling.target_tier]
        )
        payload_mbps = viewers * self.config.cost.workload_mbps_per_viewer
        billable_mbps = payload_mbps * (1.0 + self.config.cost.protocol_overhead_ratio)
        egress_gb = billable_mbps * 3600.0 * duration_hours / 8.0 / 1000.0
        egress_cost = egress_gb * self.config.cost.egress_per_gb
        total_cost = node_hourly * duration_hours + egress_cost
        hourly_cost_at_workload = total_cost / duration_hours
        external_tariff_supplied = self.config.cost.rate_source != "local-simulation-measured"
        return {
            "currency": self.config.cost.currency,
            "rate_source": self.config.cost.rate_source,
            "rate_as_of": self.config.cost.rate_as_of,
            "duration_hours": duration_hours,
            "workload_mbps_per_viewer": self.config.cost.workload_mbps_per_viewer,
            "protocol_overhead_ratio": self.config.cost.protocol_overhead_ratio,
            "payload_egress_mbps": payload_mbps,
            "billable_egress_mbps": billable_mbps,
            "billable_egress_gb": egress_gb,
            "node_and_controller_cost": node_hourly * duration_hours,
            "egress_per_gb": self.config.cost.egress_per_gb,
            "egress_cost": egress_cost,
            "estimated_total_cost": total_cost,
            "estimated_hourly_cost_at_workload": hourly_cost_at_workload,
            "estimated_cost_per_viewer_hour": total_cost / (viewers * duration_hours) if viewers > 0 else None,
            "maximum_hourly_cost": self.config.cost.maximum_hourly_cost,
            "local_measured_remote_infrastructure_cost": self.config.cost.local_remote_infrastructure_cost,
            "external_provider_estimate": total_cost if external_tariff_supplied else None,
            "external_provider_tariff_required": not external_tariff_supplied,
        }

    def metrics(self) -> dict[str, Any]:
        lifecycle = {state.value: 0 for state in Lifecycle}
        for node in self.nodes.values():
            lifecycle[node.state.value] += 1
        return {
            "schema_version": 1,
            "service": "teremoq-control-plane",
            "instance_id": self.instance_id,
            "generation": self.generation,
            "controllers_configured": self.config.controller.replicas,
            "event_queue_depth": len(self._events),
            "event_queue_capacity": self.config.controller.event_queue_limit,
            "active_sessions": len(self.sessions),
            "desired_nodes": {tier.value: self.desired[tier] for tier in Tier},
            "lifecycle_nodes": lifecycle,
            "counters": dict(sorted(self.counters.items())),
        }

    def desired_state(self, partition: str) -> dict[str, Any]:
        if partition not in self.config.controller.partitions:
            raise ValueError("unknown desired-state partition")
        value = {
            "schema_version": 1,
            "partition": partition,
            "generation": self.generation,
            "image_digest": self.config.image_digest,
            "config_digest": self.config.config_digest,
            "desired_nodes": {tier.value: self.desired[tier] for tier in Tier},
        }
        validate_desired_state(
            value,
            maximum_nodes_by_tier={tier.value: self.config.tiers[tier].maximum_nodes for tier in Tier},
        )
        return value

    def action_envelope(
        self,
        actions: tuple[Action, ...],
        *,
        partition: str | None = None,
        generation: int | None = None,
    ) -> dict[str, Any]:
        selected_partition = partition or self.config.controller.partitions[0]
        if selected_partition not in self.config.controller.partitions:
            raise ValueError("unknown action-envelope partition")
        selected_generation = self.generation if generation is None else generation
        return serialize_action_envelope(
            deployment_id=self.config.deployment_id,
            partition=selected_partition,
            generation=selected_generation,
            image_digest=self.config.image_digest,
            config_digest=self.config.config_digest,
            actions=actions,
            maximum_actions=self.config.provider.action_envelope_max_actions,
            maximum_bytes=self.config.provider.action_envelope_max_bytes,
        )

    def events_since(self, sequence: int) -> tuple[Event, ...]:
        if self._events and sequence < self._events[0].sequence - 1:
            raise ValueError("replication cursor expired; restore a snapshot")
        return tuple(event for event in self._events if event.sequence > sequence)

    def _emit(self, partition: str, generation: int, event_type: str, now: int, payload: dict[str, Any]) -> None:
        self._event_sequence += 1
        event = Event(
            event_id=f"{self.instance_id}-{self._event_sequence:012d}",
            partition=partition,
            sequence=self._event_sequence,
            generation=generation,
            event_type=event_type,
            observed_at=now,
            payload=payload,
        )
        validate_audit_event(event.to_dict())
        self._events.append(event)

    def _alert(self, code: str, severity: str, partition: str, reason: str, now: int) -> Alert:
        alert = Alert(code, severity, partition, reason, now)
        self._alerts.append(alert)
        self._emit(partition, self.generation, "alert_raised", now, alert.to_dict())
        return alert

    def audit_export(self) -> dict[str, Any]:
        return {
            "schema_version": 1,
            "config_digest": self.config.config_digest,
            "image_digest": self.config.image_digest,
            "events": [event.to_dict() for event in self._events],
            "alerts": [alert.to_dict() for alert in self._alerts],
            "metrics": self.metrics(),
        }


def canonical_digest(value: Any) -> str:
    data = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return f"sha256:{hashlib.sha256(data).hexdigest()}"


def all_states(nodes: Iterable[Node]) -> set[Lifecycle]:
    return {node.state for node in nodes}
