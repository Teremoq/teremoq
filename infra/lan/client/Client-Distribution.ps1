# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version 3.0

function Read-TeremoqBoundedUtf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$MaxBytes
    )
    if ($MaxBytes -lt 1 -or $MaxBytes -gt 1048576) { throw 'bounded file limit is outside 1..1048576 bytes' }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "path is not a regular non-reparse file: $Path"
    }
    if ($item.Length -gt $MaxBytes) { throw "file exceeds ${MaxBytes} bytes: $Path" }
    $stream = [IO.File]::Open($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $buffer = New-Object byte[] ($item.Length + 1)
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -ne $item.Length -or $stream.ReadByte() -ne -1) { throw "file changed while reading: $Path" }
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
    if ($TimeoutMilliseconds -lt 1000 -or $TimeoutMilliseconds -gt 60000) { throw 'native process timeout is outside 1000..60000 ms' }
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
    $result = Invoke-TeremoqBoundedNativeProcess -FilePath $gitPath -WorkingDirectory $CheckoutRoot -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        $detail = $result.Stderr.Trim()
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = $result.Stdout.Trim() }
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = 'no additional detail' }
        if ($detail.Length -gt 1024) { $detail = $detail.Substring(0, 1024) }
        throw "Git command failed: $detail"
    }
    return ($result.Stdout -replace "`r", '').TrimEnd("`n")
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

function Get-TeremoqLanStateContext {
    param([Parameter(Mandatory = $true)][string]$StateRoot)
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
    if ((Get-FileHash -LiteralPath $lanConfigPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $version.lan_config_sha256) {
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
    if ((Get-FileHash -LiteralPath $playerManifest -Algorithm SHA256).Hash.ToLowerInvariant() -cne $version.player_manifest_sha256 -or
        (Get-FileHash -LiteralPath $launcherContract -Algorithm SHA256).Hash.ToLowerInvariant() -cne $version.launcher_contract_sha256) {
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
        (Get-FileHash -LiteralPath $launcherPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $launcherValues.launcher_sha256) {
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
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected) {
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
        Version = $version
        Compatibility = $compatibility
        LanConfig = $lanConfig
        PlayerRoot = $playerRoot
        LauncherPath = $launcherPath
        LauncherRelativePath = $launcherValues.launcher_relative_path
        RepositorySubdirectory = $compatibility.repository_subdirectory
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
    $remotes = @(Invoke-TeremoqGit -CheckoutRoot $root -Arguments @('remote') -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($remotes.Count -ne 1 -or $remotes[0] -cne 'origin') { throw 'Git checkout must expose exactly one remote named origin' }
    $fetchUrls = @(Invoke-TeremoqGit -CheckoutRoot $root -Arguments @('config', '--get-all', 'remote.origin.url') -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($fetchUrls.Count -ne 1 -or $fetchUrls[0] -cne $StateContext.Compatibility.repository_url) {
        throw 'Git remote URL differs from the approved client repository URL'
    }
    $pushUrls = @(Invoke-TeremoqGit -CheckoutRoot $root -Arguments @('config', '--get-all', 'remote.origin.pushurl') -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
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
    foreach ($required in @('client/Install-LanClient.ps1', 'client/Initialize-LanClientState.ps1', 'client/Update-LanClient.ps1', 'client/Invoke-LanLoad.ps1', 'client/Verify-Package.ps1', 'client/Import-BrowserObservation.ps1', 'client/Client-Distribution.ps1', 'windows/Preflight-Client.ps1', 'windows/Collect-Evidence.ps1', 'windows/Preflight-Contract.ps1')) {
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
    $remotes = @(Invoke-TeremoqGit -CheckoutRoot $root -Arguments @('remote') -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($remotes.Count -ne 1 -or $remotes[0] -cne 'origin') { throw 'Git checkout must expose exactly one remote named origin' }
    $fetchUrls = @(Invoke-TeremoqGit -CheckoutRoot $root -Arguments @('config', '--get-all', 'remote.origin.url') -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($fetchUrls.Count -ne 1 -or $fetchUrls[0] -cne $RepositoryUrl) { throw 'Git remote URL differs from the approved client repository URL' }
    $pushUrls = @(Invoke-TeremoqGit -CheckoutRoot $root -Arguments @('config', '--get-all', 'remote.origin.pushurl') -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($pushUrls.Count -gt 1 -or ($pushUrls.Count -eq 1 -and $pushUrls[0] -cne $fetchUrls[0])) { throw 'Git push URL differs from the approved client repository URL' }
    $branch = Get-TeremoqRepositoryBranchName -RepositoryRef $RepositoryRef
    if ((Invoke-TeremoqGit -CheckoutRoot $root -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')) -cne $branch) { throw 'Git checkout is not on the approved LAN branch' }
    if ((Invoke-TeremoqGit -CheckoutRoot $root -Arguments @('rev-parse', 'HEAD')) -cne $ExpectedCommit) { throw 'Git checkout HEAD differs from the approved client commit' }
    $supportRoot = [IO.Path]::GetFullPath((Join-Path $root $RepositorySubdirectory))
    if (-not $supportRoot.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $supportRoot -PathType Container)) { throw 'approved repository_subdirectory is absent from the checkout' }
    return [pscustomobject]@{ CheckoutRoot = $root; Head = $ExpectedCommit; SupportRoot = $supportRoot }
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
    if ($values.schema_version -ne '1' -or $values.repository_url -cne 'https://github.com/Teremoq/teremoq' -or
        $values.repository_ref -cne (Invoke-TeremoqGit -CheckoutRoot $Checkout.CheckoutRoot -Arguments @('symbolic-ref','--quiet','HEAD')) -or
        $values.source_commit -cne $Checkout.Head -or $values.source_tree -cne $tree -or
        $values.source_contract_sha256 -cne (Get-FileHash -LiteralPath $contract -Algorithm SHA256).Hash.ToLowerInvariant() -or
        $values.package_lock_sha256 -cne (Get-FileHash -LiteralPath $lock -Algorithm SHA256).Hash.ToLowerInvariant() -or
        $values.package_json_sha256 -cne (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant() -or
        $values.node_version -cnotmatch '^v22[.][0-9]+[.][0-9]+$' -or $values.npm_version -cnotmatch '^10[.][0-9]+[.][0-9]+$' -or
        $values.independent_builds -cne '2' -or $values.byte_identical -cne 'true' -or
        $values.player_manifest_sha256 -cne $PlayerManifestSha256 -or $values.launcher_contract_sha256 -cne $LauncherContractSha256 -or
        $values.inventory_sha256 -cnotmatch '^[0-9a-f]{64}$' -or $values.player_relative_path -cne $PlayerRelativePath -or
        $values.source_diff_files -cnotmatch '^[0-9]+$' -or $values.source_diff_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $values.dependency_mode -notin @('initial','reused','refreshed') -or $values.previous_source_commit -cnotmatch '^(none|[0-9a-f]{40})$') {
        throw 'Web generation provenance is not bound to the exact clean Git source and player'
    }
    return $values
}
