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
    Assert-TeremoqNoAssistedTransition -StateRoot $layout.StateRoot
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

    Assert-TeremoqNoAssistedTransition -StateRoot $Layout.StateRoot

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
    try { $record = $text | ConvertFrom-TeremoqLanJson } catch { throw 'LAN client slot pointer is not valid JSON' }
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

function Reset-TeremoqLanUnconfirmedCandidate {
    param([Parameter(Mandatory = $true)][string]$StateRoot)

    return Invoke-TeremoqLanClientStateLocked -StateRoot $StateRoot -Action {
        param($layout)
        $active = Read-TeremoqLanSlotPointer -Path $layout.ActivePointer -AllowMissing
        $candidate = Read-TeremoqLanSlotPointer -Path $layout.CandidatePointer -AllowMissing
        $rollback = Read-TeremoqLanSlotPointer -Path $layout.RollbackPointer -AllowMissing

        foreach ($record in @($active, $candidate, $rollback)) {
            if ($null -ne $record) { [void](Assert-TeremoqLanSlotMaterial -Layout $layout -Record $record) }
        }

        if ($null -eq $candidate) {
            if ($null -ne $rollback) { throw 'rollback pointer exists without an unconfirmed candidate' }
            return [pscustomobject]@{ Status = 'clean'; Record = $active }
        }

        if ($null -ne $rollback) {
            if ($null -eq $active -or $rollback.slot_id -ceq $candidate.slot_id) {
                throw 'unconfirmed LAN client rollback state is ambiguous'
            }
            if ($active.slot_id -ceq $rollback.slot_id -and $active.slot_id -cne $candidate.slot_id) {
                Remove-Item -LiteralPath $layout.RollbackPointer -Force
                Remove-Item -LiteralPath $layout.CandidatePointer -Force
                Remove-TeremoqLanClientRecordMaterial -Layout $layout -Record $candidate
                return [pscustomobject]@{ Status = 'discarded-interrupted-stage'; Record = $candidate; ActiveRecord = $active }
            }
            if ($active.slot_id -cne $candidate.slot_id) {
                throw 'unconfirmed LAN client rollback state is ambiguous'
            }
            Write-TeremoqLanSlotPointer -Path $layout.ActivePointer -Record $rollback
            Remove-Item -LiteralPath $layout.RollbackPointer -Force
            Remove-Item -LiteralPath $layout.CandidatePointer -Force
            Remove-TeremoqLanClientRecordMaterial -Layout $layout -Record $candidate
            return [pscustomobject]@{ Status = 'rolled-back'; Record = $rollback; FailedRecord = $candidate }
        }

        if ($null -eq $active) {
            Remove-Item -LiteralPath $layout.CandidatePointer -Force
            Remove-TeremoqLanClientRecordMaterial -Layout $layout -Record $candidate
            return [pscustomobject]@{ Status = 'discarded-staged'; Record = $candidate }
        }

        if ($active.slot_id -ceq $candidate.slot_id) {
            Remove-Item -LiteralPath $layout.ActivePointer -Force
            Remove-Item -LiteralPath $layout.CandidatePointer -Force
            Remove-TeremoqLanClientRecordMaterial -Layout $layout -Record $candidate
            return [pscustomobject]@{ Status = 'initial-candidate-deactivated'; Record = $candidate }
        }

        Remove-Item -LiteralPath $layout.CandidatePointer -Force
        Remove-TeremoqLanClientRecordMaterial -Layout $layout -Record $candidate
        return [pscustomobject]@{ Status = 'discarded-staged'; Record = $candidate; ActiveRecord = $active }
    }
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

    Assert-TeremoqNoAssistedTransition -StateRoot $Layout.StateRoot
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
    Assert-TeremoqNoAssistedTransition -StateRoot $Layout.StateRoot
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
    param([Parameter(Mandatory = $true)][string]$StateRoot, [switch]$ReadOnly)
    if ($ReadOnly) {
        # Validation must not initialize, repair or clean the updater state.
        # Open the EXISTING operation lock read-only with FileShare.Read:
        # concurrent readers are allowed, writers/deletion are excluded.
        # An absent lock is not initialized here.
        $layout = Get-TeremoqLanClientLayout -StateRoot $StateRoot
        foreach ($path in @($layout.StateRoot, $layout.ConfigRoot, $layout.PlayersRoot, $layout.VersionsRoot, $layout.ControlRoot)) {
            [void](Get-TeremoqNonReparseDirectoryPath -Path $path)
        }
        $lock = Open-TeremoqVerifiedRegularFile -Path (Join-Path $layout.ControlRoot 'update.lock') -MaxBytes 4096
        try {
            if (Test-Path -LiteralPath (Join-Path $layout.StateRoot 'unconfirmed-transition')) {
                Assert-TeremoqAssistedTransitionReadable -StateRoot $layout.StateRoot
            }
            $entries = @(Get-ChildItem -LiteralPath $layout.ControlRoot -Force | Select-Object -First 5)
            if ($entries.Count -gt 4) { throw 'LAN client control directory requires explicit recovery' }
            foreach ($entry in $entries) {
                if ($entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    $entry.Name -cnotin @('active.json','candidate.json','rollback.json','update.lock')) {
                    throw 'LAN client control directory requires explicit recovery'
                }
            }
            $active = Read-TeremoqLanSlotPointer -Path $layout.ActivePointer
            $material = Assert-TeremoqLanSlotMaterial -Layout $layout -Record $active
            return [pscustomobject]@{ Layout = $layout; Record = $active; VersionRoot = $material.VersionRoot; PlayerRoot = $material.PlayerRoot }
        } finally { $lock.Dispose() }
    }
    return Invoke-TeremoqLanClientStateLocked -StateRoot $StateRoot -Action {
        param($layout)
        $active = Read-TeremoqLanSlotPointer -Path $layout.ActivePointer
        $material = Assert-TeremoqLanSlotMaterial -Layout $layout -Record $active
        return [pscustomobject]@{ Layout = $layout; Record = $active; VersionRoot = $material.VersionRoot; PlayerRoot = $material.PlayerRoot }
    }
}

# One assisted initial-candidate transition, not an autonomous recovery engine.
# The durable record lives OUTSIDE control: old temp-file repair must never
# interpret it as a disposable backup. It is deliberately never auto-removed.
function Assert-TeremoqNoAssistedTransition {
    param([Parameter(Mandatory = $true)][string]$StateRoot)
    if (Test-Path -LiteralPath (Join-Path $StateRoot 'unconfirmed-transition')) {
        throw 'assisted unconfirmed transition exists; automatic preparation, recovery and cleanup are prohibited'
    }
}

function Get-TeremoqTransitionTextHash {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash((New-Object Text.UTF8Encoding($false, $true)).GetBytes($Text))) -replace '-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Write-TeremoqTransitionCopy {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    $bytes = (New-Object Text.UTF8Encoding($false, $true)).GetBytes($Text)
    if ($bytes.Length -gt 1048576) { throw 'transition copy exceeds its bounded metadata limit' }
    [void](Get-TeremoqNonReparseDirectoryPath -Path (Split-Path -Parent $Path))
    if (-not (Test-Path -LiteralPath $Path)) {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    }
    if ((Read-TeremoqBoundedUtf8File -Path $Path -MaxBytes 1048576) -cne $Text) {
        throw 'transition snapshot conflict; preserve both states without overwriting evidence'
    }
}

function Get-TeremoqTransitionMaterialPaths {
    param([Parameter(Mandatory = $true)]$Layout, [Parameter(Mandatory = $true)]$Record)
    $material = Assert-TeremoqLanSlotMaterial -Layout $Layout -Record $Record
    return @(
        (Join-Path $material.VersionRoot 'VERSION.tsv'),
        (Join-Path $material.VersionRoot 'CLIENT-COMPATIBILITY.tsv'),
        (Join-Path $material.VersionRoot 'SHA256SUMS'),
        (Join-Path $material.PlayerRoot 'MANIFEST.sha256.json'),
        (Join-Path $material.PlayerRoot 'lan-launcher.tsv'),
        (Join-Path $Layout.ConfigRoot 'LAN-CONFIG.json'),
        (Join-Path $Layout.ConfigRoot 'public-identity\relay-cert.sha256')
    )
}

function Assert-TeremoqTransitionSlotTypes {
    param([Parameter(Mandatory = $true)]$Record)
    Assert-TeremoqLanSlotRecord -Record $Record
    foreach ($property in $Record.PSObject.Properties) {
        if ($property.Name -cin @('schema_version','config_schema_version')) {
            if (-not (Test-TeremoqClrInteger $property.Value) -or $property.Value -ne 1) { throw 'transition slot version must be an exact integer' }
        } elseif ($property.Value -isnot [string]) { throw 'transition slot fields must have exact string types' }
    }
}

function Read-TeremoqTransitionRecord {
    param([Parameter(Mandatory = $true)][string]$Directory)
    [void](Get-TeremoqNonReparseDirectoryPath -Path $Directory)
    Assert-TeremoqTransitionDirectory -Directory $Directory
    $text = Read-TeremoqBoundedUtf8File -Path (Join-Path $Directory 'binding.json') -MaxBytes 4096
    $record = $text | ConvertFrom-TeremoqLanJson
    $keys = @('schema_version','transition_id','source_sha256','target_sha256','target_commit','source_status','rollback_state')
    $actual = @($record.PSObject.Properties | ForEach-Object { $_.Name })
    if ($actual.Count -ne $keys.Count -or @($actual | Where-Object { $keys -cnotcontains $_ }).Count -ne 0 -or
        -not (Test-TeremoqClrInteger $record.schema_version) -or $record.schema_version -ne 1 -or
        $record.transition_id -isnot [string] -or $record.transition_id -cnotmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' -or
        $record.source_sha256 -isnot [string] -or $record.source_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $record.target_sha256 -isnot [string] -or $record.target_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $record.target_commit -isnot [string] -or $record.target_commit -cnotmatch '^[0-9a-f]{40}$' -or
        $record.source_status -isnot [string] -or $record.source_status -cne 'unconfirmed' -or
        $record.rollback_state -isnot [string] -or $record.rollback_state -cne 'absent' -or
        $text -cne (($record | ConvertTo-Json -Compress) + "`n")) {
        throw 'assisted transition binding is outside the closed canonical policy'
    }
    return $record
}

function Assert-TeremoqTransitionDirectory {
    param([Parameter(Mandatory = $true)][string]$Directory)
    Assert-TeremoqPrivateTransitionAcl -Path $Directory
    $entries = @(Get-ChildItem -LiteralPath $Directory -Force | Select-Object -First 33)
    if ($entries.Count -gt 32) { throw 'assisted transition directory exceeds its closed cardinality' }
    foreach ($entry in $entries) {
        if ($entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $entry.Length -gt 1048576 -or $entry.Name -cnotmatch '^(binding[.]json|source[.]json|target[.]json|phase[.]txt|(source|target)-[0-6][.]utf8|(active|candidate)-(source|target)[.]pointer|[.](write|backup)-[0-9a-f]{32}[.]tmp)$') {
            throw 'assisted transition directory contains unexpected evidence; preserve it without cleanup'
        }
        Assert-TeremoqPrivateTransitionAcl -Path $entry.FullName
    }
}

function Assert-TeremoqPrivateTransitionAcl {
    param([Parameter(Mandatory = $true)][string]$Path)
    $owner = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = Get-Acl -LiteralPath $Path
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $owner.Value) { throw 'transition evidence is not owned by the current operator' }
    foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $rule.IdentityReference.Value -cnotin @($owner.Value,'S-1-5-18','S-1-5-32-544')) {
            throw 'transition evidence has non-private access permissions'
        }
    }
}

function New-TeremoqPrivateTransitionDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        [void][IO.Directory]::CreateDirectory($Path)
        $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl=New-Object Security.AccessControl.DirectorySecurity
        $acl.SetOwner($owner)
        $acl.SetAccessRuleProtection($true,$false)
        foreach ($sid in @($owner.Value,'S-1-5-18','S-1-5-32-544')) {
            $identity=New-Object Security.Principal.SecurityIdentifier($sid)
            $rule=New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','ContainerInherit, ObjectInherit','None','Allow')
            [void]$acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $Path -AclObject $acl
    }
    [void](Get-TeremoqNonReparseDirectoryPath -Path $Path)
    Assert-TeremoqPrivateTransitionAcl -Path $Path
}

function Write-TeremoqRecoverablePointerCopy {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    # Only replacement scratch uses prefix recovery. Immutable snapshots keep
    # Write-TeremoqTransitionCopy's conflict policy. Caller holds update.lock
    # and binds these exact bytes to the sealed transition destination hash.
    $bytes = (New-Object Text.UTF8Encoding($false, $true)).GetBytes($Text)
    if ($bytes.Length -gt 4096) { throw 'replacement pointer exceeds its bound' }
    $expected = [IO.Path]::GetFullPath($Path)
    [void](Get-TeremoqNonReparseDirectoryPath -Path (Split-Path -Parent $expected))
    $mode = [IO.FileMode]::CreateNew
    if (Test-Path -LiteralPath $expected) {
        [void](Assert-TeremoqNonReparseFilePath -Path $expected)
        Assert-TeremoqPrivateTransitionAcl -Path $expected
        $mode = [IO.FileMode]::Open
    }
    $stream = [IO.File]::Open($expected, $mode, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $buffer = New-Object Text.StringBuilder 32768
        $n = [TeremoqLanNativeFile]::GetFinalPathNameByHandle($stream.SafeFileHandle, $buffer, [uint32]$buffer.Capacity, 0)
        if ($n -eq 0 -or $n -ge $buffer.Capacity) { throw 'replacement handle path unavailable' }
        $final = $buffer.ToString()
        if ($final.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) { $final = '\\' + $final.Substring(8) }
        elseif ($final.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) { $final = $final.Substring(4) }
        if (-not $final.Equals($expected, [StringComparison]::OrdinalIgnoreCase) -or $stream.SafeFileHandle.IsInvalid -or $stream.Length -gt $bytes.Length) {
            throw 'replacement scratch identity or length conflict'
        }
        $length = [int]$stream.Length
        for ($i = 0; $i -lt $length; $i++) {
            if ($stream.ReadByte() -ne $bytes[$i]) { throw 'replacement scratch prefix conflict; preserve without overwrite' }
        }
        # A cut after CreateNew, during Write, or before Flush leaves only a
        # bounded exact prefix. Resume by appending, never truncate/overwrite.
        $stream.Write($bytes, $length, $bytes.Length - $length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
    if ((Read-TeremoqBoundedUtf8File -Path $expected -MaxBytes 4096) -cne $Text) { throw 'replacement scratch did not verify' }
}

function Write-TeremoqTransitionPointer {
    param([Parameter(Mandatory = $true)]$Layout, [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][ValidateSet('active','candidate')][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('source','target')][string]$Destination,
        [Parameter(Mandatory = $true)]$Record)
    if ($Name -cnotin @('active','candidate') -or $Destination -cnotin @('source','target')) { throw 'transition pointer selector must be canonical' }
    # Replacement temporary stays outside control even if the process dies.
    # Original bytes have already been flushed in the immutable snapshot.
    $temporary = Join-Path $Directory ("$Name-$Destination.pointer")
    $path = if ($Name -ceq 'active') { $Layout.ActivePointer } else { $Layout.CandidatePointer }
    [void](Assert-TeremoqNonReparseFilePath -Path $path)
    $binding = Read-TeremoqTransitionRecord -Directory $Directory
    $text = ConvertTo-TeremoqLanSlotJson -Record $Record
    $destinationHash = if ($Destination -ceq 'source') { $binding.source_sha256 } else { $binding.target_sha256 }
    if ((Get-TeremoqTransitionTextHash -Text $text) -cne $destinationHash) { throw 'replacement differs from sealed transition destination' }
    Write-TeremoqRecoverablePointerCopy -Path $temporary -Text $text
    [IO.File]::Replace($temporary, $path, [NullString]::Value, $true)
    if ((Read-TeremoqBoundedUtf8File -Path $path -MaxBytes 4096) -cne (ConvertTo-TeremoqLanSlotJson -Record $Record)) {
        throw 'assisted pointer replacement did not verify'
    }
}

function Read-TeremoqTransitionPhase {
    param([Parameter(Mandatory = $true)][string]$Directory)
    $text = Read-TeremoqBoundedUtf8File -Path (Join-Path $Directory 'phase.txt') -MaxBytes 64
    $phases = @('sealed','applying-candidate','applying-active','pending-health','restoring-active','restoring-candidate','restored-unconfirmed')
    foreach ($phase in $phases) { if ($text -ceq ($phase + "`n")) { return $phase } }
    throw 'assisted transition phase is unknown; preserve state'
}

function Assert-TeremoqTransitionSnapshot {
    param([Parameter(Mandatory = $true)]$Layout, [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)]$Binding)
    $source = Read-TeremoqLanSlotPointer -Path (Join-Path $Directory 'source.json')
    $target = Read-TeremoqLanSlotPointer -Path (Join-Path $Directory 'target.json')
    Assert-TeremoqTransitionSlotTypes -Record $source
    Assert-TeremoqTransitionSlotTypes -Record $target
    if ((Get-TeremoqBoundedFileSha256 -Path (Join-Path $Directory 'source.json') -MaxBytes 4096) -cne $Binding.source_sha256 -or
        (Get-TeremoqBoundedFileSha256 -Path (Join-Path $Directory 'target.json') -MaxBytes 4096) -cne $Binding.target_sha256 -or
        $target.updater_commit -cne $Binding.target_commit -or $source.slot_id -ceq $target.slot_id -or
        $source.config_sha256 -cne $target.config_sha256) { throw 'transition source/target identity conflict' }
    foreach ($side in @('source','target')) {
        $slot = if ($side -ceq 'source') { $source } else { $target }
        $paths = @(Get-TeremoqTransitionMaterialPaths -Layout $Layout -Record $slot)
        for ($i = 0; $i -lt $paths.Count; $i++) {
            $copy = Join-Path $Directory ("$side-$i.utf8")
            $bound = if ($i -eq 3) { 1048576 } else { 4096 }
            if ((Get-TeremoqBoundedFileSha256 -Path $paths[$i] -MaxBytes $bound) -cne
                (Get-TeremoqBoundedFileSha256 -Path $copy -MaxBytes $bound)) {
                throw 'preserved transition material changed; do not overwrite or clean either version'
            }
        }
    }
    return [pscustomobject]@{ Source = $source; Target = $target }
}

function Assert-TeremoqTransitionPointers {
    param([Parameter(Mandatory = $true)]$Layout, [Parameter(Mandatory = $true)]$Binding,
        [Parameter(Mandatory = $true)][string]$Phase)
    if (Test-Path -LiteralPath $Layout.RollbackPointer) { throw 'transition rollback must remain absent; no healthy rollback may be fabricated' }
    $active = Get-TeremoqBoundedFileSha256 -Path $Layout.ActivePointer -MaxBytes 4096
    $candidate = Get-TeremoqBoundedFileSha256 -Path $Layout.CandidatePointer -MaxBytes 4096
    $s = $Binding.source_sha256; $t = $Binding.target_sha256
    $valid = switch ($Phase) {
        'sealed' { $active -ceq $s -and $candidate -ceq $s }
        'applying-candidate' { $active -ceq $s -and $candidate -cin @($s,$t) }
        'applying-active' { $active -cin @($s,$t) -and $candidate -ceq $t }
        'pending-health' { $active -ceq $t -and $candidate -ceq $t }
        'restoring-active' { $active -cin @($s,$t) -and $candidate -cin @($s,$t) }
        'restoring-candidate' { $active -ceq $s -and $candidate -cin @($s,$t) }
        'restored-unconfirmed' { $active -ceq $s -and $candidate -ceq $s }
        default { $false }
    }
    if (-not $valid) { throw 'transition pointer conflict; preserve both versions for explicit reconciliation' }
}

function Assert-TeremoqAssistedTransitionReadable {
    param([Parameter(Mandatory = $true)][string]$StateRoot)
    $layout = Get-TeremoqLanClientLayout -StateRoot $StateRoot
    $directory = Join-Path $layout.StateRoot 'unconfirmed-transition'
    $binding = Read-TeremoqTransitionRecord -Directory $directory
    $phase = Read-TeremoqTransitionPhase -Directory $directory
    if ($phase -cnotin @('pending-health','restored-unconfirmed')) { throw 'assisted transition is incomplete; no launcher/readiness selection is permitted' }
    [void](Assert-TeremoqTransitionSnapshot -Layout $layout -Directory $directory -Binding $binding)
    Assert-TeremoqTransitionPointers -Layout $layout -Binding $binding -Phase $phase
}

function Invoke-TeremoqAssistedUnconfirmedTransition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Supersede','Restore','Status')][string]$Action,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$TransitionId,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceSha256,
        [Parameter(Mandatory = $true)][string]$ExpectedTargetSha256,
        [Parameter(Mandatory = $true)][string]$ExpectedTargetCommit,
        [string]$TargetRecordPath
    )
    if ($Action -cnotin @('Supersede','Restore','Status') -or
        $TransitionId -cnotmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' -or
        $ExpectedSourceSha256 -cnotmatch '^[0-9a-f]{64}$' -or $ExpectedTargetSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $ExpectedTargetCommit -cnotmatch '^[0-9a-f]{40}$' -or $ExpectedSourceSha256 -ceq $ExpectedTargetSha256) {
        throw 'explicit assisted transition identity is invalid'
    }
    $layout = Get-TeremoqLanClientLayout -StateRoot $StateRoot
    foreach ($path in @($layout.StateRoot,$layout.ConfigRoot,$layout.ControlRoot,$layout.PlayersRoot,$layout.VersionsRoot)) {
        [void](Get-TeremoqNonReparseDirectoryPath -Path $path)
    }
    $lockPath = Assert-TeremoqNonReparseFilePath -Path (Join-Path $layout.ControlRoot 'update.lock')
    # Use the EXISTING operation lock without Initialize/Repair or creation.
    $lock = [IO.File]::Open($lockPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $directory = Join-Path $layout.StateRoot 'unconfirmed-transition'
        if ($Action -cne 'Supersede' -and -not (Test-Path -LiteralPath $directory)) {
            throw 'no assisted transition exists to inspect or restore'
        }
        $binding = [pscustomobject][ordered]@{ schema_version=1; transition_id=$TransitionId;
            source_sha256=$ExpectedSourceSha256; target_sha256=$ExpectedTargetSha256;
            target_commit=$ExpectedTargetCommit; source_status='unconfirmed'; rollback_state='absent' }
        $bindingText = ($binding | ConvertTo-Json -Compress) + "`n"
        if (Test-Path -LiteralPath $directory) {
            [void](Get-TeremoqNonReparseDirectoryPath -Path $directory)
            Assert-TeremoqTransitionDirectory -Directory $directory
            if (Test-Path -LiteralPath (Join-Path $directory 'binding.json')) {
                $existing = Read-TeremoqTransitionRecord -Directory $directory
                if ((($existing | ConvertTo-Json -Compress) + "`n") -cne $bindingText) { throw 'transition ID or source/target override rejected' }
            }
        }
        $phasePath = Join-Path $directory 'phase.txt'
        if (-not (Test-Path -LiteralPath $phasePath)) {
            if ($Action -ceq 'Status' -or [string]::IsNullOrEmpty($TargetRecordPath)) { throw 'transition snapshot is not sealed; explicit source/target inputs are required to complete or restore it' }
            Assert-TeremoqTransitionPointers -Layout $layout -Binding $binding -Phase sealed
            $sourceText = Read-TeremoqBoundedUtf8File -Path $layout.ActivePointer -MaxBytes 4096
            $targetText = Read-TeremoqBoundedUtf8File -Path $TargetRecordPath -MaxBytes 4096
            $source = Read-TeremoqLanSlotPointer -Path $layout.ActivePointer
            $target = Read-TeremoqLanSlotPointer -Path $TargetRecordPath
            Assert-TeremoqTransitionSlotTypes -Record $source
            Assert-TeremoqTransitionSlotTypes -Record $target
            if ((Get-TeremoqTransitionTextHash $sourceText) -cne $ExpectedSourceSha256 -or
                (Get-TeremoqTransitionTextHash $targetText) -cne $ExpectedTargetSha256 -or
                $targetText -cne (ConvertTo-TeremoqLanSlotJson -Record $target) -or
                $sourceText -cne (ConvertTo-TeremoqLanSlotJson -Record $source) -or
                $target.updater_commit -cne $ExpectedTargetCommit -or $source.slot_id -ceq $target.slot_id -or
                $source.config_sha256 -cne $target.config_sha256) { throw 'initial unconfirmed transition binding mismatch' }
            # Capture and pin all original/target metadata before any control
            # write. Snapshots are immutable and rechecked on every resumption.
            $pins = New-Object 'Collections.Generic.List[IO.FileStream]'
            try {
                $sourcePaths = @(Get-TeremoqTransitionMaterialPaths -Layout $layout -Record $source)
                $targetPaths = @(Get-TeremoqTransitionMaterialPaths -Layout $layout -Record $target)
                foreach ($path in @($layout.ActivePointer,$layout.CandidatePointer,$TargetRecordPath) + $sourcePaths + $targetPaths) {
                    $pins.Add((Open-TeremoqVerifiedRegularFile -Path $path -MaxBytes 1048576))
                }
                Assert-TeremoqTransitionPointers -Layout $layout -Binding $binding -Phase sealed
                if ((Get-TeremoqBoundedFileSha256 -Path $TargetRecordPath -MaxBytes 4096) -cne $ExpectedTargetSha256) { throw 'target record changed before snapshot' }
                New-TeremoqPrivateTransitionDirectory -Path $directory
                Write-TeremoqTransitionCopy -Path (Join-Path $directory 'binding.json') -Text $bindingText
                Write-TeremoqTransitionCopy -Path (Join-Path $directory 'source.json') -Text $sourceText
                Write-TeremoqTransitionCopy -Path (Join-Path $directory 'target.json') -Text $targetText
                foreach ($side in @('source','target')) {
                    $paths = if ($side -ceq 'source') { $sourcePaths } else { $targetPaths }
                    for ($i=0; $i -lt $paths.Count; $i++) {
                        $bound = if ($i -eq 3) { 1048576 } else { 4096 }
                        Write-TeremoqTransitionCopy -Path (Join-Path $directory ("$side-$i.utf8")) `
                            -Text (Read-TeremoqBoundedUtf8File -Path $paths[$i] -MaxBytes $bound)
                    }
                }
                [void](Assert-TeremoqTransitionSnapshot -Layout $layout -Directory $directory -Binding $binding)
                Write-TeremoqAtomicUtf8File -Path $phasePath -Content "sealed`n"
            } finally { foreach ($pin in $pins) { $pin.Dispose() } }
        }
        $stored = Read-TeremoqTransitionRecord -Directory $directory
        if ((($stored | ConvertTo-Json -Compress) + "`n") -cne $bindingText) { throw 'transition binding changed' }
        $records = Assert-TeremoqTransitionSnapshot -Layout $layout -Directory $directory -Binding $binding
        $phase = Read-TeremoqTransitionPhase -Directory $directory
        Assert-TeremoqTransitionPointers -Layout $layout -Binding $binding -Phase $phase
        if ($Action -ceq 'Status') { return [pscustomobject]@{ Status=$phase; TransitionId=$TransitionId; Health='not_measured'; Rollback='absent' } }
        if ($Action -ceq 'Supersede') {
            if ($phase -cin @('restoring-active','restoring-candidate','restored-unconfirmed')) { throw 'restoration has begun; supersession cannot be replayed' }
            if ($phase -ceq 'sealed') { Write-TeremoqAtomicUtf8File -Path $phasePath -Content "applying-candidate`n"; $phase='applying-candidate' }
            if ($phase -ceq 'applying-candidate') {
                Assert-TeremoqTransitionPointers -Layout $layout -Binding $binding -Phase $phase
                if ((Get-TeremoqBoundedFileSha256 -Path $layout.CandidatePointer -MaxBytes 4096) -cne $ExpectedTargetSha256) {
                    Write-TeremoqTransitionPointer -Layout $layout -Directory $directory -Name candidate -Destination target -Record $records.Target
                }
                Write-TeremoqAtomicUtf8File -Path $phasePath -Content "applying-active`n"; $phase='applying-active'
            }
            if ($phase -ceq 'applying-active') {
                Assert-TeremoqTransitionPointers -Layout $layout -Binding $binding -Phase $phase
                if ((Get-TeremoqBoundedFileSha256 -Path $layout.ActivePointer -MaxBytes 4096) -cne $ExpectedTargetSha256) {
                    Write-TeremoqTransitionPointer -Layout $layout -Directory $directory -Name active -Destination target -Record $records.Target
                }
                Write-TeremoqAtomicUtf8File -Path $phasePath -Content "pending-health`n"; $phase='pending-health'
            }
        } else {
            if ($phase -cnotin @('restoring-active','restoring-candidate','restored-unconfirmed')) {
                Write-TeremoqAtomicUtf8File -Path $phasePath -Content "restoring-active`n"; $phase='restoring-active'
            }
            if ($phase -ceq 'restoring-active') {
                Assert-TeremoqTransitionPointers -Layout $layout -Binding $binding -Phase $phase
                if ((Get-TeremoqBoundedFileSha256 -Path $layout.ActivePointer -MaxBytes 4096) -cne $ExpectedSourceSha256) {
                    Write-TeremoqTransitionPointer -Layout $layout -Directory $directory -Name active -Destination source -Record $records.Source
                }
                Write-TeremoqAtomicUtf8File -Path $phasePath -Content "restoring-candidate`n"; $phase='restoring-candidate'
            }
            if ($phase -ceq 'restoring-candidate') {
                Assert-TeremoqTransitionPointers -Layout $layout -Binding $binding -Phase $phase
                if ((Get-TeremoqBoundedFileSha256 -Path $layout.CandidatePointer -MaxBytes 4096) -cne $ExpectedSourceSha256) {
                    Write-TeremoqTransitionPointer -Layout $layout -Directory $directory -Name candidate -Destination source -Record $records.Source
                }
                Write-TeremoqAtomicUtf8File -Path $phasePath -Content "restored-unconfirmed`n"; $phase='restored-unconfirmed'
            }
        }
        [void](Assert-TeremoqTransitionSnapshot -Layout $layout -Directory $directory -Binding $binding)
        Assert-TeremoqTransitionPointers -Layout $layout -Binding $binding -Phase $phase
        return [pscustomobject]@{ Status=$phase; TransitionId=$TransitionId; Health='not_measured'; Rollback='absent' }
    } finally { $lock.Dispose() }
}
