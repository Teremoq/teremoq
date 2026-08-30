# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ServerIPv4,
    [Parameter(Mandatory = $true)][string]$ClientIPv4,
    [Parameter(Mandatory = $true)][ValidateRange(8, 30)][int]$PrefixLength,
    [Parameter(Mandatory = $true)][ValidateSet('Public', 'Private')][string]$NetworkProfile,
    [Parameter(Mandatory = $true)][ValidateSet('nat')][string]$ExpectedWslMode,
    [ValidateRange(1, 65535)][int]$MoqUdpPort = 14433,
    [ValidateRange(1, 65535)][int]$PlayerTcpPort = 3000,
    [ValidateRange(576, 9000)][int]$MinimumMtu = 1280,
    [ValidateRange(1, 1024)][int]$MinimumCpuCores = 2,
    [ValidateRange(1, 1073741824)][int]$MinimumMemoryMiB = 2048,
    [ValidateRange(1, 1073741824)][int]$MinimumDiskMiB = 2048
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$checks = New-Object System.Collections.Generic.List[object]

function Add-Check([string]$Name, [string]$Status, $Value, [string]$Quality) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        $Value = 'unavailable'
        $Quality = 'unavailable'
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

function Get-IPv4Integer([Net.IPAddress]$Address) {
    $bytes = $Address.GetAddressBytes()
    return ([uint32]$bytes[0] -shl 24) -bor ([uint32]$bytes[1] -shl 16) -bor ([uint32]$bytes[2] -shl 8) -bor [uint32]$bytes[3]
}

if ($MoqUdpPort -ne 14433 -or $PlayerTcpPort -ne 3000) { throw 'LAN reserves are outbound UDP/14433 and player loopback TCP/3000' }
$server = Convert-ExactPrivateIPv4 'ServerIPv4' $ServerIPv4
$client = Convert-ExactPrivateIPv4 'ClientIPv4' $ClientIPv4
if ($ServerIPv4 -eq $ClientIPv4) { throw 'server and client addresses must differ' }
$mask = [uint32](([uint64]0xffffffff -shl (32 - $PrefixLength)) -band 0xffffffff)
$serverInteger = Get-IPv4Integer $server
$clientInteger = Get-IPv4Integer $client
if (($serverInteger -band $mask) -ne ($clientInteger -band $mask)) {
    throw 'server and client must share the configured subnet'
}
$hostMask = [uint32](([uint64]0xffffffff -bxor $mask) -band 0xffffffff)
foreach ($entry in @(@{ Name = 'ServerIPv4'; Value = $serverInteger }, @{ Name = 'ClientIPv4'; Value = $clientInteger })) {
    $host = $entry.Value -band $hostMask
    if ($host -eq 0 -or $host -eq $hostMask) { throw "$($entry.Name) is a subnet or broadcast address" }
}

$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
Add-Check 'windows_caption' 'observed' $(if ($os) { $os.Caption } else { 'unavailable' }) $(if ($os) { 'real' } else { 'unavailable' })
Add-Check 'windows_version' 'observed' $(if ($os) { $os.Version } else { 'unavailable' }) $(if ($os) { 'real' } else { 'unavailable' })
$address = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $ClientIPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
Add-Check 'client_private_ip_present' $(if ($address) { 'pass' } else { 'blocked' }) $(if ($address) { $ClientIPv4 } else { 'unavailable' }) $(if ($address) { 'real' } else { 'unavailable' })
if ($address) {
    $profile = Get-NetConnectionProfile -InterfaceIndex $address.InterfaceIndex -ErrorAction SilentlyContinue | Select-Object -First 1
    $profileValue = if ($profile) { [string]$profile.NetworkCategory } else { 'unavailable' }
    Add-Check 'network_profile' $(if ($profileValue -eq $NetworkProfile) { 'pass' } else { 'blocked' }) $profileValue $(if ($profile) { 'real' } else { 'unavailable' })
    $interface = Get-NetIPInterface -InterfaceIndex $address.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    $mtu = if ($interface) { $interface.NlMtu } else { 'unavailable' }
    Add-Check 'mtu' $(if ($interface -and $mtu -ge $MinimumMtu) { 'pass' } else { 'blocked' }) $mtu $(if ($interface) { 'real' } else { 'unavailable' })
} else {
    Add-Check 'network_profile' 'blocked' 'unavailable' 'unavailable'
    Add-Check 'mtu' 'blocked' 'unavailable' 'unavailable'
}

$wlanText = (& netsh.exe wlan show interfaces 2>$null | Out-String)
$radio = if ($wlanText -match '(?im)^\s*(Radio type|Tipo de radio)\s*:\s*([^\r\n]+)') { $Matches[2].Trim() } else { 'unavailable' }
$band = if ($wlanText -match '(?im)^\s*(Band|Banda)\s*:\s*([^\r\n]+)') { $Matches[2].Trim() } else { 'unavailable' }
$wifi5 = $band -match '5\s*GHz' -or $radio -match '802\.11(ac|ax)'
Add-Check 'wifi_radio' 'observed' $radio $(if ($radio -eq 'unavailable') { 'unavailable' } else { 'real' })
Add-Check 'wifi_5ghz' $(if ($wifi5) { 'pass' } else { 'blocked' }) $band $(if ($band -eq 'unavailable') { 'unavailable' } else { 'real' })

$wslIPv4 = (& wsl.exe -e sh -lc "ip -o -4 addr show scope global 2>/dev/null | awk 'NR==1 {print `$4}'" 2>$null | Out-String).Trim()
$wslMode = 'unavailable'
if ($wslIPv4 -match '^\d+\.\d+\.\d+\.\d+/\d+$') {
    $wslAddressText = $wslIPv4.Split('/')[0]
    if ($wslAddressText -eq $ClientIPv4) { $wslMode = 'mirrored' } else { $wslMode = 'nat' }
}
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
$nodeVersion = if ($nodeCommand) { (& $nodeCommand.Source --version 2>$null | Out-String).Trim() } else { 'unavailable' }
$nodeSupported = $nodeVersion -match '^v22\.[0-9]+\.[0-9]+$'
Add-Check 'node_runtime_22_x' $(if ($nodeSupported) { 'pass' } else { 'blocked' }) `
    $(if ($nodeSupported) { $nodeVersion } else { 'unavailable; install an approved Node 22.x runtime before the LAN player' }) `
    $(if ($nodeSupported) { 'real' } else { 'unavailable' })
$playerListeners = @(Get-NetTCPConnection -State Listen -LocalPort $PlayerTcpPort -ErrorAction SilentlyContinue)
Add-Check 'player_loopback_tcp_3000' $(if ($playerListeners.Count -eq 0) { 'pass' } else { 'blocked' }) `
    $(if ($playerListeners.Count -eq 0) { 'free' } else { 'occupied' }) 'real'

$clockText = (& w32tm.exe /query /status 2>$null | Out-String)
$clockOffset = if ($clockText -match '(?im)^\s*(Phase Offset|Desfase de fase)\s*:\s*([^\r\n]+)') { $Matches[2].Trim() } else { 'unavailable' }
Add-Check 'clock_offset' 'observed' $clockOffset $(if ($clockOffset -eq 'unavailable') { 'unavailable' } else { 'real' })
$computer = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$cpu = if ($computer) { $computer.NumberOfLogicalProcessors } else { 'unavailable' }
$memory = if ($computer) { [math]::Floor($computer.TotalPhysicalMemory / 1MB) } else { 'unavailable' }
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
$diskMiB = if ($disk) { [math]::Floor($disk.FreeSpace / 1MB) } else { 'unavailable' }
Add-Check 'logical_cpu' $(if ($computer -and $cpu -ge $MinimumCpuCores) { 'pass' } else { 'blocked' }) $cpu $(if ($computer) { 'real' } else { 'unavailable' })
Add-Check 'physical_memory_mib' $(if ($computer -and $memory -ge $MinimumMemoryMiB) { 'pass' } else { 'blocked' }) $memory $(if ($computer) { 'real' } else { 'unavailable' })
Add-Check 'free_disk_mib' $(if ($disk -and $diskMiB -ge $MinimumDiskMiB) { 'pass' } else { 'blocked' }) $diskMiB $(if ($disk) { 'real' } else { 'unavailable' })

$pings = @(Test-Connection -ComputerName $ServerIPv4 -Count 4 -ErrorAction SilentlyContinue)
$rtts = @($pings | ForEach-Object { $_.ResponseTime } | Where-Object { $null -ne $_ })
$loss = [math]::Round((1.0 - ($rtts.Count / 4.0)) * 100.0, 3)
$rtt = if ($rtts.Count -gt 0) { [math]::Round(($rtts | Measure-Object -Average).Average, 3) } else { 'unavailable' }
Add-Check 'icmp_echo_loss_percent_approximation' 'observed' $loss 'real'
Add-Check 'icmp_echo_rtt_average_ms_approximation' 'observed' $rtt $(if ($rtts.Count -gt 0) { 'real' } else { 'unavailable' })
Add-Check 'quic_udp_14433_reachability' 'pending' 'not_measured' 'not_measured'
Add-Check 'secure_context' 'pending' 'player-must-bind-client-loopback;relay-uses-certificate-pin' 'configured'
Add-Check 'inbound_client_firewall' 'pass' 'not-required;client-initiates-outbound-only' 'configured'
$checks | ConvertTo-Json -Depth 4
