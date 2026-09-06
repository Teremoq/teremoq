# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0

$script:TeremoqLanUpdaterVersion = '2.0.0'
$script:TeremoqLanUpdaterProtocol = 'teremoq-lan-updater-v3'
$script:TeremoqLanConfigSchemaVersion = 1

function Get-TeremoqLanUpdaterVersion {
    return $script:TeremoqLanUpdaterVersion
}

function Get-TeremoqLanPlayerIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$SourceTree,
        [Parameter(Mandatory = $true)][string]$PackageLockSha256
    )
    if ($SourceTree -cnotmatch '^[0-9a-f]{40}$' -or $PackageLockSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'player identity inputs are outside policy'
    }
    $canonical = "schema_version=1`nsource_tree=$SourceTree`npackage_lock_sha256=$PackageLockSha256`n"
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::ASCII.GetBytes($canonical)
        $hex = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
        return "sha256:$hex"
    } finally { $sha.Dispose() }
}

function Get-TeremoqLanClientLayout {
    param([Parameter(Mandatory = $true)][string]$StateRoot)

    $root = [IO.Path]::GetFullPath($StateRoot).TrimEnd('\', '/')
    if ([string]::IsNullOrWhiteSpace($root)) { throw 'LAN client state root is invalid' }
    return [pscustomobject]@{
        StateRoot = $root
        ConfigRoot = Join-Path $root 'config'
        PlayersRoot = Join-Path $root 'players'
        VersionsRoot = Join-Path $root 'versions'
        ControlRoot = Join-Path $root 'control'
        ActivePointer = Join-Path $root 'control\active.json'
        CandidatePointer = Join-Path $root 'control\candidate.json'
        RollbackPointer = Join-Path $root 'control\rollback.json'
    }
}

function Initialize-TeremoqLanClientLayout {
    param([Parameter(Mandatory = $true)][string]$StateRoot)

    $layout = Get-TeremoqLanClientLayout -StateRoot $StateRoot
    foreach ($path in @($layout.StateRoot, $layout.ConfigRoot, $layout.PlayersRoot, $layout.VersionsRoot, $layout.ControlRoot)) {
        if (-not (Test-Path -LiteralPath $path)) { [void][IO.Directory]::CreateDirectory($path) }
        [void](Get-TeremoqNonReparseDirectoryPath -Path $path)
    }
    return $layout
}

function Invoke-TeremoqLanClientStateLocked {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    $layout = Initialize-TeremoqLanClientLayout -StateRoot $StateRoot
    $lockPath = Join-Path $layout.ControlRoot 'update.lock'
    if (Test-Path -LiteralPath $lockPath) { [void](Assert-TeremoqNonReparseFilePath -Path $lockPath) }
    try {
        $lock = New-Object IO.FileStream($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch {
        throw 'another LAN client state operation is active'
    }
    try {
        Repair-TeremoqLanControlDirectory -Layout $layout
        return & $Action $layout
    } finally {
        $lock.Dispose()
    }
}

function Repair-TeremoqLanControlDirectory {
    param([Parameter(Mandatory = $true)]$Layout)

    foreach ($item in @(Get-ChildItem -LiteralPath $Layout.ControlRoot -Force)) {
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'LAN client control directory contains a non-regular entry'
        }
        if ($item.Name -in @('active.json','candidate.json','rollback.json','update.lock')) { continue }
        if ($item.Name -notmatch '^\.(write|backup)-[0-9a-f]{32}[.]tmp$' -or $item.Length -gt 4096) {
            throw 'LAN client control directory contains an unexpected entry'
        }
        Remove-Item -LiteralPath $item.FullName -Force
    }
}

function New-TeremoqLanSlotRecord {
    param(
        [Parameter(Mandatory = $true)][string]$UpdaterCommit,
        [Parameter(Mandatory = $true)][string]$PlayerIdentity,
        [Parameter(Mandatory = $true)][string]$SourceTree,
        [Parameter(Mandatory = $true)][string]$PackageLockSha256,
        [Parameter(Mandatory = $true)][string]$PlayerManifestSha256,
        [Parameter(Mandatory = $true)][string]$LauncherContractSha256,
        [Parameter(Mandatory = $true)][string]$ConfigSha256
    )

    if ($UpdaterCommit -cnotmatch '^[0-9a-f]{40}$' -or
        $PlayerIdentity -cnotmatch '^sha256:[0-9a-f]{64}$' -or
        $SourceTree -cnotmatch '^[0-9a-f]{40}$' -or
        $PackageLockSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $PlayerManifestSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $LauncherContractSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $ConfigSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'LAN client slot identity is outside the closed policy'
    }
    $identityHex = $PlayerIdentity.Substring(7)
    $slotId = "u-${UpdaterCommit}-p-${identityHex}"
    return [pscustomobject][ordered]@{
        schema_version = 1
        updater_version = $script:TeremoqLanUpdaterVersion
        updater_protocol = $script:TeremoqLanUpdaterProtocol
        updater_commit = $UpdaterCommit
        player_identity = $PlayerIdentity
        source_tree = $SourceTree
        package_lock_sha256 = $PackageLockSha256
        player_manifest_sha256 = $PlayerManifestSha256
        launcher_contract_sha256 = $LauncherContractSha256
        config_schema_version = $script:TeremoqLanConfigSchemaVersion
        config_sha256 = $ConfigSha256
        slot_id = $slotId
        player_relative_path = "players/sha256-${identityHex}"
        version_relative_path = "versions/${slotId}"
    }
}

function ConvertTo-TeremoqLanSlotJson {
    param([Parameter(Mandatory = $true)]$Record)
    Assert-TeremoqLanSlotRecord -Record $Record
    return ($Record | ConvertTo-Json -Compress) + "`n"
}

function Assert-TeremoqLanSlotRecord {
    param([Parameter(Mandatory = $true)]$Record)

    $allowed = @(
        'schema_version','updater_version','updater_protocol','updater_commit',
        'player_identity','source_tree','package_lock_sha256','player_manifest_sha256',
        'launcher_contract_sha256','config_schema_version','config_sha256','slot_id',
        'player_relative_path','version_relative_path'
    )
    $keys = @($Record.PSObject.Properties.Name)
    if ($keys.Count -ne $allowed.Count -or @($keys | Where-Object { $allowed -cnotcontains $_ }).Count -ne 0) {
        throw 'LAN client slot record is not a closed object'
    }
    if ($Record.schema_version -ne 1 -or
        $Record.updater_version -cne $script:TeremoqLanUpdaterVersion -or
        $Record.updater_protocol -cne $script:TeremoqLanUpdaterProtocol -or
        $Record.updater_commit -cnotmatch '^[0-9a-f]{40}$' -or
        $Record.player_identity -cnotmatch '^sha256:[0-9a-f]{64}$' -or
        $Record.source_tree -cnotmatch '^[0-9a-f]{40}$' -or
        $Record.package_lock_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $Record.player_manifest_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $Record.launcher_contract_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $Record.config_schema_version -ne $script:TeremoqLanConfigSchemaVersion -or
        $Record.config_sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'LAN client slot record values are outside policy'
    }
    if ($Record.player_identity -cne (Get-TeremoqLanPlayerIdentity -SourceTree $Record.source_tree `
            -PackageLockSha256 $Record.package_lock_sha256)) {
        throw 'LAN client player identity does not match source tree and lockfile'
    }
    $identityHex = $Record.player_identity.Substring(7)
    $expectedSlot = "u-$($Record.updater_commit)-p-${identityHex}"
    if ($Record.slot_id -cne $expectedSlot -or
        $Record.player_relative_path -cne "players/sha256-${identityHex}" -or
        $Record.version_relative_path -cne "versions/${expectedSlot}") {
        throw 'LAN client slot paths do not match updater/player identities'
    }
}

function Read-TeremoqLanSlotPointer {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AllowMissing
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        if ($AllowMissing) { return $null }
        throw 'LAN client slot pointer is absent'
    }
    $path = Assert-TeremoqNonReparseFilePath -Path $Path
    $text = Read-TeremoqBoundedUtf8File -Path $path -MaxBytes 4096
    try { $record = $text | ConvertFrom-Json } catch { throw 'LAN client slot pointer is not valid JSON' }
    Assert-TeremoqLanSlotRecord -Record $record
    if ($text -cne (ConvertTo-TeremoqLanSlotJson -Record $record)) {
        throw 'LAN client slot pointer is not canonical JSON'
    }
    return $record
}

function Write-TeremoqAtomicUtf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $parent = Get-TeremoqNonReparseDirectoryPath -Path (Split-Path -Parent ([IO.Path]::GetFullPath($Path)))
    $target = [IO.Path]::GetFullPath($Path)
    if (-not $target.StartsWith($parent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'atomic state target escapes its control directory'
    }
    if (Test-Path -LiteralPath $target) { [void](Assert-TeremoqNonReparseFilePath -Path $target) }
    $temporary = Join-Path $parent ('.write-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $bytes = (New-Object Text.UTF8Encoding($false, $true)).GetBytes($Content)
    $stream = New-Object IO.FileStream($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $backup = $null
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
    try {
        if (Test-Path -LiteralPath $target) {
            $backup = Join-Path $parent ('.backup-' + [Guid]::NewGuid().ToString('N') + '.tmp')
            [IO.File]::Replace($temporary, $target, $backup, $true)
            Remove-Item -LiteralPath $backup -Force
        } else {
            [IO.File]::Move($temporary, $target)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        if ($backup -and (Test-Path -LiteralPath $backup)) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
    }
}

function Write-TeremoqLanSlotPointer {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Record
    )
    Write-TeremoqAtomicUtf8File -Path $Path -Content (ConvertTo-TeremoqLanSlotJson -Record $Record)
}

function Assert-TeremoqLanSlotMaterial {
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)]$Record
    )

    Assert-TeremoqLanSlotRecord -Record $Record
    $versionRoot = [IO.Path]::GetFullPath((Join-Path $Layout.StateRoot $Record.version_relative_path))
    $playerRoot = [IO.Path]::GetFullPath((Join-Path $Layout.StateRoot $Record.player_relative_path))
    foreach ($pair in @(@($versionRoot, $Layout.VersionsRoot), @($playerRoot, $Layout.PlayersRoot))) {
        if (-not $pair[0].StartsWith($pair[1] + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'LAN client slot material escapes its bounded root'
        }
        [void](Get-TeremoqNonReparseDirectoryPath -Path $pair[0])
    }
    foreach ($required in @(
        (Join-Path $versionRoot 'VERSION.tsv'),
        (Join-Path $versionRoot 'CLIENT-COMPATIBILITY.tsv'),
        (Join-Path $playerRoot 'MANIFEST.sha256.json'),
        (Join-Path $playerRoot 'lan-launcher.tsv'),
        (Join-Path $Layout.ConfigRoot 'LAN-CONFIG.json'),
        (Join-Path $Layout.ConfigRoot 'public-identity\relay-cert.sha256')
    )) {
        [void](Assert-TeremoqNonReparseFilePath -Path $required)
    }
    if ((Get-TeremoqBoundedFileSha256 -Path (Join-Path $playerRoot 'MANIFEST.sha256.json') -MaxBytes 1048576) -cne $Record.player_manifest_sha256 -or
        (Get-TeremoqBoundedFileSha256 -Path (Join-Path $playerRoot 'lan-launcher.tsv') -MaxBytes 4096) -cne $Record.launcher_contract_sha256 -or
        (Get-TeremoqBoundedFileSha256 -Path (Join-Path $Layout.ConfigRoot 'LAN-CONFIG.json') -MaxBytes 4096) -cne $Record.config_sha256) {
        throw 'LAN client slot material differs from its sealed hashes'
    }
    return [pscustomobject]@{ VersionRoot = $versionRoot; PlayerRoot = $playerRoot }
}

function Stage-TeremoqLanClientSlot {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)]$Record
    )

    return Invoke-TeremoqLanClientStateLocked -StateRoot $StateRoot -Action {
        param($layout)
        [void](Assert-TeremoqLanSlotMaterial -Layout $layout -Record $Record)
        $active = Read-TeremoqLanSlotPointer -Path $layout.ActivePointer -AllowMissing
        if ($null -ne $active -and $active.slot_id -ceq $Record.slot_id) {
            [void](Assert-TeremoqLanSlotMaterial -Layout $layout -Record $active)
            return [pscustomobject]@{ Status = 'already-active'; Record = $active }
        }
        $existing = Read-TeremoqLanSlotPointer -Path $layout.CandidatePointer -AllowMissing
        if ($null -ne $existing -and $existing.slot_id -cne $Record.slot_id) {
            throw 'another LAN client candidate is already staged'
        }
        Write-TeremoqLanSlotPointer -Path $layout.CandidatePointer -Record $Record
        return [pscustomobject]@{ Status = 'staged'; Record = $Record }
    }
}

function Activate-TeremoqLanClientSlot {
    param([Parameter(Mandatory = $true)][string]$StateRoot)

    return Invoke-TeremoqLanClientStateLocked -StateRoot $StateRoot -Action {
        param($layout)
        $candidate = Read-TeremoqLanSlotPointer -Path $layout.CandidatePointer
        [void](Assert-TeremoqLanSlotMaterial -Layout $layout -Record $candidate)
        $active = Read-TeremoqLanSlotPointer -Path $layout.ActivePointer -AllowMissing
        if ($null -ne $active -and $active.slot_id -ceq $candidate.slot_id) {
            return [pscustomobject]@{ Status = 'already-active'; Record = $active }
        }
        if ($null -ne $active) {
            [void](Assert-TeremoqLanSlotMaterial -Layout $layout -Record $active)
            Write-TeremoqLanSlotPointer -Path $layout.RollbackPointer -Record $active
        } elseif (Test-Path -LiteralPath $layout.RollbackPointer) {
            throw 'rollback pointer exists without an active version'
        }
        Write-TeremoqLanSlotPointer -Path $layout.ActivePointer -Record $candidate
        return [pscustomobject]@{ Status = 'activated-pending-health'; Record = $candidate }
    }
}

function Rollback-TeremoqLanClientSlot {
    param([Parameter(Mandatory = $true)][string]$StateRoot)

    return Invoke-TeremoqLanClientStateLocked -StateRoot $StateRoot -Action {
        param($layout)
        $active = Read-TeremoqLanSlotPointer -Path $layout.ActivePointer -AllowMissing
        $rollback = Read-TeremoqLanSlotPointer -Path $layout.RollbackPointer -AllowMissing
        if ($null -eq $rollback) {
            if ($null -ne $active -and (Test-Path -LiteralPath $layout.CandidatePointer)) {
                Remove-Item -LiteralPath $layout.ActivePointer -Force
                Remove-Item -LiteralPath $layout.CandidatePointer -Force
                Remove-TeremoqLanClientRecordMaterial -Layout $layout -Record $active
                return [pscustomobject]@{ Status = 'initial-candidate-deactivated'; Record = $active }
            }
            throw 'no previous LAN client version is available for rollback'
        }
        [void](Assert-TeremoqLanSlotMaterial -Layout $layout -Record $rollback)
        Write-TeremoqLanSlotPointer -Path $layout.ActivePointer -Record $rollback
        Remove-Item -LiteralPath $layout.RollbackPointer -Force
        if (Test-Path -LiteralPath $layout.CandidatePointer) { Remove-Item -LiteralPath $layout.CandidatePointer -Force }
        Remove-TeremoqObsoleteLanClientSlots -Layout $layout -ActiveRecord $rollback
        return [pscustomobject]@{ Status = 'rolled-back'; Record = $rollback; FailedRecord = $active }
    }
}

function Confirm-TeremoqLanClientSlot {
    param([Parameter(Mandatory = $true)][string]$StateRoot)

    return Invoke-TeremoqLanClientStateLocked -StateRoot $StateRoot -Action {
        param($layout)
        $active = Read-TeremoqLanSlotPointer -Path $layout.ActivePointer
        $candidate = Read-TeremoqLanSlotPointer -Path $layout.CandidatePointer -AllowMissing
        if ($null -ne $candidate -and $candidate.slot_id -cne $active.slot_id) {
            throw 'active and candidate LAN client slots differ during confirmation'
        }
        [void](Assert-TeremoqLanSlotMaterial -Layout $layout -Record $active)
        foreach ($pointer in @($layout.CandidatePointer, $layout.RollbackPointer)) {
            if (Test-Path -LiteralPath $pointer) { Remove-Item -LiteralPath $pointer -Force }
        }
        Remove-TeremoqObsoleteLanClientSlots -Layout $layout -ActiveRecord $active
        return [pscustomobject]@{ Status = 'confirmed'; Record = $active }
    }
}

function Remove-TeremoqObsoleteLanClientSlots {
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)]$ActiveRecord
    )

    [void](Assert-TeremoqLanSlotMaterial -Layout $Layout -Record $ActiveRecord)
    foreach ($directory in @(Get-ChildItem -LiteralPath $Layout.VersionsRoot -Directory -Force)) {
        if ($directory.Name -cne $ActiveRecord.slot_id) {
            Remove-TeremoqBoundedRegularTree -Path $directory.FullName -ExpectedParent $Layout.VersionsRoot
        }
    }
    # Verified player generations are content-addressed caches. Keeping them lets a
    # later updater reuse the exact artifact without rebuilding or touching config.
}

function Remove-TeremoqLanClientRecordMaterial {
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)]$Record
    )
    Assert-TeremoqLanSlotRecord -Record $Record
    $versionRoot = [IO.Path]::GetFullPath((Join-Path $Layout.StateRoot $Record.version_relative_path))
    $playerRoot = [IO.Path]::GetFullPath((Join-Path $Layout.StateRoot $Record.player_relative_path))
    if (Test-Path -LiteralPath $versionRoot) {
        Remove-TeremoqBoundedRegularTree -Path $versionRoot -ExpectedParent $Layout.VersionsRoot
    }
    # A failed candidate may be caused by transient LAN health rather than corrupt
    # bytes. The sealed, content-addressed player remains reusable but inactive.
}

function Remove-TeremoqBoundedRegularTree {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedParent
    )
    $parent = Get-TeremoqNonReparseDirectoryPath -Path $ExpectedParent
    $root = Get-TeremoqNonReparseDirectoryPath -Path $Path
    if ((Split-Path -Parent $root) -cne $parent) { throw 'cleanup target is not a direct child of its bounded root' }
    $items = @(Get-ChildItem -LiteralPath $root -Recurse -Force)
    if ($items.Count -gt 20000 -or @($items | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -ne 0) {
        throw 'cleanup target contains excessive or reparse-point content'
    }
    Remove-Item -LiteralPath $root -Recurse -Force
}

function Get-TeremoqActiveLanClientSlot {
    param([Parameter(Mandatory = $true)][string]$StateRoot)
    return Invoke-TeremoqLanClientStateLocked -StateRoot $StateRoot -Action {
        param($layout)
        $active = Read-TeremoqLanSlotPointer -Path $layout.ActivePointer
        $material = Assert-TeremoqLanSlotMaterial -Layout $layout -Record $active
        return [pscustomobject]@{ Layout = $layout; Record = $active; VersionRoot = $material.VersionRoot; PlayerRoot = $material.PlayerRoot }
    }
}
