# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$policy = Join-Path $PSScriptRoot 'assert-windows-path-policy.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ("teremoq-path-canary-" + [guid]::NewGuid().ToString('N'))
$originalLocation = Get-Location

function Assert-SafeCmdPath([string]$Value) {
    if (-not [IO.Path]::IsPathRooted($Value) -or $Value.Length -gt 1024 -or
        $Value -match '[\x00-\x1f"&|<>^%!]') {
        throw 'mklink path is outside the closed canary contract'
    }
}

function Invoke-Mklink([string]$Mode, [string]$Link, [string]$Target) {
    if ($Mode -ne '/J' -and $Mode -ne '/D') { throw 'mklink mode is outside contract' }
    Assert-SafeCmdPath $Link
    Assert-SafeCmdPath $Target

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $startInfo.Arguments = '/d /s /c "mklink ' + $Mode + ' "' + $Link + '" "' + $Target + '""'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'cmd/mklink process did not start' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) {
            try { $process.Kill() } catch {}
            throw 'cmd/mklink timed out'
        }
        if (-not $stdoutTask.Wait(2000) -or -not $stderrTask.Wait(2000)) {
            throw 'cmd/mklink output did not close'
        }
        $output = [string]$stdoutTask.Result + [string]$stderrTask.Result
        if ($output.Length -gt 8192) { throw 'cmd/mklink output exceeded limit' }
        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            Output = $output.Trim()
        }
    } finally {
        $process.Dispose()
    }
}

function Assert-ReparseDirectory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw 'mklink did not create a directory entry'
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
        throw 'mklink entry is not a reparse point'
    }
}

function New-Junction([string]$Link, [string]$Target) {
    $result = Invoke-Mklink '/J' $Link $Target
    if ($result.ExitCode -ne 0) {
        throw "junction canary setup failed with exit $($result.ExitCode): $($result.Output)"
    }
    Assert-ReparseDirectory $Link
}

function Assert-MklinkFailureCaptured([string]$ExistingLink, [string]$Target) {
    $result = Invoke-Mklink '/J' $ExistingLink $Target
    if ($result.ExitCode -eq 0) {
        throw 'duplicate mklink unexpectedly succeeded; failure canary is invalid'
    }
    Assert-ReparseDirectory $ExistingLink
}

function New-DirectorySymlink([string]$Link, [string]$Target) {
    $result = Invoke-Mklink '/D' $Link $Target
    if ($result.ExitCode -eq 0) {
        Assert-ReparseDirectory $Link
        return 'directory-symlink'
    }
    if (Test-Path -LiteralPath $Link) {
        throw 'failed symlink command left an unexpected path'
    }
    New-Junction $Link $Target
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
    Assert-MklinkFailureCaptured $parentJunction $checkout
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
        if (Test-Path -LiteralPath $link) {
            [IO.Directory]::Delete($link, $false)
        }
    }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    Set-Location -LiteralPath $originalLocation
}
