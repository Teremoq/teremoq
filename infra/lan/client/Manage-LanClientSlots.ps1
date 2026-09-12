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
# Validate the actual host before dot-sourcing, probes or state mutation.
# Desktop is retained for separate regression only; the selected procedure is Core7.
$desktopHost = $PSVersionTable.PSEdition -ceq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5
$coreHost = $PSVersionTable.PSEdition -ceq 'Core' -and $PSVersionTable.PSVersion.ToString() -ceq '7.6.6'
if (-not ($desktopHost -or $coreHost) -or [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
    -not [Environment]::Is64BitProcess -or ($coreHost -and
    [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() -cne 'X64')) {
    throw 'LAN procedure requires a validated Windows x64 Desktop5 or selected Core7.6.6 host'
}
$hostName = if ($desktopHost) { 'powershell.exe' } else { 'pwsh.exe' }
$hostPath = Join-Path ([IO.Path]::GetFullPath($PSHOME)) $hostName
$hostProcess = [Diagnostics.Process]::GetCurrentProcess()
try {
    if (-not [string]::Equals([IO.Path]::GetFullPath($hostProcess.MainModule.FileName),
            $hostPath, [StringComparison]::OrdinalIgnoreCase)) { throw 'LAN host executable differs from PSHOME' }
} finally { $hostProcess.Dispose() }
$hostEntry = Get-Item -LiteralPath $hostPath -Force
if ($hostEntry.PSIsContainer -or ($hostEntry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'LAN host must be a regular executable'
}
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
