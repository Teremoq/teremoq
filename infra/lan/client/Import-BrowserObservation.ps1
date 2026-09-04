# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [Parameter(Mandatory = $true)][string]$EvidenceRoot,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][ValidateSet(1, 5, 10, 25)][int]$Level
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot 'Client-Distribution.ps1')
$exactName = 'local-browser-observation-user-exported.json'
if ($RunId -notmatch '^lan-[a-z0-9][a-z0-9-]{0,31}$') { throw 'invalid RunId' }
$source = [IO.Path]::GetFullPath($SourcePath)
if ([IO.Path]::GetFileName($source) -cne $exactName) { throw "browser export must have the exact name $exactName" }
$sourceItem = Get-Item -LiteralPath $source -Force
if ($sourceItem.PSIsContainer) { throw 'browser export must be a regular file' }
if (($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'browser export may not be a symlink/reparse point' }
$sourceStream = $null
try {
    $sourceStream = New-Object IO.FileStream($source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    if ($sourceStream.Length -lt 2 -or $sourceStream.Length -gt 65536) { throw 'browser export is outside its 2..65536 byte limit' }
    $sourceBytes = New-Object byte[] ([int]$sourceStream.Length)
    $offset = 0
    while ($offset -lt $sourceBytes.Length) {
        $read = $sourceStream.Read($sourceBytes, $offset, $sourceBytes.Length - $offset)
        if ($read -le 0) { throw 'browser export ended before its opened length' }
        $offset += $read
    }
    if ($sourceStream.ReadByte() -ne -1) { throw 'browser export exceeded its opened length' }
    $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
    $sourceText = $strictUtf8.GetString($sourceBytes)
$state = Get-TeremoqLanStateContext -StateRoot $StateRoot
$evidenceRootFull = [IO.Path]::GetFullPath($EvidenceRoot)
foreach ($directory in @($state.StateRoot, $evidenceRootFull)) {
    if (-not (Test-Path -LiteralPath $directory -PathType Container) -or ((Get-Item -LiteralPath $directory).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'state/evidence roots must be existing non-reparse directories' }
}
$version = $state.Version
$lanConfig = $state.LanConfig
function Assert-ExactProperties($Object, [string[]]$Expected, [string]$Label) {
    if ($null -eq $Object) { throw "$Label must be an object" }
    $actual = @($Object.PSObject.Properties.Name)
    if ($actual.Count -ne $Expected.Count -or @($actual | Where-Object { $Expected -notcontains $_ }).Count -ne 0) {
        throw "$Label schema is not closed"
    }
}
function Test-SafeInteger($Value) {
    if ($null -eq $Value -or $Value -is [bool] -or -not ($Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or $Value -is [decimal] -or $Value -is [double] -or $Value -is [single])) { return $false }
    try { $number = [decimal]$Value } catch { return $false }
    return $number -ge 0 -and $number -le 9007199254740991 -and $number -eq [decimal]::Truncate($number)
}
function Assert-SafeInteger($Value, [string]$Name, [decimal]$Minimum, [decimal]$Maximum) {
    if (-not (Test-SafeInteger $Value) -or [decimal]$Value -lt $Minimum -or [decimal]$Value -gt $Maximum) {
        throw "invalid safe integer browser field: $Name"
    }
}
function Test-FiniteNumber($Value, [double]$Minimum, [double]$Maximum) {
    if ($null -eq $Value -or $Value -is [bool] -or -not ($Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or $Value -is [decimal] -or $Value -is [double] -or $Value -is [single])) { return $false }
    $number = [double]$Value
    return -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number) -and $number -ge $Minimum -and $number -le $Maximum
}
function Parse-CanonicalUtc([string]$Value, [string]$Name) {
    if ($Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[.]\d{3}Z$') { throw "$Name is not canonical UTC" }
    $parsed = [DateTimeOffset]::MinValue
    $valid = [DateTimeOffset]::TryParseExact($Value, "yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$parsed)
    if (-not $valid -or $parsed.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture) -cne $Value) {
        throw "$Name is not canonical UTC"
    }
    return $parsed
}

$document = $sourceText | ConvertFrom-Json
$common = @('schema_version', 'export_kind', 'source', 'measurement_status', 'mode', 'level', 'run_id', 'source_commit',
    'started_at_utc', 'ended_at_utc', 'phase', 'requested_sessions', 'active_sessions_peak', 'objects_observed',
    'bytes_observed', 'duration_ms')
$playerSpecific = @('track', 'frames_observed', 'presentation_rx_to_canvas_p95_ms', 'g2g_measurement_status', 'g2g_p95_ms',
    'session_losses', 'session_recoveries', 'last_session_recovery_ms', 'wifi_recovery_status', 'wifi_recovery_armed',
    'wifi_loss_observed', 'wifi_recovery_observed', 'wifi_recovery_ms', 'wifi_recovery_provenance', 'last_error', 'unavailable_measurements')
$lightSpecific = @('closed_sessions', 'local_stream_rejections', 'errors', 'reconnect_attempts', 'session_losses', 'session_recoveries',
    'last_session_recovery_ms', 'first_connected_ms', 'all_active_ms', 'last_object_ms', 'last_error', 'unavailable_measurements')
$expected = if ($Level -eq 1) { @($common + $playerSpecific) } else { @($common + $lightSpecific) }
Assert-ExactProperties $document $expected 'browser observation JSON'
if ($document.schema_version -ne 1 -or $document.source -cne 'local-browser-observation-user-exported' -or
    $document.measurement_status -cne 'measured' -or $document.phase -cne 'closed' -or
    $document.run_id -cne $RunId -or $document.source_commit -cne $version.source_commit) {
    throw 'browser observation identity/run/commit binding is outside policy'
}
Assert-SafeInteger $document.level 'level' $Level $Level
Assert-SafeInteger $document.requested_sessions 'requested_sessions' $Level $Level
Assert-SafeInteger $document.active_sessions_peak 'active_sessions_peak' $Level $Level
Assert-SafeInteger $document.objects_observed 'objects_observed' 1 9007199254740991
Assert-SafeInteger $document.bytes_observed 'bytes_observed' 1 9007199254740991
Assert-SafeInteger $document.duration_ms 'duration_ms' 600000 86400000
$started = Parse-CanonicalUtc ([string]$document.started_at_utc) 'started_at_utc'
$ended = Parse-CanonicalUtc ([string]$document.ended_at_utc) 'ended_at_utc'
if ($ended -lt $started -or [math]::Abs(($ended - $started).TotalMilliseconds - [double]$document.duration_ms) -gt 5000) {
    throw 'browser observation UTC timestamps are incoherent with duration_ms'
}
$baseUnavailable = @('quic_packet_loss', 'quic_jitter_ms', 'authorized_viewers', 'ingest_to_publish_ms', 'network_subscribers')
$durationMaximum = [double]$document.duration_ms
if ($Level -eq 1) {
    if ($document.export_kind -cne 'lan-real-player' -or $document.mode -cne 'real-player') { throw 'level 1 requires the Web real-player export' }
    Assert-SafeInteger $document.track 'track' 0 1
    Assert-SafeInteger $document.frames_observed 'frames_observed' 1 9007199254740991
    if (-not (Test-FiniteNumber $document.presentation_rx_to_canvas_p95_ms 0 $durationMaximum)) { throw 'invalid presentation_rx_to_canvas_p95_ms' }
    if ($document.g2g_measurement_status -ceq 'measured') {
        if (-not (Test-FiniteNumber $document.g2g_p95_ms 0 $durationMaximum)) { throw 'measured g2g_p95_ms is invalid' }
    } elseif ($document.g2g_measurement_status -cne 'not_available' -or $null -ne $document.g2g_p95_ms) {
        throw 'g2g status/value contract mismatch'
    }
    Assert-SafeInteger $document.session_losses 'session_losses' 1 9007199254740991
    Assert-SafeInteger $document.session_recoveries 'session_recoveries' 0 ([decimal]$document.session_losses)
    if ([decimal]$document.session_recoveries -eq 0) {
        if ($null -ne $document.last_session_recovery_ms) { throw 'last_session_recovery_ms must be null without recovery' }
    } else {
        Assert-SafeInteger $document.last_session_recovery_ms 'last_session_recovery_ms' 0 ([decimal]$document.duration_ms)
    }
    if ($document.wifi_recovery_status -cne 'measured' -or $document.wifi_recovery_armed -isnot [bool] -or
        $document.wifi_loss_observed -isnot [bool] -or $document.wifi_recovery_observed -isnot [bool] -or
        -not $document.wifi_recovery_armed -or -not $document.wifi_loss_observed -or -not $document.wifi_recovery_observed -or
        $document.wifi_recovery_provenance -cne 'operator-armed-browser-monotonic-session-loss-to-first-recovered-object' -or
        $null -ne $document.last_error) { throw 'level 1 Wi-Fi recovery is not explicit, armed and complete' }
    Assert-SafeInteger $document.wifi_recovery_ms 'wifi_recovery_ms' 1 180000
    Assert-ExactProperties $document.unavailable_measurements $baseUnavailable 'player unavailable_measurements'
    if ($document.unavailable_measurements.quic_packet_loss -cne 'not_available' -or
        $document.unavailable_measurements.quic_jitter_ms -cne 'not_available' -or
        $document.unavailable_measurements.authorized_viewers -cne 'not_measured' -or
        $document.unavailable_measurements.ingest_to_publish_ms -cne 'not_available' -or
        $document.unavailable_measurements.network_subscribers -cne 'not_available') { throw 'player unavailable_measurements values mismatch' }
} else {
    if ($document.export_kind -cne 'lan-load-sessions' -or $document.mode -cne 'lightweight-moq') { throw 'load level requires the Web lightweight export' }
    Assert-SafeInteger $document.closed_sessions 'closed_sessions' $Level 9007199254740991
    Assert-SafeInteger $document.local_stream_rejections 'local_stream_rejections' 0 9007199254740991
    Assert-SafeInteger $document.errors 'errors' ([decimal]$document.local_stream_rejections) 9007199254740991
    Assert-SafeInteger $document.reconnect_attempts 'reconnect_attempts' 0 9007199254740991
    Assert-SafeInteger $document.session_losses 'session_losses' 0 9007199254740991
    Assert-SafeInteger $document.session_recoveries 'session_recoveries' 0 ([decimal]$document.session_losses)
    if ([decimal]$document.session_recoveries -eq 0) {
        if ($null -ne $document.last_session_recovery_ms) { throw 'last_session_recovery_ms must be null without recovery' }
    } else { Assert-SafeInteger $document.last_session_recovery_ms 'last_session_recovery_ms' 0 9007199254740991 }
    Assert-SafeInteger $document.first_connected_ms 'first_connected_ms' 0 9007199254740991
    Assert-SafeInteger $document.all_active_ms 'all_active_ms' ([decimal]$document.first_connected_ms) 9007199254740991
    Assert-SafeInteger $document.last_object_ms 'last_object_ms' ([decimal]$document.first_connected_ms) ([decimal]$document.duration_ms)
    $allowedErrors = @('configuration-invalid', 'trust-invalid', 'protocol-incompatible', 'network-unreachable', 'connection-timeout', 'local-stream-rejected', 'retry-exhausted')
    if ($null -ne $document.last_error -and ($document.last_error -isnot [string] -or $allowedErrors -notcontains $document.last_error)) { throw 'invalid lightweight last_error' }
    $lightUnavailable = @($baseUnavailable + @('presentation_p95_ms', 'g2g_p95_ms', 'wifi_recovery_ms', 'frames_observed'))
    Assert-ExactProperties $document.unavailable_measurements $lightUnavailable 'lightweight unavailable_measurements'
    foreach ($name in $lightUnavailable) {
        $expectedUnavailable = if ($name -ceq 'authorized_viewers') { 'not_measured' } else { 'not_available' }
        if ($document.unavailable_measurements.$name -cne $expectedUnavailable) { throw "lightweight unavailable_measurements value mismatch: $name" }
    }
}
$destinationDirectory = Join-Path (Join-Path $evidenceRootFull $RunId) "level-$Level"
if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) { New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null }
if (((Get-Item -LiteralPath $destinationDirectory).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'deterministic evidence destination may not be a reparse point' }
$destination = Join-Path $destinationDirectory $exactName
$sidecar = "$destination.sha256"
$playerEvidence = Join-Path $destinationDirectory 'player-evidence.tsv'
$playerSidecar = "$playerEvidence.sha256"
if ((Test-Path -LiteralPath $destination) -or (Test-Path -LiteralPath $sidecar) -or (Test-Path -LiteralPath $playerEvidence) -or (Test-Path -LiteralPath $playerSidecar)) { throw 'browser observation import already exists for this run/level' }
$sourceHasher = [Security.Cryptography.SHA256]::Create()
try { $digest = ([BitConverter]::ToString($sourceHasher.ComputeHash($sourceBytes)) -replace '-', '').ToLowerInvariant() } finally { $sourceHasher.Dispose() }
$destinationStream = $null
try {
    $destinationStream = New-Object IO.FileStream($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $destinationStream.Write($sourceBytes, 0, $sourceBytes.Length)
    $destinationStream.Flush($true)
} finally {
    if ($null -ne $destinationStream) { $destinationStream.Dispose() }
}
[IO.File]::WriteAllText($sidecar, "$digest  $exactName`n", (New-Object Text.UTF8Encoding($false)))
$durationSeconds = ([decimal]$document.duration_ms / 1000).ToString([Globalization.CultureInfo]::InvariantCulture)
if ($Level -eq 1) {
    $framesPresented = [string]$document.frames_observed
    $rxToCanvasP95 = ([double]$document.presentation_rx_to_canvas_p95_ms).ToString('R', [Globalization.CultureInfo]::InvariantCulture)
    $g2gStatus = [string]$document.g2g_measurement_status
    $g2gP95 = if ($g2gStatus -ceq 'measured') { ([double]$document.g2g_p95_ms).ToString('R', [Globalization.CultureInfo]::InvariantCulture) } else { 'not_available' }
    $wifiStatus = [string]$document.wifi_recovery_status
    $wifiArmed = 'true'; $wifiLoss = 'true'; $wifiRecovered = 'true'
    $wifiMs = [string]$document.wifi_recovery_ms; $wifiProvenance = [string]$document.wifi_recovery_provenance
} else {
    $framesPresented = 'not_available'; $rxToCanvasP95 = 'not_available'; $g2gStatus = 'not_available'; $g2gP95 = 'not_available'
    $wifiStatus = 'not_available'; $wifiArmed = 'not_available'; $wifiLoss = 'not_available'; $wifiRecovered = 'not_available'
    $wifiMs = 'not_available'; $wifiProvenance = 'not_available'
}
$rows = [ordered]@{
    schema_version = '1'; collector_id = 'teremoq-lan-player-v1'
    evidence_origin = 'local-browser-observation-user-exported'; browser_observation_sha256 = $digest
    run_id = $RunId; source_commit = $version.source_commit; level = [string]$Level
    started_at_utc = [string]$document.started_at_utc; ended_at_utc = [string]$document.ended_at_utc
    duration_seconds = $durationSeconds; requested_sessions = [string]$document.requested_sessions
    active_sessions_peak = [string]$document.active_sessions_peak; frames_presented = $framesPresented
    media_objects_received = [string]$document.objects_observed; media_bytes_received = [string]$document.bytes_observed
    rx_to_canvas_p95_ms = $rxToCanvasP95; g2g_measurement_status = $g2gStatus; glass_to_glass_p95_ms = $g2gP95
    session_loss_count = [string]$document.session_losses; session_recovery_count = [string]$document.session_recoveries
    wifi_recovery_status = $wifiStatus; wifi_recovery_armed = $wifiArmed; wifi_loss_observed = $wifiLoss
    wifi_recovery_observed = $wifiRecovered; wifi_recovery_ms = $wifiMs; wifi_recovery_provenance = $wifiProvenance
    evidence_quality = 'real'
}
$lines = foreach ($item in $rows.GetEnumerator()) { "$($item.Key)`t$($item.Value)" }
[IO.File]::WriteAllText($playerEvidence, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
$playerDigest = (Get-FileHash -LiteralPath $playerEvidence -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($playerSidecar, "$playerDigest  player-evidence.tsv`n", (New-Object Text.UTF8Encoding($false)))
Write-Output 'Browser observation validated and converted to hash-bound composite player evidence; this user export is not a cryptographic attestation.'
} finally {
    if ($null -ne $sourceStream) { $sourceStream.Dispose() }
}
