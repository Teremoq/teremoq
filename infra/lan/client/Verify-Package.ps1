# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$PackageRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$root = [IO.Path]::GetFullPath($PackageRoot)
foreach ($required in @('VERSION.tsv', 'LAN-CONFIG.json', 'SHA256SUMS', 'public-identity/relay-cert.pem', 'public-identity/relay-cert.sha256', 'player')) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $required))) { throw "missing package artifact: $required" }
}
$versionPath = Join-Path $root 'VERSION.tsv'
if ((Get-Item -LiteralPath $versionPath).Length -gt 4096) { throw 'VERSION.tsv exceeds its byte limit' }
$versionAllowed = @('schema_version', 'package_version', 'run_id', 'source_commit', 'server_ipv4', 'moq_url', 'player_manifest_sha256', 'launcher_contract_sha256', 'lan_config_sha256', 'player_evidence', 'load_launcher_status')
$version = @{}
foreach ($line in Get-Content -LiteralPath $versionPath) {
    $fields = $line -split "`t", 3
    if ($fields.Count -ne 2 -or $versionAllowed -notcontains $fields[0] -or $version.ContainsKey($fields[0]) -or [string]::IsNullOrWhiteSpace($fields[1])) { throw 'invalid closed VERSION.tsv' }
    $version[$fields[0]] = $fields[1]
}
if ($version.Count -ne $versionAllowed.Count -or $version.schema_version -ne '1' -or
    $version.package_version -notmatch '^[A-Za-z0-9._-]{1,64}$' -or $version.run_id -notmatch '^lan-[a-z0-9][a-z0-9-]{0,31}$' -or
    $version.source_commit -notmatch '^[0-9a-f]{40}$' -or $version.server_ipv4 -notmatch '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' -or
    $version.moq_url -ne "https://$($version.server_ipv4):14433/watch" -or
    $version.player_manifest_sha256 -notmatch '^[0-9a-f]{64}$' -or $version.launcher_contract_sha256 -notmatch '^[0-9a-f]{64}$' -or $version.lan_config_sha256 -notmatch '^[0-9a-f]{64}$' -or
    $version.player_evidence -ne 'not_measured' -or $version.load_launcher_status -ne 'ready') { throw 'VERSION.tsv values are outside the LAN package policy' }
$playerManifest = Join-Path $root 'player\MANIFEST.sha256.json'
$launcherContract = Join-Path $root 'player\lan-launcher.tsv'
$fingerprint = (Get-Content -LiteralPath (Join-Path $root 'public-identity/relay-cert.sha256') -Raw).Trim()
if ($fingerprint -notmatch '^[0-9a-fA-F]{64}$') { throw 'invalid relay certificate fingerprint' }
if (-not (Test-Path -LiteralPath $playerManifest -PathType Leaf) -or -not (Test-Path -LiteralPath $launcherContract -PathType Leaf) -or
    (Get-FileHash -LiteralPath $playerManifest -Algorithm SHA256).Hash.ToLowerInvariant() -ne $version.player_manifest_sha256 -or
    (Get-FileHash -LiteralPath $launcherContract -Algorithm SHA256).Hash.ToLowerInvariant() -ne $version.launcher_contract_sha256) { throw 'VERSION.tsv player manifest/launcher hashes do not match' }
$playerManifestDocument = Get-Content -LiteralPath $playerManifest -Raw | ConvertFrom-Json
$playerManifestKeys = @($playerManifestDocument.PSObject.Properties.Name)
if ($playerManifestKeys.Count -ne 7 -or @($playerManifestKeys | Where-Object { @('schema_version', 'artifact', 'package_version', 'source_commit', 'entrypoint', 'files', 'total_bytes') -notcontains $_ }).Count -ne 0 -or
    $playerManifestDocument.schema_version -ne 1 -or $playerManifestDocument.artifact -ne 'teremoq-lan-lab-standalone' -or
    $playerManifestDocument.package_version -ne $version.package_version -or $playerManifestDocument.source_commit -ne $version.source_commit -or
    $playerManifestDocument.entrypoint -ne 'start.mjs' -or @($playerManifestDocument.files | Where-Object { $_.path -eq 'lan-launcher.tsv' }).Count -ne 1) { throw 'player manifest closed identity/version/source contract mismatch' }
$launcherValues = @{}
foreach ($line in Get-Content -LiteralPath $launcherContract) {
    $fields = $line -split "`t", 3
    if ($fields.Count -ne 2 -or $launcherValues.ContainsKey($fields[0])) { throw 'invalid nine-key launcher contract' }
    $launcherValues[$fields[0]] = $fields[1]
}
$launcherAllowed = @('schema_version', 'source_commit', 'launcher_relative_path', 'launcher_sha256', 'actions', 'levels', 'max_clients', 'network_contract', 'loopback_http_only')
if ($launcherValues.Count -ne 9 -or @($launcherValues.Keys | Where-Object { $launcherAllowed -notcontains $_ }).Count -ne 0 -or
    $launcherValues.source_commit -ne $version.source_commit) { throw 'launcher contract source/schema mismatch' }
$lanConfigPath = Join-Path $root 'LAN-CONFIG.json'
if ((Get-Item -LiteralPath $lanConfigPath).Length -gt 512 -or (Get-FileHash -LiteralPath $lanConfigPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $version.lan_config_sha256) { throw 'LAN-CONFIG.json size/hash mismatch' }
if (((Get-Item -LiteralPath $lanConfigPath).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'LAN-CONFIG.json may not be a symlink/reparse point' }
$lanConfig = Get-Content -LiteralPath $lanConfigPath -Raw | ConvertFrom-Json
$lanKeys = @($lanConfig.PSObject.Properties.Name)
if ($lanKeys.Count -ne 7 -or @($lanKeys | Where-Object { @('schema_version', 'run_id', 'source_commit', 'relay_url', 'fingerprint_sha256', 'prefix_length', 'namespace') -notcontains $_ }).Count -ne 0 -or
    $lanConfig.schema_version -ne 1 -or $lanConfig.run_id -ne $version.run_id -or $lanConfig.source_commit -ne $version.source_commit -or $lanConfig.relay_url -ne $version.moq_url -or
    $lanConfig.fingerprint_sha256 -ne $fingerprint.ToLowerInvariant() -or [int]$lanConfig.prefix_length -lt 8 -or [int]$lanConfig.prefix_length -gt 30 -or
    $lanConfig.namespace -isnot [string] -or $lanConfig.namespace.Length -gt 256 -or
    $lanConfig.namespace -notmatch '^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$' -or
    @($lanConfig.namespace.Split('/') | Where-Object { $_ -in @('.', '..') }).Count -ne 0) { throw 'invalid closed LAN-CONFIG.json' }
$certificateText = Get-Content -LiteralPath (Join-Path $root 'public-identity/relay-cert.pem') -Raw
$match = [regex]::Match($certificateText, '(?s)^\s*-----BEGIN CERTIFICATE-----\s*(?<body>[A-Za-z0-9+/=\r\n]+)\s*-----END CERTIFICATE-----\s*$')
if (-not $match.Success) { throw 'invalid relay public certificate PEM' }
$der = [Convert]::FromBase64String(($match.Groups['body'].Value -replace '\s', ''))
$hasher = [Security.Cryptography.SHA256]::Create()
try { $actualFingerprint = ([BitConverter]::ToString($hasher.ComputeHash($der)) -replace '-', '').ToLowerInvariant() } finally { $hasher.Dispose() }
if ($actualFingerprint -ne $fingerprint.ToLowerInvariant()) { throw 'relay public certificate fingerprint mismatch' }
$forbidden = Get-ChildItem -LiteralPath $root -Recurse -Force -File | Where-Object {
    $_.Name -match '(?i)(\.key$|\.p12$|\.pfx$|^id_rsa$|^\.env$|password|secret|token)'
}
if ($forbidden) { throw 'forbidden credential-like file in package' }
$manifestFiles = @{}
foreach ($line in Get-Content -LiteralPath (Join-Path $root 'SHA256SUMS')) {
    if ($line -notmatch '^([0-9a-f]{64})  (.+)$') { throw 'invalid SHA256SUMS line' }
    $expected = $Matches[1]
    $relative = $Matches[2]
    if ($manifestFiles.ContainsKey($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') { throw 'unsafe or duplicate manifest path' }
    $manifestFiles[$relative.Replace('\', '/')] = $true
    $path = [IO.Path]::GetFullPath((Join-Path $root $relative))
    if (-not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'manifest path escapes package root' }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "manifest file missing: $relative" }
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { throw "checksum mismatch: $relative" }
}
foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -Force -File) {
    $relative = $file.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
    if ($relative -ne 'SHA256SUMS' -and -not $manifestFiles.ContainsKey($relative)) { throw "unlisted package file: $relative" }
}
Write-Output 'Teremoq LAN client checksums and public certificate pin are present; no trust was installed and no network action was performed.'
