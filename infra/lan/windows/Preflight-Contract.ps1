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
            $current = [ordered]@{ Name = $Matches[2].Trim(); Band = 'unavailable'; Radio = 'unavailable' }
            continue
        }
        if ($null -eq $current) { continue }
        if ($line -match '(?im)^\s*(Band|Banda)\s*:\s*([^\r\n]+)\s*$') {
            $current.Band = $Matches[2].Trim()
            continue
        }
        if ($line -match '(?im)^\s*(Radio type|Tipo de radio)\s*:\s*([^\r\n]+)\s*$') {
            $current.Radio = $Matches[2].Trim()
        }
    }
    if ($null -ne $current) { $blocks.Add([pscustomobject]$current) }
    $matches = @($blocks | Where-Object { $_.Name -ceq $AdapterName })
    if ($matches.Count -ne 1) {
        return [pscustomobject]@{ Band = 'unavailable'; Radio = 'unavailable'; Is5GHz = $false }
    }
    $band = [string]$matches[0].Band
    $radio = [string]$matches[0].Radio
    $is5GHz = $false
    if ($band -match '(?i)\b5\s*GHz\b') { $is5GHz = $true }
    elseif ($band -eq 'unavailable' -and $radio -match '(?i)\b802\.11(a|ac)\b') { $is5GHz = $true }
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
            $conflict = "$containerPort/$($Matches['protocol'])"
            if ($conflict -notin @('4433/tcp', '5678/tcp', '6379/tcp', '11434/tcp', '4433/udp', '9000/udp', '14433/udp', '19000/udp')) {
                continue
            }
            $record = "service=$service;port=$conflict"
            if ($seen.Add($record)) { $conflicts.Add($record) }
        }
    }
    return @($conflicts)
}
