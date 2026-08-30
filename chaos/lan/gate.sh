#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
level='' results='' previous='' server_evidence='' client_evidence='' player_evidence=''
while (( $# > 0 )); do
    case "$1" in
        --level) (( $# >= 2 )) || lan_gate_die '--level requires 1, 5, 10 or 25'; level="$2"; shift 2 ;;
        --results) (( $# >= 2 )) || lan_gate_die '--results requires a path'; results="$2"; shift 2 ;;
        --previous) (( $# >= 2 )) || lan_gate_die '--previous requires a path'; previous="$2"; shift 2 ;;
        --server-evidence) (( $# >= 2 )) || lan_gate_die '--server-evidence requires a path'; server_evidence="$2"; shift 2 ;;
        --client-evidence) (( $# >= 2 )) || lan_gate_die '--client-evidence requires a path'; client_evidence="$2"; shift 2 ;;
        --player-evidence) (( $# >= 2 )) || lan_gate_die '--player-evidence requires a path'; player_evidence="$2"; shift 2 ;;
        *) lan_gate_die "unknown gate argument: $1" ;;
    esac
done
[[ "${level}" =~ ^(1|5|10|25)$ ]] || lan_gate_die 'level allowlist is 1, 5, 10 or 25; values above 25 are blocked'
if [[ "${level}" == 1 ]]; then
    [[ -z "${previous}" ]] || lan_gate_die 'level 1 must not provide previous evidence'
else
    [[ -n "${previous}" ]] || lan_gate_die 'progressive levels require previous accepted evidence'
fi
lan_results_load "${results}"
lan_validate_gate_results "${level}"
[[ -n "${server_evidence}" && -n "${client_evidence}" && -n "${player_evidence}" ]] || lan_gate_die 'current server, client and player collector evidence are required'
lan_validate_evidence "${server_evidence}" server "${LAN_RESULTS[server_collector_sha256]}"
[[ "${LAN_EVIDENCE[cpu_peak_percent]}" == "${LAN_RESULTS[server_cpu_peak_percent]}" && \
   "${LAN_EVIDENCE[memory_peak_mib]}" == "${LAN_RESULTS[server_memory_peak_mib]}" && \
   "${LAN_EVIDENCE[adapter_bandwidth_peak_mbps]}" == "${LAN_RESULTS[server_bandwidth_peak_mbps]}" ]] || \
    lan_gate_die 'server measurable fields differ from collector evidence'
lan_validate_evidence "${client_evidence}" client "${LAN_RESULTS[client_collector_sha256]}"
[[ "${LAN_EVIDENCE[cpu_peak_percent]}" == "${LAN_RESULTS[client_cpu_peak_percent]}" && \
   "${LAN_EVIDENCE[memory_peak_mib]}" == "${LAN_RESULTS[client_memory_peak_mib]}" && \
   "${LAN_EVIDENCE[adapter_bandwidth_peak_mbps]}" == "${LAN_RESULTS[client_bandwidth_peak_mbps]}" && \
   "${LAN_EVIDENCE[clock_offset_ms]}" == "${LAN_RESULTS[clock_error_ms]}" && \
   "${LAN_EVIDENCE[icmp_echo_loss_percent_approximation]}" == "${LAN_RESULTS[icmp_echo_loss_percent_approximation]}" && \
   "${LAN_EVIDENCE[icmp_echo_jitter_ms_approximation]}" == "${LAN_RESULTS[icmp_echo_jitter_ms_approximation]}" ]] || \
    lan_gate_die 'client measurable fields differ from collector evidence'
lan_validate_player_evidence "${player_evidence}" "${LAN_RESULTS[player_collector_sha256]}"
[[ "${PLAYER_EVIDENCE[requested_sessions]}" == "${LAN_RESULTS[requested_sessions]}" && \
   "${PLAYER_EVIDENCE[active_sessions_peak]}" == "${LAN_RESULTS[active_sessions_peak]}" && \
   "${PLAYER_EVIDENCE[duration_seconds]}" == "${LAN_RESULTS[duration_seconds]}" && \
   "${PLAYER_EVIDENCE[frames_presented]}" == "${LAN_RESULTS[frames_presented]}" && \
   "${PLAYER_EVIDENCE[media_objects_received]}" == "${LAN_RESULTS[media_objects_received]}" && \
   "${PLAYER_EVIDENCE[rx_to_canvas_p95_ms]}" == "${LAN_RESULTS[rx_to_canvas_p95_ms]}" && \
   "${PLAYER_EVIDENCE[visual_timecode_valid]}" == "${LAN_RESULTS[visual_timecode_valid]}" && \
   "${PLAYER_EVIDENCE[glass_to_glass_p95_ms]}" == "${LAN_RESULTS[glass_to_glass_p95_ms]}" && \
   "${PLAYER_EVIDENCE[session_loss_count]}" == "${LAN_RESULTS[session_loss_count]}" && \
   "${PLAYER_EVIDENCE[reconnect_count]}" == "${LAN_RESULTS[reconnect_count]}" && \
   "${PLAYER_EVIDENCE[wifi_recovery_ms]}" == "${LAN_RESULTS[wifi_recovery_ms]}" ]] || \
    lan_gate_die 'player/session/phase fields differ from collector evidence'
current_commit="${LAN_RESULTS[source_commit]}"
if [[ -n "${previous}" ]]; then
    case "${level}" in 5) expected_previous=1 ;; 10) expected_previous=5 ;; 25) expected_previous=10 ;; esac
    lan_results_load "${previous}"
    lan_validate_gate_results "${expected_previous}"
    [[ "${LAN_RESULTS[source_commit]}" == "${current_commit}" ]] || lan_gate_die 'progression must use one explicit local commit'
fi
printf 'teremoq LAN gate %s: pass; real evidence accepted for progression\n' "${level}"
