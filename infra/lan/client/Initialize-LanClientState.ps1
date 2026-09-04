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
    [Parameter(Mandatory = $true)][string]$PlayerRelativePath,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$ServerIPv4,
    [Parameter(Mandatory = $true)][int]$PrefixLength,
    [Parameter(Mandatory = $true)][string]$Namespace,
    [Parameter(Mandatory = $true)][string]$FingerprintSha256,
    # This is written by Prepare-LanClientFromGit after its bounded Web builder
    # invocation.  Initialization is intentionally not a public artifact-import API.
    [Parameter(Mandatory = $true)][string]$BuilderReceiptPath,
    [Parameter(Mandatory = $true)][string]$BuilderReceiptSha256
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot 'Client-Distribution.ps1')

if ($RunId -cnotmatch '^lan-[a-z0-9][a-z0-9-]{0,31}$' -or
    -not (Test-TeremoqCanonicalPrivateUnicastIPv4 -Value $ServerIPv4) -or
    $PrefixLength -lt 8 -or $PrefixLength -gt 30 -or
    $Namespace -isnot [string] -or $Namespace.Length -lt 1 -or $Namespace.Length -gt 256 -or
    $Namespace -cnotmatch '^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$' -or
    @($Namespace.Split('/') | Where-Object { $_ -in @('.', '..') }).Count -ne 0 -or
    $FingerprintSha256 -cnotmatch '^[0-9a-f]{64}$' -or
    $PlayerRelativePath -cne ("players/{0}" -f $ExpectedCommit)) {
    throw 'local client state parameters are outside the closed LAN policy'
}
$receiptPath = Assert-TeremoqNonReparseFilePath -Path $BuilderReceiptPath
if ($BuilderReceiptSha256 -cnotmatch '^[0-9a-f]{64}$' -or (Get-TeremoqBoundedFileSha256 -Path $receiptPath -MaxBytes 8192) -cne $BuilderReceiptSha256) {
    throw 'Web builder receipt digest is absent or changed'
}
$receiptText = Read-TeremoqBoundedUtf8File -Path $receiptPath -MaxBytes 8192
try { $receipt = $receiptText | ConvertFrom-Json } catch { throw 'Web builder receipt is not closed JSON' }
$receiptKeys = @($receipt.PSObject.Properties.Name)
$allowedReceiptKeys = @('status','source_commit','source_tree','package_lock_sha256','dependency_mode','previous_source_commit','source_diff_files','source_diff_sha256','independent_builds','byte_identical','manifest_sha256','player_relative_path')
if ($receiptKeys.Count -ne $allowedReceiptKeys.Count -or @($receiptKeys | Where-Object { $allowedReceiptKeys -notcontains $_ }).Count -ne 0 -or
    $receipt.status -cne 'built-from-clean-git-source' -or $receipt.source_commit -cne $ExpectedCommit -or
    $receipt.player_relative_path -cne $PlayerRelativePath -or $receipt.manifest_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
    $receipt.source_tree -cnotmatch '^[0-9a-f]{40}$' -or $receipt.package_lock_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
    $receipt.dependency_mode -cnotin @('initial-npm-ci','reused-lock-cache','explicit-lock-refresh') -or
    $receipt.independent_builds -isnot [ValueType] -or $receipt.independent_builds -is [bool] -or [int]$receipt.independent_builds -ne 2 -or
    $receipt.byte_identical -isnot [bool] -or -not $receipt.byte_identical) { throw 'Web builder receipt is outside the initialization policy' }
$checkout = Get-TeremoqGitBootstrapCheckoutContext -CheckoutRoot $CheckoutRoot -RepositoryUrl $RepositoryUrl -RepositoryRef $RepositoryRef -ExpectedCommit $ExpectedCommit -RepositorySubdirectory $RepositorySubdirectory
$state = [IO.Path]::GetFullPath($StateRoot)
if (-not (Test-Path -LiteralPath $state -PathType Container) -or ((Get-Item -LiteralPath $state -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'StateRoot must already be the regular external root produced by the Web Git builder'
}
$parent = Split-Path -Parent $state
Assert-TeremoqRootsSeparated -CheckoutRoot $checkout.CheckoutRoot -StateRoot $state
$playerRoot = [IO.Path]::GetFullPath((Join-Path $state $PlayerRelativePath))
if (-not $playerRoot.StartsWith($state, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $playerRoot -PathType Container) -or
    ((Get-Item -LiteralPath $playerRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
    (Get-ChildItem -LiteralPath $playerRoot -Recurse -Force | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })) {
    throw 'PlayerRelativePath must resolve to the regular Web-built player under StateRoot'
}
foreach ($required in @('.teremoq-web-build/generations/' + $ExpectedCommit + '.tsv', 'players')) {
    if (-not (Test-Path -LiteralPath (Join-Path $state $required))) { throw 'Web builder provenance is absent from StateRoot' }
}
foreach ($required in @('MANIFEST.sha256.json', 'lan-launcher.tsv')) {
    if (-not (Test-Path -LiteralPath (Join-Path $playerRoot $required) -PathType Leaf)) { throw "versioned player artifact is incomplete: $required" }
}
$playerManifestPath = Assert-TeremoqNonReparseFilePath -Path (Join-Path $playerRoot 'MANIFEST.sha256.json')
$launcherContractPath = Assert-TeremoqNonReparseFilePath -Path (Join-Path $playerRoot 'lan-launcher.tsv')
$playerManifestSha = Get-TeremoqBoundedFileSha256 -Path $playerManifestPath -MaxBytes 1048576
$launcherContractSha = Get-TeremoqBoundedFileSha256 -Path $launcherContractPath -MaxBytes 4096
if ($playerManifestSha -cne $receipt.manifest_sha256) { throw 'Web builder receipt does not bind the exact player manifest bytes' }
$webGeneration = Get-TeremoqWebGenerationContext -Checkout $checkout -StateRoot $state -PlayerRelativePath $PlayerRelativePath -PlayerManifestSha256 $playerManifestSha -LauncherContractSha256 $launcherContractSha
$manifest = (Read-TeremoqBoundedUtf8File -Path (Join-Path $playerRoot 'MANIFEST.sha256.json') -MaxBytes 1048576) | ConvertFrom-Json
if ($manifest.schema_version -ne 1 -or $manifest.artifact -cne 'teremoq-lan-lab-standalone' -or $manifest.source_commit -cne $ExpectedCommit -or
    $manifest.package_version -isnot [string] -or $manifest.package_version -cnotmatch '^[A-Za-z0-9._-]{1,64}$') {
    throw 'versioned player manifest is outside the local initialization contract'
}
$scratch = Join-Path $parent ('.' + [IO.Path]::GetFileName($state) + '.tmp.' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path (Join-Path $scratch 'public-identity') -Force | Out-Null
    # The Web builder already owns StateRoot\players\<commit>; Platform never copies it.
    [IO.File]::WriteAllText((Join-Path $scratch 'public-identity\relay-cert.sha256'), "$FingerprintSha256`n", (New-Object Text.UTF8Encoding($false)))
    $lanConfig = [ordered]@{ schema_version = 1; run_id = $RunId; source_commit = $ExpectedCommit; relay_url = "https://${ServerIPv4}:14433/watch"; fingerprint_sha256 = $FingerprintSha256; prefix_length = $PrefixLength; namespace = $Namespace }
    $lanConfigText = ($lanConfig | ConvertTo-Json -Compress) + "`n"
    if ((New-Object Text.UTF8Encoding($false)).GetByteCount($lanConfigText) -gt 512) { throw 'canonical public LAN-CONFIG.json exceeds 512 bytes' }
    [IO.File]::WriteAllText((Join-Path $scratch 'LAN-CONFIG.json'), $lanConfigText, (New-Object Text.UTF8Encoding($false)))
    $lanConfigSha = (Get-FileHash -LiteralPath (Join-Path $scratch 'LAN-CONFIG.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    $compatibility = @(
        "schema_version`t1", "repository_url`t$RepositoryUrl", "repository_ref`t$RepositoryRef", "repository_subdirectory`t$RepositorySubdirectory", "player_relative_path`t$PlayerRelativePath",
        "allowed_client_commit`t$ExpectedCommit", "source_commit`t$ExpectedCommit", "package_version`t$($manifest.package_version)", "client_protocol_version`tteremoq-lan-git-v2",
        "player_manifest_sha256`t$playerManifestSha", "launcher_contract_sha256`t$launcherContractSha", "lan_config_sha256`t$lanConfigSha"
    ) -join "`n"
    [IO.File]::WriteAllText((Join-Path $scratch 'CLIENT-COMPATIBILITY.tsv'), $compatibility + "`n", (New-Object Text.UTF8Encoding($false)))
    $version = @(
        "schema_version`t1", "package_version`t$($manifest.package_version)", "run_id`t$RunId", "source_commit`t$ExpectedCommit", "server_ipv4`t$ServerIPv4", "moq_url`thttps://${ServerIPv4}:14433/watch",
        "player_manifest_sha256`t$playerManifestSha", "launcher_contract_sha256`t$launcherContractSha", "lan_config_sha256`t$lanConfigSha", "player_evidence`tnot_measured", "load_launcher_status`tready"
    ) -join "`n"
    [IO.File]::WriteAllText((Join-Path $scratch 'VERSION.tsv'), $version + "`n", (New-Object Text.UTF8Encoding($false)))
    $hashItems = @()
    $hashItems += Get-ChildItem -LiteralPath $scratch -Recurse -Force -File | ForEach-Object { [pscustomobject]@{ Path = $_.FullName; Relative = $_.FullName.Substring($scratch.Length).TrimStart('\', '/').Replace('\', '/') } }
    $hashItems += Get-ChildItem -LiteralPath $playerRoot -Recurse -Force -File | ForEach-Object { [pscustomobject]@{ Path = $_.FullName; Relative = $_.FullName.Substring($state.Length).TrimStart('\', '/').Replace('\', '/') } }
    $hashLines = $hashItems | Sort-Object Relative | ForEach-Object { "$(Get-FileHash -LiteralPath $_.Path -Algorithm SHA256 | ForEach-Object { $_.Hash.ToLowerInvariant() })  $($_.Relative)" }
    [IO.File]::WriteAllText((Join-Path $scratch 'SHA256SUMS'), ($hashLines -join "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
    foreach ($name in @('public-identity', 'LAN-CONFIG.json', 'CLIENT-COMPATIBILITY.tsv', 'VERSION.tsv', 'SHA256SUMS')) {
        if (Test-Path -LiteralPath (Join-Path $state $name)) { throw "StateRoot already contains Platform state: $name" }
        Move-Item -LiteralPath (Join-Path $scratch $name) -Destination (Join-Path $state $name)
    }
    $verified = Get-TeremoqLanStateContext -StateRoot $state
    if ($verified.Compatibility.allowed_client_commit -cne $checkout.Head) { throw 'initialized state does not bind the exact clean checkout' }
    Write-Output ("Teremoq LAN external client state initialized at {0} from Web-built player commit {1}; no artifact was transferred." -f $verified.StateRoot, $checkout.Head)
} finally {
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}
