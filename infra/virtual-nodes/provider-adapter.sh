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
        *) die "unknown argument: $1" ;;
    esac
done

[[ "${mode}" =~ ^(simulate|dry-run)$ ]] || die 'mode must be simulate or dry-run'
[[ "${contract_version}" == 1 ]] || die 'unsupported contract version'
[[ "${operation}" =~ ^(plan|create|configure|health|drain|destroy)$ ]] || \
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

started_ms="$(monotonic_ms)"
nodes_dir="${state_dir}/nodes"
node_dir="${nodes_dir}/${node}"
[[ ! -L "${nodes_dir}" && ! -L "${node_dir}" ]] || \
    die 'provider state must not contain symbolic links'

if [[ "${mode}" == dry-run ]]; then
    if [[ "${operation}" =~ ^(plan|create)$ ]]; then
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

case "${operation}" in
    create)
        if [[ -d "${node_dir}" ]]; then
            current_state="$(read_value "${node_dir}/state")"
            emit unchanged "${current_state}" already_exists
            exit 0
        fi
        spec_id="${template_node:-${node}}"
        spec="$(lookup_topology "${spec_id}")" || die "topology node not found: ${spec_id}"
        IFS=$'\t' read -r _ role tier provider region base_capacity <<<"${spec}"
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
        atomic_write "${node_dir}/capacity" "${selected_capacity}"
        atomic_write "${node_dir}/generation" 1
        atomic_write "${node_dir}/state" created
        emit changed created created
        ;;
    configure)
        [[ -d "${node_dir}" ]] || die 'cannot configure an absent node'
        current_state="$(read_value "${node_dir}/state")"
        [[ "${current_state}" =~ ^(created|configured|healthy|drained)$ ]] || \
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
    drain)
        [[ -d "${node_dir}" ]] || die 'cannot drain an absent node'
        current_state="$(read_value "${node_dir}/state")"
        case "${current_state}" in
            healthy|configured)
                atomic_write "${node_dir}/state" drained
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
            emit unchanged absent already_absent
            exit 0
        fi
        [[ "${node_dir}" == "${state_dir}/nodes/${node}" ]] || die 'unsafe node path'
        rm -rf -- "${node_dir}"
        emit changed absent destroyed
        ;;
esac
