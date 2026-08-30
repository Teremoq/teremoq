#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
umask 077

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${TEST_DIR}/.." && pwd -P)"
scratch="$(mktemp -d /tmp/teremoq-lan-gates-test.XXXXXX)"
trap 'find "${scratch}" -depth -delete' EXIT
commit="$(printf 'a%.0s' {1..40})"
package_hash="$(printf 'b%.0s' {1..64})"

make_results() {
    local level="$1" output="$2" server_sha="$3" client_sha="$4" player_sha="$5" browser_sha="$6"
    awk -F '\t' -v OFS='\t' -v level="${level}" -v commit="${commit}" -v package_hash="${package_hash}" -v server_sha="${server_sha}" -v client_sha="${client_sha}" -v player_sha="${player_sha}" -v browser_sha="${browser_sha}" '
        /^#/ {print; next}
        $1 == "run_id" {$2="lan-gate-" level}
        $1 == "source_commit" {$2=commit}
        $1 == "level" {$2=level}
        $1 == "result" {$2="pass"}
        $1 == "measurement_kind" {$2="real"}
        $1 == "requested_sessions" {$2=level}
        $1 == "active_sessions_peak" {$2=level}
        $1 == "authorization_scope" {$2="single_allowed_client_ip"}
        $1 == "authorized_viewers" {$2="not_measured"}
        $1 == "duration_seconds" {$2="600"}
        $1 == "approved_thresholds_id" {$2="approved-test-thresholds"}
        $1 == "g2g_measurement_status" {$2="not_available"}
        $1 == "clocks_calibrated" {$2="true"}
        $1 == "clock_error_ms" {$2="1.5"}
        $1 ~ /^(ingest_to_publish_p95_ms|ingest_to_publish_source|network_subscriber_p95_ms|network_subscriber_source)$/ {$2="not_measured"}
        $1 == "frames_presented" {$2=(level == 1 ? "100" : "not_available")}
        $1 == "media_objects_received" {$2="100"}
        $1 == "media_bytes_received" {$2="1000"}
        $1 == "media_session_source" {$2="local-browser-observation-user-exported"}
        $1 == "rx_to_canvas_p95_ms" {$2=(level == 1 ? "12.5" : "not_available")}
        $1 == "rx_to_canvas_source" {$2=(level == 1 ? "local-browser-observation-user-exported" : "not_available")}
        $1 == "glass_to_glass_p95_ms" {$2="not_available"}
        $1 == "glass_to_glass_source" {$2="not_available"}
        $1 ~ /^(icmp_echo_loss_percent_approximation|icmp_echo_jitter_ms_approximation|server_cpu_peak_percent|server_memory_peak_mib|client_cpu_peak_percent|client_memory_peak_mib|server_bandwidth_peak_mbps|client_bandwidth_peak_mbps)$/ {$2="1.0"}
        $1 == "wifi_recovery_status" {$2=(level == 1 ? "measured" : "not_available")}
        $1 ~ /^(wifi_recovery_armed|wifi_loss_observed|wifi_recovery_observed)$/ {$2=(level == 1 ? "true" : "not_available")}
        $1 == "wifi_recovery_ms" {$2=(level == 1 ? "1200" : "not_available")}
        $1 == "wifi_recovery_provenance" {$2=(level == 1 ? "operator-armed-browser-monotonic-session-loss-to-first-recovered-object" : "not_available")}
        $1 == "wifi_recovery_source" {$2=(level == 1 ? "local-browser-observation-user-exported" : "not_available")}
        $1 == "session_loss_count" {$2=(level == 1 ? "1" : "0")}
        $1 == "session_recovery_count" {$2=(level == 1 ? "1" : "0")}
        $1 ~ /^(defender|hyperv)_firewall_rule_count_during_run$/ {$2="1"}
        $1 ~ /^cleanup_/ {$2="0"}
        $1 == "package_sha256" {$2=package_hash}
        $1 == "server_collector_sha256" {$2=server_sha}
        $1 == "client_collector_sha256" {$2=client_sha}
        $1 == "player_collector_sha256" {$2=player_sha}
        $1 == "browser_observation_sha256" {$2=browser_sha}
        $1 == "network_probe_kind" {$2="icmp_echo_approximation_not_quic"}
        $1 == "network_probe_source" {$2="client_windows_collector"}
        $1 == "host_resource_source" {$2="server_client_windows_collectors"}
        $1 == "evidence_quality" {$2="real"}
        {print}
    ' "${ROOT}/results.example.tsv" >"${output}"
}

make_player_evidence() {
    local level="$1" output="$2" browser_sha="$3"
    cat >"${output}" <<EOF
schema_version	1
collector_id	teremoq-lan-player-v1
evidence_origin	local-browser-observation-user-exported
browser_observation_sha256	${browser_sha}
run_id	lan-gate-${level}
source_commit	${commit}
level	${level}
started_at_utc	2026-08-30T10:00:00.0000000Z
ended_at_utc	2026-08-30T10:10:00.0000000Z
duration_seconds	600
requested_sessions	${level}
active_sessions_peak	${level}
frames_presented	$(if [[ "${level}" == 1 ]]; then printf 100; else printf not_available; fi)
media_objects_received	100
media_bytes_received	1000
rx_to_canvas_p95_ms	$(if [[ "${level}" == 1 ]]; then printf 12.5; else printf not_available; fi)
g2g_measurement_status	not_available
glass_to_glass_p95_ms	not_available
session_loss_count	$(if [[ "${level}" == 1 ]]; then printf 1; else printf 0; fi)
session_recovery_count	$(if [[ "${level}" == 1 ]]; then printf 1; else printf 0; fi)
wifi_recovery_status	$(if [[ "${level}" == 1 ]]; then printf measured; else printf not_available; fi)
wifi_recovery_armed	$(if [[ "${level}" == 1 ]]; then printf true; else printf not_available; fi)
wifi_loss_observed	$(if [[ "${level}" == 1 ]]; then printf true; else printf not_available; fi)
wifi_recovery_observed	$(if [[ "${level}" == 1 ]]; then printf true; else printf not_available; fi)
wifi_recovery_ms	$(if [[ "${level}" == 1 ]]; then printf 1200; else printf not_available; fi)
wifi_recovery_provenance	$(if [[ "${level}" == 1 ]]; then printf operator-armed-browser-monotonic-session-loss-to-first-recovered-object; else printf not_available; fi)
evidence_quality	real
EOF
}

make_evidence() {
    local level="$1" role="$2" output="$3"
    cat >"${output}" <<EOF
schema_version	1
collector_id	teremoq-lan-windows-v1
run_id	lan-gate-${level}
source_commit	${commit}
level	${level}
role	${role}
local_ipv4	192.168.77.10
peer_ipv4	192.168.77.20
started_at_utc	2026-08-30T10:00:00.0000000Z
ended_at_utc	2026-08-30T10:10:00.0000000Z
duration_seconds	600
sample_count	600
network_probe_kind	icmp_echo_approximation_not_quic
icmp_echo_sent	600
icmp_echo_received	600
icmp_echo_loss_percent_approximation	1.0
icmp_echo_rtt_average_ms_approximation	1.0
icmp_echo_jitter_ms_approximation	1.0
clock_offset_ms	1.5
cpu_peak_percent	1.0
memory_peak_mib	1.0
adapter_bandwidth_peak_mbps	1.0
evidence_quality	real
EOF
}

previous=''
for level in 1 5 10 25; do
    result="${scratch}/${level}.tsv"
    export_dir="${scratch}/lan-gate-${level}/level-${level}"
    mkdir -p -- "${export_dir}"
    server_evidence="${export_dir}/server-host-evidence.tsv"
    client_evidence="${export_dir}/client-host-evidence.tsv"
    player_evidence="${export_dir}/player-evidence.tsv"
    browser_observation="${export_dir}/local-browser-observation-user-exported.json"
    make_evidence "${level}" server "${server_evidence}"
    make_evidence "${level}" client "${client_evidence}"
    printf '{"fixture":"browser-observation","level":%s}\n' "${level}" >"${browser_observation}"
    browser_sha="$(sha256sum "${browser_observation}" | awk '{print $1}')"
    printf '%s  %s\n' "${browser_sha}" "$(basename "${browser_observation}")" >"${browser_observation}.sha256"
    make_player_evidence "${level}" "${player_evidence}" "${browser_sha}"
    server_sha="$(sha256sum "${server_evidence}" | awk '{print $1}')"
    client_sha="$(sha256sum "${client_evidence}" | awk '{print $1}')"
    player_sha="$(sha256sum "${player_evidence}" | awk '{print $1}')"
    printf '%s  %s\n' "${server_sha}" "$(basename "${server_evidence}")" >"${server_evidence}.sha256"
    printf '%s  %s\n' "${client_sha}" "$(basename "${client_evidence}")" >"${client_evidence}.sha256"
    printf '%s  %s\n' "${player_sha}" "$(basename "${player_evidence}")" >"${player_evidence}.sha256"
    make_results "${level}" "${result}" "${server_sha}" "${client_sha}" "${player_sha}" "${browser_sha}"
    args=(--level "${level}" --results "${result}" --server-evidence "${server_evidence}" --client-evidence "${client_evidence}" --player-evidence "${player_evidence}")
    [[ -z "${previous}" ]] || args+=(--previous "${previous}")
    "${ROOT}/gate.sh" "${args[@]}" >/dev/null
    previous="${result}"
done
for blocked in 26 100 1000; do
    if "${ROOT}/gate.sh" --level "${blocked}" --results "${scratch}/25.tsv" --server-evidence "${scratch}/lan-gate-25/level-25/server-host-evidence.tsv" --client-evidence "${scratch}/lan-gate-25/level-25/client-host-evidence.tsv" --player-evidence "${scratch}/lan-gate-25/level-25/player-evidence.tsv" >/dev/null 2>&1; then
        printf 'gates-test: accepted blocked level %s\n' "${blocked}" >&2; exit 1
    fi
done
simulated="${scratch}/simulated.tsv"
awk -F '\t' -v OFS='\t' '$1=="measurement_kind" {$2="simulated"} {print}' "${scratch}/1.tsv" >"${simulated}"
if "${ROOT}/gate.sh" --level 1 --results "${simulated}" --server-evidence "${scratch}/lan-gate-1/level-1/server-host-evidence.tsv" --client-evidence "${scratch}/lan-gate-1/level-1/client-host-evidence.tsv" --player-evidence "${scratch}/lan-gate-1/level-1/player-evidence.tsv" >/dev/null 2>&1; then printf 'gates-test: simulation accepted\n' >&2; exit 1; fi
residue="${scratch}/residue.tsv"
awk -F '\t' -v OFS='\t' '$1=="cleanup_hyperv_firewall_rules" {$2="1"} {print}' "${scratch}/1.tsv" >"${residue}"
if "${ROOT}/gate.sh" --level 1 --results "${residue}" --server-evidence "${scratch}/lan-gate-1/level-1/server-host-evidence.tsv" --client-evidence "${scratch}/lan-gate-1/level-1/client-host-evidence.tsv" --player-evidence "${scratch}/lan-gate-1/level-1/player-evidence.tsv" >/dev/null 2>&1; then printf 'gates-test: residue accepted\n' >&2; exit 1; fi
report="${scratch}/report.md"
"${ROOT}/render-report.sh" --results "${ROOT}/results.example.tsv" --output "${report}" >/dev/null
grep -Fq '`not_measured`' "${report}"
grep -Fq 'not a production' "${report}"
printf 'lan-gates-test: pass\n'
