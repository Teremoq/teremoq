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

function New-ValidationState {
    param([Parameter(Mandatory = $true)][string]$Commit)
    return [pscustomobject]@{
        StateRoot = (Join-Path $root 'update-validation-state')
        Compatibility = [pscustomobject]@{
            repository_url = $RepositoryUrl
            repository_ref = $RepositoryRef
            repository_subdirectory = 'infra/lan'
            allowed_client_commit = $Commit
        }
        RepositorySubdirectory = 'infra/lan'
    }
}

$current = [IO.Path]::GetFullPath($CheckoutRoot).TrimEnd('\', '/')
$root = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Teremoq')).TrimEnd('\', '/')
if (-not $current.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'current checkout is outside the Teremoq client root'
}
[void](Get-TeremoqNonReparseDirectoryPath -Path $root)
[void](Get-TeremoqGitCheckoutContext -CheckoutRoot $current -StateContext (New-ValidationState $CurrentCommit) -RequireExactHead)

$slotA = Join-Path $root 'checkout-updater-a'
$slotB = Join-Path $root 'checkout-updater-b'
$target = if ($current.Equals($slotA, [StringComparison]::OrdinalIgnoreCase)) { $slotB } else { $slotA }
if ($target.Equals($current, [StringComparison]::OrdinalIgnoreCase)) { throw 'inactive updater slot selection failed' }

if (-not (Test-Path -LiteralPath $target)) {
    $branch = Get-TeremoqRepositoryBranchName -RepositoryRef $RepositoryRef
    $temporary = Join-Path $root ('.checkout-updater-stage-' + [Guid]::NewGuid().ToString('N'))
    try {
        Invoke-TeremoqGit -CheckoutRoot $root -Arguments @(
            'clone','--local','--no-hardlinks','--origin','origin','--branch',$branch,
            '--single-branch','--no-tags',$current,$temporary
        ) | Out-Null
        Invoke-TeremoqGit -CheckoutRoot $temporary -Arguments @('remote','set-url','origin',$RepositoryUrl) | Out-Null
        foreach ($setting in @(@('core.autocrlf','false'), @('core.eol','lf'), @('core.safecrlf','true'))) {
            Invoke-TeremoqGit -CheckoutRoot $temporary -Arguments @('config','--local',$setting[0],$setting[1]) | Out-Null
        }
        [void](Get-TeremoqGitCheckoutContext -CheckoutRoot $temporary -StateContext (New-ValidationState $CurrentCommit) -RequireExactHead)
        [IO.Directory]::Move($temporary, $target)
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-TeremoqBoundedRegularTree -Path $temporary -ExpectedParent $root
        }
    }
}

$targetHead = Invoke-TeremoqGit -CheckoutRoot $target -Arguments @('rev-parse','HEAD')
if ($targetHead -cnotmatch '^[0-9a-f]{40}$') { throw 'inactive updater slot has no exact Git commit' }
[void](Get-TeremoqGitCheckoutContext -CheckoutRoot $target -StateContext (New-ValidationState $targetHead) -RequireExactHead)
$updated = Invoke-TeremoqGitFastForwardUpdate -CheckoutRoot $target -RepositoryUrl $RepositoryUrl `
    -RepositoryRef $RepositoryRef -RepositorySubdirectory 'infra/lan' -CurrentCommit $targetHead -ExpectedCommit $TargetCommit
[void](Get-TeremoqGitCheckoutContext -CheckoutRoot $updated.CheckoutRoot -StateContext (New-ValidationState $TargetCommit) -RequireExactHead)
Write-Output ("update staged in inactive A/B slot at commit={0}; slot={1}" -f $updated.Head, [IO.Path]::GetFileName($target))
