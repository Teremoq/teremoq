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
$duplicateBand = @"
Name                   : Wi-Fi
Radio type             : 802.11ac
Band                   : 2.4 GHz
Band                   : 5 GHz
"@
$duplicateSpanishRadio = @"
Nombre                 : Wi-Fi
Tipo de radio          : 802.11ac
Tipo de radio          : 802.11a
"@
$bandWithoutFallback = @"
Name                   : Wi-Fi
Radio type             : 802.11ac
Band                   : 2.4 GHz
"@
$duplicateBlock = @"
Name                   : Wi-Fi
Band                   : 5 GHz
Name                   : Wi-Fi
Band                   : 5 GHz
"@

$obs = Get-TeremoqWlanObservation -Text $english -AdapterName 'Wi-Fi'
if (-not $obs.Is5GHz -or $obs.Band -ne '5 GHz' -or $obs.Radio -ne '802.11ac') { throw 'English WLAN parsing failed' }
$obs = Get-TeremoqWlanObservation -Text $spanish -AdapterName 'Wi-Fi'
if (-not $obs.Is5GHz -or $obs.Band -ne '5 GHz' -or $obs.Radio -ne '802.11ac') { throw 'Spanish WLAN parsing failed' }
$obs = Get-TeremoqWlanObservation -Text $fallback -AdapterName 'Wi-Fi'
if (-not $obs.Is5GHz -or $obs.Band -ne 'unavailable' -or $obs.Radio -ne '802.11ac') { throw 'WLAN radio fallback failed' }
$obs = Get-TeremoqWlanObservation -Text $duplicateBand -AdapterName 'Wi-Fi'
if ($obs.Is5GHz -or $obs.Band -ne 'unavailable' -or $obs.Radio -ne 'unavailable') { throw 'duplicate Band field was not rejected' }
$obs = Get-TeremoqWlanObservation -Text $duplicateSpanishRadio -AdapterName 'Wi-Fi'
if ($obs.Is5GHz -or $obs.Band -ne 'unavailable' -or $obs.Radio -ne 'unavailable') { throw 'duplicate radio field was not rejected' }
$obs = Get-TeremoqWlanObservation -Text $bandWithoutFallback -AdapterName 'Wi-Fi'
if ($obs.Is5GHz -or $obs.Band -ne '2.4 GHz') { throw 'radio fallback overrode a present non-5 GHz band' }
$obs = Get-TeremoqWlanObservation -Text $duplicateBlock -AdapterName 'Wi-Fi'
if ($obs.Is5GHz -or $obs.Band -ne 'unavailable' -or $obs.Radio -ne 'unavailable') { throw 'duplicate adapter block was not rejected' }

$englishOffset = Convert-TeremoqPhaseOffsetMilliseconds -Text "Phase Offset: -0.0000790s"
if ($null -eq $englishOffset -or (Format-TeremoqInvariantDecimal -Value $englishOffset) -ne '-0.079') { throw 'English clock parsing failed' }
$spanishOffset = Convert-TeremoqPhaseOffsetMilliseconds -Text "Desplazamiento de fase: 0,0000790s"
if ($null -eq $spanishOffset -or (Format-TeremoqInvariantDecimal -Value $spanishOffset) -ne '0.079') { throw 'Spanish clock parsing failed' }
$spanishAltOffset = Convert-TeremoqPhaseOffsetMilliseconds -Text "Desfase de fase: -0,001000s"
if ($null -eq $spanishAltOffset -or (Format-TeremoqInvariantDecimal -Value $spanishAltOffset) -ne '-1') { throw 'Alternate Spanish clock parsing failed' }

$internalOnly = @(Get-TeremoqDockerPublicationConflicts -Rows @("tramiteplus-redis-1`t6379/tcp"))
if ($internalOnly.Count -ne 0) { throw 'internal-only EXPOSE was treated as a host publication' }
$crossHostReserved = @(Get-TeremoqDockerPublicationConflicts -Rows @("cross-host`t0.0.0.0:4433->50000/udp"))
if ($crossHostReserved.Count -ne 1 -or $crossHostReserved[0] -ne 'service=cross-host;port=4433/udp') { throw 'host-port conflict was not detected' }
$crossContainerReserved = @(Get-TeremoqDockerPublicationConflicts -Rows @("cross-container`t0.0.0.0:50000->4433/udp"))
if ($crossContainerReserved.Count -ne 0) { throw 'safe host port inherited a false conflict from the container port' }
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
try {
    $rows = @()
    for ($i = 0; $i -lt 129; $i += 1) { $rows += "service$i`t50000/tcp" }
    Get-TeremoqDockerPublicationConflicts -Rows $rows > $null
    throw 'Docker publication cardinality limit was not enforced'
} catch {
    if ($_.Exception.Message -notmatch '128') { throw }
}

$nativeContext = [ordered]@{
    schema_version = 1
    current_process_name = 'powershell.exe'
    parent_process_names = @('windowsterminal.exe', 'explorer.exe')
    wsl_environment_keys_present = @()
    powershell_edition = 'Desktop'
    powershell_version_major = 5
}
if (-not (Test-TeremoqCaptureContextEvidence -Context $nativeContext)) { throw 'native capture context was rejected' }
$interopContext = [ordered]@{
    schema_version = 1
    current_process_name = 'powershell.exe'
    parent_process_names = @('wslhost.exe', 'bash.exe')
    wsl_environment_keys_present = @('WSL_INTEROP')
    powershell_edition = 'Desktop'
    powershell_version_major = 5
}
if (Test-TeremoqCaptureContextEvidence -Context $interopContext) { throw 'WSL interop capture context was accepted' }

Write-Output 'Teremoq LAN PowerShell contract helpers passed EN/ES, Docker and clock parser regressions.'
