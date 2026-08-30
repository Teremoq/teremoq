#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
config='' state_dir=''
while (( $# > 0 )); do
    case "$1" in
        --config) (( $# >= 2 )) || lan_die '--config requires a value'; config="$2"; shift 2 ;;
        --state-dir) (( $# >= 2 )) || lan_die '--state-dir requires a value'; state_dir="$2"; shift 2 ;;
        *) lan_die "unknown rollback argument: $1" ;;
    esac
done
lan_load_config "${config}"
lan_validate_config
[[ "${state_dir}" == /tmp/teremoq-lan-* || "${state_dir}" == "${SCRIPT_DIR}/runtime/"* ]] || lan_die 'unsafe state-dir scope'
[[ "${state_dir}" != *'/../'* && "${state_dir}" != */.. && ! -L "${state_dir}" ]] || lan_die 'unsafe state-dir'
if [[ ! -e "${state_dir}" ]]; then
    printf 'teremoq LAN rollback: already absent\n'
    exit 0
fi
[[ -f "${state_dir}/run-id" && ! -L "${state_dir}/run-id" && "$(<"${state_dir}/run-id")" == "${LAN_CONFIG[run_id]}" ]] || \
    lan_die 'state-dir ownership marker mismatch'
[[ -f "${state_dir}/source-commit" && ! -L "${state_dir}/source-commit" && \
   "$(<"${state_dir}/source-commit")" == "${LAN_CONFIG[source_commit]}" ]] || \
    lan_die 'state-dir source ownership marker mismatch'
for pid_name in lab.pid proxy.pid; do
    if [[ -e "${state_dir}/${pid_name}" ]]; then
        [[ -f "${state_dir}/${pid_name}" && ! -L "${state_dir}/${pid_name}" ]] || lan_die "unsafe ${pid_name} marker"
        owned_pid="$(<"${state_dir}/${pid_name}")"
        [[ "${owned_pid}" =~ ^[1-9][0-9]*$ ]] || lan_die "invalid ${pid_name} marker"
        if kill -0 "${owned_pid}" 2>/dev/null; then lan_die "refusing cleanup while run-owned process is live: ${pid_name}"; fi
    fi
done
if [[ "${LAN_CONFIG[relay_san_integration_status]}" == ready ]]; then
    python3 "${SCRIPT_DIR}/publish_capability.py" remove --state-dir "${state_dir}" \
        --run-id "${LAN_CONFIG[run_id]}" --source-commit "${LAN_CONFIG[source_commit]}" \
        --owner-commit "${LAN_CONFIG[relay_san_integration_commit]}"
elif [[ -e "${state_dir}/publish-capability" || -L "${state_dir}/publish-capability" || \
        -e "${state_dir}/publish-capability.metadata.tsv" || -L "${state_dir}/publish-capability.metadata.tsv" ]]; then
    lan_die 'pending integration state unexpectedly contains a publish capability'
fi
find "${state_dir}" -depth -delete
printf 'teremoq LAN rollback: runtime removed\n'
