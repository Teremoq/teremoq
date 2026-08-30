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
    [ValidateRange(1, 65535)][int]$MoqUdpPort = 14433,
    [ValidateRange(1, 65535)][int]$SrtUdpPort = 19000
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$checks = New-Object System.Collections.Generic.List[object]
$script:PreflightBlocked = $false
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
$expectedAddress = if ($Role -eq 'Server') { $ServerIPv4 } else { $ClientIPv4 }
$address = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $expectedAddress }
Add-Check 'configured_private_ip_present' $(if ($address) { 'pass' } else { 'blocked' }) $(if ($address) { $expectedAddress } else { 'unavailable' }) $(if ($address) { 'real' } else { 'unavailable' })
if ($address) {
    $profile = Get-NetConnectionProfile -InterfaceIndex $address.InterfaceIndex -ErrorAction SilentlyContinue | Select-Object -First 1
    $profileValue = if ($profile) { [string]$profile.NetworkCategory } else { 'unavailable' }
    Add-Check 'network_profile' $(if ($profileValue -eq $NetworkProfile) { 'pass' } else { 'blocked' }) $profileValue $(if ($profile) { 'real' } else { 'unavailable' })
} else {
    Add-Check 'network_profile' 'blocked' 'unavailable' 'unavailable'
}

$wifi = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and ($_.NdisPhysicalMedium -match '802.11|WirelessLan') } | Select-Object -First 1
Add-Check 'wifi_adapter' 'observed' $(if ($wifi) { $wifi.Name } else { 'unavailable' }) $(if ($wifi) { 'real' } else { 'unavailable' })
Add-Check 'wifi_link_speed' 'observed' $(if ($wifi) { $wifi.LinkSpeed } else { 'unavailable' }) $(if ($wifi) { 'real' } else { 'unavailable' })
$wlanText = (@(& "$env:SystemRoot\System32\netsh.exe" wlan show interfaces 2>$null) -join "`n")
$band = 'unavailable'
if ($wlanText -match '(?im)^\s*Band\s*:\s*([^\r\n]+)') { $band = $Matches[1].Trim() }
Add-Check 'wifi_band' $(if ($band -match '5\s*GHz') { 'pass' } else { 'blocked' }) $band $(if ($band -eq 'unavailable') { 'unavailable' } else { 'real' })

$wslNetworkingMode = (@(& "$env:SystemRoot\System32\wsl.exe" -e wslinfo --networking-mode 2>$null) -join "`n").Trim().ToLowerInvariant()
$wslStatus = (@(& "$env:SystemRoot\System32\wsl.exe" --status 2>$null) -join "`n")
$wslMode = 'unavailable'
if ($wslNetworkingMode -match '^(nat|mirrored)$') { $wslMode = $wslNetworkingMode }
elseif ($wslStatus -match '(?i)mirrored') { $wslMode = 'mirrored' }
elseif ($wslStatus -match '(?i)\bnat\b') { $wslMode = 'nat' }
Add-Check 'wsl_mode' 'observed' $wslMode $(if ($wslMode -eq 'unavailable') { 'unavailable' } else { 'real' })
Add-Check 'expected_wsl_mode_gate' $(if ($wslMode -eq $ExpectedWslMode) { 'pass' } else { 'blocked' }) $wslMode $(if ($wslMode -eq 'unavailable') { 'unavailable' } else { 'real' })
if ($Role -eq 'Client' -and $wslMode -eq 'mirrored') { Add-Check 'client_wsl_nat_gate' 'blocked' $wslMode 'real' }
elseif ($Role -eq 'Client') { Add-Check 'client_wsl_nat_gate' $(if ($wslMode -eq 'nat') { 'pass' } else { 'blocked' }) $wslMode $(if ($wslMode -eq 'unavailable') { 'unavailable' } else { 'real' }) }

$clockText = (@(& "$env:SystemRoot\System32\w32tm.exe" /query /status 2>$null) -join "`n")
$clockOffset = 'unavailable'
if ($clockText -match '(?im)^\s*Phase Offset\s*:\s*([^\r\n]+)') { $clockOffset = $Matches[1].Trim() }
Add-Check 'clock_offset' 'observed' $clockOffset $(if ($clockOffset -eq 'unavailable') { 'unavailable' } else { 'real' })

$activeAdapter = Get-NetIPInterface -AddressFamily IPv4 -ConnectionState Connected -ErrorAction SilentlyContinue | Sort-Object InterfaceMetric | Select-Object -First 1
Add-Check 'mtu' 'observed' $(if ($activeAdapter) { $activeAdapter.NlMtu } else { 'unavailable' }) $(if ($activeAdapter) { 'real' } else { 'unavailable' })
$computer = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
Add-Check 'logical_cpu' 'observed' $computer.NumberOfLogicalProcessors $(if ($computer) { 'real' } else { 'unavailable' })
if ($computer) { $memoryMiB = [math]::Floor($computer.TotalPhysicalMemory / 1MB) } else { $memoryMiB = 'unavailable' }
Add-Check 'physical_memory_mib' 'observed' $memoryMiB $(if ($computer) { 'real' } else { 'unavailable' })
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
if ($disk) { $diskMiB = [math]::Floor($disk.FreeSpace / 1MB) } else { $diskMiB = 'unavailable' }
Add-Check 'free_disk_mib' 'observed' $diskMiB $(if ($disk) { 'real' } else { 'unavailable' })

foreach ($browser in @('msedge.exe', 'chrome.exe')) {
    $found = Get-Command $browser -ErrorAction SilentlyContinue
    Add-Check "browser_$browser" 'observed' $(if ($found) { 'present' } else { 'absent' }) 'real'
}
$docker = (@(& docker.exe version --format '{{.Server.Version}}' 2>$null) -join "`n").Trim()
Add-Check 'docker_server' 'observed' $docker $(if ($docker) { 'real' } else { 'unavailable' })
$dockerRows = @(& docker.exe ps --format '{{.Names}}`t{{.Ports}}' 2>$null)
foreach ($row in $dockerRows) {
    $fields = $row -split "`t", 2
    if ($fields.Count -ne 2) { continue }
    foreach ($conflict in @('4433/tcp', '5678/tcp', '6379/tcp', '11434/tcp', '4433/udp', '9000/udp', '14433/udp', '19000/udp')) {
        if ($fields[1] -like "*$conflict*") { Add-Check 'inherited_docker_publication' 'blocked' "service=$($fields[0]);port=$conflict" 'real' }
    }
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
    schema_version = 1
    report_kind = 'teremoq-lan-windows-preflight-v1'
    run_id = $RunId
    source_commit = $SourceCommit
    role = $Role.ToLowerInvariant()
    server_ipv4 = $ServerIPv4
    client_ipv4 = $ClientIPv4
    prefix_length = $PrefixLength
    network_profile = $NetworkProfile
    expected_wsl_mode = $ExpectedWslMode
    checks = @($checks | ForEach-Object { $_ })
} | ConvertTo-Json -Depth 5
