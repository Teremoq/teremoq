#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
config='' cert='' fingerprint='' attestation='' state_dir=''
while (( $# > 0 )); do
    case "$1" in
        --config|--certificate|--fingerprint|--attestation|--state-dir)
            (( $# >= 2 )) || lan_die "$1 requires a value"
            case "$1" in
                --config) config="$2" ;; --certificate) cert="$2" ;; --fingerprint) fingerprint="$2" ;;
                --attestation) attestation="$2" ;; --state-dir) state_dir="$2" ;;
            esac
            shift 2 ;;
        *) lan_die "unknown proxy start argument: $1" ;;
    esac
done
lan_load_config "${config}"
lan_validate_config
[[ "${LAN_CONFIG[relay_san_integration_status]}" == ready ]] || lan_die 'relay SAN owner integration remains pending'
lan_require_clean_integrated_source "${REPO_ROOT}" "${LAN_CONFIG[source_commit]}" "${LAN_CONFIG[relay_san_integration_commit]}"
[[ "${state_dir}" == /tmp/teremoq-lan-* || "${state_dir}" == "${SCRIPT_DIR}/runtime/"* ]] || lan_die 'unsafe state-dir scope'
[[ -f "${state_dir}/run-id" && "$(<"${state_dir}/run-id")" == "${LAN_CONFIG[run_id]}" ]] || lan_die 'state run ownership mismatch'
exec python3 "${SCRIPT_DIR}/udp_proxy.py" \
    --frontend-ip "${LAN_CONFIG[server_ipv4]}" \
    --frontend-port "${LAN_CONFIG[moq_frontend_udp_port]}" \
    --allowed-client-ip "${LAN_CONFIG[client_ipv4]}" \
    --prefix-length "${LAN_CONFIG[prefix_length]}" \
    --backend "${LAN_CONFIG[moq_backend_loopback_addr]}" \
    --max-clients "${LAN_CONFIG[proxy_max_clients]}" \
    --association-margin "${LAN_CONFIG[proxy_association_margin]}" \
    --idle-timeout "${LAN_CONFIG[proxy_idle_timeout_seconds]}" \
    --certificate "${cert}" --fingerprint "${fingerprint}" \
    --attestation "${attestation}" --state-dir "${state_dir}" \
    --run-id "${LAN_CONFIG[run_id]}" --source-commit "${LAN_CONFIG[source_commit]}" \
    --owner-commit "${LAN_CONFIG[relay_san_integration_commit]}"
