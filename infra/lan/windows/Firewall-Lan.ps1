# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Validate', 'Plan', 'Verify', 'Apply', 'Rollback')]
    [string]$Action,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$SourceCommit,
    [Parameter(Mandatory = $true)][string]$ServerIPv4,
    [Parameter(Mandatory = $true)][string]$ClientIPv4,
    [Parameter(Mandatory = $true)][string]$RouterIPv4,
    [Parameter(Mandatory = $true)][ValidateRange(8, 30)][int]$PrefixLength,
    [ValidateRange(1, 65535)][int]$MoqUdpPort = 14433,
    [Parameter(Mandatory = $true)][ValidateSet('Public', 'Private')][string]$NetworkProfile,
    [ValidateRange(0, 65535)][int]$DashboardTlsPort = 0,
    [ValidateRange(0, 65535)][int]$CoordinationTlsPort = 0,
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
if ($SourceCommit -notmatch '^[0-9a-f]{40}$') { throw 'SourceCommit must be one exact integrated commit' }
if ($MoqUdpPort -ne 14433) { throw 'the LAN QUIC frontend reserve contains only UDP/14433' }
if ($DashboardTlsPort -ne 0) { throw 'dashboard LAN firewall is blocked until a reviewed TLS/read-only frontier exists' }
if ($CoordinationTlsPort -notin @(0, 18443)) { throw 'the LAN coordination reserve contains only disabled or TCP/18443' }
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
$coordinationRuleName = "$group-Defender-Control-TCP-$CoordinationTlsPort"
$coordinationHyperVRuleName = "$group-HyperV-Control-TCP-$CoordinationTlsPort"
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
$newCoordinationRule = @{
    Name = $coordinationRuleName
    DisplayName = $coordinationRuleName
    Group = $group
    Direction = 'Inbound'
    Action = 'Allow'
    Enabled = 'True'
    Profile = $NetworkProfile
    LocalAddress = $ServerIPv4
    RemoteAddress = $ClientIPv4
    Protocol = 'TCP'
    LocalPort = $CoordinationTlsPort
    EdgeTraversalPolicy = 'Block'
    Description = "Temporary Teremoq LAN coordination for run $RunId; exact client only"
}

if ($Action -eq 'Validate') {
    [pscustomobject]@{ status = 'valid'; group = $group; classic_rule = $ruleName; hyperv_rule = $hyperVRuleName; remote = $ClientIPv4; protocol = 'UDP'; port = $MoqUdpPort; coordination_tls_port = $CoordinationTlsPort; profile = $NetworkProfile } | ConvertTo-Json -Compress
    exit 0
}
if ($Action -eq 'Plan') {
    Write-Output "New-NetFirewallRule -Name '$ruleName' -DisplayName '$ruleName' -Group '$group' -Description 'Temporary Teremoq LAN run $RunId; exact client only' -Direction Inbound -Action Allow -Enabled True -Profile '$NetworkProfile' -LocalAddress '$ServerIPv4' -RemoteAddress '$ClientIPv4' -Protocol UDP -LocalPort $MoqUdpPort -EdgeTraversalPolicy Block"
    Write-Output "New-NetFirewallHyperVRule -Name '$hyperVRuleName' -DisplayName '$hyperVRuleName' -Direction Inbound -Action Allow -Enabled True -Profiles '$NetworkProfile' -VMCreatorId '$wslCreatorId' -Protocol UDP -LocalAddresses '$ServerIPv4' -RemoteAddresses '$ClientIPv4' -LocalPorts $MoqUdpPort"
    if ($CoordinationTlsPort -eq 18443) {
        Write-Output "New-NetFirewallRule -Name '$coordinationRuleName' -DisplayName '$coordinationRuleName' -Group '$group' -Description 'Temporary Teremoq LAN coordination for run $RunId; exact client only' -Direction Inbound -Action Allow -Enabled True -Profile '$NetworkProfile' -LocalAddress '$ServerIPv4' -RemoteAddress '$ClientIPv4' -Protocol TCP -LocalPort $CoordinationTlsPort -EdgeTraversalPolicy Block"
        Write-Output "New-NetFirewallHyperVRule -Name '$coordinationHyperVRuleName' -DisplayName '$coordinationHyperVRuleName' -Direction Inbound -Action Allow -Enabled True -Profiles '$NetworkProfile' -VMCreatorId '$wslCreatorId' -Protocol TCP -LocalAddresses '$ServerIPv4' -RemoteAddresses '$ClientIPv4' -LocalPorts $CoordinationTlsPort"
    }
    Write-Output "Remove-NetFirewallRule -Name '$ruleName' -ErrorAction SilentlyContinue"
    Write-Output "Remove-NetFirewallHyperVRule -Name '$hyperVRuleName' -ErrorAction SilentlyContinue"
    if ($CoordinationTlsPort -eq 18443) {
        Write-Output "Remove-NetFirewallRule -Name '$coordinationRuleName' -ErrorAction SilentlyContinue"
        Write-Output "Remove-NetFirewallHyperVRule -Name '$coordinationHyperVRuleName' -ErrorAction SilentlyContinue"
    }
    Write-Output "# Verify both exact names are absent; do not change DefaultInboundAction or the network profile."
    exit 0
}
if ($Action -eq 'Verify') {
    $classicRules = @(Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)
    $hypervRules = @(Get-NetFirewallHyperVRule -Name $hyperVRuleName -ErrorAction SilentlyContinue)
    if ($classicRules.Count -ne 1 -or $hypervRules.Count -ne 1) { throw 'exactly one classic and one Hyper-V rule must exist' }
    $classic = $classicRules[0]
    $hyperv = $hypervRules[0]
    $addressFilters = @($classic | Get-NetFirewallAddressFilter)
    $portFilters = @($classic | Get-NetFirewallPortFilter)
    if ($addressFilters.Count -ne 1 -or $portFilters.Count -ne 1) { throw 'classic rule filter cardinality differs from the exact plan' }
    $addressFilter = $addressFilters[0]
    $portFilter = $portFilters[0]
    if ([string]$classic.Name -cne $ruleName -or [string]$classic.DisplayName -cne $ruleName -or
        [string]$classic.Group -cne $group -or [string]$classic.Description -cne "Temporary Teremoq LAN run $RunId; exact client only" -or
        [string]$classic.Enabled -ne 'True' -or [string]$classic.Direction -ne 'Inbound' -or [string]$classic.Action -ne 'Allow' -or
        [string]$classic.Profile -ne $NetworkProfile -or [string]$classic.EdgeTraversalPolicy -ne 'Block' -or
        @($addressFilter.LocalAddress).Count -ne 1 -or @($addressFilter.RemoteAddress).Count -ne 1 -or
        [string]$addressFilter.LocalAddress -cne $ServerIPv4 -or [string]$addressFilter.RemoteAddress -cne $ClientIPv4 -or
        [string]$portFilter.Protocol -notmatch '^(UDP|17)$' -or [string]$portFilter.LocalPort -ne [string]$MoqUdpPort -or
        [string]$portFilter.RemotePort -ne 'Any') { throw 'classic rule properties differ from the exact plan' }
    if ([string]$hyperv.Name -cne $hyperVRuleName -or [string]$hyperv.DisplayName -cne $hyperVRuleName -or
        [string]$hyperv.Enabled -ne 'True' -or [string]$hyperv.Direction -ne 'Inbound' -or [string]$hyperv.Action -ne 'Allow' -or
        [string]$hyperv.VMCreatorId -cne $wslCreatorId -or @($hyperv.LocalAddresses).Count -ne 1 -or
        @($hyperv.RemoteAddresses).Count -ne 1 -or @($hyperv.LocalPorts).Count -ne 1 -or
        [string]$hyperv.LocalAddresses -cne $ServerIPv4 -or [string]$hyperv.RemoteAddresses -cne $ClientIPv4 -or
        [string]$hyperv.Protocol -notmatch '^(UDP|17)$' -or [string]$hyperv.LocalPorts -ne [string]$MoqUdpPort -or
        [string]$hyperv.Profiles -ne $NetworkProfile) {
        throw 'Hyper-V rule properties differ from the exact plan'
    }
    if ($CoordinationTlsPort -eq 18443) {
        $coordinationClassicRules = @(Get-NetFirewallRule -Name $coordinationRuleName -ErrorAction SilentlyContinue)
        $coordinationHyperVRules = @(Get-NetFirewallHyperVRule -Name $coordinationHyperVRuleName -ErrorAction SilentlyContinue)
        if ($coordinationClassicRules.Count -ne 1 -or $coordinationHyperVRules.Count -ne 1) { throw 'exactly one classic and one Hyper-V coordination rule must exist' }
        $coordinationClassic = $coordinationClassicRules[0]
        $coordinationHyperv = $coordinationHyperVRules[0]
        $coordinationAddressFilters = @($coordinationClassic | Get-NetFirewallAddressFilter)
        $coordinationPortFilters = @($coordinationClassic | Get-NetFirewallPortFilter)
        if ($coordinationAddressFilters.Count -ne 1 -or $coordinationPortFilters.Count -ne 1) { throw 'coordination rule filter cardinality differs from the exact plan' }
        $coordinationAddressFilter = $coordinationAddressFilters[0]
        $coordinationPortFilter = $coordinationPortFilters[0]
        if ([string]$coordinationClassic.Name -cne $coordinationRuleName -or [string]$coordinationClassic.DisplayName -cne $coordinationRuleName -or
            [string]$coordinationClassic.Group -cne $group -or [string]$coordinationClassic.Description -cne "Temporary Teremoq LAN coordination for run $RunId; exact client only" -or
            [string]$coordinationClassic.Enabled -ne 'True' -or [string]$coordinationClassic.Direction -ne 'Inbound' -or
            [string]$coordinationClassic.Action -ne 'Allow' -or [string]$coordinationClassic.Profile -ne $NetworkProfile -or
            [string]$coordinationClassic.EdgeTraversalPolicy -ne 'Block' -or
            @($coordinationAddressFilter.LocalAddress).Count -ne 1 -or @($coordinationAddressFilter.RemoteAddress).Count -ne 1 -or
            [string]$coordinationAddressFilter.LocalAddress -cne $ServerIPv4 -or [string]$coordinationAddressFilter.RemoteAddress -cne $ClientIPv4 -or
            [string]$coordinationPortFilter.Protocol -notmatch '^(TCP|6)$' -or [string]$coordinationPortFilter.LocalPort -ne '18443' -or
            [string]$coordinationPortFilter.RemotePort -ne 'Any') { throw 'classic coordination rule properties differ from the exact plan' }
        if ([string]$coordinationHyperv.Name -cne $coordinationHyperVRuleName -or [string]$coordinationHyperv.DisplayName -cne $coordinationHyperVRuleName -or
            [string]$coordinationHyperv.Enabled -ne 'True' -or [string]$coordinationHyperv.Direction -ne 'Inbound' -or
            [string]$coordinationHyperv.Action -ne 'Allow' -or [string]$coordinationHyperv.VMCreatorId -cne $wslCreatorId -or
            @($coordinationHyperv.LocalAddresses).Count -ne 1 -or @($coordinationHyperv.RemoteAddresses).Count -ne 1 -or
            @($coordinationHyperv.LocalPorts).Count -ne 1 -or [string]$coordinationHyperv.LocalAddresses -cne $ServerIPv4 -or
            [string]$coordinationHyperv.RemoteAddresses -cne $ClientIPv4 -or [string]$coordinationHyperv.Protocol -notmatch '^(TCP|6)$' -or
            [string]$coordinationHyperv.LocalPorts -ne '18443' -or [string]$coordinationHyperv.Profiles -ne $NetworkProfile) {
            throw 'Hyper-V coordination rule properties differ from the exact plan'
        }
    }
    $attestation = [ordered]@{
        schema_version = 1; run_id = $RunId; source_commit = $SourceCommit
        server_ipv4 = $ServerIPv4; client_ipv4 = $ClientIPv4; network_profile = $NetworkProfile
        protocol = 'UDP'; local_port = $MoqUdpPort
        classic_rule_name = $ruleName; hyperv_rule_name = $hyperVRuleName
        classic_rule_count = $classicRules.Count; hyperv_rule_count = $hypervRules.Count
        edge_traversal_policy = 'Block'; firewall_verified = $true; default_inbound_action_changed = $false
    }
    if ($CoordinationTlsPort -eq 18443) {
        $attestation.coordination_tls_port = 18443
        $attestation.coordination_firewall_verified = $true
    }
    $attestation | ConvertTo-Json -Compress
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
    if ($CoordinationTlsPort -eq 18443 -and (Get-NetFirewallRule -Name $coordinationRuleName -ErrorAction SilentlyContinue)) { throw 'classic coordination firewall rule already exists' }
    if ($CoordinationTlsPort -eq 18443 -and (Get-NetFirewallHyperVRule -Name $coordinationHyperVRuleName -ErrorAction SilentlyContinue)) { throw 'Hyper-V coordination firewall rule already exists' }
    New-NetFirewallRule @newRule | Out-Null
    try {
        New-NetFirewallHyperVRule -Name $hyperVRuleName -DisplayName $hyperVRuleName -Direction Inbound -Action Allow -Enabled True -Profiles $NetworkProfile -VMCreatorId $wslCreatorId -Protocol UDP -LocalAddresses $ServerIPv4 -RemoteAddresses $ClientIPv4 -LocalPorts $MoqUdpPort | Out-Null
        if ($CoordinationTlsPort -eq 18443) {
            New-NetFirewallRule @newCoordinationRule | Out-Null
            New-NetFirewallHyperVRule -Name $coordinationHyperVRuleName -DisplayName $coordinationHyperVRuleName -Direction Inbound -Action Allow -Enabled True -Profiles $NetworkProfile -VMCreatorId $wslCreatorId -Protocol TCP -LocalAddresses $ServerIPv4 -RemoteAddresses $ClientIPv4 -LocalPorts $CoordinationTlsPort | Out-Null
        }
    } catch {
        Remove-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
        Remove-NetFirewallRule -Name $coordinationRuleName -ErrorAction SilentlyContinue
        Remove-NetFirewallHyperVRule -Name $hyperVRuleName -ErrorAction SilentlyContinue
        Remove-NetFirewallHyperVRule -Name $coordinationHyperVRuleName -ErrorAction SilentlyContinue
        throw
    }
    Write-Output "created exact classic and Hyper-V rules for $group"
    exit 0
}
$classic = @(Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)
$hyperv = @(Get-NetFirewallHyperVRule -Name $hyperVRuleName -ErrorAction SilentlyContinue)
$coordinationClassic = @()
$coordinationHyperv = @()
if ($CoordinationTlsPort -eq 18443) {
    $coordinationClassic = @(Get-NetFirewallRule -Name $coordinationRuleName -ErrorAction SilentlyContinue)
    $coordinationHyperv = @(Get-NetFirewallHyperVRule -Name $coordinationHyperVRuleName -ErrorAction SilentlyContinue)
}
if ($classic.Count -gt 0) { Remove-NetFirewallRule -Name $ruleName }
if ($hyperv.Count -gt 0) { Remove-NetFirewallHyperVRule -Name $hyperVRuleName }
if ($coordinationClassic.Count -gt 0) { Remove-NetFirewallRule -Name $coordinationRuleName }
if ($coordinationHyperv.Count -gt 0) { Remove-NetFirewallHyperVRule -Name $coordinationHyperVRuleName }
if (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue) { throw 'classic rule residue remains' }
if (Get-NetFirewallHyperVRule -Name $hyperVRuleName -ErrorAction SilentlyContinue) { throw 'Hyper-V rule residue remains' }
if ($CoordinationTlsPort -eq 18443 -and (Get-NetFirewallRule -Name $coordinationRuleName -ErrorAction SilentlyContinue)) { throw 'classic coordination rule residue remains' }
if ($CoordinationTlsPort -eq 18443 -and (Get-NetFirewallHyperVRule -Name $coordinationHyperVRuleName -ErrorAction SilentlyContinue)) { throw 'Hyper-V coordination rule residue remains' }
[ordered]@{
    schema_version = 1; run_id = $RunId; source_commit = $SourceCommit
    server_ipv4 = $ServerIPv4; client_ipv4 = $ClientIPv4
    quic_udp_port = $MoqUdpPort; coordination_tls_port = $CoordinationTlsPort
    classic_rules_absent = $true; hyperv_rules_absent = $true
    default_inbound_action_changed = $false; status = 'rolled_back'
} | ConvertTo-Json -Compress
