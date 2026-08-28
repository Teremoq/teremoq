# SPDX-License-Identifier: Apache-2.0
"""Strict JSON configuration loader."""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Any

from .model import Placement, Tier


class ConfigError(ValueError):
    """Configuration is incomplete, ambiguous, or unsafe."""


SHA256_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
MAX_SAFE_JSON_INTEGER = (1 << 53) - 1
MAX_CONFIG_COLLECTION_LIMIT = (1 << 31) - 1


def _exact_keys(value: dict[str, Any], required: set[str], optional: set[str], path: str) -> None:
    missing = required - value.keys()
    unknown = value.keys() - required - optional
    if missing:
        raise ConfigError(f"{path}: missing keys: {', '.join(sorted(missing))}")
    if unknown:
        raise ConfigError(f"{path}: unknown keys: {', '.join(sorted(unknown))}")


def _integer(value: Any, minimum: int, maximum: int, path: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise ConfigError(f"{path}: expected integer in [{minimum}, {maximum}]")
    return value


def _number(value: Any, minimum: float, maximum: float, path: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ConfigError(f"{path}: expected number")
    result = float(value)
    if not minimum <= result <= maximum:
        raise ConfigError(f"{path}: expected number in [{minimum}, {maximum}]")
    return result


def _name(value: Any, path: str) -> str:
    if not isinstance(value, str) or NAME_RE.fullmatch(value) is None:
        raise ConfigError(f"{path}: expected lowercase DNS-like name")
    return value


@dataclass(frozen=True, slots=True)
class ControllerConfig:
    replicas: int
    partitions: tuple[str, ...]
    event_queue_limit: int
    snapshot_limit: int
    session_registry_limit: int


@dataclass(frozen=True, slots=True)
class TierConfig:
    tier: Tier
    enabled: bool
    minimum_nodes: int
    maximum_nodes: int
    capacity_viewers_per_node: int
    capacity_egress_mbps_per_node: int
    placements: tuple[Placement, ...]


@dataclass(frozen=True, slots=True)
class ScalingConfig:
    target_tier: Tier
    reserve_ratio: float
    scale_out_cooldown_seconds: int
    scale_in_cooldown_seconds: int
    scale_out_stability_seconds: int
    scale_in_stability_seconds: int
    scale_in_utilization_threshold: float
    metrics_max_age_seconds: int
    maximum_sequence_gap: int
    maximum_demand_increase_per_second: float
    maximum_initial_unreserved_demand: int
    maximum_reservations_per_sample: int
    reservation_registry_limit: int
    maximum_actions_per_reconcile: int
    drain_timeout_seconds: int


@dataclass(frozen=True, slots=True)
class LifecycleConfig:
    timeouts: dict[str, int]


@dataclass(frozen=True, slots=True)
class ProviderConfig:
    mode: str
    adapter: str


@dataclass(frozen=True, slots=True)
class CostConfig:
    currency: str
    rate_source: str
    rate_as_of: str
    hourly_by_tier: dict[Tier, float]
    controller_hourly: float
    egress_per_gb: float
    workload_mbps_per_viewer: float
    protocol_overhead_ratio: float
    maximum_hourly_cost: float
    local_remote_infrastructure_cost: float


@dataclass(frozen=True, slots=True)
class MilestoneConfig:
    gate_viewers: int
    progressive_scenarios: tuple[int, ...]
    expected_origin_nodes: int
    expected_distributor_nodes: int
    expected_controller_nodes: int
    forbidden_execution_viewers: int


@dataclass(frozen=True, slots=True)
class Config:
    schema_version: int
    deployment_id: str
    image_digest: str
    config_digest: str
    controller: ControllerConfig
    tiers: dict[Tier, TierConfig]
    scaling: ScalingConfig
    lifecycle: LifecycleConfig
    provider: ProviderConfig
    cost: CostConfig
    milestone: MilestoneConfig


def _validate_placement(value: Any, path: str) -> Placement:
    if not isinstance(value, dict):
        raise ConfigError(f"{path}: expected object")
    _exact_keys(value, {"provider", "region", "zone"}, set(), path)
    return Placement(
        provider=_name(value["provider"], f"{path}.provider"),
        region=_name(value["region"], f"{path}.region"),
        zone=_name(value["zone"], f"{path}.zone"),
    )


def _validate_tiers(value: Any) -> dict[Tier, TierConfig]:
    if not isinstance(value, dict):
        raise ConfigError("tiers: expected object")
    expected = {tier.value for tier in Tier}
    if set(value) != expected:
        raise ConfigError(f"tiers: expected exactly {', '.join(sorted(expected))}")
    result: dict[Tier, TierConfig] = {}
    for tier in Tier:
        item = value[tier.value]
        path = f"tiers.{tier.value}"
        if not isinstance(item, dict):
            raise ConfigError(f"{path}: expected object")
        _exact_keys(
            item,
            {
                "enabled",
                "minimum_nodes",
                "maximum_nodes",
                "capacity_viewers_per_node",
                "capacity_egress_mbps_per_node",
                "placements",
            },
            set(),
            path,
        )
        if not isinstance(item["enabled"], bool):
            raise ConfigError(f"{path}.enabled: expected boolean")
        minimum = _integer(item["minimum_nodes"], 0, MAX_SAFE_JSON_INTEGER, f"{path}.minimum_nodes")
        maximum = _integer(item["maximum_nodes"], 0, MAX_SAFE_JSON_INTEGER, f"{path}.maximum_nodes")
        if minimum > maximum:
            raise ConfigError(f"{path}: minimum_nodes exceeds maximum_nodes")
        viewers = _integer(
            item["capacity_viewers_per_node"], 1, MAX_SAFE_JSON_INTEGER, f"{path}.capacity_viewers_per_node"
        )
        egress = _integer(
            item["capacity_egress_mbps_per_node"], 1, MAX_SAFE_JSON_INTEGER, f"{path}.capacity_egress_mbps_per_node"
        )
        placements_raw = item["placements"]
        if not isinstance(placements_raw, list) or not placements_raw:
            raise ConfigError(f"{path}.placements: expected non-empty array")
        placements = tuple(
            _validate_placement(placement, f"{path}.placements[{index}]")
            for index, placement in enumerate(placements_raw)
        )
        if len(set(placements)) != len(placements):
            raise ConfigError(f"{path}.placements: duplicate placement")
        result[tier] = TierConfig(
            tier=tier,
            enabled=item["enabled"],
            minimum_nodes=minimum,
            maximum_nodes=maximum,
            capacity_viewers_per_node=viewers,
            capacity_egress_mbps_per_node=egress,
            placements=placements,
        )
    if not result[Tier.ORIGIN].enabled or not result[Tier.CORE].enabled:
        raise ConfigError("tiers: origin and core must be enabled")
    return result


def load_config(path: str | Path) -> Config:
    source = Path(path)
    try:
        raw_bytes = source.read_bytes()
        value = json.loads(raw_bytes)
    except (OSError, json.JSONDecodeError) as error:
        raise ConfigError(f"cannot load {source}: {error}") from error
    if not isinstance(value, dict):
        raise ConfigError("root: expected object")
    _exact_keys(
        value,
        {
            "schema_version",
            "deployment_id",
            "image_digest",
            "controller",
            "tiers",
            "scaling",
            "lifecycle",
            "provider",
            "cost",
            "milestone",
        },
        set(),
        "root",
    )
    schema_version = _integer(value["schema_version"], 1, 1, "schema_version")
    deployment_id = _name(value["deployment_id"], "deployment_id")
    image_digest = value["image_digest"]
    if not isinstance(image_digest, str) or SHA256_RE.fullmatch(image_digest) is None:
        raise ConfigError("image_digest: immutable sha256 digest required")

    controller = value["controller"]
    if not isinstance(controller, dict):
        raise ConfigError("controller: expected object")
    _exact_keys(
        controller,
        {"replicas", "partitions", "event_queue_limit", "snapshot_limit", "session_registry_limit"},
        set(),
        "controller",
    )
    replicas = _integer(controller["replicas"], 1, 1024, "controller.replicas")
    partitions_raw = controller["partitions"]
    if not isinstance(partitions_raw, list) or not partitions_raw:
        raise ConfigError("controller.partitions: expected non-empty array")
    partitions = tuple(_name(item, f"controller.partitions[{index}]") for index, item in enumerate(partitions_raw))
    if len(set(partitions)) != len(partitions):
        raise ConfigError("controller.partitions: duplicate partition")
    controller_config = ControllerConfig(
        replicas=replicas,
        partitions=partitions,
        event_queue_limit=_integer(
            controller["event_queue_limit"], 16, MAX_CONFIG_COLLECTION_LIMIT, "controller.event_queue_limit"
        ),
        snapshot_limit=_integer(
            controller["snapshot_limit"], 1, MAX_CONFIG_COLLECTION_LIMIT, "controller.snapshot_limit"
        ),
        session_registry_limit=_integer(
            controller["session_registry_limit"], 1, MAX_CONFIG_COLLECTION_LIMIT, "controller.session_registry_limit"
        ),
    )

    tiers = _validate_tiers(value["tiers"])

    scaling = value["scaling"]
    if not isinstance(scaling, dict):
        raise ConfigError("scaling: expected object")
    scaling_keys = {
        "target_tier",
        "reserve_ratio",
        "scale_out_cooldown_seconds",
        "scale_in_cooldown_seconds",
        "scale_out_stability_seconds",
        "scale_in_stability_seconds",
        "scale_in_utilization_threshold",
        "metrics_max_age_seconds",
        "maximum_sequence_gap",
        "maximum_demand_increase_per_second",
        "maximum_initial_unreserved_demand",
        "maximum_reservations_per_sample",
        "reservation_registry_limit",
        "maximum_actions_per_reconcile",
        "drain_timeout_seconds",
    }
    _exact_keys(scaling, scaling_keys, set(), "scaling")
    try:
        target_tier = Tier(scaling["target_tier"])
    except (TypeError, ValueError) as error:
        raise ConfigError("scaling.target_tier: invalid tier") from error
    if not tiers[target_tier].enabled:
        raise ConfigError("scaling.target_tier: tier is disabled")
    scaling_config = ScalingConfig(
        target_tier=target_tier,
        reserve_ratio=_number(scaling["reserve_ratio"], 0.0, 10.0, "scaling.reserve_ratio"),
        scale_out_cooldown_seconds=_integer(scaling["scale_out_cooldown_seconds"], 0, 604_800, "scaling.scale_out_cooldown_seconds"),
        scale_in_cooldown_seconds=_integer(scaling["scale_in_cooldown_seconds"], 0, 604_800, "scaling.scale_in_cooldown_seconds"),
        scale_out_stability_seconds=_integer(scaling["scale_out_stability_seconds"], 0, 604_800, "scaling.scale_out_stability_seconds"),
        scale_in_stability_seconds=_integer(scaling["scale_in_stability_seconds"], 0, 604_800, "scaling.scale_in_stability_seconds"),
        scale_in_utilization_threshold=_number(scaling["scale_in_utilization_threshold"], 0.0, 1.0, "scaling.scale_in_utilization_threshold"),
        metrics_max_age_seconds=_integer(scaling["metrics_max_age_seconds"], 1, 86_400, "scaling.metrics_max_age_seconds"),
        maximum_sequence_gap=_integer(
            scaling["maximum_sequence_gap"], 1, MAX_SAFE_JSON_INTEGER, "scaling.maximum_sequence_gap"
        ),
        maximum_demand_increase_per_second=_number(
            scaling["maximum_demand_increase_per_second"],
            0.0,
            float(MAX_SAFE_JSON_INTEGER),
            "scaling.maximum_demand_increase_per_second",
        ),
        maximum_initial_unreserved_demand=_integer(
            scaling["maximum_initial_unreserved_demand"],
            0,
            MAX_SAFE_JSON_INTEGER,
            "scaling.maximum_initial_unreserved_demand",
        ),
        maximum_reservations_per_sample=_integer(
            scaling["maximum_reservations_per_sample"],
            0,
            MAX_CONFIG_COLLECTION_LIMIT,
            "scaling.maximum_reservations_per_sample",
        ),
        reservation_registry_limit=_integer(
            scaling["reservation_registry_limit"],
            1,
            MAX_CONFIG_COLLECTION_LIMIT,
            "scaling.reservation_registry_limit",
        ),
        maximum_actions_per_reconcile=_integer(
            scaling["maximum_actions_per_reconcile"],
            1,
            MAX_CONFIG_COLLECTION_LIMIT,
            "scaling.maximum_actions_per_reconcile",
        ),
        drain_timeout_seconds=_integer(scaling["drain_timeout_seconds"], 1, 86_400, "scaling.drain_timeout_seconds"),
    )

    lifecycle = value["lifecycle"]
    if not isinstance(lifecycle, dict):
        raise ConfigError("lifecycle: expected object")
    _exact_keys(lifecycle, {"timeouts_seconds"}, set(), "lifecycle")
    timeouts = lifecycle["timeouts_seconds"]
    expected_timeout_states = {"provisioning", "bootstrapping", "authenticated", "registered", "draining", "replacing"}
    if not isinstance(timeouts, dict) or set(timeouts) != expected_timeout_states:
        raise ConfigError("lifecycle.timeouts_seconds: exact lifecycle timeout set required")
    lifecycle_config = LifecycleConfig(
        timeouts={key: _integer(item, 1, 86_400, f"lifecycle.timeouts_seconds.{key}") for key, item in timeouts.items()}
    )

    provider = value["provider"]
    if not isinstance(provider, dict):
        raise ConfigError("provider: expected object")
    _exact_keys(provider, {"mode", "adapter"}, set(), "provider")
    if provider["mode"] not in {"simulate", "dry-run"} or provider["adapter"] != "local-simulator":
        raise ConfigError("provider: only local-simulator in simulate or dry-run mode is allowed")
    provider_config = ProviderConfig(mode=provider["mode"], adapter=provider["adapter"])

    cost = value["cost"]
    if not isinstance(cost, dict):
        raise ConfigError("cost: expected object")
    _exact_keys(
        cost,
        {
            "currency",
            "rate_source",
            "rate_as_of",
            "hourly_by_tier",
            "controller_hourly",
            "egress_per_gb",
            "workload_mbps_per_viewer",
            "protocol_overhead_ratio",
            "maximum_hourly_cost",
            "local_remote_infrastructure_cost",
        },
        set(),
        "cost",
    )
    hourly = cost["hourly_by_tier"]
    if not isinstance(hourly, dict) or set(hourly) != {tier.value for tier in Tier}:
        raise ConfigError("cost.hourly_by_tier: exact tier set required")
    currency = cost["currency"]
    rate_source = cost["rate_source"]
    rate_as_of = cost["rate_as_of"]
    if not all(isinstance(item, str) and item for item in (currency, rate_source, rate_as_of)):
        raise ConfigError("cost: currency, rate_source and rate_as_of must be non-empty strings")
    try:
        date.fromisoformat(rate_as_of)
    except ValueError as error:
        raise ConfigError("cost.rate_as_of: expected ISO-8601 calendar date") from error
    cost_config = CostConfig(
        currency=currency,
        rate_source=rate_source,
        rate_as_of=rate_as_of,
        hourly_by_tier={
            Tier(key): _number(item, 0.0, float(MAX_SAFE_JSON_INTEGER), f"cost.hourly_by_tier.{key}")
            for key, item in hourly.items()
        },
        controller_hourly=_number(
            cost["controller_hourly"], 0.0, float(MAX_SAFE_JSON_INTEGER), "cost.controller_hourly"
        ),
        egress_per_gb=_number(cost["egress_per_gb"], 0.0, float(MAX_SAFE_JSON_INTEGER), "cost.egress_per_gb"),
        workload_mbps_per_viewer=_number(
            cost["workload_mbps_per_viewer"],
            0.0,
            float(MAX_SAFE_JSON_INTEGER),
            "cost.workload_mbps_per_viewer",
        ),
        protocol_overhead_ratio=_number(
            cost["protocol_overhead_ratio"], 0.0, 10.0, "cost.protocol_overhead_ratio"
        ),
        maximum_hourly_cost=_number(
            cost["maximum_hourly_cost"], 0.0, float(MAX_SAFE_JSON_INTEGER), "cost.maximum_hourly_cost"
        ),
        local_remote_infrastructure_cost=_number(
            cost["local_remote_infrastructure_cost"],
            0.0,
            float(MAX_SAFE_JSON_INTEGER),
            "cost.local_remote_infrastructure_cost",
        ),
    )

    milestone = value["milestone"]
    if not isinstance(milestone, dict):
        raise ConfigError("milestone: expected object")
    _exact_keys(
        milestone,
        {"gate_viewers", "progressive_scenarios", "expected_origin_nodes", "expected_distributor_nodes", "expected_controller_nodes", "forbidden_execution_viewers"},
        set(),
        "milestone",
    )
    scenario_raw = milestone["progressive_scenarios"]
    if not isinstance(scenario_raw, list) or not scenario_raw:
        raise ConfigError("milestone.progressive_scenarios: expected non-empty array")
    scenarios = tuple(
        _integer(item, 0, MAX_SAFE_JSON_INTEGER, f"milestone.progressive_scenarios[{index}]")
        for index, item in enumerate(scenario_raw)
    )
    if tuple(sorted(set(scenarios))) != scenarios:
        raise ConfigError("milestone.progressive_scenarios: must be strictly increasing")
    milestone_config = MilestoneConfig(
        gate_viewers=_integer(milestone["gate_viewers"], 1, MAX_SAFE_JSON_INTEGER, "milestone.gate_viewers"),
        progressive_scenarios=scenarios,
        expected_origin_nodes=_integer(
            milestone["expected_origin_nodes"], 1, MAX_SAFE_JSON_INTEGER, "milestone.expected_origin_nodes"
        ),
        expected_distributor_nodes=_integer(
            milestone["expected_distributor_nodes"],
            1,
            MAX_SAFE_JSON_INTEGER,
            "milestone.expected_distributor_nodes",
        ),
        expected_controller_nodes=_integer(milestone["expected_controller_nodes"], 1, 1024, "milestone.expected_controller_nodes"),
        forbidden_execution_viewers=_integer(
            milestone["forbidden_execution_viewers"],
            1,
            MAX_SAFE_JSON_INTEGER,
            "milestone.forbidden_execution_viewers",
        ),
    )
    if milestone_config.gate_viewers not in scenarios:
        raise ConfigError("milestone.gate_viewers must be a progressive scenario")
    if milestone_config.expected_controller_nodes != replicas:
        raise ConfigError("milestone.expected_controller_nodes must match controller.replicas")
    if milestone_config.gate_viewers >= milestone_config.forbidden_execution_viewers:
        raise ConfigError("milestone forbidden execution gate must exceed the demonstrated gate")

    canonical = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return Config(
        schema_version=schema_version,
        deployment_id=deployment_id,
        image_digest=image_digest,
        config_digest=f"sha256:{hashlib.sha256(canonical).hexdigest()}",
        controller=controller_config,
        tiers=tiers,
        scaling=scaling_config,
        lifecycle=lifecycle_config,
        provider=provider_config,
        cost=cost_config,
        milestone=milestone_config,
    )
