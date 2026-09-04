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
$checkout = Get-TeremoqGitCheckoutContext -CheckoutRoot $CheckoutRoot -StateContext $state
$branch = Get-TeremoqRepositoryBranchName -RepositoryRef $state.Compatibility.repository_ref
$currentBranch = Invoke-TeremoqGit -CheckoutRoot $checkout.CheckoutRoot -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')
if ($currentBranch -cne $branch) { throw 'Git checkout is not on the approved LAN branch' }
$upstream = Invoke-TeremoqGit -CheckoutRoot $checkout.CheckoutRoot -Arguments @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}')
if ($upstream -cne ("origin/{0}" -f $branch)) { throw 'Git checkout upstream differs from the approved LAN branch' }
Invoke-TeremoqGit -CheckoutRoot $checkout.CheckoutRoot -Arguments @('fetch', '--no-tags', 'origin', $state.Compatibility.repository_ref) | Out-Null
$fetched = Invoke-TeremoqGit -CheckoutRoot $checkout.CheckoutRoot -Arguments @('rev-parse', 'FETCH_HEAD')
if ($fetched -cne $state.Compatibility.allowed_client_commit) { throw 'fetched commit differs from the approved client commit' }
$currentHead = Invoke-TeremoqGit -CheckoutRoot $checkout.CheckoutRoot -Arguments @('rev-parse', 'HEAD')
if ($currentHead -cne $fetched) {
    try {
        Invoke-TeremoqGit -CheckoutRoot $checkout.CheckoutRoot -Arguments @('merge-base', '--is-ancestor', $currentHead, $fetched) | Out-Null
    } catch {
        throw 'Git checkout diverges from the approved client commit; ff-only update is forbidden'
    }
    Invoke-TeremoqGit -CheckoutRoot $checkout.CheckoutRoot -Arguments @('merge', '--ff-only', $fetched) | Out-Null
}
$verified = Get-TeremoqGitCheckoutContext -CheckoutRoot $checkout.CheckoutRoot -StateContext $state -RequireExactHead
Write-Output ("Teremoq LAN Git checkout is updated to approved commit {0}; external state at {1} was left untouched." -f $verified.Head, $state.StateRoot)
