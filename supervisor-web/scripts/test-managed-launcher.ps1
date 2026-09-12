# SPDX-License-Identifier: Apache-2.0
# Real Core7 launcher / real Platform slot producer. Sealed files are TEST
# fixtures, not a built player, browser observation or a live Prepare/build run.
[CmdletBinding()]
param([string]$OutputRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
if ($PSVersionTable.PSEdition -cne 'Core' -or
    $PSVersionTable.PSVersion.ToString() -cne '7.6.6' -or
    [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
    [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() -cne 'X64') {
  throw 'managed launcher focal requires selected Windows x64 Core7 7.6.6'
}
$WebRoot = Split-Path -Parent $PSScriptRoot
$RepoRoot = Split-Path -Parent $WebRoot
if (-not $OutputRoot) { $OutputRoot = Join-Path $WebRoot ('evidence/managed-v2-' + [guid]::NewGuid().ToString('N')) }
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) { throw 'test output must be new' }
if (-not $OutputRoot.StartsWith((Join-Path $WebRoot 'evidence') + [IO.Path]::DirectorySeparatorChar)) {
  throw 'test output must remain inside supervisor-web/evidence'
}
[void][IO.Directory]::CreateDirectory($OutputRoot)
. (Join-Path $RepoRoot 'infra/lan/client/Client-Slot-State.ps1')
$Utf8 = New-Object Text.UTF8Encoding($false, $true)
$Results = New-Object 'System.Collections.Generic.List[string]'
# Runtime representation probe, not a replacement for the full launcher below.
$JsonProbe = ConvertFrom-Json -InputObject '{"number":1,"timestamp":"2026-09-12T00:00:00Z"}' -DateKind String
if ($JsonProbe.number -isnot [long] -or $JsonProbe.timestamp -isnot [string]) {
  throw 'Core7 JSON representation differs from the reviewed integer/string policy'
}
$Results.Add('real-core7-json-int64-and-datekind-string')
function Put([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, $Utf8) }
function Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Tsv($Value) { return (($Value.Keys | ForEach-Object { "$_`t$($Value[$_])" }) -join "`n") + "`n" }
function Save-Context($Fixture) {
  Put $Fixture.ActivePath ((ConvertTo-TeremoqLanSlotJson $Fixture.Record) + "`n")
  Put $Fixture.VersionPath (Tsv $Fixture.Version)
  Put $Fixture.CompatibilityPath (Tsv $Fixture.Compatibility)
  Put (Join-Path $Fixture.VersionRoot 'SHA256SUMS') (
    (Hash $Fixture.CompatibilityPath) + "  CLIENT-COMPATIBILITY.tsv`n" +
    (Hash $Fixture.VersionPath) + "  VERSION.tsv`n")
}
function Seal-Config($Fixture, [string]$Text) {
  Put $Fixture.ConfigPath $Text
  $Digest = Hash $Fixture.ConfigPath
  $Fixture.Record.config_sha256 = $Digest
  $Fixture.Version.lan_config_sha256 = $Digest
  $Fixture.Compatibility.lan_config_sha256 = $Digest
  Save-Context $Fixture
}
function Seal-Manifest($Fixture) {
  Put $Fixture.ManifestPath ((ConvertTo-Json -InputObject $Fixture.Manifest -Depth 8 -Compress) + "`n")
  $Digest = Hash $Fixture.ManifestPath
  $Fixture.Record.player_manifest_sha256 = $Digest
  $Fixture.Version.player_manifest_sha256 = $Digest
  $Fixture.Compatibility.player_manifest_sha256 = $Digest
  Save-Context $Fixture
}
function New-Fixture([string]$Name) {
  # Keep executable-shaped fixtures out of ESLint/Vitest automatic discovery.
  $Root = [IO.Path]::GetFullPath((Join-Path $OutputRoot ('node_modules/' + $Name)))
  $StateRoot = Join-Path $Root 'state'
  $SourceTree = 'a' * 40
  $LockHash = 'b' * 64
  $Commit = 'c' * 40
  $Identity = Get-TeremoqLanPlayerIdentity -SourceTree $SourceTree -PackageLockSha256 $LockHash
  $PlayerRoot = Join-Path $StateRoot ('players/sha256-' + $Identity.Substring(7))
  $ConfigRoot = Join-Path $StateRoot 'config'
  foreach ($Path in @($PlayerRoot, (Join-Path $ConfigRoot 'public-identity'), (Join-Path $StateRoot 'control'))) {
    [void][IO.Directory]::CreateDirectory($Path)
  }
  $Launcher = Join-Path $PlayerRoot 'teremoq-lan-platform.ps1'
  [IO.File]::Copy((Join-Path $PSScriptRoot 'teremoq-lan-platform.ps1'), $Launcher)
  foreach ($Name in @('server.js','start.mjs','validate-lan-evidence.mjs')) {
    Put (Join-Path $PlayerRoot $Name) 'throw new Error("TEST FIXTURE MUST NEVER EXECUTE");'
  }
  $Package = [ordered]@{ schema_version='1'; launcher_relative_path='teremoq-lan-platform.ps1'
    launcher_sha256=(Hash $Launcher); actions='start,status,stop,collect'; levels='1,5,10,25'
    max_clients='25'; network_contract='outbound_udp_14433_only'; loopback_http_only='true'
    updater_version='2.0.0'; player_identity=$Identity; player_version='0.1.0'; config_schema_version='1' }
  $PackagePath = Join-Path $PlayerRoot 'lan-launcher.tsv'
  Put $PackagePath (Tsv $Package)
  $Files = @(Get-ChildItem -LiteralPath $PlayerRoot -File | Sort-Object Name | ForEach-Object {
    [pscustomobject][ordered]@{ bytes=$_.Length; path=$_.Name; sha256=(Hash $_.FullName) }
  })
  $Manifest = [ordered]@{ schema_version=1; artifact='teremoq-lan-lab-standalone'; entrypoint='start.mjs'
    package_version='0.1.0'; updater_version='2.0.0'; player_identity=$Identity
    player_version='0.1.0'; config_schema_version=1; files=$Files
    total_bytes=[long]($Files | Measure-Object bytes -Sum).Sum }
  $ManifestPath = Join-Path $PlayerRoot 'MANIFEST.sha256.json'
  Put $ManifestPath ((ConvertTo-Json -InputObject $Manifest -Depth 8 -Compress) + "`n")
  $Config = [ordered]@{ schema_version=1; run_id='lan-managed-test'; relay_url='https://192.168.1.130:14433/watch'
    fingerprint_sha256=('d' * 64); prefix_length=24; namespace='fixture/main' }
  $ConfigPath = Join-Path $ConfigRoot 'LAN-CONFIG.json'
  Put $ConfigPath (($Config | ConvertTo-Json -Compress) + "`n")
  $FingerprintPath = [IO.Path]::GetFullPath((Join-Path $ConfigRoot 'public-identity/relay-cert.sha256'))
  Put $FingerprintPath (('d' * 64) + "`n")
  # Use Platform's production producer, not an independently invented slot schema.
  $Record = New-TeremoqLanSlotRecord -UpdaterCommit $Commit -PlayerIdentity $Identity -SourceTree $SourceTree `
    -PackageLockSha256 $LockHash -PlayerManifestSha256 (Hash $ManifestPath) `
    -LauncherContractSha256 (Hash $PackagePath) -ConfigSha256 (Hash $ConfigPath)
  $VersionRoot = [IO.Path]::GetFullPath((Join-Path $StateRoot $Record.version_relative_path))
  [void][IO.Directory]::CreateDirectory($VersionRoot)
  $Version = [ordered]@{ schema_version='2'; updater_version='2.0.0'; updater_commit=$Commit
    player_identity=$Identity; player_version='0.1.0'; config_schema_version='1'; run_id=$Config.run_id
    server_ipv4='192.168.1.130'; moq_url=$Config.relay_url; player_manifest_sha256=(Hash $ManifestPath)
    launcher_contract_sha256=(Hash $PackagePath); lan_config_sha256=(Hash $ConfigPath)
    player_evidence='not_measured'; load_launcher_status='ready' }
  $Compatibility = [ordered]@{ schema_version='2'; repository_url='https://github.com/Teremoq/teremoq'
    repository_ref='refs/heads/fixture'; repository_subdirectory='infra/lan'; allowed_client_commit=$Commit
    updater_version='2.0.0'; updater_protocol='teremoq-lan-updater-v3'; player_identity=$Identity
    player_version='0.1.0'; source_tree=$SourceTree; package_lock_sha256=$LockHash
    player_relative_path=$Record.player_relative_path; config_schema_version='1'
    player_manifest_sha256=(Hash $ManifestPath); launcher_contract_sha256=(Hash $PackagePath)
    lan_config_sha256=(Hash $ConfigPath) }
  $Fixture = [pscustomobject]@{ Root=$Root; StateRoot=$StateRoot; PlayerRoot=$PlayerRoot; Launcher=$Launcher
    ActivePath=(Join-Path $StateRoot 'control/active.json'); VersionRoot=$VersionRoot
    VersionPath=(Join-Path $VersionRoot 'VERSION.tsv'); CompatibilityPath=(Join-Path $VersionRoot 'CLIENT-COMPATIBILITY.tsv')
    ConfigPath=$ConfigPath; FingerprintPath=$FingerprintPath; Record=$Record; Version=$Version
    Compatibility=$Compatibility; Config=$Config; Manifest=$Manifest; ManifestPath=$ManifestPath }
  Save-Context $Fixture
  return $Fixture
}
function Tree-Hash([string]$Root) {
  return (@(Get-ChildItem -LiteralPath $Root -Recurse -Force | Sort-Object FullName | ForEach-Object {
    if ($_.PSIsContainer) { 'directory:' + $_.FullName } else { $_.FullName + ':' + (Hash $_.FullName) }
  }) -join "`n")
}
function Validate($Fixture, [int]$Level = 1) {
  $Before = Tree-Hash $Fixture.Root
  $EnvironmentBefore = @(Get-ChildItem Env: | Sort-Object Name | ForEach-Object { $_.Name + '=' + $_.Value }) -join "`n"
  $Evidence = [IO.Path]::GetFullPath((Join-Path $Fixture.Root "absent-evidence/lan-managed-test/level-$Level"))
  $Output = & $Fixture.Launcher -Action Start -ValidateOnly -StateRoot $Fixture.StateRoot `
    -RunId 'lan-managed-test' -Level $Level -VersionPath $Fixture.VersionPath `
    -FingerprintPath $Fixture.FingerprintPath -EvidenceDirectory $Evidence
  $Receipt = $Output | ConvertFrom-Json
  if ($Receipt.status -cne 'validated' -or $Receipt.level -ne $Level -or
      $Receipt.updater_commit -cne $Fixture.Record.updater_commit -or
      $Receipt.player_identity -cne $Fixture.Record.player_identity) { throw 'invalid validation receipt' }
  if ((Test-Path -LiteralPath $Evidence) -or (Tree-Hash $Fixture.Root) -cne $Before) { throw 'validation mutated files' }
  if ((@(Get-ChildItem Env: | Sort-Object Name | ForEach-Object { $_.Name + '=' + $_.Value }) -join "`n") -cne $EnvironmentBefore) {
    throw 'validation mutated environment'
  }
}
function Reject([string]$Name, [scriptblock]$Mutation) {
  $Fixture = New-Fixture $Name
  & $Mutation $Fixture
  $Rejected = $false
  try { Validate $Fixture } catch { $Rejected = $true }
  if (-not $Rejected) { throw "adversarial case accepted: $Name" }
  # Even failed parsing must release descriptors before returning to the owner.
  if (Test-Path -LiteralPath $Fixture.ActivePath) {
    $Released = [IO.File]::Open($Fixture.ActivePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $Released.Dispose()
  }
  $Results.Add($Name)
}
# Any accidental product process or command lookup on the validation path fails.
function Start-Process { throw 'forbidden product process' }
function Get-Command { throw 'forbidden command lookup' }
function Add-Type { throw 'forbidden compiler on ValidateOnly path' }
$Valid = New-Fixture 'valid'
foreach ($Level in @(1,5,10,25)) { Validate $Valid $Level; $Results.Add("valid-level-$Level-no-effects") }
function Test-RetainedPins($Fixture) {
  $Probe = @{ Count = 0 }
  $Targets = @($Fixture.ActivePath, $Fixture.VersionPath, $Fixture.ConfigPath,
    $Fixture.ManifestPath, $Fixture.Launcher, (Join-Path $Fixture.PlayerRoot 'server.js'),
    (Join-Path $Fixture.PlayerRoot 'validate-lan-evidence.mjs'))
  function ConvertTo-Json {
    param([Parameter(ValueFromPipeline=$true)]$InputObject, [int]$Depth=2, [switch]$Compress)
    process {
      if ($InputObject -is [pscustomobject] -and
          $InputObject.PSObject.Properties.Name -contains 'status' -and $InputObject.status -ceq 'validated') {
        foreach ($Target in $Targets) {
          $Writer = $null
          try { $Writer = [IO.File]::Open($Target, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite) }
          catch [IO.IOException] { $Probe.Count += 1 }
          if ($null -ne $Writer) { $Writer.Dispose(); throw 'verified dependency was writable before return' }
        }
      }
      Microsoft.PowerShell.Utility\ConvertTo-Json -InputObject $InputObject -Depth $Depth -Compress:$Compress
    }
  }
  Validate $Fixture
  if ($Probe.Count -ne $Targets.Count) { throw 'retained-descriptor canary did not reach receipt boundary' }
  foreach ($Target in $Targets) {
    $Released = [IO.File]::Open($Target, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $Released.Dispose()
  }
}
Test-RetainedPins $Valid
$Results.Add('retained-descriptors-deny-writes-then-release')
Reject 'active-unknown' { param($F) Put $F.ActivePath (([IO.File]::ReadAllText($F.ActivePath)).Replace('"schema_version":1','"unknown":1,"schema_version":1')) }
Reject 'active-duplicate' { param($F) Put $F.ActivePath (([IO.File]::ReadAllText($F.ActivePath)).Replace('"schema_version":1','"schema_version":1,"schema_version":1')) }
Reject 'active-bool' { param($F) Put $F.ActivePath (([IO.File]::ReadAllText($F.ActivePath)).Replace('"schema_version":1','"schema_version":true')) }
Reject 'active-oversize' { param($F) Put $F.ActivePath (' ' * 4097) }
Reject 'active-missing' { param($F) [IO.File]::Move($F.ActivePath, $F.ActivePath + '.absent') }
Reject 'identity-tree-mismatch' { param($F) Put $F.ActivePath (([IO.File]::ReadAllText($F.ActivePath)).Replace(('a' * 40), ('e' * 40))) }
Reject 'inactive-version-path' { param($F) $Other=Join-Path $F.Root 'VERSION.tsv'; [IO.File]::Copy($F.VersionPath,$Other); $F.VersionPath=$Other }
Reject 'version-v1' { param($F) $F.Version.schema_version='1'; Save-Context $F }
Reject 'version-duplicate' { param($F) Put $F.VersionPath (([IO.File]::ReadAllText($F.VersionPath)) + "schema_version`t2`n") }
Reject 'version-commit-mismatch' { param($F) $F.Version.updater_commit='e'*40; Save-Context $F }
Reject 'compatibility-hash-mismatch' { param($F) $F.Compatibility.lan_config_sha256='e'*64; Save-Context $F }
Reject 'sums-mismatch' { param($F) Put (Join-Path $F.VersionRoot 'SHA256SUMS') (('0'*64)+"  VERSION.tsv`n") }
Reject 'config-seven' { param($F) $F.Config.source_commit='c'*40; Seal-Config $F (($F.Config | ConvertTo-Json -Compress)+"`n") }
Reject 'config-duplicate' { param($F) Seal-Config $F (([IO.File]::ReadAllText($F.ConfigPath)).Replace('"schema_version":1','"schema_version":1,"schema_version":1')) }
Reject 'config-bool-prefix' { param($F) $F.Config.prefix_length=$true; Seal-Config $F (($F.Config | ConvertTo-Json -Compress)+"`n") }
Reject 'config-oversize' { param($F) Seal-Config $F (' ' * 513) }
Reject 'config-hash-mismatch' { param($F) Put $F.ConfigPath (([IO.File]::ReadAllText($F.ConfigPath))+' ') }
Reject 'config-public-host' { param($F) $F.Config.relay_url='https://8.8.8.8:14433/watch'; Seal-Config $F (($F.Config | ConvertTo-Json -Compress)+"`n") }
Reject 'config-publish-path' { param($F) $F.Config.relay_url='https://192.168.1.130:14433/publish'; Seal-Config $F (($F.Config | ConvertTo-Json -Compress)+"`n") }
Reject 'config-runtime-overflow' { param($F) $F.Config.namespace='n'*240; Seal-Config $F (($F.Config | ConvertTo-Json -Compress)+"`n") }
Reject 'pin-mismatch' { param($F) Put $F.FingerprintPath (('e'*64)+"`n") }
Reject 'pin-wrong-path' { param($F) $Other=Join-Path $F.Root 'pin.sha256'; [IO.File]::Copy($F.FingerprintPath,$Other); $F.FingerprintPath=$Other }
Reject 'inventory-extra' { param($F) Put (Join-Path $F.PlayerRoot 'extra') 'test' }
Reject 'evidence-file-ancestor' { param($F) Put (Join-Path $F.Root 'absent-evidence') 'not-a-directory' }
Reject 'inventory-missing' { param($F) [IO.File]::Move((Join-Path $F.PlayerRoot 'server.js'),(Join-Path $F.Root 'server-removed.js')) }
Reject 'inventory-changed' { param($F) Put (Join-Path $F.PlayerRoot 'server.js') 'changed' }
Reject 'manifest-unknown' { param($F) $F.Manifest.unknown=$true; Seal-Manifest $F }
Reject 'manifest-collection-type' { param($F) $F.Manifest.files=[pscustomobject]@{ invalid=1 }; Seal-Manifest $F }
Reject 'manifest-cardinality' { param($F) $F.Manifest.files=@(0..10000); Seal-Manifest $F }
Reject 'manifest-size-limit' { param($F) Put $F.ManifestPath (' ' * 1048577) }
Reject 'manifest-nested-unknown' { param($F) $F.Manifest.files[0] | Add-Member -NotePropertyName unknown -NotePropertyValue 1; Seal-Manifest $F }
Reject 'manifest-bool-bytes' { param($F) $F.Manifest.files[0].bytes=$true; Seal-Manifest $F }
Reject 'manifest-traversal' { param($F) $F.Manifest.files[0].path='../escape'; Seal-Manifest $F }
# Core7 deserializes integer JSON tokens as Int64. Accepting those must NOT
# accept coercible strings, floating point or booleans in any schema field.
foreach ($DocumentKind in @('active','config','manifest')) {
  $Fields = if ($DocumentKind -ceq 'config') { @('schema_version') } else { @('schema_version','config_schema_version') }
  foreach ($Field in $Fields) {
    foreach ($Case in @(@('string','"1"'), @('float','1.0'), @('bool','true'))) {
      $Token = $Case[1]
      Reject ("$DocumentKind-$Field-" + $Case[0]) {
        param($F)
        $Needle = '"' + $Field + '":1'
        $Replacement = '"' + $Field + '":' + $Token
        if ($DocumentKind -ceq 'active') {
          Put $F.ActivePath (([IO.File]::ReadAllText($F.ActivePath)).Replace($Needle,$Replacement))
        } elseif ($DocumentKind -ceq 'config') {
          Seal-Config $F (([IO.File]::ReadAllText($F.ConfigPath)).Replace($Needle,$Replacement))
        } else {
          # Preserve the exact adversarial token, not a serializer's numeric normalization.
          Put $F.ManifestPath (([IO.File]::ReadAllText($F.ManifestPath)).Replace($Needle,$Replacement))
          $Digest = Hash $F.ManifestPath
          $F.Record.player_manifest_sha256 = $Digest
          $F.Version.player_manifest_sha256 = $Digest
          $F.Compatibility.player_manifest_sha256 = $Digest
          Save-Context $F
        }
      }
    }
  }
}
$PriorConfig=$env:TEREMOQ_LAN_LAB_CONFIG
try {
  $env:TEREMOQ_LAN_LAB_CONFIG='{"untrusted":true}'
  Reject 'inherited-config-mismatch' { param($F) }
} finally { $env:TEREMOQ_LAN_LAB_CONFIG=$PriorConfig }
$Summary = [ordered]@{ schema_version=1; kind='offline-core7-contract-fixtures-not-live-prepare'
  powershell_version=$PSVersionTable.PSVersion.ToString(); edition=$PSVersionTable.PSEdition
  architecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
  launcher_sha256=(Hash (Join-Path $PSScriptRoot 'teremoq-lan-platform.ps1'))
  platform_slot_producer_sha256=(Hash (Join-Path $RepoRoot 'infra/lan/client/Client-Slot-State.ps1'))
  passed=$Results.Count; cases=@($Results); product_processes_started=0; measurement_status='not_measured' }
Put (Join-Path $OutputRoot 'result.json') (($Summary | ConvertTo-Json -Depth 5) + "`n")
$Summary | ConvertTo-Json -Depth 5
