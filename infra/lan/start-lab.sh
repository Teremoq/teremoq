#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
umask 077
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
declare -A options=()
while (( $# > 0 )); do
    case "$1" in
        --config|--commands|--authorization|--wsl-preflight|--server-preflight|--client-preflight|--firewall-attestation|--certificate|--key|--fingerprint|--identity-profile|--proxy-attestation|--artifact-root|--state-dir)
            (( $# >= 2 )) || lan_die "$1 requires a value"; options["${1#--}"]="$2"; shift 2 ;;
        *) lan_die "unknown lab start argument: $1" ;;
    esac
done
for key in config commands authorization wsl-preflight server-preflight client-preflight firewall-attestation certificate key fingerprint identity-profile proxy-attestation artifact-root state-dir; do
    [[ -n "${options[${key}]:-}" ]] || lan_die "missing --${key}"
done
lan_load_config "${options[config]}"
lan_validate_config
[[ "${LAN_CONFIG[server_wsl_mode]}" == mirrored ]] || lan_die 'server WSL NAT remains active; mirrored mode is required'
[[ "${LAN_CONFIG[relay_san_integration_status]}" == ready ]] || lan_die 'relay/player owner integration remains pending'
lan_require_clean_integrated_source "${REPO_ROOT}" "${LAN_CONFIG[source_commit]}" "${LAN_CONFIG[relay_san_integration_commit]}"
[[ -f "${options[state-dir]}/run-id" && "$(<"${options[state-dir]}/run-id")" == "${LAN_CONFIG[run_id]}" ]] || lan_die 'state run ownership mismatch'
for path in commands authorization wsl-preflight server-preflight client-preflight firewall-attestation certificate key fingerprint identity-profile proxy-attestation artifact-root state-dir; do
    [[ "${options[${path}]}" == /* ]] || lan_die "--${path} must be absolute"
done
"${SCRIPT_DIR}/verify-runtime-pki.sh" --config "${options[config]}" --cert "${options[certificate]}" \
    --root "${options[certificate]}" --fingerprint "${options[fingerprint]}"
exec python3 "${SCRIPT_DIR}/lab_runtime.py" \
    --commands "${options[commands]}" --authorization "${options[authorization]}" \
    --wsl-preflight "${options[wsl-preflight]}" \
    --server-preflight "${options[server-preflight]}" --client-preflight "${options[client-preflight]}" \
    --firewall-attestation "${options[firewall-attestation]}" --certificate "${options[certificate]}" \
    --key "${options[key]}" --fingerprint "${options[fingerprint]}" --identity-profile "${options[identity-profile]}" --proxy-attestation "${options[proxy-attestation]}" \
    --repo-root "${REPO_ROOT}" --artifact-root "${options[artifact-root]}" \
    --state-dir "${options[state-dir]}" --run-id "${LAN_CONFIG[run_id]}" --source-commit "${LAN_CONFIG[source_commit]}" \
    --owner-commit "${LAN_CONFIG[relay_san_integration_commit]}" \
    --server-ip "${LAN_CONFIG[server_ipv4]}" --client-ip "${LAN_CONFIG[client_ipv4]}" \
    --network-profile "${LAN_CONFIG[network_profile]}" \
    --moq-namespace "${LAN_CONFIG[moq_namespace]}" \
    --prefix-length "${LAN_CONFIG[prefix_length]}" \
    --maximum-clock-offset-ms "${LAN_CONFIG[maximum_clock_offset_ms]}" \
    --minimum-mtu "${LAN_CONFIG[minimum_mtu]}" \
    --server-minimum-cpu-cores "${LAN_CONFIG[server_minimum_cpu_cores]}" \
    --server-minimum-memory-mib "${LAN_CONFIG[server_minimum_memory_mib]}" \
    --server-minimum-disk-mib "${LAN_CONFIG[server_minimum_disk_mib]}" \
    --client-minimum-cpu-cores "${LAN_CONFIG[client_minimum_cpu_cores]}" \
    --client-minimum-memory-mib "${LAN_CONFIG[client_minimum_memory_mib]}" \
    --client-minimum-disk-mib "${LAN_CONFIG[client_minimum_disk_mib]}" \
    --max-clients "${LAN_CONFIG[proxy_max_clients]}" --association-margin "${LAN_CONFIG[proxy_association_margin]}" \
    --idle-timeout "${LAN_CONFIG[proxy_idle_timeout_seconds]}"
