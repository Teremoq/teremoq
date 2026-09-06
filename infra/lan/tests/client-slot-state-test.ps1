# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot '..\client\Client-Distribution.ps1')
. (Join-Path $PSScriptRoot '..\client\Client-Slot-State.ps1')

$root = Join-Path ([IO.Path]::GetTempPath()) ('teremoq-lan-slots-' + [Guid]::NewGuid().ToString('N'))
$utf8 = New-Object Text.UTF8Encoding($false)
$hash = 'a' * 64

function New-FixtureSlot {
    param([string]$Commit, [string]$Tree, [string]$Lock)
    $layout = Initialize-TeremoqLanClientLayout -StateRoot $root
    if (-not (Test-Path -LiteralPath (Join-Path $layout.ConfigRoot 'public-identity'))) {
        [void][IO.Directory]::CreateDirectory((Join-Path $layout.ConfigRoot 'public-identity'))
        [IO.File]::WriteAllText((Join-Path $layout.ConfigRoot 'LAN-CONFIG.json'), "{}`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $layout.ConfigRoot 'public-identity\relay-cert.sha256'), "$hash`n", $utf8)
    }
    $configHash = Get-TeremoqBoundedFileSha256 -Path (Join-Path $layout.ConfigRoot 'LAN-CONFIG.json') -MaxBytes 4096
    $playerIdentity = Get-TeremoqLanPlayerIdentity -SourceTree $Tree -PackageLockSha256 $Lock
    $identityHex = $playerIdentity.Substring(7)
    $player = Join-Path $layout.PlayersRoot "sha256-${identityHex}"
    [void][IO.Directory]::CreateDirectory($player)
    [IO.File]::WriteAllText((Join-Path $player 'MANIFEST.sha256.json'), "{}`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $player 'lan-launcher.tsv'), "schema_version`t1`n", $utf8)
    $manifestHash = Get-TeremoqBoundedFileSha256 -Path (Join-Path $player 'MANIFEST.sha256.json') -MaxBytes 1048576
    $launcherHash = Get-TeremoqBoundedFileSha256 -Path (Join-Path $player 'lan-launcher.tsv') -MaxBytes 4096
    $record = New-TeremoqLanSlotRecord -UpdaterCommit $Commit -PlayerIdentity $playerIdentity `
        -SourceTree $Tree -PackageLockSha256 $Lock -PlayerManifestSha256 $manifestHash `
        -LauncherContractSha256 $launcherHash -ConfigSha256 $configHash
    $version = Join-Path $layout.StateRoot $record.version_relative_path
    [void][IO.Directory]::CreateDirectory($version)
    [IO.File]::WriteAllText((Join-Path $version 'VERSION.tsv'), "schema_version`t1`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $version 'CLIENT-COMPATIBILITY.tsv'), "schema_version`t1`n", $utf8)
    return $record
}

try {
    if ((Get-TeremoqLanPlayerIdentity -SourceTree ('0' * 40) -PackageLockSha256 ('0' * 64)) -cne
        'sha256:56b3f8b327b5f99e3aab0bddef08e467496f298c096eece81448d325978803f3') {
        throw 'PowerShell player identity differs from the canonical cross-language vector'
    }
    $first = New-FixtureSlot -Commit ('1' * 40) -Tree ('3' * 40) -Lock ('4' * 64)
    $configPath = Join-Path $root 'config\LAN-CONFIG.json'
    $configBefore = Get-TeremoqBoundedFileSha256 -Path $configPath -MaxBytes 4096
    if ((Stage-TeremoqLanClientSlot -StateRoot $root -Record $first).Status -cne 'staged') { throw 'initial stage failed' }
    if ((Activate-TeremoqLanClientSlot -StateRoot $root).Status -cne 'activated-pending-health') { throw 'initial activation failed' }
    if ((Confirm-TeremoqLanClientSlot -StateRoot $root).Status -cne 'confirmed') { throw 'initial confirmation failed' }

    $second = New-FixtureSlot -Commit ('5' * 40) -Tree ('7' * 40) -Lock ('8' * 64)
    [void](Stage-TeremoqLanClientSlot -StateRoot $root -Record $second)
    $candidatePath = Join-Path $root 'control\candidate.json'
    [IO.File]::WriteAllText($candidatePath, "{}`n", $utf8)
    try { Activate-TeremoqLanClientSlot -StateRoot $root | Out-Null; throw 'invalid candidate pointer was activated' }
    catch { if ($_.Exception.Message -match 'invalid candidate pointer was activated') { throw } }
    if ((Get-TeremoqActiveLanClientSlot -StateRoot $root).Record.slot_id -cne $first.slot_id) { throw 'failed activation changed the active pointer' }
    Write-TeremoqLanSlotPointer -Path $candidatePath -Record $second
    [void](Activate-TeremoqLanClientSlot -StateRoot $root)
    $active = Get-TeremoqActiveLanClientSlot -StateRoot $root
    if ($active.Record.slot_id -cne $second.slot_id) { throw 'candidate was not atomically selected' }
    $rolledBack = Rollback-TeremoqLanClientSlot -StateRoot $root
    if ($rolledBack.Record.slot_id -cne $first.slot_id) { throw 'rollback did not restore the previous slot' }
    if (Test-Path -LiteralPath (Join-Path $root $second.version_relative_path)) { throw 'rollback retained the failed version' }

    $second = New-FixtureSlot -Commit ('5' * 40) -Tree ('7' * 40) -Lock ('8' * 64)

    [void](Stage-TeremoqLanClientSlot -StateRoot $root -Record $second)
    [void](Activate-TeremoqLanClientSlot -StateRoot $root)
    [void](Confirm-TeremoqLanClientSlot -StateRoot $root)
    $active = Get-TeremoqActiveLanClientSlot -StateRoot $root
    if ($active.Record.slot_id -cne $second.slot_id) { throw 'updated slot was not confirmed' }
    if (Test-Path -LiteralPath (Join-Path $root $first.version_relative_path)) { throw 'obsolete version was not cleaned' }
    if (-not (Test-Path -LiteralPath (Join-Path $root $first.player_relative_path))) {
        throw 'verified player cache was removed during updater cleanup'
    }
    if ((Get-TeremoqBoundedFileSha256 -Path $configPath -MaxBytes 4096) -cne $configBefore) { throw 'local configuration changed during update' }
    if ((Test-Path -LiteralPath (Join-Path $root 'control\candidate.json')) -or
        (Test-Path -LiteralPath (Join-Path $root 'control\rollback.json'))) { throw 'confirmed state retained transient pointers' }

    $playerCacheCountBeforeUpdaterOnly = @(Get-ChildItem -LiteralPath (Join-Path $root 'players') -Directory).Count
    $third = New-FixtureSlot -Commit ('e' * 40) -Tree ('7' * 40) -Lock ('8' * 64)
    [void](Stage-TeremoqLanClientSlot -StateRoot $root -Record $third)
    [void](Activate-TeremoqLanClientSlot -StateRoot $root)
    [void](Confirm-TeremoqLanClientSlot -StateRoot $root)
    $active = Get-TeremoqActiveLanClientSlot -StateRoot $root
    if ($active.Record.slot_id -cne $third.slot_id -or $active.Record.player_identity -cne $second.player_identity) {
        throw 'updater-only update did not reuse the player identity'
    }
    if (@(Get-ChildItem -LiteralPath (Join-Path $root 'players') -Directory).Count -ne $playerCacheCountBeforeUpdaterOnly) {
        throw 'updater-only update duplicated the player generation'
    }
    if (Test-Path -LiteralPath (Join-Path $root $second.version_relative_path)) {
        throw 'updater-only update retained an obsolete updater version'
    }

    $lockPath = Join-Path $root 'control\update.lock'
    $heldLock = New-Object IO.FileStream($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        try { Get-TeremoqActiveLanClientSlot -StateRoot $root | Out-Null; throw 'concurrent state access was accepted' }
        catch { if ($_.Exception.Message -match 'concurrent state access was accepted') { throw } }
    } finally { $heldLock.Dispose() }

    $stale = Join-Path $root 'control\.write-11111111111111111111111111111111.tmp'
    [IO.File]::WriteAllText($stale, 'interrupted', $utf8)
    [void](Get-TeremoqActiveLanClientSlot -StateRoot $root)
    if (Test-Path -LiteralPath $stale) { throw 'interrupted atomic-write residue was not cleaned' }

    $unexpected = Join-Path $root 'control\unexpected.txt'
    [IO.File]::WriteAllText($unexpected, 'reject', $utf8)
    try { Get-TeremoqActiveLanClientSlot -StateRoot $root | Out-Null; throw 'unexpected control file was accepted' }
    catch { if ($_.Exception.Message -match 'unexpected control file was accepted') { throw } }
    Remove-Item -LiteralPath $unexpected -Force

    $tampered = New-FixtureSlot -Commit ('9' * 40) -Tree ('b' * 40) -Lock ('c' * 64)
    $tampered.config_sha256 = 'd' * 64
    try { Stage-TeremoqLanClientSlot -StateRoot $root -Record $tampered | Out-Null; throw 'tampered config was accepted' }
    catch { if ($_.Exception.Message -match 'tampered config was accepted') { throw } }

    Write-Output 'client slot state tests passed: reuse, update, atomic activation, rollback, updater cleanup, verified cache retention, config preservation, locking, interruption recovery, tamper rejection'
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
