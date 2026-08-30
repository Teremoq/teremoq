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
  [string]$EvidenceDirectory
)

$ErrorActionPreference = "Stop"
$ScriptRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$PackageContractPath = Join-Path $ScriptRoot "lan-launcher.tsv"
$ManifestPath = Join-Path $ScriptRoot "MANIFEST.sha256.json"
$ServerPath = Join-Path $ScriptRoot "server.js"
$EvidenceValidatorPath = Join-Path $ScriptRoot "validate-lan-evidence.mjs"
$ExpectedVersionPath = Join-Path ([System.IO.Directory]::GetParent($ScriptRoot).FullName) "VERSION.tsv"
$ExpectedLanConfigPath = Join-Path ([System.IO.Directory]::GetParent($ScriptRoot).FullName) "LAN-CONFIG.json"
$ResolvedVersionPath = [System.IO.Path]::GetFullPath($VersionPath)
if ($ResolvedVersionPath -cne [System.IO.Path]::GetFullPath($ExpectedVersionPath)) {
  throw "VersionPath debe ser el VERSION.tsv canónico exterior al paquete."
}

function Read-ClosedTsv([string]$Path, [string[]]$ExpectedKeys) {
  $Item = Get-Item -LiteralPath $Path
  if ($Item.PSIsContainer -or
      ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or
      $Item.Length -gt 4096) {
    throw "TSV contractual ausente o fuera de límite."
  }
  $Result = @{}
  foreach ($Line in [System.IO.File]::ReadAllLines($Item.FullName)) {
    $Parts = $Line.Split("`t")
    if ($Parts.Count -ne 2 -or [string]::IsNullOrEmpty($Parts[0]) -or
        $Result.ContainsKey($Parts[0]) -or $ExpectedKeys -cnotcontains $Parts[0]) {
      throw "TSV contractual inválido o abierto."
    }
    $Result[$Parts[0]] = $Parts[1]
  }
  if ($Result.Count -ne $ExpectedKeys.Count -or
      ($ExpectedKeys | Where-Object { -not $Result.ContainsKey($_) }).Count -ne 0) {
    throw "TSV contractual incompleto."
  }
  return $Result
}

function Test-ExactProperties([object]$Value, [string[]]$ExpectedKeys) {
  return (($Value.PSObject.Properties.Name | Sort-Object) -join ",") -ceq
    (($ExpectedKeys | Sort-Object) -join ",")
}

$PackageKeys = @(
  "schema_version", "launcher_relative_path", "launcher_sha256", "actions",
  "levels", "max_clients", "network_contract", "loopback_http_only", "source_commit"
)
$Package = Read-ClosedTsv $PackageContractPath $PackageKeys
if ($Package.schema_version -cne "1" -or
    $Package.launcher_relative_path -cne "teremoq-lan-platform.ps1" -or
    $Package.actions -cne "start,status,stop,collect" -or
    $Package.levels -cne "1,5,10,25" -or $Package.max_clients -cne "25" -or
    $Package.network_contract -cne "outbound_udp_14433_only" -or
    $Package.loopback_http_only -cne "true" -or
    $Package.source_commit -cnotmatch "^[0-9a-f]{40}$") {
  throw "Contrato del launcher fuera de versión."
}
$SelfHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($SelfHash -cne $Package.launcher_sha256) {
  throw "El hash del launcher no coincide con el contrato."
}

$LanConfigItem = Get-Item -LiteralPath $ExpectedLanConfigPath
if ($LanConfigItem.PSIsContainer -or
    ($LanConfigItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or
    $LanConfigItem.Length -lt 2 -or $LanConfigItem.Length -gt 512) {
  throw "LAN-CONFIG.json debe ser un fichero público regular y acotado."
}
$LanConfigRaw = [System.IO.File]::ReadAllText($LanConfigItem.FullName)
try { $LocalConfig = $LanConfigRaw | ConvertFrom-Json }
catch { throw "LAN-CONFIG.json no es JSON válido." }
$ConfigKeys = @(
  "schema_version", "relay_url", "fingerprint_sha256", "prefix_length", "namespace",
  "run_id", "source_commit"
)
if (-not (Test-ExactProperties $LocalConfig $ConfigKeys) -or
    $LocalConfig.schema_version -ne 1 -or
    $LocalConfig.fingerprint_sha256 -cnotmatch "^[0-9a-f]{64}$" -or
    (($LocalConfig.prefix_length -isnot [int]) -and ($LocalConfig.prefix_length -isnot [long])) -or
    $LocalConfig.prefix_length -lt 8 -or $LocalConfig.prefix_length -gt 30 -or
    $LocalConfig.namespace -isnot [string] -or [string]::IsNullOrWhiteSpace($LocalConfig.namespace) -or
    [System.Text.Encoding]::UTF8.GetByteCount($LocalConfig.namespace) -gt 256 -or
    ($LocalConfig.namespace.Split("/") | Where-Object {
      $_ -cnotmatch "^[A-Za-z0-9._-]+$" -or $_ -in @(".", "..")
    }).Count -ne 0 -or
    $LocalConfig.run_id -cnotmatch "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$" -or
    $LocalConfig.source_commit -cnotmatch "^[0-9a-f]{40}$") {
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
$CanonicalConfig = [ordered]@{
  schema_version = 1
  relay_url = $LocalConfig.relay_url
  fingerprint_sha256 = $LocalConfig.fingerprint_sha256
  prefix_length = $LocalConfig.prefix_length
  namespace = $LocalConfig.namespace
  run_id = $LocalConfig.run_id
  source_commit = $LocalConfig.source_commit
} | ConvertTo-Json -Compress
if (-not [string]::IsNullOrEmpty($env:TEREMOQ_LAN_LAB_CONFIG) -and
    $env:TEREMOQ_LAN_LAB_CONFIG -cne $CanonicalConfig) {
  throw "La variable LAN heredada no coincide con LAN-CONFIG.json."
}

$VersionKeys = @(
  "schema_version", "package_version", "run_id", "source_commit", "server_ipv4",
  "moq_url", "player_manifest_sha256", "launcher_contract_sha256",
  "lan_config_sha256", "player_evidence", "load_launcher_status"
)
$Version = Read-ClosedTsv $ResolvedVersionPath $VersionKeys
if ($Version.schema_version -cne "1" -or
    $Version.package_version -cnotmatch "^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$" -or
    $Version.run_id -cne $RunId -or $Version.source_commit -cne $Package.source_commit -or
    $LocalConfig.run_id -cne $Version.run_id -or
    $LocalConfig.source_commit -cne $Version.source_commit -or
    $Version.server_ipv4 -cne $MoqUri.Host -or $Version.moq_url -cne $LocalConfig.relay_url -or
    $Version.player_manifest_sha256 -cnotmatch "^[0-9a-f]{64}$" -or
    $Version.launcher_contract_sha256 -cnotmatch "^[0-9a-f]{64}$" -or
    $Version.lan_config_sha256 -cnotmatch "^[0-9a-f]{64}$" -or
    $Version.player_evidence -cne "not_measured" -or $Version.load_launcher_status -cne "ready") {
  throw "VERSION.tsv no coincide con el paquete."
}
if ((Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Version.player_manifest_sha256 -or
    (Get-FileHash -LiteralPath $PackageContractPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Version.launcher_contract_sha256 -or
    (Get-FileHash -LiteralPath $ExpectedLanConfigPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Version.lan_config_sha256) {
  throw "Los checksums de VERSION.tsv no corresponden al player."
}

$ManifestItem = Get-Item -LiteralPath $ManifestPath
if ($ManifestItem.Length -gt 8MB -or ($ManifestItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
  throw "Manifest del player fuera de límite."
}
$Manifest = [System.IO.File]::ReadAllText($ManifestItem.FullName) | ConvertFrom-Json
$ManifestKeys = @(
  "schema_version", "artifact", "entrypoint", "package_version", "source_commit", "files", "total_bytes"
)
if (-not (Test-ExactProperties $Manifest $ManifestKeys) -or
    $Manifest.schema_version -ne 1 -or $Manifest.artifact -cne "teremoq-lan-lab-standalone" -or
    $Manifest.entrypoint -cne "start.mjs" -or
    $Manifest.package_version -cne $Version.package_version -or
    $Manifest.source_commit -cne $Package.source_commit -or
    $Manifest.files.Count -lt 1 -or $Manifest.files.Count -gt 10000 -or
    (($Manifest.total_bytes -isnot [int]) -and ($Manifest.total_bytes -isnot [long])) -or
    $Manifest.total_bytes -lt 1) {
  throw "Manifest del player inválido."
}
$ManifestTotalBytes = 0
$ManifestPaths = @{}
foreach ($File in $Manifest.files) {
  if (-not (Test-ExactProperties $File @("bytes", "path", "sha256")) -or
      $File.path -isnot [string] -or $File.path.Length -lt 1 -or $File.path.Length -gt 512 -or
      $File.path.Contains("..") -or $File.path.Contains("\") -or
      ($File.bytes -isnot [long] -and $File.bytes -isnot [int]) -or
      $File.bytes -lt 0 -or $File.sha256 -cnotmatch "^[0-9a-f]{64}$" -or
      $ManifestPaths.ContainsKey($File.path)) {
    throw "Entrada de manifest inválida."
  }
  $ManifestPaths[$File.path] = $true
  $FullPath = [System.IO.Path]::GetFullPath((Join-Path $ScriptRoot $File.path))
  if (-not $FullPath.StartsWith($ScriptRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::Ordinal) -or
      -not (Test-Path -LiteralPath $FullPath -PathType Leaf)) {
    throw "Entrada de manifest fuera del paquete."
  }
  $Item = Get-Item -LiteralPath $FullPath
  if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or
      $Item.Length -ne $File.bytes -or
      (Get-FileHash -LiteralPath $FullPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $File.sha256) {
    throw "Checksum interno del player inválido."
  }
  $ManifestTotalBytes += $File.bytes
}
if ($ManifestTotalBytes -ne $Manifest.total_bytes -or
    -not $ManifestPaths.ContainsKey("lan-launcher.tsv") -or
    -not $ManifestPaths.ContainsKey("teremoq-lan-platform.ps1")) {
  throw "Manifest del player no enlaza los contratos requeridos."
}
$ActualPaths = @{}
foreach ($Item in Get-ChildItem -LiteralPath $ScriptRoot -Recurse -Force) {
  if ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
    throw "El directorio player contiene un enlace no permitido."
  }
  if ($Item.PSIsContainer) { continue }
  $RelativePath = $Item.FullName.Substring($ScriptRoot.Length + 1).Replace("\", "/")
  if ($RelativePath -ceq "MANIFEST.sha256.json") { continue }
  $ActualPaths[$RelativePath] = $true
}
if ($ActualPaths.Count -ne $ManifestPaths.Count -or
    ($ActualPaths.Keys | Where-Object { -not $ManifestPaths.ContainsKey($_) }).Count -ne 0) {
  throw "El inventario del player contiene extras o ausencias."
}

$FingerprintItem = Get-Item -LiteralPath $FingerprintPath
if ($FingerprintItem.PSIsContainer -or
    ($FingerprintItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or
    $FingerprintItem.Length -gt 128) {
  throw "FingerprintPath debe ser un fichero regular y acotado."
}
$Fingerprint = ([System.IO.File]::ReadAllText($FingerprintItem.FullName)).Trim()
if ($Fingerprint -cnotmatch "^[0-9a-f]{64}$") {
  throw "FingerprintPath no contiene un SHA-256 canónico."
}
if ($Fingerprint -cne $LocalConfig.fingerprint_sha256) {
  throw "El fingerprint verificado no coincide con la configuración local."
}

$ResolvedEvidence = [System.IO.Path]::GetFullPath($EvidenceDirectory)
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
