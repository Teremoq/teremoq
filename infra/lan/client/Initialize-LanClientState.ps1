# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CheckoutRoot,
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [Parameter(Mandatory = $true)][string]$RepositoryUrl,
    [Parameter(Mandatory = $true)][string]$RepositoryRef,
    [Parameter(Mandatory = $true)][string]$ExpectedCommit,
    [Parameter(Mandatory = $true)][string]$RepositorySubdirectory,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$ServerIPv4,
    [Parameter(Mandatory = $true)][int]$PrefixLength,
    [Parameter(Mandatory = $true)][string]$Namespace,
    [Parameter(Mandatory = $true)][string]$FingerprintSha256,
    [Parameter(Mandatory = $true)][string]$BuilderReceiptPath,
    [Parameter(Mandatory = $true)][string]$BuilderReceiptSha256
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot 'Client-Distribution.ps1')
. (Join-Path $PSScriptRoot 'Client-Slot-State.ps1')

if ($RunId -cnotmatch '^lan-[a-z0-9][a-z0-9-]{0,31}$' -or
    -not (Test-TeremoqCanonicalPrivateUnicastIPv4 -Value $ServerIPv4) -or
    $PrefixLength -lt 8 -or $PrefixLength -gt 30 -or
    $Namespace -isnot [string] -or $Namespace.Length -lt 1 -or $Namespace.Length -gt 256 -or
    $Namespace -cnotmatch '^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$' -or
    @($Namespace.Split('/') | Where-Object { $_ -in @('.', '..') }).Count -ne 0 -or
    $FingerprintSha256 -cnotmatch '^[0-9a-f]{64}$') {
    throw 'local client configuration is outside the closed LAN policy'
}
$checkout = Get-TeremoqGitBootstrapCheckoutContext -CheckoutRoot $CheckoutRoot -RepositoryUrl $RepositoryUrl `
    -RepositoryRef $RepositoryRef -ExpectedCommit $ExpectedCommit -RepositorySubdirectory $RepositorySubdirectory
$layout = Initialize-TeremoqLanClientLayout -StateRoot $StateRoot
Assert-TeremoqRootsSeparated -CheckoutRoot $checkout.CheckoutRoot -StateRoot $layout.StateRoot

$receiptPath = Assert-TeremoqNonReparseFilePath -Path $BuilderReceiptPath
if ($BuilderReceiptSha256 -cnotmatch '^[0-9a-f]{64}$' -or
    (Get-TeremoqBoundedFileSha256 -Path $receiptPath -MaxBytes 8192) -cne $BuilderReceiptSha256) {
    throw 'Web builder receipt digest is absent or changed'
}
$receiptText = Read-TeremoqBoundedUtf8File -Path $receiptPath -MaxBytes 8192
try { $receipt = $receiptText | ConvertFrom-Json } catch { throw 'Web builder receipt is not JSON' }
$receiptKeys = @(
    'schema_version','status','updater_version','player_identity','player_version','config_schema_version',
    'build_mode','source_commit','source_tree','package_lock_sha256','node_version','npm_version','platform',
    'architecture','dependency_status','previous_source_commit','source_diff_files','source_diff_sha256',
    'builds_executed','build_verification','manifest_sha256','launcher_contract_sha256',
    'artifact_inventory_sha256','player_relative_path'
)
$actualReceiptKeys = @($receipt.PSObject.Properties.Name)
if ($actualReceiptKeys.Count -ne $receiptKeys.Count -or
    @($actualReceiptKeys | Where-Object { $receiptKeys -cnotcontains $_ }).Count -ne 0 -or
    $receipt.schema_version -ne 1 -or $receipt.status -cnotin @('built','reused') -or
    $receipt.updater_version -cne (Get-TeremoqLanUpdaterVersion) -or
    $receipt.player_identity -cnotmatch '^sha256:[0-9a-f]{64}$' -or
    $receipt.player_version -cnotmatch '^[0-9]+[.][0-9]+[.][0-9]+(?:-[0-9A-Za-z.-]+)?$' -or
    $receipt.config_schema_version -ne 1 -or $receipt.build_mode -cne 'node' -or
    $receipt.source_commit -cne $ExpectedCommit -or $receipt.source_tree -cnotmatch '^[0-9a-f]{40}$' -or
    $receipt.package_lock_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
    $receipt.manifest_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
    $receipt.launcher_contract_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
    $receipt.player_relative_path -cne ('players/' + $receipt.player_identity.Replace(':','-'))) {
    throw 'Web builder receipt is outside initialization policy'
}
$measuredSourceTree = Invoke-TeremoqGit -CheckoutRoot $checkout.CheckoutRoot -Arguments @('rev-parse', ($ExpectedCommit + ':supervisor-web'))
$measuredLockSha256 = Get-TeremoqBoundedFileSha256 -Path (Join-Path $checkout.CheckoutRoot 'supervisor-web\package-lock.json') -MaxBytes 1048576
if ($receipt.source_tree -cne $measuredSourceTree -or $receipt.package_lock_sha256 -cne $measuredLockSha256 -or
    $receipt.player_identity -cne (Get-TeremoqLanPlayerIdentity -SourceTree $measuredSourceTree `
        -PackageLockSha256 $measuredLockSha256)) {
    throw 'Web player identity does not match the exact clean Git source and lockfile'
}

$identityRoot = Join-Path $layout.ConfigRoot 'public-identity'
if (-not (Test-Path -LiteralPath $identityRoot)) { [void][IO.Directory]::CreateDirectory($identityRoot) }
[void](Get-TeremoqNonReparseDirectoryPath -Path $identityRoot)
$configPath = Join-Path $layout.ConfigRoot 'LAN-CONFIG.json'
$fingerprintPath = Join-Path $identityRoot 'relay-cert.sha256'
$configObject = [pscustomobject][ordered]@{
    schema_version = 1
    run_id = $RunId
    relay_url = "https://${ServerIPv4}:14433/watch"
    fingerprint_sha256 = $FingerprintSha256
    prefix_length = $PrefixLength
    namespace = $Namespace
}
$configText = ($configObject | ConvertTo-Json -Compress) + "`n"
if ((New-Object Text.UTF8Encoding($false)).GetByteCount($configText) -gt 512) {
    throw 'canonical public LAN configuration exceeds 512 bytes'
}
$configExists = Test-Path -LiteralPath $configPath
$fingerprintExists = Test-Path -LiteralPath $fingerprintPath
if ($configExists -xor $fingerprintExists) { throw 'local LAN configuration is incomplete; it will not be overwritten' }
if (-not $configExists) {
    Write-TeremoqAtomicUtf8File -Path $fingerprintPath -Content ($FingerprintSha256 + "`n")
    Write-TeremoqAtomicUtf8File -Path $configPath -Content $configText
} else {
    $existingConfig = Read-TeremoqBoundedUtf8File -Path $configPath -MaxBytes 512
    $existingFingerprint = (Read-TeremoqBoundedUtf8File -Path $fingerprintPath -MaxBytes 128).Trim()
    if ($existingConfig -cne $configText -or $existingFingerprint -cne $FingerprintSha256) {
        throw 'local LAN configuration differs from the update request and will not be overwritten'
    }
}
$configSha256 = Get-TeremoqBoundedFileSha256 -Path $configPath -MaxBytes 512

$playerRoot = [IO.Path]::GetFullPath((Join-Path $layout.StateRoot $receipt.player_relative_path))
if (-not $playerRoot.StartsWith($layout.PlayersRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Web player path escapes the immutable player root'
}
[void](Get-TeremoqNonReparseDirectoryPath -Path $playerRoot)
$manifestPath = Assert-TeremoqNonReparseFilePath -Path (Join-Path $playerRoot 'MANIFEST.sha256.json')
$launcherPath = Assert-TeremoqNonReparseFilePath -Path (Join-Path $playerRoot 'lan-launcher.tsv')
if ((Get-TeremoqBoundedFileSha256 -Path $manifestPath -MaxBytes 1048576) -cne $receipt.manifest_sha256 -or
    (Get-TeremoqBoundedFileSha256 -Path $launcherPath -MaxBytes 4096) -cne $receipt.launcher_contract_sha256) {
    throw 'Web player hashes differ from the sealed builder receipt'
}
$manifest = (Read-TeremoqBoundedUtf8File -Path $manifestPath -MaxBytes 1048576) | ConvertFrom-Json
$manifestKeys = @($manifest.PSObject.Properties.Name)
$expectedManifestKeys = @('schema_version','artifact','entrypoint','package_version','updater_version','player_identity','player_version','config_schema_version','files','total_bytes')
if ($manifestKeys.Count -ne $expectedManifestKeys.Count -or
    @($manifestKeys | Where-Object { $expectedManifestKeys -cnotcontains $_ }).Count -ne 0 -or
    $manifest.schema_version -ne 1 -or $manifest.artifact -cne 'teremoq-lan-lab-standalone' -or
    $manifest.entrypoint -cne 'start.mjs' -or $manifest.updater_version -cne $receipt.updater_version -or
    $manifest.player_identity -cne $receipt.player_identity -or $manifest.player_version -cne $receipt.player_version -or
    $manifest.package_version -cne $receipt.player_version -or $manifest.config_schema_version -ne 1) {
    throw 'Web player manifest differs from its immutable identity'
}

$record = New-TeremoqLanSlotRecord -UpdaterCommit $ExpectedCommit -PlayerIdentity $receipt.player_identity `
    -SourceTree $receipt.source_tree -PackageLockSha256 $receipt.package_lock_sha256 `
    -PlayerManifestSha256 $receipt.manifest_sha256 -LauncherContractSha256 $receipt.launcher_contract_sha256 `
    -ConfigSha256 $configSha256
$versionRoot = [IO.Path]::GetFullPath((Join-Path $layout.StateRoot $record.version_relative_path))
$version = @(
    "schema_version`t2",
    "updater_version`t$($record.updater_version)",
    "updater_commit`t$ExpectedCommit",
    "player_identity`t$($receipt.player_identity)",
    "player_version`t$($receipt.player_version)",
    "config_schema_version`t1",
    "run_id`t$RunId",
    "server_ipv4`t$ServerIPv4",
    "moq_url`thttps://${ServerIPv4}:14433/watch",
    "player_manifest_sha256`t$($receipt.manifest_sha256)",
    "launcher_contract_sha256`t$($receipt.launcher_contract_sha256)",
    "lan_config_sha256`t$configSha256",
    "player_evidence`tnot_measured",
    "load_launcher_status`tready"
) -join "`n"
$compatibility = @(
    "schema_version`t2",
    "repository_url`t$RepositoryUrl",
    "repository_ref`t$RepositoryRef",
    "repository_subdirectory`t$RepositorySubdirectory",
    "allowed_client_commit`t$ExpectedCommit",
    "updater_version`t$($record.updater_version)",
    "updater_protocol`t$($record.updater_protocol)",
    "player_identity`t$($receipt.player_identity)",
    "player_version`t$($receipt.player_version)",
    "source_tree`t$($receipt.source_tree)",
    "package_lock_sha256`t$($receipt.package_lock_sha256)",
    "player_relative_path`t$($receipt.player_relative_path)",
    "config_schema_version`t1",
    "player_manifest_sha256`t$($receipt.manifest_sha256)",
    "launcher_contract_sha256`t$($receipt.launcher_contract_sha256)",
    "lan_config_sha256`t$configSha256"
) -join "`n"
$scratch = Join-Path $layout.VersionsRoot ('.stage-' + [Guid]::NewGuid().ToString('N'))
try {
    if (-not (Test-Path -LiteralPath $versionRoot)) {
        [void][IO.Directory]::CreateDirectory($scratch)
        [IO.File]::WriteAllText((Join-Path $scratch 'VERSION.tsv'), $version + "`n", (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $scratch 'CLIENT-COMPATIBILITY.tsv'), $compatibility + "`n", (New-Object Text.UTF8Encoding($false)))
        $hashLines = @('CLIENT-COMPATIBILITY.tsv','VERSION.tsv') | ForEach-Object {
            "$(Get-TeremoqBoundedFileSha256 -Path (Join-Path $scratch $_) -MaxBytes 4096)  $_"
        }
        [IO.File]::WriteAllText((Join-Path $scratch 'SHA256SUMS'), ($hashLines -join "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
        [IO.Directory]::Move($scratch, $versionRoot)
    } else {
        [void](Get-TeremoqNonReparseDirectoryPath -Path $versionRoot)
        if ((Read-TeremoqBoundedUtf8File -Path (Join-Path $versionRoot 'VERSION.tsv') -MaxBytes 4096) -cne ($version + "`n") -or
            (Read-TeremoqBoundedUtf8File -Path (Join-Path $versionRoot 'CLIENT-COMPATIBILITY.tsv') -MaxBytes 4096) -cne ($compatibility + "`n")) {
            throw 'existing updater/player slot differs and will not be overwritten'
        }
    }
    $staged = Stage-TeremoqLanClientSlot -StateRoot $layout.StateRoot -Record $record
    Write-Output ("LAN client slot {0}: updater={1}, player={2}." -f $staged.Status, $ExpectedCommit.Substring(0,8), $receipt.player_identity)
} finally {
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}
