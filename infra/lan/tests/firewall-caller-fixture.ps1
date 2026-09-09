# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [Parameter(Mandatory = $true)][string]$SourceCommit,
    [Parameter(Mandatory = $true)][string]$ServerIPv4,
    [Parameter(Mandatory = $true)][string]$ClientIPv4,
    [Parameter(Mandatory = $true)][string]$RouterIPv4,
    [Parameter(Mandatory = $true)][ValidateRange(8, 30)][int]$PrefixLength,
    [Parameter(Mandatory = $true)][ValidateSet('Public', 'Private')][string]$NetworkProfile
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

& $ScriptPath -Action Validate -RunId lan-firewall-caller-test -SourceCommit $SourceCommit `
    -ServerIPv4 $ServerIPv4 -ClientIPv4 $ClientIPv4 -RouterIPv4 $RouterIPv4 `
    -PrefixLength $PrefixLength -NetworkProfile $NetworkProfile -CoordinationTlsPort 18443 | Out-Null

Write-Output 'firewall-caller-survived'
