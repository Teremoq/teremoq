# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [ValidateSet('none', 'edge', 'cardinality', 'coordination-protocol')][string]$Tamper = 'none',
    [switch]$WithCoordination
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$runId = 'lan-firewall-test'
$sourceCommit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$serverIPv4 = '192.168.77.10'
$clientIPv4 = '192.168.77.20'
$routerIPv4 = '192.168.77.1'
$global:TeremoqTestNetworkProfile = 'Public'
$group = "Teremoq-LAN-$runId"
$classicName = "$group-Defender-QUIC-UDP-14433"
$hypervName = "$group-HyperV-QUIC-UDP-14433"
$edge = if ($Tamper -eq 'edge') { 'Allow' } else { 'Block' }
$classic = [pscustomobject]@{
    Name = $classicName; DisplayName = $classicName; Group = $group
    Description = "Temporary Teremoq LAN run $runId; exact client only"
    Enabled = 'True'; Direction = 'Inbound'; Action = 'Allow'; Profile = $global:TeremoqTestNetworkProfile; EdgeTraversalPolicy = $edge
}
$global:TeremoqTestClassicRules = if ($Tamper -eq 'cardinality') { @($classic, $classic) } else { @($classic) }
$global:TeremoqTestHyperVRules = @([pscustomobject]@{
    Name = $hypervName; DisplayName = $hypervName; Enabled = 'True'; Direction = 'Inbound'; Action = 'Allow'
    Profiles = $global:TeremoqTestNetworkProfile; VMCreatorId = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'; Protocol = 'UDP'
    LocalAddresses = @($serverIPv4); RemoteAddresses = @($clientIPv4); LocalPorts = @(14433)
})
$global:TeremoqTestAddressFilter = [pscustomobject]@{ LocalAddress = @($serverIPv4); RemoteAddress = @($clientIPv4) }
$global:TeremoqTestPortFilter = [pscustomobject]@{ Protocol = 'UDP'; LocalPort = 14433; RemotePort = 'Any' }
$coordinationClassicName = "$group-Defender-Control-TCP-18443"
$coordinationHypervName = "$group-HyperV-Control-TCP-18443"
$coordinationClassic = [pscustomobject]@{
    Name = $coordinationClassicName; DisplayName = $coordinationClassicName; Group = $group
    Description = "Temporary Teremoq LAN coordination for run $runId; exact client only"
    Enabled = 'True'; Direction = 'Inbound'; Action = 'Allow'; Profile = $global:TeremoqTestNetworkProfile; EdgeTraversalPolicy = 'Block'
}
$coordinationHyperv = [pscustomobject]@{
    Name = $coordinationHypervName; DisplayName = $coordinationHypervName; Enabled = 'True'; Direction = 'Inbound'; Action = 'Allow'
    Profiles = $global:TeremoqTestNetworkProfile; VMCreatorId = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
    Protocol = $(if ($Tamper -eq 'coordination-protocol') { 'UDP' } else { 'TCP' })
    LocalAddresses = @($serverIPv4); RemoteAddresses = @($clientIPv4); LocalPorts = @(18443)
}

function Get-NetIPAddress { [CmdletBinding()] param([string]$AddressFamily, [string]$IPAddress) [pscustomobject]@{ InterfaceIndex = 7 } }
function Get-NetConnectionProfile { [CmdletBinding()] param([int]$InterfaceIndex) [pscustomobject]@{ NetworkCategory = $global:TeremoqTestNetworkProfile } }
function Get-NetFirewallRule {
    [CmdletBinding()] param([string]$Name)
    if ($Name -eq $coordinationClassicName -and $WithCoordination) { return @($coordinationClassic) }
    if ($Name -eq $classicName) { return $global:TeremoqTestClassicRules }
    return @()
}
function Get-NetFirewallHyperVRule {
    [CmdletBinding()] param([string]$Name)
    if ($Name -eq $coordinationHypervName -and $WithCoordination) { return @($coordinationHyperv) }
    if ($Name -eq $hypervName) { return $global:TeremoqTestHyperVRules }
    return @()
}
function Get-NetFirewallAddressFilter {
    [CmdletBinding()] param([Parameter(ValueFromPipeline = $true)]$InputObject)
    process { [pscustomobject]@{ LocalAddress = @($serverIPv4); RemoteAddress = @($clientIPv4) } }
}
function Get-NetFirewallPortFilter {
    [CmdletBinding()] param([Parameter(ValueFromPipeline = $true)]$InputObject)
    process {
        if ($InputObject.Name -eq $coordinationClassicName) {
            [pscustomobject]@{ Protocol = $(if ($Tamper -eq 'coordination-protocol') { 'UDP' } else { 'TCP' }); LocalPort = 18443; RemotePort = 'Any' }
        } else { $global:TeremoqTestPortFilter }
    }
}

& $ScriptPath -Action Verify -RunId $runId -SourceCommit $sourceCommit `
    -ServerIPv4 $serverIPv4 -ClientIPv4 $clientIPv4 -RouterIPv4 $routerIPv4 `
    -PrefixLength 24 -NetworkProfile $global:TeremoqTestNetworkProfile `
    -CoordinationTlsPort $(if ($WithCoordination) { 18443 } else { 0 })
