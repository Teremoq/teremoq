# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [Parameter(Mandatory = $true)][string]$CheckoutRoot,
    [Parameter(Mandatory = $true)][string]$ExpectedCommit,
    [Parameter()][string]$NewStateRoot,
    [switch]$RefreshDependencies,
    [switch]$Offline
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot 'Client-Distribution.ps1')

$state = Get-TeremoqLanStateContext -StateRoot $StateRoot
$checkout = Get-TeremoqGitCheckoutContext -CheckoutRoot $CheckoutRoot -StateContext $state -RequireExactHead
$currentCommit = $state.Compatibility.allowed_client_commit
if ($ExpectedCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'ExpectedCommit must be an exact lowercase Git commit' }
if ($ExpectedCommit -cne $currentCommit) {
    if ([string]::IsNullOrWhiteSpace($NewStateRoot)) { throw 'NewStateRoot is required when advancing to a new commit' }
    $newState = [IO.Path]::GetFullPath($NewStateRoot)
    if (Test-Path -LiteralPath $newState) { throw 'NewStateRoot must be absent so the previous local state is never overwritten' }
    [void](Get-TeremoqNonReparseDirectoryPath -Path (Split-Path -Parent $newState))
    Assert-TeremoqRootsSeparated -CheckoutRoot $checkout.CheckoutRoot -StateRoot $newState
    if ($newState.Equals($state.StateRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'NewStateRoot must differ from the previous local state' }
}
$updated = Invoke-TeremoqGitFastForwardUpdate -CheckoutRoot $checkout.CheckoutRoot `
    -RepositoryUrl $state.Compatibility.repository_url -RepositoryRef $state.Compatibility.repository_ref `
    -RepositorySubdirectory $state.Compatibility.repository_subdirectory -CurrentCommit $currentCommit -ExpectedCommit $ExpectedCommit
if ($ExpectedCommit -ceq $currentCommit) {
    Write-Output ("Teremoq LAN Git checkout already matches approved commit {0}; external state at {1} was left untouched." -f $updated.Head, $state.StateRoot)
    exit 0
}
$prepare = Join-Path $updated.CheckoutRoot 'infra\lan\client\Prepare-LanClientFromGit.ps1'
$arguments = @{
    CheckoutRoot = $updated.CheckoutRoot
    StateRoot = [IO.Path]::GetFullPath($NewStateRoot)
    RepositoryUrl = $state.Compatibility.repository_url
    RepositoryRef = $state.Compatibility.repository_ref
    ExpectedCommit = $ExpectedCommit
    RunId = $state.LanConfig.run_id
    ServerIPv4 = $state.Version.server_ipv4
    PrefixLength = [int]$state.LanConfig.prefix_length
    Namespace = $state.LanConfig.namespace
    FingerprintSha256 = $state.LanConfig.fingerprint_sha256
}
if ($RefreshDependencies) { $arguments.RefreshDependencies = $true }
if ($Offline) { $arguments.Offline = $true }
& $prepare @arguments
$newContext = Get-TeremoqLanStateContext -StateRoot ([IO.Path]::GetFullPath($NewStateRoot))
[void](Get-TeremoqGitCheckoutContext -CheckoutRoot $updated.CheckoutRoot -StateContext $newContext -RequireExactHead)
if ($newContext.LanConfig.run_id -cne $state.LanConfig.run_id -or
    $newContext.LanConfig.relay_url -cne $state.LanConfig.relay_url -or
    $newContext.LanConfig.fingerprint_sha256 -cne $state.LanConfig.fingerprint_sha256 -or
    [int]$newContext.LanConfig.prefix_length -ne [int]$state.LanConfig.prefix_length -or
    $newContext.LanConfig.namespace -cne $state.LanConfig.namespace) {
    throw 'updated client state did not preserve the local LAN configuration'
}
Write-Output ("Teremoq LAN Git checkout advanced to {0}; new state is {1}; previous state {2} was preserved." -f $updated.Head, $newContext.StateRoot, $state.StateRoot)
