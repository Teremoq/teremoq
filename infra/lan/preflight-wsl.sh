#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
role=''
config=''
while (( $# > 0 )); do
    case "$1" in
        --role) (( $# >= 2 )) || lan_die '--role requires server or client'; role="$2"; shift 2 ;;
        --config) (( $# >= 2 )) || lan_die '--config requires an absolute path'; config="$2"; shift 2 ;;
        *) lan_die "unknown preflight argument: $1" ;;
    esac
done
[[ "${role}" =~ ^(server|client)$ ]] || lan_die '--role must be server or client'
lan_load_config "${config}"
lan_validate_config

emit() {
    local check="$1" status="$2" value="$3" quality="$4"
    value="${value//$'\t'/ }"; value="${value//$'\n'/ }"; value="${value//$'\r'/ }"
    [[ -n "${value}" ]] || value=unavailable
    if [[ "${check}" != preflight_gate ]] && { [[ ! "${status}" =~ ^(pass|observed)$ ]] || [[ ! "${quality}" =~ ^(real|configured)$ ]] || \
       [[ "${value,,}" =~ (^|[^a-z])(blocked|pending|unavailable|unknown|not_measured|occupied)($|[^a-z]) ]]; }; then
        preflight_blocked=1
    fi
    printf '%s\t%s\t%s\t%s\n' "${check}" "${status}" "${value}" "${quality}"
}

preflight_blocked=0
printf 'check\tstatus\tvalue\tevidence_quality\n'
emit schema_version pass 1 configured
emit report_kind pass teremoq-lan-wsl-preflight-v1 configured
emit run_id pass "${LAN_CONFIG[run_id]}" configured
emit source_commit pass "${LAN_CONFIG[source_commit]}" configured
emit role pass "${role}" configured
emit server_ipv4 pass "${LAN_CONFIG[server_ipv4]}" configured
emit client_ipv4 pass "${LAN_CONFIG[client_ipv4]}" configured
emit prefix_length pass "${LAN_CONFIG[prefix_length]}" configured
emit network_profile pass "${LAN_CONFIG[network_profile]}" configured
emit expected_wsl_mode pass "${LAN_CONFIG[${role}_wsl_mode]}" configured
if grep -qi microsoft /proc/version 2>/dev/null; then
    emit wsl_kernel observed "$(uname -r 2>/dev/null || printf unavailable)" real
else
    emit wsl_kernel blocked unavailable unavailable
fi

observed_wsl_mode=unavailable
if command -v wslinfo >/dev/null 2>&1; then
    reported_mode="$(wslinfo --networking-mode 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    [[ "${reported_mode}" =~ ^(nat|mirrored)$ ]] && observed_wsl_mode="${reported_mode}"
fi
if [[ "${observed_wsl_mode}" == unavailable ]] && command -v ip >/dev/null 2>&1; then
    global_ipv4="$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
    if grep -Fxq "${LAN_CONFIG[${role}_ipv4]}" <<<"${global_ipv4}"; then observed_wsl_mode=mirrored
    elif [[ -n "${global_ipv4}" ]]; then observed_wsl_mode=nat
    fi
fi
emit windows_wsl_mode_observed "$([[ "${observed_wsl_mode}" == "${LAN_CONFIG[${role}_wsl_mode]}" ]] && printf pass || printf blocked)" \
    "${observed_wsl_mode}" "$([[ "${observed_wsl_mode}" == unavailable ]] && printf unavailable || printf real)"

clock_sync=unavailable
if command -v timedatectl >/dev/null 2>&1; then
    clock_sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || printf unavailable)"
fi
[[ -n "${clock_sync}" ]] || clock_sync=unavailable
clock_status=blocked
[[ "${clock_sync,,}" =~ ^(yes|true|1)$ ]] && clock_status=pass
emit clock_synchronized "${clock_status}" "${clock_sync}" "$([[ "${clock_sync}" == unavailable ]] && printf unavailable || printf real)"

peer="${LAN_CONFIG[client_ipv4]}"
[[ "${role}" == client ]] && peer="${LAN_CONFIG[server_ipv4]}"
route_line=unavailable
interface=unavailable
mtu=unavailable
if command -v ip >/dev/null 2>&1; then
    route_line="$(ip -o route get "${peer}" 2>/dev/null | head -1 || printf unavailable)"
    interface="$(awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<<"${route_line}")"
    [[ -n "${interface}" ]] || interface=unavailable
    if [[ "${interface}" != unavailable ]]; then
        mtu="$(ip -o link show dev "${interface}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="mtu") {print $(i+1); exit}}')"
        [[ -n "${mtu}" ]] || mtu=unavailable
    fi
fi
emit route_to_peer "$([[ "${route_line}" == unavailable ]] && printf blocked || printf observed)" "${route_line}" "$([[ "${route_line}" == unavailable ]] && printf unavailable || printf real)"
emit route_interface "$([[ "${interface}" == unavailable ]] && printf blocked || printf observed)" "${interface}" "$([[ "${interface}" == unavailable ]] && printf unavailable || printf real)"
emit mtu "$([[ "${mtu}" == unavailable ]] && printf blocked || printf observed)" "${mtu}" "$([[ "${mtu}" == unavailable ]] && printf unavailable || printf real)"

cpu="$(command -v nproc >/dev/null 2>&1 && nproc 2>/dev/null || printf unavailable)"
memory="$(awk '/MemAvailable:/ {printf "%d", $2 / 1024}' /proc/meminfo 2>/dev/null || true)"
[[ -n "${memory}" ]] || memory=unavailable
disk="$(df -Pm "${SCRIPT_DIR}" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
[[ -n "${disk}" ]] || disk=unavailable
emit cpu_cores "$([[ "${cpu}" == unavailable ]] && printf blocked || printf observed)" "${cpu}" "$([[ "${cpu}" == unavailable ]] && printf unavailable || printf real)"
emit available_memory_mib "$([[ "${memory}" == unavailable ]] && printf blocked || printf observed)" "${memory}" "$([[ "${memory}" == unavailable ]] && printf unavailable || printf real)"
emit available_disk_mib "$([[ "${disk}" == unavailable ]] && printf blocked || printf observed)" "${disk}" "$([[ "${disk}" == unavailable ]] && printf unavailable || printf real)"

for tool in openssl curl sha256sum tar; do
    if command -v "${tool}" >/dev/null 2>&1; then emit "tool_${tool}" pass present real; else emit "tool_${tool}" blocked unavailable unavailable; fi
done
if [[ "${role}" == server ]]; then
    docker_version="$(docker version --format '{{.Server.Version}}' 2>/dev/null || printf unavailable)"
    emit docker_server "$([[ "${docker_version}" == unavailable ]] && printf blocked || printf observed)" "${docker_version}" "$([[ "${docker_version}" == unavailable ]] && printf unavailable || printf real)"
    if command -v ss >/dev/null 2>&1; then
        for port in 4433 9000 "${LAN_CONFIG[moq_frontend_udp_port]}" "${LAN_CONFIG[srt_udp_port]}"; do
            if ss -H -lun "sport = :${port}" 2>/dev/null | grep -q .; then udp_state=occupied; else udp_state=free; fi
            case "${port}" in 4433|9000) expected=absent ;; *) expected=free ;; esac
            status=pass; [[ "${udp_state}" == "${expected}" || "${udp_state}" == free && "${expected}" == absent ]] || status=blocked
            emit "listener_udp_${port}" "${status}" "${udp_state}" real
        done
        for port in 4433 5678 6379 11434; do
            if ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .; then tcp_state=occupied; else tcp_state=free; fi
            emit "listener_tcp_${port}" "$([[ "${tcp_state}" == free ]] && printf pass || printf blocked)" "${tcp_state}" real
        done
    else
        for descriptor in udp_4433 udp_9000 "udp_${LAN_CONFIG[moq_frontend_udp_port]}" "udp_${LAN_CONFIG[srt_udp_port]}" tcp_4433 tcp_5678 tcp_6379 tcp_11434; do
            emit "listener_${descriptor}" blocked unavailable unavailable
        done
    fi
    if command -v docker >/dev/null 2>&1; then
        while IFS=$'\t' read -r service ports; do
            [[ -n "${service}" ]] || continue
            for conflict in '4433/tcp' '5678/tcp' '6379/tcp' '11434/tcp' '4433/udp' '9000/udp' '14433/udp' '19000/udp'; do
                [[ "${ports}" == *"${conflict}"* ]] || continue
                emit inherited_docker_publication blocked "service=${service};port=${conflict}" real
            done
        done < <(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null || true)
    fi
fi
if [[ "${role}" == client ]]; then
    if command -v ss >/dev/null 2>&1; then
        if ss -H -ltn 'sport = :3000' 2>/dev/null | grep -q .; then tcp_state=occupied; else tcp_state=free; fi
        emit listener_tcp_3000 "$([[ "${tcp_state}" == free ]] && printf pass || printf blocked)" "${tcp_state}" real
    else
        emit listener_tcp_3000 blocked unavailable unavailable
    fi
fi
if (( preflight_blocked == 0 )); then emit preflight_gate pass ready real; else emit preflight_gate blocked blocked real; fi
