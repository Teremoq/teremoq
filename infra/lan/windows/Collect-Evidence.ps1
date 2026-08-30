# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Server', 'Client')][string]$Role,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$SourceCommit,
    [Parameter(Mandatory = $true)][ValidateSet(1, 5, 10, 25)][int]$Level,
    [Parameter(Mandatory = $true)][string]$LocalIPv4,
    [Parameter(Mandatory = $true)][string]$PeerIPv4,
    [Parameter(Mandatory = $true)][ValidateRange(1, 3600)][int]$DurationSeconds,
    [ValidateRange(1, 10)][int]$SampleIntervalSeconds = 1,
    [Parameter(Mandatory = $true)][string]$EvidenceRoot
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Convert-ExactPrivateIPv4([string]$Name, [string]$Value) {
    $parsed = $null
    if ($Value.Contains('/') -or -not [Net.IPAddress]::TryParse($Value, [ref]$parsed) -or
        $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $parsed.IPAddressToString -ne $Value) { throw "$Name must be one exact canonical IPv4 address" }
    $bytes = $parsed.GetAddressBytes()
    $private = ($bytes[0] -eq 10) -or ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
        ($bytes[0] -eq 192 -and $bytes[1] -eq 168)
    if (-not $private -or $Value -eq '0.0.0.0' -or $Value -eq '255.255.255.255') { throw "$Name must be one unicast RFC1918 address" }
    return $parsed
}

if ($RunId -notmatch '^lan-[a-z0-9][a-z0-9-]{0,31}$') { throw 'invalid RunId' }
if ($SourceCommit -notmatch '^[0-9a-f]{40}$') { throw 'SourceCommit must be one explicit local commit' }
Convert-ExactPrivateIPv4 'LocalIPv4' $LocalIPv4 | Out-Null
Convert-ExactPrivateIPv4 'PeerIPv4' $PeerIPv4 | Out-Null
if ($LocalIPv4 -eq $PeerIPv4) { throw 'local and peer addresses must differ' }
if (-not [IO.Path]::IsPathRooted($EvidenceRoot) -or -not (Test-Path -LiteralPath $EvidenceRoot -PathType Container)) { throw 'EvidenceRoot must be an absolute existing directory' }
$rootItem = Get-Item -LiteralPath $EvidenceRoot
if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'EvidenceRoot may not be a reparse point' }
$exportDirectory = Join-Path (Join-Path $rootItem.FullName $RunId) "level-$Level"
$OutputPath = Join-Path $exportDirectory "$($Role.ToLowerInvariant())-host-evidence.tsv"
$ChecksumPath = "$OutputPath.sha256"
if ((Test-Path -LiteralPath $OutputPath) -or (Test-Path -LiteralPath $ChecksumPath)) { throw 'deterministic evidence output already exists' }
$localAddress = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $LocalIPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $localAddress) { throw 'LocalIPv4 is not assigned to this host' }
$adapter = Get-NetAdapter -InterfaceIndex $localAddress.InterfaceIndex -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $adapter) { throw 'cannot resolve the measured network adapter' }
$parent = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
$parentItem = Get-Item -LiteralPath $parent
if (($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'evidence export directory may not be a reparse point' }
$computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
$totalMemoryMiB = [double]$computer.TotalPhysicalMemory / 1MB
$ping = New-Object Net.NetworkInformation.Ping
$started = [DateTime]::UtcNow
$deadline = $started.AddSeconds($DurationSeconds)
$samples = 0
$sent = 0
$received = 0
$rtts = New-Object System.Collections.Generic.List[double]
$cpuPeak = $null
$memoryPeak = $null
$bandwidthPeak = $null
$previousStats = Get-NetAdapterStatistics -Name $adapter.Name -ErrorAction Stop
$previousAt = [DateTime]::UtcNow
while ([DateTime]::UtcNow -lt $deadline) {
    $sampleAt = [DateTime]::UtcNow
    $samples += 1
    $sent += 1
    try {
        $reply = $ping.Send($PeerIPv4, 1000)
        if ($reply.Status -eq [Net.NetworkInformation.IPStatus]::Success) {
            $received += 1
            $rtts.Add([double]$reply.RoundtripTime)
        }
    } catch { }
    $processor = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction SilentlyContinue
    if ($processor) {
        $cpu = [double]$processor.PercentProcessorTime
        if ($null -eq $cpuPeak -or $cpu -gt $cpuPeak) { $cpuPeak = $cpu }
    }
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) {
        $usedMemory = $totalMemoryMiB - ([double]$os.FreePhysicalMemory / 1024.0)
        if ($null -eq $memoryPeak -or $usedMemory -gt $memoryPeak) { $memoryPeak = $usedMemory }
    }
    $stats = Get-NetAdapterStatistics -Name $adapter.Name -ErrorAction SilentlyContinue
    if ($stats) {
        $seconds = [math]::Max(0.001, ($sampleAt - $previousAt).TotalSeconds)
        $bytes = ([double]$stats.ReceivedBytes + [double]$stats.SentBytes) -
            ([double]$previousStats.ReceivedBytes + [double]$previousStats.SentBytes)
        if ($bytes -ge 0) {
            $mbps = ($bytes * 8.0) / ($seconds * 1000000.0)
            if ($null -eq $bandwidthPeak -or $mbps -gt $bandwidthPeak) { $bandwidthPeak = $mbps }
        }
        $previousStats = $stats
        $previousAt = $sampleAt
    }
    $remaining = ($deadline - [DateTime]::UtcNow).TotalSeconds
    if ($remaining -gt 0) { Start-Sleep -Milliseconds ([int]([math]::Min($SampleIntervalSeconds, $remaining) * 1000)) }
}
$ended = [DateTime]::UtcNow
$clockText = (& w32tm.exe /stripchart /computer:$PeerIPv4 /dataonly /samples:1 2>$null | Out-String)
$clockOffsetMs = 'unavailable'
$clockMatches = [regex]::Matches($clockText, '[+-](?<seconds>[0-9]+[.,][0-9]+)s')
if ($clockMatches.Count -gt 0) {
    $secondsText = $clockMatches[$clockMatches.Count - 1].Groups['seconds'].Value.Replace(',', '.')
    $clockOffsetMs = [math]::Round(([double]::Parse($secondsText, [Globalization.CultureInfo]::InvariantCulture) * 1000.0), 3)
}
$loss = if ($sent -gt 0) { [math]::Round((1.0 - ($received / [double]$sent)) * 100.0, 3) } else { 'unavailable' }
$rttAverage = if ($rtts.Count -gt 0) { [math]::Round(($rtts | Measure-Object -Average).Average, 3) } else { 'unavailable' }
$jitter = 'unavailable'
if ($rtts.Count -gt 1) {
    $differences = for ($index = 1; $index -lt $rtts.Count; $index += 1) { [math]::Abs($rtts[$index] - $rtts[$index - 1]) }
    $jitter = [math]::Round(($differences | Measure-Object -Average).Average, 3)
}
function Measured($Value) { if ($null -eq $Value) { return 'unavailable' }; return [math]::Round([double]$Value, 3) }
$rows = [ordered]@{
    schema_version = '1'; collector_id = 'teremoq-lan-windows-v1'; run_id = $RunId
    source_commit = $SourceCommit; level = [string]$Level; role = $Role.ToLowerInvariant()
    local_ipv4 = $LocalIPv4; peer_ipv4 = $PeerIPv4
    started_at_utc = $started.ToString('o'); ended_at_utc = $ended.ToString('o')
    duration_seconds = [math]::Round(($ended - $started).TotalSeconds, 3); sample_count = $samples
    network_probe_kind = 'icmp_echo_approximation_not_quic'; icmp_echo_sent = $sent
    icmp_echo_received = $received; icmp_echo_loss_percent_approximation = $loss
    icmp_echo_rtt_average_ms_approximation = $rttAverage
    icmp_echo_jitter_ms_approximation = $jitter; clock_offset_ms = $clockOffsetMs
    cpu_peak_percent = (Measured $cpuPeak)
    memory_peak_mib = (Measured $memoryPeak); adapter_bandwidth_peak_mbps = (Measured $bandwidthPeak)
    evidence_quality = 'real'
}
$lines = foreach ($item in $rows.GetEnumerator()) { "$($item.Key)`t$($item.Value)" }
[IO.File]::WriteAllText($OutputPath, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
$digest = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($ChecksumPath, "$digest  $([IO.Path]::GetFileName($OutputPath))`n", (New-Object Text.UTF8Encoding($false)))
Write-Output "Teremoq LAN $Role evidence and SHA-256 sidecar written to the deterministic run/level export; ICMP fields are approximations and are not QUIC loss/jitter."
