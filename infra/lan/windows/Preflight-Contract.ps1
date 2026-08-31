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
                $current.Band = $Matches[2].Trim()
            }
            continue
        }
        if ($line -match '(?im)^\s*(Radio type|Tipo de radio)\s*:\s*([^\r\n]+)\s*$') {
            $current.RadioCount += 1
            if ($current.RadioCount -gt 1) {
                $current.Ambiguous = $true
            } else {
                $current.Radio = $Matches[2].Trim()
            }
        }
    }
    if ($null -ne $current) { $blocks.Add([pscustomobject]$current) }
    $matches = @($blocks | Where-Object { $_.Name -ceq $AdapterName })
    if ($matches.Count -ne 1 -or $matches[0].Ambiguous) {
        return [pscustomobject]@{ Band = 'unavailable'; Radio = 'unavailable'; Is5GHz = $false }
    }
    $band = [string]$matches[0].Band
    $radio = [string]$matches[0].Radio
    $is5GHz = $false
    if ($band -match '(?i)\b5\s*GHz\b') { $is5GHz = $true }
    elseif ($matches[0].BandCount -eq 0 -and $matches[0].RadioCount -eq 1 -and $radio -match '(?i)\b802\.11(a|ac)\b') { $is5GHz = $true }
    return [pscustomobject]@{ Band = $band; Radio = $radio; Is5GHz = $is5GHz }
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

function Get-TeremoqCaptureContext {
    $allowedEnvKeys = @('WSLENV', 'WSL_INTEROP', 'WSL_DISTRO_NAME')
    $blockedAncestorNames = @('bash.exe', 'sh.exe', 'dash.exe', 'wsl.exe', 'wslhost.exe', 'ubuntu.exe', 'debian.exe', 'kali.exe', 'arch.exe')
    $current = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue
    $currentProcessName = if ($current) { [string]$current.Name } else { 'unavailable' }
    $parentNames = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[int]'
    $walker = $current
    for ($depth = 0; $depth -lt 8 -and $null -ne $walker; $depth += 1) {
        $parentId = [int]$walker.ParentProcessId
        if ($parentId -le 0 -or -not $seen.Add($parentId)) { break }
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$parentId" -ErrorAction SilentlyContinue
        if ($null -eq $parent -or [string]::IsNullOrWhiteSpace([string]$parent.Name)) { break }
        $parentNames.Add(([string]$parent.Name).ToLowerInvariant())
        $walker = $parent
    }
    $presentEnvKeys = @($allowedEnvKeys | Where-Object { -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($_)) })
    return [ordered]@{
        schema_version = 1
        current_process_name = $currentProcessName.ToLowerInvariant()
        parent_process_names = @($parentNames)
        wsl_environment_keys_present = @($presentEnvKeys)
        powershell_edition = [string]$PSVersionTable.PSEdition
        powershell_version_major = [int]$PSVersionTable.PSVersion.Major
    }
}

function Test-TeremoqCaptureContextEvidence {
    param([Parameter(Mandatory = $true)]$Context)
    if ($Context -isnot [System.Collections.IDictionary]) { return $false }
    $keys = @($Context.Keys)
    if ($keys.Count -ne 6 -or @($keys | Where-Object { @('schema_version', 'current_process_name', 'parent_process_names', 'wsl_environment_keys_present', 'powershell_edition', 'powershell_version_major') -notcontains $_ }).Count -ne 0) {
        return $false
    }
    if ($Context.schema_version -ne 1 -or $Context.current_process_name -isnot [string] -or
        $Context.current_process_name -notin @('powershell.exe', 'pwsh.exe') -or
        $Context.parent_process_names -isnot [System.Array] -or $Context.parent_process_names.Count -lt 1 -or $Context.parent_process_names.Count -gt 8 -or
        $Context.wsl_environment_keys_present -isnot [System.Array] -or $Context.wsl_environment_keys_present.Count -gt 3 -or
        $Context.powershell_edition -isnot [string] -or $Context.powershell_edition -notin @('Desktop', 'Core') -or
        $Context.powershell_version_major -isnot [int] -or $Context.powershell_version_major -lt 5 -or $Context.powershell_version_major -gt 9) {
        return $false
    }
    $allowedEnvKeys = @('WSLENV', 'WSL_INTEROP', 'WSL_DISTRO_NAME')
    $blockedAncestorNames = @('bash.exe', 'sh.exe', 'dash.exe', 'wsl.exe', 'wslhost.exe', 'ubuntu.exe', 'debian.exe', 'kali.exe', 'arch.exe')
    $normalizedParents = @()
    foreach ($name in $Context.parent_process_names) {
        if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 128) { return $false }
        $normalized = $name.ToLowerInvariant()
        if ($normalizedParents -contains $normalized) { return $false }
        $normalizedParents += $normalized
    }
    foreach ($key in $Context.wsl_environment_keys_present) {
        if ($key -isnot [string] -or $key -notin $allowedEnvKeys) { return $false }
    }
    if (@($Context.wsl_environment_keys_present | Select-Object -Unique).Count -ne $Context.wsl_environment_keys_present.Count) { return $false }
    return @($normalizedParents | Where-Object { $_ -in $blockedAncestorNames }).Count -eq 0 -and $Context.wsl_environment_keys_present.Count -eq 0
}
