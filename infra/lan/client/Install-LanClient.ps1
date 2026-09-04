# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [Parameter(Mandatory = $true)][string]$CheckoutRoot
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot 'Client-Distribution.ps1')

$state = Get-TeremoqLanStateContext -StateRoot $StateRoot
$checkout = [IO.Path]::GetFullPath($CheckoutRoot)
Assert-TeremoqRootsSeparated -CheckoutRoot $checkout -StateRoot $state.StateRoot
if (Test-Path -LiteralPath $checkout) { throw 'CheckoutRoot already exists; use Update-LanClient.ps1 for an existing checkout' }
$parent = Split-Path -Parent $checkout
if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'CheckoutRoot parent directory must already exist' }
if (((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'CheckoutRoot parent may not be a reparse point' }
$branch = Get-TeremoqRepositoryBranchName -RepositoryRef $state.Compatibility.repository_ref
$temporary = Join-Path $parent ("." + [IO.Path]::GetFileName($checkout) + ".tmp." + [Guid]::NewGuid().ToString('N'))
try {
    Invoke-TeremoqGit -CheckoutRoot $parent -Arguments @('clone', '--origin', 'origin', '--branch', $branch, '--single-branch', '--no-tags', $state.Compatibility.repository_url, $temporary) | Out-Null
    $cloned = Get-TeremoqGitCheckoutContext -CheckoutRoot $temporary -StateContext $state -RequireExactHead
    Move-Item -LiteralPath $temporary -Destination $checkout
    Write-Output ("Teremoq LAN Git checkout installed at {0} for commit {1}; external state remains at {2}." -f $checkout, $cloned.Head, $state.StateRoot)
} finally {
    if (Test-Path -LiteralPath $temporary) {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}
