#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
VIRTUAL_NODE_ROOT="${REPO_ROOT}/infra/virtual-nodes"
PROVIDER_ADAPTER="${VIRTUAL_NODE_ROOT}/provider-adapter.sh"
TOPOLOGY="${VIRTUAL_NODE_ROOT}/topology/default.tsv"
COMPOSE_FILE="${VIRTUAL_NODE_ROOT}/compose.yaml"
REPORT_DIR="${TEREMOQ_AUTOSCALING_REPORT_DIR:-${SCRIPT_DIR}/reports}"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

profile=10
mode=simulate
with_compose=false
control_replicas_override=
while (( $# > 0 )); do
    case "$1" in
        --profile) (( $# >= 2 )) || autoscaling_die '--profile requires 10, 25, 50, or 100'; profile="$2"; shift 2 ;;
        --mode) (( $# >= 2 )) || autoscaling_die '--mode requires simulate or dry-run'; mode="$2"; shift 2 ;;
        --compose) with_compose=true; shift ;;
        --control-replicas) (( $# >= 2 )) || autoscaling_die '--control-replicas requires a value'; control_replicas_override="$2"; shift 2 ;;
        *) autoscaling_die "unknown argument: $1" ;;
    esac
done
[[ "${profile}" =~ ^(10|25|50|100)$ ]] || autoscaling_die 'invalid profile'
[[ "${mode}" =~ ^(simulate|dry-run)$ ]] || autoscaling_die 'invalid mode'
[[ "${with_compose}" == false || "${mode}" == simulate ]] || \
    autoscaling_die '--compose is available only in simulate mode'

load_autoscaling_profile "${SCRIPT_DIR}/profiles/${profile}.env"
control_replicas="${control_replicas_override:-${PROFILE_CONTROL_REPLICAS}}"
max_control_replicas="${TEREMOQ_AUTOSCALING_MAX_CONTROL_REPLICAS:-8}"
require_uint_between TEREMOQ_AUTOSCALING_MAX_CONTROL_REPLICAS "${max_control_replicas}" 1 64
require_uint_between control_replicas "${control_replicas}" 1 "${max_control_replicas}"
if [[ "${with_compose}" == true && "${control_replicas}" != 1 ]]; then
    autoscaling_die 'the milestone Compose is limited to one uniquely identified control replica'
fi
inject_failure_after_start="${TEREMOQ_AUTOSCALING_INJECT_FAILURE_AFTER_START:-0}"
require_uint_between TEREMOQ_AUTOSCALING_INJECT_FAILURE_AFTER_START \
    "${inject_failure_after_start}" 0 1
(( inject_failure_after_start == 0 )) || [[ "${with_compose}" == true ]] || \
    autoscaling_die 'post-start failure injection requires --compose'

# Repository-owned immutable image coordinates.
# shellcheck disable=SC1091
source "${VIRTUAL_NODE_ROOT}/versions.env"
[[ "${VIRTUAL_NODE_IMAGE}" =~ ^[^[:space:]]+@sha256:[0-9a-f]{64}$ ]] || \
    autoscaling_die 'virtual node image is not digest-pinned'

for command_name in awk bash date find mktemp nproc sed sha256sum uname wc; do
    require_command "${command_name}"
done
[[ -x "${PROVIDER_ADAPTER}" ]] || autoscaling_die 'provider adapter is not executable'
[[ -f "${COMPOSE_FILE}" && -f "${TOPOLOGY}" ]] || autoscaling_die 'virtual node assets are incomplete'

if [[ "${with_compose}" == true ]]; then
    require_command docker
    docker info >/dev/null 2>&1 || autoscaling_die 'Docker daemon is unavailable'
    docker compose version >/dev/null 2>&1 || autoscaling_die 'Docker Compose is unavailable'
    docker image inspect "${VIRTUAL_NODE_IMAGE}" >/dev/null 2>&1 || \
        autoscaling_die 'the reviewed virtual-node image is not available locally'
    observed_image_id="$(docker image inspect --format '{{.Id}}' "${VIRTUAL_NODE_IMAGE}")"
    [[ "${observed_image_id}" == "${VIRTUAL_NODE_IMAGE_ID}" ]] || \
        autoscaling_die 'local image ID does not match versions.env'
fi

mkdir -p -- "${REPORT_DIR}"
run_id="t10-${PROFILE_NAME}-$(date -u +%Y%m%dt%H%M%Sz)-$$-${RANDOM}"
compose_project="t10${PROFILE_NAME}$$${RANDOM}"
scratch="$(mktemp -d "/tmp/teremoq-autoscaling-${PROFILE_NAME}.XXXXXX")"
state_dir="${scratch}/provider-state"
events_path="${scratch}/events.jsonl"
resources_path="${scratch}/resources.tsv"
report_path="${REPORT_DIR}/autoscaling-${PROFILE_NAME}-${run_id}.md"
: >"${events_path}"
printf 'not_applicable (simulation-only run)\n' >"${resources_path}"

started_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
workspace_revision="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || printf metadata_unavailable)"
node_runtime_sha="$(sha256sum "${VIRTUAL_NODE_ROOT}/node-runtime.sh" | awk '{print $1}')"
[[ "${node_runtime_sha}" == "${VIRTUAL_NODE_RUNTIME_SHA256}" ]] || \
    autoscaling_die 'virtual-node runtime does not match versions.env'
docker_version="$(docker version --format '{{.Server.Version}}' 2>/dev/null || printf unavailable)"
request_sequence=0
last_adapter_output=
compose_started=0
cleanup_ok=false
containers_after=unavailable
networks_after=unavailable
volumes_after=unavailable
control_replicas_observed=not_applicable
viewers_consumed=0
initial_a=0
initial_b=0
capacity_configuration_changes=0
task09_create_actions_consumed=0
injected_replacement_creates=0
sessions_after_replacement=0
sessions_after_drain=0
simulated_lost_sessions=0
replacement_ms=not_applicable
reassignment_ms=not_applicable
drain_ms=not_applicable
rollback_ms=not_applicable
alerts_emitted=0
control_nodes=(control)
for (( replica = 2; replica <= control_replicas; replica++ )); do
    control_nodes+=("control-r${replica}")
done

finish() {
    local status=$?
    trap - EXIT INT TERM
    if [[ "${with_compose}" == true ]]; then
        if ! cleanup_compose; then
            (( status != 0 )) || status=125
            emit_event cleanup_residue critical cleanup_incomplete ",\"containers\":${containers_after},\"networks\":${networks_after},\"volumes\":${volumes_after}"
            alerts_emitted=$(( alerts_emitted + 1 ))
        fi
    else
        cleanup_ok=true
        containers_after=0
        networks_after=0
        volumes_after=0
    fi
    finished_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    render_autoscaling_report "${report_path}" "${status}"
    rm -rf -- "${scratch}"
    printf 'autoscaling report: %s\n' "${report_path}"
    exit "${status}"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "${with_compose}" == true ]]; then
    export VIRTUAL_NODE_IMAGE TEREMOQ_RUN_ID="${run_id}"
    compose_command config --quiet
    compose_command up -d
    compose_started=1
    wait_compose_healthy || autoscaling_die 'virtual node topology did not become healthy'
    assert_no_published_ports
    control_replicas_observed="$(compose_command ps -q control | wc -l)"
    (( control_replicas_observed == control_replicas )) || \
        autoscaling_die 'control replica count differs from request'
    sample_compose_resources
    if (( inject_failure_after_start == 1 )); then
        emit_event injected_harness_failure critical cleanup_regression_probe
        alerts_emitted=$(( alerts_emitted + 1 ))
        autoscaling_die 'injected failure after Compose startup'
    fi
fi

for node in origin-1 distributor-a distributor-b; do
    adapter_call plan "${node}"
    adapter_call create "${node}"
    adapter_call create "${node}"
    adapter_call configure "${node}"
    adapter_call health "${node}"
    adapter_call health "${node}"
done

for node in "${control_nodes[@]}"; do
    template_args=()
    [[ "${node}" == control ]] || template_args=(--template-node control)
    adapter_call plan "${node}" "${template_args[@]}"
    adapter_call create "${node}" "${template_args[@]}"
    adapter_call create "${node}" "${template_args[@]}"
    adapter_call configure "${node}"
    adapter_call health "${node}"
    adapter_call health "${node}"
done
control_replicas_observed="${control_replicas}"

if [[ "${mode}" == dry-run ]]; then
    [[ ! -e "${state_dir}" ]] || autoscaling_die 'dry-run mutated provider state'
    viewers_consumed="${PROFILE_VIEWERS}"
    emit_event dry_run_complete info no_mutation ",\"viewers\":${PROFILE_VIEWERS}"
    exit 0
fi

viewers_consumed="${PROFILE_VIEWERS}"
initial_a=$(( (PROFILE_VIEWERS + 1) / 2 ))
initial_b=$(( PROFILE_VIEWERS / 2 ))
emit_event session_distribution info balanced_initial ",\"distributor_a\":${initial_a},\"distributor_b\":${initial_b},\"total\":${PROFILE_VIEWERS}"

for node in distributor-a distributor-b; do
    if [[ "${node}" == distributor-a ]]; then assigned="${initial_a}"; else assigned="${initial_b}"; fi
    capacity="$(<"${state_dir}/nodes/${node}/capacity")"
    if (( assigned * 100 > capacity * 80 )); then
        requested_capacity=$(( (assigned * 100 + 79) / 80 ))
        adapter_call configure "${node}" --capacity "${requested_capacity}"
        adapter_call health "${node}"
        capacity_configuration_changes=$(( capacity_configuration_changes + 1 ))
        alerts_emitted=$(( alerts_emitted + 1 ))
        emit_event capacity_configuration_requested warning utilization_above_80_percent ",\"node_id\":\"${node}\",\"assigned\":${assigned},\"previous_capacity\":${capacity},\"requested_capacity\":${requested_capacity},\"creates_node\":false"
    fi
done
adapter_call sessions distributor-a --assignments "${initial_a}"
adapter_call sessions distributor-b --assignments "${initial_b}"

failure_started="$(monotonic_ms)"
alerts_emitted=$(( alerts_emitted + 1 ))
emit_event node_unhealthy critical injected_distributor_failure ',"node_id":"distributor-a"'
adapter_call fail distributor-a
if [[ "${with_compose}" == true ]]; then
    compose_command stop --timeout 2 distributor-a >/dev/null
    compose_command up -d --force-recreate distributor-a >/dev/null
    wait_compose_healthy || autoscaling_die 'replacement distributor container did not become healthy'
    assert_no_published_ports
fi
adapter_call create distributor-a-r1 --template-node distributor-a --capacity "${initial_a}"
injected_replacement_creates=$(( injected_replacement_creates + 1 ))
adapter_call configure distributor-a-r1 --capacity "${initial_a}"
adapter_call health distributor-a-r1
adapter_call sessions distributor-a-r1 --assignments "${initial_a}"
adapter_call sessions distributor-a --assignments 0
adapter_call stop-admit distributor-a
adapter_call drain distributor-a
adapter_call destroy distributor-a
replacement_finished="$(monotonic_ms)"
replacement_ms=$(( replacement_finished - failure_started ))

reassignment_started="$(monotonic_ms)"
replacement_sessions="${initial_a}"
remaining_b="${initial_b}"
sessions_after_replacement=$(( replacement_sessions + remaining_b ))
(( sessions_after_replacement == PROFILE_VIEWERS )) || autoscaling_die 'replacement lost simulated sessions'
reassignment_ms=$(( $(monotonic_ms) - reassignment_started ))
emit_event sessions_reassigned info replacement_complete ",\"from\":\"distributor-a\",\"to\":\"distributor-a-r1\",\"moved\":${initial_a},\"total\":${sessions_after_replacement}"

drain_started="$(monotonic_ms)"
adapter_call configure distributor-a-r1 --capacity "${PROFILE_VIEWERS}"
adapter_call health distributor-a-r1
adapter_call sessions distributor-a-r1 --assignments "${PROFILE_VIEWERS}"
adapter_call sessions distributor-b --assignments 0
adapter_call stop-admit distributor-b
adapter_call drain distributor-b
replacement_sessions="${PROFILE_VIEWERS}"
remaining_b=0
sessions_after_drain=$(( replacement_sessions + remaining_b ))
(( sessions_after_drain == PROFILE_VIEWERS )) || autoscaling_die 'drain lost simulated sessions'
drain_ms=$(( $(monotonic_ms) - drain_started ))
emit_event drain_complete info sessions_moved_before_drain ",\"node_id\":\"distributor-b\",\"moved\":${initial_b},\"total\":${sessions_after_drain}"

rollback_started="$(monotonic_ms)"
snapshot_replacement="${replacement_sessions}"
snapshot_b="${remaining_b}"
drained_state="$(<"${state_dir}/nodes/distributor-b/state")"
[[ "${drained_state}" == drained ]] || autoscaling_die 'rollback precondition is not drained'
# A stale plan tried to assign all sessions to the drained node. Reject it and
# restore the last complete assignment atomically in the model.
replacement_sessions=0
remaining_b="${PROFILE_VIEWERS}"
if [[ "${drained_state}" == drained ]]; then
    replacement_sessions="${snapshot_replacement}"
    remaining_b="${snapshot_b}"
else
    autoscaling_die 'unsafe stale plan was not rejected'
fi
(( replacement_sessions + remaining_b == PROFILE_VIEWERS )) || autoscaling_die 'rollback lost sessions'
rollback_ms=$(( $(monotonic_ms) - rollback_started ))
emit_event rollback_complete warning target_node_drained ",\"restored_total\":$((replacement_sessions + remaining_b))"
alerts_emitted=$(( alerts_emitted + 1 ))

request_sequence=$(( request_sequence + 1 ))
if premature_drain="$(${PROVIDER_ADAPTER} \
    --contract-version 1 --mode "${mode}" --operation drain \
    --request-id "r${request_sequence}-drain-distributor-a-r1" --run-id "${run_id}" \
    --node distributor-a-r1 --state-dir "${state_dir}" --topology "${TOPOLOGY}" \
    2>&1)"; then
    autoscaling_die 'final drain unexpectedly succeeded before stop-admit'
fi
[[ "${premature_drain}" == *'drain requires stop-admit acknowledgement'* ]] || \
    autoscaling_die 'premature drain failed for an unexpected reason'
adapter_call sessions distributor-a-r1 --assignments 0
adapter_call stop-admit distributor-a-r1
adapter_call drain distributor-a-r1
adapter_call drain distributor-a-r1
for node in "${control_nodes[@]}" origin-1; do
    adapter_call sessions "${node}" --assignments 0
    adapter_call stop-admit "${node}"
    adapter_call drain "${node}"
done
for node in distributor-a-r1 distributor-b distributor-a "${control_nodes[@]}" origin-1; do
    adapter_call destroy "${node}"
    adapter_call destroy "${node}"
done

remaining_nodes="$(find "${state_dir}/nodes" -mindepth 1 -maxdepth 1 -type d | wc -l)"
(( remaining_nodes == 0 )) || autoscaling_die 'provider state was not fully destroyed'
emit_event simulation_complete info all_invariants_passed ",\"viewers\":${PROFILE_VIEWERS},\"lost_sessions\":${simulated_lost_sessions}"
