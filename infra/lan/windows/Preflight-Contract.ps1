# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0

function Format-TeremoqInvariantDecimal {
    param([Parameter(Mandatory = $true)][double]$Value)
    return $Value.ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-TeremoqExactWifiAdapter {
    param([Parameter(Mandatory = $true)][int]$InterfaceIndex)
    $adapters = @(Get-NetAdapter -InterfaceIndex $InterfaceIndex -ErrorAction SilentlyContinue)
    if ($adapters.Count -ne 1) { return $null }
    $adapter = $adapters[0]
    $physicalMedia = [string]$adapter.PhysicalMediaType
    $ndisMedium = [int]$adapter.NdisPhysicalMedium
    if ($adapter.Status -ne 'Up' -or ($physicalMedia -ne 'Native 802.11' -and $ndisMedium -ne 9)) { return $null }
    return $adapter
}

function Get-TeremoqWlanObservation {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$AdapterName
    )
    function Normalize-TeremoqWifiBandCandidate {
        param([Parameter(Mandatory = $true)][string]$Value)
        if ($Value.Length -gt 64) { return $null }
        $builder = New-Object System.Text.StringBuilder
        foreach ($character in $Value.ToCharArray()) {
            if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($character) -eq [System.Globalization.UnicodeCategory]::SpaceSeparator) {
                [void]$builder.Append(' ')
            } else {
                [void]$builder.Append($character)
            }
        }
        $normalized = $builder.ToString().Trim()
        if ($normalized.Length -gt 64) { return $null }
        return $normalized
    }
    if ($Text.Length -gt 32768) { throw 'netsh wlan output exceeds 32768 bytes' }
    $blocks = New-Object System.Collections.Generic.List[object]
    $current = $null
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '(?im)^\s*(Name|Nombre)\s*:\s*([^\r\n]+)\s*$') {
            if ($null -ne $current) { $blocks.Add([pscustomobject]$current) }
            $current = [ordered]@{
                Name = $Matches[2].Trim()
                Band = 'unavailable'
                Radio = 'unavailable'
                BandCount = 0
                RadioCount = 0
                Ambiguous = $false
            }
            continue
        }
        if ($null -eq $current) { continue }
        if ($line -match '(?im)^\s*(Band|Banda)\s*:\s*([^\r\n]+)\s*$') {
            $current.BandCount += 1
            if ($current.BandCount -gt 1) {
                $current.Ambiguous = $true
            } else {
                $current.Band = $Matches[2]
            }
            continue
        }
        if ($line -match '(?im)^\s*(Radio type|Tipo de radio)\s*:\s*([^\r\n]+)\s*$') {
            $current.RadioCount += 1
            if ($current.RadioCount -gt 1) {
                $current.Ambiguous = $true
            } else {
                $current.Radio = $Matches[2]
            }
        }
    }
    if ($null -ne $current) { $blocks.Add([pscustomobject]$current) }
    $matches = @($blocks | Where-Object { $_.Name -ceq $AdapterName })
    if ($matches.Count -ne 1 -or $matches[0].Ambiguous) {
        return [pscustomobject]@{ Band = 'unavailable'; Radio = 'unavailable'; IsCanonical5GHz = $false; FallbackRadioQualified = $false }
    }
    $band = [string]$matches[0].Band
    $radio = [string]$matches[0].Radio
    $normalizedBand = if ($band -ne 'unavailable') { Normalize-TeremoqWifiBandCandidate -Value $band } else { $null }
    $fallbackRadioQualified = $matches[0].BandCount -eq 0 -and $matches[0].RadioCount -eq 1 -and $radio -in @('802.11a', '802.11ac')
    return [pscustomobject]@{
        Band = $(if ($normalizedBand -ceq '5 GHz') { '5 GHz' } else { $band })
        Radio = $radio
        IsCanonical5GHz = $normalizedBand -ceq '5 GHz'
        FallbackRadioQualified = $fallbackRadioQualified
    }
}

function Convert-TeremoqPhaseOffsetMilliseconds {
    param([Parameter(Mandatory = $true)][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 32768) { return $null }
    $matches = [regex]::Matches($Text, '(?im)^\s*(Phase Offset|Desplazamiento de fase|Desfase de fase)\s*:\s*([+-]?[0-9]+(?:[.,][0-9]+)?)\s*s\s*$')
    if ($matches.Count -ne 1) { return $null }
    $candidate = $matches[0].Groups[2].Value.Replace(',', '.')
    $value = 0.0
    if (-not [double]::TryParse($candidate, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value) -or
        [double]::IsNaN($value) -or [double]::IsInfinity($value)) {
        return $null
    }
    return [math]::Round($value * 1000.0, 3)
}

function Read-TeremoqBoundedUtf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$MaxBytes
    )
    if ($MaxBytes -lt 1 -or $MaxBytes -gt 65536) { throw 'bounded UTF-8 file limit is outside 1..65536 bytes' }
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $buffer = New-Object byte[] ($MaxBytes + 1)
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -gt $MaxBytes) { throw "bounded UTF-8 file exceeds ${MaxBytes} bytes" }
        return $encoding.GetString($buffer, 0, $read)
    } finally {
        $stream.Dispose()
    }
}

function Test-TeremoqAllowedWslMountWarningLine {
    param([Parameter(Mandatory = $true)][string]$Line)
    return $Line -cmatch '^WSL: Failed to mount [A-Z]:\\, see dmesg for more details\.$'
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
    if ($backslashes -gt 0) {
        [void]$builder.Append('\' * ($backslashes * 2))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Convert-TeremoqWindowsCommandLine {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    if ($Arguments.Count -lt 1 -or $Arguments.Count -gt 16) { throw 'native process argument count is outside 1..16' }
    return (($Arguments | ForEach-Object { Convert-TeremoqWindowsArgument -Value $_ }) -join ' ')
}

function Read-TeremoqBoundedUtf8StreamCapture {
    param(
        [Parameter(Mandatory = $true)][System.IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][int]$MaxBytes
    )
    if ($MaxBytes -lt 1 -or $MaxBytes -gt 65536) { throw 'bounded stream limit is outside 1..65536 bytes' }
    $buffer = New-Object byte[] 256
    $bytes = New-Object 'System.Collections.Generic.List[byte]'
    while ($true) {
        $read = $Stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { break }
        for ($index = 0; $index -lt $read; $index += 1) { $bytes.Add($buffer[$index]) }
        if ($bytes.Count -gt $MaxBytes) {
            return [pscustomobject]@{ Oversized = $true; Text = '' }
        }
    }
    $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
    return [pscustomobject]@{
        Oversized = $false
        Text = $strictUtf8.GetString($bytes.ToArray())
    }
}

function Invoke-TeremoqBoundedNativeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)][int]$StdoutMaxBytes,
        [Parameter(Mandatory = $true)][int]$StderrMaxBytes,
        [Parameter()][int]$TimeoutMilliseconds = 15000
    )
    if ($TimeoutMilliseconds -lt 1000 -or $TimeoutMilliseconds -gt 60000) {
        throw 'native process timeout is outside 1000..60000 ms'
    }
    $resolvedPath = [IO.Path]::GetFullPath($FilePath)
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        return [pscustomobject]@{
            Outcome = 'launch-failed'; ExitCode = -1; Stdout = ''; Stderr = ''
        }
    }
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $resolvedPath
    $startInfo.Arguments = Convert-TeremoqWindowsCommandLine -Arguments $ArgumentList
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            return [pscustomobject]@{ Outcome = 'launch-failed'; ExitCode = -1; Stdout = ''; Stderr = '' }
        }
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try { $process.Kill() } catch { return [pscustomobject]@{ Outcome = 'kill-failed'; ExitCode = -1; Stdout = ''; Stderr = '' } }
            if (-not $process.WaitForExit(5000)) {
                return [pscustomobject]@{ Outcome = 'kill-timeout'; ExitCode = -1; Stdout = ''; Stderr = '' }
            }
            return [pscustomobject]@{ Outcome = 'timeout'; ExitCode = -1; Stdout = ''; Stderr = '' }
        }
        $stdoutCapture = Read-TeremoqBoundedUtf8StreamCapture -Stream $process.StandardOutput.BaseStream -MaxBytes $StdoutMaxBytes
        $stderrCapture = Read-TeremoqBoundedUtf8StreamCapture -Stream $process.StandardError.BaseStream -MaxBytes $StderrMaxBytes
        if ($stdoutCapture.Oversized -or $stderrCapture.Oversized) {
            return [pscustomobject]@{ Outcome = 'oversized'; ExitCode = $process.ExitCode; Stdout = ''; Stderr = '' }
        }
        return [pscustomobject]@{
            Outcome = 'ok'
            ExitCode = $process.ExitCode
            Stdout = $stdoutCapture.Text
            Stderr = $stderrCapture.Text
        }
    } catch [System.Text.DecoderFallbackException] {
        return [pscustomobject]@{ Outcome = 'encoding-invalid'; ExitCode = -1; Stdout = ''; Stderr = '' }
    } catch {
        return [pscustomobject]@{ Outcome = 'unavailable'; ExitCode = -1; Stdout = ''; Stderr = '' }
    } finally {
        $process.Dispose()
    }
}

function Test-TeremoqCanonicalPrivateUnicastIPv4 {
    param([Parameter(Mandatory = $true)][string]$Value)
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Value, [ref]$parsed) -or
        $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $parsed.IPAddressToString -cne $Value) {
        return $false
    }
    $bytes = $parsed.GetAddressBytes()
    if ([Net.IPAddress]::IsLoopback($parsed) -or $bytes[0] -eq 0 -or $Value -eq '255.255.255.255') {
        return $false
    }
    if ($bytes[0] -ge 224 -or (($bytes[0] -eq 169) -and ($bytes[1] -eq 254)) -or $bytes[0] -ge 240) { return $false }
    return ($bytes[0] -eq 10) -or ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or ($bytes[0] -eq 192 -and $bytes[1] -eq 168)
}

function Test-TeremoqHostAddressInPrefix {
    param(
        [Parameter(Mandatory = $true)][string]$IPv4,
        [Parameter(Mandatory = $true)][int]$PrefixLength
    )
    if ($PrefixLength -lt 8 -or $PrefixLength -gt 30) { return $false }
    $parts = $IPv4.Split('.')
    if ($parts.Count -ne 4) { return $false }
    [int64]$value = 0
    foreach ($part in $parts) { $value = (($value -shl 8) -bor [int64][int]$part) -band 0xffffffffL }
    [int64]$mask = ((-1L -shl (32 - $PrefixLength)) -band 0xffffffffL)
    [int64]$hostMask = ((-bnot $mask) -band 0xffffffffL)
    $hostBits = $value -band $hostMask
    return $hostBits -ne 0 -and $hostBits -ne $hostMask
}

function Get-TeremoqWslIpv4ModeFromCommandResult {
    param(
        [Parameter(Mandatory = $true)][string]$ClientIPv4,
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [string]$Stdout = '',
        [string]$Stderr = ''
    )
    if ($Stdout.Length -gt 256 -or $Stderr.Length -gt 4096) {
        return [pscustomobject]@{ Mode = 'unavailable'; WarningCount = 0; StderrClassification = 'oversized' }
    }
    if ($ExitCode -ne 0) {
        return [pscustomobject]@{ Mode = 'unavailable'; WarningCount = 0; StderrClassification = 'exit-nonzero' }
    }
    $stdoutMatch = [regex]::Match($Stdout, '^(?<cidr>(?<ip>\d{1,3}(?:\.\d{1,3}){3})/(?<prefix>\d|[12]\d|3[0-2]))(?:\r?\n)?$')
    if (-not $stdoutMatch.Success) {
        return [pscustomobject]@{ Mode = 'unavailable'; WarningCount = 0; StderrClassification = 'stdout-invalid' }
    }
    $wslIpv4 = $stdoutMatch.Groups['ip'].Value
    $prefixLength = [int]$stdoutMatch.Groups['prefix'].Value
    if (-not (Test-TeremoqCanonicalPrivateUnicastIPv4 -Value $wslIpv4) -or -not (Test-TeremoqHostAddressInPrefix -IPv4 $wslIpv4 -PrefixLength $prefixLength)) {
        return [pscustomobject]@{ Mode = 'unavailable'; WarningCount = 0; StderrClassification = 'stdout-invalid' }
    }
    $warningCount = 0
    if (-not [string]::IsNullOrEmpty($Stderr)) {
        $stderrLines = @($Stderr -split "`r?`n")
        if ($stderrLines.Count -gt 8) {
            return [pscustomobject]@{ Mode = 'unavailable'; WarningCount = 0; StderrClassification = 'stderr-invalid' }
        }
        foreach ($stderrLine in $stderrLines) {
            if ([string]::IsNullOrEmpty($stderrLine)) { continue }
            if (-not (Test-TeremoqAllowedWslMountWarningLine -Line $stderrLine)) {
                return [pscustomobject]@{ Mode = 'unavailable'; WarningCount = 0; StderrClassification = 'stderr-invalid' }
            }
            $warningCount += 1
        }
        if ($warningCount -eq 0) {
            return [pscustomobject]@{ Mode = 'unavailable'; WarningCount = 0; StderrClassification = 'stderr-invalid' }
        }
    }
    return [pscustomobject]@{
        Mode = $(if ($wslIpv4 -ceq $ClientIPv4) { 'mirrored' } else { 'nat' })
        WarningCount = $warningCount
        StderrClassification = $(if ($warningCount -gt 0) { 'allowed-mount-warning-redacted' } else { 'none' })
    }
}

function Invoke-TeremoqClientWslIpv4ModeQuery {
    param(
        [Parameter(Mandatory = $true)][string]$ClientIPv4,
        [Parameter()][int]$TimeoutMilliseconds = 15000
    )
    if ($TimeoutMilliseconds -lt 1000 -or $TimeoutMilliseconds -gt 60000) {
        throw 'WSL IPv4 query timeout is outside 1000..60000 ms'
    }
    $result = Invoke-TeremoqBoundedNativeProcess -FilePath "$env:SystemRoot\System32\wsl.exe" `
        -ArgumentList @('-e', 'sh', '-lc', "ip -o -4 addr show scope global 2>/dev/null | awk 'NR==1 {print `$4}'") `
        -StdoutMaxBytes 256 -StderrMaxBytes 4096 -TimeoutMilliseconds $TimeoutMilliseconds
    switch ($result.Outcome) {
        'ok' { return Get-TeremoqWslIpv4ModeFromCommandResult -ClientIPv4 $ClientIPv4 -ExitCode $result.ExitCode -Stdout $result.Stdout -Stderr $result.Stderr }
        'oversized' { return [pscustomobject]@{ Mode = 'unavailable'; WarningCount = 0; StderrClassification = 'oversized' } }
        'launch-failed' { return [pscustomobject]@{ Mode = 'unavailable'; WarningCount = 0; StderrClassification = 'launch-failed' } }
        'timeout' { return [pscustomobject]@{ Mode = 'unavailable'; WarningCount = 0; StderrClassification = 'timeout' } }
        'kill-failed' { return [pscustomobject]@{ Mode = 'unavailable'; WarningCount = 0; StderrClassification = 'kill-failed' } }
        'kill-timeout' { return [pscustomobject]@{ Mode = 'unavailable'; WarningCount = 0; StderrClassification = 'kill-timeout' } }
        default { return [pscustomobject]@{ Mode = 'unavailable'; WarningCount = 0; StderrClassification = 'unavailable' } }
    }
}

function Test-TeremoqDockerHostLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value -in @('localhost', '*', '::')) { return $true }
    $candidate = $Value
    if ($candidate.StartsWith('[') -and $candidate.EndsWith(']')) {
        $candidate = $candidate.Substring(1, $candidate.Length - 2)
    }
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($candidate, [ref]$parsed)) { return $false }
    if ($parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
        return $parsed.IPAddressToString -ceq $candidate
    }
    return $true
}

function Get-TeremoqDockerPublicationConflicts {
    param([Parameter(Mandatory = $true)][string[]]$Rows)
    if ($Rows.Count -gt 128) { throw 'Docker publication row count exceeds 128' }
    $conflicts = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($row in $Rows) {
        if ($row.Length -gt 4096) { throw 'Docker publication row exceeds 4096 bytes' }
        $fields = $row -split "`t", 2
        if ($fields.Count -ne 2 -or $fields[0] -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') {
            throw 'Docker publication row is malformed'
        }
        $service = $fields[0]
        $portsField = $fields[1]
        if ($portsField.Length -gt 3072) { throw 'Docker publication port field exceeds 3072 bytes' }
        if ([string]::IsNullOrEmpty($portsField)) { continue }
        $tokens = @($portsField -split ',')
        if ($tokens.Count -gt 256) { throw 'Docker publication token count exceeds 256' }
        foreach ($tokenValue in $tokens) {
            $token = $tokenValue.Trim()
            if ([string]::IsNullOrEmpty($token)) { throw 'Docker publication token is empty' }
            if ($token -match '^(?<container>\d{1,5})/(?<protocol>tcp|udp)$') {
                $containerPort = [int]$Matches['container']
                if ($containerPort -lt 1 -or $containerPort -gt 65535) { throw 'Docker internal port is outside 1..65535' }
                continue
            }
            if ($token -notmatch '^(?<host>localhost|\d{1,3}(?:\.\d{1,3}){3}|\[[0-9A-Fa-f:.]+\]|::|\*):(?<hostport>\d{1,5})->(?<container>\d{1,5})/(?<protocol>tcp|udp)$') {
                throw 'Docker publication token is malformed'
            }
            if (-not (Test-TeremoqDockerHostLiteral -Value $Matches['host'])) { throw 'Docker publication host literal is invalid' }
            $hostPort = [int]$Matches['hostport']
            $containerPort = [int]$Matches['container']
            if ($hostPort -lt 1 -or $hostPort -gt 65535 -or $containerPort -lt 1 -or $containerPort -gt 65535) {
                throw 'Docker publication port is outside 1..65535'
            }
            $conflict = "$hostPort/$($Matches['protocol'])"
            if ($conflict -notin @('4433/tcp', '5678/tcp', '6379/tcp', '11434/tcp', '4433/udp', '9000/udp', '14433/udp', '19000/udp')) {
                continue
            }
            $record = "service=$service;port=$conflict"
            if ($seen.Add($record)) { $conflicts.Add($record) }
        }
    }
    return @($conflicts)
}

function Get-TeremoqDockerPsFormat {
    return "{{.Names}}" + [string][char]9 + "{{.Ports}}"
}

function Convert-TeremoqProcessCreationDateToCanonicalDmtf {
    param([Parameter(Mandatory = $true)]$Value)
    if ($Value -is [datetime]) {
        try {
            return [System.Management.ManagementDateTimeConverter]::ToDmtfDateTime([datetime]$Value)
        } catch {
            return $null
        }
    }
    if ($Value -isnot [string] -or $Value -cnotmatch '^\d{14}\.\d{6}[+-]\d{3}$') { return $null }
    try {
        [void][System.Management.ManagementDateTimeConverter]::ToDateTime($Value)
        return $Value
    } catch {
        return $null
    }
}

function Get-TeremoqProcessQueryResult {
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    $requestedProcessId = [int64]$ProcessId
    try {
        $processes = @(Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop)
    } catch {
        return [ordered]@{ Status = 'cim_query_failed'; RequestedProcessId = $requestedProcessId; Process = $null }
    }
    if ($processes.Count -eq 0) {
        return [ordered]@{ Status = 'process_missing'; RequestedProcessId = $requestedProcessId; Process = $null }
    }
    if ($processes.Count -ne 1) {
        return [ordered]@{ Status = 'cim_query_failed'; RequestedProcessId = $requestedProcessId; Process = $null }
    }
    $process = $processes[0]
    if ($null -eq $process -or [string]::IsNullOrWhiteSpace([string]$process.Name)) {
        return [ordered]@{ Status = 'process_missing'; RequestedProcessId = $requestedProcessId; Process = $null }
    }
    $name = [string]$process.Name
    $creationDate = Convert-TeremoqProcessCreationDateToCanonicalDmtf -Value $process.CreationDate
    if ($process.ProcessId -is [bool] -or $process.ParentProcessId -is [bool] -or
        $process.ProcessId -isnot [ValueType] -or $process.ParentProcessId -isnot [ValueType] -or
        [Type]::GetTypeCode($process.ProcessId.GetType()) -notin @([TypeCode]::Byte, [TypeCode]::SByte, [TypeCode]::Int16, [TypeCode]::UInt16, [TypeCode]::Int32, [TypeCode]::UInt32, [TypeCode]::Int64, [TypeCode]::UInt64) -or
        [Type]::GetTypeCode($process.ParentProcessId.GetType()) -notin @([TypeCode]::Byte, [TypeCode]::SByte, [TypeCode]::Int16, [TypeCode]::UInt16, [TypeCode]::Int32, [TypeCode]::UInt32, [TypeCode]::Int64, [TypeCode]::UInt64) -or
        [int64]$process.ProcessId -ne $requestedProcessId -or $name -isnot [string] -or
        [string]::IsNullOrWhiteSpace($name) -or $name.Trim() -cne $name -or
        $name -cmatch '[\\/:]' -or $name.ToLowerInvariant() -cnotmatch '^[a-z0-9][a-z0-9._-]{0,123}\.exe$' -or
        $creationDate -isnot [string] -or $creationDate -cnotmatch '^\d{14}\.\d{6}[+-]\d{3}$') {
        return [ordered]@{ Status = 'cim_query_failed'; RequestedProcessId = $requestedProcessId; Process = $null }
    }
    return [ordered]@{
        Status = 'ok'
        RequestedProcessId = $requestedProcessId
        Process = [ordered]@{
            ProcessId = [int64]$process.ProcessId
            ParentProcessId = [int64]$process.ParentProcessId
            Name = $name.ToLowerInvariant()
            CreationDate = $creationDate
        }
    }
}

function Test-TeremoqIntegralScalar {
    param([Parameter(Mandatory = $true)]$Value)
    if ($Value -is [bool] -or $Value -isnot [ValueType]) { return $false }
    return [Type]::GetTypeCode($Value.GetType()) -in @(
        [TypeCode]::Byte, [TypeCode]::SByte, [TypeCode]::Int16, [TypeCode]::UInt16,
        [TypeCode]::Int32, [TypeCode]::UInt32, [TypeCode]::Int64, [TypeCode]::UInt64
    )
}

function Convert-TeremoqDmtfUtc {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value -cnotmatch '^\d{14}\.\d{6}[+-]\d{3}$') { return $null }
    try {
        return [System.Management.ManagementDateTimeConverter]::ToDateTime($Value).ToUniversalTime()
    } catch {
        return $null
    }
}

function Get-TeremoqValidatedProcessIdentity {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][int64]$ExpectedProcessId
    )
    $allowedStatuses = @('ok', 'cim_query_failed', 'process_missing')
    if ($Result -isnot [System.Collections.IDictionary] -or
        @($Result.Keys).Count -ne 3 -or
        @($Result.Keys | Where-Object { @('Status', 'RequestedProcessId', 'Process') -notcontains $_ }).Count -ne 0 -or
        $Result.Status -isnot [string] -or $Result.Status -notin $allowedStatuses -or
        -not (Test-TeremoqIntegralScalar -Value $Result.RequestedProcessId) -or
        [int64]$Result.RequestedProcessId -ne $ExpectedProcessId) {
        return [ordered]@{ Outcome = 'cim_query_failed'; Identity = $null }
    }
    if ($Result.Status -eq 'cim_query_failed') {
        if ($null -ne $Result.Process) { return [ordered]@{ Outcome = 'cim_query_failed'; Identity = $null } }
        return [ordered]@{ Outcome = 'cim_query_failed'; Identity = $null }
    }
    if ($Result.Status -eq 'process_missing') {
        if ($null -ne $Result.Process) { return [ordered]@{ Outcome = 'cim_query_failed'; Identity = $null } }
        return [ordered]@{ Outcome = 'process_missing'; Identity = $null }
    }
    if ($null -eq $Result.Process -or $Result.Process -isnot [System.Collections.IDictionary] -or
        @($Result.Process.Keys).Count -ne 4 -or
        @($Result.Process.Keys | Where-Object { @('ProcessId', 'ParentProcessId', 'Name', 'CreationDate') -notcontains $_ }).Count -ne 0 -or
        -not (Test-TeremoqIntegralScalar -Value $Result.Process.ProcessId) -or
        -not (Test-TeremoqIntegralScalar -Value $Result.Process.ParentProcessId) -or
        [int64]$Result.Process.ProcessId -ne $ExpectedProcessId -or
        $Result.Process.Name -isnot [string] -or $Result.Process.Name -cnotmatch '^[a-z0-9][a-z0-9._-]{0,123}\.exe$' -or
        $Result.Process.CreationDate -isnot [string]) {
        return [ordered]@{ Outcome = 'cim_query_failed'; Identity = $null }
    }
    $creationUtc = Convert-TeremoqDmtfUtc -Value $Result.Process.CreationDate
    if ($null -eq $creationUtc) {
        return [ordered]@{ Outcome = 'cim_query_failed'; Identity = $null }
    }
    return [ordered]@{
        Outcome = 'ok'
        Identity = [ordered]@{
            ProcessId = [int64]$Result.Process.ProcessId
            ParentProcessId = [int64]$Result.Process.ParentProcessId
            Name = [string]$Result.Process.Name
            CreationDate = [string]$Result.Process.CreationDate
            CreationDateUtc = $creationUtc
        }
    }
}

function Resolve-TeremoqStableProcessIdentity {
    param(
        [Parameter(Mandatory = $true)][int64]$ProcessId,
        [Parameter(Mandatory = $true)]$InitialResult,
        [Parameter(Mandatory = $true)][scriptblock]$ResolveProcess,
        [Parameter(Mandatory = $true)][string]$MissingOutcome,
        [Parameter(Mandatory = $true)][string]$UnstableOutcome
    )
    $initial = Get-TeremoqValidatedProcessIdentity -Result $InitialResult -ExpectedProcessId $ProcessId
    if ($initial.Outcome -eq 'process_missing') {
        return [ordered]@{ Outcome = $MissingOutcome; Identity = $null }
    }
    if ($initial.Outcome -ne 'ok') {
        return [ordered]@{ Outcome = 'cim_query_failed'; Identity = $null }
    }
    $requery = Get-TeremoqValidatedProcessIdentity -Result (& $ResolveProcess $ProcessId) -ExpectedProcessId $ProcessId
    if ($requery.Outcome -ne 'ok') {
        return [ordered]@{ Outcome = $UnstableOutcome; Identity = $null }
    }
    $left = $initial.Identity
    $right = $requery.Identity
    if ($left.ProcessId -ne $right.ProcessId -or
        $left.ParentProcessId -ne $right.ParentProcessId -or
        $left.Name -cne $right.Name -or
        $left.CreationDate -cne $right.CreationDate -or
        $left.CreationDateUtc -ne $right.CreationDateUtc) {
        return [ordered]@{ Outcome = $UnstableOutcome; Identity = $null }
    }
    return [ordered]@{ Outcome = 'ok'; Identity = $left }
}

function Test-TeremoqTrustedExplorerRootTermination {
    param(
        [Parameter(Mandatory = $true)][string]$CurrentProcessName,
        [Parameter(Mandatory = $true)][string]$PowerShellEdition,
        [string[]]$ParentProcessNames = @(),
        [string[]]$ObservedEnvKeys = @()
    )
    return $CurrentProcessName -ceq 'powershell.exe' -and
        $PowerShellEdition -ceq 'Desktop' -and
        $ParentProcessNames.Count -eq 1 -and
        $ParentProcessNames[0] -ceq 'explorer.exe' -and
        $ObservedEnvKeys.Count -eq 0
}

function New-TeremoqCaptureContext {
    param(
        [Parameter(Mandatory = $true)][int]$CurrentProcessId,
        [Parameter(Mandatory = $true)]$CurrentResult,
        [Parameter(Mandatory = $true)][scriptblock]$ResolveProcess,
        [Parameter()][int]$DepthLimit = 16,
        [Parameter()]$ObservedEnvKeys = $null
    )
    if ($DepthLimit -lt 8 -or $DepthLimit -gt 32) { throw 'capture context depth limit is outside 8..32' }
    $allowedEnvKeys = @('WSLENV', 'WSL_INTEROP', 'WSL_DISTRO_NAME')
    $presentEnvKeys = if ($null -ne $ObservedEnvKeys) {
        @($ObservedEnvKeys)
    } else {
        @($allowedEnvKeys | Where-Object { -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($_)) })
    }
    $currentProcessName = 'unavailable'
    $parentNames = New-Object System.Collections.Generic.List[string]
    $traversalOutcome = 'current_process_query_failed'
    $seen = New-Object 'System.Collections.Generic.Dictionary[long,string]'
    $resolvedCurrent = Resolve-TeremoqStableProcessIdentity -ProcessId ([int64]$CurrentProcessId) -InitialResult $CurrentResult -ResolveProcess $ResolveProcess -MissingOutcome 'current_process_missing' -UnstableOutcome 'current_process_unstable'
    if ($resolvedCurrent.Outcome -eq 'ok') {
        $walker = $resolvedCurrent.Identity
        $currentProcessName = [string]$walker.Name
        $seen[[int64]$walker.ProcessId] = [string]$walker.CreationDate
        $traversalOutcome = 'depth_limit_reached'
        for ($depth = 0; $depth -lt $DepthLimit; $depth += 1) {
            $parentId = [int64]$walker.ParentProcessId
            if ($parentId -le 0) {
                $traversalOutcome = 'terminated_parent_pid_nonpositive'
                break
            }
            $parentFirstResult = & $ResolveProcess $parentId
            $resolvedParent = Resolve-TeremoqStableProcessIdentity -ProcessId $parentId -InitialResult $parentFirstResult -ResolveProcess $ResolveProcess -MissingOutcome 'parent_process_missing' -UnstableOutcome 'parent_process_unstable'
            if ($resolvedParent.Outcome -ne 'ok') {
                if ($resolvedParent.Outcome -eq 'parent_process_missing' -and
                    (Test-TeremoqTrustedExplorerRootTermination -CurrentProcessName $currentProcessName -PowerShellEdition ([string]$PSVersionTable.PSEdition) -ParentProcessNames @($parentNames) -ObservedEnvKeys @($presentEnvKeys))) {
                    $traversalOutcome = 'terminated_after_explorer_root_missing'
                } else {
                    $traversalOutcome = [string]$resolvedParent.Outcome
                }
                break
            }
            $parentIdentity = $resolvedParent.Identity
            if ($parentIdentity.CreationDateUtc -gt $walker.CreationDateUtc) {
                $traversalOutcome = 'parent_process_newer_than_child'
                break
            }
            $parentCreationDate = [string]$parentIdentity.CreationDate
            if ($seen.ContainsKey($parentId)) {
                $traversalOutcome = 'cycle_or_pid_reuse_detected'
                break
            }
            $seen[$parentId] = $parentCreationDate
            $parentName = [string]$parentIdentity.Name
            $parentNames.Add($parentName)
            $walker = $parentIdentity
        }
    } else {
        $traversalOutcome = [string]$resolvedCurrent.Outcome
    }
    return [ordered]@{
        schema_version = 2
        current_process_name = $currentProcessName
        parent_process_names = @($parentNames)
        parent_process_count = $parentNames.Count
        traversal_depth_limit = $DepthLimit
        traversal_outcome = $traversalOutcome
        wsl_environment_keys_present = @($presentEnvKeys)
        powershell_edition = [string]$PSVersionTable.PSEdition
        powershell_version_major = [int]$PSVersionTable.PSVersion.Major
    }
}

function Get-TeremoqCaptureContext {
    $currentResult = Get-TeremoqProcessQueryResult -ProcessId $PID
    return New-TeremoqCaptureContext -CurrentProcessId $PID -CurrentResult $currentResult -ResolveProcess {
        param($ProcessId)
        Get-TeremoqProcessQueryResult -ProcessId $ProcessId
    }
}

function Test-TeremoqCaptureContextEvidence {
    param([Parameter(Mandatory = $true)]$Context)
    if ($Context -isnot [System.Collections.IDictionary]) { return $false }
    $keys = @($Context.Keys)
    if ($keys.Count -ne 9 -or @($keys | Where-Object { @('schema_version', 'current_process_name', 'parent_process_names', 'parent_process_count', 'traversal_depth_limit', 'traversal_outcome', 'wsl_environment_keys_present', 'powershell_edition', 'powershell_version_major') -notcontains $_ }).Count -ne 0) {
        return $false
    }
    if ($Context.schema_version -is [bool] -or $Context.schema_version -isnot [ValueType] -or
        [Type]::GetTypeCode($Context.schema_version.GetType()) -notin @([TypeCode]::Byte, [TypeCode]::SByte, [TypeCode]::Int16, [TypeCode]::UInt16, [TypeCode]::Int32, [TypeCode]::UInt32, [TypeCode]::Int64, [TypeCode]::UInt64) -or
        [int64]$Context.schema_version -ne 2 -or $Context.current_process_name -isnot [string] -or
        $Context.current_process_name -notin @('powershell.exe', 'pwsh.exe') -or $Context.current_process_name -cnotmatch '^[a-z0-9][a-z0-9._-]{0,123}\.exe$' -or
        $Context.parent_process_names -isnot [System.Array] -or $Context.parent_process_names.Count -lt 1 -or $Context.parent_process_names.Count -gt 16 -or
        $Context.parent_process_count -is [bool] -or $Context.parent_process_count -isnot [ValueType] -or
        [Type]::GetTypeCode($Context.parent_process_count.GetType()) -notin @([TypeCode]::Byte, [TypeCode]::SByte, [TypeCode]::Int16, [TypeCode]::UInt16, [TypeCode]::Int32, [TypeCode]::UInt32, [TypeCode]::Int64, [TypeCode]::UInt64) -or
        [int64]$Context.parent_process_count -ne $Context.parent_process_names.Count -or
        $Context.traversal_depth_limit -is [bool] -or $Context.traversal_depth_limit -isnot [ValueType] -or
        [Type]::GetTypeCode($Context.traversal_depth_limit.GetType()) -notin @([TypeCode]::Byte, [TypeCode]::SByte, [TypeCode]::Int16, [TypeCode]::UInt16, [TypeCode]::Int32, [TypeCode]::UInt32, [TypeCode]::Int64, [TypeCode]::UInt64) -or
        [int64]$Context.traversal_depth_limit -ne 16 -or
        $Context.traversal_outcome -isnot [string] -or $Context.traversal_outcome -notin @('terminated_parent_pid_nonpositive', 'terminated_after_explorer_root_missing') -or
        $Context.wsl_environment_keys_present -isnot [System.Array] -or $Context.wsl_environment_keys_present.Count -gt 3 -or
        $Context.powershell_edition -isnot [string] -or $Context.powershell_edition -notin @('Desktop', 'Core') -or
        $Context.powershell_version_major -is [bool] -or $Context.powershell_version_major -isnot [ValueType] -or
        [Type]::GetTypeCode($Context.powershell_version_major.GetType()) -notin @([TypeCode]::Byte, [TypeCode]::SByte, [TypeCode]::Int16, [TypeCode]::UInt16, [TypeCode]::Int32, [TypeCode]::UInt32, [TypeCode]::Int64, [TypeCode]::UInt64) -or
        [int64]$Context.powershell_version_major -lt 5 -or [int64]$Context.powershell_version_major -gt 9) {
        return $false
    }
    $allowedEnvKeys = @('WSLENV', 'WSL_INTEROP', 'WSL_DISTRO_NAME')
    $blockedAncestorNames = @('bash.exe', 'sh.exe', 'dash.exe', 'wsl.exe', 'wslhost.exe', 'ubuntu.exe', 'debian.exe', 'kali.exe', 'arch.exe')
    $normalizedParents = @()
    foreach ($name in $Context.parent_process_names) {
        if ($name -isnot [string] -or $name.Length -gt 128 -or $name.Trim() -cne $name -or $name -cnotmatch '^[a-z0-9][a-z0-9._-]{0,123}\.exe$') { return $false }
        if ($normalizedParents -contains $name) { return $false }
        $normalizedParents += $name
    }
    foreach ($key in $Context.wsl_environment_keys_present) {
        if ($key -isnot [string] -or $key -notin $allowedEnvKeys) { return $false }
    }
    if (@($Context.wsl_environment_keys_present | Select-Object -Unique).Count -ne $Context.wsl_environment_keys_present.Count) { return $false }
    if ($Context.traversal_outcome -ceq 'terminated_after_explorer_root_missing' -and
        -not (Test-TeremoqTrustedExplorerRootTermination -CurrentProcessName $Context.current_process_name -PowerShellEdition $Context.powershell_edition -ParentProcessNames $normalizedParents -ObservedEnvKeys $Context.wsl_environment_keys_present)) {
        return $false
    }
    return @($normalizedParents | Where-Object { $_ -in $blockedAncestorNames }).Count -eq 0 -and $Context.wsl_environment_keys_present.Count -eq 0
}
