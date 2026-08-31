# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ScriptPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. $ScriptPath

$english = @"
Name                   : Wi-Fi
Radio type             : 802.11ac
Band                   : 5 GHz
"@
$spanish = @"
Nombre                 : Wi-Fi
Tipo de radio          : 802.11ac
Banda                  : 5 GHz
"@
$fallback = @"
Name                   : Wi-Fi
Radio type             : 802.11ac
"@

$obs = Get-TeremoqWlanObservation -Text $english -AdapterName 'Wi-Fi'
if (-not $obs.Is5GHz -or $obs.Band -ne '5 GHz' -or $obs.Radio -ne '802.11ac') { throw 'English WLAN parsing failed' }
$obs = Get-TeremoqWlanObservation -Text $spanish -AdapterName 'Wi-Fi'
if (-not $obs.Is5GHz -or $obs.Band -ne '5 GHz' -or $obs.Radio -ne '802.11ac') { throw 'Spanish WLAN parsing failed' }
$obs = Get-TeremoqWlanObservation -Text $fallback -AdapterName 'Wi-Fi'
if (-not $obs.Is5GHz -or $obs.Band -ne 'unavailable' -or $obs.Radio -ne '802.11ac') { throw 'WLAN radio fallback failed' }

$englishOffset = Convert-TeremoqPhaseOffsetMilliseconds -Text "Phase Offset: -0.0000790s"
if ($null -eq $englishOffset -or (Format-TeremoqInvariantDecimal -Value $englishOffset) -ne '-0.079') { throw 'English clock parsing failed' }
$spanishOffset = Convert-TeremoqPhaseOffsetMilliseconds -Text "Desplazamiento de fase: 0,0000790s"
if ($null -eq $spanishOffset -or (Format-TeremoqInvariantDecimal -Value $spanishOffset) -ne '0.079') { throw 'Spanish clock parsing failed' }
$spanishAltOffset = Convert-TeremoqPhaseOffsetMilliseconds -Text "Desfase de fase: -0,001000s"
if ($null -eq $spanishAltOffset -or (Format-TeremoqInvariantDecimal -Value $spanishAltOffset) -ne '-1') { throw 'Alternate Spanish clock parsing failed' }

$internalOnly = @(Get-TeremoqDockerPublicationConflicts -Rows @("tramiteplus-redis-1`t6379/tcp"))
if ($internalOnly.Count -ne 0) { throw 'internal-only EXPOSE was treated as a host publication' }
$loopback = @(Get-TeremoqDockerPublicationConflicts -Rows @("tramiteplus-redis-1`t127.0.0.1:6379->6379/tcp"))
if ($loopback.Count -ne 1 -or $loopback[0] -ne 'service=tramiteplus-redis-1;port=6379/tcp') { throw 'loopback publication parsing failed' }
$ipv6 = @(Get-TeremoqDockerPublicationConflicts -Rows @("legacy-ollama`t[::]:11434->11434/tcp"))
if ($ipv6.Count -ne 1 -or $ipv6[0] -ne 'service=legacy-ollama;port=11434/tcp') { throw 'IPv6 publication parsing failed' }
$wildcard = @(Get-TeremoqDockerPublicationConflicts -Rows @("legacy-relay`t0.0.0.0:4433->4433/udp"))
if ($wildcard.Count -ne 1 -or $wildcard[0] -ne 'service=legacy-relay;port=4433/udp') { throw 'wildcard publication parsing failed' }
try {
    Get-TeremoqDockerPublicationConflicts -Rows @("bad`t0.0.0.0:6379-6380->6379/tcp") > $null
    throw 'malformed publication token was accepted'
} catch {
    if ($_.Exception.Message -notmatch 'malformed') { throw }
}

Write-Output 'Teremoq LAN PowerShell contract helpers passed EN/ES, Docker and clock parser regressions.'
