#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
NODE_ROOT="${REPO_ROOT}/infra/virtual-nodes"
ADAPTER="${NODE_ROOT}/provider-adapter.sh"
CONSUMER="${NODE_ROOT}/action-envelope-consumer.py"
TOPOLOGY="${NODE_ROOT}/topology/default.tsv"
REPORT_DIR="${TEREMOQ_AUTOSCALING_REPORT_DIR:-${SCRIPT_DIR}/reports}"
CONTROL_REPO="${TEREMOQ_CONTROL_REPO:-${REPO_ROOT}}"
CONTROL_ROOT="${CONTROL_REPO}/control-plane"
CONTROL_TREE=1ffd80a0b2135c86b5d11751aeca49ae791de53d
CONFIG="${CONTROL_ROOT}/config/milestone-100.json"
CONFIG_FILE_SHA=d6eb34768e62a87a39ab9cc4ba25d915198a2dc559c5c7b30930e77e55044506
IMAGE_MAP="${NODE_ROOT}/contract/v1/image-map.tsv"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck disable=SC1091
source "${NODE_ROOT}/versions.env"

mode=simulate
with_docker=false
viewers=100
while (( $# > 0 )); do
    case "$1" in
        --mode) (( $# >= 2 )) || autoscaling_die '--mode requires simulate or dry-run'; mode="$2"; shift 2 ;;
        --docker) with_docker=true; shift ;;
        --viewers) (( $# >= 2 )) || autoscaling_die '--viewers requires a value'; viewers="$2"; shift 2 ;;
        *) autoscaling_die "unknown integrated argument: $1" ;;
    esac
done
[[ "${mode}" =~ ^(simulate|dry-run)$ ]] || autoscaling_die 'invalid integrated mode'
[[ "${with_docker}" == false || "${mode}" == simulate ]] || \
    autoscaling_die '--docker is available only in simulate mode'
require_uint_between viewers "${viewers}" 1 9007199254740991
for command_name in awk date find git grep mktemp nproc python3 sed sha256sum sort uname wc; do
    require_command "${command_name}"
done
[[ -x "${ADAPTER}" && -x "${CONSUMER}" && -x "${CONTROL_ROOT}/bin/control-plane" ]] || \
    autoscaling_die 'integrated executable boundary is incomplete'
[[ "$(git -C "${CONTROL_REPO}" rev-parse HEAD:control-plane 2>/dev/null)" == "${CONTROL_TREE}" ]] || \
    autoscaling_die 'control-plane integration subtree changed'
git -C "${CONTROL_REPO}" diff --quiet -- control-plane || \
    autoscaling_die 'control-plane source has uncommitted divergence'
[[ "$(sha256sum "${CONFIG}" | awk '{print $1}')" == "${CONFIG_FILE_SHA}" ]] || \
    autoscaling_die 'milestone configuration file changed'
[[ "$(sha256sum "${NODE_ROOT}/node-runtime.sh" | awk '{print $1}')" == \
   "${VIRTUAL_NODE_RUNTIME_SHA256}" ]] || autoscaling_die 'virtual-node runtime hash mismatch'
desired_image_identifier="$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="${CONTROL_ROOT}/src" \
    python3 -c 'import sys; from pathlib import Path; from teremoq_control.config import load_config; print(load_config(Path(sys.argv[1])).image_digest)' "${CONFIG}")"
mapping="$(awk -F '\t' -v desired="${desired_image_identifier}" \
    '$0 !~ /^#/ && NF == 3 && $1 == desired {print $2 "\t" $3; found++} END {exit found == 1 ? 0 : 1}' \
    "${IMAGE_MAP}")" || autoscaling_die 'desired image identifier has no unique simulator mapping'
IFS=$'\t' read -r mapped_runtime_oci mapped_runtime_id <<<"${mapping}"
[[ "${mapped_runtime_oci}" == "${VIRTUAL_NODE_IMAGE}" && \
   "${mapped_runtime_id}" == "${VIRTUAL_NODE_IMAGE_ID}" ]] || \
    autoscaling_die 'simulator image mapping does not match versions.env'

inject_failure="${TEREMOQ_INTEGRATED_INJECT_FAILURE_AFTER_BOOTSTRAP:-0}"
require_uint_between TEREMOQ_INTEGRATED_INJECT_FAILURE_AFTER_BOOTSTRAP "${inject_failure}" 0 1
(( inject_failure == 0 )) || [[ "${with_docker}" == true ]] || \
    autoscaling_die 'integrated failure injection requires --docker'

if [[ "${with_docker}" == true ]]; then
    require_command docker
    docker info >/dev/null 2>&1 || autoscaling_die 'Docker daemon is unavailable'
    docker image inspect "${VIRTUAL_NODE_IMAGE}" >/dev/null 2>&1 || \
        autoscaling_die 'pinned local image is unavailable'
    [[ "$(docker image inspect --format '{{.Id}}' "${VIRTUAL_NODE_IMAGE}")" == \
       "${VIRTUAL_NODE_IMAGE_ID}" ]] || autoscaling_die 'local image ID mismatch'
fi

mkdir -p -- "${REPORT_DIR}"
run_id="t10-integrated-$(date -u +%Y%m%dt%H%M%Sz)-$$-${RANDOM}"
docker_prefix="t10i$$${RANDOM}"
control_network="${docker_prefix}-control"
data_network="${docker_prefix}-data"
scratch="$(mktemp -d /tmp/teremoq-integrated-100.XXXXXX)"
state_dir="${scratch}/provider-state"
control_report="${scratch}/control-report"
events_path="${scratch}/events.jsonl"
resources_path="${scratch}/resources.tsv"
report_path="${REPORT_DIR}/integrated-100-${run_id}.md"
: >"${events_path}"
printf 'unavailable\n' >"${resources_path}"
started_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
started_ms="$(monotonic_ms)"
request_sequence=0
docker_started=0
cleanup_ok=false
containers_after=unavailable
networks_after=unavailable
volumes_after=unavailable
provider_nodes_after=unavailable
actions_consumed=0
action_results_observed=0
create_actions_consumed=0
destroy_actions_consumed=0
replays_observed=0
topology_after_control=0
topology_after_bootstrap=0
topology_after_scaleout=0
topology_after_replacement=0
sessions_after_replacement=0
simulated_lost_sessions=0
rollback_rejections=0
replacement_ms=not_applicable
duration_ms=not_applicable
remote_cost=0
config_digest=unavailable
control_image_digest=unavailable

cleanup_integrated() {
    local cleanup_status=0 id
    if [[ "${with_docker}" == true ]]; then
        while IFS= read -r id; do
            [[ -n "${id}" ]] || continue
            docker rm -f "${id}" >/dev/null 2>&1 || cleanup_status=1
        done < <(docker ps -aq --filter "label=teremoq.run-id=${run_id}" 2>/dev/null || true)
        while IFS= read -r id; do
            [[ -n "${id}" ]] || continue
            docker network rm "${id}" >/dev/null 2>&1 || cleanup_status=1
        done < <(docker network ls -q --filter "label=teremoq.run-id=${run_id}" 2>/dev/null || true)
        while IFS= read -r id; do
            [[ -n "${id}" ]] || continue
            docker volume rm "${id}" >/dev/null 2>&1 || cleanup_status=1
        done < <(docker volume ls -q --filter "label=teremoq.run-id=${run_id}" 2>/dev/null || true)
        containers_after="$(docker ps -aq --filter "label=teremoq.run-id=${run_id}" | wc -l)"
        networks_after="$(docker network ls -q --filter "label=teremoq.run-id=${run_id}" | wc -l)"
        volumes_after="$(docker volume ls -q --filter "label=teremoq.run-id=${run_id}" | wc -l)"
    else
        containers_after=0
        networks_after=0
        volumes_after=0
    fi
    provider_nodes_after=0
    if [[ -d "${state_dir}/nodes" ]]; then
        provider_nodes_after="$(find "${state_dir}/nodes" -mindepth 1 -maxdepth 1 -type d | wc -l)"
    fi
    if (( containers_after == 0 && networks_after == 0 && volumes_after == 0 && cleanup_status == 0 )); then
        cleanup_ok=true
    fi
}

render_integrated_report() {
    local exit_code="$1" result=fail consumed_viewers=0
    if (( exit_code == 0 )); then
        result=pass
        consumed_viewers="${viewers}"
    fi
    duration_ms=$(( $(monotonic_ms) - started_ms ))
    {
        printf '# Task 10 integrated local 100-viewer simulation\n\n'
        printf -- '- Schema version: 1\n- Result: `%s`\n' "${result}"
        printf -- '- Run ID: `%s`\n- Started/finished UTC: `%s` / `%s`\n' \
            "${run_id}" "${started_utc}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf -- '- Workspace commit / control-plane subtree tree: `%s` / `%s`\n' \
            "$(git -C "${REPO_ROOT}" rev-parse HEAD)" "${CONTROL_TREE}"
        printf -- '- Mode/Docker: `%s` / `%s`\n' "${mode}" "${with_docker}"
        printf -- '- Requested/consumed simulated viewers: `%s` / `%s`\n' \
            "${viewers}" "${consumed_viewers}"
        printf -- '- Configuration file SHA-256: `%s`\n' "${CONFIG_FILE_SHA}"
        printf -- '- Configuration digest: `%s`\n- Desired image identifier (Task 09 fixture): `%s`\n' \
            "${config_digest}" "${control_image_digest}"
        printf -- '- Mapped simulator runtime OCI: `%s`\n' "${VIRTUAL_NODE_IMAGE}"
        printf -- '- Mapped simulator runtime image ID: `%s`\n- Runtime SHA-256: `%s`\n' \
            "${VIRTUAL_NODE_IMAGE_ID}" "${VIRTUAL_NODE_RUNTIME_SHA256}"
        printf -- '- Duration ms: `%s`; remote cost: `%s`\n' "${duration_ms}" "${remote_cost}"
        printf -- '- Host CPU / available memory KiB: `%s` / `%s`\n' \
            "$(nproc)" "$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
        printf '\n## Consumed control actions\n\n'
        printf '| Metric | Value |\n| --- | ---: |\n'
        printf '| Envelope action results observed | %s |\n| Unique/planned actions consumed | %s |\n' \
            "${action_results_observed}" "${actions_consumed}"
        printf '| Create actions consumed | %s |\n| Destroy actions consumed | %s |\n' \
            "${create_actions_consumed}" "${destroy_actions_consumed}"
        printf '| Idempotent replays | %s |\n| Rollback/lifecycle rejections | %s |\n' \
            "${replays_observed}" "${rollback_rejections}"
        printf '| Containers after control/bootstrap/scale-out/replacement | %s/%s/%s/%s |\n' \
            "${topology_after_control}" "${topology_after_bootstrap}" \
            "${topology_after_scaleout}" "${topology_after_replacement}"
        printf '| Sessions after replacement | %s |\n| Simulated lost sessions | %s |\n' \
            "${sessions_after_replacement}" "${simulated_lost_sessions}"
        printf '| Replacement time ms (single sample) | %s |\n' "${replacement_ms}"
        printf '\n## Resource sample\n\n```text\n'
        sed -E 's/[[:space:]]+$//' "${resources_path}"
        printf '\n```\n\nCleanup: `%s`; containers `%s`; networks `%s`; volumes `%s`; provider nodes before ephemeral-root removal `%s`.\n\n' \
            "${cleanup_ok}" "${containers_after}" "${networks_after}" "${volumes_after}" "${provider_nodes_after}"
        printf '## Events\n\n```jsonl\n'
        sed -E 's#(/tmp|/home)/[^"[:space:]]+#[REDACTED_PATH]#g' "${events_path}"
        printf '```\n\n'
        if [[ "${with_docker}" == true ]]; then
            printf 'This run created real local containers but used only simulated assignment counts. '
        else
            printf 'This run used only local provider state and simulated assignment counts; it created no containers. '
        fi
        printf 'It carried no video, opened no MoQT viewer sessions, performed no authentication/registration and proves neither media recovery nor productive capacity. The Task 09 image value is a fixture identifier mapped only for this lab; production requires a real inventoried OCI digest in desired state.\n'
    } >"${report_path}"
}

finish() {
    local status=$?
    trap - EXIT INT TERM
    cleanup_integrated
    if [[ "${cleanup_ok}" != true && "${status}" -eq 0 ]]; then status=125; fi
    render_integrated_report "${status}"
    find "${scratch}" -depth -delete
    printf 'integrated autoscaling report: %s\n' "${report_path}"
    exit "${status}"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

container_for_node() {
    docker ps -aq --filter "label=teremoq.run-id=${run_id}" \
        --filter "label=teremoq.node-id=$1"
}

wait_healthy() {
    local id="$1" deadline=$(( SECONDS + 20 )) health
    while (( SECONDS < deadline )); do
        health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${id}" 2>/dev/null || printf missing)"
        [[ "${health}" == healthy ]] && return 0
        sleep 1
    done
    return 1
}

create_local_container() {
    local node="$1" role="$2" tier="$3" provider="$4" region="$5" id
    [[ -z "$(container_for_node "${node}")" ]] || autoscaling_die "duplicate local container for ${node}"
    id="$(docker run -d \
        --name "${docker_prefix}-${node}" \
        --network "${control_network}" \
        --user 65532:65532 --read-only \
        --tmpfs /tmp:rw,noexec,nosuid,size=8m,uid=65532,gid=65532 \
        --cap-drop ALL --security-opt no-new-privileges:true \
        --pids-limit 32 --memory 64m --cpus 0.25 --restart no --stop-timeout 5 \
        --health-cmd 'test -s /tmp/teremoq-virtual-node.ready' \
        --health-interval 1s --health-timeout 1s --health-retries 10 --health-start-period 1s \
        --label teremoq.owner=TP-PLATFORM-CHAOS --label teremoq.task=10 \
        --label "teremoq.run-id=${run_id}" --label teremoq.simulation=true \
        --label "teremoq.node-id=${node}" --label "teremoq.node-role=${role}" \
        --label "teremoq.node-tier=${tier}" \
        --env "TEREMOQ_RUN_ID=${run_id}" --env "NODE_ID=${node}" --env "NODE_ROLE=${role}" \
        --env "NODE_TIER=${tier}" --env "NODE_PROVIDER=${provider}" --env "NODE_REGION=${region}" \
        --volume "${NODE_ROOT}/node-runtime.sh:/opt/teremoq/node-runtime.sh:ro" \
        "${VIRTUAL_NODE_IMAGE}" /bin/bash /opt/teremoq/node-runtime.sh)"
    [[ "${role}" == control ]] || docker network connect "${data_network}" "${id}"
    wait_healthy "${id}" || autoscaling_die "local container did not become healthy: ${node}"
}

provider_call() {
    local operation="$1" node="$2"
    shift 2
    request_sequence=$(( request_sequence + 1 ))
    "${ADAPTER}" --contract-version 1 --mode simulate --operation "${operation}" \
        --request-id "i${request_sequence}-${operation}" --run-id "${run_id}" \
        --node "${node}" --state-dir "${state_dir}" --topology "${TOPOLOGY}" "$@" \
        >>"${events_path}"
}

reconcile_containers() {
    local node_dir node id= role tier provider region state
    while IFS= read -r node_dir; do
        node="$(basename "${node_dir}")"
        if [[ "${with_docker}" == true ]]; then
            id="$(container_for_node "${node}")"
        fi
        if [[ "${with_docker}" == true && -z "${id}" ]]; then
            role="$(<"${node_dir}/role")"; tier="$(<"${node_dir}/tier")"
            provider="$(<"${node_dir}/provider")"; region="$(<"${node_dir}/region")"
            create_local_container "${node}" "${role}" "${tier}" "${provider}" "${region}"
        fi
        state="$(<"${node_dir}/state")"
        if [[ "${state}" == created ]]; then
            provider_call configure "${node}"
            provider_call health "${node}"
        fi
    done < <(find "${state_dir}/nodes" -mindepth 1 -maxdepth 1 -type d | sort)
    [[ "${with_docker}" == true ]] || return 0
    while IFS= read -r id; do
        [[ -n "${id}" ]] || continue
        node="$(docker inspect --format '{{index .Config.Labels "teremoq.node-id"}}' "${id}")"
        [[ "${node}" == control || -d "${state_dir}/nodes/${node}" ]] || docker rm -f "${id}" >/dev/null
    done < <(docker ps -aq --filter "label=teremoq.run-id=${run_id}")
}

consume_envelope() {
    local label="$1" file="$2" now="$3" index="${4:-all}" output counts consumer_status
    set +e
    output="$("${CONSUMER}" --control-plane-root "${CONTROL_ROOT}" --config "${CONFIG}" \
        --envelope "${file}" --label "${label}" --action-index "${index}" \
        --viewers "${viewers}" --logical-now "${now}" --adapter "${ADAPTER}" \
        --mode "${mode}" --run-id "${run_id}" --state-dir "${state_dir}" --topology "${TOPOLOGY}")"
    consumer_status=$?
    set -e
    (( consumer_status == 0 )) || return "${consumer_status}"
    printf '%s\n' "${output}" >>"${events_path}"
    counts="$(python3 -c 'import json,sys; x=json.load(sys.stdin); a=x["actions"]; applied=[v for v in a if v["result"]!="unchanged"]; print(len(a),len(applied),sum(v["operation"]=="create" for v in applied),sum(v["operation"]=="destroy" for v in applied),x["status"],x["config_digest"],x["image_digest"])' <<<"${output}")"
    read -r observed count creates destroys status config_digest control_image_digest <<<"${counts}"
    action_results_observed=$(( action_results_observed + observed ))
    actions_consumed=$(( actions_consumed + count ))
    create_actions_consumed=$(( create_actions_consumed + creates ))
    destroy_actions_consumed=$(( destroy_actions_consumed + destroys ))
    [[ "${status}" != idempotent_replay ]] || replays_observed=$(( replays_observed + 1 ))
}

sample_resources() {
    local id name stats pid rss
    : >"${resources_path}"
    while IFS= read -r id; do
        [[ -n "${id}" ]] || continue
        name="$(docker inspect --format '{{.Name}}' "${id}" | sed 's#^/##')"
        stats="$(docker stats --no-stream --format '{{.CPUPerc}}\t{{.MemUsage}}\t{{.PIDs}}' "${id}" 2>/dev/null || printf 'unavailable\tunavailable\tunavailable')"
        pid="$(docker inspect --format '{{.State.Pid}}' "${id}")"
        rss=unavailable
        [[ ! -r "/proc/${pid}/status" ]] || rss="$(awk '/VmRSS:/ {print $2}' "/proc/${pid}/status")"
        printf '%s\t%s\tRSS_KiB=%s\n' "${name}" "${stats}" "${rss}" >>"${resources_path}"
    done < <(docker ps -q --filter "label=teremoq.run-id=${run_id}" | sort)
}

"${CONTROL_ROOT}/bin/control-plane" --config "${CONFIG}" validate >/dev/null
"${CONTROL_ROOT}/bin/control-plane" --config "${CONFIG}" demo --report-dir "${control_report}" >/dev/null

if [[ "${mode}" == dry-run ]]; then
    consume_envelope bootstrap "${control_report}/actions-bootstrap.json" 0
    consume_envelope scenario-100-2 "${control_report}/actions-scenario-100-2.json" 50
    consume_envelope replacement-create "${control_report}/actions-replacement.json" 51 0
    consume_envelope replacement-destroy "${control_report}/actions-replacement.json" 51 1
    consume_envelope cleanup "${control_report}/actions-cleanup.json" 54
    [[ ! -e "${state_dir}" ]] || autoscaling_die 'integrated dry-run mutated provider state'
    provider_nodes_after=0
    exit 0
fi

if [[ "${with_docker}" == true ]]; then
    docker network create --internal --label teremoq.owner=TP-PLATFORM-CHAOS \
        --label teremoq.task=10 --label "teremoq.run-id=${run_id}" "${control_network}" >/dev/null
    docker network create --internal --label teremoq.owner=TP-PLATFORM-CHAOS \
        --label teremoq.task=10 --label "teremoq.run-id=${run_id}" "${data_network}" >/dev/null
    docker_started=1
    create_local_container control control control local-control eu-south
    topology_after_control="$(docker ps -q --filter "label=teremoq.run-id=${run_id}" | wc -l)"
fi

consume_envelope bootstrap "${control_report}/actions-bootstrap.json" 0
reconcile_containers
if [[ "${with_docker}" == true ]]; then
    topology_after_bootstrap="$(docker ps -q --filter "label=teremoq.run-id=${run_id}" | wc -l)"
else
    topology_after_bootstrap=2
fi
consume_envelope bootstrap "${control_report}/actions-bootstrap.json" 0

if (( inject_failure == 1 )); then
    printf '{"schema_version":1,"event":"injected_integrated_failure","run_id":"%s"}\n' "${run_id}" >>"${events_path}"
    autoscaling_die 'injected failure after integrated bootstrap'
fi

consume_envelope scenario-100-2 "${control_report}/actions-scenario-100-2.json" 50
reconcile_containers
if [[ "${with_docker}" == true ]]; then
    topology_after_scaleout="$(docker ps -q --filter "label=teremoq.run-id=${run_id}" | wc -l)"
else
    topology_after_scaleout=3
fi

mapfile -t core_nodes < <(find "${state_dir}/nodes" -mindepth 1 -maxdepth 1 -type d | while read -r path; do [[ "$(<"${path}/tier")" == core ]] && basename "${path}"; done | sort)
(( ${#core_nodes[@]} == 2 )) || autoscaling_die 'scenario did not create exactly two core nodes'
provider_call sessions "${core_nodes[0]}" --assignments 60
provider_call sessions "${core_nodes[1]}" --assignments 40

replacement_started="$(monotonic_ms)"
old_node="${core_nodes[0]}"
provider_call fail "${old_node}"
if [[ "${with_docker}" == true ]]; then
    old_container="$(container_for_node "${old_node}")"
    docker stop --time 2 "${old_container}" >/dev/null
fi
consume_envelope replacement-create "${control_report}/actions-replacement.json" 51 0
reconcile_containers
replacement_node=milestone-local-core-000004

early_rejection="${scratch}/early-destroy.stderr"
if consume_envelope replacement-destroy-early "${control_report}/actions-replacement.json" 51 1 \
    >/dev/null 2>"${early_rejection}"; then
    autoscaling_die 'destroy succeeded before drain acknowledgement'
fi
grep -Fq '"reason":"destroy_requires_drain_ack"' "${early_rejection}" || \
    autoscaling_die 'early destroy failed for a reason other than lifecycle fencing'
cat "${early_rejection}" >>"${events_path}"
rollback_rejections=$(( rollback_rejections + 1 ))
[[ -d "${state_dir}/nodes/${old_node}" ]] || autoscaling_die 'early destroy mutated old node'
provider_call sessions "${replacement_node}" --assignments 60
provider_call sessions "${old_node}" --assignments 0
provider_call stop-admit "${old_node}"
provider_call drain "${old_node}"
consume_envelope replacement-destroy "${control_report}/actions-replacement.json" 51 1
reconcile_containers
sessions_after_replacement=$(( $(<"${state_dir}/nodes/${replacement_node}/assignments") + $(<"${state_dir}/nodes/${core_nodes[1]}/assignments") ))
(( sessions_after_replacement == viewers )) || autoscaling_die 'replacement lost simulated assignments'
replacement_ms=$(( $(monotonic_ms) - replacement_started ))
if [[ "${with_docker}" == true ]]; then
    topology_after_replacement="$(docker ps -q --filter "label=teremoq.run-id=${run_id}" | wc -l)"
else
    topology_after_replacement=3
fi

if [[ "${with_docker}" == true ]]; then
    sample_resources
    while IFS= read -r id; do
        bindings="$(docker inspect --format '{{json .HostConfig.PortBindings}}' "${id}")"
        [[ "${bindings}" == null || "${bindings}" == '{}' ]] || autoscaling_die 'integrated container published a port'
    done < <(docker ps -q --filter "label=teremoq.run-id=${run_id}")
fi

while IFS= read -r node_dir; do
    node="$(basename "${node_dir}")"
    provider_call sessions "${node}" --assignments 0
    provider_call stop-admit "${node}"
    provider_call drain "${node}"
done < <(find "${state_dir}/nodes" -mindepth 1 -maxdepth 1 -type d | sort)
consume_envelope cleanup "${control_report}/actions-cleanup.json" 54
reconcile_containers
provider_nodes_after="$(find "${state_dir}/nodes" -mindepth 1 -maxdepth 1 -type d | wc -l)"
(( provider_nodes_after == 0 )) || autoscaling_die 'cleanup envelope left provider nodes'
(( simulated_lost_sessions == 0 )) || autoscaling_die 'integrated model lost sessions'
