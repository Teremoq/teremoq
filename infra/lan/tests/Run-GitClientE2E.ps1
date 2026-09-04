# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CheckoutRoot,
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [Parameter(Mandatory = $true)][string]$RepositoryUrl,
    [Parameter(Mandatory = $true)][string]$RepositoryRef,
    [Parameter(Mandatory = $true)][string]$ExpectedCommit,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$ServerIPv4,
    [Parameter(Mandatory = $true)][int]$PrefixLength,
    [Parameter(Mandatory = $true)][string]$Namespace,
    [Parameter(Mandatory = $true)][string]$FingerprintSha256
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
if ($RepositoryUrl -cne 'https://github.com/Teremoq/teremoq' -or $RepositoryRef -cnotmatch '^refs/heads/' -or $ExpectedCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'invalid E2E Git inputs' }
$branch = $RepositoryRef.Substring('refs/heads/'.Length)
git clone --origin origin --branch $branch --single-branch --no-tags $RepositoryUrl $CheckoutRoot
if ($LASTEXITCODE -ne 0) { throw 'Git clone failed' }
& "$CheckoutRoot\infra\lan\client\Install-LanClient.ps1" -CheckoutRoot $CheckoutRoot -RepositoryUrl $RepositoryUrl -RepositoryRef $RepositoryRef -ExpectedCommit $ExpectedCommit -RepositorySubdirectory infra/lan
& "$CheckoutRoot\supervisor-web\lan-player\Build-LanPlayerFromGit.ps1" -CheckoutRoot $CheckoutRoot -StateRoot $StateRoot -RepositoryUrl $RepositoryUrl -RepositoryRef $RepositoryRef -SourceCommit $ExpectedCommit
$build = Get-Content -LiteralPath (Join-Path $StateRoot '.teremoq-web-build\generations\' + $ExpectedCommit + '.tsv') -Raw
if ($build.Length -gt 8192 -or $build -notmatch "player_relative_path`tplayers/$ExpectedCommit") { throw 'Web builder output provenance missing' }
& "$CheckoutRoot\infra\lan\client\Initialize-LanClientState.ps1" -CheckoutRoot $CheckoutRoot -StateRoot $StateRoot -RepositoryUrl $RepositoryUrl -RepositoryRef $RepositoryRef -ExpectedCommit $ExpectedCommit -RepositorySubdirectory infra/lan -PlayerRelativePath "players/$ExpectedCommit" -RunId $RunId -ServerIPv4 $ServerIPv4 -PrefixLength $PrefixLength -Namespace $Namespace -FingerprintSha256 $FingerprintSha256
& "$CheckoutRoot\infra\lan\client\Verify-Package.ps1" -CheckoutRoot $CheckoutRoot -StateRoot $StateRoot
& "$CheckoutRoot\infra\lan\client\Update-LanClient.ps1" -CheckoutRoot $CheckoutRoot -StateRoot $StateRoot
Write-Output 'lan-git-client-e2e: pass'
