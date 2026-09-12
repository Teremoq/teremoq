# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [Parameter(Mandatory = $true)][string]$CheckoutRoot,
    [Parameter(Mandatory = $true)][string]$ExpectedCommit
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

$state = Get-TeremoqLanStateContext -StateRoot $StateRoot
$checkout = Get-TeremoqGitCheckoutContext -CheckoutRoot $CheckoutRoot -StateContext $state -RequireExactHead
$currentCommit = $state.Compatibility.allowed_client_commit
if ($ExpectedCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'ExpectedCommit must be an exact lowercase Git commit' }
if ($ExpectedCommit -ceq $currentCommit) {
    Write-Output ("Teremoq updater already matches {0}; active updater, player and local configuration were reused." -f $currentCommit)
    exit 0
}

$stage = Join-Path $checkout.CheckoutRoot 'infra\lan\client\Stage-LanClientUpdate.ps1'
& $stage -CheckoutRoot $checkout.CheckoutRoot -CurrentCommit $currentCommit -TargetCommit $ExpectedCommit `
    -RepositoryUrl $state.Compatibility.repository_url -RepositoryRef $state.Compatibility.repository_ref
Write-Output ("Teremoq updater {0} is verified in the inactive A/B slot; the active updater and configuration were not changed." -f $ExpectedCommit)
