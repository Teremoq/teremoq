# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CheckoutRoot,
    [Parameter(Mandatory = $true)][string]$CurrentCommit,
    [Parameter(Mandatory = $true)][string]$TargetCommit,
    [Parameter(Mandatory = $true)][string]$RepositoryUrl,
    [Parameter(Mandatory = $true)][string]$RepositoryRef
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot 'Client-Distribution.ps1')

if ($RepositoryUrl -cne 'https://github.com/Teremoq/teremoq' -or
    $RepositoryRef -cne 'refs/heads/codex/lan-e2e-integration' -or
    $CurrentCommit -cnotmatch '^[0-9a-f]{40}$' -or
    $TargetCommit -cnotmatch '^[0-9a-f]{40}$' -or
    $TargetCommit -ceq $CurrentCommit) {
    throw 'LAN update identity differs from the closed policy'
}

$current = [IO.Path]::GetFullPath($CheckoutRoot)
$root = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Teremoq'))
if (-not $current.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'current checkout is outside the Teremoq client root'
}
$currentState = [pscustomobject]@{
    StateRoot = (Join-Path $root 'update-validation-state')
    Compatibility = [pscustomobject]@{
        repository_url = $RepositoryUrl
        repository_ref = $RepositoryRef
        repository_subdirectory = 'infra/lan'
        allowed_client_commit = $CurrentCommit
    }
    RepositorySubdirectory = 'infra/lan'
}
[void](Get-TeremoqGitCheckoutContext -CheckoutRoot $current -StateContext $currentState -RequireExactHead)

$target = Join-Path $root ("checkout-lan-{0}" -f $TargetCommit.Substring(0, 8))
$installer = Join-Path $current 'infra\lan\client\Install-LanClient.ps1'
& $installer -CheckoutRoot $target -RepositoryUrl $RepositoryUrl -RepositoryRef $RepositoryRef `
    -ExpectedCommit $TargetCommit -RepositorySubdirectory 'infra/lan'
[void](Invoke-TeremoqGit -CheckoutRoot $target -Arguments @(
    'merge-base', '--is-ancestor', $CurrentCommit, $TargetCommit
))
$targetState = [pscustomobject]@{
    StateRoot = (Join-Path $root 'update-validation-state')
    Compatibility = [pscustomobject]@{
        repository_url = $RepositoryUrl
        repository_ref = $RepositoryRef
        repository_subdirectory = 'infra/lan'
        allowed_client_commit = $TargetCommit
    }
    RepositorySubdirectory = 'infra/lan'
}
$verified = Get-TeremoqGitCheckoutContext -CheckoutRoot $target -StateContext $targetState -RequireExactHead
Write-Output ("update staged and verified at commit={0}" -f $verified.Head)
