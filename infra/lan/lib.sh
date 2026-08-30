#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0

lan_die() {
    printf 'teremoq LAN: %s\n' "$*" >&2
    exit 2
}

lan_ipv4_to_int() {
    local value="$1" a b c d extra
    IFS=. read -r a b c d extra <<<"${value}"
    [[ -z "${extra:-}" && -n "${d:-}" ]] || return 1
    for octet in "${a}" "${b}" "${c}" "${d}"; do
        [[ "${octet}" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
        (( 10#${octet} <= 255 )) || return 1
    done
    printf '%u\n' "$(( (10#${a} << 24) | (10#${b} << 16) | (10#${c} << 8) | 10#${d} ))"
}

lan_is_private_ipv4() {
    local value="$1" numeric first second
    numeric="$(lan_ipv4_to_int "${value}")" || return 1
    first=$(( (numeric >> 24) & 255 ))
    second=$(( (numeric >> 16) & 255 ))
    (( first == 10 )) || (( first == 172 && second >= 16 && second <= 31 )) || \
        (( first == 192 && second == 168 ))
}

lan_same_subnet() {
    local left right prefix mask left_int right_int
    left="$1"; right="$2"; prefix="$3"
    left_int="$(lan_ipv4_to_int "${left}")" || return 1
    right_int="$(lan_ipv4_to_int "${right}")" || return 1
    mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
    (( (left_int & mask) == (right_int & mask) ))
}

lan_is_host_address() {
    local value="$1" prefix="$2" numeric mask host_mask
    numeric="$(lan_ipv4_to_int "${value}")" || return 1
    mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
    host_mask=$(( (~mask) & 0xffffffff ))
    (( (numeric & host_mask) != 0 && (numeric & host_mask) != host_mask ))
}

lan_require_positive_uint() {
    local name="$1" value="$2" minimum="$3" maximum="$4"
    [[ "${value}" =~ ^[1-9][0-9]*$ ]] || lan_die "${name} must be a positive integer"
    (( 10#${value} >= minimum && 10#${value} <= maximum )) || \
        lan_die "${name} must be between ${minimum} and ${maximum}"
}

lan_load_config() {
    local config="$1" line=0 key value extra required_key
    [[ "${config}" == /* && -f "${config}" && ! -L "${config}" ]] || \
        lan_die 'config must be an absolute regular non-symlink TSV file'
    LAN_REQUIRED_KEYS=(
        schema_version run_id source_commit server_ipv4 client_ipv4 router_ipv4
        prefix_length server_wsl_mode client_wsl_mode srt_udp_port moq_frontend_udp_port
        moq_backend_loopback_addr moq_namespace player_loopback_tcp_port proxy_max_clients proxy_association_margin proxy_idle_timeout_seconds
        dashboard_lan_enabled supervisor_loopback_addr network_profile pki_runtime_dir
        client_artifact_dir maximum_clock_offset_ms minimum_mtu
        server_minimum_cpu_cores server_minimum_memory_mib server_minimum_disk_mib
        client_minimum_cpu_cores client_minimum_memory_mib client_minimum_disk_mib
        wifi_minimum_ghz legacy_wildcard_conflicts_must_be_absent relay_san_integration_status
        relay_san_integration_commit
    )
    declare -gA LAN_CONFIG=() LAN_ALLOWED=()
    for required_key in "${LAN_REQUIRED_KEYS[@]}"; do LAN_ALLOWED["${required_key}"]=1; done
    while IFS=$'\t' read -r key value extra || [[ -n "${key}${value}${extra}" ]]; do
        line=$(( line + 1 ))
        [[ -n "${key}" && "${key}" != \#* ]] || continue
        [[ -z "${extra}" && -n "${value}" ]] || lan_die "line ${line} must have exactly two non-empty TSV fields"
        [[ -n "${LAN_ALLOWED[${key}]:-}" ]] || lan_die "unknown config key: ${key}"
        [[ -z "${LAN_CONFIG[${key}]+present}" ]] || lan_die "duplicate config key: ${key}"
        [[ "${value}" != REQUIRED_* ]] || lan_die "unresolved placeholder: ${key}"
        [[ "${value}" != *$'\r'* && "${value}" != *$'\n'* ]] || lan_die "control character in ${key}"
        [[ "${value}" != *'PRIVATE KEY'* && "${value}" != *'BEGIN CERTIFICATE'* ]] || \
            lan_die "embedded credential material is forbidden: ${key}"
        LAN_CONFIG["${key}"]="${value}"
    done <"${config}"
    for required_key in "${LAN_REQUIRED_KEYS[@]}"; do
        [[ -n "${LAN_CONFIG[${required_key}]:-}" ]] || lan_die "missing config key: ${required_key}"
    done
    (( ${#LAN_CONFIG[@]} == ${#LAN_REQUIRED_KEYS[@]} )) || lan_die 'config key count mismatch'
}

lan_validate_config() {
    local prefix ip path key namespace_segment
    local -a namespace_segments
    [[ "${LAN_CONFIG[schema_version]}" == 1 ]] || lan_die 'unsupported schema_version'
    [[ "${LAN_CONFIG[run_id]}" =~ ^lan-[a-z0-9][a-z0-9-]{0,31}$ ]] || lan_die 'invalid run_id'
    [[ "${LAN_CONFIG[source_commit]}" =~ ^[0-9a-f]{40}$ ]] || lan_die 'source_commit must be an explicit full commit'
    prefix="${LAN_CONFIG[prefix_length]}"
    lan_require_positive_uint prefix_length "${prefix}" 8 30
    for key in server_ipv4 client_ipv4 router_ipv4; do
        ip="${LAN_CONFIG[${key}]}"
        lan_is_private_ipv4 "${ip}" || lan_die "${key} must be one exact RFC1918 IPv4 address"
        lan_is_host_address "${ip}" "${prefix}" || lan_die "${key} must not be a subnet or broadcast address"
    done
    [[ "${LAN_CONFIG[server_ipv4]}" != "${LAN_CONFIG[client_ipv4]}" && \
       "${LAN_CONFIG[server_ipv4]}" != "${LAN_CONFIG[router_ipv4]}" && \
       "${LAN_CONFIG[client_ipv4]}" != "${LAN_CONFIG[router_ipv4]}" ]] || \
        lan_die 'server, client and router addresses must be distinct'
    lan_same_subnet "${LAN_CONFIG[server_ipv4]}" "${LAN_CONFIG[client_ipv4]}" "${prefix}" || \
        lan_die 'server and client must be in the same configured subnet'
    lan_same_subnet "${LAN_CONFIG[server_ipv4]}" "${LAN_CONFIG[router_ipv4]}" "${prefix}" || \
        lan_die 'router must be in the same configured subnet'
    [[ "${LAN_CONFIG[server_wsl_mode]}" =~ ^(nat|mirrored)$ ]] || lan_die 'server_wsl_mode must be nat or mirrored'
    [[ "${LAN_CONFIG[client_wsl_mode]}" == nat ]] || lan_die 'Windows 10 client WSL mode must remain nat'
    [[ "${LAN_CONFIG[srt_udp_port]}" == 19000 ]] || lan_die 'LAN SRT laboratory reserve is UDP/19000'
    [[ "${LAN_CONFIG[moq_frontend_udp_port]}" == 14433 ]] || lan_die 'LAN MoQT frontend reserve is UDP/14433'
    [[ "${LAN_CONFIG[moq_backend_loopback_addr]}" == 127.0.0.1:4433 ]] || lan_die 'relay backend must remain loopback UDP/4433'
    [[ ${#LAN_CONFIG[moq_namespace]} -le 256 && "${LAN_CONFIG[moq_namespace]}" =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$ ]] || \
        lan_die 'moq_namespace must match the Gateway ASCII path contract (<=256 bytes, no empty/dot segments)'
    IFS='/' read -r -a namespace_segments <<<"${LAN_CONFIG[moq_namespace]}"
    for namespace_segment in "${namespace_segments[@]}"; do
        [[ "${namespace_segment}" != . && "${namespace_segment}" != .. ]] || lan_die 'moq_namespace dot segments are forbidden'
    done
    [[ "${LAN_CONFIG[player_loopback_tcp_port]}" == 3000 ]] || lan_die 'LAN standalone player loopback reserve is TCP/3000'
    lan_require_positive_uint proxy_max_clients "${LAN_CONFIG[proxy_max_clients]}" 1 25
    [[ "${LAN_CONFIG[proxy_association_margin]}" == 2 ]] || lan_die 'proxy technical association margin is fixed to two'
    lan_require_positive_uint proxy_idle_timeout_seconds "${LAN_CONFIG[proxy_idle_timeout_seconds]}" 5 120
    [[ "${LAN_CONFIG[dashboard_lan_enabled]}" == false ]] || \
        lan_die 'LAN dashboard is blocked until a reviewed TLS/read-only frontier exists'
    [[ "${LAN_CONFIG[supervisor_loopback_addr]}" == 127.0.0.1:9080 ]] || \
        lan_die 'supervisor must retain the loopback contract'
    [[ "${LAN_CONFIG[network_profile]}" =~ ^(Public|Private)$ ]] || \
        lan_die 'network_profile must be exactly Public or Private; Any and Domain are forbidden'
    [[ "${LAN_CONFIG[legacy_wildcard_conflicts_must_be_absent]}" == true ]] || \
        lan_die 'legacy wildcard conflict gate cannot be disabled'
    [[ "${LAN_CONFIG[relay_san_integration_status]}" =~ ^(pending_owner_integration|ready)$ ]] || \
        lan_die 'invalid relay SAN integration status'
    if [[ "${LAN_CONFIG[relay_san_integration_status]}" == ready ]]; then
        [[ "${LAN_CONFIG[relay_san_integration_commit]}" == 2f8fb1b3219483050bc997bee25a052c2db5f463 ]] || \
            lan_die 'ready relay LAN capability integration requires exact reviewed commit 2f8fb1b3219483050bc997bee25a052c2db5f463'
    else
        [[ "${LAN_CONFIG[relay_san_integration_commit]}" == unavailable ]] || \
            lan_die 'pending owner integration must not claim a commit'
    fi
    for key in pki_runtime_dir client_artifact_dir; do
        path="${LAN_CONFIG[${key}]}"
        [[ "${path}" == /* && "${path}" != *'/../'* && "${path}" != */.. ]] || \
            lan_die "${key} must be a traversal-free absolute path"
    done
    lan_require_positive_uint maximum_clock_offset_ms "${LAN_CONFIG[maximum_clock_offset_ms]}" 1 60000
    lan_require_positive_uint minimum_mtu "${LAN_CONFIG[minimum_mtu]}" 576 9000
    for key in server_minimum_cpu_cores client_minimum_cpu_cores; do
        lan_require_positive_uint "${key}" "${LAN_CONFIG[${key}]}" 1 1024
    done
    for key in server_minimum_memory_mib server_minimum_disk_mib client_minimum_memory_mib client_minimum_disk_mib; do
        lan_require_positive_uint "${key}" "${LAN_CONFIG[${key}]}" 1 1073741824
    done
    [[ "${LAN_CONFIG[wifi_minimum_ghz]}" == 5 ]] || lan_die 'Wi-Fi laboratory requires the 5 GHz gate'
}

lan_require_clean_integrated_source() {
    local repo="$1" source_commit="$2" owner_commit="$3"
    [[ "${repo}" == /* && -d "${repo}/.git" || "${repo}" == /* && -f "${repo}/.git" ]] || lan_die 'source repository path is invalid'
    [[ "$(git -C "${repo}" rev-parse HEAD 2>/dev/null)" == "${source_commit}" ]] || lan_die 'runtime source commit differs from exact local HEAD'
    git -C "${repo}" cat-file -e "${owner_commit}^{commit}" 2>/dev/null || lan_die 'owner integration commit is unavailable locally'
    git -C "${repo}" merge-base --is-ancestor "${owner_commit}" "${source_commit}" 2>/dev/null || \
        lan_die 'owner integration commit is not an ancestor of exact HEAD'
    [[ -z "$(git -C "${repo}" status --porcelain=v1 --untracked-files=all)" ]] || \
        lan_die 'runtime source worktree must be clean, including untracked files'
}
