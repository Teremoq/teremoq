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
    [Parameter(Mandatory = $true)][string]$FingerprintSha256
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
    -not (Test-TeremoqSafeRelativeRepositorySubdirectory -Value $PlayerRelativePath)) {
    throw 'local client state parameters are outside the closed LAN policy'
}
$checkout = Get-TeremoqGitBootstrapCheckoutContext -CheckoutRoot $CheckoutRoot -RepositoryUrl $RepositoryUrl -RepositoryRef $RepositoryRef -ExpectedCommit $ExpectedCommit -RepositorySubdirectory $RepositorySubdirectory
$state = [IO.Path]::GetFullPath($StateRoot)
if (Test-Path -LiteralPath $state) { throw 'StateRoot must not already exist; initialization never overwrites local state' }
$parent = Split-Path -Parent $state
if (-not (Test-Path -LiteralPath $parent -PathType Container) -or ((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'StateRoot parent must already exist and may not be a reparse point'
}
Assert-TeremoqRootsSeparated -CheckoutRoot $checkout.CheckoutRoot -StateRoot $state
$playerRoot = [IO.Path]::GetFullPath((Join-Path $checkout.CheckoutRoot $PlayerRelativePath))
if (-not $playerRoot.StartsWith($checkout.CheckoutRoot, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $playerRoot -PathType Container) -or
    ((Get-Item -LiteralPath $playerRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
    (Get-ChildItem -LiteralPath $playerRoot -Recurse -Force | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })) {
    throw 'PlayerRelativePath must resolve to a regular versioned directory inside the clean checkout'
}
foreach ($required in @('MANIFEST.sha256.json', 'lan-launcher.tsv')) {
    if (-not (Test-Path -LiteralPath (Join-Path $playerRoot $required) -PathType Leaf)) { throw "versioned player artifact is incomplete: $required" }
}
$playerManifestSha = (Get-FileHash -LiteralPath (Join-Path $playerRoot 'MANIFEST.sha256.json') -Algorithm SHA256).Hash.ToLowerInvariant()
$launcherContractSha = (Get-FileHash -LiteralPath (Join-Path $playerRoot 'lan-launcher.tsv') -Algorithm SHA256).Hash.ToLowerInvariant()
$manifest = (Read-TeremoqBoundedUtf8File -Path (Join-Path $playerRoot 'MANIFEST.sha256.json') -MaxBytes 1048576) | ConvertFrom-Json
if ($manifest.schema_version -ne 1 -or $manifest.artifact -cne 'teremoq-lan-lab-standalone' -or $manifest.source_commit -cne $ExpectedCommit -or
    $manifest.package_version -isnot [string] -or $manifest.package_version -cnotmatch '^[A-Za-z0-9._-]{1,64}$') {
    throw 'versioned player manifest is outside the local initialization contract'
}
$scratch = Join-Path $parent ('.' + [IO.Path]::GetFileName($state) + '.tmp.' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path (Join-Path $scratch 'public-identity') -Force | Out-Null
    Copy-Item -LiteralPath $playerRoot -Destination (Join-Path $scratch 'player') -Recurse -Force
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
    $hashLines = Get-ChildItem -LiteralPath $scratch -Recurse -Force -File | Sort-Object { $_.FullName.Substring($scratch.Length).Replace('\', '/') } | ForEach-Object {
        $relative = $_.FullName.Substring($scratch.Length).TrimStart('\', '/').Replace('\', '/')
        "$(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256 | ForEach-Object { $_.Hash.ToLowerInvariant() })  $relative"
    }
    [IO.File]::WriteAllText((Join-Path $scratch 'SHA256SUMS'), ($hashLines -join "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $scratch -Destination $state
    $verified = Get-TeremoqLanStateContext -StateRoot $state
    if ($verified.Compatibility.allowed_client_commit -cne $checkout.Head) { throw 'initialized state does not bind the exact clean checkout' }
    Write-Output ("Teremoq LAN external client state initialized at {0} from versioned checkout commit {1}; no artifact was transferred." -f $verified.StateRoot, $checkout.Head)
} finally {
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}
