# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ScriptPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. $ScriptPath

if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw 'this fixture must run under Windows PowerShell 5 Desktop'
}
if ([bool]([System.Diagnostics.ProcessStartInfo].GetProperty('ArgumentList'))) {
    throw 'fixture expected the Windows PowerShell 5 ProcessStartInfo surface without ArgumentList'
}
$nativeShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $nativeShell -PathType Leaf)) { throw 'native Windows PowerShell executable is unavailable' }
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('teremoq-client-distribution-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
try {
    $argvScript = Join-Path $scratch 'argv.ps1'
    Set-Content -LiteralPath $argvScript -Encoding UTF8 -Value @'
param([string]$First, [string]$Second)
[Console]::Out.Write(([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($First)) + ':' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Second))))
'@
    $first = 'alpha beta'
    $second = 'metacharacters &|<>^% ! "quoted" \tail'
    $result = Invoke-TeremoqBoundedNativeProcess -FilePath $nativeShell -WorkingDirectory $scratch `
        -Arguments @('-NoProfile', '-NonInteractive', '-File', $argvScript, $first, $second) `
        -TimeoutMilliseconds 5000 -StdoutMaxBytes 1024 -StderrMaxBytes 1024
    $expected = ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($first)) + ':' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($second)))
    if ($result.ExitCode -ne 0 -or $result.Stdout -ne $expected -or $result.Stderr -ne '') {
        throw 'PowerShell 5 native argv round-trip did not preserve spaces and metacharacters'
    }
    $warningScript = Join-Path $scratch 'warning.ps1'
    Set-Content -LiteralPath $warningScript -Encoding UTF8 -Value "[Console]::Out.Write('ok'); [Console]::Error.Write('npm warning fixture')"
    $warning = Invoke-TeremoqBoundedNativeProcess -FilePath $nativeShell -WorkingDirectory $scratch `
        -Arguments @('-NoProfile', '-NonInteractive', '-File', $warningScript) -TimeoutMilliseconds 5000 -StdoutMaxBytes 1024 -StderrMaxBytes 1024
    if ($warning.ExitCode -ne 0 -or $warning.Stdout -ne 'ok' -or $warning.Stderr -ne 'npm warning fixture') { throw 'bounded successful stderr fixture was not preserved' }
    $utf8Script = Join-Path $scratch 'utf8.ps1'
    Set-Content -LiteralPath $utf8Script -Encoding UTF8 -Value @'
$utf8NoBom = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom
[Console]::Out.Write("compilación válida")
[Console]::Error.Write("página con espacio no separable")
'@
    $utf8 = Invoke-TeremoqBoundedNativeProcess -FilePath $nativeShell -WorkingDirectory $scratch `
        -Arguments @('-NoProfile', '-NonInteractive', '-File', $utf8Script) -TimeoutMilliseconds 5000 -StdoutMaxBytes 1024 -StderrMaxBytes 1024
    if ($utf8.ExitCode -ne 0 -or $utf8.Stdout -cne 'compilación válida' -or $utf8.Stderr -cne 'página con espacio no separable') {
        throw 'PowerShell 5 child output was not emitted and decoded as strict UTF-8'
    }
    $pinnedFile = Join-Path $scratch 'read-pinned.txt'
    [IO.File]::WriteAllText($pinnedFile, 'verified while read-pinned', (New-Object Text.UTF8Encoding($false)))
    $readPin = [IO.File]::Open($pinnedFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ((Read-TeremoqBoundedUtf8File -Path $pinnedFile -MaxBytes 1024) -cne 'verified while read-pinned') {
            throw 'read-pinned verified source content was not preserved'
        }
        $writerRejected = $false
        try {
            $writer = [IO.File]::Open($pinnedFile, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
            $writer.Dispose()
        } catch [IO.IOException] {
            $writerRejected = $true
        }
        if (-not $writerRejected) { throw 'verified read sharing permitted a concurrent writer' }
    } finally {
        $readPin.Dispose()
    }
    $lockedFile = Join-Path $scratch 'transient-lock.txt'
    $lockReady = Join-Path $scratch 'transient-lock.ready'
    $lockScript = Join-Path $scratch 'hold-lock.ps1'
    [IO.File]::WriteAllText($lockedFile, 'verified after transient lock', (New-Object Text.UTF8Encoding($false)))
    Set-Content -LiteralPath $lockScript -Encoding UTF8 -Value @'
param([string]$LockedFile, [string]$ReadyFile)
$stream = [IO.File]::Open($LockedFile, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    [IO.File]::WriteAllText($ReadyFile, 'ready')
    Start-Sleep -Milliseconds 1250
} finally {
    $stream.Dispose()
}
'@
    $lockProcess = Start-Process -FilePath $nativeShell -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-File', $lockScript, $lockedFile, $lockReady
    ) -PassThru -WindowStyle Hidden
    try {
        $readyWatch = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $lockReady -PathType Leaf)) {
            if ($lockProcess.HasExited -or $readyWatch.ElapsedMilliseconds -gt 5000) { throw 'transient lock fixture did not become ready' }
            Start-Sleep -Milliseconds 50
        }
        $lockWatch = [Diagnostics.Stopwatch]::StartNew()
        $lockedText = Read-TeremoqBoundedUtf8File -Path $lockedFile -MaxBytes 1024
        if ($lockedText -cne 'verified after transient lock') { throw 'transiently locked file content was not preserved' }
        if ($lockWatch.ElapsedMilliseconds -lt 500 -or $lockWatch.ElapsedMilliseconds -gt 6000) {
            throw 'transient file lock was not retried within the bounded policy'
        }
    } finally {
        if (-not $lockProcess.HasExited) { $lockProcess.Kill() }
        [void]$lockProcess.WaitForExit(5000)
        $lockProcess.Dispose()
    }
    $floodScript = Join-Path $scratch 'flood.ps1'
    Set-Content -LiteralPath $floodScript -Encoding UTF8 -Value "[Console]::Out.Write(('x' * 140000)); [Console]::Error.Write(('y' * 140000))"
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        Invoke-TeremoqBoundedNativeProcess -FilePath $nativeShell -WorkingDirectory $scratch `
            -Arguments @('-NoProfile', '-NonInteractive', '-File', $floodScript) `
            -TimeoutMilliseconds 5000 -StdoutMaxBytes 131072 -StderrMaxBytes 131072 | Out-Null
        throw 'oversized concurrent native stdout/stderr was accepted'
    } catch {
        if ($_.Exception.Message -notmatch 'output exceeded byte limits') { throw }
    }
    if ($watch.ElapsedMilliseconds -gt 10000) { throw 'bounded concurrent stream capture deadlocked or did not terminate promptly' }
    $timeoutScript = Join-Path $scratch 'timeout.ps1'
    Set-Content -LiteralPath $timeoutScript -Encoding UTF8 -Value 'Start-Sleep -Seconds 30'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        Invoke-TeremoqBoundedNativeProcess -FilePath $nativeShell -WorkingDirectory $scratch `
            -Arguments @('-NoProfile', '-NonInteractive', '-File', $timeoutScript) `
            -TimeoutMilliseconds 1000 -StdoutMaxBytes 1024 -StderrMaxBytes 1024 | Out-Null
        throw 'timed-out native process was accepted'
    } catch {
        if ($_.Exception.Message -notmatch 'native process timed out') { throw }
    }
    if ($watch.ElapsedMilliseconds -gt 7000) { throw 'timed-out native process was not killed, waited for, and disposed promptly' }
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
