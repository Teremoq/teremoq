# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$PackageRoot,
    [Parameter(Mandatory = $true)][string]$EvidenceRoot,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][ValidateSet(1, 5, 10, 25)][int]$Level
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$exactName = 'local-browser-observation-user-exported.json'
if ($RunId -notmatch '^lan-[a-z0-9][a-z0-9-]{0,31}$') { throw 'invalid RunId' }
$source = [IO.Path]::GetFullPath($SourcePath)
if ([IO.Path]::GetFileName($source) -cne $exactName -or -not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "browser export must have the exact name $exactName" }
$sourceItem = Get-Item -LiteralPath $source
if (($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $sourceItem.Length -lt 2 -or $sourceItem.Length -gt 65536) { throw 'browser export is unsafe or outside its byte limit' }
$package = [IO.Path]::GetFullPath($PackageRoot)
$evidenceRootFull = [IO.Path]::GetFullPath($EvidenceRoot)
foreach ($directory in @($package, $evidenceRootFull)) {
    if (-not (Test-Path -LiteralPath $directory -PathType Container) -or ((Get-Item -LiteralPath $directory).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'package/evidence roots must be existing non-reparse directories' }
}
$version = @{}
foreach ($line in Get-Content -LiteralPath (Join-Path $package 'VERSION.tsv')) {
    $fields = $line -split "`t", 3
    if ($fields.Count -eq 2 -and -not $version.ContainsKey($fields[0])) { $version[$fields[0]] = $fields[1] }
}
$lanConfigPath = Join-Path $package 'LAN-CONFIG.json'
if (-not (Test-Path -LiteralPath $lanConfigPath -PathType Leaf) -or (Get-Item -LiteralPath $lanConfigPath).Length -gt 512 -or
    (Get-FileHash -LiteralPath $lanConfigPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $version.lan_config_sha256) { throw 'package LAN configuration is absent or not bound by VERSION.tsv' }
if (((Get-Item -LiteralPath $lanConfigPath).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'package LAN configuration may not be a symlink/reparse point' }
$lanConfig = Get-Content -LiteralPath $lanConfigPath -Raw | ConvertFrom-Json
$lanConfigKeys = @($lanConfig.PSObject.Properties.Name)
if ($lanConfigKeys.Count -ne 7 -or @($lanConfigKeys | Where-Object { @('schema_version', 'run_id', 'source_commit', 'relay_url', 'fingerprint_sha256', 'prefix_length', 'namespace') -notcontains $_ }).Count -ne 0 -or
    $lanConfig.schema_version -ne 1 -or $lanConfig.run_id -ne $version.run_id -or $lanConfig.source_commit -ne $version.source_commit -or
    $lanConfig.namespace -isnot [string] -or $lanConfig.namespace.Length -gt 256 -or
    $lanConfig.namespace -notmatch '^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$' -or
    @($lanConfig.namespace.Split('/') | Where-Object { $_ -in @('.', '..') }).Count -ne 0) { throw 'LAN configuration closed schema/run/commit/namespace binding mismatch' }
$document = Get-Content -LiteralPath $source -Raw | ConvertFrom-Json
$allowed = @('schema_version', 'export_kind', 'run_id', 'source_commit', 'level', 'started_at_utc', 'ended_at_utc', 'duration_seconds', 'requested_sessions', 'active_sessions_peak', 'frames_presented', 'media_objects_received', 'rx_to_canvas_samples', 'rx_to_canvas_p95_ms', 'visual_timecode_valid', 'glass_to_glass_p95_ms', 'session_loss_count', 'reconnect_count', 'wifi_recovery_ms')
$keys = @($document.PSObject.Properties.Name)
if ($keys.Count -ne $allowed.Count -or @($keys | Where-Object { $allowed -notcontains $_ }).Count -ne 0) { throw 'browser observation JSON schema is not closed' }
if ($document.schema_version -ne 1 -or $document.export_kind -ne 'local-browser-observation-user-exported' -or $document.run_id -ne $RunId -or
    $document.source_commit -ne $version.source_commit -or [int]$document.level -ne $Level -or
    $document.requested_sessions -ne $Level -or $document.active_sessions_peak -ne $Level -or
    $document.visual_timecode_valid -isnot [bool]) { throw 'browser observation identity/run binding is outside policy' }
foreach ($name in @('requested_sessions', 'active_sessions_peak', 'media_objects_received', 'session_loss_count', 'reconnect_count')) {
    if ([string]$document.$name -notmatch '^(0|[1-9][0-9]*)$') { throw "browser observation count is not an integer: $name" }
}
if ([string]$document.duration_seconds -notmatch '^[0-9]+([.][0-9]+)?$') { throw 'browser observation duration is not measured' }
foreach ($name in @('glass_to_glass_p95_ms', 'wifi_recovery_ms')) {
    if ([string]$document.$name -ne 'not_measured' -and [string]$document.$name -notmatch '^[0-9]+([.][0-9]+)?$') { throw "invalid browser observation field: $name" }
}
if ([double]$document.duration_seconds -lt 600 -or [long]$document.media_objects_received -le 0) { throw 'browser observation lacks the minimum real duration/media objects' }
if ($Level -eq 1) {
    foreach ($name in @('frames_presented', 'rx_to_canvas_samples')) {
        if ([string]$document.$name -notmatch '^[1-9][0-9]*$') { throw "level 1 requires positive integer browser field: $name" }
    }
    if ([string]$document.rx_to_canvas_p95_ms -notmatch '^[0-9]+([.][0-9]+)?$') { throw 'level 1 requires measured RX-to-canvas p95' }
} elseif ([string]$document.frames_presented -ne 'not_available' -or [string]$document.rx_to_canvas_samples -ne 'not_available' -or [string]$document.rx_to_canvas_p95_ms -ne 'not_available') {
    throw 'lightweight session observations must mark all render metrics not_available'
}
$started = [DateTimeOffset]::MinValue
$ended = [DateTimeOffset]::MinValue
$startedValid = [DateTimeOffset]::TryParse([string]$document.started_at_utc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$started)
$endedValid = [DateTimeOffset]::TryParse([string]$document.ended_at_utc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$ended)
if (-not $startedValid -or -not $endedValid -or -not ([string]$document.started_at_utc).EndsWith('Z') -or -not ([string]$document.ended_at_utc).EndsWith('Z') -or $ended -lt $started -or
    [math]::Abs(($ended - $started).TotalSeconds - [double]$document.duration_seconds) -gt 5) { throw 'browser observation UTC timestamps are invalid or incoherent with duration' }
if (-not [bool]$document.visual_timecode_valid -and [string]$document.glass_to_glass_p95_ms -ne 'not_measured') { throw 'glass-to-glass requires valid visual timecode' }
if ($Level -eq 1 -and [string]$document.wifi_recovery_ms -notmatch '^[0-9]+([.][0-9]+)?$') { throw 'level 1 requires measured manual Wi-Fi recovery' }
$destinationDirectory = Join-Path (Join-Path $evidenceRootFull $RunId) "level-$Level"
if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) { New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null }
if (((Get-Item -LiteralPath $destinationDirectory).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'deterministic evidence destination may not be a reparse point' }
$destination = Join-Path $destinationDirectory $exactName
$sidecar = "$destination.sha256"
$playerEvidence = Join-Path $destinationDirectory 'player-evidence.tsv'
$playerSidecar = "$playerEvidence.sha256"
if ((Test-Path -LiteralPath $destination) -or (Test-Path -LiteralPath $sidecar) -or (Test-Path -LiteralPath $playerEvidence) -or (Test-Path -LiteralPath $playerSidecar)) { throw 'browser observation import already exists for this run/level' }
[IO.File]::Copy($source, $destination, $false)
$digest = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($sidecar, "$digest  $exactName`n", (New-Object Text.UTF8Encoding($false)))
$rows = [ordered]@{
    schema_version = '1'; collector_id = 'teremoq-lan-player-v1'
    evidence_origin = 'local-browser-observation-user-exported'; browser_observation_sha256 = $digest
    run_id = $RunId; source_commit = $version.source_commit; level = [string]$Level
    started_at_utc = [string]$document.started_at_utc; ended_at_utc = [string]$document.ended_at_utc
    duration_seconds = [string]$document.duration_seconds; requested_sessions = [string]$document.requested_sessions
    active_sessions_peak = [string]$document.active_sessions_peak; frames_presented = [string]$document.frames_presented
    media_objects_received = [string]$document.media_objects_received; rx_to_canvas_samples = [string]$document.rx_to_canvas_samples
    rx_to_canvas_p95_ms = [string]$document.rx_to_canvas_p95_ms
    visual_timecode_valid = ([string]$document.visual_timecode_valid).ToLowerInvariant()
    glass_to_glass_p95_ms = [string]$document.glass_to_glass_p95_ms
    session_loss_count = [string]$document.session_loss_count; reconnect_count = [string]$document.reconnect_count
    wifi_recovery_ms = [string]$document.wifi_recovery_ms; evidence_quality = 'real'
}
$lines = foreach ($item in $rows.GetEnumerator()) { "$($item.Key)`t$($item.Value)" }
[IO.File]::WriteAllText($playerEvidence, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
$playerDigest = (Get-FileHash -LiteralPath $playerEvidence -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($playerSidecar, "$playerDigest  player-evidence.tsv`n", (New-Object Text.UTF8Encoding($false)))
Write-Output 'Browser observation validated and converted to hash-bound composite player evidence; this user export is not a cryptographic attestation.'
