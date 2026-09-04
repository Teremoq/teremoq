#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${TEST_DIR}/.." && pwd -P)"
policy_commit="$(printf 'a%.0s' {1..40})"
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
for file in "${TEST_DIR}"/Run-GitClientE2E.ps1 "${TEST_DIR}"/client-distribution-fixture.ps1; do
    TEREMOQ_PS_PARSE_FILE="${file}" WSLENV="TEREMOQ_PS_PARSE_FILE/p${WSLENV:+:${WSLENV}}" powershell.exe -NoProfile -NonInteractive -Command \
        '$errors=$null; $tokens=$null; [System.Management.Automation.Language.Parser]::ParseFile($env:TEREMOQ_PS_PARSE_FILE,[ref]$tokens,[ref]$errors) > $null; if($errors.Count -ne 0){$errors | ForEach-Object {Write-Error $_}; exit 1}' \
        >/dev/null
done
if rg -n '^\s*\$[A-Za-z0-9_]+\.ArgumentList\b' "${ROOT}/client"/*.ps1 >/dev/null; then
    printf 'powershell-policy-test: client runner uses ProcessStartInfo.ArgumentList, unsupported by Windows PowerShell 5\n' >&2
    exit 1
fi
grep -Fq 'Convert-TeremoqWindowsCommandLine -Arguments $Arguments' "${ROOT}/client/Client-Distribution.ps1"
grep -Fq 'New-TeremoqBoundedStreamState -Stream $process.StandardOutput.BaseStream' "${ROOT}/client/Client-Distribution.ps1"
grep -Fq 'New-TeremoqBoundedStreamState -Stream $process.StandardError.BaseStream' "${ROOT}/client/Client-Distribution.ps1"
client_distribution_fixture="$(wslpath -w "${TEST_DIR}/client-distribution-fixture.ps1")"
client_distribution="$(wslpath -w "${ROOT}/client/Client-Distribution.ps1")"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${client_distribution_fixture}" -ScriptPath "${client_distribution}" >/dev/null
grep -Fq 'Get-TeremoqExactWifiAdapter -InterfaceIndex $address.InterfaceIndex' "${ROOT}/windows/Preflight-Lan.ps1"
grep -Fq 'Get-TeremoqExactWifiAdapter -InterfaceIndex $address.InterfaceIndex' "${ROOT}/windows/Preflight-Client.ps1"
grep -Fq '/query /status /verbose' "${ROOT}/windows/Preflight-Lan.ps1"
grep -Fq '/query /status /verbose' "${ROOT}/windows/Preflight-Client.ps1"
grep -Fq 'Preflight-Contract.ps1' "${ROOT}/windows/Preflight-Lan.ps1"
grep -Fq 'Preflight-Contract.ps1' "${ROOT}/windows/Preflight-Client.ps1"
grep -Fq 'capture_context = $captureContext' "${ROOT}/windows/Preflight-Lan.ps1"
grep -Fq 'capture_context = $captureContext' "${ROOT}/windows/Preflight-Client.ps1"

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
    -Action Plan -RunId lan-firewall-test -SourceCommit "${policy_commit}" -ServerIPv4 "${server_ip}" -ClientIPv4 "${client_ip}" \
    -RouterIPv4 "${router_ip}" -PrefixLength "${prefix}" -NetworkProfile "${profile}" 2>/dev/null | tr -d '\r')"
[[ "${plan}" == *'New-NetFirewallRule'* && "${plan}" == *'New-NetFirewallHyperVRule'* ]]
[[ "${plan}" == *'-LocalAddress'* && "${plan}" == *'-RemoteAddress'* && "${plan}" == *'-LocalAddresses'* && "${plan}" == *'-RemoteAddresses'* ]]
[[ "${plan}" == *'UDP'* && "${plan}" == *'14433'* && "${plan}" == *'Remove-NetFirewallHyperVRule'* ]]
[[ "${plan}" != *'DefaultInboundAction'* || "${plan}" == *'do not change DefaultInboundAction'* ]]
if powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${firewall}" \
    -Action Validate -RunId lan-firewall-test -SourceCommit "${policy_commit}" -ServerIPv4 "${server_ip}" -ClientIPv4 "${router_ip}" \
    -RouterIPv4 "${router_ip}" -PrefixLength "${prefix}" -NetworkProfile "${profile}" >/dev/null 2>&1; then
    printf 'powershell-policy-test: router accepted as client\n' >&2; exit 1
fi
if powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${firewall}" \
    -Action Validate -RunId lan-firewall-test -SourceCommit "${policy_commit}" -ServerIPv4 192.168.77.0 -ClientIPv4 192.168.77.20 \
    -RouterIPv4 192.168.77.1 -PrefixLength 24 -NetworkProfile Public >/dev/null 2>&1; then
    printf 'powershell-policy-test: network address accepted as server\n' >&2; exit 1
fi
firewall_fixture="$(wslpath -w "${TEST_DIR}/firewall-verify-fixture.ps1")"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${firewall_fixture}" \
    -ScriptPath "${firewall}" -Tamper none \
    | tr -d '\r' | grep -Fq '"edge_traversal_policy":"Block"'
for tamper in edge cardinality; do
    if powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${firewall_fixture}" \
        -ScriptPath "${firewall}" -Tamper "${tamper}" >/dev/null 2>&1; then
        printf 'powershell-policy-test: firewall Verify accepted %s tamper\n' "${tamper}" >&2; exit 1
    fi
done
wlan_fixture="$(wslpath -w "${TEST_DIR}/preflight-contract-fixture.ps1")"
contract_helper="$(wslpath -w "${ROOT}/windows/Preflight-Contract.ps1")"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${wlan_fixture}" -ScriptPath "${contract_helper}" >/dev/null
wsl_plan="$(wslpath -w "${ROOT}/windows/Wsl-Mirrored-Plan.ps1")"
wsl_plan_output="$(powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${wsl_plan}" -Action Plan -RunId lan-firewall-test 2>/dev/null | tr -d '\r')"
grep -Fq 'networkingMode=mirrored' <<<"${wsl_plan_output}"
wsl_rollback_output="$(powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${wsl_plan}" -Action RollbackPlan -RunId lan-firewall-test 2>/dev/null | tr -d '\r')"
grep -Fq 'wsl.exe --shutdown' <<<"${wsl_rollback_output}"
client_preflight="$(wslpath -w "${ROOT}/windows/Preflight-Client.ps1")"
if powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${client_preflight}" \
    -RunId lan-policy-test -SourceCommit "${policy_commit}" -ServerIPv4 8.8.8.8 -ClientIPv4 192.168.77.20 -PrefixLength 24 -NetworkProfile Public -ExpectedWslMode nat \
    -MaximumClockOffsetMs 25 -MinimumMtu 1280 -MinimumCpuCores 2 -MinimumMemoryMiB 2048 -MinimumDiskMiB 4096 >/dev/null 2>&1; then
    printf 'powershell-policy-test: public server IP accepted by client preflight\n' >&2; exit 1
fi
if powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${client_preflight}" \
    -RunId lan-policy-test -SourceCommit "${policy_commit}" -ServerIPv4 192.168.77.0 -ClientIPv4 192.168.77.20 -PrefixLength 24 -NetworkProfile Public -ExpectedWslMode nat \
    -MaximumClockOffsetMs 25 -MinimumMtu 1280 -MinimumCpuCores 2 -MinimumMemoryMiB 2048 -MinimumDiskMiB 4096 >/dev/null 2>&1; then
    printf 'powershell-policy-test: network address accepted by client preflight\n' >&2; exit 1
fi
collector="$(wslpath -w "${ROOT}/windows/Collect-Evidence.ps1")"
if powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${collector}" \
    -Role Client -RunId lan-policy-test -SourceCommit "$(printf 'a%.0s' {1..40})" -Level 1 \
    -LocalIPv4 8.8.8.8 -PeerIPv4 192.168.77.10 -DurationSeconds 1 -EvidenceRoot 'C:\' >/dev/null 2>&1; then
    printf 'powershell-policy-test: collector accepted public local IP\n' >&2; exit 1
fi
commit="$(printf '1%.0s' {1..40})"
run_id='lan-contract-fixture'
mkdir -p -- "${scratch}/package" "${scratch}/evidence" "${scratch}/download" "${scratch}/light-download"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=powershell-policy-test-relay' \
    -keyout "${scratch}/ignored.key" -out "${scratch}/relay-cert.pem" >/dev/null 2>&1
openssl x509 -in "${scratch}/relay-cert.pem" -outform DER | sha256sum | awk '{print $1}' >"${scratch}/package/public-fingerprint.txt"
printf '{"schema_version":1,"run_id":"%s","source_commit":"%s","relay_url":"https://192.168.77.10:14433/watch","fingerprint_sha256":"%s","prefix_length":24,"namespace":"teremoq/live"}\n' \
    "${run_id}" \
    "${commit}" "$(cat "${scratch}/package/public-fingerprint.txt")" >"${scratch}/package/LAN-CONFIG.json"
config_sha="$(sha256sum "${scratch}/package/LAN-CONFIG.json" | awk '{print $1}')"
printf 'schema_version\t1\npackage_version\t0.1.0-lan\nrun_id\t%s\nsource_commit\t%s\nserver_ipv4\t192.168.77.10\nmoq_url\thttps://192.168.77.10:14433/watch\nplayer_manifest_sha256\t%s\nlauncher_contract_sha256\t%s\nlan_config_sha256\t%s\nplayer_evidence\tnot_measured\nload_launcher_status\tready\n' \
    "${run_id}" "${commit}" "$(printf 'c%.0s' {1..64})" "$(printf 'd%.0s' {1..64})" "${config_sha}" >"${scratch}/package/VERSION.tsv"
printf 'schema_version\t1\nrepository_url\thttps://github.com/Teremoq/teremoq\nrepository_ref\trefs/heads/codex/lan-e2e-lab\nrepository_subdirectory\tinfra/lan\nplayer_relative_path\tplayer\nallowed_client_commit\t%s\nsource_commit\t%s\npackage_version\t0.1.0-lan\nclient_protocol_version\tteremoq-lan-git-v2\nplayer_manifest_sha256\t%s\nlauncher_contract_sha256\t%s\nlan_config_sha256\t%s\n' \
    "${commit}" "${commit}" "$(printf 'c%.0s' {1..64})" "$(printf 'd%.0s' {1..64})" "${config_sha}" >"${scratch}/package/CLIENT-COMPATIBILITY.tsv"
mkdir -p -- "${scratch}/package/public-identity" "${scratch}/package/player"
cp -- "${scratch}/package/public-fingerprint.txt" "${scratch}/package/public-identity/relay-cert.sha256"
cp -- "${scratch}/relay-cert.pem" "${scratch}/package/public-identity/relay-cert.pem"
printf 'schema_version\t1\nsource_commit\t%s\nlauncher_relative_path\tStart-TeremoqLanLoad.ps1\nlauncher_sha256\t%s\nactions\tstart,status,stop,collect\nlevels\t1,5,10,25\nmax_clients\t25\nnetwork_contract\toutbound_udp_14433_only\nloopback_http_only\ttrue\n' \
    "${commit}" "$(printf 'e%.0s' {1..64})" >"${scratch}/package/player/lan-launcher.tsv"
printf '# launcher fixture\n' >"${scratch}/package/player/Start-TeremoqLanLoad.ps1"
printf '// start fixture\n' >"${scratch}/package/player/start.mjs"
python3 - "${scratch}/package/player" "${commit}" <<'PY'
import hashlib, json, pathlib, sys
root, commit = pathlib.Path(sys.argv[1]), sys.argv[2]
files = []
for name in ("Start-TeremoqLanLoad.ps1", "lan-launcher.tsv", "start.mjs"):
    data = (root / name).read_bytes()
    files.append({"path": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
manifest = {"schema_version": 1, "artifact": "teremoq-lan-lab-standalone", "package_version": "0.1.0-lan",
            "source_commit": commit, "entrypoint": "start.mjs", "files": files,
            "total_bytes": sum(item["bytes"] for item in files)}
(root / "MANIFEST.sha256.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
PY
launcher_sha="$(sha256sum "${scratch}/package/player/Start-TeremoqLanLoad.ps1" | awk '{print $1}')"
manifest_sha="$(sha256sum "${scratch}/package/player/MANIFEST.sha256.json" | awk '{print $1}')"
contract_sha="$(sha256sum "${scratch}/package/player/lan-launcher.tsv" | awk '{print $1}')"
awk -F '\t' -v OFS='\t' -v launcher="${launcher_sha}" '$1=="launcher_sha256" {$2=launcher} {print}' \
    "${scratch}/package/player/lan-launcher.tsv" >"${scratch}/package/player/lan-launcher.tsv.tmp"
mv "${scratch}/package/player/lan-launcher.tsv.tmp" "${scratch}/package/player/lan-launcher.tsv"
contract_sha="$(sha256sum "${scratch}/package/player/lan-launcher.tsv" | awk '{print $1}')"
awk -F '\t' -v OFS='\t' -v manifest="${manifest_sha}" -v contract="${contract_sha}" -v config="${config_sha}" '
    $1=="player_manifest_sha256" {$2=manifest}
    $1=="launcher_contract_sha256" {$2=contract}
    $1=="lan_config_sha256" {$2=config}
    {print}
' "${scratch}/package/VERSION.tsv" >"${scratch}/package/VERSION.tsv.tmp"
mv "${scratch}/package/VERSION.tsv.tmp" "${scratch}/package/VERSION.tsv"
awk -F '\t' -v OFS='\t' -v manifest="${manifest_sha}" -v contract="${contract_sha}" -v config="${config_sha}" '
    $1=="player_manifest_sha256" {$2=manifest}
    $1=="launcher_contract_sha256" {$2=contract}
    $1=="lan_config_sha256" {$2=config}
    {print}
' "${scratch}/package/CLIENT-COMPATIBILITY.tsv" >"${scratch}/package/CLIENT-COMPATIBILITY.tsv.tmp"
mv "${scratch}/package/CLIENT-COMPATIBILITY.tsv.tmp" "${scratch}/package/CLIENT-COMPATIBILITY.tsv"
(
    cd "${scratch}/package"
    find . -type f ! -name SHA256SUMS -print0 | sort -z | while IFS= read -r -d '' file; do
        sha256sum "${file#./}"
    done >SHA256SUMS
)
cp -- "${TEST_DIR}/fixtures/player-level-1.valid.json" "${scratch}/download/local-browser-observation-user-exported.json"
cp -- "${TEST_DIR}/fixtures/lightweight-level-5.valid.json" "${scratch}/light-download/local-browser-observation-user-exported.json"
[[ "$(sha256sum "${TEST_DIR}/fixtures/player-level-1.valid.json" | awk '{print $1}')" == 5f69843519ee19d190251ba93a992eb1e39c9a84a182aaa2a66f7ec41ea86a3f ]]
[[ "$(sha256sum "${TEST_DIR}/fixtures/lightweight-level-5.valid.json" | awk '{print $1}')" == 653ec1dbc1240564b3389b4148b9f2bfb6907026ff0ba2f296da50eb1eeb8d43 ]]
importer="$(wslpath -w "${ROOT}/client/Import-BrowserObservation.ps1")"
grep -Fq 'New-Object IO.FileStream($source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)' "${ROOT}/client/Import-BrowserObservation.ps1"
! grep -Eq 'Get-Content .*\$source|\[IO\.File\]::Copy\(\$source|Get-FileHash .*\$destination' "${ROOT}/client/Import-BrowserObservation.ps1"
# The exact FileShare.None primitive used by the importer must deny a writer
# while the single read handle remains open.
TEREMOQ_PS_LOCK_SOURCE="${scratch}/download/local-browser-observation-user-exported.json" \
    WSLENV="TEREMOQ_PS_LOCK_SOURCE/p${WSLENV:+:${WSLENV}}" powershell.exe -NoProfile -NonInteractive -Command '
$stream = New-Object IO.FileStream($env:TEREMOQ_PS_LOCK_SOURCE, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
try {
    $denied = $false
    try { [IO.File]::WriteAllText($env:TEREMOQ_PS_LOCK_SOURCE, "replacement") } catch [IO.IOException] { $denied = $true }
    if (-not $denied) { throw "exclusive import source handle allowed concurrent modification" }
} finally { $stream.Dispose() }
' >/dev/null
source_hash_before="$(sha256sum "${scratch}/download/local-browser-observation-user-exported.json" | awk '{print $1}')"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${importer}" \
    -SourcePath "$(wslpath -w "${scratch}/download/local-browser-observation-user-exported.json")" \
    -StateRoot "$(wslpath -w "${scratch}/package")" -EvidenceRoot "$(wslpath -w "${scratch}/evidence")" \
    -RunId "${run_id}" -Level 1 >/dev/null
imported="${scratch}/evidence/${run_id}/level-1/player-evidence.tsv"
imported_json="${scratch}/evidence/${run_id}/level-1/local-browser-observation-user-exported.json"
[[ -f "${imported}" && -f "${imported}.sha256" ]]
[[ -f "${imported_json}" && -f "${imported_json}.sha256" ]]
! grep -q $'\r' "${imported}"
cmp -- "${scratch}/download/local-browser-observation-user-exported.json" "${imported_json}"
source_hash_after="$(sha256sum "${scratch}/download/local-browser-observation-user-exported.json" | awk '{print $1}')"
destination_hash="$(sha256sum "${imported_json}" | awk '{print $1}')"
[[ "${source_hash_before}" == "${source_hash_after}" && "${source_hash_before}" == "${destination_hash}" ]]
grep -Fx "${destination_hash}  local-browser-observation-user-exported.json" "${imported_json}.sha256" >/dev/null
grep -Fx $'browser_observation_sha256\t'"${destination_hash}" "${imported}" >/dev/null
grep -Fx $'requested_sessions\t1' "${imported}" >/dev/null
grep -Fx $'frames_presented\t12000' "${imported}" >/dev/null
grep -Fx $'media_objects_received\t20000' "${imported}" >/dev/null
grep -Fx $'media_bytes_received\t2000000' "${imported}" >/dev/null
grep -Fx $'g2g_measurement_status\tnot_available' "${imported}" >/dev/null
grep -Fx $'session_recovery_count\t1' "${imported}" >/dev/null
grep -Fx $'wifi_recovery_armed\ttrue' "${imported}" >/dev/null
grep -Fx $'wifi_recovery_provenance\toperator-armed-browser-monotonic-session-loss-to-first-recovered-object' "${imported}" >/dev/null
grep -Fx $'evidence_origin\tlocal-browser-observation-user-exported' "${imported}" >/dev/null
light_evidence="${scratch}/light-evidence"
mkdir -- "${light_evidence}"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${importer}" \
    -SourcePath "$(wslpath -w "${scratch}/light-download/local-browser-observation-user-exported.json")" \
    -StateRoot "$(wslpath -w "${scratch}/package")" -EvidenceRoot "$(wslpath -w "${light_evidence}")" \
    -RunId "${run_id}" -Level 5 >/dev/null
light_tsv="${light_evidence}/${run_id}/level-5/player-evidence.tsv"
grep -Fx $'requested_sessions\t5' "${light_tsv}" >/dev/null
grep -Fx $'frames_presented\tnot_available' "${light_tsv}" >/dev/null
grep -Fx $'rx_to_canvas_p95_ms\tnot_available' "${light_tsv}" >/dev/null
grep -Fx $'g2g_measurement_status\tnot_available' "${light_tsv}" >/dev/null
grep -Fx $'wifi_recovery_ms\tnot_available' "${light_tsv}" >/dev/null
mkdir -p -- "${scratch}/legacy" "${scratch}/legacy-evidence"
printf '{"schema_version":1,"export_kind":"local-browser-observation-user-exported","run_id":"%s","source_commit":"%s","level":1,"duration_seconds":600,"frames_presented":100}\n' \
    "${run_id}" "${commit}" >"${scratch}/legacy/local-browser-observation-user-exported.json"
if powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${importer}" \
    -SourcePath "$(wslpath -w "${scratch}/legacy/local-browser-observation-user-exported.json")" \
    -StateRoot "$(wslpath -w "${scratch}/package")" -EvidenceRoot "$(wslpath -w "${scratch}/legacy-evidence")" \
    -RunId "${run_id}" -Level 1 >/dev/null 2>&1; then
    printf 'powershell-policy-test: obsolete Platform browser schema accepted\n' >&2; exit 1
fi
mkdir -p -- "${scratch}/unarmed" "${scratch}/unarmed-evidence"
sed 's/"wifi_recovery_armed": true/"wifi_recovery_armed": false/' \
    "${TEST_DIR}/fixtures/player-level-1.valid.json" >"${scratch}/unarmed/local-browser-observation-user-exported.json"
if powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${importer}" \
    -SourcePath "$(wslpath -w "${scratch}/unarmed/local-browser-observation-user-exported.json")" \
    -StateRoot "$(wslpath -w "${scratch}/package")" -EvidenceRoot "$(wslpath -w "${scratch}/unarmed-evidence")" \
    -RunId "${run_id}" -Level 1 >/dev/null 2>&1; then
    printf 'powershell-policy-test: unarmed Wi-Fi observation accepted\n' >&2; exit 1
fi
mkdir -p -- "${scratch}/oversized" "${scratch}/oversized-evidence"
head -c 65537 /dev/zero >"${scratch}/oversized/local-browser-observation-user-exported.json"
if powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${importer}" \
    -SourcePath "$(wslpath -w "${scratch}/oversized/local-browser-observation-user-exported.json")" \
    -StateRoot "$(wslpath -w "${scratch}/package")" -EvidenceRoot "$(wslpath -w "${scratch}/oversized-evidence")" \
    -RunId "${run_id}" -Level 1 >/dev/null 2>&1; then
    printf 'powershell-policy-test: oversized browser observation accepted\n' >&2; exit 1
fi
printf 'lan-powershell-policy-test: pass\n'
