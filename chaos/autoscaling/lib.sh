#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0

autoscaling_die() {
    printf 'autoscaling chaos: %s\n' "$*" >&2
    exit 2
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || autoscaling_die "missing required command: $1"
}

require_uint_between() {
    local name="$1" value="$2" minimum="$3" maximum="$4"
    [[ "${value}" =~ ^[0-9]+$ ]] || autoscaling_die "${name} must be an unsigned integer"
    (( value >= minimum && value <= maximum )) || \
        autoscaling_die "${name} must be between ${minimum} and ${maximum}"
}

monotonic_ms() {
    awk '{printf "%.0f\n", $1 * 1000}' /proc/uptime
}

load_autoscaling_profile() {
    local path="$1"
    [[ -f "${path}" ]] || autoscaling_die "profile does not exist: ${path}"
    # Repository-owned constant assignments, never external input.
    # shellcheck disable=SC1090
    source "${path}"
    [[ "${PROFILE_NAME:-}" =~ ^(10|25|50|100)$ ]] || autoscaling_die 'invalid profile name'
    require_uint_between PROFILE_VIEWERS "${PROFILE_VIEWERS:-}" 1 100
    (( PROFILE_VIEWERS == PROFILE_NAME )) || autoscaling_die 'profile viewers do not match name'
    require_uint_between PROFILE_SEED "${PROFILE_SEED:-}" 0 4294967295
    require_uint_between PROFILE_TIMEOUT_SECONDS "${PROFILE_TIMEOUT_SECONDS:-}" 30 300
    require_uint_between PROFILE_CONTROL_REPLICAS "${PROFILE_CONTROL_REPLICAS:-}" 1 64
}

adapter_call() {
    local operation="$1" node="$2"
    shift 2
    request_sequence=$(( request_sequence + 1 ))
    local request_id="r${request_sequence}-${operation}-${node}"
    local output
    output="$(${PROVIDER_ADAPTER} \
        --contract-version 1 \
        --mode "${mode}" \
        --operation "${operation}" \
        --request-id "${request_id}" \
        --run-id "${run_id}" \
        --node "${node}" \
        --state-dir "${state_dir}" \
        --topology "${TOPOLOGY}" \
        "$@")"
    [[ ${output} == '{"schema_version":1,'* ]] || \
        autoscaling_die "adapter returned an invalid response for ${operation}/${node}"
    printf '%s\n' "${output}" >>"${events_path}"
    last_adapter_output="${output}"
}

emit_event() {
    local event="$1" severity="$2" reason="$3"
    shift 3
    local extra="${1:-}"
    printf '{"schema_version":1,"event":"%s","severity":"%s","reason":"%s","run_id":"%s","profile":"%s"%s}\n' \
        "${event}" "${severity}" "${reason}" "${run_id}" "${PROFILE_NAME}" "${extra}" \
        >>"${events_path}"
}

compose_command() {
    docker compose \
        --project-name "${compose_project}" \
        --project-directory "${VIRTUAL_NODE_ROOT}" \
        -f "${COMPOSE_FILE}" "$@"
}

wait_compose_healthy() {
    local deadline=$(( SECONDS + 20 ))
    local ids id health all_healthy
    while (( SECONDS < deadline )); do
        mapfile -t ids < <(compose_command ps -q)
        # The milestone Compose intentionally has exactly one control identity.
        expected_containers=4
        if (( ${#ids[@]} == expected_containers )); then
            all_healthy=1
            for id in "${ids[@]}"; do
                health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${id}" 2>/dev/null || printf missing)"
                [[ "${health}" == healthy ]] || all_healthy=0
            done
            (( all_healthy == 1 )) && return 0
        fi
        sleep 1
    done
    return 1
}

assert_no_published_ports() {
    local id bindings
    while IFS= read -r id; do
        [[ -n "${id}" ]] || continue
        bindings="$(docker inspect --format '{{json .HostConfig.PortBindings}}' "${id}")"
        [[ "${bindings}" == null || "${bindings}" == '{}' ]] || \
            autoscaling_die "container ${id} unexpectedly publishes host ports"
    done < <(compose_command ps -q)
}

sample_compose_resources() {
    local ids
    mapfile -t ids < <(compose_command ps -q)
    if (( ${#ids[@]} == 0 )); then
        printf 'unavailable\n' >"${resources_path}"
        return
    fi
    docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.PIDs}}' \
        "${ids[@]}" >"${resources_path}" 2>/dev/null || printf 'unavailable\n' >"${resources_path}"
}

cleanup_compose() {
    local cleanup_status=0
    if (( compose_started == 1 )); then
        compose_command down --volumes --remove-orphans --timeout 5 >/dev/null 2>&1 || cleanup_status=1
        compose_started=0
    fi

    local ids id
    mapfile -t ids < <(docker ps -aq --filter "label=teremoq.run-id=${run_id}" 2>/dev/null || true)
    for id in "${ids[@]}"; do
        docker rm -f "${id}" >/dev/null 2>&1 || cleanup_status=1
    done
    mapfile -t ids < <(docker network ls -q --filter "label=teremoq.run-id=${run_id}" 2>/dev/null || true)
    for id in "${ids[@]}"; do
        docker network rm "${id}" >/dev/null 2>&1 || cleanup_status=1
    done
    mapfile -t ids < <(docker volume ls -q --filter "label=teremoq.run-id=${run_id}" 2>/dev/null || true)
    for id in "${ids[@]}"; do
        docker volume rm "${id}" >/dev/null 2>&1 || cleanup_status=1
    done

    containers_after="$(docker ps -aq --filter "label=teremoq.run-id=${run_id}" 2>/dev/null | wc -l)"
    networks_after="$(docker network ls -q --filter "label=teremoq.run-id=${run_id}" 2>/dev/null | wc -l)"
    volumes_after="$(docker volume ls -q --filter "label=teremoq.run-id=${run_id}" 2>/dev/null | wc -l)"
    if (( containers_after == 0 && networks_after == 0 && volumes_after == 0 && cleanup_status == 0 )); then
        cleanup_ok=true
        return 0
    fi
    cleanup_ok=false
    return 1
}

render_autoscaling_report() {
    local report_path="$1" exit_code="$2"
    local result=fail
    (( exit_code == 0 )) && result=pass
    {
        printf '# Task 10 local autoscaling simulation report\n\n'
        printf -- '- Schema version: 1\n'
        printf -- '- Result: `%s`\n' "${result}"
        printf -- '- Run ID: `%s`\n' "${run_id}"
        printf -- '- Started UTC: `%s`; finished UTC: `%s`\n' "${started_utc}" "${finished_utc}"
        printf -- '- Workspace commit: `%s`\n' "${workspace_revision}"
        printf -- '- Mode: `%s`; Compose: `%s`\n' "${mode}" "${with_compose}"
        printf -- '- Profile/seed: `%s` / `%s`\n' "${PROFILE_NAME}" "${PROFILE_SEED}"
        printf -- '- Requested and consumed simulated viewers: `%s` / `%s`\n' "${PROFILE_VIEWERS}" "${viewers_consumed}"
        printf -- '- Control replicas requested/observed: `%s` / `%s`\n' "${control_replicas}" "${control_replicas_observed}"
        printf -- '- Image: `%s`\n' "${VIRTUAL_NODE_IMAGE}"
        printf -- '- Artifact SHA-256: `%s`\n' "${node_runtime_sha}"
        printf -- '- Kernel/Docker: `%s` / `%s`\n' "$(uname -srmo)" "${docker_version}"
        printf -- '- Host logical CPU / available memory KiB: `%s` / `%s`\n' "$(nproc)" "$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
        printf '\n## Simulated placement and continuity\n\n'
        printf '| Metric | Value |\n| --- | ---: |\n'
        printf '| Initial distributor-a sessions | %s |\n' "${initial_a}"
        printf '| Initial distributor-b sessions | %s |\n' "${initial_b}"
        printf '| Capacity configuration changes | %s |\n' "${capacity_configuration_changes}"
        printf '| Task 09 create actions consumed | %s |\n' "${task09_create_actions_consumed}"
        printf '| Harness-injected replacement creates | %s |\n' "${injected_replacement_creates}"
        printf '| Sessions after replacement | %s |\n' "${sessions_after_replacement}"
        printf '| Sessions after drain | %s |\n' "${sessions_after_drain}"
        printf '| Simulated lost sessions | %s |\n' "${simulated_lost_sessions}"
        printf '| Replacement time ms (single sample) | %s |\n' "${replacement_ms}"
        printf '| Reassignment time ms (single sample) | %s |\n' "${reassignment_ms}"
        printf '| Drain time ms (single sample) | %s |\n' "${drain_ms}"
        printf '| Rollback time ms (single sample) | %s |\n' "${rollback_ms}"
        printf '| Alerts emitted | %s |\n' "${alerts_emitted}"
        printf '\n## Disposable resource sample\n\n'
        printf 'The sample is one `docker stats` observation, not a capacity distribution.\n\n```text\n'
        sed -E 's/[[:space:]]+$//' "${resources_path}"
        printf '\n```\n\n'
        printf 'Cleanup: `%s`; containers `%s`; networks `%s`; volumes `%s`.\n\n' \
            "${cleanup_ok}" "${containers_after}" "${networks_after}" "${volumes_after}"
        printf '## Events\n\n```jsonl\n'
        sed -E 's#(/tmp|/home)/[^"[:space:]]+#[REDACTED_PATH]#g' "${events_path}"
        printf '```\n\n'
        printf 'This run models viewer counts, placement and state transitions. It sends no video, opens no viewer transport sessions and does not demonstrate MoQT throughput, latency, media continuity, memory bounds or capacity for real spectators.\n'
    } >"${report_path}"
}
