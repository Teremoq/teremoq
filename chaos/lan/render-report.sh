#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
(( $# == 4 )) && [[ "$1" == --results && "$3" == --output ]] || lan_gate_die 'usage: render-report.sh --results ABSOLUTE_TSV --output ABSOLUTE_MD'
results="$2"; output="$4"
[[ "${output}" == /* && ! -e "${output}" && ! -L "${output}" ]] || lan_gate_die 'output must be a new absolute path'
lan_results_load "${results}"
mkdir -p -- "$(dirname -- "${output}")"
{
    printf '# Teremoq minimal LAN E2E result\n\n'
    printf -- '- Run ID: `%s`\n- Explicit local commit: `%s`\n- Level: `%s`\n' "${LAN_RESULTS[run_id]}" "${LAN_RESULTS[source_commit]}" "${LAN_RESULTS[level]}"
    printf -- '- Operator result / measurement kind / evidence quality: `%s` / `%s` / `%s`\n' "${LAN_RESULTS[result]}" "${LAN_RESULTS[measurement_kind]}" "${LAN_RESULTS[evidence_quality]}"
    printf -- '- Requested sessions / peak active sessions / duration seconds: `%s` / `%s` / `%s`\n' "${LAN_RESULTS[requested_sessions]}" "${LAN_RESULTS[active_sessions_peak]}" "${LAN_RESULTS[duration_seconds]}"
    printf -- '- Authorization scope / authenticated viewers measured: `%s` / `%s`\n\n' "${LAN_RESULTS[authorization_scope]}" "${LAN_RESULTS[authorized_viewers]}"
    printf '| Measurement | Value |\n| --- | ---: |\n'
    for key in clock_error_ms ingest_to_publish_p95_ms ingest_to_publish_source network_subscriber_p95_ms network_subscriber_source frames_presented media_objects_received media_session_source rx_to_canvas_p95_ms rx_to_canvas_source glass_to_glass_p95_ms glass_to_glass_source icmp_echo_loss_percent_approximation icmp_echo_jitter_ms_approximation network_probe_source server_cpu_peak_percent server_memory_peak_mib client_cpu_peak_percent client_memory_peak_mib server_bandwidth_peak_mbps client_bandwidth_peak_mbps host_resource_source wifi_recovery_ms wifi_recovery_source session_loss_count reconnect_count defender_firewall_rule_count_during_run hyperv_firewall_rule_count_during_run cleanup_processes cleanup_defender_firewall_rules cleanup_hyperv_firewall_rules network_probe_kind server_collector_sha256 client_collector_sha256 browser_observation_sha256 player_collector_sha256; do
        printf '| `%s` | `%s` |\n' "${key}" "${LAN_RESULTS[${key}]}"
    done
    printf '\n`not_measured`, `not_available`, `unavailable`, `simulated` and numeric real values retain distinct meanings. '
    printf 'One allowed client IP is not proof of authenticated-viewer authorization. This laboratory report is not a production, HA, capacity or latency-SLO claim. '
    if [[ "${LAN_RESULTS[visual_timecode_valid]}" != true || "${LAN_RESULTS[clocks_calibrated]}" != true ]]; then
        printf 'Glass-to-glass is not claimable without source timecode and calibrated clocks.\n'
    else
        printf 'Any glass-to-glass value is limited to the recorded source, clocks, network, load and duration.\n'
    fi
} >"${output}"
printf 'teremoq LAN report: %s\n' "${output}"
