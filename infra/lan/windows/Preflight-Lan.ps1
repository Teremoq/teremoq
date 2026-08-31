# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Server', 'Client')][string]$Role,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$SourceCommit,
    [Parameter(Mandatory = $true)][string]$ServerIPv4,
    [Parameter(Mandatory = $true)][string]$ClientIPv4,
    [Parameter(Mandatory = $true)][ValidateRange(8, 30)][int]$PrefixLength,
    [Parameter(Mandatory = $true)][ValidateSet('Public', 'Private')][string]$NetworkProfile,
    [Parameter(Mandatory = $true)][ValidateSet('nat', 'mirrored')][string]$ExpectedWslMode,
    [Parameter(Mandatory = $true)][ValidateRange(1, 60000)][int]$MaximumClockOffsetMs,
    [Parameter(Mandatory = $true)][ValidateRange(576, 9000)][int]$MinimumMtu,
    [Parameter(Mandatory = $true)][ValidateRange(1, 1024)][int]$MinimumCpuCores,
    [Parameter(Mandatory = $true)][ValidateRange(1, 1073741824)][int]$MinimumMemoryMiB,
    [Parameter(Mandatory = $true)][ValidateRange(1, 1073741824)][int]$MinimumDiskMiB,
    [ValidateRange(1, 65535)][int]$MoqUdpPort = 14433,
    [ValidateRange(1, 65535)][int]$SrtUdpPort = 19000
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot 'Preflight-Contract.ps1')
$checks = New-Object System.Collections.Generic.List[object]
$script:PreflightBlocked = $false
$captureContext = Get-TeremoqCaptureContext
$nativeCapture = Test-TeremoqCaptureContextEvidence -Context $captureContext

function Add-Check([string]$Name, [string]$Status, $Value, [string]$Quality) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { $Value = 'unavailable'; $Quality = 'unavailable' }
    if ($Name -ne 'preflight_gate' -and ($Status -notin @('pass', 'observed') -or $Quality -notin @('real', 'configured') -or
        [string]$Value -match '(?i)(^|[^a-z])(blocked|pending|unavailable|unknown|not_measured|occupied)($|[^a-z])')) {
        $script:PreflightBlocked = $true
    }
    $checks.Add([pscustomobject]@{ check = $Name; status = $Status; value = [string]$Value; evidence_quality = $Quality })
}

function Exact-IPv4([string]$Name, [string]$Value) {
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Value, [ref]$parsed) -or
        $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $parsed.IPAddressToString -ne $Value) { throw "$Name must be one exact canonical IPv4 address" }
    $bytes = $parsed.GetAddressBytes()
    $private = ($bytes[0] -eq 10) -or ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
        ($bytes[0] -eq 192 -and $bytes[1] -eq 168)
    if (-not $private -or $Value -eq '0.0.0.0' -or $Value -eq '255.255.255.255') { throw "$Name must be one unicast RFC1918 address" }
    return $parsed
}

function Get-BitString([Net.IPAddress]$Address) {
    return (($Address.GetAddressBytes() | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join '')
}

$server = Exact-IPv4 'ServerIPv4' $ServerIPv4
$client = Exact-IPv4 'ClientIPv4' $ClientIPv4
if ($RunId -notmatch '^lan-[a-z0-9][a-z0-9-]{0,31}$' -or $SourceCommit -notmatch '^[0-9a-f]{40}$') { throw 'preflight run/commit binding is invalid' }
if ($MoqUdpPort -ne 14433 -or $SrtUdpPort -ne 19000) { throw 'LAN reserves are UDP/14433 for the proxy and UDP/19000 for SRT' }
if ($ServerIPv4 -eq $ClientIPv4) { throw 'server and client addresses must differ' }
$serverBits = Get-BitString $server
$clientBits = Get-BitString $client
if ($serverBits.Substring(0, $PrefixLength) -ne $clientBits.Substring(0, $PrefixLength)) { throw 'server and client must share the configured subnet' }
foreach ($entry in @(@{ Name = 'ServerIPv4'; Bits = $serverBits }, @{ Name = 'ClientIPv4'; Bits = $clientBits })) {
    $hostBits = $entry.Bits.Substring($PrefixLength)
    if ($hostBits -notmatch '1' -or $hostBits -notmatch '0') { throw "$($entry.Name) is a subnet or broadcast address" }
}

$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
Add-Check 'windows_caption' 'observed' $(if ($os) { $os.Caption } else { 'unavailable' }) $(if ($os) { 'real' } else { 'unavailable' })
Add-Check 'windows_version' 'observed' $(if ($os) { $os.Version } else { 'unavailable' }) $(if ($os) { 'real' } else { 'unavailable' })
Add-Check 'capture_origin' $(if ($nativeCapture) { 'pass' } else { 'blocked' }) $(if ($nativeCapture) { 'native_windows_powershell' } else { 'wsl_or_ambiguous_capture' }) 'real'
$expectedAddress = if ($Role -eq 'Server') { $ServerIPv4 } else { $ClientIPv4 }
$addressMatches = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $expectedAddress })
$address = if ($addressMatches.Count -eq 1) { $addressMatches[0] } else { $null }
$addressValue = if ($addressMatches.Count -eq 1) { $expectedAddress } elseif ($addressMatches.Count -gt 1) { 'duplicate-address-record' } else { 'unavailable' }
Add-Check 'configured_private_ip_present' $(if ($addressMatches.Count -eq 1) { 'pass' } else { 'blocked' }) $addressValue $(if ($addressMatches.Count -gt 0) { 'real' } else { 'unavailable' })
if ($address) {
    $profileMatches = @(Get-NetConnectionProfile -InterfaceIndex $address.InterfaceIndex -ErrorAction SilentlyContinue)
    $profile = if ($profileMatches.Count -eq 1) { $profileMatches[0] } else { $null }
    $profileValue = if ($profile) { [string]$profile.NetworkCategory } elseif ($profileMatches.Count -gt 1) { 'duplicate-profile-record' } else { 'unavailable' }
    Add-Check 'network_profile' $(if ($profileValue -eq $NetworkProfile) { 'pass' } else { 'blocked' }) $profileValue $(if ($profileMatches.Count -gt 0) { 'real' } else { 'unavailable' })

    $wifi = Get-TeremoqExactWifiAdapter -InterfaceIndex $address.InterfaceIndex
    $wifiStatus = if ($wifi) { 'pass' } else { 'blocked' }
    $wifiValue = if ($wifi) { "ifindex=$($address.InterfaceIndex);physical_media=$([string]$wifi.PhysicalMediaType);ndis_medium=$([int]$wifi.NdisPhysicalMedium)" } else { 'exact-interface-not-up-80211' }
    Add-Check 'wifi_adapter' $wifiStatus $wifiValue 'real'
    Add-Check 'wifi_link_speed' $(if ($wifi) { 'observed' } else { 'blocked' }) $(if ($wifi) { $wifi.LinkSpeed } else { 'unavailable' }) $(if ($wifi) { 'real' } else { 'unavailable' })

    $wlanText = (@(& "$env:SystemRoot\System32\netsh.exe" wlan show interfaces 2>$null) -join "`n")
    $wifiObservation = if ($wifi) { Get-TeremoqWlanObservation -Text $wlanText -AdapterName $wifi.Name } else { [pscustomobject]@{ Band = 'unavailable'; Radio = 'unavailable'; IsCanonical5GHz = $false; FallbackRadioQualified = $false } }
    $wifiBandValue = if ($wifiObservation.Band -ne 'unavailable') { $wifiObservation.Band } elseif ($wifiObservation.FallbackRadioQualified) { "fallback-radio=$($wifiObservation.Radio)" } else { 'unavailable' }
    Add-Check 'wifi_radio' 'observed' $wifiObservation.Radio $(if ($wifiObservation.Radio -eq 'unavailable') { 'unavailable' } else { 'real' })
    Add-Check 'wifi_band' $(if ($wifiObservation.IsCanonical5GHz) { 'pass' } else { 'blocked' }) $wifiBandValue $(if ($wifiBandValue -eq 'unavailable') { 'unavailable' } else { 'real' })

    $interfaceMatches = @(Get-NetIPInterface -InterfaceIndex $address.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    $interface = if ($interfaceMatches.Count -eq 1) { $interfaceMatches[0] } else { $null }
    $mtuValue = if ($interface) { [int]$interface.NlMtu } elseif ($interfaceMatches.Count -gt 1) { 'duplicate-interface-record' } else { 'unavailable' }
    Add-Check 'mtu' $(if ($interface -and [int]$interface.NlMtu -ge $MinimumMtu) { 'pass' } else { 'blocked' }) $mtuValue $(if ($interfaceMatches.Count -gt 0) { 'real' } else { 'unavailable' })
} else {
    Add-Check 'network_profile' 'blocked' 'unavailable' 'unavailable'
    Add-Check 'wifi_adapter' 'blocked' 'unavailable' 'unavailable'
    Add-Check 'wifi_link_speed' 'blocked' 'unavailable' 'unavailable'
    Add-Check 'wifi_radio' 'observed' 'unavailable' 'unavailable'
    Add-Check 'wifi_band' 'blocked' 'unavailable' 'unavailable'
    Add-Check 'mtu' 'blocked' 'unavailable' 'unavailable'
}

$wslNetworkingMode = (@(& "$env:SystemRoot\System32\wsl.exe" -e wslinfo --networking-mode 2>$null) -join "`n").Trim().ToLowerInvariant()
$wslStatus = (@(& "$env:SystemRoot\System32\wsl.exe" --status 2>$null) -join "`n")
$wslMode = 'unavailable'
if ($wslNetworkingMode -match '^(nat|mirrored)$') { $wslMode = $wslNetworkingMode }
elseif ($wslStatus -match '(?i)mirrored') { $wslMode = 'mirrored' }
elseif ($wslStatus -match '(?i)\bnat\b') { $wslMode = 'nat' }
Add-Check 'wsl_mode' 'observed' $wslMode $(if ($wslMode -eq 'unavailable') { 'unavailable' } else { 'real' })
Add-Check 'expected_wsl_mode_gate' $(if ($wslMode -eq $ExpectedWslMode) { 'pass' } else { 'blocked' }) $wslMode $(if ($wslMode -eq 'unavailable') { 'unavailable' } else { 'real' })

$clockText = (@(& "$env:SystemRoot\System32\w32tm.exe" /query /status /verbose 2>$null) -join "`n")
$clockOffsetMs = Convert-TeremoqPhaseOffsetMilliseconds -Text $clockText
$clockValue = if ($null -eq $clockOffsetMs) { 'unavailable' } else { Format-TeremoqInvariantDecimal -Value $clockOffsetMs }
$clockStatus = if ($null -ne $clockOffsetMs -and [math]::Abs($clockOffsetMs) -le $MaximumClockOffsetMs) { 'pass' } else { 'blocked' }
Add-Check 'clock_offset' $clockStatus $clockValue $(if ($null -eq $clockOffsetMs) { 'unavailable' } else { 'real' })

$computer = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$cpu = if ($computer) { [int]$computer.NumberOfLogicalProcessors } else { 'unavailable' }
$memoryMiB = if ($computer) { [math]::Floor($computer.TotalPhysicalMemory / 1MB) } else { 'unavailable' }
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
$diskMiB = if ($disk) { [math]::Floor($disk.FreeSpace / 1MB) } else { 'unavailable' }
Add-Check 'logical_cpu' $(if ($computer -and [int]$cpu -ge $MinimumCpuCores) { 'pass' } else { 'blocked' }) $cpu $(if ($computer) { 'real' } else { 'unavailable' })
Add-Check 'physical_memory_mib' $(if ($computer -and [double]$memoryMiB -ge $MinimumMemoryMiB) { 'pass' } else { 'blocked' }) $memoryMiB $(if ($computer) { 'real' } else { 'unavailable' })
Add-Check 'free_disk_mib' $(if ($disk -and [double]$diskMiB -ge $MinimumDiskMiB) { 'pass' } else { 'blocked' }) $diskMiB $(if ($disk) { 'real' } else { 'unavailable' })

foreach ($browser in @('msedge.exe', 'chrome.exe')) {
    $found = Get-Command $browser -ErrorAction SilentlyContinue
    Add-Check "browser_$browser" 'observed' $(if ($found) { 'present' } else { 'absent' }) 'real'
}
$docker = (@(& docker.exe version --format '{{.Server.Version}}' 2>$null) -join "`n").Trim()
$dockerVersionExit = $LASTEXITCODE
Add-Check 'docker_server' 'observed' $(if ($dockerVersionExit -eq 0 -and $docker) { $docker } else { 'unavailable' }) $(if ($dockerVersionExit -eq 0 -and $docker) { 'real' } else { 'unavailable' })
try {
    $dockerRows = @(& docker.exe ps --format '{{.Names}}`t{{.Ports}}' 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'docker ps failed' }
    $dockerConflicts = Get-TeremoqDockerPublicationConflicts -Rows $dockerRows
    Add-Check 'docker_publication_inventory' 'pass' 'bounded-scan' 'real'
    foreach ($conflict in $dockerConflicts) {
        Add-Check 'inherited_docker_publication' 'blocked' $conflict 'real'
    }
} catch {
    Add-Check 'docker_publication_inventory' 'blocked' 'malformed-or-unavailable' 'real'
}
foreach ($port in @(4433, 9000, $MoqUdpPort, $SrtUdpPort)) {
    $udp = @(Get-NetUDPEndpoint -LocalPort $port -ErrorAction SilentlyContinue)
    $state = if ($udp.Count -gt 0) { 'occupied' } else { 'free' }
    $status = if ($state -eq 'free') { 'pass' } else { 'blocked' }
    Add-Check "listener_udp_$port" $status $state 'real'
}
foreach ($port in @(4433, 5678, 6379, 11434)) {
    $tcp = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
    $state = if ($tcp.Count -gt 0) { 'occupied' } else { 'free' }
    $status = if ($state -eq 'free') { 'pass' } else { 'blocked' }
    Add-Check "listener_tcp_$port" $status $state 'real'
}
$wslConfigPath = Join-Path $env:USERPROFILE '.wslconfig'
Add-Check 'wslconfig_present' 'observed' $(if (Test-Path -LiteralPath $wslConfigPath) { 'present' } else { 'absent' }) 'real'
Add-Check 'preflight_gate' $(if ($script:PreflightBlocked) { 'blocked' } else { 'pass' }) $(if ($script:PreflightBlocked) { 'blocked' } else { 'ready' }) 'real'
[ordered]@{
    schema_version = 2
    report_kind = 'teremoq-lan-windows-preflight-v2'
    run_id = $RunId
    source_commit = $SourceCommit
    role = $Role.ToLowerInvariant()
    server_ipv4 = $ServerIPv4
    client_ipv4 = $ClientIPv4
    prefix_length = $PrefixLength
    network_profile = $NetworkProfile
    expected_wsl_mode = $ExpectedWslMode
    maximum_clock_offset_ms = $MaximumClockOffsetMs
    minimum_mtu = $MinimumMtu
    minimum_cpu_cores = $MinimumCpuCores
    minimum_memory_mib = $MinimumMemoryMiB
    minimum_disk_mib = $MinimumDiskMiB
    capture_context = $captureContext
    checks = @($checks | ForEach-Object { $_ })
} | ConvertTo-Json -Depth 5
