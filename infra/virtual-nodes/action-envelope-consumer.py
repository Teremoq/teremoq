#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
"""Apply a validated Task 09 action envelope to the local provider adapter.

The schema, enum and canonical idempotency semantics are imported from the
read-only control-plane source. This file adds only Task 10 run policy and the
local adapter boundary; it is not a transport or a second schema.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, NoReturn


def fail(message: str) -> NoReturn:
    raise ValueError(message)


def strict_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail("duplicate JSON property")
        result[key] = value
    return result


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description="Consume one validated local action envelope")
    value.add_argument("--control-plane-root", required=True, type=Path)
    value.add_argument("--config", required=True, type=Path)
    value.add_argument("--envelope", required=True, type=Path)
    value.add_argument("--label", required=True)
    value.add_argument("--action-index", default="all")
    value.add_argument("--viewers", required=True, type=int)
    value.add_argument("--logical-now", required=True, type=int)
    value.add_argument("--adapter", required=True, type=Path)
    value.add_argument("--mode", choices=("simulate", "dry-run"), required=True)
    value.add_argument("--run-id", required=True)
    value.add_argument("--state-dir", required=True, type=Path)
    value.add_argument("--topology", required=True, type=Path)
    return value


def main() -> int:
    arguments = parser().parse_args()
    if re.fullmatch(r"[a-z0-9][a-z0-9-]{0,31}", arguments.label) is None:
        fail("label must be a bounded lowercase token")
    source_root = arguments.control_plane_root / "src"
    if not source_root.is_dir() or not arguments.config.is_file():
        fail("bound control-plane source or configuration is unavailable")
    sys.path.insert(0, str(source_root))

    from teremoq_control.config import load_config  # pylint: disable=import-outside-toplevel
    from teremoq_control.contracts import (  # pylint: disable=import-outside-toplevel
        ActionEnvelopeGuard,
    )
    from teremoq_control.model import Placement, Tier  # pylint: disable=import-outside-toplevel

    config = load_config(arguments.config)
    if arguments.viewers != config.milestone.gate_viewers:
        fail("requested viewers do not match the configured milestone gate")
    if arguments.logical_now < 0:
        fail("logical time must be nonnegative")

    envelope_size = arguments.envelope.stat().st_size
    if envelope_size < 1 or envelope_size > config.provider.action_envelope_max_bytes:
        fail("action envelope exceeds configured byte limit")
    envelope = json.loads(
        arguments.envelope.read_text(encoding="utf-8"),
        object_pairs_hook=strict_object,
        parse_constant=lambda _value: fail("non-finite JSON number"),
    )
    guard = ActionEnvelopeGuard(
        maximum_actions=config.provider.action_envelope_max_actions,
        maximum_bytes=config.provider.action_envelope_max_bytes,
        registry_limit=config.provider.idempotency_registry_limit,
    )
    decision = guard.evaluate(envelope)

    if envelope["deployment_id"] != config.deployment_id:
        fail("action envelope deployment does not match configuration")
    if envelope["partition"] not in config.controller.partitions:
        fail("action envelope partition is not configured")
    if envelope["config_digest"] != config.config_digest:
        fail("action envelope configuration digest mismatch")
    if envelope["image_digest"] != config.image_digest:
        fail("action envelope image digest mismatch")

    actions = list(decision.actions)
    if arguments.action_index == "all":
        selected = actions
    else:
        try:
            index = int(arguments.action_index, 10)
        except ValueError as error:
            raise ValueError("action index must be all or a nonnegative integer") from error
        if index < 0 or index >= len(actions):
            fail("action index is outside the validated envelope")
        selected = [actions[index]]

    # Phase 1: validate every selected action before invoking any subprocess.
    # A failure here is an atomic rejection with zero provider mutation.
    for action in selected:
        tier = Tier(action["tier"])
        tier_config = config.tiers[tier]
        placement = Placement(**action["placement"])
        if not tier_config.enabled or placement not in tier_config.placements:
            fail("action placement or tier is not enabled by configuration")
        if (
            action["capacity_viewers"] != tier_config.capacity_viewers_per_node
            or action["capacity_egress_mbps"] != tier_config.capacity_egress_mbps_per_node
        ):
            fail("action capacity does not match configured tier capacity")
        if action["deadline_at"] < arguments.logical_now:
            fail("action logical deadline expired")

    # Phase 2: apply only after the complete semantic preflight passed.
    adapter_results: list[dict[str, Any]] = []
    for action in selected:
        request_id = f"e-{arguments.label}-{action['idempotency_key'][7:23]}"
        if len(request_id) > 63:
            fail("derived provider request ID exceeds adapter bound")
        command = [
            str(arguments.adapter),
            "--contract-version", "1",
            "--mode", arguments.mode,
            "--operation", action["operation"],
            "--request-id", request_id,
            "--run-id", arguments.run_id,
            "--node", action["node_id"],
            "--state-dir", str(arguments.state_dir),
            "--topology", str(arguments.topology),
            "--capacity", str(action["capacity_viewers"]),
            "--capacity-egress", str(action["capacity_egress_mbps"]),
            "--node-generation", str(action["generation"]),
            "--partition-generation", str(envelope["generation"]),
            "--partition", envelope["partition"],
            "--config-digest", envelope["config_digest"],
            "--image-digest", envelope["image_digest"],
            "--idempotency-key", action["idempotency_key"],
            "--registry-limit", str(config.provider.idempotency_registry_limit),
            "--tier", action["tier"],
            "--provider", action["placement"]["provider"],
            "--region", action["placement"]["region"],
            "--zone", action["placement"]["zone"],
            "--reason", action["reason"],
            "--requires-drained", str(action["requires_drained"]).lower(),
        ]
        if "replaces_node_id" in action:
            command.extend(("--replaces-node", action["replaces_node_id"]))
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )
        if completed.returncode != 0:
            rejection_reason = "provider_action_rejected"
            if "destroy requires drain acknowledgement" in completed.stderr:
                rejection_reason = "destroy_requires_drain_ack"
            rejection = {
                "schema_version": 1,
                "event": "action_envelope_apply_rejected",
                "label": arguments.label,
                "status": "apply_rejected",
                "reason": rejection_reason,
                "failed_node_id": action["node_id"],
                "cleanup_required": bool(adapter_results),
            }
            if adapter_results:
                rejection["event"] = "action_envelope_partial_apply"
                rejection["status"] = "partial_apply"
                rejection["applied"] = adapter_results
                print(json.dumps(rejection, sort_keys=True, separators=(",", ":")), file=sys.stderr)
                return 3
            print(json.dumps(rejection, sort_keys=True, separators=(",", ":")), file=sys.stderr)
            return 2
        result = json.loads(completed.stdout, object_pairs_hook=strict_object)
        if result.get("schema_version") != 1 or result.get("node_id") != action["node_id"]:
            fail("local provider adapter returned an invalid result")
        adapter_results.append(result)

    effective_status = decision.status
    if adapter_results and all(item.get("reason") == "idempotent_replay" for item in adapter_results):
        effective_status = "idempotent_replay"
    config_sha = hashlib.sha256(arguments.config.read_bytes()).hexdigest()
    envelope_sha = hashlib.sha256(arguments.envelope.read_bytes()).hexdigest()
    print(
        json.dumps(
            {
                "schema_version": 1,
                "event": "action_envelope_consumed",
                "label": arguments.label,
                "status": effective_status,
                "mode": arguments.mode,
                "viewers": arguments.viewers,
                "logical_now": arguments.logical_now,
                "config_digest": config.config_digest,
                "config_file_sha256": config_sha,
                "image_digest": config.image_digest,
                "envelope_sha256": envelope_sha,
                "actions": adapter_results,
            },
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        print(f"action-envelope-consumer: {error}", file=sys.stderr)
        raise SystemExit(2) from None
