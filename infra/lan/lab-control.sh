#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
action='' config=''
while (( $# > 0 )); do
    case "$1" in
        --action) (( $# >= 2 )) || lan_die '--action requires start-plan or stop-plan'; action="$2"; shift 2 ;;
        --config) (( $# >= 2 )) || lan_die '--config requires a value'; config="$2"; shift 2 ;;
        *) lan_die "unknown lab-control argument: $1" ;;
    esac
done
[[ "${action}" =~ ^(start-plan|stop-plan)$ ]] || lan_die 'action must be start-plan or stop-plan'
lan_load_config "${config}"
lan_validate_config
if [[ "${action}" == start-plan ]]; then
    if [[ "${LAN_CONFIG[relay_san_integration_status]}" != ready ]]; then
        printf 'BLOCKED: relay certificate SAN owner integration is pending.\n' >&2
        exit 3
    fi
    printf 'Planned path: client %s -> UDP/%s proxy bound to %s -> relay %s.\n' \
        "${LAN_CONFIG[client_ipv4]}" "${LAN_CONFIG[moq_frontend_udp_port]}" \
        "${LAN_CONFIG[server_ipv4]}" "${LAN_CONFIG[moq_backend_loopback_addr]}"
    printf 'Supervisor remains %s; no dashboard LAN bind.\n' "${LAN_CONFIG[supervisor_loopback_addr]}"
    printf 'Executable lifecycle: infra/lan/start-lab.sh after hashed preflight/firewall/PKI authorization; this planning action starts nothing.\n'
    exit 0
fi
printf 'Executable run-owned stop: infra/lan/stop-lab.sh; it stops source/proxy/Gateway/relay children in reverse order.\n'
printf 'Then use the exact elevated firewall rollback and remove run-owned runtime only after both rule residues are zero.\n'
