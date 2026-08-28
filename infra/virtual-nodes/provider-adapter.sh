#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DEFAULT_TOPOLOGY="${SCRIPT_DIR}/topology/default.tsv"

die() {
    printf 'virtual-node provider: %s\n' "$*" >&2
    exit 2
}

monotonic_ms() {
    awk '{printf "%.0f\n", $1 * 1000}' /proc/uptime
}

valid_token() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9.-]{0,62}$ ]]
}

valid_node_id() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]
}

require_uint() {
    [[ "$2" =~ ^[0-9]+$ ]] || die "$1 must be an unsigned integer"
}

atomic_write() {
    local path="$1"
    local value="$2"
    local temporary
    temporary="$(mktemp "${path}.tmp.XXXXXX")"
    printf '%s\n' "${value}" >"${temporary}"
    mv -f -- "${temporary}" "${path}"
}

read_value() {
    local path="$1"
    [[ -f "${path}" ]] || return 1
    local value
    IFS= read -r value <"${path}" || return 1
    printf '%s\n' "${value}"
}

lookup_topology() {
    local lookup_id="$1"
    awk -F '\t' -v id="${lookup_id}" '
        $0 !~ /^#/ && NF == 6 && $1 == id {print; found=1}
        END {exit found ? 0 : 1}
    ' "${topology}"
}

emit() {
    local result="$1"
    local state="$2"
    local reason="$3"
    local finished duration
    finished="$(monotonic_ms)"
    duration=$(( finished - started_ms ))
    if [[ "${mode}" == simulate && -n "${idempotency_key}" && ! -f "${keys_dir}/${idempotency_hex}" ]]; then
        mkdir -p -- "${contracts_dir}" "${keys_dir}"
        atomic_write "${keys_dir}/${idempotency_hex}" "${partition}:${partition_generation}"
        atomic_write "${contracts_dir}/config_digest" "${config_digest}"
        atomic_write "${contracts_dir}/image_digest" "${image_digest}"
        atomic_write "${contracts_dir}/generation-${partition}" "${partition_generation}"
    fi
    printf '{"schema_version":1,"contract":"teremoq.virtual-node.provider","mode":"%s","operation":"%s","request_id":"%s","run_id":"%s","node_id":"%s","result":"%s","state":"%s","reason":"%s","duration_ms":%s}\n' \
        "${mode}" "${operation}" "${request_id}" "${run_id}" "${node}" \
        "${result}" "${state}" "${reason}" "${duration}"
}

mode=simulate
operation=
contract_version=1
request_id=
run_id=
node=
template_node=
state_dir=
topology="${DEFAULT_TOPOLOGY}"
capacity=
capacity_egress=
assignments=
node_generation=1
partition_generation=
partition=
config_digest=
image_digest=
idempotency_key=
registry_limit=4096
tier_override=
provider_override=
region_override=
zone_override=
reason=
requires_drained=
replaces_node=

while (( $# > 0 )); do
    case "$1" in
        --mode) (( $# >= 2 )) || die '--mode requires a value'; mode="$2"; shift 2 ;;
        --operation) (( $# >= 2 )) || die '--operation requires a value'; operation="$2"; shift 2 ;;
        --contract-version) (( $# >= 2 )) || die '--contract-version requires a value'; contract_version="$2"; shift 2 ;;
        --request-id) (( $# >= 2 )) || die '--request-id requires a value'; request_id="$2"; shift 2 ;;
        --run-id) (( $# >= 2 )) || die '--run-id requires a value'; run_id="$2"; shift 2 ;;
        --node) (( $# >= 2 )) || die '--node requires a value'; node="$2"; shift 2 ;;
        --template-node) (( $# >= 2 )) || die '--template-node requires a value'; template_node="$2"; shift 2 ;;
        --state-dir) (( $# >= 2 )) || die '--state-dir requires a value'; state_dir="$2"; shift 2 ;;
        --topology) (( $# >= 2 )) || die '--topology requires a value'; topology="$2"; shift 2 ;;
        --capacity) (( $# >= 2 )) || die '--capacity requires a value'; capacity="$2"; shift 2 ;;
        --capacity-egress) (( $# >= 2 )) || die '--capacity-egress requires a value'; capacity_egress="$2"; shift 2 ;;
        --assignments) (( $# >= 2 )) || die '--assignments requires a value'; assignments="$2"; shift 2 ;;
        --node-generation) (( $# >= 2 )) || die '--node-generation requires a value'; node_generation="$2"; shift 2 ;;
        --partition-generation) (( $# >= 2 )) || die '--partition-generation requires a value'; partition_generation="$2"; shift 2 ;;
        --partition) (( $# >= 2 )) || die '--partition requires a value'; partition="$2"; shift 2 ;;
        --config-digest) (( $# >= 2 )) || die '--config-digest requires a value'; config_digest="$2"; shift 2 ;;
        --image-digest) (( $# >= 2 )) || die '--image-digest requires a value'; image_digest="$2"; shift 2 ;;
        --idempotency-key) (( $# >= 2 )) || die '--idempotency-key requires a value'; idempotency_key="$2"; shift 2 ;;
        --registry-limit) (( $# >= 2 )) || die '--registry-limit requires a value'; registry_limit="$2"; shift 2 ;;
        --tier) (( $# >= 2 )) || die '--tier requires a value'; tier_override="$2"; shift 2 ;;
        --provider) (( $# >= 2 )) || die '--provider requires a value'; provider_override="$2"; shift 2 ;;
        --region) (( $# >= 2 )) || die '--region requires a value'; region_override="$2"; shift 2 ;;
        --zone) (( $# >= 2 )) || die '--zone requires a value'; zone_override="$2"; shift 2 ;;
        --reason) (( $# >= 2 )) || die '--reason requires a value'; reason="$2"; shift 2 ;;
        --requires-drained) (( $# >= 2 )) || die '--requires-drained requires a value'; requires_drained="$2"; shift 2 ;;
        --replaces-node) (( $# >= 2 )) || die '--replaces-node requires a value'; replaces_node="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ "${mode}" =~ ^(simulate|dry-run)$ ]] || die 'mode must be simulate or dry-run'
[[ "${contract_version}" == 1 ]] || die 'unsupported contract version'
[[ "${operation}" =~ ^(plan|create|configure|health|sessions|stop-admit|fail|drain|destroy)$ ]] || \
    die 'unsupported operation'
valid_node_id "${node}" || die 'node id is invalid'
valid_token "${run_id}" || die 'run id is invalid'
valid_token "${request_id}" || die 'request id is invalid'
[[ -f "${topology}" ]] || die 'topology does not exist'
[[ -n "${state_dir}" && "${state_dir}" == /* && "${state_dir}" != / ]] || \
    die 'state-dir must be an absolute non-root path'
[[ "${state_dir}" != *'/../'* && "${state_dir}" != */.. && \
   "${state_dir}" != *'/./'* && "${state_dir}" != */. && \
   "${state_dir}" != *$'\n'* ]] || die 'state-dir is not a canonical safe path'
[[ ! -L "${state_dir}" ]] || die 'state-dir must not be a symbolic link'
[[ -z "${template_node}" ]] || valid_node_id "${template_node}" || die 'template node is invalid'
[[ -z "${capacity}" ]] || require_uint capacity "${capacity}"
[[ -z "${capacity_egress}" ]] || require_uint capacity_egress "${capacity_egress}"
[[ -z "${assignments}" ]] || require_uint assignments "${assignments}"
require_uint node_generation "${node_generation}"
require_uint registry_limit "${registry_limit}"

action_context=false
if [[ -n "${idempotency_key}" ]]; then
    action_context=true
    [[ "${operation}" =~ ^(create|destroy)$ ]] || die 'envelope action must be create or destroy'
    [[ "${idempotency_key}" =~ ^sha256:[0-9a-f]{64}$ ]] || die 'idempotency key is invalid'
    [[ "${config_digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || die 'config digest is invalid'
    [[ "${image_digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || die 'image digest is invalid'
    valid_token "${partition}" || die 'partition is invalid'
    require_uint partition_generation "${partition_generation}"
    (( partition_generation >= 1 && node_generation >= 1 && registry_limit >= 1 )) || \
        die 'action generations and registry limit must be positive'
    valid_token "${tier_override}" && valid_token "${provider_override}" && \
        valid_token "${region_override}" && valid_token "${zone_override}" || \
        die 'action placement or tier is invalid'
    [[ "${reason}" =~ ^[a-z][a-z0-9_]{0,62}$ ]] || die 'action reason is invalid'
    [[ "${reason}" =~ ^(configured_minimum|autoscale_out|autoscale_in|failed_node_replacement|failed_node_cleanup|safe_shutdown)$ ]] || \
        die 'action reason is outside contract v1'
    [[ "${requires_drained}" =~ ^(true|false)$ ]] || die 'requires-drained is invalid'
    [[ -n "${capacity}" && -n "${capacity_egress}" ]] || die 'action capacity is incomplete'
    [[ -z "${replaces_node}" ]] || valid_node_id "${replaces_node}" || die 'replacement node is invalid'
    if [[ "${operation}" == create ]]; then
        [[ "${requires_drained}" == false ]] || die 'create cannot require drained state'
    else
        [[ "${requires_drained}" == true ]] || die 'destroy must require drained state'
        [[ -z "${replaces_node}" ]] || die 'replacement linkage is valid only for create'
    fi
fi

started_ms="$(monotonic_ms)"
nodes_dir="${state_dir}/nodes"
node_dir="${nodes_dir}/${node}"
contracts_dir="${state_dir}/contracts"
keys_dir="${state_dir}/idempotency"
idempotency_hex="${idempotency_key#sha256:}"
[[ ! -L "${nodes_dir}" && ! -L "${node_dir}" ]] || \
    die 'provider state must not contain symbolic links'

if [[ "${mode}" == dry-run ]]; then
    if [[ "${operation}" =~ ^(plan|create)$ && "${action_context}" == false ]]; then
        spec_id="${template_node:-${node}}"
        lookup_topology "${spec_id}" >/dev/null || die "topology node not found: ${spec_id}"
    fi
    emit planned planned dry_run_no_mutation
    exit 0
fi

if [[ "${operation}" == plan ]]; then
    spec_id="${template_node:-${node}}"
    lookup_topology "${spec_id}" >/dev/null || die "topology node not found: ${spec_id}"
    emit planned planned desired_state_valid
    exit 0
fi

mkdir -p -- "${nodes_dir}"
chmod 700 "${state_dir}" "${nodes_dir}"

lock_dir="${state_dir}/.adapter-lock"
mkdir -- "${lock_dir}" 2>/dev/null || die 'provider state is busy'
release_lock() {
    rmdir -- "${lock_dir}" 2>/dev/null || true
}
trap release_lock EXIT

if [[ "${action_context}" == true ]]; then
    mkdir -p -- "${contracts_dir}" "${keys_dir}"
    if [[ -f "${keys_dir}/${idempotency_hex}" ]]; then
        current_state=absent
        [[ ! -d "${node_dir}" ]] || current_state="$(read_value "${node_dir}/state")"
        emit unchanged "${current_state}" idempotent_replay
        exit 0
    fi
    key_count="$(find "${keys_dir}" -mindepth 1 -maxdepth 1 -type f | wc -l)"
    (( key_count < registry_limit )) || die 'idempotency registry is full'
    if [[ -f "${contracts_dir}/config_digest" ]]; then
        [[ "$(read_value "${contracts_dir}/config_digest")" == "${config_digest}" ]] || \
            die 'config digest changed within provider state'
        [[ "$(read_value "${contracts_dir}/image_digest")" == "${image_digest}" ]] || \
            die 'image digest changed within provider state'
    fi
    previous_partition_generation=0
    if [[ -f "${contracts_dir}/generation-${partition}" ]]; then
        previous_partition_generation="$(read_value "${contracts_dir}/generation-${partition}")"
    fi
    (( partition_generation >= previous_partition_generation )) || die 'stale partition generation'
fi

case "${operation}" in
    create)
        if [[ -d "${node_dir}" ]]; then
            [[ "${action_context}" == false ]] || die 'unseen create targets an existing node'
            current_state="$(read_value "${node_dir}/state")"
            emit unchanged "${current_state}" already_exists
            exit 0
        fi
        if [[ "${action_context}" == true ]]; then
            role=distributor
            [[ "${tier_override}" != origin ]] || role=origin
            tier="${tier_override}"
            provider="${provider_override}"
            region="${region_override}"
            zone="${zone_override}"
            base_capacity="${capacity}"
        else
            spec_id="${template_node:-${node}}"
            spec="$(lookup_topology "${spec_id}")" || die "topology node not found: ${spec_id}"
            IFS=$'\t' read -r _ role tier provider region base_capacity <<<"${spec}"
            zone=local
        fi
        valid_token "${role}" && valid_token "${tier}" && valid_token "${provider}" && \
            valid_token "${region}" || die 'topology contains an invalid token'
        require_uint base_capacity "${base_capacity}"
        selected_capacity="${capacity:-${base_capacity}}"
        mkdir -- "${node_dir}"
        chmod 700 "${node_dir}"
        atomic_write "${node_dir}/role" "${role}"
        atomic_write "${node_dir}/tier" "${tier}"
        atomic_write "${node_dir}/provider" "${provider}"
        atomic_write "${node_dir}/region" "${region}"
        atomic_write "${node_dir}/zone" "${zone}"
        atomic_write "${node_dir}/capacity" "${selected_capacity}"
        atomic_write "${node_dir}/capacity_egress" "${capacity_egress:-0}"
        atomic_write "${node_dir}/generation" "${node_generation}"
        atomic_write "${node_dir}/partition" "${partition:-local}"
        atomic_write "${node_dir}/config_digest" "${config_digest:-not_applicable}"
        atomic_write "${node_dir}/image_digest" "${image_digest:-not_applicable}"
        atomic_write "${node_dir}/assignments" 0
        atomic_write "${node_dir}/admissions" open
        atomic_write "${node_dir}/drain_ack" 0
        atomic_write "${node_dir}/state" created
        emit changed created created
        ;;
    configure)
        [[ -d "${node_dir}" ]] || die 'cannot configure an absent node'
        current_state="$(read_value "${node_dir}/state")"
        [[ "${current_state}" =~ ^(created|configured|healthy)$ ]] || \
            die "cannot configure node in state ${current_state}"
        selected_capacity="${capacity:-$(read_value "${node_dir}/capacity")}"
        require_uint capacity "${selected_capacity}"
        current_capacity="$(read_value "${node_dir}/capacity")"
        if [[ "${selected_capacity}" == "${current_capacity}" && \
              "${current_state}" =~ ^(configured|healthy)$ ]]; then
            emit unchanged "${current_state}" configuration_matches
            exit 0
        fi
        atomic_write "${node_dir}/capacity" "${selected_capacity}"
        atomic_write "${node_dir}/state" configured
        emit changed configured configured
        ;;
    health)
        [[ -d "${node_dir}" ]] || die 'cannot inspect an absent node'
        current_state="$(read_value "${node_dir}/state")"
        case "${current_state}" in
            configured)
                atomic_write "${node_dir}/state" healthy
                emit changed healthy health_passed
                ;;
            healthy)
                emit unchanged healthy health_passed
                ;;
            drained)
                emit unchanged drained health_passed_drained
                ;;
            *) die "node is not configured: ${current_state}" ;;
        esac
        ;;
    sessions)
        [[ -d "${node_dir}" ]] || die 'cannot assign sessions to an absent node'
        [[ -n "${assignments}" ]] || die 'sessions requires assignments'
        current_state="$(read_value "${node_dir}/state")"
        admissions="$(read_value "${node_dir}/admissions")"
        capacity_value="$(read_value "${node_dir}/capacity")"
        if (( assignments > 0 )); then
            [[ "${current_state}" == healthy && "${admissions}" == open ]] || \
                die 'nonzero assignments require a healthy admitting node'
            (( assignments <= capacity_value )) || die 'assignments exceed node capacity'
        fi
        current_assignments="$(read_value "${node_dir}/assignments")"
        if [[ "${current_assignments}" == "${assignments}" ]]; then
            emit unchanged "${current_state}" assignments_match
        else
            atomic_write "${node_dir}/assignments" "${assignments}"
            emit changed "${current_state}" assignments_updated
        fi
        ;;
    stop-admit)
        [[ -d "${node_dir}" ]] || die 'cannot stop admissions on an absent node'
        current_state="$(read_value "${node_dir}/state")"
        if [[ "$(read_value "${node_dir}/admissions")" == stopped ]]; then
            emit unchanged "${current_state}" admissions_already_stopped
        else
            atomic_write "${node_dir}/admissions" stopped
            emit changed "${current_state}" admissions_stopped
        fi
        ;;
    fail)
        [[ -d "${node_dir}" ]] || die 'cannot fail an absent node'
        current_state="$(read_value "${node_dir}/state")"
        if [[ "${current_state}" == failed ]]; then
            emit unchanged failed already_failed
        else
            [[ "${current_state}" == healthy ]] || die "cannot fail node in state ${current_state}"
            atomic_write "${node_dir}/admissions" stopped
            atomic_write "${node_dir}/state" failed
            emit changed failed failed
        fi
        ;;
    drain)
        [[ -d "${node_dir}" ]] || die 'cannot drain an absent node'
        current_state="$(read_value "${node_dir}/state")"
        case "${current_state}" in
            healthy|configured|failed)
                [[ "$(read_value "${node_dir}/admissions")" == stopped ]] || \
                    die 'drain requires stop-admit acknowledgement'
                [[ "$(read_value "${node_dir}/assignments")" == 0 ]] || \
                    die 'drain requires zero assignments'
                atomic_write "${node_dir}/state" drained
                atomic_write "${node_dir}/drain_ack" 1
                emit changed drained drained
                ;;
            drained)
                emit unchanged drained already_drained
                ;;
            *) die "cannot drain node in state ${current_state}" ;;
        esac
        ;;
    destroy)
        if [[ ! -d "${node_dir}" ]]; then
            [[ "${action_context}" == false ]] || die 'unseen destroy targets an absent node'
            emit unchanged absent already_absent
            exit 0
        fi
        [[ "$(read_value "${node_dir}/state")" == drained && \
           "$(read_value "${node_dir}/drain_ack")" == 1 ]] || \
            die 'destroy requires drain acknowledgement'
        [[ "$(read_value "${node_dir}/admissions")" == stopped ]] || \
            die 'destroy requires stopped admissions'
        [[ "$(read_value "${node_dir}/assignments")" == 0 ]] || \
            die 'destroy requires zero assignments'
        if [[ "${action_context}" == true ]]; then
            current_generation="$(read_value "${node_dir}/generation")"
            (( node_generation >= current_generation )) || die 'destroy node generation is stale'
            [[ "${requires_drained}" == true ]] || die 'envelope destroy lacks drain requirement'
        fi
        [[ "${node_dir}" == "${state_dir}/nodes/${node}" ]] || die 'unsafe node path'
        rm -rf -- "${node_dir}"
        emit changed absent destroyed
        ;;
esac
