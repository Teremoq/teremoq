# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version 3.0

if (-not ('TeremoqLanNativeFile' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class TeremoqLanNativeFile {
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
 public static extern uint GetFinalPathNameByHandle(SafeFileHandle h, StringBuilder p, uint n, uint f);
}
'@
}

function Open-TeremoqVerifiedRegularFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][int]$MaxBytes)
    [void](Assert-TeremoqNonReparseFilePath -Path $Path)
    $expected = [IO.Path]::GetFullPath($Path)
    $stream = [IO.File]::Open($expected, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        $buffer = New-Object Text.StringBuilder 32768
        $n = [TeremoqLanNativeFile]::GetFinalPathNameByHandle($stream.SafeFileHandle, $buffer, [uint32]$buffer.Capacity, 0)
        if ($n -eq 0 -or $n -ge $buffer.Capacity) { throw 'could not obtain bounded final path for opened file handle' }
        $final = $buffer.ToString()
        if ($final.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) { $final = '\\' + $final.Substring(8) }
        elseif ($final.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) { $final = $final.Substring(4) }
        if (-not $final.Equals($expected, [StringComparison]::OrdinalIgnoreCase) -or $stream.Length -gt $MaxBytes -or $stream.SafeFileHandle.IsInvalid) {
            throw 'opened file handle does not match the validated regular path'
        }
        return $stream
    } catch { $stream.Dispose(); throw }
}

function Read-TeremoqBoundedUtf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$MaxBytes
    )
    if ($MaxBytes -lt 1 -or $MaxBytes -gt 1048576) { throw 'bounded file limit is outside 1..1048576 bytes' }
    $stream = Open-TeremoqVerifiedRegularFile -Path $Path -MaxBytes $MaxBytes
    try {
        $initialLength = $stream.Length
        $buffer = New-Object byte[] $initialLength
        $read = 0
        while ($read -lt $initialLength) { $chunk = $stream.Read($buffer, $read, $initialLength - $read); if ($chunk -eq 0) { break }; $read += $chunk }
        # Length and LastWriteTimeUtc here are queried from the already-open
        # FileStream; never reopen a pathname to decide which object was parsed.
        if ($read -ne $initialLength -or $stream.ReadByte() -ne -1 -or $stream.Length -ne $initialLength -or $stream.SafeFileHandle.IsInvalid) { throw "file changed while reading: $Path" }
        $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
        return $strictUtf8.GetString($buffer, 0, $read)
    } finally {
        $stream.Dispose()
    }
}

function Read-TeremoqClosedTsv {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$MaxBytes,
        [Parameter(Mandatory = $true)][string[]]$AllowedKeys,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $text = Read-TeremoqBoundedUtf8File -Path $Path -MaxBytes $MaxBytes
    $values = [ordered]@{}
    foreach ($line in ($text -split "`r?`n")) {
        if ([string]::IsNullOrEmpty($line) -or $line.StartsWith('#')) { continue }
        $fields = $line -split "`t", 3
        if ($fields.Count -ne 2 -or $AllowedKeys -notcontains $fields[0] -or $values.Contains($fields[0]) -or [string]::IsNullOrWhiteSpace($fields[1])) {
            throw "invalid closed $Label"
        }
        $values[$fields[0]] = $fields[1]
    }
    if ($values.Count -ne $AllowedKeys.Count) { throw "$Label is incomplete" }
    return $values
}

function Get-TeremoqBoundedFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][int]$MaxBytes)
    if ($MaxBytes -lt 1 -or $MaxBytes -gt 104857600) { throw 'bounded hash limit is outside 1..104857600 bytes' }
    $stream = Open-TeremoqVerifiedRegularFile -Path $Path -MaxBytes $MaxBytes
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $buffer = New-Object byte[] 65536
        $total = [Int64]0
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $total += $read
            if ($total -gt $MaxBytes) { throw 'file exceeded bounded hash limit while reading' }
            [void]$hash.TransformBlock($buffer, 0, $read, $buffer, 0)
        }
        [void]$hash.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        if ($total -ne $stream.Length -or $stream.SafeFileHandle.IsInvalid) { throw "file changed while hashing: $Path" }
        return ([BitConverter]::ToString($hash.Hash) -replace '-', '').ToLowerInvariant()
    } finally { $stream.Dispose(); $hash.Dispose() }
}

function Get-TeremoqGitExecutable {
    # A .cmd/.bat launcher introduces a second cmd.exe parsing boundary. The
    # approved client flow invokes only the Git for Windows executable.
    $commands = @('git.exe', 'git')
    foreach ($commandName in $commands) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($command -and $command.Source -and $command.Source.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) { return $command.Source }
    }
    $where = Get-Command where.exe -ErrorAction SilentlyContinue
    if ($where) {
        foreach ($commandName in @('git.exe', 'git')) {
            $matches = & $where.Source $commandName 2>$null
            foreach ($match in @($matches)) {
                if (-not [string]::IsNullOrWhiteSpace($match) -and $match.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $match -PathType Leaf)) { return $match }
            }
        }
    }
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Git\cmd\git.exe'),
        (Join-Path $env:ProgramFiles 'Git\bin\git.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\cmd\git.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\git.exe'),
        (Join-Path $env:LocalAppData 'Programs\Git\cmd\git.exe'),
        (Join-Path $env:LocalAppData 'Programs\Git\bin\git.exe')
    ) | Where-Object { $_ }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Convert-TeremoqWindowsArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value -eq '') { return '""' }
    if ($Value -cnotmatch '[\s"]') { return $Value }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes += 1
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append('\' * (($backslashes * 2) + 1))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append('\' * $backslashes)
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) { [void]$builder.Append('\' * ($backslashes * 2)) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Convert-TeremoqWindowsCommandLine {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    if ($Arguments.Count -lt 1 -or $Arguments.Count -gt 32) { throw 'native process argument count is outside 1..32' }
    foreach ($argument in $Arguments) {
        if ($null -eq $argument -or $argument.Length -gt 8192) { throw 'native process argument is invalid or oversized' }
    }
    return (($Arguments | ForEach-Object { Convert-TeremoqWindowsArgument -Value $_ }) -join ' ')
}

function New-TeremoqBoundedStreamState {
    param(
        [Parameter(Mandatory = $true)][System.IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][int]$MaxBytes
    )
    if ($MaxBytes -lt 1 -or $MaxBytes -gt 131072) { throw 'native stream limit is outside 1..131072 bytes' }
    $state = [pscustomobject]@{
        Stream = $Stream
        MaxBytes = $MaxBytes
        Buffer = New-Object byte[] 4096
        Bytes = New-Object System.IO.MemoryStream
        Pending = $null
        Complete = $false
        Oversized = $false
    }
    $state.Pending = $state.Stream.BeginRead($state.Buffer, 0, $state.Buffer.Length, $null, $null)
    return $state
}

function Update-TeremoqBoundedStreamState {
    param([Parameter(Mandatory = $true)]$State)
    if ($State.Complete -or -not $State.Pending.IsCompleted) { return }
    $read = $State.Stream.EndRead($State.Pending)
    $State.Pending = $null
    if ($read -eq 0) {
        $State.Complete = $true
        return
    }
    if (($State.Bytes.Length + $read) -gt $State.MaxBytes) {
        $State.Oversized = $true
        $State.Complete = $true
        return
    }
    $State.Bytes.Write($State.Buffer, 0, $read)
    $State.Pending = $State.Stream.BeginRead($State.Buffer, 0, $State.Buffer.Length, $null, $null)
}

function Convert-TeremoqStreamStateToStrictUtf8 {
    param([Parameter(Mandatory = $true)]$State)
    if (-not $State.Complete -or $State.Oversized) { throw 'native stream did not finish within its bounded policy' }
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    return $encoding.GetString($State.Bytes.ToArray())
}

function Stop-TeremoqNativeProcess {
    param([Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process)
    if ($Process.HasExited) { return $true }
    try { $Process.Kill() } catch { return $false }
    return $Process.WaitForExit(5000)
}

function Invoke-TeremoqBoundedNativeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter()][int]$TimeoutMilliseconds = 30000,
        [Parameter()][int]$StdoutMaxBytes = 131072,
        [Parameter()][int]$StderrMaxBytes = 131072
    )
    if ($TimeoutMilliseconds -lt 1000 -or $TimeoutMilliseconds -gt 900000) { throw 'native process timeout is outside 1000..900000 ms' }
    $resolvedFilePath = [IO.Path]::GetFullPath($FilePath)
    $resolvedWorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
    if (-not (Test-Path -LiteralPath $resolvedFilePath -PathType Leaf) -or -not (Test-Path -LiteralPath $resolvedWorkingDirectory -PathType Container)) {
        throw 'native executable or working directory is unavailable'
    }
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $resolvedFilePath
    # ProcessStartInfo.ArgumentList is not present in Windows PowerShell 5/.NET Framework.
    # This explicit Win32 command line is the single argv boundary for Git and test canaries.
    $startInfo.Arguments = Convert-TeremoqWindowsCommandLine -Arguments $Arguments
    $startInfo.WorkingDirectory = $resolvedWorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $stdoutState = $null
    $stderrState = $null
    $started = $false
    try {
        if (-not $process.Start()) { throw 'failed to start native process' }
        $started = $true
        $stdoutState = New-TeremoqBoundedStreamState -Stream $process.StandardOutput.BaseStream -MaxBytes $StdoutMaxBytes
        $stderrState = New-TeremoqBoundedStreamState -Stream $process.StandardError.BaseStream -MaxBytes $StderrMaxBytes
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        while (-not ($process.HasExited -and $stdoutState.Complete -and $stderrState.Complete)) {
            Update-TeremoqBoundedStreamState -State $stdoutState
            Update-TeremoqBoundedStreamState -State $stderrState
            if ($stdoutState.Oversized -or $stderrState.Oversized) {
                if (-not (Stop-TeremoqNativeProcess -Process $process)) { throw 'native process output exceeded byte limits and termination could not be confirmed' }
                throw 'native process output exceeded byte limits'
            }
            if ($stopwatch.ElapsedMilliseconds -gt $TimeoutMilliseconds) {
                if (-not (Stop-TeremoqNativeProcess -Process $process)) { throw 'native process timed out and termination could not be confirmed' }
                throw 'native process timed out'
            }
            Start-Sleep -Milliseconds 5
        }
        # Streams have reached EOF before collecting ExitCode: no redirected-pipe deadlock.
        if (-not $process.WaitForExit(1000)) { throw 'native process did not exit after its streams closed' }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = Convert-TeremoqStreamStateToStrictUtf8 -State $stdoutState
            Stderr = Convert-TeremoqStreamStateToStrictUtf8 -State $stderrState
        }
    } finally {
        if ($started -and -not $process.HasExited) { [void](Stop-TeremoqNativeProcess -Process $process) }
        if ($stdoutState) { $stdoutState.Bytes.Dispose() }
        if ($stderrState) { $stderrState.Bytes.Dispose() }
        $process.Dispose()
    }
}

function Invoke-TeremoqGit {
    param(
        [Parameter(Mandatory = $true)][string]$CheckoutRoot,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $gitPath = Get-TeremoqGitExecutable
    if (-not $gitPath) { throw 'Git for Windows is required and was not found' }
    $prefix = @(
        '--no-replace-objects',
        '-c', 'core.hooksPath=NUL',
        '-c', 'core.fsmonitor=false',
        '-c', 'core.autocrlf=false',
        '-c', 'core.eol=lf',
        '-c', 'core.safecrlf=true'
    )
    $previousNoSystem = $env:GIT_CONFIG_NOSYSTEM
    $previousGlobal = $env:GIT_CONFIG_GLOBAL
    try {
        $env:GIT_CONFIG_NOSYSTEM = '1'
        $env:GIT_CONFIG_GLOBAL = 'NUL'
        $result = Invoke-TeremoqBoundedNativeProcess -FilePath $gitPath -WorkingDirectory $CheckoutRoot -Arguments ($prefix + $Arguments)
    } finally {
        $env:GIT_CONFIG_NOSYSTEM = $previousNoSystem
        $env:GIT_CONFIG_GLOBAL = $previousGlobal
    }
    if ($result.ExitCode -ne 0) {
        $detail = $result.Stderr.Trim()
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = $result.Stdout.Trim() }
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = 'no additional detail' }
        if ($detail.Length -gt 1024) { $detail = $detail.Substring(0, 1024) }
        throw "Git command failed: $detail"
    }
    return ($result.Stdout -replace "`r", '').TrimEnd("`n")
}

function Get-TeremoqOptionalGitConfigValues {
    param([Parameter(Mandatory = $true)][string]$CheckoutRoot, [Parameter(Mandatory = $true)][string]$Key)
    $gitPath = Get-TeremoqGitExecutable
    if (-not $gitPath) { throw 'Git for Windows is required and was not found' }
    $result = Invoke-TeremoqBoundedNativeProcess -FilePath $gitPath -WorkingDirectory $CheckoutRoot `
        -Arguments @('config', '--get-all', $Key) -TimeoutMilliseconds 30000 -StdoutMaxBytes 131072 -StderrMaxBytes 131072
    if ($result.ExitCode -eq 1 -and [string]::IsNullOrWhiteSpace($result.Stdout) -and [string]::IsNullOrWhiteSpace($result.Stderr)) { return @() }
    if ($result.ExitCode -ne 0) { throw 'Git config query failed' }
    return @(($result.Stdout -replace "`r", '').TrimEnd("`n") -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Test-TeremoqSafeRelativeRepositorySubdirectory {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value.Length -lt 1 -or $Value.Length -gt 128) { return $false }
    if ($Value -cnotmatch '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$') { return $false }
    return @($Value.Split('/') | Where-Object { $_ -in @('.', '..') }).Count -eq 0
}

function Test-TeremoqCanonicalPrivateUnicastIPv4 {
    param([Parameter(Mandatory = $true)][string]$Value)
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Value, [ref]$parsed) -or
        $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $parsed.IPAddressToString -cne $Value) { return $false }
    $bytes = $parsed.GetAddressBytes()
    if ([Net.IPAddress]::IsLoopback($parsed) -or $bytes[0] -eq 0 -or $Value -eq '255.255.255.255' -or
        $bytes[0] -ge 224 -or ($bytes[0] -eq 169 -and $bytes[1] -eq 254) -or $bytes[0] -ge 240) { return $false }
    return ($bytes[0] -eq 10) -or ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or ($bytes[0] -eq 192 -and $bytes[1] -eq 168)
}

function Get-TeremoqRepositoryBranchName {
    param([Parameter(Mandatory = $true)][string]$RepositoryRef)
    if ($RepositoryRef -cnotmatch '^refs/heads/([A-Za-z0-9][A-Za-z0-9._/-]{0,127})$') {
        throw 'repository_ref must be an explicit refs/heads/* name for the ff-only LAN workflow'
    }
    return $Matches[1]
}

function Assert-TeremoqApprovedGitBootstrapParameters {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryUrl,
        [Parameter(Mandatory = $true)][string]$RepositoryRef,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$RepositorySubdirectory
    )
    if ($RepositoryUrl -cne 'https://github.com/Teremoq/teremoq' -or
        $ExpectedCommit -cnotmatch '^[0-9a-f]{40}$' -or
        -not (Test-TeremoqSafeRelativeRepositorySubdirectory -Value $RepositorySubdirectory)) {
        throw 'Git bootstrap parameters are outside the approved LAN policy'
    }
    [void](Get-TeremoqRepositoryBranchName -RepositoryRef $RepositoryRef)
}

function Assert-TeremoqRootsSeparated {
    param(
        [Parameter(Mandatory = $true)][string]$CheckoutRoot,
        [Parameter(Mandatory = $true)][string]$StateRoot
    )
    $checkout = [IO.Path]::GetFullPath($CheckoutRoot).TrimEnd('\', '/')
    $state = [IO.Path]::GetFullPath($StateRoot).TrimEnd('\', '/')
    if ($checkout.Length -eq 0 -or $state.Length -eq 0) { throw 'invalid checkout/state roots' }
    if ($checkout.StartsWith($state + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        $state.StartsWith($checkout + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        $checkout.Equals($state, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'checkout root and external client state must be separate trees'
    }
}

function Get-TeremoqNonReparseDirectoryPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) { throw 'path must be an existing directory' }
    $current = $item
    while ($true) {
        if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'directory path or ancestor may not be a junction/reparse point' }
        $parent = $current.Parent
        if ($null -eq $parent -or $parent.FullName -ceq $current.FullName) { break }
        $current = $parent
    }
    return $item.FullName
}

function Assert-TeremoqNonReparseFilePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'file may not be a reparse point' }
    [void](Get-TeremoqNonReparseDirectoryPath -Path (Split-Path -Parent $item.FullName))
    return $item.FullName
}

function Get-TeremoqLanStateContext {
    param([Parameter(Mandatory = $true)][string]$StateRoot)
    $managedPointer = Join-Path ([IO.Path]::GetFullPath($StateRoot)) 'control\active.json'
    if (Test-Path -LiteralPath $managedPointer -PathType Leaf) {
        return Get-TeremoqManagedLanStateContext -StateRoot $StateRoot
    }
    $root = Get-TeremoqNonReparseDirectoryPath -Path $StateRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'StateRoot must exist' }
    $rootItem = Get-Item -LiteralPath $root -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'StateRoot may not be a reparse point' }
    foreach ($required in @('VERSION.tsv', 'LAN-CONFIG.json', 'CLIENT-COMPATIBILITY.tsv', 'SHA256SUMS', 'public-identity/relay-cert.sha256')) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $required))) { throw "missing client state artifact: $required" }
    }
    $versionAllowed = @('schema_version', 'package_version', 'run_id', 'source_commit', 'server_ipv4', 'moq_url', 'player_manifest_sha256', 'launcher_contract_sha256', 'lan_config_sha256', 'player_evidence', 'load_launcher_status')
    $version = Read-TeremoqClosedTsv -Path (Join-Path $root 'VERSION.tsv') -MaxBytes 4096 -AllowedKeys $versionAllowed -Label 'VERSION.tsv'
    if ($version.schema_version -ne '1' -or
        $version.package_version -cnotmatch '^[A-Za-z0-9._-]{1,64}$' -or
        $version.run_id -cnotmatch '^lan-[a-z0-9][a-z0-9-]{0,31}$' -or
        $version.source_commit -cnotmatch '^[0-9a-f]{40}$' -or
        $version.server_ipv4 -cnotmatch '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' -or
        $version.moq_url -cne "https://$($version.server_ipv4):14433/watch" -or
        $version.player_manifest_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $version.launcher_contract_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $version.lan_config_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $version.player_evidence -cne 'not_measured' -or
        $version.load_launcher_status -cne 'ready') {
        throw 'VERSION.tsv values are outside the LAN Git client policy'
    }
    $compatibilityAllowed = @('schema_version', 'repository_url', 'repository_ref', 'repository_subdirectory', 'player_relative_path', 'allowed_client_commit', 'source_commit', 'package_version', 'client_protocol_version', 'player_manifest_sha256', 'launcher_contract_sha256', 'lan_config_sha256')
    $compatibility = Read-TeremoqClosedTsv -Path (Join-Path $root 'CLIENT-COMPATIBILITY.tsv') -MaxBytes 4096 -AllowedKeys $compatibilityAllowed -Label 'CLIENT-COMPATIBILITY.tsv'
    if ($compatibility.schema_version -ne '1' -or
        $compatibility.repository_url -cne 'https://github.com/Teremoq/teremoq' -or
        $compatibility.repository_ref -cnotmatch '^refs/heads/[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$' -or
        -not (Test-TeremoqSafeRelativeRepositorySubdirectory -Value $compatibility.repository_subdirectory) -or
        -not (Test-TeremoqSafeRelativeRepositorySubdirectory -Value $compatibility.player_relative_path) -or
        $compatibility.allowed_client_commit -cnotmatch '^[0-9a-f]{40}$' -or
        $compatibility.source_commit -cnotmatch '^[0-9a-f]{40}$' -or
        $compatibility.package_version -cnotmatch '^[A-Za-z0-9._-]{1,64}$' -or
        $compatibility.client_protocol_version -cne 'teremoq-lan-git-v2' -or
        $compatibility.player_manifest_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $compatibility.launcher_contract_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $compatibility.lan_config_sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'CLIENT-COMPATIBILITY.tsv values are outside policy'
    }
    if ($compatibility.allowed_client_commit -cne $compatibility.source_commit -or
        $compatibility.source_commit -cne $version.source_commit -or
        $compatibility.package_version -cne $version.package_version -or
        $compatibility.player_manifest_sha256 -cne $version.player_manifest_sha256 -or
        $compatibility.launcher_contract_sha256 -cne $version.launcher_contract_sha256 -or
        $compatibility.lan_config_sha256 -cne $version.lan_config_sha256) {
        throw 'CLIENT-COMPATIBILITY.tsv and VERSION.tsv are not bound to the same exact client commit and hashes'
    }
    $fingerprint = (Read-TeremoqBoundedUtf8File -Path (Join-Path $root 'public-identity/relay-cert.sha256') -MaxBytes 128).Trim()
    if ($fingerprint -cnotmatch '^[0-9a-f]{64}$') { throw 'invalid relay certificate fingerprint' }
    $lanConfigPath = Join-Path $root 'LAN-CONFIG.json'
    if ((Get-TeremoqBoundedFileSha256 -Path $lanConfigPath -MaxBytes 512) -cne $version.lan_config_sha256) {
        throw 'LAN-CONFIG.json hash mismatch'
    }
    $lanConfig = (Read-TeremoqBoundedUtf8File -Path $lanConfigPath -MaxBytes 512) | ConvertFrom-Json
    $lanKeys = @($lanConfig.PSObject.Properties.Name)
    if ($lanKeys.Count -ne 7 -or @($lanKeys | Where-Object { @('schema_version', 'run_id', 'source_commit', 'relay_url', 'fingerprint_sha256', 'prefix_length', 'namespace') -notcontains $_ }).Count -ne 0 -or
        $lanConfig.schema_version -ne 1 -or
        $lanConfig.run_id -cne $version.run_id -or
        $lanConfig.source_commit -cne $version.source_commit -or
        $lanConfig.relay_url -cne $version.moq_url -or
        $lanConfig.fingerprint_sha256 -cne $fingerprint -or
        $lanConfig.prefix_length -is [bool] -or
        $lanConfig.prefix_length -isnot [ValueType] -or
        [int]$lanConfig.prefix_length -lt 8 -or
        [int]$lanConfig.prefix_length -gt 30 -or
        $lanConfig.namespace -isnot [string] -or
        $lanConfig.namespace.Length -gt 256 -or
        $lanConfig.namespace -cnotmatch '^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$' -or
        @($lanConfig.namespace.Split('/') | Where-Object { $_ -in @('.', '..') }).Count -ne 0) {
        throw 'LAN-CONFIG.json is outside the closed LAN client policy'
    }
    $playerRoot = [IO.Path]::GetFullPath((Join-Path $root $compatibility.player_relative_path))
    if (-not $playerRoot.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'player path escapes StateRoot' }
    $playerItem = Get-Item -LiteralPath $playerRoot -Force
    if (-not $playerItem.PSIsContainer -or ($playerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'player must be a regular directory' }
    $playerManifest = Join-Path $playerRoot 'MANIFEST.sha256.json'
    $launcherContract = Join-Path $playerRoot 'lan-launcher.tsv'
    if (-not (Test-Path -LiteralPath $playerManifest -PathType Leaf) -or -not (Test-Path -LiteralPath $launcherContract -PathType Leaf)) {
        throw 'player manifest or launcher contract is missing'
    }
    $playerManifest = Assert-TeremoqNonReparseFilePath -Path $playerManifest
    $launcherContract = Assert-TeremoqNonReparseFilePath -Path $launcherContract
    if ((Get-TeremoqBoundedFileSha256 -Path $playerManifest -MaxBytes 1048576) -cne $version.player_manifest_sha256 -or
        (Get-TeremoqBoundedFileSha256 -Path $launcherContract -MaxBytes 4096) -cne $version.launcher_contract_sha256) {
        throw 'player manifest or launcher contract hash mismatch'
    }
    $manifest = (Read-TeremoqBoundedUtf8File -Path $playerManifest -MaxBytes 1048576) | ConvertFrom-Json
    $manifestKeys = @($manifest.PSObject.Properties.Name)
    $expectedManifestKeys = @('schema_version', 'artifact', 'package_version', 'source_commit', 'entrypoint', 'files', 'total_bytes')
    if ($manifestKeys.Count -ne $expectedManifestKeys.Count -or @($manifestKeys | Where-Object { $expectedManifestKeys -notcontains $_ }).Count -ne 0 -or
        $manifest.schema_version -ne 1 -or $manifest.artifact -cne 'teremoq-lan-lab-standalone' -or
        $manifest.package_version -cne $version.package_version -or $manifest.source_commit -cne $version.source_commit -or
        $manifest.entrypoint -cne 'start.mjs') {
        throw 'player manifest identity/version/source contract mismatch'
    }
    $launcherValues = Read-TeremoqClosedTsv -Path $launcherContract -MaxBytes 4096 -AllowedKeys @('schema_version', 'source_commit', 'launcher_relative_path', 'launcher_sha256', 'actions', 'levels', 'max_clients', 'network_contract', 'loopback_http_only') -Label 'lan-launcher.tsv'
    if ($launcherValues.schema_version -ne '1' -or
        $launcherValues.source_commit -cne $version.source_commit -or
        $launcherValues.launcher_relative_path -cnotmatch '^[A-Za-z0-9._-]+\.ps1$' -or
        $launcherValues.launcher_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $launcherValues.actions -cne 'start,status,stop,collect' -or
        $launcherValues.levels -cne '1,5,10,25' -or
        $launcherValues.max_clients -cne '25' -or
        $launcherValues.network_contract -cne 'outbound_udp_14433_only' -or
        $launcherValues.loopback_http_only -cne 'true') {
        throw 'player launcher contract values are outside policy'
    }
    $launcherPath = [IO.Path]::GetFullPath((Join-Path $playerRoot $launcherValues.launcher_relative_path))
    if (-not $launcherPath.StartsWith([IO.Path]::GetFullPath($playerRoot), [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $launcherPath -PathType Leaf) -or
        ((Get-Item -LiteralPath $launcherPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        (Get-TeremoqBoundedFileSha256 -Path (Assert-TeremoqNonReparseFilePath -Path $launcherPath) -MaxBytes 1048576) -cne $launcherValues.launcher_sha256) {
        throw 'player launcher artifact/checksum mismatch'
    }
    $forbidden = Get-ChildItem -LiteralPath $root -Recurse -Force -File | Where-Object {
        $_.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/') -notmatch '^\.teremoq-web-build/' -and
        $_.Name -match '(?i)(\.key$|\.p12$|\.pfx$|^id_rsa$|^\.env$|password|secret|token)'
    }
    if ($forbidden) { throw 'forbidden credential-like file in client state' }
    $manifestFiles = @{}
    foreach ($line in (Read-TeremoqBoundedUtf8File -Path (Join-Path $root 'SHA256SUMS') -MaxBytes 1048576) -split "`r?`n") {
        if ([string]::IsNullOrEmpty($line)) { continue }
        if ($line -cnotmatch '^([0-9a-f]{64})  (.+)$') { throw 'invalid SHA256SUMS line' }
        $expected = $Matches[1]
        $relative = $Matches[2].Replace('\', '/')
        if ($manifestFiles.ContainsKey($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|/)\.\.(/|$)') {
            throw 'unsafe or duplicate manifest path'
        }
        $path = [IO.Path]::GetFullPath((Join-Path $root $relative))
        if (-not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "manifest file missing or escaping root: $relative"
        }
        if (((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "manifest file may not be a reparse point: $relative"
        }
        if ((Get-TeremoqBoundedFileSha256 -Path (Assert-TeremoqNonReparseFilePath -Path $path) -MaxBytes 1048576) -cne $expected) {
            throw "checksum mismatch: $relative"
        }
        $manifestFiles[$relative] = $true
    }
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -Force -File) {
        $relative = $file.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
        if ($relative -match '^\.teremoq-web-build/') { continue }
        if ($relative -ne 'SHA256SUMS' -and -not $manifestFiles.ContainsKey($relative)) { throw "unlisted client state file: $relative" }
    }
    return [pscustomobject]@{
        StateRoot = $root
        VersionRoot = $root
        ConfigRoot = $root
        VersionPath = Join-Path $root 'VERSION.tsv'
        FingerprintPath = Join-Path $root 'public-identity\relay-cert.sha256'
        Version = $version
        Compatibility = $compatibility
        LanConfig = $lanConfig
        PlayerRoot = $playerRoot
        LauncherPath = $launcherPath
        LauncherRelativePath = $launcherValues.launcher_relative_path
        RepositorySubdirectory = $compatibility.repository_subdirectory
    }
}

function Get-TeremoqManagedLanStateContext {
    param([Parameter(Mandatory = $true)][string]$StateRoot)

    $slotLibrary = Join-Path $PSScriptRoot 'Client-Slot-State.ps1'
    if (-not (Test-Path -LiteralPath $slotLibrary -PathType Leaf)) { throw 'managed LAN client slot library is absent' }
    . $slotLibrary
    $slot = Get-TeremoqActiveLanClientSlot -StateRoot $StateRoot
    $root = $slot.Layout.StateRoot
    $record = $slot.Record
    $versionRoot = $slot.VersionRoot
    $configRoot = $slot.Layout.ConfigRoot
    $playerRoot = $slot.PlayerRoot

    foreach ($required in @(
        (Join-Path $versionRoot 'VERSION.tsv'),
        (Join-Path $versionRoot 'CLIENT-COMPATIBILITY.tsv'),
        (Join-Path $versionRoot 'SHA256SUMS'),
        (Join-Path $configRoot 'LAN-CONFIG.json'),
        (Join-Path $configRoot 'public-identity\relay-cert.sha256')
    )) { [void](Assert-TeremoqNonReparseFilePath -Path $required) }

    $versionAllowed = @(
        'schema_version','updater_version','updater_commit','player_identity','player_version',
        'config_schema_version','run_id','server_ipv4','moq_url','player_manifest_sha256',
        'launcher_contract_sha256','lan_config_sha256','player_evidence','load_launcher_status'
    )
    $version = Read-TeremoqClosedTsv -Path (Join-Path $versionRoot 'VERSION.tsv') -MaxBytes 4096 `
        -AllowedKeys $versionAllowed -Label 'managed VERSION.tsv'
    $compatibilityAllowed = @(
        'schema_version','repository_url','repository_ref','repository_subdirectory','allowed_client_commit',
        'updater_version','updater_protocol','player_identity','player_version','source_tree',
        'package_lock_sha256','player_relative_path','config_schema_version','player_manifest_sha256',
        'launcher_contract_sha256','lan_config_sha256'
    )
    $compatibility = Read-TeremoqClosedTsv -Path (Join-Path $versionRoot 'CLIENT-COMPATIBILITY.tsv') `
        -MaxBytes 4096 -AllowedKeys $compatibilityAllowed -Label 'managed CLIENT-COMPATIBILITY.tsv'
    if ($version.schema_version -ne '2' -or $compatibility.schema_version -ne '2' -or
        $version.updater_version -cne $record.updater_version -or
        $version.updater_commit -cne $record.updater_commit -or
        $version.player_identity -cne $record.player_identity -or
        $version.player_version -cnotmatch '^[0-9]+[.][0-9]+[.][0-9]+(?:-[0-9A-Za-z.-]+)?$' -or
        $version.config_schema_version -cne '1' -or
        $version.run_id -cnotmatch '^lan-[a-z0-9][a-z0-9-]{0,31}$' -or
        -not (Test-TeremoqCanonicalPrivateUnicastIPv4 -Value $version.server_ipv4) -or
        $version.moq_url -cne "https://$($version.server_ipv4):14433/watch" -or
        $version.player_manifest_sha256 -cne $record.player_manifest_sha256 -or
        $version.launcher_contract_sha256 -cne $record.launcher_contract_sha256 -or
        $version.lan_config_sha256 -cne $record.config_sha256 -or
        $version.player_evidence -cne 'not_measured' -or $version.load_launcher_status -cne 'ready' -or
        $compatibility.repository_url -cne 'https://github.com/Teremoq/teremoq' -or
        $compatibility.repository_ref -cnotmatch '^refs/heads/[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$' -or
        -not (Test-TeremoqSafeRelativeRepositorySubdirectory -Value $compatibility.repository_subdirectory) -or
        $compatibility.allowed_client_commit -cne $record.updater_commit -or
        $compatibility.updater_version -cne $record.updater_version -or
        $compatibility.updater_protocol -cne $record.updater_protocol -or
        $compatibility.player_identity -cne $record.player_identity -or
        $compatibility.player_version -cne $version.player_version -or
        $compatibility.source_tree -cne $record.source_tree -or
        $compatibility.package_lock_sha256 -cne $record.package_lock_sha256 -or
        $compatibility.player_relative_path -cne $record.player_relative_path -or
        $compatibility.config_schema_version -cne '1' -or
        $compatibility.player_manifest_sha256 -cne $record.player_manifest_sha256 -or
        $compatibility.launcher_contract_sha256 -cne $record.launcher_contract_sha256 -or
        $compatibility.lan_config_sha256 -cne $record.config_sha256) {
        throw 'managed updater/player compatibility metadata is inconsistent'
    }

    $sumLines = @((Read-TeremoqBoundedUtf8File -Path (Join-Path $versionRoot 'SHA256SUMS') -MaxBytes 4096) -split "`r?`n" | Where-Object { $_ })
    if ($sumLines.Count -ne 2) { throw 'managed version checksum list is not closed' }
    $seenSums = @{}
    foreach ($line in $sumLines) {
        if ($line -cnotmatch '^([0-9a-f]{64})  (CLIENT-COMPATIBILITY[.]tsv|VERSION[.]tsv)$' -or $seenSums.ContainsKey($Matches[2])) {
            throw 'managed version checksum line is invalid or duplicated'
        }
        $seenSums[$Matches[2]] = $true
        if ((Get-TeremoqBoundedFileSha256 -Path (Join-Path $versionRoot $Matches[2]) -MaxBytes 4096) -cne $Matches[1]) {
            throw 'managed version metadata checksum mismatch'
        }
    }

    $configPath = Join-Path $configRoot 'LAN-CONFIG.json'
    $configText = Read-TeremoqBoundedUtf8File -Path $configPath -MaxBytes 512
    if ((Get-TeremoqBoundedFileSha256 -Path $configPath -MaxBytes 512) -cne $record.config_sha256) {
        throw 'managed local LAN configuration hash mismatch'
    }
    try { $lanConfig = $configText | ConvertFrom-Json } catch { throw 'managed local LAN configuration is not JSON' }
    $lanKeys = @($lanConfig.PSObject.Properties.Name)
    $expectedLanKeys = @('schema_version','run_id','relay_url','fingerprint_sha256','prefix_length','namespace')
    $fingerprintPath = Join-Path $configRoot 'public-identity\relay-cert.sha256'
    $fingerprint = (Read-TeremoqBoundedUtf8File -Path $fingerprintPath -MaxBytes 128).Trim()
    if ($lanKeys.Count -ne $expectedLanKeys.Count -or @($lanKeys | Where-Object { $expectedLanKeys -cnotcontains $_ }).Count -ne 0 -or
        $lanConfig.schema_version -ne 1 -or $lanConfig.run_id -cne $version.run_id -or
        $lanConfig.relay_url -cne $version.moq_url -or $lanConfig.fingerprint_sha256 -cne $fingerprint -or
        $fingerprint -cnotmatch '^[0-9a-f]{64}$' -or $lanConfig.prefix_length -is [bool] -or
        $lanConfig.prefix_length -isnot [ValueType] -or [int]$lanConfig.prefix_length -lt 8 -or
        [int]$lanConfig.prefix_length -gt 30 -or $lanConfig.namespace -isnot [string] -or
        $lanConfig.namespace.Length -lt 1 -or $lanConfig.namespace.Length -gt 256 -or
        $lanConfig.namespace -cnotmatch '^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$' -or
        @($lanConfig.namespace.Split('/') | Where-Object { $_ -in @('.', '..') }).Count -ne 0) {
        throw 'managed local LAN configuration is outside policy'
    }

    $manifestPath = Assert-TeremoqNonReparseFilePath -Path (Join-Path $playerRoot 'MANIFEST.sha256.json')
    $launcherContractPath = Assert-TeremoqNonReparseFilePath -Path (Join-Path $playerRoot 'lan-launcher.tsv')
    if ((Get-TeremoqBoundedFileSha256 -Path $manifestPath -MaxBytes 1048576) -cne $record.player_manifest_sha256 -or
        (Get-TeremoqBoundedFileSha256 -Path $launcherContractPath -MaxBytes 4096) -cne $record.launcher_contract_sha256) {
        throw 'managed player manifest or launcher contract hash mismatch'
    }
    $manifest = (Read-TeremoqBoundedUtf8File -Path $manifestPath -MaxBytes 1048576) | ConvertFrom-Json
    $manifestKeys = @($manifest.PSObject.Properties.Name)
    $expectedManifestKeys = @('schema_version','artifact','entrypoint','package_version','updater_version','player_identity','player_version','config_schema_version','files','total_bytes')
    if ($manifestKeys.Count -ne $expectedManifestKeys.Count -or @($manifestKeys | Where-Object { $expectedManifestKeys -cnotcontains $_ }).Count -ne 0 -or
        $manifest.schema_version -ne 1 -or $manifest.artifact -cne 'teremoq-lan-lab-standalone' -or
        $manifest.entrypoint -cne 'start.mjs' -or $manifest.package_version -cne $version.player_version -or
        $manifest.updater_version -cne $record.updater_version -or $manifest.player_identity -cne $record.player_identity -or
        $manifest.player_version -cne $version.player_version -or $manifest.config_schema_version -ne 1 -or
        $manifest.files -isnot [Array] -or $manifest.files.Count -lt 1 -or $manifest.files.Count -gt 10000 -or
        $manifest.total_bytes -is [bool] -or $manifest.total_bytes -isnot [ValueType] -or
        [Int64]$manifest.total_bytes -lt 1 -or [Int64]$manifest.total_bytes -gt 134217728) {
        throw 'managed player manifest identity or inventory header is invalid'
    }
    $listed = @{}
    $measuredBytes = [Int64]0
    foreach ($entry in @($manifest.files)) {
        $entryKeys = @($entry.PSObject.Properties.Name)
        if ($entryKeys.Count -ne 3 -or @($entryKeys | Where-Object { @('path','bytes','sha256') -cnotcontains $_ }).Count -ne 0 -or
            $entry.path -isnot [string] -or $entry.path.Length -lt 1 -or $entry.path.Length -gt 260 -or
            [IO.Path]::IsPathRooted($entry.path) -or $entry.path -match '(^|/)\.\.(/|$)|\\' -or
            $entry.bytes -is [bool] -or $entry.bytes -isnot [ValueType] -or [Int64]$entry.bytes -lt 0 -or
            [Int64]$entry.bytes -gt 104857600 -or $entry.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            $listed.ContainsKey($entry.path)) { throw 'managed player manifest entry is unsafe or duplicated' }
        $path = [IO.Path]::GetFullPath((Join-Path $playerRoot $entry.path))
        if (-not $path.StartsWith($playerRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'managed player manifest entry escapes its root'
        }
        $path = Assert-TeremoqNonReparseFilePath -Path $path
        $item = Get-Item -LiteralPath $path -Force
        if ([Int64]$item.Length -ne [Int64]$entry.bytes -or
            (Get-TeremoqBoundedFileSha256 -Path $path -MaxBytes 104857600) -cne $entry.sha256) {
            throw 'managed player file differs from its manifest'
        }
        $listed[$entry.path] = $true
        $measuredBytes += [Int64]$entry.bytes
    }
    if ($measuredBytes -ne [Int64]$manifest.total_bytes) { throw 'managed player total byte count is inconsistent' }
    foreach ($file in @(Get-ChildItem -LiteralPath $playerRoot -Recurse -Force -File)) {
        $relative = $file.FullName.Substring($playerRoot.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
        if ($relative -cne 'MANIFEST.sha256.json' -and -not $listed.ContainsKey($relative)) {
            throw 'managed player contains an unlisted file'
        }
    }

    $launcherAllowed = @(
        'schema_version','launcher_relative_path','launcher_sha256','actions','levels','max_clients',
        'network_contract','loopback_http_only','updater_version','player_identity','player_version','config_schema_version'
    )
    $launcher = Read-TeremoqClosedTsv -Path $launcherContractPath -MaxBytes 4096 -AllowedKeys $launcherAllowed -Label 'managed lan-launcher.tsv'
    if ($launcher.schema_version -ne '1' -or $launcher.launcher_relative_path -cnotmatch '^[A-Za-z0-9._-]+[.]ps1$' -or
        $launcher.launcher_sha256 -cnotmatch '^[0-9a-f]{64}$' -or $launcher.actions -cne 'start,status,stop,collect' -or
        $launcher.levels -cne '1,5,10,25' -or $launcher.max_clients -cne '25' -or
        $launcher.network_contract -cne 'outbound_udp_14433_only' -or $launcher.loopback_http_only -cne 'true' -or
        $launcher.updater_version -cne $record.updater_version -or $launcher.player_identity -cne $record.player_identity -or
        $launcher.player_version -cne $version.player_version -or $launcher.config_schema_version -cne '1') {
        throw 'managed player launcher contract values are outside policy'
    }
    $launcherPath = [IO.Path]::GetFullPath((Join-Path $playerRoot $launcher.launcher_relative_path))
    if (-not $launcherPath.StartsWith($playerRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        (Get-TeremoqBoundedFileSha256 -Path (Assert-TeremoqNonReparseFilePath -Path $launcherPath) -MaxBytes 1048576) -cne $launcher.launcher_sha256) {
        throw 'managed player launcher artifact differs from its contract'
    }
    return [pscustomobject]@{
        StateRoot = $root
        VersionRoot = $versionRoot
        ConfigRoot = $configRoot
        VersionPath = Join-Path $versionRoot 'VERSION.tsv'
        FingerprintPath = $fingerprintPath
        Version = $version
        Compatibility = $compatibility
        LanConfig = $lanConfig
        PlayerRoot = $playerRoot
        LauncherPath = $launcherPath
        LauncherRelativePath = $launcher.launcher_relative_path
        RepositorySubdirectory = $compatibility.repository_subdirectory
        SlotRecord = $record
    }
}

function Get-TeremoqGitCheckoutContext {
    param(
        [Parameter(Mandatory = $true)][string]$CheckoutRoot,
        [Parameter(Mandatory = $true)]$StateContext,
        [switch]$RequireExactHead
    )
    $root = Get-TeremoqNonReparseDirectoryPath -Path $CheckoutRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'CheckoutRoot must exist' }
    $item = Get-Item -LiteralPath $root -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'CheckoutRoot may not be a reparse point' }
    Assert-TeremoqRootsSeparated -CheckoutRoot $root -StateRoot $StateContext.StateRoot
    $topLevel = [IO.Path]::GetFullPath((Invoke-TeremoqGit -CheckoutRoot $root -Arguments @('rev-parse', '--show-toplevel')))
    if ($topLevel -cne $root) {
        throw 'CheckoutRoot is not the Git repository root'
    }
    $status = Invoke-TeremoqGit -CheckoutRoot $root -Arguments @('status', '--porcelain=v1', '--untracked-files=all')
    if (-not [string]::IsNullOrEmpty($status)) { throw 'Git checkout must be clean, including untracked files' }
    $remoteOutput = Invoke-TeremoqGit -CheckoutRoot $root -Arguments @('remote')
    $remotes = @($remoteOutput -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($remotes.Count -ne 1 -or $remotes[0] -cne 'origin') { throw 'Git checkout must expose exactly one remote named origin' }
    $fetchUrlOutput = Invoke-TeremoqGit -CheckoutRoot $root -Arguments @('config', '--get-all', 'remote.origin.url')
    $fetchUrls = @($fetchUrlOutput -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($fetchUrls.Count -ne 1 -or $fetchUrls[0] -cne $StateContext.Compatibility.repository_url) {
        throw 'Git remote URL differs from the approved client repository URL'
    }
    $pushUrls = @(Get-TeremoqOptionalGitConfigValues -CheckoutRoot $root -Key 'remote.origin.pushurl')
    if ($pushUrls.Count -gt 1 -or ($pushUrls.Count -eq 1 -and $pushUrls[0] -cne $fetchUrls[0])) {
        throw 'Git push URL differs from the approved client repository URL'
    }
    $head = Invoke-TeremoqGit -CheckoutRoot $root -Arguments @('rev-parse', 'HEAD')
    if ($head -cnotmatch '^[0-9a-f]{40}$') { throw 'Git HEAD is not an exact commit' }
    if ($RequireExactHead -and $head -cne $StateContext.Compatibility.allowed_client_commit) {
        throw 'Git checkout HEAD differs from the approved client commit'
    }
    $supportRoot = [IO.Path]::GetFullPath((Join-Path $root $StateContext.RepositorySubdirectory))
    if (-not $supportRoot.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $supportRoot -PathType Container)) {
        throw 'approved repository_subdirectory is absent from the checkout'
    }
    foreach ($required in @('client/Install-LanClient.ps1', 'client/Initialize-LanClientState.ps1', 'client/Update-LanClient.ps1', 'client/Stage-LanClientUpdate.ps1', 'client/Pin-LanUpdateLauncher.ps1', 'client/Invoke-LanLoad.ps1', 'client/Verify-Package.ps1', 'client/Import-BrowserObservation.ps1', 'client/Client-Distribution.ps1', 'client/Client-Slot-State.ps1', 'client/Manage-LanClientSlots.ps1', 'windows/Preflight-Client.ps1', 'windows/Collect-Evidence.ps1', 'windows/Preflight-Contract.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $supportRoot $required) -PathType Leaf)) {
            throw "required LAN support file is absent from checkout: $required"
        }
    }
    return [pscustomobject]@{
        CheckoutRoot = $root
        Head = $head
        SupportRoot = $supportRoot
        FetchUrl = $fetchUrls[0]
    }
}

function Get-TeremoqGitBootstrapCheckoutContext {
    param(
        [Parameter(Mandatory = $true)][string]$CheckoutRoot,
        [Parameter(Mandatory = $true)][string]$RepositoryUrl,
        [Parameter(Mandatory = $true)][string]$RepositoryRef,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$RepositorySubdirectory
    )
    Assert-TeremoqApprovedGitBootstrapParameters -RepositoryUrl $RepositoryUrl -RepositoryRef $RepositoryRef -ExpectedCommit $ExpectedCommit -RepositorySubdirectory $RepositorySubdirectory
    $root = Get-TeremoqNonReparseDirectoryPath -Path $CheckoutRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'CheckoutRoot must exist' }
    $item = Get-Item -LiteralPath $root -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'CheckoutRoot may not be a reparse point' }
    $topLevel = [IO.Path]::GetFullPath((Invoke-TeremoqGit -CheckoutRoot $root -Arguments @('rev-parse', '--show-toplevel')))
    if ($topLevel -cne $root) { throw 'CheckoutRoot is not the Git repository root' }
    $status = Invoke-TeremoqGit -CheckoutRoot $root -Arguments @('status', '--porcelain=v1', '--untracked-files=all')
    if (-not [string]::IsNullOrEmpty($status)) { throw 'Git checkout must be clean, including untracked files' }
    $remoteOutput = Invoke-TeremoqGit -CheckoutRoot $root -Arguments @('remote')
    $remotes = @($remoteOutput -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($remotes.Count -ne 1 -or $remotes[0] -cne 'origin') { throw 'Git checkout must expose exactly one remote named origin' }
    $fetchUrlOutput = Invoke-TeremoqGit -CheckoutRoot $root -Arguments @('config', '--get-all', 'remote.origin.url')
    $fetchUrls = @($fetchUrlOutput -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($fetchUrls.Count -ne 1 -or $fetchUrls[0] -cne $RepositoryUrl) { throw 'Git remote URL differs from the approved client repository URL' }
    $pushUrls = @(Get-TeremoqOptionalGitConfigValues -CheckoutRoot $root -Key 'remote.origin.pushurl')
    if ($pushUrls.Count -gt 1 -or ($pushUrls.Count -eq 1 -and $pushUrls[0] -cne $fetchUrls[0])) { throw 'Git push URL differs from the approved client repository URL' }
    $branch = Get-TeremoqRepositoryBranchName -RepositoryRef $RepositoryRef
    if ((Invoke-TeremoqGit -CheckoutRoot $root -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')) -cne $branch) { throw 'Git checkout is not on the approved LAN branch' }
    if ((Invoke-TeremoqGit -CheckoutRoot $root -Arguments @('rev-parse', 'HEAD')) -cne $ExpectedCommit) { throw 'Git checkout HEAD differs from the approved client commit' }
    $supportRoot = [IO.Path]::GetFullPath((Join-Path $root $RepositorySubdirectory))
    if (-not $supportRoot.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $supportRoot -PathType Container)) { throw 'approved repository_subdirectory is absent from the checkout' }
    return [pscustomobject]@{ CheckoutRoot = $root; Head = $ExpectedCommit; SupportRoot = $supportRoot }
}

function Invoke-TeremoqGitFastForwardUpdate {
    param(
        [Parameter(Mandatory = $true)][string]$CheckoutRoot,
        [Parameter(Mandatory = $true)][string]$RepositoryUrl,
        [Parameter(Mandatory = $true)][string]$RepositoryRef,
        [Parameter(Mandatory = $true)][string]$RepositorySubdirectory,
        [Parameter(Mandatory = $true)][string]$CurrentCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit
    )
    if ($ExpectedCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'expected update commit must be an exact lowercase Git commit' }
    $current = Get-TeremoqGitBootstrapCheckoutContext -CheckoutRoot $CheckoutRoot -RepositoryUrl $RepositoryUrl `
        -RepositoryRef $RepositoryRef -ExpectedCommit $CurrentCommit -RepositorySubdirectory $RepositorySubdirectory
    $branch = Get-TeremoqRepositoryBranchName -RepositoryRef $RepositoryRef
    $upstream = Invoke-TeremoqGit -CheckoutRoot $current.CheckoutRoot -Arguments @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}')
    if ($upstream -cne ("origin/{0}" -f $branch)) { throw 'Git checkout upstream differs from the approved LAN branch' }
    Invoke-TeremoqGit -CheckoutRoot $current.CheckoutRoot -Arguments @('fetch', '--no-tags', 'origin', $RepositoryRef) | Out-Null
    $fetched = Invoke-TeremoqGit -CheckoutRoot $current.CheckoutRoot -Arguments @('rev-parse', 'FETCH_HEAD')
    if ($fetched -cne $ExpectedCommit) { throw 'fetched commit differs from the explicitly approved update commit' }
    if ($fetched -cne $CurrentCommit) {
        try {
            Invoke-TeremoqGit -CheckoutRoot $current.CheckoutRoot -Arguments @('merge-base', '--is-ancestor', $CurrentCommit, $fetched) | Out-Null
        } catch {
            throw 'Git checkout diverges from the approved update commit; ff-only update is forbidden'
        }
        Invoke-TeremoqGit -CheckoutRoot $current.CheckoutRoot -Arguments @('merge', '--ff-only', $fetched) | Out-Null
    }
    return Get-TeremoqGitBootstrapCheckoutContext -CheckoutRoot $current.CheckoutRoot -RepositoryUrl $RepositoryUrl `
        -RepositoryRef $RepositoryRef -ExpectedCommit $ExpectedCommit -RepositorySubdirectory $RepositorySubdirectory
}

function Get-TeremoqWebGenerationContext {
    param(
        [Parameter(Mandatory = $true)]$Checkout,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$PlayerRelativePath,
        [Parameter(Mandatory = $true)][string]$PlayerManifestSha256,
        [Parameter(Mandatory = $true)][string]$LauncherContractSha256
    )
    $generation = Join-Path $StateRoot ('.teremoq-web-build\generations\' + $Checkout.Head + '.tsv')
    [void](Get-TeremoqNonReparseDirectoryPath -Path (Split-Path -Parent $generation))
    [void](Get-TeremoqNonReparseDirectoryPath -Path (Split-Path -Parent ([IO.Path]::GetFullPath((Join-Path $StateRoot $PlayerRelativePath)))))
    $generation = Assert-TeremoqNonReparseFilePath -Path $generation
    $allowed = @('schema_version','repository_url','repository_ref','source_commit','source_tree','source_contract_sha256','package_lock_sha256','package_json_sha256','node_version','npm_version','dependency_mode','previous_source_commit','source_diff_files','source_diff_sha256','independent_builds','byte_identical','player_manifest_sha256','launcher_contract_sha256','inventory_sha256','player_relative_path')
    $values = Read-TeremoqClosedTsv -Path $generation -MaxBytes 8192 -AllowedKeys $allowed -Label 'Web generation provenance'
    $project = Join-Path $Checkout.CheckoutRoot 'supervisor-web'
    $contract = Join-Path $project 'lan-player\source-contract.tsv'
    $lock = Join-Path $project 'package-lock.json'
    $package = Join-Path $project 'package.json'
    foreach ($path in @($project, $contract, $lock, $package)) {
        if (-not (Test-Path -LiteralPath $path) -or ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Web source provenance path is absent or a reparse point' }
    }
    $tree = Invoke-TeremoqGit -CheckoutRoot $Checkout.CheckoutRoot -Arguments @('rev-parse', ($Checkout.Head + ':supervisor-web'))
    $inventory = Get-TeremoqWebPlayerInventorySha256 -PlayerRoot ([IO.Path]::GetFullPath((Join-Path $StateRoot $PlayerRelativePath)))
    if ($values.schema_version -ne '1' -or $values.repository_url -cne 'https://github.com/Teremoq/teremoq' -or
        $values.repository_ref -cne (Invoke-TeremoqGit -CheckoutRoot $Checkout.CheckoutRoot -Arguments @('symbolic-ref','--quiet','HEAD')) -or
        $values.source_commit -cne $Checkout.Head -or $values.source_tree -cne $tree -or
        $values.source_contract_sha256 -cne (Get-TeremoqBoundedFileSha256 -Path $contract -MaxBytes 4096) -or
        $values.package_lock_sha256 -cne (Get-TeremoqBoundedFileSha256 -Path $lock -MaxBytes 1048576) -or
        $values.package_json_sha256 -cne (Get-TeremoqBoundedFileSha256 -Path $package -MaxBytes 65536) -or
        $values.node_version -cnotmatch '^v22[.][0-9]+[.][0-9]+$' -or $values.npm_version -cnotmatch '^10[.][0-9]+[.][0-9]+$' -or
        $values.independent_builds -cne '2' -or $values.byte_identical -cne 'true' -or
        $values.player_manifest_sha256 -cne $PlayerManifestSha256 -or $values.launcher_contract_sha256 -cne $LauncherContractSha256 -or
        $values.inventory_sha256 -cne $inventory -or $values.player_relative_path -cne $PlayerRelativePath -or
        $values.source_diff_files -cnotmatch '^[0-9]+$' -or $values.source_diff_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $values.dependency_mode -notin @('initial-npm-ci','reused-lock-cache','explicit-lock-refresh') -or $values.previous_source_commit -cnotmatch '^(none|[0-9a-f]{40})$') {
        throw 'Web generation provenance is not bound to the exact clean Git source and player'
    }
    return $values
}

function Get-TeremoqWebPlayerInventorySha256 {
    param([Parameter(Mandatory = $true)][string]$PlayerRoot)
    $root = Get-TeremoqNonReparseDirectoryPath -Path $PlayerRoot
    $items = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File)
    if ($items.Count -lt 1 -or $items.Count -gt 10000) { throw 'Web player inventory cardinality is outside policy' }
    foreach ($item in $items) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -gt 104857600) { throw 'Web player inventory contains unsafe file' }
    }
    $inventory = @($items | ForEach-Object {
        [ordered]@{ path = $_.FullName.Substring($root.Length).TrimStart([char[]]@('\','/')).Replace('\','/'); bytes = [Int64]$_.Length; sha256 = (Get-TeremoqBoundedFileSha256 -Path (Assert-TeremoqNonReparseFilePath -Path $_.FullName) -MaxBytes 104857600) }
    } | Sort-Object @{ Expression = { if ($_.path -eq 'MANIFEST.sha256.json') { 1 } else { 0 } } }, @{ Expression = { $_.path } })
    $json = (ConvertTo-Json -InputObject $inventory -Compress -Depth 3) + "`n"
    $encoding = New-Object Text.UTF8Encoding($false)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hasher.ComputeHash($encoding.GetBytes($json))) -replace '-', '').ToLowerInvariant() } finally { $hasher.Dispose() }
}
