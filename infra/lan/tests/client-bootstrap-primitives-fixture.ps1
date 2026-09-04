# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BootstrapPath,
    [Parameter(Mandatory = $true)][string]$BlobPath,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedBlob
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$content = [IO.File]::ReadAllText($BootstrapPath)
$mainMarker = '$hostPath = '
$mainOffset = $content.IndexOf($mainMarker, [StringComparison]::Ordinal)
if ($mainOffset -lt 1) { throw 'bootstrap main marker missing' }
Invoke-Expression $content.Substring(0, $mainOffset)

$stream = [IO.File]::Open($BlobPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    Assert-LockedHandlePath -Stream $stream -ExpectedPath $BlobPath
    if ((Get-LockedGitBlobId -Stream $stream) -cne $ExpectedBlob) {
        throw 'locked Git blob identity mismatch'
    }
    $writeDenied = $false
    try {
        [IO.File]::Open($BlobPath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None).Dispose()
    } catch [IO.IOException] {
        $writeDenied = $true
    }
    if (-not $writeDenied) { throw 'locked source accepted a concurrent writer' }
    $childCreationDenied = $false
    try {
        [void][IO.Directory]::CreateDirectory((Join-Path $BlobPath 'disabled'))
    } catch {
        $childCreationDenied = $true
    }
    if (-not $childCreationDenied) { throw 'a child path was created below a locked regular file' }
} finally {
    $stream.Dispose()
}

$lockRoot = Join-Path $env:TEMP ('teremoq-root-lock-' + [Guid]::NewGuid().ToString('N'))
$movedRoot = "$lockRoot-moved"
[void][IO.Directory]::CreateDirectory($lockRoot)
$lockPath = Join-Path $lockRoot 'lock'
$rootStream = New-Object IO.FileStream(
    $lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read
)
try {
    Assert-LockedHandlePath -Stream $rootStream -ExpectedPath $lockPath
    $moveDenied = $false
    try {
        [IO.Directory]::Move($lockRoot, $movedRoot)
    } catch [IO.IOException] {
        $moveDenied = $true
    }
    if (-not $moveDenied) { throw 'locked root accepted a concurrent rename' }
} finally {
    $rootStream.Dispose()
    if (Test-Path -LiteralPath $lockPath) { [IO.File]::Delete($lockPath) }
    if (Test-Path -LiteralPath $lockRoot) { [IO.Directory]::Delete($lockRoot) }
    if (Test-Path -LiteralPath $movedRoot) { [IO.Directory]::Delete($movedRoot) }
}

$snapshot = Get-ProcessEnvironmentSnapshot
$originalPath = $env:PATH
$canaryName = 'TEREMOQ_BOOTSTRAP_ENV_RESTORE_CANARY'
[Environment]::SetEnvironmentVariable($canaryName, 'unexpected', 'Process')
$env:PATH = 'unexpected'
Restore-ProcessEnvironment -Snapshot $snapshot
if (Test-Path "Env:$canaryName") { throw 'new process environment entry survived restoration' }
if ($env:PATH -cne $originalPath) { throw 'PATH was not restored exactly' }

Write-Output 'client-bootstrap-primitives-fixture: pass'
