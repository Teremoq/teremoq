#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
umask 077

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${TEST_DIR}/.." && pwd -P)"
REPO_ROOT="$(cd -- "${ROOT}/../.." && pwd -P)"
CONTROL_REPO="${TEREMOQ_CONTROL_REPO:-${REPO_ROOT}}"
CONTROL_ROOT="${CONTROL_REPO}/control-plane"
VERIFY_BINDING="${ROOT}/verify-control-plane-binding.sh"
CONFIG="${CONTROL_ROOT}/config/milestone-100.json"
CONSUMER="${ROOT}/action-envelope-consumer.py"
ADAPTER="${ROOT}/provider-adapter.sh"
TOPOLOGY="${ROOT}/topology/default.tsv"
scratch="$(mktemp -d /tmp/teremoq-envelope-test.XXXXXX)"
trap 'find "${scratch}" -depth -delete' EXIT
state_dir="${scratch}/state"
report_dir="${scratch}/control-report"

fail() {
    printf 'action-envelope-consumer-test: %s\n' "$*" >&2
    exit 1
}

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        fail "unexpected success: $*"
    fi
}

"${VERIFY_BINDING}" --repo "${CONTROL_REPO}"

# Prove that the same verifier rejects a repository whose control-plane tree is
# any value other than the contract binding. This is a real Git-tree mismatch,
# not an override of the expected value.
wrong_repo="${scratch}/wrong-control-repo"
git init -q "${wrong_repo}"
mkdir -p -- "${wrong_repo}/control-plane/config"
printf '{"tampered":true}\n' >"${wrong_repo}/control-plane/config/milestone-100.json"
git -C "${wrong_repo}" add control-plane
git -C "${wrong_repo}" -c user.name='Teremoq test' -c user.email='test@invalid' \
    commit -q -m 'test: wrong control-plane tree'
expect_failure "${VERIFY_BINDING}" --repo "${wrong_repo}"
"${CONTROL_ROOT}/bin/control-plane" --config "${CONFIG}" validate >/dev/null
"${CONTROL_ROOT}/bin/control-plane" --config "${CONFIG}" \
    demo --report-dir "${report_dir}" >/dev/null

consume() {
    local mode="$1" envelope="$2" label="$3" now="$4"
    shift 4
    "${CONSUMER}" --control-plane-root "${CONTROL_ROOT}" --config "${CONFIG}" \
        --envelope "${envelope}" --label "${label}" --viewers 100 \
        --logical-now "${now}" --adapter "${ADAPTER}" --mode "${mode}" \
        --run-id t10-envelope-test --state-dir "${state_dir}" \
        --topology "${TOPOLOGY}" "$@"
}

dry_state="${scratch}/dry-state"
max_label=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
"${CONSUMER}" --control-plane-root "${CONTROL_ROOT}" --config "${CONFIG}" \
    --envelope "${report_dir}/actions-bootstrap.json" --label bootstrap \
    --viewers 100 --logical-now 0 --adapter "${ADAPTER}" --mode dry-run \
    --run-id t10-envelope-dry --state-dir "${dry_state}" \
    --topology "${TOPOLOGY}" >/dev/null
[[ ! -e "${dry_state}" ]] || fail 'dry-run mutated provider state'
max_label_output="$("${CONSUMER}" --control-plane-root "${CONTROL_ROOT}" --config "${CONFIG}" \
    --envelope "${report_dir}/actions-bootstrap.json" --label "${max_label}" \
    --viewers 100 --logical-now 0 --adapter "${ADAPTER}" --mode dry-run \
    --run-id t10-envelope-label --state-dir "${dry_state}" \
    --topology "${TOPOLOGY}")"
python3 -c 'import json,sys; data=json.load(sys.stdin); assert all(len(action["request_id"]) <= 63 for action in data["actions"])' \
    <<<"${max_label_output}" || fail 'maximum valid label produced an oversized request id'
for invalid_label in A-upper aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa invalid_label invalid/label; do
    expect_failure "${CONSUMER}" --control-plane-root "${CONTROL_ROOT}" --config "${CONFIG}" \
        --envelope "${report_dir}/actions-bootstrap.json" --label "${invalid_label}" \
        --viewers 100 --logical-now 0 --adapter "${ADAPTER}" --mode dry-run \
        --run-id t10-envelope-invalid-label --state-dir "${dry_state}" \
        --topology "${TOPOLOGY}"
done
[[ ! -e "${dry_state}" ]] || fail 'label validation mutated provider state'

first="$(consume simulate "${report_dir}/actions-bootstrap.json" bootstrap 0)"
[[ "${first}" == *'"status":"accepted"'* ]] || fail 'bootstrap was not accepted'
replay="$(consume simulate "${report_dir}/actions-bootstrap.json" bootstrap 0)"
[[ "${replay}" == *'"status":"idempotent_replay"'* ]] || fail 'replay was not unchanged'
consume simulate "${report_dir}/actions-scenario-100-2.json" scenario-100-2 50 >/dev/null
[[ "$(find "${state_dir}/nodes" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 3 ]] || \
    fail 'bootstrap plus scenario did not create three nodes'

PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="${CONTROL_ROOT}/src" \
    python3 - "${CONFIG}" "${scratch}" <<'PY'
import json
import sys
from dataclasses import replace
from pathlib import Path

from teremoq_control.config import load_config
from teremoq_control.contracts import serialize_action_envelope
from teremoq_control.model import Action, ActionReason, Placement, Tier

config = load_config(Path(sys.argv[1]))
output = Path(sys.argv[2])
placement = config.tiers[Tier.CORE].placements[0]
base = Action(
    operation="create",
    node_id="milestone-local-core-000099",
    generation=1,
    tier=Tier.CORE,
    placement=placement,
    reason=ActionReason.AUTOSCALE_OUT,
    capacity_viewers=config.tiers[Tier.CORE].capacity_viewers_per_node,
    capacity_egress_mbps=config.tiers[Tier.CORE].capacity_egress_mbps_per_node,
    deadline_at=100,
    requires_drained=False,
)

def write(name, action=base, config_digest=config.config_digest, image_digest=config.image_digest):
    envelope = serialize_action_envelope(
        deployment_id=config.deployment_id,
        partition=config.controller.partitions[0],
        generation=1,
        image_digest=image_digest,
        config_digest=config_digest,
        actions=(action,),
        maximum_actions=config.provider.action_envelope_max_actions,
        maximum_bytes=config.provider.action_envelope_max_bytes,
    )
    (output / name).write_text(json.dumps(envelope, sort_keys=True) + "\n", encoding="utf-8")

write("stale.json")
write("wrong-capacity.json", replace(base, capacity_viewers=61))
write("wrong-placement.json", replace(base, placement=Placement("local-sim-x", "eu-south", "zone-a")))
write("wrong-config.json", config_digest="sha256:" + "0" * 64)
write("wrong-image.json", image_digest="sha256:" + "1" * 64)
write("expired.json", replace(base, deadline_at=1))
write("valid-first.json", base)

def write_pair(name, second):
    envelope = serialize_action_envelope(
        deployment_id=config.deployment_id,
        partition=config.controller.partitions[0],
        generation=3,
        image_digest=config.image_digest,
        config_digest=config.config_digest,
        actions=(replace(base, node_id="milestone-local-core-000097", generation=3), second),
        maximum_actions=config.provider.action_envelope_max_actions,
        maximum_bytes=config.provider.action_envelope_max_bytes,
    )
    (output / name).write_text(json.dumps(envelope, sort_keys=True) + "\n", encoding="utf-8")

write_pair(
    "pair-second-capacity.json",
    replace(base, node_id="milestone-local-core-000098", generation=3, capacity_viewers=61),
)
write_pair(
    "pair-second-expired.json",
    replace(base, node_id="milestone-local-core-000096", generation=3, deadline_at=1),
)

partial_first = replace(base, node_id="milestone-local-core-000095", generation=4)
partial_second = Action(
    operation="destroy",
    node_id="milestone-local-core-000094",
    generation=4,
    tier=Tier.CORE,
    placement=placement,
    reason=ActionReason.SAFE_SHUTDOWN,
    capacity_viewers=config.tiers[Tier.CORE].capacity_viewers_per_node,
    capacity_egress_mbps=config.tiers[Tier.CORE].capacity_egress_mbps_per_node,
    deadline_at=100,
    requires_drained=True,
)
envelope = serialize_action_envelope(
    deployment_id=config.deployment_id,
    partition=config.controller.partitions[0],
    generation=4,
    image_digest=config.image_digest,
    config_digest=config.config_digest,
    actions=(partial_first, partial_second),
    maximum_actions=config.provider.action_envelope_max_actions,
    maximum_bytes=config.provider.action_envelope_max_bytes,
)
(output / "pair-operational-partial.json").write_text(
    json.dumps(envelope, sort_keys=True) + "\n", encoding="utf-8"
)
PY

nodes_before="$(find "${state_dir}/nodes" -mindepth 1 -maxdepth 1 -type d | wc -l)"
keys_before="$(find "${state_dir}/idempotency" -mindepth 1 -maxdepth 1 -type f | wc -l)"
expect_failure consume simulate "${scratch}/stale.json" stale 50
for invalid in wrong-capacity wrong-placement wrong-config wrong-image; do
    expect_failure consume simulate "${scratch}/${invalid}.json" "${invalid}" 0
done
expect_failure consume simulate "${scratch}/expired.json" expired 2
atomic_state="${scratch}/atomic-state"
for pair in pair-second-capacity pair-second-expired; do
    expect_failure "${CONSUMER}" --control-plane-root "${CONTROL_ROOT}" --config "${CONFIG}" \
        --envelope "${scratch}/${pair}.json" --label "${pair}" --viewers 100 \
        --logical-now 2 --adapter "${ADAPTER}" --mode simulate \
        --run-id t10-envelope-atomic --state-dir "${atomic_state}" --topology "${TOPOLOGY}"
    [[ ! -e "${atomic_state}" ]] || fail "${pair} mutated state before complete preflight"
done
partial_state="${scratch}/partial-state"
partial_stderr="${scratch}/partial.stderr"
set +e
"${CONSUMER}" --control-plane-root "${CONTROL_ROOT}" --config "${CONFIG}" \
    --envelope "${scratch}/pair-operational-partial.json" --label partial-apply \
    --viewers 100 --logical-now 2 --adapter "${ADAPTER}" --mode simulate \
    --run-id t10-envelope-partial --state-dir "${partial_state}" --topology "${TOPOLOGY}" \
    >/dev/null 2>"${partial_stderr}"
partial_status=$?
set -e
(( partial_status == 3 )) || fail 'operational partial apply did not use its stable exit code'
grep -Fq '"event":"action_envelope_partial_apply"' "${partial_stderr}" || \
    fail 'operational partial apply event missing'
grep -Fq '"cleanup_required":true' "${partial_stderr}" || \
    fail 'operational partial apply did not require cleanup'
partial_node=milestone-local-core-000095
[[ -d "${partial_state}/nodes/${partial_node}" ]] || \
    fail 'partial apply did not preserve its explicit applied result'
for operation in configure health stop-admit drain destroy; do
    "${ADAPTER}" --contract-version 1 --mode simulate --operation "${operation}" \
        --request-id "partial-cleanup-${operation}" --run-id t10-envelope-partial \
        --node "${partial_node}" --state-dir "${partial_state}" --topology "${TOPOLOGY}" \
        >/dev/null
done
[[ ! -d "${partial_state}/nodes/${partial_node}" ]] || \
    fail 'bounded partial-apply cleanup left the applied node'
expect_failure "${CONSUMER}" --control-plane-root "${CONTROL_ROOT}" --config "${CONFIG}" \
    --envelope "${report_dir}/actions-bootstrap.json" --label gate-101 \
    --viewers 101 --logical-now 0 --adapter "${ADAPTER}" --mode dry-run \
    --run-id t10-gate-101 --state-dir "${scratch}/gate-101" --topology "${TOPOLOGY}"
expect_failure "${CONSUMER}" --control-plane-root "${CONTROL_ROOT}" --config "${CONFIG}" \
    --envelope "${report_dir}/actions-bootstrap.json" --label gate-1000 \
    --viewers 1000 --logical-now 0 --adapter "${ADAPTER}" --mode dry-run \
    --run-id t10-gate-1000 --state-dir "${scratch}/gate-1000" --topology "${TOPOLOGY}"
[[ "$(find "${state_dir}/nodes" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq "${nodes_before}" ]] || \
    fail 'rejected envelope mutated nodes'
[[ "$(find "${state_dir}/idempotency" -mindepth 1 -maxdepth 1 -type f | wc -l)" -eq "${keys_before}" ]] || \
    fail 'rejected envelope mutated idempotency state'
printf 'action-envelope-consumer-test: pass\n'
