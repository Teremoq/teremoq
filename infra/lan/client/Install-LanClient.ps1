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
. (Join-Path $PSScriptRoot 'Client-Distribution.ps1')

$checkout = [IO.Path]::GetFullPath($CheckoutRoot)
Assert-TeremoqApprovedGitBootstrapParameters -RepositoryUrl $RepositoryUrl -RepositoryRef $RepositoryRef -ExpectedCommit $ExpectedCommit -RepositorySubdirectory $RepositorySubdirectory
if (Test-Path -LiteralPath $checkout) {
    $existing = Get-TeremoqGitBootstrapCheckoutContext -CheckoutRoot $checkout -RepositoryUrl $RepositoryUrl -RepositoryRef $RepositoryRef -ExpectedCommit $ExpectedCommit -RepositorySubdirectory $RepositorySubdirectory
    Write-Output ("Teremoq LAN Git checkout already validates at {0} for commit {1}; no overwrite occurred." -f $existing.CheckoutRoot, $existing.Head)
    exit 0
}
$parent = Split-Path -Parent $checkout
if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'CheckoutRoot parent directory must already exist' }
if (((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'CheckoutRoot parent may not be a reparse point' }
$branch = Get-TeremoqRepositoryBranchName -RepositoryRef $RepositoryRef
$temporary = Join-Path $parent ("." + [IO.Path]::GetFileName($checkout) + ".tmp." + [Guid]::NewGuid().ToString('N'))
try {
    Invoke-TeremoqGit -CheckoutRoot $parent -Arguments @('clone', '--origin', 'origin', '--branch', $branch, '--single-branch', '--no-tags', $RepositoryUrl, $temporary) | Out-Null
    $cloned = Get-TeremoqGitBootstrapCheckoutContext -CheckoutRoot $temporary -RepositoryUrl $RepositoryUrl -RepositoryRef $RepositoryRef -ExpectedCommit $ExpectedCommit -RepositorySubdirectory $RepositorySubdirectory
    Move-Item -LiteralPath $temporary -Destination $checkout
    Write-Output ("Teremoq LAN Git checkout installed at {0} for commit {1}; initialize external state only after this exact clone is verified." -f $checkout, $cloned.Head)
} finally {
    if (Test-Path -LiteralPath $temporary) {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}
