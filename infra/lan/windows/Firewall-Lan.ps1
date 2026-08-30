# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Validate', 'Plan', 'Verify', 'Apply', 'Rollback')]
    [string]$Action,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$ServerIPv4,
    [Parameter(Mandatory = $true)][string]$ClientIPv4,
    [Parameter(Mandatory = $true)][string]$RouterIPv4,
    [Parameter(Mandatory = $true)][ValidateRange(8, 30)][int]$PrefixLength,
    [ValidateRange(1, 65535)][int]$MoqUdpPort = 14433,
    [Parameter(Mandatory = $true)][ValidateSet('Public', 'Private')][string]$NetworkProfile,
    [ValidateRange(0, 65535)][int]$DashboardTlsPort = 0,
    [switch]$ConfirmApply
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Convert-ExactPrivateIPv4([string]$Name, [string]$Value) {
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Value, [ref]$parsed) -or
        $parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
        $parsed.IPAddressToString -ne $Value) {
        throw "$Name must be one canonical exact IPv4 address; ranges, CIDR, any and aliases are forbidden"
    }
    $bytes = $parsed.GetAddressBytes()
    $private = ($bytes[0] -eq 10) -or
        ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
        ($bytes[0] -eq 192 -and $bytes[1] -eq 168)
    if (-not $private -or $bytes[0] -ge 224 -or $Value -eq '0.0.0.0' -or $Value -eq '255.255.255.255') {
        throw "$Name must be one unicast RFC1918 address"
    }
    return $parsed
}

function Get-BitString([System.Net.IPAddress]$Address) {
    return (($Address.GetAddressBytes() | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join '')
}

if ($RunId -notmatch '^lan-[a-z0-9][a-z0-9-]{0,31}$') { throw 'RunId is outside the allowlist' }
if ($MoqUdpPort -ne 14433) { throw 'the LAN QUIC frontend reserve contains only UDP/14433' }
if ($DashboardTlsPort -ne 0) { throw 'dashboard LAN firewall is blocked until a reviewed TLS/read-only frontier exists' }
$server = Convert-ExactPrivateIPv4 'ServerIPv4' $ServerIPv4
$client = Convert-ExactPrivateIPv4 'ClientIPv4' $ClientIPv4
$router = Convert-ExactPrivateIPv4 'RouterIPv4' $RouterIPv4
if ($ServerIPv4 -eq $ClientIPv4 -or $ServerIPv4 -eq $RouterIPv4 -or $ClientIPv4 -eq $RouterIPv4) {
    throw 'server, client and router addresses must be distinct; the router can never be the firewall peer'
}
$serverBits = Get-BitString $server
$clientBits = Get-BitString $client
$routerBits = Get-BitString $router
if ($serverBits.Substring(0, $PrefixLength) -ne $clientBits.Substring(0, $PrefixLength) -or
    $serverBits.Substring(0, $PrefixLength) -ne $routerBits.Substring(0, $PrefixLength)) {
    throw 'server, client and router must share the configured subnet'
}
foreach ($entry in @(
    @{ Name = 'ServerIPv4'; Bits = $serverBits },
    @{ Name = 'ClientIPv4'; Bits = $clientBits },
    @{ Name = 'RouterIPv4'; Bits = $routerBits }
)) {
    $hostBits = $entry.Bits.Substring($PrefixLength)
    if ($hostBits -notmatch '1' -or $hostBits -notmatch '0') { throw "$($entry.Name) is a subnet or broadcast address" }
}
$serverInterface = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $ServerIPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $serverInterface) { throw 'ServerIPv4 is not currently assigned on this Windows host' }
$currentProfile = Get-NetConnectionProfile -InterfaceIndex $serverInterface.InterfaceIndex -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $currentProfile -or [string]$currentProfile.NetworkCategory -ne $NetworkProfile) {
    throw "NetworkProfile must equal the current profile associated with ServerIPv4; profile changes are forbidden"
}

$group = "Teremoq-LAN-$RunId"
$ruleName = "$group-Defender-QUIC-UDP-$MoqUdpPort"
$hyperVRuleName = "$group-HyperV-QUIC-UDP-$MoqUdpPort"
$wslCreatorId = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
$newRule = @{
    Name = $ruleName
    DisplayName = $ruleName
    Group = $group
    Direction = 'Inbound'
    Action = 'Allow'
    Enabled = 'True'
    Profile = $NetworkProfile
    LocalAddress = $ServerIPv4
    RemoteAddress = $ClientIPv4
    Protocol = 'UDP'
    LocalPort = $MoqUdpPort
    EdgeTraversalPolicy = 'Block'
    Description = "Temporary Teremoq LAN run $RunId; exact client only"
}

if ($Action -eq 'Validate') {
    [pscustomobject]@{ status = 'valid'; group = $group; classic_rule = $ruleName; hyperv_rule = $hyperVRuleName; remote = $ClientIPv4; protocol = 'UDP'; port = $MoqUdpPort; profile = $NetworkProfile } | ConvertTo-Json -Compress
    exit 0
}
if ($Action -eq 'Plan') {
    Write-Output "New-NetFirewallRule -Name '$ruleName' -DisplayName '$ruleName' -Group '$group' -Direction Inbound -Action Allow -Enabled True -Profile '$NetworkProfile' -LocalAddress '$ServerIPv4' -RemoteAddress '$ClientIPv4' -Protocol UDP -LocalPort $MoqUdpPort -EdgeTraversalPolicy Block"
    Write-Output "New-NetFirewallHyperVRule -Name '$hyperVRuleName' -DisplayName '$hyperVRuleName' -Direction Inbound -Action Allow -Enabled True -Profiles '$NetworkProfile' -VMCreatorId '$wslCreatorId' -Protocol UDP -LocalAddresses '$ServerIPv4' -RemoteAddresses '$ClientIPv4' -LocalPorts $MoqUdpPort"
    Write-Output "Remove-NetFirewallRule -Name '$ruleName' -ErrorAction SilentlyContinue"
    Write-Output "Remove-NetFirewallHyperVRule -Name '$hyperVRuleName' -ErrorAction SilentlyContinue"
    Write-Output "# Verify both exact names are absent; do not change DefaultInboundAction or the network profile."
    exit 0
}
if ($Action -eq 'Verify') {
    $classic = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
    $hyperv = Get-NetFirewallHyperVRule -Name $hyperVRuleName -ErrorAction SilentlyContinue
    if (-not $classic -or -not $hyperv) { throw 'both exact classic and Hyper-V rules must exist' }
    $addressFilter = $classic | Get-NetFirewallAddressFilter
    $portFilter = $classic | Get-NetFirewallPortFilter
    if ($classic.Enabled -ne 'True' -or $classic.Direction -ne 'Inbound' -or $classic.Action -ne 'Allow' -or
        [string]$classic.Profile -ne $NetworkProfile -or @($addressFilter.LocalAddress).Count -ne 1 -or
        @($addressFilter.RemoteAddress).Count -ne 1 -or $addressFilter.LocalAddress -ne $ServerIPv4 -or
        $addressFilter.RemoteAddress -ne $ClientIPv4 -or [string]$portFilter.Protocol -notmatch '^(UDP|17)$' -or
        [string]$portFilter.LocalPort -ne [string]$MoqUdpPort) { throw 'classic rule properties differ from the exact plan' }
    if ($hyperv.Enabled -ne 'True' -or $hyperv.Direction -ne 'Inbound' -or $hyperv.Action -ne 'Allow' -or
        [string]$hyperv.VMCreatorId -ne $wslCreatorId -or @($hyperv.LocalAddresses).Count -ne 1 -or
        @($hyperv.RemoteAddresses).Count -ne 1 -or [string]$hyperv.LocalAddresses -ne $ServerIPv4 -or
        [string]$hyperv.RemoteAddresses -ne $ClientIPv4 -or [string]$hyperv.Protocol -notmatch '^(UDP|17)$' -or
        [string]$hyperv.LocalPorts -ne [string]$MoqUdpPort -or [string]$hyperv.Profiles -ne $NetworkProfile) {
        throw 'Hyper-V rule properties differ from the exact plan'
    }
    [pscustomobject]@{ firewall_verified = $true; classic_rule = $ruleName; hyperv_rule = $hyperVRuleName; default_inbound_action_changed = $false } | ConvertTo-Json -Compress
    exit 0
}
if (-not $ConfirmApply) { throw 'Apply and Rollback require explicit -ConfirmApply' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'administrator privileges are required for firewall mutation'
}
if ($Action -eq 'Apply') {
    if (-not (Get-Command New-NetFirewallHyperVRule -ErrorAction SilentlyContinue)) { throw 'Hyper-V firewall cmdlets are unavailable' }
    if (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue) { throw 'classic run firewall rule already exists' }
    if (Get-NetFirewallHyperVRule -Name $hyperVRuleName -ErrorAction SilentlyContinue) { throw 'Hyper-V run firewall rule already exists' }
    New-NetFirewallRule @newRule | Out-Null
    try {
        New-NetFirewallHyperVRule -Name $hyperVRuleName -DisplayName $hyperVRuleName -Direction Inbound -Action Allow -Enabled True -Profiles $NetworkProfile -VMCreatorId $wslCreatorId -Protocol UDP -LocalAddresses $ServerIPv4 -RemoteAddresses $ClientIPv4 -LocalPorts $MoqUdpPort | Out-Null
    } catch {
        Remove-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
        throw
    }
    Write-Output "created exact classic and Hyper-V rules for $group"
    exit 0
}
$classic = @(Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)
$hyperv = @(Get-NetFirewallHyperVRule -Name $hyperVRuleName -ErrorAction SilentlyContinue)
if ($classic.Count -gt 0) { Remove-NetFirewallRule -Name $ruleName }
if ($hyperv.Count -gt 0) { Remove-NetFirewallHyperVRule -Name $hyperVRuleName }
if (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue) { throw 'classic rule residue remains' }
if (Get-NetFirewallHyperVRule -Name $hyperVRuleName -ErrorAction SilentlyContinue) { throw 'Hyper-V rule residue remains' }
Write-Output "rollback complete for exact classic and Hyper-V rule names; DefaultInboundAction unchanged"
