# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Activate','Confirm','Rollback','Resolve','SupersedeUnconfirmed','RestoreUnconfirmed','UnconfirmedStatus')][string]$Action,
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [string]$TransitionId,
    [string]$ConfirmTransitionId,
    [string]$ExpectedSourceSha256,
    [string]$ExpectedTargetSha256,
    [string]$ExpectedTargetCommit,
    [string]$TargetRecordPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot 'Client-Distribution.ps1')
. (Join-Path $PSScriptRoot 'Client-Slot-State.ps1')

if ($Action -cin @('SupersedeUnconfirmed','RestoreUnconfirmed','UnconfirmedStatus')) {
    if ([string]::IsNullOrEmpty($TransitionId) -or $ConfirmTransitionId -cne $TransitionId) {
        throw 'explicit confirmation of the exact assisted transition ID is required'
    }
    $transitionAction = switch ($Action) { 'SupersedeUnconfirmed' { 'Supersede' }; 'RestoreUnconfirmed' { 'Restore' }; 'UnconfirmedStatus' { 'Status' } }
    Invoke-TeremoqAssistedUnconfirmedTransition -Action $transitionAction -StateRoot $StateRoot `
        -TransitionId $TransitionId -ExpectedSourceSha256 $ExpectedSourceSha256 -ExpectedTargetSha256 $ExpectedTargetSha256 `
        -ExpectedTargetCommit $ExpectedTargetCommit -TargetRecordPath $TargetRecordPath | ConvertTo-Json -Compress
    exit 0
}
if ($TransitionId -or $ConfirmTransitionId -or $ExpectedSourceSha256 -or $ExpectedTargetSha256 -or $ExpectedTargetCommit -or $TargetRecordPath) {
    throw 'assisted transition arguments cannot override a legacy state action'
}

$result = switch ($Action) {
    'Activate' { Activate-TeremoqLanClientSlot -StateRoot $StateRoot }
    'Confirm' { Confirm-TeremoqLanClientSlot -StateRoot $StateRoot }
    'Rollback' { Rollback-TeremoqLanClientSlot -StateRoot $StateRoot }
    'Resolve' { Get-TeremoqActiveLanClientSlot -StateRoot $StateRoot }
}
$result | ConvertTo-Json -Compress -Depth 4
