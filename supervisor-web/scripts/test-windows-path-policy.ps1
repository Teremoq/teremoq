# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$policy = Join-Path $PSScriptRoot 'assert-windows-path-policy.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ("teremoq-path-canary-" + [guid]::NewGuid().ToString('N'))
$originalLocation = Get-Location

function New-Junction([string]$Link, [string]$Target) {
    $output = & cmd.exe /d /s /c "mklink /J `"$Link`" `"$Target`"" 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Link -PathType Container)) {
        throw "junction canary setup failed: $output"
    }
}

function New-DirectorySymlink([string]$Link, [string]$Target) {
    $created = $false
    try {
        & cmd.exe /d /s /c "mklink /D `"$Link`" `"$Target`"" 2>$null | Out-Null
        $created = $LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $Link -PathType Container)
    } catch { $created = $false }
    if ($created) { return 'directory-symlink' }
    New-Junction $Link $Target
    if (-not (Test-Path -LiteralPath $Link -PathType Container)) {
        throw 'symlink privilege unavailable and reparse fallback setup failed'
    }
    return 'junction-reparse-fallback'
}

function Assert-Rejected([string]$Candidate, [bool]$AllowMissing) {
    $failed = $false
    try {
        if ($AllowMissing) { & $policy -Path $Candidate -AllowMissingLeaf | Out-Null }
        else { & $policy -Path $Candidate | Out-Null }
    } catch { $failed = $true }
    if (-not $failed) { throw "path policy accepted a reparse canary" }
}

Set-Location -LiteralPath ([IO.Path]::GetTempPath())
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $checkout = Join-Path $root 'checkout'
    $outside = Join-Path $root 'outside'
    $state = Join-Path $root 'state'
    New-Item -ItemType Directory -Path $checkout, $outside, $state | Out-Null

    $parentJunction = Join-Path $root 'junction-parent'
    New-Junction $parentJunction $checkout
    Assert-Rejected (Join-Path $parentJunction 'generated-player') $true

    $intermediateJunction = Join-Path $state 'junction-intermediate'
    New-Junction $intermediateJunction $outside
    Assert-Rejected (Join-Path $intermediateJunction 'cache') $true

    $directorySymlink = Join-Path $root 'directory-symlink'
    $symlinkMode = New-DirectorySymlink $directorySymlink $outside
    Assert-Rejected $directorySymlink $false

    & $policy -Path $checkout | Out-Null
    Write-Output "Windows path policy canaries: PASS ($symlinkMode)"
} finally {
    foreach ($link in @(
        (Join-Path $root 'directory-symlink'),
        (Join-Path $root 'state\junction-intermediate'),
        (Join-Path $root 'junction-parent')
    )) {
        if (Test-Path -LiteralPath $link) { & cmd.exe /d /s /c "rmdir `"$link`"" | Out-Null }
    }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    Set-Location -LiteralPath $originalLocation
}
