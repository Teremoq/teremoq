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
$englishLowercase = @"
Name                   : Wi-Fi
Radio type             : 802.11ac
Band                   : 5 ghz
"@
$englishExtraWhitespace = @"
Name                   : Wi-Fi
Radio type             : 802.11ac
Band                   : 5     GHz
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
$combinedBand = @"
Name                   : Wi-Fi
Radio type             : 802.11ac
Band                   : 2.4 GHz / 5 GHz
"@
$combinedBandSpanish = @"
Nombre                 : Wi-Fi
Tipo de radio          : 802.11ac
Banda                  : 2.4 GHz / 5 GHz
"@
$negatedBand = @"
Name                   : Wi-Fi
Radio type             : 802.11ac
Band                   : not 5 GHz
"@
$unknownBandSpanish = @"
Nombre                 : Wi-Fi
Tipo de radio          : 802.11ac
Banda                  : desconocida
"@
$duplicateBlock = @"
Name                   : Wi-Fi
Band                   : 5 GHz
Name                   : Wi-Fi
Band                   : 5 GHz
"@

$obs = Get-TeremoqWlanObservation -Text $english -AdapterName 'Wi-Fi'
if (-not $obs.IsCanonical5GHz -or $obs.Band -ne '5 GHz' -or $obs.Radio -ne '802.11ac' -or $obs.FallbackRadioQualified) { throw 'English WLAN parsing failed' }
$obs = Get-TeremoqWlanObservation -Text $englishLowercase -AdapterName 'Wi-Fi'
if ($obs.IsCanonical5GHz -or $obs.Band -ne '5 ghz') { throw 'lowercase Band value was accepted' }
$obs = Get-TeremoqWlanObservation -Text $englishExtraWhitespace -AdapterName 'Wi-Fi'
if ($obs.IsCanonical5GHz -or $obs.Band -ne '5     GHz') { throw 'Band with internal extra whitespace was accepted' }
$obs = Get-TeremoqWlanObservation -Text $spanish -AdapterName 'Wi-Fi'
if (-not $obs.IsCanonical5GHz -or $obs.Band -ne '5 GHz' -or $obs.Radio -ne '802.11ac' -or $obs.FallbackRadioQualified) { throw 'Spanish WLAN parsing failed' }
$obs = Get-TeremoqWlanObservation -Text $fallback -AdapterName 'Wi-Fi'
if ($obs.IsCanonical5GHz -or -not $obs.FallbackRadioQualified -or $obs.Band -ne 'unavailable' -or $obs.Radio -ne '802.11ac') { throw 'WLAN radio fallback classification failed' }
$obs = Get-TeremoqWlanObservation -Text $duplicateBand -AdapterName 'Wi-Fi'
if ($obs.IsCanonical5GHz -or $obs.FallbackRadioQualified -or $obs.Band -ne 'unavailable' -or $obs.Radio -ne 'unavailable') { throw 'duplicate Band field was not rejected' }
$obs = Get-TeremoqWlanObservation -Text $duplicateSpanishRadio -AdapterName 'Wi-Fi'
if ($obs.IsCanonical5GHz -or $obs.FallbackRadioQualified -or $obs.Band -ne 'unavailable' -or $obs.Radio -ne 'unavailable') { throw 'duplicate radio field was not rejected' }
$obs = Get-TeremoqWlanObservation -Text $bandWithoutFallback -AdapterName 'Wi-Fi'
if ($obs.IsCanonical5GHz -or $obs.FallbackRadioQualified -or $obs.Band -ne '2.4 GHz') { throw 'radio fallback overrode a present non-5 GHz band' }
$obs = Get-TeremoqWlanObservation -Text $combinedBand -AdapterName 'Wi-Fi'
if ($obs.IsCanonical5GHz -or $obs.FallbackRadioQualified -or $obs.Band -ne '2.4 GHz / 5 GHz') { throw 'combined English band value was accepted' }
$obs = Get-TeremoqWlanObservation -Text $combinedBandSpanish -AdapterName 'Wi-Fi'
if ($obs.IsCanonical5GHz -or $obs.FallbackRadioQualified -or $obs.Band -ne '2.4 GHz / 5 GHz') { throw 'combined Spanish band value was accepted' }
$obs = Get-TeremoqWlanObservation -Text $negatedBand -AdapterName 'Wi-Fi'
if ($obs.IsCanonical5GHz -or $obs.FallbackRadioQualified -or $obs.Band -ne 'not 5 GHz') { throw 'negated English band value was accepted' }
$obs = Get-TeremoqWlanObservation -Text $unknownBandSpanish -AdapterName 'Wi-Fi'
if ($obs.IsCanonical5GHz -or $obs.FallbackRadioQualified -or $obs.Band -ne 'desconocida') { throw 'unknown Spanish band value was accepted' }
$obs = Get-TeremoqWlanObservation -Text $duplicateBlock -AdapterName 'Wi-Fi'
if ($obs.IsCanonical5GHz -or $obs.FallbackRadioQualified -or $obs.Band -ne 'unavailable' -or $obs.Radio -ne 'unavailable') { throw 'duplicate adapter block was not rejected' }

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

function New-TeremoqMockProcess {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$ParentProcessId,
        [Parameter()][string]$CreationDate = '20260831100000.000000+120'
    )
    return [ordered]@{
        ProcessId = $ProcessId
        Name = $Name
        ParentProcessId = $ParentProcessId
        CreationDate = $CreationDate
    }
}

$nativeRecords = @{
    101 = (New-TeremoqMockProcess -ProcessId 101 -Name 'powershell.exe' -ParentProcessId 100)
    100 = (New-TeremoqMockProcess -ProcessId 100 -Name 'windowsterminal.exe' -ParentProcessId 99)
    99 = (New-TeremoqMockProcess -ProcessId 99 -Name 'explorer.exe' -ParentProcessId 0)
}
$nativeContext = New-TeremoqCaptureContext -CurrentProcessId 101 -CurrentResult ([ordered]@{ Status = 'ok'; RequestedProcessId = [int64]101; Process = $nativeRecords[101] }) -ResolveProcess ({
    param($ProcessId)
    if ($nativeRecords.ContainsKey([int]$ProcessId)) {
        return ([ordered]@{ Status = 'ok'; RequestedProcessId = [int64][int]$ProcessId; Process = $nativeRecords[[int]$ProcessId] })
    }
    return ([ordered]@{ Status = 'process_missing'; RequestedProcessId = [int64][int]$ProcessId; Process = $null })
}.GetNewClosure()) -ObservedEnvKeys @()
if (-not (Test-TeremoqCaptureContextEvidence -Context $nativeContext)) { throw 'native capture context was rejected' }
if ($nativeContext.traversal_outcome -ne 'terminated_parent_pid_nonpositive' -or $nativeContext.parent_process_count -ne 2) {
    throw 'native capture context did not prove termination'
}
$missingParentRecords = @{
    201 = (New-TeremoqMockProcess -ProcessId 201 -Name 'powershell.exe' -ParentProcessId 200)
    200 = (New-TeremoqMockProcess -ProcessId 200 -Name 'windowsterminal.exe' -ParentProcessId 199)
}
$missingParentContext = New-TeremoqCaptureContext -CurrentProcessId 201 -CurrentResult ([ordered]@{ Status = 'ok'; RequestedProcessId = [int64]201; Process = $missingParentRecords[201] }) -ResolveProcess ({
    param($ProcessId)
    if ($missingParentRecords.ContainsKey([int]$ProcessId)) {
        return ([ordered]@{ Status = 'ok'; RequestedProcessId = [int64][int]$ProcessId; Process = $missingParentRecords[[int]$ProcessId] })
    }
    return ([ordered]@{ Status = 'process_missing'; RequestedProcessId = [int64][int]$ProcessId; Process = $null })
}.GetNewClosure()) -ObservedEnvKeys @()
if ($missingParentContext.traversal_outcome -ne 'parent_process_missing' -or (Test-TeremoqCaptureContextEvidence -Context $missingParentContext)) {
    throw 'positive parent PID without CIM result was accepted'
}
$cycleRecords = @{
    301 = (New-TeremoqMockProcess -ProcessId 301 -Name 'powershell.exe' -ParentProcessId 300)
    300 = (New-TeremoqMockProcess -ProcessId 300 -Name 'windowsterminal.exe' -ParentProcessId 299)
    299 = (New-TeremoqMockProcess -ProcessId 299 -Name 'explorer.exe' -ParentProcessId 300)
}
$cycleContext = New-TeremoqCaptureContext -CurrentProcessId 301 -CurrentResult ([ordered]@{ Status = 'ok'; RequestedProcessId = [int64]301; Process = $cycleRecords[301] }) -ResolveProcess ({
    param($ProcessId)
    if ($cycleRecords.ContainsKey([int]$ProcessId)) {
        return ([ordered]@{ Status = 'ok'; RequestedProcessId = [int64][int]$ProcessId; Process = $cycleRecords[[int]$ProcessId] })
    }
    return ([ordered]@{ Status = 'process_missing'; RequestedProcessId = [int64][int]$ProcessId; Process = $null })
}.GetNewClosure()) -ObservedEnvKeys @()
if ($cycleContext.traversal_outcome -ne 'cycle_or_pid_reuse_detected' -or (Test-TeremoqCaptureContextEvidence -Context $cycleContext)) {
    throw 'cycle/reused PID capture context was accepted'
}
$deepRecords = @{ 401 = (New-TeremoqMockProcess -ProcessId 401 -Name 'powershell.exe' -ParentProcessId 400) }
for ($offset = 0; $offset -lt 16; $offset += 1) {
    $processId = 400 - $offset
    $parentId = if ($offset -eq 15) { 1 } else { $processId - 1 }
    $deepRecords[$processId] = New-TeremoqMockProcess -ProcessId $processId -Name "safe$offset.exe" -ParentProcessId $parentId
}
$deepRecords[1] = New-TeremoqMockProcess -ProcessId 1 -Name 'wslhost.exe' -ParentProcessId 0
$deepContext = New-TeremoqCaptureContext -CurrentProcessId 401 -CurrentResult ([ordered]@{ Status = 'ok'; RequestedProcessId = [int64]401; Process = $deepRecords[401] }) -ResolveProcess ({
    param($ProcessId)
    if ($deepRecords.ContainsKey([int]$ProcessId)) {
        return ([ordered]@{ Status = 'ok'; RequestedProcessId = [int64][int]$ProcessId; Process = $deepRecords[[int]$ProcessId] })
    }
    return ([ordered]@{ Status = 'process_missing'; RequestedProcessId = [int64][int]$ProcessId; Process = $null })
}.GetNewClosure()) -ObservedEnvKeys @()
if ($deepContext.traversal_outcome -ne 'depth_limit_reached' -or $deepContext.parent_process_count -ne 16 -or (Test-TeremoqCaptureContextEvidence -Context $deepContext)) {
    throw 'depth-limited capture context was accepted'
}
$mismatchCurrentProcess = [ordered]@{
    ProcessId = [int64]777
    ParentProcessId = [int64]0
    Name = 'powershell.exe'
    CreationDate = '20260831100000.000000+120'
}
$mismatchProcessIdContext = New-TeremoqCaptureContext -CurrentProcessId 501 -CurrentResult ([ordered]@{ Status = 'ok'; RequestedProcessId = [int64]501; Process = $mismatchCurrentProcess }) -ResolveProcess ({ param($ProcessId) [ordered]@{ Status = 'process_missing'; RequestedProcessId = [int64][int]$ProcessId; Process = $null } }.GetNewClosure()) -ObservedEnvKeys @()
if ($mismatchProcessIdContext.traversal_outcome -ne 'cim_query_failed' -or (Test-TeremoqCaptureContextEvidence -Context $mismatchProcessIdContext)) {
    throw 'mismatched current ProcessId was accepted'
}
$stringPidProcess = [ordered]@{
    ProcessId = '601'
    ParentProcessId = 0
    Name = 'powershell.exe'
    CreationDate = '20260831100000.000000+120'
}
$stringPidContext = New-TeremoqCaptureContext -CurrentProcessId 601 -CurrentResult ([ordered]@{ Status = 'ok'; RequestedProcessId = [int64]601; Process = $stringPidProcess }) -ResolveProcess ({ param($ProcessId) [ordered]@{ Status = 'process_missing'; RequestedProcessId = [int64][int]$ProcessId; Process = $null } }.GetNewClosure()) -ObservedEnvKeys @()
if ($stringPidContext.traversal_outcome -ne 'cim_query_failed' -or (Test-TeremoqCaptureContextEvidence -Context $stringPidContext)) {
    throw 'string ProcessId was accepted'
}
$impossibleDateProcess = [ordered]@{
    ProcessId = [int64]602
    ParentProcessId = [int64]0
    Name = 'powershell.exe'
    CreationDate = '20261331100000.000000+120'
}
$impossibleDateContext = New-TeremoqCaptureContext -CurrentProcessId 602 -CurrentResult ([ordered]@{ Status = 'ok'; RequestedProcessId = [int64]602; Process = $impossibleDateProcess }) -ResolveProcess ({ param($ProcessId) [ordered]@{ Status = 'process_missing'; RequestedProcessId = [int64][int]$ProcessId; Process = $null } }.GetNewClosure()) -ObservedEnvKeys @()
if ($impossibleDateContext.traversal_outcome -ne 'cim_query_failed' -or (Test-TeremoqCaptureContextEvidence -Context $impossibleDateContext)) {
    throw 'regex-valid impossible DMTF date was accepted'
}
$unknownStatusContext = New-TeremoqCaptureContext -CurrentProcessId 701 -CurrentResult ([ordered]@{
    Status = 'unexpected'
    RequestedProcessId = [int64]701
    Process = [ordered]@{
        ProcessId = [int64]701
        ParentProcessId = [int64]0
        Name = 'powershell.exe'
        CreationDate = '20260831100000.000000+120'
    }
}) -ResolveProcess ({ param($ProcessId) [ordered]@{ Status = 'process_missing'; RequestedProcessId = [int64][int]$ProcessId; Process = $null } }.GetNewClosure()) -ObservedEnvKeys @()
if ($unknownStatusContext.traversal_outcome -ne 'cim_query_failed' -or (Test-TeremoqCaptureContextEvidence -Context $unknownStatusContext)) {
    throw 'unknown CIM query status was accepted'
}
$mismatchedRequestedParentCurrent = [ordered]@{
    ProcessId = [int64]801
    ParentProcessId = [int64]800
    Name = 'powershell.exe'
    CreationDate = '20260831100000.000000+120'
}
$mismatchedRequestedParent = New-TeremoqCaptureContext -CurrentProcessId 801 -CurrentResult ([ordered]@{ Status = 'ok'; RequestedProcessId = [int64]801; Process = $mismatchedRequestedParentCurrent }) -ResolveProcess ({
    param($ProcessId)
    if ([int]$ProcessId -eq 801) {
        return ([ordered]@{ Status = 'ok'; RequestedProcessId = [int64]801; Process = $mismatchedRequestedParentCurrent })
    }
    return ([ordered]@{
        Status = 'ok'
        RequestedProcessId = [int64]999
        Process = [ordered]@{
            ProcessId = [int64]800
            ParentProcessId = [int64]0
            Name = 'windowsterminal.exe'
            CreationDate = '20260831100000.000000+120'
        }
    })
}.GetNewClosure()) -ObservedEnvKeys @()
if ($mismatchedRequestedParent.traversal_outcome -ne 'cim_query_failed' -or (Test-TeremoqCaptureContextEvidence -Context $mismatchedRequestedParent)) {
    throw 'mismatched requested parent PID was accepted'
}
$parentNewerCurrent = [ordered]@{
    ProcessId = [int64]901
    ParentProcessId = [int64]900
    Name = 'powershell.exe'
    CreationDate = '20260831100000.000000+120'
}
$parentNewerContext = New-TeremoqCaptureContext -CurrentProcessId 901 -CurrentResult ([ordered]@{ Status = 'ok'; RequestedProcessId = [int64]901; Process = $parentNewerCurrent }) -ResolveProcess ({
    param($ProcessId)
    if ([int]$ProcessId -eq 901) {
        return ([ordered]@{ Status = 'ok'; RequestedProcessId = [int64]901; Process = $parentNewerCurrent })
    }
    if ([int]$ProcessId -eq 900) {
        return ([ordered]@{
            Status = 'ok'
            RequestedProcessId = [int64]900
            Process = [ordered]@{
                ProcessId = [int64]900
                ParentProcessId = [int64]0
                Name = 'windowsterminal.exe'
                CreationDate = '20260831100100.000000+120'
            }
        })
    }
    return ([ordered]@{ Status = 'process_missing'; RequestedProcessId = [int64][int]$ProcessId; Process = $null })
}.GetNewClosure()) -ObservedEnvKeys @()
if ($parentNewerContext.traversal_outcome -ne 'parent_process_newer_than_child' -or (Test-TeremoqCaptureContextEvidence -Context $parentNewerContext)) {
    throw 'newer parent creation date was accepted'
}
$pidReuseCurrent = [ordered]@{
    ProcessId = [int64]921
    ParentProcessId = [int64]920
    Name = 'powershell.exe'
    CreationDate = '20260831100000.000000+120'
}
$pidReuseContext = New-TeremoqCaptureContext -CurrentProcessId 921 -CurrentResult ([ordered]@{ Status = 'ok'; RequestedProcessId = [int64]921; Process = $pidReuseCurrent }) -ResolveProcess ({
    param($ProcessId)
    if ([int]$ProcessId -eq 920) {
        return ([ordered]@{
            Status = 'ok'
            RequestedProcessId = [int64]920
            Process = [ordered]@{
                ProcessId = [int64]920
                ParentProcessId = [int64]921
                Name = 'windowsterminal.exe'
                CreationDate = '20260831100000.000000+120'
            }
        })
    }
    if ([int]$ProcessId -eq 921) {
        return ([ordered]@{ Status = 'ok'; RequestedProcessId = [int64]921; Process = $pidReuseCurrent })
    }
    return ([ordered]@{ Status = 'process_missing'; RequestedProcessId = [int64][int]$ProcessId; Process = $null })
}.GetNewClosure()) -ObservedEnvKeys @()
if ($pidReuseContext.traversal_outcome -ne 'cycle_or_pid_reuse_detected' -or (Test-TeremoqCaptureContextEvidence -Context $pidReuseContext)) {
    throw 'PID reuse/cycle was accepted'
}
$unstableCreationCurrent = [ordered]@{
    ProcessId = [int64]931
    ParentProcessId = [int64]930
    Name = 'powershell.exe'
    CreationDate = '20260831100000.000000+120'
}
$unstableCreationState = [pscustomobject]@{ Count = 0 }
$unstableCreationContext = New-TeremoqCaptureContext -CurrentProcessId 931 -CurrentResult ([ordered]@{ Status = 'ok'; RequestedProcessId = [int64]931; Process = $unstableCreationCurrent }) -ResolveProcess ({
    param($ProcessId)
    if ([int]$ProcessId -eq 931) {
        return ([ordered]@{ Status = 'ok'; RequestedProcessId = [int64]931; Process = $unstableCreationCurrent })
    }
    if ([int]$ProcessId -eq 930) {
        $unstableCreationState.Count += 1
        $creationDate = if ($unstableCreationState.Count -eq 1) { '20260831095900.000000+120' } else { '20260831100100.000000+120' }
        return ([ordered]@{
            Status = 'ok'
            RequestedProcessId = [int64]930
            Process = [ordered]@{
                ProcessId = [int64]930
                ParentProcessId = [int64]0
                Name = 'windowsterminal.exe'
                CreationDate = $creationDate
            }
        })
    }
    if ([int]$ProcessId -eq 901) {
        return ([ordered]@{
            Status = 'ok'
            RequestedProcessId = [int64]901
            Process = [ordered]@{
                ProcessId = [int64]901
                ParentProcessId = [int64]0
                Name = 'powershell.exe'
                CreationDate = '20260831100200.000000+120'
            }
        })
    }
    return ([ordered]@{ Status = 'process_missing'; RequestedProcessId = [int64][int]$ProcessId; Process = $null })
}.GetNewClosure()) -ObservedEnvKeys @()
if ($unstableCreationContext.traversal_outcome -ne 'parent_process_unstable' -or (Test-TeremoqCaptureContextEvidence -Context $unstableCreationContext)) {
    throw 'parent CreationDate change between queries was accepted'
}
$unstableParentPidCurrent = [ordered]@{
    ProcessId = [int64]941
    ParentProcessId = [int64]940
    Name = 'powershell.exe'
    CreationDate = '20260831100000.000000+120'
}
$unstableParentPidState = [pscustomobject]@{ Count = 0 }
$unstableParentPidContext = New-TeremoqCaptureContext -CurrentProcessId 941 -CurrentResult ([ordered]@{ Status = 'ok'; RequestedProcessId = [int64]941; Process = $unstableParentPidCurrent }) -ResolveProcess ({
    param($ProcessId)
    if ([int]$ProcessId -eq 941) {
        return ([ordered]@{ Status = 'ok'; RequestedProcessId = [int64]941; Process = $unstableParentPidCurrent })
    }
    if ([int]$ProcessId -eq 940) {
        $unstableParentPidState.Count += 1
        $parentProcessId = if ($unstableParentPidState.Count -eq 1) { [int64]0 } else { [int64]1 }
        return ([ordered]@{
            Status = 'ok'
            RequestedProcessId = [int64]940
            Process = [ordered]@{
                ProcessId = [int64]940
                ParentProcessId = $parentProcessId
                Name = 'windowsterminal.exe'
                CreationDate = '20260831095900.000000+120'
            }
        })
    }
    return ([ordered]@{ Status = 'process_missing'; RequestedProcessId = [int64][int]$ProcessId; Process = $null })
}.GetNewClosure()) -ObservedEnvKeys @()
if ($unstableParentPidContext.traversal_outcome -ne 'parent_process_unstable' -or (Test-TeremoqCaptureContextEvidence -Context $unstableParentPidContext)) {
    throw 'parent ParentProcessId change between queries was accepted'
}
$unstableNameCurrent = [ordered]@{
    ProcessId = [int64]951
    ParentProcessId = [int64]950
    Name = 'powershell.exe'
    CreationDate = '20260831100000.000000+120'
}
$unstableNameState = [pscustomobject]@{ Count = 0 }
$unstableNameContext = New-TeremoqCaptureContext -CurrentProcessId 951 -CurrentResult ([ordered]@{ Status = 'ok'; RequestedProcessId = [int64]951; Process = $unstableNameCurrent }) -ResolveProcess ({
    param($ProcessId)
    if ([int]$ProcessId -eq 951) {
        return ([ordered]@{ Status = 'ok'; RequestedProcessId = [int64]951; Process = $unstableNameCurrent })
    }
    if ([int]$ProcessId -eq 950) {
        $unstableNameState.Count += 1
        $name = if ($unstableNameState.Count -eq 1) { 'windowsterminal.exe' } else { 'explorer.exe' }
        return ([ordered]@{
            Status = 'ok'
            RequestedProcessId = [int64]950
            Process = [ordered]@{
                ProcessId = [int64]950
                ParentProcessId = [int64]0
                Name = $name
                CreationDate = '20260831095900.000000+120'
            }
        })
    }
    return ([ordered]@{ Status = 'process_missing'; RequestedProcessId = [int64][int]$ProcessId; Process = $null })
}.GetNewClosure()) -ObservedEnvKeys @()
if ($unstableNameContext.traversal_outcome -ne 'parent_process_unstable' -or (Test-TeremoqCaptureContextEvidence -Context $unstableNameContext)) {
    throw 'parent name change between queries was accepted'
}
$nonOkRequeryCurrent = [ordered]@{
    ProcessId = [int64]961
    ParentProcessId = [int64]960
    Name = 'powershell.exe'
    CreationDate = '20260831100000.000000+120'
}
$nonOkRequeryState = [pscustomobject]@{ Count = 0 }
$nonOkRequeryContext = New-TeremoqCaptureContext -CurrentProcessId 961 -CurrentResult ([ordered]@{ Status = 'ok'; RequestedProcessId = [int64]961; Process = $nonOkRequeryCurrent }) -ResolveProcess ({
    param($ProcessId)
    if ([int]$ProcessId -eq 961) {
        return ([ordered]@{ Status = 'ok'; RequestedProcessId = [int64]961; Process = $nonOkRequeryCurrent })
    }
    if ([int]$ProcessId -eq 960) {
        $nonOkRequeryState.Count += 1
        if ($nonOkRequeryState.Count -eq 1) {
            return ([ordered]@{
                Status = 'ok'
                RequestedProcessId = [int64]960
                Process = [ordered]@{
                    ProcessId = [int64]960
                    ParentProcessId = [int64]0
                    Name = 'windowsterminal.exe'
                    CreationDate = '20260831095900.000000+120'
                }
            })
        }
        return ([ordered]@{ Status = 'cim_query_failed'; RequestedProcessId = [int64]960; Process = $null })
    }
    return ([ordered]@{ Status = 'process_missing'; RequestedProcessId = [int64][int]$ProcessId; Process = $null })
}.GetNewClosure()) -ObservedEnvKeys @()
if ($nonOkRequeryContext.traversal_outcome -ne 'parent_process_unstable' -or (Test-TeremoqCaptureContextEvidence -Context $nonOkRequeryContext)) {
    throw 'non-ok parent requery was accepted'
}
$interopContext = [ordered]@{
    schema_version = 2
    current_process_name = 'powershell.exe'
    parent_process_names = @('wslhost.exe', 'bash.exe')
    parent_process_count = 2
    traversal_depth_limit = 16
    traversal_outcome = 'terminated_parent_pid_nonpositive'
    wsl_environment_keys_present = @('WSL_INTEROP')
    powershell_edition = 'Desktop'
    powershell_version_major = 5
}
if (Test-TeremoqCaptureContextEvidence -Context $interopContext) { throw 'WSL interop capture context was accepted' }
$uppercaseContext = [ordered]@{
    schema_version = 2
    current_process_name = 'PowerShell.exe'
    parent_process_names = @('windowsterminal.exe')
    parent_process_count = 1
    traversal_depth_limit = 16
    traversal_outcome = 'terminated_parent_pid_nonpositive'
    wsl_environment_keys_present = @()
    powershell_edition = 'Desktop'
    powershell_version_major = 5
}
if (Test-TeremoqCaptureContextEvidence -Context $uppercaseContext) { throw 'uppercase current process name was accepted' }
$pathParentContext = [ordered]@{
    schema_version = 2
    current_process_name = 'powershell.exe'
    parent_process_names = @('C:\Windows\System32\wslhost.exe')
    parent_process_count = 1
    traversal_depth_limit = 16
    traversal_outcome = 'terminated_parent_pid_nonpositive'
    wsl_environment_keys_present = @()
    powershell_edition = 'Desktop'
    powershell_version_major = 5
}
if (Test-TeremoqCaptureContextEvidence -Context $pathParentContext) { throw 'path parent process name was accepted' }
$trailingSpaceParentContext = [ordered]@{
    schema_version = 2
    current_process_name = 'powershell.exe'
    parent_process_names = @('wslhost.exe ')
    parent_process_count = 1
    traversal_depth_limit = 16
    traversal_outcome = 'terminated_parent_pid_nonpositive'
    wsl_environment_keys_present = @()
    powershell_edition = 'Desktop'
    powershell_version_major = 5
}
if (Test-TeremoqCaptureContextEvidence -Context $trailingSpaceParentContext) { throw 'trailing-space parent process name was accepted' }
$stringSchemaContext = [ordered]@{
    schema_version = '2'
    current_process_name = 'powershell.exe'
    parent_process_names = @('windowsterminal.exe')
    parent_process_count = 1
    traversal_depth_limit = 16
    traversal_outcome = 'terminated_parent_pid_nonpositive'
    wsl_environment_keys_present = @()
    powershell_edition = 'Desktop'
    powershell_version_major = 5
}
if (Test-TeremoqCaptureContextEvidence -Context $stringSchemaContext) { throw 'string schema_version was accepted' }

Write-Output 'Teremoq LAN PowerShell contract helpers passed WLAN, Docker, clock and capture-context regressions.'
