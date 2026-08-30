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
        *) lan_die "unknown lab stop argument: $1" ;;
    esac
done
lan_load_config "${config}"
lan_validate_config
[[ "${state_dir}" == /tmp/teremoq-lan-* || "${state_dir}" == "${SCRIPT_DIR}/runtime/"* ]] || lan_die 'unsafe state-dir scope'
[[ -f "${state_dir}/run-id" && "$(<"${state_dir}/run-id")" == "${LAN_CONFIG[run_id]}" ]] || lan_die 'state ownership marker mismatch'
pid_file="${state_dir}/lab.pid"
if [[ ! -e "${pid_file}" ]]; then printf 'teremoq LAN lab: already stopped\n'; exit 0; fi
[[ -f "${pid_file}" && ! -L "${pid_file}" ]] || lan_die 'unsafe lab pid file'
pid="$(<"${pid_file}")"
[[ "${pid}" =~ ^[1-9][0-9]*$ ]] || lan_die 'invalid lab pid'
cmdline="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)"
[[ "${cmdline}" == *"${SCRIPT_DIR}/lab_runtime.py"* && "${cmdline}" == *"${state_dir}"* ]] || lan_die 'pid does not own this exact LAN lab state'
kill -TERM "${pid}"
deadline=$(( SECONDS + 15 ))
while kill -0 "${pid}" 2>/dev/null; do
    (( SECONDS < deadline )) || lan_die 'lab did not stop within 15 seconds'
    sleep 0.1
done
for residue in lab.pid lab.ready proxy.pid proxy.ready; do [[ ! -e "${state_dir}/${residue}" ]] || lan_die "run-owned residue remains: ${residue}"; done
printf 'teremoq LAN lab: relay, Gateway, source and proxy stopped; run-owned readiness/PID residue is zero\n'
