#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${TEST_DIR}/.." && pwd -P)"
if ! command -v powershell.exe >/dev/null 2>&1 || ! command -v wslpath >/dev/null 2>&1; then
    printf 'lan-powershell-policy-test: skipped (Windows PowerShell runtime unavailable)\n'
    exit 0
fi
scratch="$(mktemp -d /tmp/teremoq-lan-powershell-test.XXXXXX)"
trap 'find "${scratch}" -depth -delete' EXIT
for file in "${ROOT}"/windows/*.ps1 "${ROOT}"/client/*.ps1; do
    windows_file="$(wslpath -w "${file}")"
    TEREMOQ_PS_PARSE_FILE="${file}" WSLENV="TEREMOQ_PS_PARSE_FILE/p${WSLENV:+:${WSLENV}}" powershell.exe -NoProfile -NonInteractive -Command \
        '$errors=$null; $tokens=$null; [System.Management.Automation.Language.Parser]::ParseFile($env:TEREMOQ_PS_PARSE_FILE,[ref]$tokens,[ref]$errors) > $null; if($errors.Count -ne 0){$errors | ForEach-Object {Write-Error $_}; exit 1}' \
        >/dev/null
done

context="$(powershell.exe -NoProfile -NonInteractive -Command '
$profile = Get-NetConnectionProfile | Where-Object {$_.NetworkCategory -in @("Public","Private")} | Select-Object -First 1
if(-not $profile){exit 2}
$ip = Get-NetIPAddress -InterfaceIndex $profile.InterfaceIndex -AddressFamily IPv4 | Where-Object {$_.IPAddress -match "^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)"} | Select-Object -First 1
if(-not $ip){exit 3}
$route = Get-NetRoute -InterfaceIndex $profile.InterfaceIndex -DestinationPrefix "0.0.0.0/0" | Sort-Object RouteMetric | Select-Object -First 1
$parts = $ip.IPAddress.Split("."); $candidateLast = if($parts[3] -ne "254" -and $route.NextHop -notmatch "\.254$"){254}else{253}; $candidate = "$($parts[0]).$($parts[1]).$($parts[2]).$candidateLast"
Write-Output "$($ip.IPAddress)`t$candidate`t$($route.NextHop)`t$($ip.PrefixLength)`t$($profile.NetworkCategory)"' 2>/dev/null | tr -d '\r')"
IFS=$'\t' read -r server_ip client_ip router_ip prefix profile <<<"${context}"
[[ -n "${profile}" ]]
firewall="$(wslpath -w "${ROOT}/windows/Firewall-Lan.ps1")"
plan="$(powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${firewall}" \
    -Action Plan -RunId lan-firewall-test -ServerIPv4 "${server_ip}" -ClientIPv4 "${client_ip}" \
    -RouterIPv4 "${router_ip}" -PrefixLength "${prefix}" -NetworkProfile "${profile}" 2>/dev/null | tr -d '\r')"
[[ "${plan}" == *'New-NetFirewallRule'* && "${plan}" == *'New-NetFirewallHyperVRule'* ]]
[[ "${plan}" == *'-LocalAddress'* && "${plan}" == *'-RemoteAddress'* && "${plan}" == *'-LocalAddresses'* && "${plan}" == *'-RemoteAddresses'* ]]
[[ "${plan}" == *'UDP'* && "${plan}" == *'14433'* && "${plan}" == *'Remove-NetFirewallHyperVRule'* ]]
[[ "${plan}" != *'DefaultInboundAction'* || "${plan}" == *'do not change DefaultInboundAction'* ]]
if powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${firewall}" \
    -Action Validate -RunId lan-firewall-test -ServerIPv4 "${server_ip}" -ClientIPv4 "${router_ip}" \
    -RouterIPv4 "${router_ip}" -PrefixLength "${prefix}" -NetworkProfile "${profile}" >/dev/null 2>&1; then
    printf 'powershell-policy-test: router accepted as client\n' >&2; exit 1
fi
if powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${firewall}" \
    -Action Validate -RunId lan-firewall-test -ServerIPv4 192.168.77.0 -ClientIPv4 192.168.77.20 \
    -RouterIPv4 192.168.77.1 -PrefixLength 24 -NetworkProfile Public >/dev/null 2>&1; then
    printf 'powershell-policy-test: network address accepted as server\n' >&2; exit 1
fi
wsl_plan="$(wslpath -w "${ROOT}/windows/Wsl-Mirrored-Plan.ps1")"
wsl_plan_output="$(powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${wsl_plan}" -Action Plan -RunId lan-firewall-test 2>/dev/null | tr -d '\r')"
grep -Fq 'networkingMode=mirrored' <<<"${wsl_plan_output}"
wsl_rollback_output="$(powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${wsl_plan}" -Action RollbackPlan -RunId lan-firewall-test 2>/dev/null | tr -d '\r')"
grep -Fq 'wsl.exe --shutdown' <<<"${wsl_rollback_output}"
client_preflight="$(wslpath -w "${ROOT}/windows/Preflight-Client.ps1")"
if powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${client_preflight}" \
    -ServerIPv4 8.8.8.8 -ClientIPv4 192.168.77.20 -PrefixLength 24 -NetworkProfile Public -ExpectedWslMode nat >/dev/null 2>&1; then
    printf 'powershell-policy-test: public server IP accepted by client preflight\n' >&2; exit 1
fi
if powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${client_preflight}" \
    -ServerIPv4 192.168.77.0 -ClientIPv4 192.168.77.20 -PrefixLength 24 -NetworkProfile Public -ExpectedWslMode nat >/dev/null 2>&1; then
    printf 'powershell-policy-test: network address accepted by client preflight\n' >&2; exit 1
fi
collector="$(wslpath -w "${ROOT}/windows/Collect-Evidence.ps1")"
if powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${collector}" \
    -Role Client -RunId lan-policy-test -SourceCommit "$(printf 'a%.0s' {1..40})" -Level 1 \
    -LocalIPv4 8.8.8.8 -PeerIPv4 192.168.77.10 -DurationSeconds 1 -EvidenceRoot 'C:\' >/dev/null 2>&1; then
    printf 'powershell-policy-test: collector accepted public local IP\n' >&2; exit 1
fi
commit="$(printf 'a%.0s' {1..40})"
mkdir -p -- "${scratch}/package" "${scratch}/evidence" "${scratch}/download"
printf '{"schema_version":1,"run_id":"lan-import-test","source_commit":"%s","relay_url":"https://192.168.77.10:14433/watch","fingerprint_sha256":"%s","prefix_length":24,"namespace":"teremoq/live"}\n' \
    "${commit}" "$(printf 'b%.0s' {1..64})" >"${scratch}/package/LAN-CONFIG.json"
config_sha="$(sha256sum "${scratch}/package/LAN-CONFIG.json" | awk '{print $1}')"
printf 'source_commit\t%s\nrun_id\tlan-import-test\nlan_config_sha256\t%s\n' "${commit}" "${config_sha}" >"${scratch}/package/VERSION.tsv"
printf '{"schema_version":1,"export_kind":"local-browser-observation-user-exported","run_id":"lan-import-test","source_commit":"%s","level":1,"started_at_utc":"2026-08-30T10:00:00Z","ended_at_utc":"2026-08-30T10:10:00Z","duration_seconds":600,"requested_sessions":1,"active_sessions_peak":1,"frames_presented":100,"media_objects_received":100,"rx_to_canvas_samples":100,"rx_to_canvas_p95_ms":12.5,"visual_timecode_valid":false,"glass_to_glass_p95_ms":"not_measured","session_loss_count":0,"reconnect_count":1,"wifi_recovery_ms":1200}\n' \
    "${commit}" >"${scratch}/download/local-browser-observation-user-exported.json"
importer="$(wslpath -w "${ROOT}/client/Import-BrowserObservation.ps1")"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${importer}" \
    -SourcePath "$(wslpath -w "${scratch}/download/local-browser-observation-user-exported.json")" \
    -PackageRoot "$(wslpath -w "${scratch}/package")" -EvidenceRoot "$(wslpath -w "${scratch}/evidence")" \
    -RunId lan-import-test -Level 1 >/dev/null
imported="${scratch}/evidence/lan-import-test/level-1/player-evidence.tsv"
[[ -f "${imported}" && -f "${imported}.sha256" ]]
! grep -q $'\r' "${imported}"
grep -Fx $'requested_sessions\t1' "${imported}" >/dev/null
grep -Fx $'evidence_origin\tlocal-browser-observation-user-exported' "${imported}" >/dev/null
printf 'lan-powershell-policy-test: pass\n'
