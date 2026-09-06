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
