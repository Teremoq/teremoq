# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$SourceCommit,
    [Parameter(Mandatory = $true)][string]$ServerIPv4,
    [Parameter(Mandatory = $true)][string]$ClientIPv4,
    [Parameter(Mandatory = $true)][ValidateRange(8, 30)][int]$PrefixLength,
    [Parameter(Mandatory = $true)][ValidateSet('Public', 'Private')][string]$NetworkProfile,
    [Parameter(Mandatory = $true)][ValidateSet('nat')][string]$ExpectedWslMode,
    [Parameter(Mandatory = $true)][ValidateRange(1, 60000)][int]$MaximumClockOffsetMs,
    [Parameter(Mandatory = $true)][ValidateRange(576, 9000)][int]$MinimumMtu,
    [Parameter(Mandatory = $true)][ValidateRange(1, 1024)][int]$MinimumCpuCores,
    [Parameter(Mandatory = $true)][ValidateRange(1, 1073741824)][int]$MinimumMemoryMiB,
    [Parameter(Mandatory = $true)][ValidateRange(1, 1073741824)][int]$MinimumDiskMiB,
    [ValidateRange(1, 65535)][int]$MoqUdpPort = 14433,
    [ValidateRange(1, 65535)][int]$PlayerTcpPort = 3000
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot 'Preflight-Contract.ps1')
$checks = New-Object System.Collections.Generic.List[object]
$script:PreflightBlocked = $false
$script:AdvisoryChecks = @('windows_caption', 'windows_version', 'wifi_radio', 'wifi_5ghz', 'browser_edge', 'browser_chrome', 'icmp_echo_loss_percent_approximation', 'icmp_echo_rtt_average_ms_approximation')
$captureContext = Get-TeremoqCaptureContext
$nativeCapture = Test-TeremoqCaptureContextEvidence -Context $captureContext

function Add-Check([string]$Name, [string]$Status, $Value, [string]$Quality) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        $Value = 'unavailable'
        $Quality = 'unavailable'
    }
    if ($Name -ne 'preflight_gate' -and $script:AdvisoryChecks -notcontains $Name -and ($Status -notin @('pass', 'observed') -or $Quality -notin @('real', 'configured') -or
        [string]$Value -match '(?i)(^|[^a-z])(blocked|pending|unavailable|unknown|not_measured|occupied)($|[^a-z])')) {
        $script:PreflightBlocked = $true
    }
    $checks.Add([pscustomobject]@{ check = $Name; status = $Status; value = [string]$Value; evidence_quality = $Quality })
}

function Convert-ExactPrivateIPv4([string]$Name, [string]$Value) {
    $parsed = $null
    if ($Value.Contains('/') -or -not [Net.IPAddress]::TryParse($Value, [ref]$parsed) -or
        $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $parsed.IPAddressToString -ne $Value) { throw "$Name must be one exact canonical IPv4 address" }
    $bytes = $parsed.GetAddressBytes()
    $private = ($bytes[0] -eq 10) -or ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
        ($bytes[0] -eq 192 -and $bytes[1] -eq 168)
    if (-not $private -or $parsed.IsIPv6Multicast -or $Value -eq '0.0.0.0' -or $Value -eq '255.255.255.255') {
        throw "$Name must be one unicast RFC1918 address"
    }
    return $parsed
}

function Get-BitString([Net.IPAddress]$Address) {
    return (($Address.GetAddressBytes() | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join '')
}

if ($MoqUdpPort -ne 14433 -or $PlayerTcpPort -ne 3000) { throw 'LAN reserves are outbound UDP/14433 and player loopback TCP/3000' }
if ($RunId -notmatch '^lan-[a-z0-9][a-z0-9-]{0,31}$' -or $SourceCommit -notmatch '^[0-9a-f]{40}$') { throw 'preflight run/commit binding is invalid' }
$server = Convert-ExactPrivateIPv4 'ServerIPv4' $ServerIPv4
$client = Convert-ExactPrivateIPv4 'ClientIPv4' $ClientIPv4
if ($ServerIPv4 -eq $ClientIPv4) { throw 'server and client addresses must differ' }
$serverBits = Get-BitString $server
$clientBits = Get-BitString $client
if ($serverBits.Substring(0, $PrefixLength) -ne $clientBits.Substring(0, $PrefixLength)) {
    throw 'server and client must share the configured subnet'
}
foreach ($entry in @(@{ Name = 'ServerIPv4'; Bits = $serverBits }, @{ Name = 'ClientIPv4'; Bits = $clientBits })) {
    $hostBits = $entry.Bits.Substring($PrefixLength)
    if ($hostBits -notmatch '1' -or $hostBits -notmatch '0') { throw "$($entry.Name) is a subnet or broadcast address" }
}

$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
Add-Check 'windows_caption' 'observed' $(if ($os) { $os.Caption } else { 'unavailable' }) $(if ($os) { 'real' } else { 'unavailable' })
Add-Check 'windows_version' 'observed' $(if ($os) { $os.Version } else { 'unavailable' }) $(if ($os) { 'real' } else { 'unavailable' })
Add-Check 'capture_origin' $(if ($nativeCapture) { 'pass' } else { 'blocked' }) $(if ($nativeCapture) { 'native_windows_powershell' } else { 'wsl_or_ambiguous_capture' }) 'real'
$addressMatches = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $ClientIPv4 })
$address = if ($addressMatches.Count -eq 1) { $addressMatches[0] } else { $null }
$addressValue = if ($addressMatches.Count -eq 1) { $ClientIPv4 } elseif ($addressMatches.Count -gt 1) { 'duplicate-address-record' } else { 'unavailable' }
Add-Check 'client_private_ip_present' $(if ($addressMatches.Count -eq 1) { 'pass' } else { 'blocked' }) $addressValue $(if ($addressMatches.Count -gt 0) { 'real' } else { 'unavailable' })
if ($address) {
    $profileMatches = @(Get-NetConnectionProfile -InterfaceIndex $address.InterfaceIndex -ErrorAction SilentlyContinue)
    $profile = if ($profileMatches.Count -eq 1) { $profileMatches[0] } else { $null }
    $profileValue = if ($profile) { [string]$profile.NetworkCategory } elseif ($profileMatches.Count -gt 1) { 'duplicate-profile-record' } else { 'unavailable' }
    Add-Check 'network_profile' $(if ($profileValue -eq $NetworkProfile) { 'pass' } else { 'blocked' }) $profileValue $(if ($profileMatches.Count -gt 0) { 'real' } else { 'unavailable' })
    $interfaceMatches = @(Get-NetIPInterface -InterfaceIndex $address.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    $interface = if ($interfaceMatches.Count -eq 1) { $interfaceMatches[0] } else { $null }
    $mtuValue = if ($interface) { [int]$interface.NlMtu } elseif ($interfaceMatches.Count -gt 1) { 'duplicate-interface-record' } else { 'unavailable' }
    Add-Check 'mtu' $(if ($interface -and [int]$interface.NlMtu -ge $MinimumMtu) { 'pass' } else { 'blocked' }) $mtuValue $(if ($interfaceMatches.Count -gt 0) { 'real' } else { 'unavailable' })

    $wifi = Get-TeremoqExactWifiAdapter -InterfaceIndex $address.InterfaceIndex
    $wlanText = (@(& "$env:SystemRoot\System32\netsh.exe" wlan show interfaces 2>$null) -join "`n")
    $wifiObservation = if ($wifi) { Get-TeremoqWlanObservation -Text $wlanText -AdapterName $wifi.Name } else { [pscustomobject]@{ Band = 'unavailable'; Radio = 'unavailable'; IsCanonical5GHz = $false; FallbackRadioQualified = $false } }
    Add-Check 'wifi_radio' 'observed' $(if ($wifiObservation.Radio -eq 'unavailable') { 'warning:radio-not-observed' } else { $wifiObservation.Radio }) $(if ($wifiObservation.Radio -eq 'unavailable') { 'configured' } else { 'real' })
    $wifi5Value = if ($wifiObservation.Band -ne 'unavailable') { $wifiObservation.Band } elseif ($wifiObservation.FallbackRadioQualified) { "fallback-radio=$($wifiObservation.Radio)" } else { 'unavailable' }
    Add-Check 'wifi_5ghz' $(if ($wifiObservation.IsCanonical5GHz) { 'pass' } else { 'observed' }) `
        $(if ($wifiObservation.IsCanonical5GHz) { '5 GHz' } elseif ($wifi5Value -eq 'unavailable') { 'warning:band-not-observed' } else { "warning:band-not-confirmed:$wifi5Value" }) `
        $(if ($wifi5Value -eq 'unavailable') { 'configured' } else { 'real' })
} else {
    Add-Check 'network_profile' 'blocked' 'unavailable' 'unavailable'
    Add-Check 'mtu' 'blocked' 'unavailable' 'unavailable'
    Add-Check 'wifi_radio' 'observed' 'warning:radio-not-observed' 'configured'
    Add-Check 'wifi_5ghz' 'observed' 'warning:band-not-observed' 'configured'
}

$wslObservation = Invoke-TeremoqClientWslIpv4ModeQuery -ClientIPv4 $ClientIPv4
$wslMode = [string]$wslObservation.Mode
Add-Check 'wsl_ipv4_mode' $(if ($wslMode -eq $ExpectedWslMode) { 'pass' } else { 'blocked' }) $wslMode $(if ($wslMode -eq 'unavailable') { 'unavailable' } else { 'real' })

$browserFound = $false
foreach ($browser in @(
    @{ Name = 'edge'; Paths = @("$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe", "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe") },
    @{ Name = 'chrome'; Paths = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") }
)) {
    $path = $browser.Paths | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
    if ($path) { $browserFound = $true }
    Add-Check "browser_$($browser.Name)" 'observed' $(if ($path) { 'present' } else { 'unavailable' }) $(if ($path) { 'real' } else { 'unavailable' })
}
Add-Check 'browser_gate' $(if ($browserFound) { 'pass' } else { 'blocked' }) $(if ($browserFound) { 'chrome-or-edge-present' } else { 'unavailable' }) $(if ($browserFound) { 'real' } else { 'unavailable' })
$nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
$nodeVersion = if ($nodeCommand) { (@(& $nodeCommand.Source --version 2>$null) -join "`n").Trim() } else { 'unavailable' }
$nodeSupported = $nodeVersion -match '^v22\.[0-9]+\.[0-9]+$'
Add-Check 'node_runtime_22_x' $(if ($nodeSupported) { 'pass' } else { 'blocked' }) `
    $(if ($nodeSupported) { $nodeVersion } else { 'unavailable; install an approved Node 22.x runtime before the LAN player' }) `
    $(if ($nodeSupported) { 'real' } else { 'unavailable' })
$playerListeners = @(Get-NetTCPConnection -State Listen -LocalPort $PlayerTcpPort -ErrorAction SilentlyContinue)
Add-Check 'player_loopback_tcp_3000' $(if ($playerListeners.Count -eq 0) { 'pass' } else { 'blocked' }) `
    $(if ($playerListeners.Count -eq 0) { 'free' } else { 'occupied' }) 'real'

$clockText = (@(& "$env:SystemRoot\System32\w32tm.exe" /query /status /verbose 2>$null) -join "`n")
$clockOffsetMs = Convert-TeremoqPhaseOffsetMilliseconds -Text $clockText
$clockValue = if ($null -eq $clockOffsetMs) { 'unavailable' } else { Format-TeremoqInvariantDecimal -Value $clockOffsetMs }
Add-Check 'clock_offset' $(if ($null -ne $clockOffsetMs -and [math]::Abs($clockOffsetMs) -le $MaximumClockOffsetMs) { 'pass' } else { 'blocked' }) $clockValue $(if ($null -eq $clockOffsetMs) { 'unavailable' } else { 'real' })

$computer = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$cpu = if ($computer) { [int]$computer.NumberOfLogicalProcessors } else { 'unavailable' }
$memory = if ($computer) { [math]::Floor($computer.TotalPhysicalMemory / 1MB) } else { 'unavailable' }
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
$diskMiB = if ($disk) { [math]::Floor($disk.FreeSpace / 1MB) } else { 'unavailable' }
Add-Check 'logical_cpu' $(if ($computer -and [int]$cpu -ge $MinimumCpuCores) { 'pass' } else { 'blocked' }) $cpu $(if ($computer) { 'real' } else { 'unavailable' })
Add-Check 'physical_memory_mib' $(if ($computer -and [double]$memory -ge $MinimumMemoryMiB) { 'pass' } else { 'blocked' }) $memory $(if ($computer) { 'real' } else { 'unavailable' })
Add-Check 'free_disk_mib' $(if ($disk -and [double]$diskMiB -ge $MinimumDiskMiB) { 'pass' } else { 'blocked' }) $diskMiB $(if ($disk) { 'real' } else { 'unavailable' })

$pings = @(Test-Connection -ComputerName $ServerIPv4 -Count 4 -ErrorAction SilentlyContinue)
$rtts = @($pings | ForEach-Object { $_.ResponseTime } | Where-Object { $null -ne $_ })
$loss = [math]::Round((1.0 - ($rtts.Count / 4.0)) * 100.0, 3)
$rtt = if ($rtts.Count -gt 0) { [math]::Round(($rtts | Measure-Object -Average).Average, 3) } else { 'unavailable' }
Add-Check 'icmp_echo_loss_percent_approximation' 'observed' $loss 'real'
Add-Check 'icmp_echo_rtt_average_ms_approximation' 'observed' $rtt $(if ($rtts.Count -gt 0) { 'real' } else { 'unavailable' })
Add-Check 'inbound_client_firewall' 'pass' 'not-required;client-initiates-outbound-only' 'configured'
Add-Check 'preflight_gate' $(if ($script:PreflightBlocked) { 'blocked' } else { 'pass' }) $(if ($script:PreflightBlocked) { 'blocked' } else { 'ready' }) 'real'
[ordered]@{
    schema_version = 2
    report_kind = 'teremoq-lan-windows-preflight-v2'
    run_id = $RunId
    source_commit = $SourceCommit
    role = 'client'
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
