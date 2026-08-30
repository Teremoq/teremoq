#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
config='' state_dir=''
state_created=false
cleanup_partial_state() {
    local status=$?
    if (( status != 0 )) && [[ "${state_created}" == true && -d "${state_dir}" && ! -L "${state_dir}" ]]; then
        if [[ ! -e "${state_dir}/run-id" && ! -L "${state_dir}/run-id" ]] || \
           [[ -f "${state_dir}/run-id" && ! -L "${state_dir}/run-id" && \
              "$(<"${state_dir}/run-id")" == "${LAN_CONFIG[run_id]:-}" ]]; then
            find "${state_dir}" -depth -delete
        fi
    fi
    exit "${status}"
}
trap cleanup_partial_state EXIT
while (( $# > 0 )); do
    case "$1" in
        --config) (( $# >= 2 )) || lan_die '--config requires a value'; config="$2"; shift 2 ;;
        --state-dir) (( $# >= 2 )) || lan_die '--state-dir requires a value'; state_dir="$2"; shift 2 ;;
        *) lan_die "unknown runtime preparation argument: $1" ;;
    esac
done
lan_load_config "${config}"
lan_validate_config
[[ "${state_dir}" == /tmp/teremoq-lan-* || "${state_dir}" == "${SCRIPT_DIR}/runtime/"* ]] || \
    lan_die 'state-dir must be an explicit LAN runtime path under /tmp or infra/lan/runtime'
[[ "${state_dir}" != *'/../'* && "${state_dir}" != */.. && ! -L "${state_dir}" ]] || lan_die 'unsafe state-dir'
[[ ! -e "${state_dir}" ]] || lan_die 'state-dir already exists'
mkdir -m 0700 -p -- "${state_dir}"
state_created=true
printf '%s\n' "${LAN_CONFIG[run_id]}" >"${state_dir}/run-id"
printf '%s\n' "${LAN_CONFIG[source_commit]}" >"${state_dir}/source-commit"
printf '%s\n' "${LAN_CONFIG[relay_san_integration_status]}" >"${state_dir}/activation-status"
if [[ "${LAN_CONFIG[relay_san_integration_status]}" == ready ]]; then
    python3 "${SCRIPT_DIR}/publish_capability.py" prepare --state-dir "${state_dir}" \
        --run-id "${LAN_CONFIG[run_id]}" --source-commit "${LAN_CONFIG[source_commit]}" \
        --owner-commit "${LAN_CONFIG[relay_san_integration_commit]}"
fi
printf 'server_ipv4\t%s\nclient_ipv4\t%s\nmoq_frontend_udp_port\t%s\nmoq_backend\t%s\n' \
    "${LAN_CONFIG[server_ipv4]}" "${LAN_CONFIG[client_ipv4]}" "${LAN_CONFIG[moq_frontend_udp_port]}" \
    "${LAN_CONFIG[moq_backend_loopback_addr]}" \
    >"${state_dir}/non-secret-plan.tsv"
printf 'teremoq LAN runtime prepared at %s; relay SAN owner gate is %s\n' "${state_dir}" "${LAN_CONFIG[relay_san_integration_status]}"
