# SPDX-License-Identifier: Apache-2.0
"""Install-free CLI and reproducible milestone demonstration."""

from __future__ import annotations

import argparse
import json
import math
import platform
import sys
import time
from pathlib import Path
from typing import Any

from .config import Config, ConfigError, load_config
from .engine import ControlPlane, canonical_digest
from .model import MetricsSample, Tier, VerifiedAuthContext


def _sample(viewers: int, sequence: int, now: int, partition: str, config: Config) -> MetricsSample:
    return MetricsSample(
        sample_id=f"milestone-{sequence:04d}",
        partition=partition,
        sequence=sequence,
        observed_at=now,
        authorized_viewers=viewers,
        active_sessions=viewers,
        egress_mbps=math.ceil(
            viewers * config.cost.workload_mbps_per_viewer * (1.0 + config.cost.protocol_overhead_ratio)
        ),
        auth_context=VerifiedAuthContext(
            verification_id=f"local-verification-{sequence:04d}",
            principal_ref="local-milestone-principal",
            verified_at=now,
        ),
    )


def run_demo(config: Config) -> dict[str, Any]:
    started = time.perf_counter_ns()
    if any(item >= config.milestone.forbidden_execution_viewers for item in config.milestone.progressive_scenarios):
        raise ValueError("progressive scenario crosses the configured out-of-scope execution gate")
    plane = ControlPlane(config)
    now = 0
    bootstrap_actions = plane.bootstrap(now)
    action_envelopes: list[dict[str, Any]] = [
        {"label": "bootstrap", "envelope": plane.action_envelope(bootstrap_actions)}
    ]
    initial_snapshot = plane.snapshot("initial", now)
    sequence = 0
    scenarios: list[dict[str, Any]] = []
    for viewers in config.milestone.progressive_scenarios:
        now += max(config.scaling.scale_out_cooldown_seconds, 1)
        sequence += 1
        first = plane.reconcile(_sample(viewers, sequence, now, config.controller.partitions[0], config), now)
        results = [first]
        if first.reason.endswith("stability_pending"):
            now += max(config.scaling.scale_out_stability_seconds, config.scaling.scale_in_stability_seconds)
            sequence += 1
            second = plane.reconcile(_sample(viewers, sequence, now, config.controller.partitions[0], config), now)
            results.append(second)
        for result_index, result in enumerate(results):
            if result.actions:
                action_envelopes.append(
                    {
                        "label": f"scenario-{viewers}-{result_index + 1}",
                        "envelope": plane.action_envelope(result.actions),
                    }
                )
        distribution = plane.set_sessions(viewers, now)
        scenarios.append(
            {
                "viewers": viewers,
                "samples": len(results),
                "reconcile": [item.to_dict() for item in results],
                "ready_distributors": len(plane._ready_nodes(config.scaling.target_tier)),
                "session_distribution": distribution,
            }
        )

    ready_origin = plane._ready_nodes(Tier.ORIGIN)
    ready_distributors = plane._ready_nodes(config.scaling.target_tier)
    if len(ready_origin) != config.milestone.expected_origin_nodes:
        raise AssertionError("origin milestone count not reached")
    if len(ready_distributors) != config.milestone.expected_distributor_nodes:
        raise AssertionError("distributor milestone count not reached")
    if config.controller.replicas != config.milestone.expected_controller_nodes:
        raise AssertionError("controller milestone count not reached")
    if len(plane.sessions) != config.milestone.gate_viewers:
        raise AssertionError("viewer gate not reached")

    before_failure_distribution = plane.session_distribution()
    failed_node = ready_distributors[0].node_id
    replacement_actions = plane.fail_and_replace(failed_node, now + 1)
    action_envelopes.append(
        {"label": "replacement", "envelope": plane.action_envelope(replacement_actions)}
    )
    after_recovery_distribution = plane.session_distribution()
    if failed_node in after_recovery_distribution:
        raise AssertionError("failed distributor remained ready")
    if sum(after_recovery_distribution.values()) != config.milestone.gate_viewers:
        raise AssertionError("sessions were not recovered")
    recovered_snapshot = plane.snapshot("recovered", now + 2)
    generation_before_rollback = plane.generation
    plane.rollback(recovered_snapshot, now + 3)
    if plane.generation <= generation_before_rollback:
        raise AssertionError("rollback did not advance generation")

    milestone_metrics = plane.metrics()
    cost = plane.cost_report(config.milestone.gate_viewers)
    audit = plane.audit_export()
    cleanup_actions = plane.shutdown(now + 4)
    action_envelopes.append(
        {"label": "cleanup", "envelope": plane.action_envelope(cleanup_actions)}
    )
    cleanup_metrics = plane.metrics()
    if cleanup_metrics["active_sessions"] != 0 or any(
        node.state.value != "terminated" for node in plane.nodes.values()
    ):
        raise AssertionError("cleanup left active local state")

    elapsed_ns = time.perf_counter_ns() - started
    report: dict[str, Any] = {
        "schema_version": 1,
        "result": "pass",
        "scope": "local deterministic control-plane simulation; no real video or provider capacity",
        "runtime": {
            "python": platform.python_version(),
            "platform": platform.platform(),
            "elapsed_ns_measured": elapsed_ns,
            "logical_time_seconds": now + 4,
        },
        "inputs": {
            "config_digest": config.config_digest,
            "image_digest_identifier": config.image_digest,
            "provider_mode": config.provider.mode,
            "controller_replicas": config.controller.replicas,
            "partitions": list(config.controller.partitions),
        },
        "gate": {
            "viewers": config.milestone.gate_viewers,
            "origin_nodes": len(ready_origin),
            "distributor_nodes": len(ready_distributors),
            "controller_nodes": config.controller.replicas,
            "progressive_scenarios": list(config.milestone.progressive_scenarios),
            "out_of_scope_execution_floor": config.milestone.forbidden_execution_viewers,
            "larger_scenario_executed": False,
        },
        "bootstrap_actions": [action.to_dict() for action in bootstrap_actions],
        "action_envelopes": action_envelopes,
        "scenarios": scenarios,
        "failure_recovery": {
            "failed_node": failed_node,
            "before_distribution": before_failure_distribution,
            "replacement_actions": [action.to_dict() for action in replacement_actions],
            "after_distribution": after_recovery_distribution,
            "sessions_recovered": sum(after_recovery_distribution.values()),
        },
        "snapshot_rollback": {
            "initial_digest": initial_snapshot["digest"],
            "recovered_digest": recovered_snapshot["digest"],
            "rollback_generation": plane.generation,
        },
        "cost": cost,
        "milestone_metrics": milestone_metrics,
        "alerts": audit["alerts"],
        "audit_digest": canonical_digest(audit),
        "cleanup": {
            "actions": [action.to_dict() for action in cleanup_actions],
            "active_sessions": cleanup_metrics["active_sessions"],
            "terminated_nodes": cleanup_metrics["lifecycle_nodes"]["terminated"],
            "local_remote_infrastructure_cost": config.cost.local_remote_infrastructure_cost,
        },
        "limitations": [
            "The simulator does not create remote resources or forward video.",
            "The local milestone runs one controller; leases and replicated storage are integration contracts.",
            "The opaque local auth context is test input, not a PKI or signature verification result.",
            "Unresolved drain preserves assignments; no forced session-termination policy is enabled.",
            "External provider cost estimates remain unavailable until dated tariffs are supplied.",
            "Action envelope files are local plans; no Platform adapter or transport consumed them.",
            "The 100-viewer result is simulated control-state evidence, not real media capacity evidence.",
        ],
    }
    report["report_content_digest"] = canonical_digest(report)
    return report


def render_markdown(report: dict[str, Any]) -> str:
    failure = report["failure_recovery"]
    cost = report["cost"]
    return "\n".join(
        [
            "# Task 09 local milestone evidence",
            "",
            f"- Result: `{report['result']}`",
            f"- Scope: {report['scope']}",
            f"- Config digest: `{report['inputs']['config_digest']}`",
            f"- Report content digest: `{report['report_content_digest']}`",
            f"- Measured wall execution: `{report['runtime']['elapsed_ns_measured']} ns`",
            f"- Logical time: `{report['runtime']['logical_time_seconds']} s`",
            "",
            "## Demonstrated gate",
            "",
            f"Progressive viewers: `{report['gate']['progressive_scenarios']}`. Final topology: "
            f"`{report['gate']['origin_nodes']} origin`, `{report['gate']['distributor_nodes']} distributors`, "
            f"`{report['gate']['controller_nodes']} control`. No larger scenario was executed.",
            "",
            "## Failure and recovery",
            "",
            f"Failed `{failure['failed_node']}`, emitted ordered create/destroy replacement actions, "
            f"and recovered `{failure['sessions_recovered']}` session assignments. Distribution after recovery: "
            f"`{failure['after_distribution']}`.",
            "",
            "## Cost boundary",
            "",
            f"Measured local remote-infrastructure cost: `{cost['local_measured_remote_infrastructure_cost']} "
            f"{cost['currency']}`. External provider estimate: `unavailable`; dated external tariffs are required.",
            "",
            "## Cleanup",
            "",
            f"Active sessions: `{report['cleanup']['active_sessions']}`; terminated simulated nodes: "
            f"`{report['cleanup']['terminated_nodes']}`.",
            "",
            "## Limitations",
            "",
            *(f"- {item}" for item in report["limitations"]),
            "",
        ]
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Teremoq deterministic control-plane simulator")
    parser.add_argument("--config", required=True, type=Path)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("validate", help="strictly validate configuration")
    demo = subparsers.add_parser("demo", help="run only the configured local milestone scenarios")
    demo.add_argument("--report-dir", type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        config = load_config(arguments.config)
        if arguments.command == "validate":
            print(json.dumps({"result": "valid", "config_digest": config.config_digest}, sort_keys=True))
            return 0
        report = run_demo(config)
        if arguments.report_dir is not None:
            arguments.report_dir.mkdir(parents=True, exist_ok=True)
            json_path = arguments.report_dir / "milestone-100.json"
            markdown_path = arguments.report_dir / "milestone-100.md"
            json_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            markdown_path.write_text(render_markdown(report), encoding="utf-8")
            for item in report["action_envelopes"]:
                action_path = arguments.report_dir / f"actions-{item['label']}.json"
                action_path.write_text(
                    json.dumps(item["envelope"], indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
        print(json.dumps(report, sort_keys=True))
        return 0
    except (ConfigError, ValueError, RuntimeError, AssertionError) as error:
        print(json.dumps({"result": "fail", "error": str(error)}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
