# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param([switch]$LiveLoopback)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot '..\windows\Preflight-Contract.ps1')
function Assert-Observation($Replies, $Loss, $LossQuality, $Rtt, $RttQuality) {
    $result = Get-TeremoqIcmpEchoObservation -Replies $Replies -SentCount 4
    if ($result.LossPercent -cne $Loss -or $result.LossQuality -cne $LossQuality -or
        $result.RttAverage -cne $Rtt -or $result.RttQuality -cne $RttQuality) {
        throw 'ICMP observation differs from the synthetic expected result'
    }
    # Same fields/JSON serialization used by the preflight. No synthetic PASS
    # claims about host identity, firewall, AV or the full client preflight.
    $json = @(
        [ordered]@{check='icmp_echo_loss_percent_approximation';status='observed';value=$result.LossPercent;evidence_quality=$result.LossQuality},
        [ordered]@{check='icmp_echo_rtt_average_ms_approximation';status='observed';value=$result.RttAverage;evidence_quality=$result.RttQuality}
    ) | ConvertTo-Json
    if (@($json | ConvertFrom-Json).Count -ne 2) { throw 'ICMP records did not serialize' }
}
$desktop = [pscustomobject]@{StatusCode=[uint32]0;ResponseTime=[uint32]2}
$core = [pscustomobject]@{Status=[Net.NetworkInformation.IPStatus]::Success;Latency=[long]4}
Assert-Observation @($desktop,$desktop,$desktop,$desktop) '0' 'real' '2' 'real'
Assert-Observation @($core,$core,$core,$core) '0' 'real' '4' 'real'
Assert-Observation @($desktop,$core) '50' 'real' '3' 'real'
Assert-Observation @() '100' 'real' 'unavailable' 'unavailable'
$timeout = [pscustomobject]@{Status=[Net.NetworkInformation.IPStatus]::TimedOut;Latency=[long]0}
$desktopFailure = [pscustomobject]@{StatusCode=[uint32]11010}
Assert-Observation @($timeout,$desktopFailure) '100' 'real' 'unavailable' 'unavailable'
Assert-Observation @([pscustomobject]@{Status=[Net.NetworkInformation.IPStatus]::Success}) '75' 'real' 'unavailable' 'unavailable'
Assert-Observation @([pscustomobject]@{StatusCode=[uint32]0}) '75' 'real' 'unavailable' 'unavailable'
Assert-Observation @([pscustomobject]@{ResponseTime=0}) 'unavailable' 'unavailable' 'unavailable' 'unavailable'
Assert-Observation @([pscustomobject]@{StatusCode=$false;ResponseTime=0}) 'unavailable' 'unavailable' 'unavailable' 'unavailable'
Assert-Observation @([pscustomobject]@{Status='Success';Latency=0}) 'unavailable' 'unavailable' 'unavailable' 'unavailable'
Assert-Observation @([pscustomobject]@{Status=[Net.NetworkInformation.IPStatus]::Success;StatusCode=0;Latency=0}) 'unavailable' 'unavailable' 'unavailable' 'unavailable'
foreach ($value in @($null,$false,'0',-1,[double]::NaN,[double]::PositiveInfinity)) {
    Assert-Observation @([pscustomobject]@{Status=[Net.NetworkInformation.IPStatus]::Success;Latency=$value}) '75' 'real' 'unavailable' 'unavailable'
}
$rejected = $false
try { Get-TeremoqIcmpEchoObservation -Replies @($core,$core,$core,$core,$core) -SentCount 4 | Out-Null } catch { $rejected = $true }
if (-not $rejected) { throw 'Excess ICMP records accepted' }
Write-Output 'PASS: synthetic Desktop5/Core7 ICMP records under StrictMode; unavailable is not a measured RTT'
if ($LiveLoopback) {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
        -not (($PSVersionTable.PSEdition -ceq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5) -or
        ($PSVersionTable.PSEdition -ceq 'Core' -and $PSVersionTable.PSVersion.ToString() -ceq '7.6.6'))) {
        throw 'Live compatibility test requires Windows Desktop5 or Core7.6.6'
    }
    # Official cmdlet, actual replies, only the local host. Never target the LAN.
    $responses = @(Test-Connection -ComputerName '127.0.0.1' -Count 4 -ErrorAction Stop)
    if ($responses.Count -ne 4) { throw 'Loopback did not return all requested replies' }
    $actual = Get-TeremoqIcmpEchoObservation -Replies $responses -SentCount 4
    if ($actual.LossPercent -cne '0' -or $actual.LossQuality -cne 'real' -or $actual.RttQuality -cne 'real') {
        throw 'Real loopback Test-Connection replies could not be normalized'
    }
    Write-Output ('PASS: real Test-Connection loopback -> normalizer; edition={0}; version={1}; replies=4' -f
        $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)
} else { Write-Output 'NOT_EXECUTED: live Test-Connection loopback (use -LiveLoopback explicitly)' }
