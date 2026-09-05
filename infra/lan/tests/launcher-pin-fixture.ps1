# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PinScript,
    [Parameter(Mandatory = $true)][string]$LauncherPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$bytes = [IO.File]::ReadAllBytes($LauncherPath)
$sha = [Security.Cryptography.SHA1]::Create()
try {
    $header = [Text.Encoding]::ASCII.GetBytes(('blob ' + $bytes.Length))
    $combined = New-Object byte[] ($header.Length + 1 + $bytes.Length)
    [Array]::Copy($header, $combined, $header.Length)
    [Array]::Copy($bytes, 0, $combined, $header.Length + 1, $bytes.Length)
    $blob = ([BitConverter]::ToString($sha.ComputeHash($combined)) -replace '-', '').ToLowerInvariant()
} finally { $sha.Dispose() }

$start = New-Object Diagnostics.ProcessStartInfo
$start.FileName = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $PinScript + '" -LauncherPath "' + $LauncherPath + '" -ExpectedBlobId ' + $blob
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardInput = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$process = New-Object Diagnostics.Process
$process.StartInfo = $start
try {
    if (-not $process.Start()) { throw 'pin fixture process did not start' }
    if ($process.StandardOutput.ReadLine() -cne 'PINNED') { throw 'pin fixture did not report readiness' }
    $mutationRejected = $false
    try {
        $write = New-Object IO.FileStream($LauncherPath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $write.Dispose()
    } catch [IO.IOException] { $mutationRejected = $true }
    if (-not $mutationRejected) { throw 'launcher mutation succeeded while pin was active' }
    $process.StandardInput.WriteLine('release')
    $process.StandardInput.Dispose()
    if (-not $process.WaitForExit(5000) -or $process.ExitCode -ne 0) { throw 'pin fixture did not release cleanly' }
    Write-Output 'lan-launcher-pin-fixture: PASS'
} finally {
    if (-not $process.HasExited) { $process.Kill() }
    $process.Dispose()
}
