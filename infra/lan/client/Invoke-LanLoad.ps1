# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Validate', 'Start', 'Status', 'Stop', 'Collect')][string]$Action,
    [Parameter(Mandatory = $true)][ValidateSet(1, 5, 10, 25)][int]$Level,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$CheckoutRoot,
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [Parameter(Mandatory = $true)][string]$EvidenceRoot,
    [switch]$ConfirmStart
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot 'Client-Distribution.ps1')

if ($RunId -notmatch '^lan-[a-z0-9][a-z0-9-]{0,31}$') { throw 'invalid RunId' }
$state = Get-TeremoqLanStateContext -StateRoot $StateRoot
$checkout = Get-TeremoqGitCheckoutContext -CheckoutRoot $CheckoutRoot -StateContext $state -RequireExactHead
if ($state.Version.run_id -cne $RunId) { throw 'RunId differs from the approved external client state' }
$evidenceRootFull = [IO.Path]::GetFullPath($EvidenceRoot)
if (-not (Test-Path -LiteralPath $evidenceRootFull -PathType Container)) { throw 'EvidenceRoot must exist' }
if (((Get-Item -LiteralPath $evidenceRootFull -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'EvidenceRoot may not be a reparse point' }
$node = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
$nodeVersion = if ($node) { (& $node.Source --version 2>$null | Out-String).Trim() } else { 'unavailable' }
if ($nodeVersion -notmatch '^v22\.[0-9]+\.[0-9]+$') { throw 'approved Node 22.x runtime is required; no runtime is embedded or installed' }
if ($Action -eq 'Validate') {
    Write-Output ("TP-WEB-REALTIME LAN launcher contract and Git checkout are valid for commit {0}; no player started." -f $checkout.Head)
    exit 0
}
if ($Action -eq 'Start' -and -not $ConfirmStart) { throw 'Start requires -ConfirmStart' }
if ($Action -eq 'Start' -and @(Get-NetTCPConnection -State Listen -LocalPort 3000 -ErrorAction SilentlyContinue).Count -ne 0) { throw 'reserved player loopback TCP/3000 is occupied' }
$evidence = Join-Path (Join-Path $evidenceRootFull $RunId) "level-$Level"
if ($Action -eq 'Start') {
    if (Test-Path -LiteralPath $evidence) { throw 'deterministic player evidence directory already exists' }
    New-Item -ItemType Directory -Path $evidence -Force | Out-Null
} elseif (-not (Test-Path -LiteralPath $evidence -PathType Container)) {
    throw 'deterministic player evidence directory does not exist for this action'
}
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $state.LauncherPath `
    -Action $Action -RunId $RunId -Level $Level -VersionPath (Join-Path $state.StateRoot 'VERSION.tsv') `
    -FingerprintPath (Join-Path $state.StateRoot 'public-identity\relay-cert.sha256') -EvidenceDirectory $evidence
if ($LASTEXITCODE -ne 0) { throw "TP-WEB-REALTIME LAN launcher failed: $LASTEXITCODE" }
if ($Action -eq 'Collect') { Write-Output 'Import the exact browser JSON with Import-BrowserObservation.ps1; launcher output/hash alone is not composite gate evidence.' }
