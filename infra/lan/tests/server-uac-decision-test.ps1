# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
# Pure synthetic tests only. Never invoke the live preflight or firewall.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot '..\windows\Server-Uac-Capture.ps1')
function Assert-Rejected([scriptblock]$Action) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Negative UAC fixture unexpectedly accepted' }
}
$names = @('windows_caption','windows_version','configured_private_ip_present','network_profile',
    'capture_origin','wifi_adapter','wifi_link_speed','wifi_radio','wifi_band','wsl_mode','expected_wsl_mode_gate',
    'clock_offset','mtu','logical_cpu','physical_memory_mib','free_disk_mib','browser_msedge.exe','browser_chrome.exe',
    'docker_server','docker_publication_inventory','wslconfig_present','preflight_gate',
    'listener_udp_4433','listener_udp_9000','listener_udp_14433','listener_udp_19000',
    'listener_tcp_4433','listener_tcp_5678','listener_tcp_6379','listener_tcp_11434','listener_tcp_18443')
$checks = @($names | ForEach-Object {
    $status = if ($_ -cin @('capture_origin','preflight_gate')) { 'blocked' } else { 'pass' }
    $value = if ($_ -ceq 'capture_origin') { 'wsl_or_ambiguous_capture' } elseif ($_ -ceq 'preflight_gate') { 'blocked' } else { 'fixture' }
    [ordered]@{check=$_;status=$status;value=$value;evidence_quality='real'}
})
$report = [ordered]@{
    schema_version=2;report_kind='teremoq-lan-windows-preflight-v2';run_id='lan-synthetic-uac';source_commit=('a'*40)
    role='server';server_ipv4='192.168.77.10';client_ipv4='192.168.77.20';prefix_length=24;network_profile='Public'
    expected_wsl_mode='mirrored';maximum_clock_offset_ms=2000;minimum_mtu=1280;minimum_cpu_cores=2
    minimum_memory_mib=2048;minimum_disk_mib=1024
    capture_context=[ordered]@{schema_version=2;current_process_name='powershell.exe';parent_process_names=@()
        parent_process_count=0;traversal_depth_limit=16;traversal_outcome='parent_process_missing'
        wsl_environment_keys_present=@();powershell_edition='Desktop';powershell_version_major=5}
    checks=$checks
}
$evidence = [ordered]@{
    collector='preflight-lan-same-process-v1';elevated=$true;architecture='x64'
    host_path='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    host_sha256='3247bcfd60f6dd25f34cb74b5889ab10ef1b3ec72b4d4b3d95b5b25b534560b8'
    checkout_kind='local-clean-git';source_commit=('a'*40);configuration_binding='original-report-sha256'
}
($checks | Where-Object { $_.check -ceq 'configured_private_ip_present' }).value = $report.server_ipv4
$raw = ($report | ConvertTo-Json -Depth 6) + "`n"
$decision = New-TeremoqServerUacDecision -RawReport $raw -Evidence $evidence
if ($decision.raw_preflight_utf8 -cne $raw -or $decision.disposition -cne 'warning:verified-elevated-host-parent-unobserved') {
    throw 'Original bytes or warning disposition changed'
}
foreach ($mutation in @(@('elevated',$false),@('elevated',1),@('host_sha256',('b'*64)),
    @('architecture','arm64'),@('host_path','C:\Temp\powershell.exe'),@('source_commit',('b'*40)))) {
    $copy = [ordered]@{};foreach($key in $evidence.Keys){$copy[$key]=$evidence[$key]};$copy[$mutation[0]]=$mutation[1]
    Assert-Rejected { New-TeremoqServerUacDecision -RawReport $raw -Evidence $copy }
}
foreach ($mutation in @(@('wsl_environment_keys_present',@('WSL_INTEROP')),@('parent_process_names',@('explorer.exe')),
    @('parent_process_count',$false),@('traversal_outcome','cim_query_failed'),@('powershell_edition','Core'))) {
    $copy = $raw | ConvertFrom-Json
    $copy.capture_context.($mutation[0])=$mutation[1]
    Assert-Rejected { New-TeremoqServerUacDecision -RawReport ($copy|ConvertTo-Json -Depth 6) -Evidence $evidence }
}
$copy = $raw | ConvertFrom-Json
$copy.checks[0].status='blocked'
Assert-Rejected { New-TeremoqServerUacDecision -RawReport ($copy|ConvertTo-Json -Depth 6) -Evidence $evidence }
$copy = $raw | ConvertFrom-Json
$copy.checks=@($copy.checks | Select-Object -Skip 1)
Assert-Rejected { New-TeremoqServerUacDecision -RawReport ($copy|ConvertTo-Json -Depth 6) -Evidence $evidence }
Assert-Rejected { New-TeremoqServerUacDecision -RawReport (' '*24577) -Evidence $evidence }
Write-Output 'PASS: synthetic UAC warning, byte preservation and negative boundaries; no live origin claim'
