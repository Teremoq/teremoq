# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ScriptPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. $ScriptPath

function Assert-Record($Record, [string]$Status, [string]$Value, [string]$Quality) {
    if ($Record.check -cne 'listener_tcp_18443' -or $Record.status -cne $Status -or
        $Record.value -cne $Value -or $Record.evidence_quality -cne $Quality) {
        throw "unexpected listener record: $($Record | ConvertTo-Json -Compress)"
    }
}

$free = @(Get-TeremoqListenerCheckRecords -Protocol tcp -Ports @(18443) -Query { @() })
if ($free.Count -ne 1) { throw 'free listener result cardinality differs from policy' }
Assert-Record $free[0] 'pass' 'free' 'real'

$occupied = @(Get-TeremoqListenerCheckRecords -Protocol tcp -Ports @(18443) -Query {
    [pscustomobject]@{ LocalPort = [uint16]18443 }
})
if ($occupied.Count -ne 1) { throw 'occupied listener result cardinality differs from policy' }
Assert-Record $occupied[0] 'blocked' 'occupied' 'real'

$duplicate = @(Get-TeremoqListenerCheckRecords -Protocol tcp -Ports @(18443) -Query {
    [pscustomobject]@{ LocalPort = [uint16]18443 }
    [pscustomobject]@{ LocalPort = [uint16]18443 }
})
if ($duplicate.Count -ne 1) { throw 'duplicate listener result cardinality differs from policy' }
Assert-Record $duplicate[0] 'blocked' 'occupied' 'real'

$failed = @(Get-TeremoqListenerCheckRecords -Protocol tcp -Ports @(18443) -Query {
    Write-Error 'provider failure' -ErrorAction Stop
})
if ($failed.Count -ne 1) { throw 'failed listener result cardinality differs from policy' }
Assert-Record $failed[0] 'blocked' 'query-failed' 'unavailable'

$otherNativePort = @(Get-TeremoqListenerCheckRecords -Protocol tcp -Ports @(18443) -Query {
    [pscustomobject]@{ LocalPort = [uint16]18444 }
})
Assert-Record $otherNativePort[0] 'pass' 'free' 'real'

$malformedQueries = @(
    { [pscustomobject]@{ LocalPort = '18444' } },
    { [pscustomobject]@{ LocalPort = [double]18444 } },
    { [pscustomobject]@{ LocalPort = $true } },
    { [pscustomobject]@{ LocalPort = [int32]18444 } },
    { [pscustomobject]@{ LocalPort = @([uint16]18444) } },
    { [pscustomobject]@{ OtherPort = [uint16]18444 } },
    { [pscustomobject]@{ LocalPort = [uint16]0 } }
)
foreach ($query in $malformedQueries) {
    $malformed = @(Get-TeremoqListenerCheckRecords -Protocol tcp -Ports @(18443) -Query $query)
    if ($malformed.Count -ne 1) { throw 'malformed listener result cardinality differs from policy' }
    Assert-Record $malformed[0] 'blocked' 'query-failed' 'unavailable'
}

Write-Output 'listener-query-fixture: PASS'
