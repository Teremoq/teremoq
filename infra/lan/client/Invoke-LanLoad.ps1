# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Validate', 'Start', 'Status', 'Stop', 'Collect')][string]$Action,
    [Parameter(Mandatory = $true)][ValidateSet(1, 5, 10, 25)][int]$Level,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$PackageRoot,
    [Parameter(Mandatory = $true)][string]$EvidenceRoot,
    [switch]$ConfirmStart
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
if ($RunId -notmatch '^lan-[a-z0-9][a-z0-9-]{0,31}$') { throw 'invalid RunId' }
$root = [IO.Path]::GetFullPath($PackageRoot)
$evidenceRootFull = [IO.Path]::GetFullPath($EvidenceRoot)
if (-not (Test-Path -LiteralPath $root -PathType Container) -or -not (Test-Path -LiteralPath $evidenceRootFull -PathType Container)) { throw 'package/evidence root directories must exist' }
foreach ($directory in @($root, $evidenceRootFull)) {
    if (((Get-Item -LiteralPath $directory).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'package/evidence roots may not be reparse points' }
}
$contractPath = Join-Path $root 'player\lan-launcher.tsv'
if (-not (Test-Path -LiteralPath $contractPath -PathType Leaf)) { throw 'pending_owner_integration: TP-WEB-REALTIME LAN launcher contract is absent' }
if ((Get-Item -LiteralPath $contractPath).Length -gt 4096) { throw 'LAN launcher contract exceeds its byte limit' }
$allowed = @('schema_version', 'source_commit', 'launcher_relative_path', 'launcher_sha256', 'actions', 'levels', 'max_clients', 'network_contract', 'loopback_http_only')
$contract = @{}
foreach ($line in Get-Content -LiteralPath $contractPath) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
    $fields = $line -split "`t", 3
    if ($fields.Count -ne 2 -or $allowed -notcontains $fields[0] -or $contract.ContainsKey($fields[0])) { throw 'invalid LAN launcher contract' }
    $contract[$fields[0]] = $fields[1]
}
$versionPath = Join-Path $root 'VERSION.tsv'
if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf) -or (Get-Item -LiteralPath $versionPath).Length -gt 4096) { throw 'VERSION.tsv is absent or oversized' }
$versionAllowed = @('schema_version', 'package_version', 'run_id', 'source_commit', 'server_ipv4', 'moq_url', 'player_manifest_sha256', 'launcher_contract_sha256', 'lan_config_sha256', 'player_evidence', 'load_launcher_status')
$version = @{}
foreach ($line in Get-Content -LiteralPath $versionPath) {
    $fields = $line -split "`t", 3
    if ($fields.Count -ne 2 -or $versionAllowed -notcontains $fields[0] -or $version.ContainsKey($fields[0]) -or [string]::IsNullOrWhiteSpace($fields[1])) { throw 'invalid closed VERSION.tsv' }
    $version[$fields[0]] = $fields[1]
}
if ($version.Count -ne $versionAllowed.Count -or $version.schema_version -ne '1' -or
    $version.package_version -notmatch '^[A-Za-z0-9._-]{1,64}$' -or
    $version.source_commit -notmatch '^[0-9a-f]{40}$' -or $version.run_id -ne $RunId -or
    $version.server_ipv4 -notmatch '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' -or
    $version.moq_url -ne "https://$($version.server_ipv4):14433/watch" -or
    $version.player_manifest_sha256 -notmatch '^[0-9a-f]{64}$' -or $version.launcher_contract_sha256 -notmatch '^[0-9a-f]{64}$' -or $version.lan_config_sha256 -notmatch '^[0-9a-f]{64}$' -or
    $version.player_evidence -ne 'not_measured' -or $version.load_launcher_status -ne 'ready') {
    throw 'VERSION.tsv does not bind this ready launcher to the requested run and exact commit'
}
$lanConfigPath = Join-Path $root 'LAN-CONFIG.json'
if (-not (Test-Path -LiteralPath $lanConfigPath -PathType Leaf) -or (Get-Item -LiteralPath $lanConfigPath).Length -gt 512 -or
    (Get-FileHash -LiteralPath $lanConfigPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $version.lan_config_sha256) { throw 'LAN-CONFIG.json is absent, oversized or differs from VERSION.tsv' }
$lanConfigItem = Get-Item -LiteralPath $lanConfigPath
if (($lanConfigItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'LAN-CONFIG.json may not be a symlink/reparse point' }
$lanConfig = Get-Content -LiteralPath $lanConfigPath -Raw | ConvertFrom-Json
$lanConfigKeys = @($lanConfig.PSObject.Properties.Name)
if ($lanConfigKeys.Count -ne 7 -or @($lanConfigKeys | Where-Object { @('schema_version', 'run_id', 'source_commit', 'relay_url', 'fingerprint_sha256', 'prefix_length', 'namespace') -notcontains $_ }).Count -ne 0 -or
    $lanConfig.schema_version -ne 1 -or $lanConfig.run_id -ne $version.run_id -or $lanConfig.source_commit -ne $version.source_commit -or $lanConfig.relay_url -ne $version.moq_url -or
    $lanConfig.fingerprint_sha256 -notmatch '^[0-9a-f]{64}$' -or [int]$lanConfig.prefix_length -lt 8 -or [int]$lanConfig.prefix_length -gt 30 -or
    $lanConfig.namespace -isnot [string] -or $lanConfig.namespace.Length -gt 256 -or
    $lanConfig.namespace -notmatch '^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$' -or
    @($lanConfig.namespace.Split('/') | Where-Object { $_ -in @('.', '..') }).Count -ne 0) { throw 'LAN-CONFIG.json closed public connection contract is invalid' }
$pinValue = (Get-Content -LiteralPath (Join-Path $root 'public-identity\relay-cert.sha256') -Raw).Trim().ToLowerInvariant()
if ($lanConfig.fingerprint_sha256 -ne $pinValue) { throw 'LAN-CONFIG.json fingerprint differs from the packaged public pin' }
if ($contract.Count -ne $allowed.Count -or $contract.schema_version -ne '1' -or
    $contract.source_commit -ne $version.source_commit -or
    $contract.actions -ne 'start,status,stop,collect' -or $contract.levels -ne '1,5,10,25' -or
    $contract.max_clients -ne '25' -or $contract.network_contract -ne 'outbound_udp_14433_only' -or
    $contract.loopback_http_only -ne 'true' -or $contract.launcher_relative_path -notmatch '^[A-Za-z0-9._-]+\.ps1$' -or
    $contract.launcher_sha256 -notmatch '^[0-9a-f]{64}$') { throw 'LAN launcher contract values are outside policy' }
$launcher = [IO.Path]::GetFullPath((Join-Path (Join-Path $root 'player') $contract.launcher_relative_path))
$playerRoot = [IO.Path]::GetFullPath((Join-Path $root 'player'))
if (-not $launcher.StartsWith($playerRoot, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw 'LAN launcher path is unavailable or escapes player/' }
$actual = (Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $contract.launcher_sha256) { throw 'LAN launcher checksum mismatch' }
$contractDigest = (Get-FileHash -LiteralPath $contractPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($contractDigest -ne $version.launcher_contract_sha256) { throw 'VERSION.tsv launcher contract hash mismatch' }
$manifestPath = Join-Path $playerRoot 'MANIFEST.sha256.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or (Get-Item -LiteralPath $manifestPath).Length -gt 1MB) { throw 'standalone manifest is absent or oversized' }
$manifestDigest = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($manifestDigest -ne $version.player_manifest_sha256) { throw 'VERSION.tsv player manifest hash mismatch' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$manifestKeys = @($manifest.PSObject.Properties.Name)
$expectedManifestKeys = @('schema_version', 'artifact', 'package_version', 'source_commit', 'entrypoint', 'files', 'total_bytes')
if ($manifestKeys.Count -ne $expectedManifestKeys.Count -or @($manifestKeys | Where-Object { $expectedManifestKeys -notcontains $_ }).Count -ne 0 -or
    $manifest.schema_version -ne 1 -or $manifest.artifact -ne 'teremoq-lan-lab-standalone' -or
    $manifest.package_version -ne $version.package_version -or $manifest.source_commit -ne $version.source_commit -or
    $manifest.entrypoint -ne 'start.mjs') { throw 'standalone manifest identity/version/source contract mismatch' }
$listed = @{}
[long]$manifestBytes = 0
foreach ($record in @($manifest.files)) {
    $recordKeys = @($record.PSObject.Properties.Name)
    if ($recordKeys.Count -ne 3 -or @($recordKeys | Where-Object { @('path', 'bytes', 'sha256') -notcontains $_ }).Count -ne 0 -or
        $record.path -notmatch '^[A-Za-z0-9._/-]+$' -or $record.path.Contains('..') -or $record.path.Contains('\') -or
        $listed.ContainsKey($record.path) -or $record.sha256 -notmatch '^[0-9a-f]{64}$' -or [long]$record.bytes -lt 0) { throw 'standalone manifest file record is outside policy' }
    $listed[$record.path] = $true
    $manifestBytes += [long]$record.bytes
    $listedPath = [IO.Path]::GetFullPath((Join-Path $playerRoot $record.path))
    if (-not $listedPath.StartsWith($playerRoot, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $listedPath -PathType Leaf) -or
        (Get-Item -LiteralPath $listedPath).Length -ne [long]$record.bytes -or
        (Get-FileHash -LiteralPath $listedPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $record.sha256) { throw 'standalone manifest file hash/size mismatch' }
}
if ($listed.Count -lt 1 -or $listed.Count -gt 10000 -or $manifestBytes -ne [long]$manifest.total_bytes -or $manifestBytes -gt 128MB -or -not $listed.ContainsKey('start.mjs')) {
    throw 'standalone manifest inventory/size is outside policy'
}
$allowedUnlisted = @('MANIFEST.sha256.json')
foreach ($file in Get-ChildItem -LiteralPath $playerRoot -File -Recurse) {
    $relative = $file.FullName.Substring($playerRoot.Length).TrimStart('\', '/').Replace('\', '/')
    if (-not $listed.ContainsKey($relative) -and $allowedUnlisted -notcontains $relative) { throw 'player contains a file outside its closed manifest' }
}
if (-not $listed.ContainsKey('lan-launcher.tsv') -or -not $listed.ContainsKey($contract.launcher_relative_path)) { throw 'closed player manifest omits launcher contract/artifact' }
$node = Get-Command node.exe -ErrorAction SilentlyContinue
$nodeVersion = if ($node) { (& $node.Source --version 2>$null | Out-String).Trim() } else { 'unavailable' }
if ($nodeVersion -notmatch '^v22\.[0-9]+\.[0-9]+$') { throw 'approved Node 22.x runtime is required; no runtime is embedded or installed' }
if ($Action -eq 'Validate') { Write-Output 'TP-WEB-REALTIME LAN launcher contract valid; no player started.'; exit 0 }
if ($Action -eq 'Start' -and -not $ConfirmStart) { throw 'Start requires -ConfirmStart' }
if ($Action -eq 'Start' -and @(Get-NetTCPConnection -State Listen -LocalPort 3000 -ErrorAction SilentlyContinue).Count -ne 0) { throw 'reserved player loopback TCP/3000 is occupied' }
$evidence = Join-Path (Join-Path $evidenceRootFull $RunId) "level-$Level"
if ($Action -eq 'Start') {
    if (Test-Path -LiteralPath $evidence) { throw 'deterministic player evidence directory already exists' }
    New-Item -ItemType Directory -Path $evidence -Force | Out-Null
} elseif (-not (Test-Path -LiteralPath $evidence -PathType Container)) {
    throw 'deterministic player evidence directory does not exist for this action'
}
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $launcher `
    -Action $Action -RunId $RunId -Level $Level -VersionPath (Join-Path $root 'VERSION.tsv') `
    -FingerprintPath (Join-Path $root 'public-identity\relay-cert.sha256') -EvidenceDirectory $evidence
if ($LASTEXITCODE -ne 0) { throw "TP-WEB-REALTIME LAN launcher failed: $LASTEXITCODE" }
if ($Action -eq 'Collect') { Write-Output 'Import the exact browser JSON with Import-BrowserObservation.ps1; launcher output/hash alone is not composite gate evidence.' }
