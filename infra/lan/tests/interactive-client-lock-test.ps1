# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$launcher = Join-Path $PSScriptRoot '..\client\Start-LanInteractiveClient.ps1'
$zeroCommit = '0' * 40
$zeroHash = '0' * 64
. $launcher -ExpectedCommit $zeroCommit -ExpectedLauncherSha256 $zeroHash `
    -ExpectedGitSha256 $zeroHash -ExpectedNodeSha256 $zeroHash `
    -ExpectedNpmCliSha256 $zeroHash -ExpectedPowerShellSha256 $zeroHash `
    -ExpectedTaskkillSha256 $zeroHash

$root = Join-Path ([IO.Path]::GetTempPath()) ('teremoq-interactive-lock-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $source = Join-Path $root 'source'
    New-Item -ItemType Directory -Path $source | Out-Null
    $entrypoint = Join-Path $source 'entrypoint.mjs'
    $replacement = Join-Path $root 'replacement.mjs'
    [IO.File]::WriteAllText($entrypoint, 'reviewed bytes', (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($replacement, 'substituted bytes', (New-Object Text.UTF8Encoding($false)))
    $expected = (Get-FileHash -LiteralPath $entrypoint -Algorithm SHA256).Hash.ToLowerInvariant()
    $hashRejected = $false
    try { Open-TeremoqPinnedFile -Path $entrypoint -ExpectedSha256 ('0' * 64) | Out-Null }
    catch { $hashRejected = $true }
    if (-not $hashRejected) { throw 'Unapproved entrypoint hash was accepted' }
    $pin = Open-TeremoqPinnedFile -Path $entrypoint -ExpectedSha256 $expected `
        -ExpectedBlobId '015e494e9ad2856ee83a283fb6dd24307b83fc29'
    try {
        $writeRejected = $false
        try { [IO.File]::WriteAllText($entrypoint, 'mutated') } catch { $writeRejected = $true }
        if (-not $writeRejected) { throw 'Pinned entrypoint remained writable' }
        $replaceRejected = $false
        try { Move-Item -LiteralPath $replacement -Destination $entrypoint -Force } catch { $replaceRejected = $true }
        if (-not $replaceRejected) { throw 'Pinned entrypoint remained replaceable' }
        $parentSwapRejected = $false
        try { Move-Item -LiteralPath $source -Destination (Join-Path $root 'moved-source') } catch { $parentSwapRejected = $true }
        if (-not $parentSwapRejected) { throw 'Pinned entrypoint parent remained replaceable' }
        if ((Get-TeremoqStreamSha256 $pin.Stream) -cne $expected) { throw 'Pinned handle bytes changed' }
    } finally { $pin.Stream.Dispose() }
    Move-Item -LiteralPath $replacement -Destination $entrypoint -Force
    if ([IO.File]::ReadAllText($entrypoint) -cne 'substituted bytes') { throw 'Canary did not exercise replacement after unlock' }
    $nodePath = 'C:\Program Files\nodejs\node.exe'
    $nodeHash = (Get-FileHash -LiteralPath $nodePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $nodePin = Open-TeremoqPinnedFile -Path $nodePath -ExpectedSha256 $nodeHash
    try {
        $global:LASTEXITCODE = $null
        $version = (@(& $nodePath --version 2>$null) -join '').Trim()
        if ($global:LASTEXITCODE -isnot [int] -or $global:LASTEXITCODE -ne 0 -or
            $version -cnotmatch '^v22\.[0-9]+\.[0-9]+$') {
            throw 'Pinned Node executable did not start as the held identity'
        }
    } finally { $nodePin.Stream.Dispose() }
    Write-Output 'lan-interactive-client-lock-test: PASS'
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
