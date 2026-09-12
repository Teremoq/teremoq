# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CheckoutRoot,
    [Parameter(Mandatory = $true)][string]$RepositoryUrl,
    [Parameter(Mandatory = $true)][string]$RepositoryRef,
    [Parameter(Mandatory = $true)][string]$ExpectedCommit,
    [Parameter(Mandatory = $true)][string]$RepositorySubdirectory
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

$checkout = [IO.Path]::GetFullPath($CheckoutRoot)
Assert-TeremoqApprovedGitBootstrapParameters -RepositoryUrl $RepositoryUrl -RepositoryRef $RepositoryRef -ExpectedCommit $ExpectedCommit -RepositorySubdirectory $RepositorySubdirectory
if (Test-Path -LiteralPath $checkout) {
    $existing = Get-TeremoqGitBootstrapCheckoutContext -CheckoutRoot $checkout -RepositoryUrl $RepositoryUrl -RepositoryRef $RepositoryRef -ExpectedCommit $ExpectedCommit -RepositorySubdirectory $RepositorySubdirectory
    Write-Output ("Teremoq LAN Git checkout already validates commit {0}; no overwrite occurred." -f $existing.Head)
    exit 0
}
$parent = Split-Path -Parent $checkout
if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'CheckoutRoot parent directory must already exist' }
if (((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'CheckoutRoot parent may not be a reparse point' }
$branch = Get-TeremoqRepositoryBranchName -RepositoryRef $RepositoryRef
$temporary = Join-Path $parent ("." + [IO.Path]::GetFileName($checkout) + ".tmp." + [Guid]::NewGuid().ToString('N'))
try {
    Invoke-TeremoqGit -CheckoutRoot $parent -Arguments @(
        '-c', 'core.autocrlf=false', '-c', 'core.eol=lf', '-c', 'core.safecrlf=true',
        'clone', '--origin', 'origin', '--branch', $branch, '--single-branch', '--no-tags',
        $RepositoryUrl, $temporary
    ) | Out-Null
    foreach ($setting in @(@('core.autocrlf','false'), @('core.eol','lf'), @('core.safecrlf','true'))) {
        Invoke-TeremoqGit -CheckoutRoot $temporary -Arguments @('config','--local',$setting[0],$setting[1]) | Out-Null
    }
    $cloned = Get-TeremoqGitBootstrapCheckoutContext -CheckoutRoot $temporary -RepositoryUrl $RepositoryUrl -RepositoryRef $RepositoryRef -ExpectedCommit $ExpectedCommit -RepositorySubdirectory $RepositorySubdirectory
    Move-Item -LiteralPath $temporary -Destination $checkout
    Write-Output ("Teremoq LAN Git checkout installed and verified at commit {0}." -f $cloned.Head)
} finally {
    if (Test-Path -LiteralPath $temporary) {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}
