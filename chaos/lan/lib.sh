#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0

lan_gate_die() {
    printf 'teremoq LAN gate: %s\n' "$*" >&2
    exit 2
}

lan_results_load() {
    local path="$1" line=0 key value extra required_key
    [[ "${path}" == /* && -f "${path}" && ! -L "${path}" ]] || lan_gate_die 'results must be an absolute regular non-symlink TSV file'
    LAN_RESULT_KEYS=(
        schema_version run_id source_commit level result measurement_kind
        requested_sessions active_sessions_peak authorization_scope authorized_viewers duration_seconds approved_thresholds_id
        visual_timecode_valid clocks_calibrated clock_error_ms ingest_to_publish_p95_ms ingest_to_publish_source
        network_subscriber_p95_ms network_subscriber_source frames_presented media_objects_received media_session_source
        rx_to_canvas_p95_ms rx_to_canvas_source glass_to_glass_p95_ms glass_to_glass_source
        icmp_echo_loss_percent_approximation icmp_echo_jitter_ms_approximation
        server_cpu_peak_percent server_memory_peak_mib client_cpu_peak_percent client_memory_peak_mib
        server_bandwidth_peak_mbps client_bandwidth_peak_mbps wifi_recovery_ms wifi_recovery_source
        session_loss_count reconnect_count defender_firewall_rule_count_during_run
        hyperv_firewall_rule_count_during_run cleanup_processes
        cleanup_defender_firewall_rules cleanup_hyperv_firewall_rules
        package_sha256 server_collector_sha256 client_collector_sha256 player_collector_sha256 browser_observation_sha256 network_probe_kind network_probe_source host_resource_source evidence_quality
    )
    declare -gA LAN_RESULTS=() LAN_RESULT_ALLOWED=()
    for required_key in "${LAN_RESULT_KEYS[@]}"; do LAN_RESULT_ALLOWED["${required_key}"]=1; done
    while IFS=$'\t' read -r key value extra || [[ -n "${key}${value}${extra}" ]]; do
        line=$(( line + 1 ))
        [[ -n "${key}" && "${key}" != \#* ]] || continue
        [[ -z "${extra}" && -n "${value}" ]] || lan_gate_die "results line ${line} must contain exactly two fields"
        [[ -n "${LAN_RESULT_ALLOWED[${key}]:-}" ]] || lan_gate_die "unknown results key: ${key}"
        [[ -z "${LAN_RESULTS[${key}]+present}" ]] || lan_gate_die "duplicate results key: ${key}"
        LAN_RESULTS["${key}"]="${value}"
    done <"${path}"
    for required_key in "${LAN_RESULT_KEYS[@]}"; do [[ -n "${LAN_RESULTS[${required_key}]:-}" ]] || lan_gate_die "missing results key: ${required_key}"; done
    (( ${#LAN_RESULTS[@]} == ${#LAN_RESULT_KEYS[@]} )) || lan_gate_die 'results key count mismatch'
}

lan_numeric() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

lan_uint() {
    [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]
}

lan_validate_timing() {
    local started="$1" ended="$2" duration="$3" started_epoch ended_epoch
    [[ "${started}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]{1,7})?Z$ && \
       "${ended}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]{1,7})?Z$ ]] || \
        lan_gate_die 'evidence timestamps must be explicit UTC ISO-8601 values'
    started_epoch="$(date -u -d "${started}" +%s 2>/dev/null)" || lan_gate_die 'invalid evidence start timestamp'
    ended_epoch="$(date -u -d "${ended}" +%s 2>/dev/null)" || lan_gate_die 'invalid evidence end timestamp'
    awk -v start="${started_epoch}" -v end="${ended_epoch}" -v observed="${duration}" \
        'BEGIN {delta=end-start; difference=delta-observed; if(difference<0) difference=-difference; exit !(delta >= 0 && difference <= 5)}' || \
        lan_gate_die 'evidence timestamps are incoherent with measured duration'
}

lan_validate_export_path_and_sidecar() {
    local path="$1" expected_name="$2" expected_sha="$3" parent run_parent sidecar sidecar_value
    [[ "$(basename -- "${path}")" == "${expected_name}" ]] || lan_gate_die 'evidence filename is outside the deterministic export contract'
    parent="$(dirname -- "${path}")"
    run_parent="$(dirname -- "${parent}")"
    [[ "$(basename -- "${parent}")" == "level-${LAN_RESULTS[level]}" && \
       "$(basename -- "${run_parent}")" == "${LAN_RESULTS[run_id]}" ]] || \
        lan_gate_die 'evidence path is not bound to the exact run/level export'
    sidecar="${path}.sha256"
    [[ -f "${sidecar}" && ! -L "${sidecar}" && $(stat -c %s -- "${sidecar}") -le 256 ]] || \
        lan_gate_die 'evidence SHA-256 sidecar is unavailable or unsafe'
    IFS= read -r sidecar_value <"${sidecar}" || lan_gate_die 'cannot read evidence SHA-256 sidecar'
    [[ "${sidecar_value}" == "${expected_sha}  ${expected_name}" ]] || lan_gate_die 'evidence SHA-256 sidecar/origin mismatch'
}

lan_validate_gate_results() {
    local requested_level="$1" key
    [[ "${requested_level}" =~ ^(1|5|10|25)$ ]] || lan_gate_die 'level allowlist is 1, 5, 10 or 25; values above 25 are blocked'
    [[ "${LAN_RESULTS[schema_version]}" == 1 ]] || lan_gate_die 'unsupported results schema'
    [[ "${LAN_RESULTS[level]}" == "${requested_level}" ]] || lan_gate_die 'results level mismatch'
    [[ "${LAN_RESULTS[run_id]}" =~ ^lan-[a-z0-9][a-z0-9-]{0,31}$ ]] || lan_gate_die 'invalid results run_id'
    [[ "${LAN_RESULTS[source_commit]}" =~ ^[0-9a-f]{40}$ ]] || lan_gate_die 'results require an explicit local commit'
    [[ "${LAN_RESULTS[result]}" == pass ]] || lan_gate_die 'operator result is not pass'
    [[ "${LAN_RESULTS[measurement_kind]}" == real && "${LAN_RESULTS[evidence_quality]}" == real ]] || \
        lan_gate_die 'simulated, unavailable or not_measured evidence cannot pass a real gate'
    [[ "${LAN_RESULTS[approved_thresholds_id]}" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || lan_gate_die 'approved thresholds identifier missing'
    [[ "${LAN_RESULTS[requested_sessions]}" == "${requested_level}" && \
       "${LAN_RESULTS[active_sessions_peak]}" == "${requested_level}" ]] || \
        lan_gate_die 'requested and peak active real sessions must equal the gate level'
    [[ "${LAN_RESULTS[authorization_scope]}" == single_allowed_client_ip && \
       "${LAN_RESULTS[authorized_viewers]}" == not_measured ]] || \
        lan_gate_die 'this LAN authorizes one client IP and may not claim authenticated viewers'
    lan_numeric "${LAN_RESULTS[duration_seconds]}" && \
        awk -v value="${LAN_RESULTS[duration_seconds]}" 'BEGIN {exit !(value >= 600)}' || \
        lan_gate_die 'each real gate requires at least 600 measured seconds'
    [[ "${LAN_RESULTS[visual_timecode_valid]}" =~ ^(true|false)$ && "${LAN_RESULTS[clocks_calibrated]}" =~ ^(true|false)$ ]] || \
        lan_gate_die 'timecode/clock flags must be true or false'
    for key in clock_error_ms \
        icmp_echo_loss_percent_approximation icmp_echo_jitter_ms_approximation \
        server_cpu_peak_percent server_memory_peak_mib client_cpu_peak_percent client_memory_peak_mib \
        server_bandwidth_peak_mbps client_bandwidth_peak_mbps \
        defender_firewall_rule_count_during_run hyperv_firewall_rule_count_during_run \
        cleanup_processes cleanup_defender_firewall_rules cleanup_hyperv_firewall_rules; do
        lan_numeric "${LAN_RESULTS[${key}]}" || lan_gate_die "${key} must be a measured numeric value"
    done
    lan_uint "${LAN_RESULTS[session_loss_count]}" || lan_gate_die 'session_loss_count must be a measured integer'
    lan_uint "${LAN_RESULTS[reconnect_count]}" || lan_gate_die 'reconnect_count must be a measured integer'
    [[ "${LAN_RESULTS[clocks_calibrated]}" == true ]] || lan_gate_die 'calibrated clocks and numeric error are required for phase evidence'
    lan_uint "${LAN_RESULTS[media_objects_received]}" && (( 10#${LAN_RESULTS[media_objects_received]} > 0 )) || lan_gate_die 'real received media object count must be a positive integer'
    [[ "${LAN_RESULTS[media_session_source]}" == local-browser-observation-user-exported ]] || lan_gate_die 'media/session fields must identify the raw browser observation source'
    if [[ "${requested_level}" == 1 ]]; then
        lan_uint "${LAN_RESULTS[frames_presented]}" && (( 10#${LAN_RESULTS[frames_presented]} > 0 )) || lan_gate_die 'level 1 requires positive integer presented frames'
        lan_numeric "${LAN_RESULTS[rx_to_canvas_p95_ms]}" || lan_gate_die 'level 1 requires measured RX-to-canvas p95'
        [[ "${LAN_RESULTS[rx_to_canvas_source]}" == local-browser-observation-user-exported ]] || lan_gate_die 'level 1 RX-to-canvas source mismatch'
    else
        [[ "${LAN_RESULTS[frames_presented]}" == not_available && "${LAN_RESULTS[rx_to_canvas_p95_ms]}" == not_available && \
           "${LAN_RESULTS[rx_to_canvas_source]}" == not_available ]] || \
            lan_gate_die 'lightweight levels do not render and must mark frame/RX-to-canvas fields not_available'
    fi
    [[ "${LAN_RESULTS[ingest_to_publish_p95_ms]}" == not_measured && "${LAN_RESULTS[ingest_to_publish_source]}" == not_measured ]] || \
        lan_gate_die 'ingest-to-publish needs a future hash-bound Gateway/server collector and is currently not_measured'
    [[ "${LAN_RESULTS[network_subscriber_p95_ms]}" == not_measured && "${LAN_RESULTS[network_subscriber_source]}" == not_measured ]] || \
        lan_gate_die 'network/subscriber latency is not instrumented and must remain not_measured'
    if [[ "${LAN_RESULTS[visual_timecode_valid]}" == true ]]; then
        lan_numeric "${LAN_RESULTS[glass_to_glass_p95_ms]}" || lan_gate_die 'glass-to-glass must be numeric when source timecode exists'
        [[ "${LAN_RESULTS[glass_to_glass_source]}" == local-browser-observation-user-exported ]] || lan_gate_die 'glass-to-glass source mismatch'
    else
        [[ "${LAN_RESULTS[glass_to_glass_p95_ms]}" == not_measured && "${LAN_RESULTS[glass_to_glass_source]}" == not_measured ]] || lan_gate_die 'glass-to-glass must be not_measured without source timecode'
    fi
    if [[ "${requested_level}" == 1 ]]; then
        lan_numeric "${LAN_RESULTS[wifi_recovery_ms]}" || lan_gate_die 'manual Wi-Fi recovery must be measured at level 1'
        [[ "${LAN_RESULTS[wifi_recovery_source]}" == local-browser-observation-user-exported ]] || lan_gate_die 'Wi-Fi recovery source mismatch'
    else
        [[ "${LAN_RESULTS[wifi_recovery_ms]}" == not_measured && "${LAN_RESULTS[wifi_recovery_source]}" == not_measured ]] || lan_gate_die 'higher-level Wi-Fi recovery must remain not_measured'
    fi
    [[ "${LAN_RESULTS[cleanup_processes]}" == 0 && \
       "${LAN_RESULTS[cleanup_defender_firewall_rules]}" == 0 && \
       "${LAN_RESULTS[cleanup_hyperv_firewall_rules]}" == 0 ]] || \
        lan_gate_die 'process, Defender or Hyper-V cleanup residue blocks progression'
    [[ "${LAN_RESULTS[defender_firewall_rule_count_during_run]}" == 1 && \
       "${LAN_RESULTS[hyperv_firewall_rule_count_during_run]}" == 1 ]] || \
        lan_gate_die 'one exact Defender rule and one exact Hyper-V rule are required'
    [[ "${LAN_RESULTS[package_sha256]}" =~ ^[0-9a-f]{64}$ ]] || lan_gate_die 'client package checksum is missing'
    [[ "${LAN_RESULTS[server_collector_sha256]}" =~ ^[0-9a-f]{64}$ && \
       "${LAN_RESULTS[client_collector_sha256]}" =~ ^[0-9a-f]{64}$ && \
       "${LAN_RESULTS[player_collector_sha256]}" =~ ^[0-9a-f]{64}$ && \
       "${LAN_RESULTS[browser_observation_sha256]}" =~ ^[0-9a-f]{64}$ ]] || \
        lan_gate_die 'server, client, player and browser observation provenance hashes are required'
    [[ "${LAN_RESULTS[network_probe_kind]}" == icmp_echo_approximation_not_quic ]] || \
        lan_gate_die 'network loss/jitter may only be reported as the bounded ICMP approximation'
    [[ "${LAN_RESULTS[network_probe_source]}" == client_windows_collector && \
       "${LAN_RESULTS[host_resource_source]}" == server_client_windows_collectors ]] || \
        lan_gate_die 'network/resource field provenance is missing'
}

lan_validate_player_evidence() {
    local path="$1" expected_sha="$2" actual_sha line=0 key value extra required_key
    [[ "${path}" == /* && -f "${path}" && ! -L "${path}" ]] || lan_gate_die 'player evidence must be an absolute regular non-symlink TSV file'
    lan_validate_export_path_and_sidecar "${path}" player-evidence.tsv "${expected_sha}"
    PLAYER_EVIDENCE_KEYS=(schema_version collector_id evidence_origin browser_observation_sha256 run_id source_commit level started_at_utc ended_at_utc duration_seconds requested_sessions active_sessions_peak frames_presented media_objects_received rx_to_canvas_samples rx_to_canvas_p95_ms visual_timecode_valid glass_to_glass_p95_ms session_loss_count reconnect_count wifi_recovery_ms evidence_quality)
    declare -gA PLAYER_EVIDENCE=() PLAYER_EVIDENCE_ALLOWED=()
    for required_key in "${PLAYER_EVIDENCE_KEYS[@]}"; do PLAYER_EVIDENCE_ALLOWED["${required_key}"]=1; done
    while IFS=$'\t' read -r key value extra || [[ -n "${key}${value}${extra}" ]]; do
        line=$(( line + 1 )); [[ -n "${key}" && "${key}" != \#* ]] || continue
        [[ -z "${extra}" && -n "${value}" && -n "${PLAYER_EVIDENCE_ALLOWED[${key}]:-}" && -z "${PLAYER_EVIDENCE[${key}]+present}" ]] || lan_gate_die "invalid player evidence line ${line}"
        PLAYER_EVIDENCE["${key}"]="${value}"
    done <"${path}"
    for required_key in "${PLAYER_EVIDENCE_KEYS[@]}"; do [[ -n "${PLAYER_EVIDENCE[${required_key}]:-}" ]] || lan_gate_die "missing player evidence key: ${required_key}"; done
    actual_sha="$(sha256sum "${path}" | awk '{print $1}')"
    [[ "${actual_sha}" == "${expected_sha}" && "${PLAYER_EVIDENCE[schema_version]}" == 1 && \
       "${PLAYER_EVIDENCE[collector_id]}" == teremoq-lan-player-v1 && \
       "${PLAYER_EVIDENCE[evidence_origin]}" == local-browser-observation-user-exported && \
       "${PLAYER_EVIDENCE[browser_observation_sha256]}" == "${LAN_RESULTS[browser_observation_sha256]}" && \
       "${PLAYER_EVIDENCE[evidence_quality]}" == real ]] || \
        lan_gate_die 'player collector identity, quality or SHA-256 mismatch'
    [[ "${PLAYER_EVIDENCE[run_id]}" == "${LAN_RESULTS[run_id]}" && \
       "${PLAYER_EVIDENCE[source_commit]}" == "${LAN_RESULTS[source_commit]}" && \
       "${PLAYER_EVIDENCE[level]}" == "${LAN_RESULTS[level]}" ]] || lan_gate_die 'player collector run binding mismatch'
    local browser_observation="$(dirname -- "${path}")/local-browser-observation-user-exported.json" browser_actual
    [[ -f "${browser_observation}" && ! -L "${browser_observation}" ]] || lan_gate_die 'raw browser observation is absent from the deterministic export'
    browser_actual="$(sha256sum "${browser_observation}" | awk '{print $1}')"
    lan_validate_export_path_and_sidecar "${browser_observation}" local-browser-observation-user-exported.json "${browser_actual}"
    [[ "${browser_actual}" == "${PLAYER_EVIDENCE[browser_observation_sha256]}" ]] || lan_gate_die 'browser observation provenance hash mismatch'
    lan_validate_timing "${PLAYER_EVIDENCE[started_at_utc]}" "${PLAYER_EVIDENCE[ended_at_utc]}" "${PLAYER_EVIDENCE[duration_seconds]}"
    for key in requested_sessions active_sessions_peak media_objects_received session_loss_count reconnect_count; do
        lan_uint "${PLAYER_EVIDENCE[${key}]}" || lan_gate_die "player count is not an integer: ${key}"
    done
    lan_numeric "${PLAYER_EVIDENCE[duration_seconds]}" || lan_gate_die 'player duration is not measured'
    awk -v value="${PLAYER_EVIDENCE[duration_seconds]}" 'BEGIN {exit !(value >= 600)}' || lan_gate_die 'player duration is shorter than 600 seconds'
    (( 10#${PLAYER_EVIDENCE[media_objects_received]} > 0 )) || lan_gate_die 'player received no real media objects'
    if [[ "${PLAYER_EVIDENCE[level]}" == 1 ]]; then
        lan_uint "${PLAYER_EVIDENCE[frames_presented]}" && (( 10#${PLAYER_EVIDENCE[frames_presented]} > 0 )) || lan_gate_die 'level 1 player presented no real frames'
        lan_uint "${PLAYER_EVIDENCE[rx_to_canvas_samples]}" && (( 10#${PLAYER_EVIDENCE[rx_to_canvas_samples]} > 0 )) || lan_gate_die 'level 1 player has no RX-to-canvas samples'
        lan_numeric "${PLAYER_EVIDENCE[rx_to_canvas_p95_ms]}" || lan_gate_die 'level 1 RX-to-canvas p95 is not measured'
    else
        [[ "${PLAYER_EVIDENCE[frames_presented]}" == not_available && "${PLAYER_EVIDENCE[rx_to_canvas_samples]}" == not_available && \
           "${PLAYER_EVIDENCE[rx_to_canvas_p95_ms]}" == not_available ]] || \
            lan_gate_die 'lightweight player evidence must mark render metrics not_available'
    fi
    [[ "${PLAYER_EVIDENCE[visual_timecode_valid]}" =~ ^(true|false)$ ]] || lan_gate_die 'invalid player visual_timecode flag'
    if [[ "${PLAYER_EVIDENCE[visual_timecode_valid]}" == true ]]; then
        lan_numeric "${PLAYER_EVIDENCE[glass_to_glass_p95_ms]}" || lan_gate_die 'player glass-to-glass must be numeric with timecode'
    else
        [[ "${PLAYER_EVIDENCE[glass_to_glass_p95_ms]}" == not_measured ]] || lan_gate_die 'player falsely claims glass-to-glass without timecode'
    fi
    if [[ "${PLAYER_EVIDENCE[level]}" == 1 ]]; then
        lan_numeric "${PLAYER_EVIDENCE[wifi_recovery_ms]}" || lan_gate_die 'level 1 player evidence must measure manual Wi-Fi recovery'
    else
        [[ "${PLAYER_EVIDENCE[wifi_recovery_ms]}" == not_measured || "${PLAYER_EVIDENCE[wifi_recovery_ms]}" =~ ^[0-9]+([.][0-9]+)?$ ]] || lan_gate_die 'invalid player Wi-Fi recovery evidence'
    fi
}

lan_evidence_load() {
    local path="$1" line=0 key value extra required_key
    [[ "${path}" == /* && -f "${path}" && ! -L "${path}" ]] || lan_gate_die 'collector evidence must be an absolute regular non-symlink TSV file'
    LAN_EVIDENCE_KEYS=(
        schema_version collector_id run_id source_commit level role local_ipv4 peer_ipv4
        started_at_utc ended_at_utc duration_seconds sample_count network_probe_kind
        icmp_echo_sent icmp_echo_received icmp_echo_loss_percent_approximation
        icmp_echo_rtt_average_ms_approximation icmp_echo_jitter_ms_approximation
        clock_offset_ms cpu_peak_percent memory_peak_mib adapter_bandwidth_peak_mbps evidence_quality
    )
    declare -gA LAN_EVIDENCE=() LAN_EVIDENCE_ALLOWED=()
    for required_key in "${LAN_EVIDENCE_KEYS[@]}"; do LAN_EVIDENCE_ALLOWED["${required_key}"]=1; done
    while IFS=$'\t' read -r key value extra || [[ -n "${key}${value}${extra}" ]]; do
        line=$(( line + 1 ))
        [[ -n "${key}" && "${key}" != \#* ]] || continue
        [[ -z "${extra}" && -n "${value}" ]] || lan_gate_die "collector line ${line} must contain exactly two fields"
        [[ -n "${LAN_EVIDENCE_ALLOWED[${key}]:-}" && -z "${LAN_EVIDENCE[${key}]+present}" ]] || lan_gate_die "unknown or duplicate collector key: ${key}"
        LAN_EVIDENCE["${key}"]="${value}"
    done <"${path}"
    for required_key in "${LAN_EVIDENCE_KEYS[@]}"; do [[ -n "${LAN_EVIDENCE[${required_key}]:-}" ]] || lan_gate_die "missing collector key: ${required_key}"; done
}

lan_validate_evidence() {
    local path="$1" role="$2" expected_sha="$3" actual_sha key
    lan_validate_export_path_and_sidecar "${path}" "${role}-host-evidence.tsv" "${expected_sha}"
    lan_evidence_load "${path}"
    actual_sha="$(sha256sum "${path}" | awk '{print $1}')"
    [[ "${actual_sha}" == "${expected_sha}" ]] || lan_gate_die "${role} collector SHA-256 mismatch"
    [[ "${LAN_EVIDENCE[schema_version]}" == 1 && "${LAN_EVIDENCE[collector_id]}" == teremoq-lan-windows-v1 && \
       "${LAN_EVIDENCE[role]}" == "${role}" && "${LAN_EVIDENCE[evidence_quality]}" == real ]] || \
        lan_gate_die "${role} collector identity/quality mismatch"
    [[ "${LAN_EVIDENCE[run_id]}" == "${LAN_RESULTS[run_id]}" && \
       "${LAN_EVIDENCE[source_commit]}" == "${LAN_RESULTS[source_commit]}" && \
       "${LAN_EVIDENCE[level]}" == "${LAN_RESULTS[level]}" ]] || lan_gate_die "${role} collector run binding mismatch"
    [[ "${LAN_EVIDENCE[network_probe_kind]}" == icmp_echo_approximation_not_quic ]] || lan_gate_die "${role} collector falsely labels network evidence"
    for key in duration_seconds sample_count icmp_echo_sent icmp_echo_received \
        icmp_echo_loss_percent_approximation icmp_echo_rtt_average_ms_approximation \
        icmp_echo_jitter_ms_approximation clock_offset_ms cpu_peak_percent memory_peak_mib adapter_bandwidth_peak_mbps; do
        lan_numeric "${LAN_EVIDENCE[${key}]}" || lan_gate_die "${role} collector field is not measured: ${key}"
    done
    lan_validate_timing "${LAN_EVIDENCE[started_at_utc]}" "${LAN_EVIDENCE[ended_at_utc]}" "${LAN_EVIDENCE[duration_seconds]}"
    awk -v observed="${LAN_EVIDENCE[duration_seconds]}" -v required="${LAN_RESULTS[duration_seconds]}" \
        'BEGIN {exit !(observed >= required)}' || lan_gate_die "${role} collector duration is shorter than the accepted run"
}
