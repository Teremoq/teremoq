[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("start", "status", "stop", "collect")]
  [string]$Action,
  [Parameter(Mandatory = $true)]
  [ValidatePattern("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")]
  [string]$RunId,
  [Parameter(Mandatory = $true)]
  [ValidateSet(1, 5, 10, 25)]
  [int]$Level,
  [Parameter(Mandatory = $true)]
  [string]$VersionPath,
  [Parameter(Mandatory = $true)]
  [string]$FingerprintPath,
  [Parameter(Mandatory = $true)]
  [string]$EvidenceDirectory,
  [Parameter(Mandatory = $true)]
  [string]$StateRoot,
  [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"
$ScriptRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$PackageContractPath = Join-Path $ScriptRoot "lan-launcher.tsv"
$ManifestPath = Join-Path $ScriptRoot "MANIFEST.sha256.json"
$ServerPath = Join-Path $ScriptRoot "server.js"
$EvidenceValidatorPath = Join-Path $ScriptRoot "validate-lan-evidence.mjs"
$PinnedStreams = New-Object 'System.Collections.Generic.List[System.IO.FileStream]'
if ($ValidateOnly -and $Action -ine "start") {
  throw "ValidateOnly requiere la accion start."
}

# Managed v2 is an external deployment context, never part of player identity.
# Check every ancestor, including when the evidence leaf does not exist yet.
function Assert-CanonicalPath([string]$Path, [switch]$AllowMissing) {
  if (-not [IO.Path]::IsPathRooted($Path) -or $Path.Length -gt 4096 -or
      $Path -match '[\x00-\x1f]' -or $Path -match '(^|[\\/])[.][.]?([\\/]|$)') {
    throw "Ruta contractual no canonica."
  }
  $Full = [IO.Path]::GetFullPath($Path)
  if ($Full -cne $Path) { throw "Ruta contractual no canonica." }
  $Current = $Full
  while ($Current) {
    if (Test-Path -LiteralPath $Current) {
      $Item = Get-Item -LiteralPath $Current -Force
      if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Ruta contractual contiene reparse point."
      }
      if ($Current -cne $Full -and -not $Item.PSIsContainer) { throw "Ancestro no es directorio." }
    } elseif (-not $AllowMissing) { throw "Ruta contractual ausente." }
    $Parent = [IO.Directory]::GetParent($Current)
    $Current = if ($null -eq $Parent) { $null } else { $Parent.FullName }
  }
  return $Full
}

function Get-BytesHash([byte[]]$Bytes) {
  $Hash = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($Hash.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant() }
  finally { $Hash.Dispose() }
}

# Bind the Windows handle API in-process: Add-Type on PS 5.1 can spawn a compiler,
# which is deliberately forbidden on the ValidateOnly path.
$NativeAssembly = [AppDomain]::CurrentDomain.DefineDynamicAssembly(
  (New-Object Reflection.AssemblyName 'TeremoqManagedLauncher'), [Reflection.Emit.AssemblyBuilderAccess]::Run)
$NativeModule = $NativeAssembly.DefineDynamicModule('Handles')
$NativeBuilder = $NativeModule.DefineType('ManagedLauncherHandles', [Reflection.TypeAttributes]::Public)
$NativeMethod = $NativeBuilder.DefinePInvokeMethod('GetFinalPathNameByHandleW', 'kernel32.dll',
  [Reflection.MethodAttributes]'Public, Static, PinvokeImpl', [Reflection.CallingConventions]::Standard,
  [uint32], [type[]]@([Microsoft.Win32.SafeHandles.SafeFileHandle], [Text.StringBuilder], [uint32], [uint32]),
  [Runtime.InteropServices.CallingConvention]::Winapi, [Runtime.InteropServices.CharSet]::Unicode)
$NativeMethod.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)
$NativeHandleType = $NativeBuilder.CreateType()
function Assert-OpenedPath([IO.FileStream]$Stream, [string]$Expected) {
  $Buffer = New-Object Text.StringBuilder 32768
  $Length = $NativeHandleType::GetFinalPathNameByHandleW(
    $Stream.SafeFileHandle, $Buffer, [uint32]$Buffer.Capacity, [uint32]0)
  if ($Length -eq 0 -or $Length -ge $Buffer.Capacity) { throw "No se pudo verificar el descriptor." }
  $Actual = $Buffer.ToString()
  if ($Actual.StartsWith('\\?\UNC\')) { $Actual = '\\' + $Actual.Substring(8) }
  elseif ($Actual.StartsWith('\\?\')) { $Actual = $Actual.Substring(4) }
  if (-not [string]::Equals($Actual, $Expected, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Descriptor fuera de la ruta verificada."
  }
}

# Bounds, bytes and SHA refer to the SAME open descriptor. Windows sharing denies
# writes/deletion while reading. Never stat a file and then reopen it to hash/parse.
function Read-BoundedDocument([string]$Path, [int]$Limit) {
  $Path = [IO.Path]::GetFullPath($Path)
  [void](Assert-CanonicalPath $Path)
  $Stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  $Retained = $false
  try {
    Assert-OpenedPath $Stream $Path
    if ($Stream.Length -lt 1 -or $Stream.Length -gt $Limit) { throw "Documento fuera de limite." }
    $Bytes = New-Object byte[] ([int]$Stream.Length)
    $Offset = 0
    while ($Offset -lt $Bytes.Length) {
      $Read = $Stream.Read($Bytes, $Offset, $Bytes.Length - $Offset)
      if ($Read -le 0) { throw "Documento incompleto." }
      $Offset += $Read
    }
    if ($Stream.ReadByte() -ne -1) { throw "Documento excede limite abierto." }
    [void](Assert-CanonicalPath $Path)
    $Utf8 = New-Object Text.UTF8Encoding($false, $true)
    $Document = [pscustomobject]@{ Text = $Utf8.GetString($Bytes); Sha256 = Get-BytesHash $Bytes }
    $PinnedStreams.Add($Stream)
    $Retained = $true
    return $Document
  } finally { if (-not $Retained) { $Stream.Dispose() } }
}

function Convert-ClosedTsv([string]$Text, [string[]]$ExpectedKeys) {
  $Result = @{}
  if (-not $Text.EndsWith("`n")) { throw "TSV contractual no canonico." }
  foreach ($Line in $Text.TrimEnd("`n").Split("`n")) {
    $Parts = $Line.Split("`t")
    if ($Parts.Count -ne 2 -or [string]::IsNullOrEmpty($Parts[0]) -or
        $Result.ContainsKey($Parts[0]) -or $ExpectedKeys -cnotcontains $Parts[0]) {
      throw "TSV contractual inválido o abierto."
    }
    $Result[$Parts[0]] = $Parts[1]
  }
  if ($Result.Count -ne $ExpectedKeys.Count -or
      @($ExpectedKeys | Where-Object { -not $Result.ContainsKey($_) }).Count -ne 0) {
    throw "TSV contractual incompleto."
  }
  return $Result
}

function Test-ExactProperties([object]$Value, [string[]]$ExpectedKeys) {
  if ($Value -isnot [pscustomobject]) { return $false }
  $Keys = @($Value.PSObject.Properties.Name)
  return $Keys.Count -eq $ExpectedKeys.Count -and
    @($Keys | Where-Object { $ExpectedKeys -cnotcontains $_ }).Count -eq 0
}

function Convert-CanonicalJson([string]$Text) {
  # Use the native JSON implementation, then require its canonical token spelling.
  # This rejects overwritten duplicate keys (including escaped aliases), rather
  # than accepting ConvertFrom-Json's last-value-wins behaviour on PS 5.1.
  $Value = ConvertFrom-Json -InputObject $Text
  $Compact = [regex]::Replace($Text, '("(?:[^"\\]|\\.)*")|\s+', {
    param($Match)
    if ($Match.Groups[1].Success) { return $Match.Value }
    return ''
  })
  if ($Compact -cne (ConvertTo-Json -InputObject $Value -Depth 12 -Compress)) {
    throw "JSON contractual no canonico o duplicado."
  }
  return $Value
}

try {
$ResolvedStateRoot = Assert-CanonicalPath $StateRoot
$ActiveDocument = Read-BoundedDocument (Join-Path $ResolvedStateRoot 'control/active.json') 4096
$Active = Convert-CanonicalJson $ActiveDocument.Text
$ActiveKeys = @('schema_version','updater_version','updater_protocol','updater_commit',
  'player_identity','source_tree','package_lock_sha256','player_manifest_sha256',
  'launcher_contract_sha256','config_schema_version','config_sha256','slot_id',
  'player_relative_path','version_relative_path')
if (-not (Test-ExactProperties $Active $ActiveKeys) -or
    $Active.schema_version -isnot [int] -or $Active.schema_version -ne 1 -or
    $Active.config_schema_version -isnot [int] -or $Active.config_schema_version -ne 1 -or
    $Active.updater_version -cne '2.0.0' -or $Active.updater_protocol -cne 'teremoq-lan-updater-v3') {
  throw "Slot activo fuera de contrato."
}
foreach ($Key in $ActiveKeys | Where-Object { $_ -notin @('schema_version','config_schema_version') }) {
  if ($Active.$Key -isnot [string]) { throw "Tipo de slot activo invalido." }
}
foreach ($Key in @('updater_commit','source_tree')) {
  if ($Active.$Key -cnotmatch '^[0-9a-f]{40}$') { throw "Commit de slot invalido." }
}
foreach ($Key in @('package_lock_sha256','player_manifest_sha256','launcher_contract_sha256','config_sha256')) {
  if ($Active.$Key -cnotmatch '^[0-9a-f]{64}$') { throw "Hash de slot invalido." }
}
$IdentityText = "schema_version=1`nsource_tree=$($Active.source_tree)`npackage_lock_sha256=$($Active.package_lock_sha256)`n"
$IdentityHex = Get-BytesHash ([Text.Encoding]::ASCII.GetBytes($IdentityText))
$SlotId = "u-$($Active.updater_commit)-p-$IdentityHex"
if ($Active.player_identity -cne "sha256:$IdentityHex" -or $Active.slot_id -cne $SlotId -or
    $Active.player_relative_path -cne "players/sha256-$IdentityHex" -or
    $Active.version_relative_path -cne "versions/$SlotId") { throw "Identidad o rutas de slot invalidas." }
$ExpectedPlayerRoot = [IO.Path]::GetFullPath((Join-Path $ResolvedStateRoot $Active.player_relative_path))
$ExpectedVersionRoot = [IO.Path]::GetFullPath((Join-Path $ResolvedStateRoot $Active.version_relative_path))
$ResolvedVersionPath = Assert-CanonicalPath $VersionPath
if ($ScriptRoot -cne $ExpectedPlayerRoot -or
    $ResolvedVersionPath -cne (Join-Path $ExpectedVersionRoot 'VERSION.tsv')) {
  throw "VersionPath y player deben corresponder al slot activo."
}
$ExpectedLanConfigPath = [IO.Path]::GetFullPath((Join-Path $ResolvedStateRoot 'config/LAN-CONFIG.json'))
$ExpectedFingerprintPath = [IO.Path]::GetFullPath((Join-Path $ResolvedStateRoot 'config/public-identity/relay-cert.sha256'))
if ((Assert-CanonicalPath $FingerprintPath) -cne $ExpectedFingerprintPath) { throw "FingerprintPath fuera del contexto." }

$PackageKeys = @(
  "schema_version", "launcher_relative_path", "launcher_sha256", "actions",
  "levels", "max_clients", "network_contract", "loopback_http_only", "updater_version",
  "player_identity", "player_version", "config_schema_version"
)
$PackageDocument = Read-BoundedDocument $PackageContractPath 4096
$Package = Convert-ClosedTsv $PackageDocument.Text $PackageKeys
if ($Package.schema_version -cne "1" -or
    $Package.launcher_relative_path -cne "teremoq-lan-platform.ps1" -or
    $Package.actions -cne "start,status,stop,collect" -or
    $Package.levels -cne "1,5,10,25" -or $Package.max_clients -cne "25" -or
    $Package.network_contract -cne "outbound_udp_14433_only" -or
    $Package.loopback_http_only -cne "true" -or
    $Package.updater_version -cnotmatch "^[0-9]+[.][0-9]+[.][0-9]+$" -or
    $Package.player_identity -cnotmatch "^sha256:[0-9a-f]{64}$" -or
    $Package.player_version -cnotmatch "^[0-9]+[.][0-9]+[.][0-9]+(?:-[0-9A-Za-z.-]+)?$" -or
    $Package.config_schema_version -cne "1") {
  throw "Contrato del launcher fuera de versión."
}
$SelfHash = (Read-BoundedDocument $PSCommandPath 1048576).Sha256
if ($SelfHash -cne $Package.launcher_sha256) {
  throw "El hash del launcher no coincide con el contrato."
}

$LanConfigDocument = Read-BoundedDocument $ExpectedLanConfigPath 512
try { $LocalConfig = Convert-CanonicalJson $LanConfigDocument.Text }
catch { throw "LAN-CONFIG.json no es JSON válido." }
$ConfigKeys = @(
  "schema_version", "relay_url", "fingerprint_sha256", "prefix_length", "namespace",
  "run_id"
)
if (-not (Test-ExactProperties $LocalConfig $ConfigKeys) -or
    $LocalConfig.schema_version -isnot [int] -or $LocalConfig.schema_version -ne 1 -or
    $LocalConfig.relay_url -isnot [string] -or $LocalConfig.fingerprint_sha256 -isnot [string] -or
    $LocalConfig.fingerprint_sha256 -cnotmatch "^[0-9a-f]{64}$" -or
    (($LocalConfig.prefix_length -isnot [int]) -and ($LocalConfig.prefix_length -isnot [long])) -or
    $LocalConfig.prefix_length -lt 8 -or $LocalConfig.prefix_length -gt 30 -or
    $LocalConfig.namespace -isnot [string] -or [string]::IsNullOrWhiteSpace($LocalConfig.namespace) -or
    [System.Text.Encoding]::UTF8.GetByteCount($LocalConfig.namespace) -gt 256 -or
    @($LocalConfig.namespace.Split("/") | Where-Object {
      $_ -cnotmatch "^[A-Za-z0-9._-]+$" -or $_ -in @(".", "..")
    }).Count -ne 0 -or
    $LocalConfig.run_id -isnot [string] -or
    $LocalConfig.run_id -cnotmatch '^lan-[a-z0-9][a-z0-9-]{0,31}$') {
  throw "LAN-CONFIG.json no cumple el contrato cerrado."
}
[System.Uri]$MoqUri = $null
[System.Net.IPAddress]$MoqAddress = $null
if (-not [System.Uri]::TryCreate($LocalConfig.relay_url, [System.UriKind]::Absolute, [ref]$MoqUri) -or
    $MoqUri.Scheme -cne "https" -or $MoqUri.Port -ne 14433 -or $MoqUri.AbsolutePath -cne "/watch" -or
    -not [string]::IsNullOrEmpty($MoqUri.UserInfo) -or -not [string]::IsNullOrEmpty($MoqUri.Query) -or
    -not [string]::IsNullOrEmpty($MoqUri.Fragment) -or
    -not [System.Net.IPAddress]::TryParse($MoqUri.Host, [ref]$MoqAddress) -or
    $MoqAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
    $MoqUri.AbsoluteUri -cne $LocalConfig.relay_url) {
  throw "relay_url debe ser la URL HTTPS canónica del banco."
}
$Octets = $MoqAddress.GetAddressBytes()
if (-not ($Octets[0] -eq 10 -or
          ($Octets[0] -eq 172 -and $Octets[1] -ge 16 -and $Octets[1] -le 31) -or
          ($Octets[0] -eq 192 -and $Octets[1] -eq 168))) {
  throw "relay_url debe usar una IPv4 RFC1918."
}
$PrivatePrefix = if ($Octets[0] -eq 10) { 8 } elseif ($Octets[0] -eq 172) { 12 } else { 16 }
if ($LocalConfig.prefix_length -lt $PrivatePrefix) { throw "prefix_length sale del bloque RFC1918." }
$AddressValue = [uint64]$Octets[0] * 16777216 + [uint64]$Octets[1] * 65536 +
  [uint64]$Octets[2] * 256 + [uint64]$Octets[3]
$HostMask = [uint64]([Math]::Pow(2, 32 - $LocalConfig.prefix_length) - 1)
$HostPart = $AddressValue -band $HostMask
if ($HostPart -eq 0 -or $HostPart -eq $HostMask) { throw "relay_url usa red o broadcast." }
$VersionKeys = @(
  "schema_version", "updater_version", "player_identity", "player_version",
  "config_schema_version", "run_id", "updater_commit", "server_ipv4",
  "moq_url", "player_manifest_sha256", "launcher_contract_sha256",
  "lan_config_sha256", "player_evidence", "load_launcher_status"
)
$VersionDocument = Read-BoundedDocument $ResolvedVersionPath 4096
$Version = Convert-ClosedTsv $VersionDocument.Text $VersionKeys
if ($Version.schema_version -cne "2" -or
    $Version.updater_version -cne $Package.updater_version -or
    $Version.player_identity -cne $Package.player_identity -or
    $Version.player_version -cne $Package.player_version -or
    $Version.config_schema_version -cne $Package.config_schema_version -or
    $Version.run_id -cne $RunId -or
    $LocalConfig.run_id -cne $Version.run_id -or
    $Version.updater_commit -cne $Active.updater_commit -or
    $Version.server_ipv4 -cne $MoqUri.Host -or $Version.moq_url -cne $LocalConfig.relay_url -or
    $Version.player_manifest_sha256 -cnotmatch "^[0-9a-f]{64}$" -or
    $Version.launcher_contract_sha256 -cnotmatch "^[0-9a-f]{64}$" -or
    $Version.lan_config_sha256 -cnotmatch "^[0-9a-f]{64}$" -or
    $Version.player_evidence -cne "not_measured" -or $Version.load_launcher_status -cne "ready") {
  throw "VERSION.tsv no coincide con el paquete."
}
$ManifestDocument = Read-BoundedDocument $ManifestPath 1048576
if ($ManifestDocument.Sha256 -cne $Version.player_manifest_sha256 -or
    $PackageDocument.Sha256 -cne $Version.launcher_contract_sha256 -or
    $LanConfigDocument.Sha256 -cne $Version.lan_config_sha256 -or
    $Version.player_manifest_sha256 -cne $Active.player_manifest_sha256 -or
    $Version.launcher_contract_sha256 -cne $Active.launcher_contract_sha256 -or
    $Version.lan_config_sha256 -cne $Active.config_sha256 -or
    $Version.player_identity -cne $Active.player_identity -or
    $Version.updater_version -cne $Active.updater_version) {
  throw "Los checksums de VERSION.tsv no corresponden al player."
}

$CompatibilityKeys = @('schema_version','repository_url','repository_ref','repository_subdirectory',
  'allowed_client_commit','updater_version','updater_protocol','player_identity','player_version',
  'source_tree','package_lock_sha256','player_relative_path','config_schema_version',
  'player_manifest_sha256','launcher_contract_sha256','lan_config_sha256')
$CompatibilityDocument = Read-BoundedDocument (Join-Path $ExpectedVersionRoot 'CLIENT-COMPATIBILITY.tsv') 4096
$Compatibility = Convert-ClosedTsv $CompatibilityDocument.Text $CompatibilityKeys
if ($Compatibility.schema_version -cne '2' -or $Compatibility.repository_subdirectory -cne 'infra/lan' -or
    $Compatibility.repository_url -cne 'https://github.com/Teremoq/teremoq' -or
    $Compatibility.repository_ref -cnotmatch '^refs/heads/[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$' -or
    $Compatibility.repository_ref.Contains('..') -or
    $Compatibility.allowed_client_commit -cne $Active.updater_commit -or
    $Compatibility.updater_protocol -cne $Active.updater_protocol -or
    $Compatibility.player_version -cne $Version.player_version -or
    $Compatibility.config_schema_version -cne '1' -or
    $Compatibility.lan_config_sha256 -cne $Active.config_sha256) {
  throw "Compatibilidad gestionada invalida."
}
foreach ($Key in @('updater_version','player_identity','source_tree','package_lock_sha256',
    'player_relative_path','player_manifest_sha256','launcher_contract_sha256')) {
  if ($Compatibility[$Key] -cne $Active.$Key) { throw "Compatibilidad difiere del slot activo." }
}
$SumsDocument = Read-BoundedDocument (Join-Path $ExpectedVersionRoot 'SHA256SUMS') 4096
$Sums = @{}
foreach ($Line in $SumsDocument.Text.TrimEnd("`n").Split("`n")) {
  if ($Line -cnotmatch '^([0-9a-f]{64})  (CLIENT-COMPATIBILITY[.]tsv|VERSION[.]tsv)$' -or
      $Sums.ContainsKey($Matches[2])) { throw "Lista de hashes gestionada invalida." }
  $Sums[$Matches[2]] = $Matches[1]
}
if ($Sums.Count -ne 2 -or $Sums['VERSION.tsv'] -cne $VersionDocument.Sha256 -or
    $Sums['CLIENT-COMPATIBILITY.tsv'] -cne $CompatibilityDocument.Sha256) {
  throw "Hashes de metadatos gestionados invalidos."
}

# Only the child receives the enriched public runtime contract. The six-key file
# remains byte-identical across updater commits; no sealed player bytes change.
$CanonicalConfig = [ordered]@{
  schema_version = 1
  relay_url = $LocalConfig.relay_url
  fingerprint_sha256 = $LocalConfig.fingerprint_sha256
  prefix_length = $LocalConfig.prefix_length
  namespace = $LocalConfig.namespace
  run_id = $LocalConfig.run_id
  source_commit = $Version.updater_commit
} | ConvertTo-Json -Compress
if ([Text.Encoding]::UTF8.GetByteCount($CanonicalConfig) -gt 512) { throw "Runtime LAN fuera de limite." }
if (-not [string]::IsNullOrEmpty($env:TEREMOQ_LAN_LAB_CONFIG) -and
    $env:TEREMOQ_LAN_LAB_CONFIG -cne $CanonicalConfig) {
  throw "La variable LAN heredada no coincide con LAN-CONFIG.json."
}

$Manifest = Convert-CanonicalJson $ManifestDocument.Text
$ManifestKeys = @(
  "schema_version", "artifact", "entrypoint", "package_version", "updater_version",
  "player_identity", "player_version", "config_schema_version", "files", "total_bytes"
)
if (-not (Test-ExactProperties $Manifest $ManifestKeys) -or
    $Manifest.schema_version -ne 1 -or $Manifest.artifact -cne "teremoq-lan-lab-standalone" -or
    $Manifest.entrypoint -cne "start.mjs" -or
    $Manifest.package_version -cne $Version.player_version -or
    $Manifest.updater_version -cne $Package.updater_version -or
    $Manifest.player_identity -cne $Package.player_identity -or
    $Manifest.player_version -cne $Package.player_version -or
    $Manifest.config_schema_version -ne 1 -or
    $Manifest.schema_version -isnot [int] -or $Manifest.config_schema_version -isnot [int] -or
    $Manifest.files -isnot [array] -or $Manifest.files.Count -lt 1 -or $Manifest.files.Count -gt 10000 -or
    (($Manifest.total_bytes -isnot [int]) -and ($Manifest.total_bytes -isnot [long])) -or
    $Manifest.total_bytes -lt 1 -or $Manifest.total_bytes -gt 128MB) {
  throw "Manifest del player inválido."
}
$ManifestTotalBytes = 0
$ManifestPaths = @{}
function Get-InventoryHash([string]$Path, [long]$ExpectedBytes) {
  [void](Assert-CanonicalPath $Path)
  $Stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  $Hash = [Security.Cryptography.SHA256]::Create()
  $Retained = $false
  try {
    Assert-OpenedPath $Stream $Path
    if ($ExpectedBytes -lt 0 -or $ExpectedBytes -gt 128MB -or $Stream.Length -ne $ExpectedBytes) {
      throw "Longitud de fichero sellado invalida."
    }
    $Value = ([BitConverter]::ToString($Hash.ComputeHash($Stream)) -replace '-', '').ToLowerInvariant()
    if ($Stream.Position -ne $ExpectedBytes) { throw "Fichero sellado cambio durante lectura." }
    [void](Assert-CanonicalPath $Path)
    $PinnedStreams.Add($Stream)
    $Retained = $true
    return $Value
  } finally { $Hash.Dispose(); if (-not $Retained) { $Stream.Dispose() } }
}
foreach ($File in $Manifest.files) {
  if (-not (Test-ExactProperties $File @("bytes", "path", "sha256")) -or
      $File.path -isnot [string] -or $File.path.Length -lt 1 -or $File.path.Length -gt 512 -or
      $File.path.Contains("..") -or $File.path.Contains("\") -or
      $File.path -match '[:\x00-\x1f]' -or
      ($File.bytes -isnot [long] -and $File.bytes -isnot [int]) -or
      $File.bytes -lt 0 -or $File.bytes -gt 128MB -or $File.sha256 -isnot [string] -or
      $File.sha256 -cnotmatch "^[0-9a-f]{64}$" -or
      $ManifestPaths.ContainsKey($File.path)) {
    throw "Entrada de manifest inválida."
  }
  $ManifestPaths[$File.path] = $true
  $FullPath = [System.IO.Path]::GetFullPath((Join-Path $ScriptRoot $File.path))
  if (-not $FullPath.StartsWith($ScriptRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::Ordinal) -or
      -not (Test-Path -LiteralPath $FullPath -PathType Leaf)) {
    throw "Entrada de manifest fuera del paquete."
  }
  if ((Get-InventoryHash $FullPath $File.bytes) -cne $File.sha256) {
    throw "Checksum interno del player inválido."
  }
  $ManifestTotalBytes += $File.bytes
  if ($ManifestTotalBytes -gt 128MB) { throw "Inventario excede limite." }
}
if ($ManifestTotalBytes -ne $Manifest.total_bytes -or
    -not $ManifestPaths.ContainsKey("lan-launcher.tsv") -or
    -not $ManifestPaths.ContainsKey("teremoq-lan-platform.ps1")) {
  throw "Manifest del player no enlaza los contratos requeridos."
}
$ActualPaths = @{}
$Directories = New-Object 'System.Collections.Generic.Queue[string]'
$Directories.Enqueue($ScriptRoot)
$EntryCount = 0
while ($Directories.Count -gt 0) {
  foreach ($Path in [IO.Directory]::EnumerateFileSystemEntries($Directories.Dequeue())) {
    $EntryCount += 1
    if ($EntryCount -gt 20000 -or $Path.Length - $ScriptRoot.Length -gt 513) {
      throw "Inventario excede cardinalidad o longitud."
    }
    $Item = Get-Item -LiteralPath $Path -Force
    if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      throw "El directorio player contiene un enlace no permitido."
    }
    if ($Item.PSIsContainer) { $Directories.Enqueue($Item.FullName); continue }
    $RelativePath = $Item.FullName.Substring($ScriptRoot.Length + 1).Replace("\", "/")
    if ($RelativePath -ceq "MANIFEST.sha256.json") { continue }
    $ActualPaths[$RelativePath] = $true
  }
}
if ($ActualPaths.Count -ne $ManifestPaths.Count -or
    @($ActualPaths.Keys | Where-Object { -not $ManifestPaths.ContainsKey($_) }).Count -ne 0) {
  throw "El inventario del player contiene extras o ausencias."
}

$Fingerprint = (Read-BoundedDocument $FingerprintPath 128).Text.Trim()
if ($Fingerprint -cnotmatch "^[0-9a-f]{64}$") {
  throw "FingerprintPath no contiene un SHA-256 canónico."
}
if ($Fingerprint -cne $LocalConfig.fingerprint_sha256) {
  throw "El fingerprint verificado no coincide con la configuración local."
}

$ResolvedEvidence = Assert-CanonicalPath $EvidenceDirectory -AllowMissing
if ((Test-Path -LiteralPath $ResolvedEvidence) -and
    -not (Test-Path -LiteralPath $ResolvedEvidence -PathType Container)) {
  throw "EvidenceDirectory debe ser directorio o estar ausente."
}
# This is the SAME static boundary used by start. No product process, environment
# assignment, evidence directory, state/log write, port probe or Node --version.
if ($ValidateOnly) {
  [pscustomobject]@{
    schema_version = 1; status = 'validated'; run_id = $RunId; level = $Level
    updater_commit = $Active.updater_commit; player_identity = $Active.player_identity
  } | ConvertTo-Json -Compress
  return
}
[System.IO.Directory]::CreateDirectory($ResolvedEvidence) | Out-Null
$EvidenceItem = Get-Item -LiteralPath $ResolvedEvidence
if ($EvidenceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
  throw "EvidenceDirectory no puede ser un enlace."
}
$StatePath = Join-Path $ResolvedEvidence ("teremoq-lan-{0}.state.json" -f $RunId)
$StdoutPath = Join-Path $ResolvedEvidence ("teremoq-lan-{0}.stdout.log" -f $RunId)
$StderrPath = Join-Path $ResolvedEvidence ("teremoq-lan-{0}.stderr.log" -f $RunId)

function Read-State {
  if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { return $null }
  $Item = Get-Item -LiteralPath $StatePath
  if ($Item.Length -gt 8192 -or ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    throw "Estado local fuera de contrato."
  }
  $State = [System.IO.File]::ReadAllText($StatePath) | ConvertFrom-Json
  $Keys = @("schema_version", "run_id", "level", "pid", "status", "executable_path", "server_path", "start_time_utc")
  if (-not (Test-ExactProperties $State $Keys) -or
      $State.schema_version -ne 1 -or $State.run_id -cne $RunId -or $State.level -ne $Level -or
      $State.status -notin @("starting", "running", "stopped", "failed")) {
    throw "Estado local inválido."
  }
  return $State
}

function Write-State([object]$State) {
  [System.IO.File]::WriteAllText($StatePath, ($State | ConvertTo-Json -Compress) + [Environment]::NewLine)
}

function Get-OwnedProcess([object]$State) {
  if ($null -eq $State -or $State.pid -le 0 -or $State.status -notin @("starting", "running")) { return $null }
  $Process = Get-Process -Id ([int]$State.pid) -ErrorAction SilentlyContinue
  if ($null -eq $Process) { return $null }
  $StartTime = $Process.StartTime.ToUniversalTime().ToString("o")
  $ExecutablePath = [System.IO.Path]::GetFullPath($Process.Path)
  $Record = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $State.pid)
  if ($StartTime -cne $State.start_time_utc -or $ExecutablePath -cne $State.executable_path -or
      [System.IO.Path]::GetFullPath($State.server_path) -cne [System.IO.Path]::GetFullPath($ServerPath) -or
      $Record.ExecutablePath -cne $State.executable_path -or -not $Record.CommandLine.Contains($State.server_path)) {
    throw "La identidad del proceso no coincide; se rechaza terminar un PID reutilizado."
  }
  return $Process
}

function Stop-OwnedProcess([object]$State) {
  $Process = Get-OwnedProcess $State
  if ($null -ne $Process) {
    Stop-Process -Id $Process.Id -Force
    $Process.WaitForExit(5000) | Out-Null
  }
}

switch ($Action) {
  "start" {
    $Existing = Read-State
    if ($null -ne (Get-OwnedProcess $Existing)) { throw "La ejecución solicitada ya está activa." }
    $Node = Get-Command node -CommandType Application -ErrorAction Stop
    $NodePath = [System.IO.Path]::GetFullPath($Node.Source)
    $PortProbe = [System.Net.Sockets.TcpClient]::new()
    try {
      $PortBusy = $PortProbe.ConnectAsync("127.0.0.1", 3000).Wait(250) -and $PortProbe.Connected
    } catch { $PortBusy = $false }
    finally { $PortProbe.Dispose() }
    if ($PortBusy) { throw "TCP loopback/3000 ya está ocupado; no se acepta readiness ajena." }
    $PreviousHostname = $env:HOSTNAME
    $PreviousLanMode = $env:TEREMOQ_LAN_LAB
    $PreviousLanLevel = $env:TEREMOQ_LAN_LAB_LEVEL
    $PreviousLanConfig = $env:TEREMOQ_LAN_LAB_CONFIG
    try {
      $env:HOSTNAME = "127.0.0.1"
      $env:TEREMOQ_LAN_LAB = "1"
      $env:TEREMOQ_LAN_LAB_LEVEL = [string]$Level
      $env:TEREMOQ_LAN_LAB_CONFIG = $CanonicalConfig
      $Process = Start-Process -FilePath $NodePath -ArgumentList @($ServerPath) `
        -WorkingDirectory $ScriptRoot -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath
    } finally {
      $env:HOSTNAME = $PreviousHostname
      $env:TEREMOQ_LAN_LAB = $PreviousLanMode
      $env:TEREMOQ_LAN_LAB_LEVEL = $PreviousLanLevel
      $env:TEREMOQ_LAN_LAB_CONFIG = $PreviousLanConfig
    }
    $Process.Refresh()
    $State = [pscustomobject]@{
      schema_version = 1; run_id = $RunId; level = $Level; pid = $Process.Id
      status = "starting"; executable_path = $NodePath; server_path = $ServerPath
      start_time_utc = $Process.StartTime.ToUniversalTime().ToString("o")
    }
    Write-State $State
    $Ready = $false
    $Handler = [System.Net.Http.HttpClientHandler]::new()
    $Handler.UseProxy = $false
    $Handler.AllowAutoRedirect = $false
    $Client = [System.Net.Http.HttpClient]::new($Handler)
    $Client.Timeout = [TimeSpan]::FromMilliseconds(750)
    $Deadline = [System.Diagnostics.Stopwatch]::StartNew()
    try {
      while ($Deadline.ElapsedMilliseconds -lt 15000) {
        if ($Process.HasExited) { break }
        try {
          $Response = $Client.GetAsync("http://127.0.0.1:3000/").GetAwaiter().GetResult()
          if ([int]$Response.StatusCode -eq 200 -and $null -ne (Get-OwnedProcess $State)) {
            $Ready = $true; break
          }
        } catch { }
        Start-Sleep -Milliseconds 250
        $Process.Refresh()
      }
    } finally { $Client.Dispose(); $Handler.Dispose() }
    if (-not $Ready) {
      Stop-OwnedProcess $State
      $State.status = "failed"; Write-State $State
      throw "El standalone local no alcanzó readiness dentro del límite."
    }
    $State.status = "running"; Write-State $State
    [pscustomobject]@{
      schema_version = 1; run_id = $RunId; level = $Level; status = "running"
      local_url = $(if ($Level -eq 1) { "http://127.0.0.1:3000/" } else { "http://127.0.0.1:3000/lan-load" })
    } | ConvertTo-Json -Compress
  }
  "status" {
    $State = Read-State
    [pscustomobject]@{
      schema_version = 1; run_id = $RunId; level = $Level
      status = $(if ($null -ne (Get-OwnedProcess $State)) { "running" } else { "stopped" })
    } | ConvertTo-Json -Compress
  }
  "stop" {
    $State = Read-State
    Stop-OwnedProcess $State
    if ($null -ne $State) { $State.status = "stopped"; Write-State $State }
    [pscustomobject]@{ schema_version = 1; run_id = $RunId; level = $Level; status = "stopped" } |
      ConvertTo-Json -Compress
  }
  "collect" {
    $EvidenceName = "local-browser-observation-user-exported.json"
    $MetricsPath = Join-Path $ResolvedEvidence $EvidenceName
    $MetricsItem = Get-Item -LiteralPath $MetricsPath
    if ($MetricsItem.PSIsContainer -or
        ($MetricsItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or
        $MetricsItem.Length -gt 65536) {
      throw "La evidencia real no está disponible como fichero regular acotado."
    }
    $Node = Get-Command node -CommandType Application -ErrorAction Stop
    $ValidationJson = & $Node.Source $EvidenceValidatorPath --file $MetricsItem.FullName --level $Level
    if ($LASTEXITCODE -ne 0) { throw "El validador cerrado rechazó la evidencia." }
    $Validation = $ValidationJson | ConvertFrom-Json
    if ($Validation.status -cne "valid_user_export_not_attested" -or
        $Validation.sha256 -cnotmatch "^[0-9a-f]{64}$") {
      throw "Resultado del validador de evidencia inválido."
    }
    [pscustomobject]@{
      schema_version = 1; run_id = $RunId; level = $Level; status = "collected"
      attestation_status = "not_attested_user_export"
      evidence_sha256 = $Validation.sha256
    } | ConvertTo-Json -Compress
  }
}
} finally {
  # Retain verified metadata and dependency descriptors across the action. The
  # caller must separately pin this PS script BEFORE invocation (Platform).
  foreach ($PinnedStream in $PinnedStreams) { $PinnedStream.Dispose() }
  $PinnedStreams.Clear()
}
