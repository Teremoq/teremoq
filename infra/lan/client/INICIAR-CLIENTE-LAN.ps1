# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$RepositoryUrl = 'https://github.com/Teremoq/teremoq'
$RepositoryRef = 'refs/heads/codex/lan-e2e-integration'
$Branch = 'codex/lan-e2e-integration'
$ExpectedCommit = '7d19febedd91bfa30f58a577865bbd6b5b8b3f7a'
$RunId = 'lan-20260831-wifi1'
$ServerIPv4 = '192.168.1.130'
$ClientIPv4 = '192.168.1.139'
$FingerprintSha256 = '7984fd4852ec204dc16fb445d5260325fd3b686b478676767f52a1fa63a1a7bc'
$ExpectedPackageJsonSha256 = '1e5d32db5c08045cb8eabfde932af80b3ae8606da9d35d8f214a7570a46e20c5'
$ExpectedPackageLockSha256 = 'ea213de47c167e46e5879fef9723b19f950c245fe571b9908ec6bb9a64c7c0f8'

function Assert-SafePathChain {
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$MustExist)
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    $current = $root.TrimEnd([char[]]@('\', '/')) + '\'
    foreach ($part in $full.Substring($root.Length).Split([char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $part
        if (-not (Test-Path -LiteralPath $current)) {
            if ($MustExist) { throw "No existe una ruta requerida: $current" }
            break
        }
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "No se permiten enlaces o redirecciones de ruta: $current"
        }
    }
    return $full
}

function Assert-RegularFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = Assert-SafePathChain -Path $Path -MustExist
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "No es un archivo regular: $full" }
    return $full
}

function Invoke-IsolatedGit {
    param([Parameter(Mandatory = $true)][string]$WorkingDirectory,
          [Parameter(Mandatory = $true)][string[]]$Arguments,
          [int[]]$AllowedExitCodes = @(0))
    if ((Get-FileHash -LiteralPath $script:GitExecutable -Algorithm SHA256).Hash -cne $script:GitExecutableSha256) {
        throw 'git.exe cambio durante la instalacion'
    }
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& $script:GitExecutable -C $WorkingDirectory @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    $output = (($lines | ForEach-Object { [string]$_ }) -join "`n").Trim()
    if ($output.Length -gt 8192) { throw 'La salida de Git excedio el limite permitido' }
    if ($AllowedExitCodes -notcontains $exitCode) {
        if ([string]::IsNullOrWhiteSpace($output)) { $output = 'sin detalle adicional' }
        throw "Git rechazo la operacion $($Arguments[0]): $output"
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

function Get-ExactGitOutput {
    param([Parameter(Mandatory = $true)][string]$WorkingDirectory,
          [Parameter(Mandatory = $true)][string[]]$Arguments)
    return (Invoke-IsolatedGit -WorkingDirectory $WorkingDirectory -Arguments $Arguments).Output
}

function Open-LockedSourceFiles {
    param([Parameter(Mandatory = $true)][string]$CheckoutRoot)
    $roots = @(
        (Join-Path $CheckoutRoot 'infra\lan\client'),
        (Join-Path $CheckoutRoot 'infra\lan\windows'),
        (Join-Path $CheckoutRoot 'supervisor-web\lan-player'),
        (Join-Path $CheckoutRoot 'supervisor-web\scripts')
    )
    $paths = @($roots | ForEach-Object {
        [void](Assert-SafePathChain -Path $_ -MustExist)
        Get-ChildItem -LiteralPath $_ -File -Recurse -Force | Select-Object -ExpandProperty FullName
    }) + @(
        (Join-Path $CheckoutRoot 'supervisor-web\package.json'),
        (Join-Path $CheckoutRoot 'supervisor-web\package-lock.json')
    )
    $streams = New-Object Collections.Generic.List[IO.FileStream]
    try {
        foreach ($path in ($paths | Sort-Object -Unique)) {
            $regular = Assert-RegularFile -Path $path
            $streams.Add([IO.File]::Open($regular, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
        }
        return $streams
    } catch {
        foreach ($stream in $streams) { $stream.Dispose() }
        throw
    }
}

$hostPath = (Get-Process -Id $PID).Path
if (-not $hostPath -or -not $hostPath.EndsWith('powershell.exe', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Ejecuta este archivo con Windows PowerShell, no desde WSL ni PowerShell Core'
}
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Ejecuta el iniciador en una ventana PowerShell normal, no como administrador'
}

$clientAddresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -ceq $ClientIPv4 })
if ($clientAddresses.Count -ne 1) { throw "Este iniciador es exclusivamente para el portatil cliente $ClientIPv4" }
if (@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ceq $ServerIPv4 }).Count -ne 0) {
    throw 'El iniciador del cliente no puede ejecutarse en el servidor'
}
$profiles = @(Get-NetConnectionProfile -InterfaceIndex $clientAddresses[0].InterfaceIndex -ErrorAction SilentlyContinue)
if ($profiles.Count -ne 1 -or [string]$profiles[0].NetworkCategory -notin @('Public', 'Private')) {
    throw 'No se pudo identificar de forma unica el perfil de red del portatil'
}
$networkProfile = [string]$profiles[0].NetworkCategory

$script:GitExecutable = Assert-RegularFile -Path (Join-Path $env:ProgramFiles 'Git\cmd\git.exe')
$nodeExecutable = Assert-RegularFile -Path (Join-Path $env:ProgramFiles 'nodejs\node.exe')
$script:GitExecutableSha256 = (Get-FileHash -LiteralPath $script:GitExecutable -Algorithm SHA256).Hash
$nodeExecutableSha256 = (Get-FileHash -LiteralPath $nodeExecutable -Algorithm SHA256).Hash
$nodeVersion = (& $nodeExecutable --version).Trim()
if ($LASTEXITCODE -ne 0 -or $nodeVersion -notmatch '^v22\.[0-9]+\.[0-9]+$' -or
    (Get-FileHash -LiteralPath $nodeExecutable -Algorithm SHA256).Hash -cne $nodeExecutableSha256) {
    throw 'Se requiere la instalacion regular de Node.js 22.x en Program Files'
}

$localAppData = Assert-SafePathChain -Path $env:LOCALAPPDATA -MustExist
$root = Join-Path $localAppData 'Teremoq'
if (-not (Test-Path -LiteralPath $root)) { [void][IO.Directory]::CreateDirectory($root) }
[void](Assert-SafePathChain -Path $root -MustExist)
$checkoutRoot = Join-Path $root 'checkout-lan-7d19feb'
$stateRoot = Join-Path $root 'state-lan-20260831-wifi1-7d19feb'
$preflightPath = Join-Path $root 'client-preflight-7d19feb.json'
foreach ($path in @($checkoutRoot, $stateRoot, $preflightPath)) {
    if (Test-Path -LiteralPath $path) { throw "No se sobrescribira una instalacion o evidencia existente: $path" }
}

$sessionRoot = Join-Path $root ('.bootstrap-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($sessionRoot)
[void](Assert-SafePathChain -Path $sessionRoot -MustExist)
$stagingCheckout = Join-Path $sessionRoot 'checkout'
$stagingState = Join-Path $sessionRoot 'state'
$isolatedHome = Join-Path $sessionRoot 'home'
$emptyHooks = Join-Path $sessionRoot 'hooks'
[void][IO.Directory]::CreateDirectory($isolatedHome)
[void][IO.Directory]::CreateDirectory($emptyHooks)
$emptyConfig = Join-Path $sessionRoot 'empty.gitconfig'
$emptyAttributes = Join-Path $sessionRoot 'empty.gitattributes'
[IO.File]::WriteAllBytes($emptyConfig, (New-Object byte[] 0))
[IO.File]::WriteAllBytes($emptyAttributes, (New-Object byte[] 0))

foreach ($entry in @(Get-ChildItem Env: | Where-Object {
        $_.Name -like 'GIT_*' -or $_.Name -like 'GCM_*' -or $_.Name -like 'SSH_*' -or
        $_.Name -like 'CURL_*' -or $_.Name -like 'SSL_CERT_*' -or
        $_.Name -in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')
    })) {
    [Environment]::SetEnvironmentVariable($entry.Name, $null, 'Process')
}
$env:GIT_CONFIG_NOSYSTEM = '1'
$env:GIT_CONFIG_SYSTEM = $emptyConfig
$env:GIT_CONFIG_GLOBAL = $emptyConfig
$env:GIT_TERMINAL_PROMPT = '0'
$env:GCM_INTERACTIVE = 'Never'
$env:HOME = $isolatedHome
$env:USERPROFILE = $isolatedHome
$env:XDG_CONFIG_HOME = $isolatedHome
$env:PATH = "$(Split-Path -Parent $script:GitExecutable);$(Split-Path -Parent $nodeExecutable);$env:SystemRoot\System32;$env:SystemRoot"
$gitConfig = [ordered]@{
    'core.hooksPath' = $emptyHooks
    'core.attributesFile' = $emptyAttributes
    'core.fsmonitor' = 'false'
    'core.autocrlf' = 'false'
    'core.eol' = 'lf'
    'protocol.file.allow' = 'never'
    'protocol.ext.allow' = 'never'
    'init.templateDir' = $emptyHooks
}
$env:GIT_CONFIG_COUNT = [string]$gitConfig.Count
$index = 0
foreach ($pair in $gitConfig.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable("GIT_CONFIG_KEY_$index", [string]$pair.Key, 'Process')
    [Environment]::SetEnvironmentVariable("GIT_CONFIG_VALUE_$index", [string]$pair.Value, 'Process')
    $index += 1
}

Write-Host '1/4 Descargando por Git el cliente aprobado...'
[void](Invoke-IsolatedGit -WorkingDirectory $sessionRoot -Arguments @('init', '--quiet', '--initial-branch', $Branch, $stagingCheckout))
[void](Invoke-IsolatedGit -WorkingDirectory $stagingCheckout -Arguments @('remote', 'add', 'origin', $RepositoryUrl))
[void](Invoke-IsolatedGit -WorkingDirectory $stagingCheckout -Arguments @('config', 'remote.origin.fetch', "+$RepositoryRef`:refs/remotes/origin/$Branch"))
[void](Invoke-IsolatedGit -WorkingDirectory $stagingCheckout -Arguments @('fetch', '--quiet', '--no-tags', 'origin', "+$RepositoryRef`:refs/remotes/origin/$Branch"))
$remoteTip = Get-ExactGitOutput -WorkingDirectory $stagingCheckout -Arguments @('rev-parse', "refs/remotes/origin/$Branch")
[void](Invoke-IsolatedGit -WorkingDirectory $stagingCheckout -Arguments @('cat-file', '-e', "$ExpectedCommit`^{commit}"))
[void](Invoke-IsolatedGit -WorkingDirectory $stagingCheckout -Arguments @('merge-base', '--is-ancestor', $ExpectedCommit, $remoteTip))
[void](Invoke-IsolatedGit -WorkingDirectory $stagingCheckout -Arguments @('checkout', '--quiet', '-b', $Branch, $ExpectedCommit))
[void](Invoke-IsolatedGit -WorkingDirectory $stagingCheckout -Arguments @('branch', '--set-upstream-to', "origin/$Branch", $Branch))

$remotes = @((Get-ExactGitOutput -WorkingDirectory $stagingCheckout -Arguments @('remote')) -split "`n")
$remoteUrl = Get-ExactGitOutput -WorkingDirectory $stagingCheckout -Arguments @('remote', 'get-url', 'origin')
$head = Get-ExactGitOutput -WorkingDirectory $stagingCheckout -Arguments @('rev-parse', 'HEAD')
$checkedOutBranch = Get-ExactGitOutput -WorkingDirectory $stagingCheckout -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')
$dirty = Get-ExactGitOutput -WorkingDirectory $stagingCheckout -Arguments @('status', '--porcelain=v1', '--untracked-files=all')
if ($remotes.Count -ne 1 -or $remotes[0] -cne 'origin' -or $remoteUrl -cne $RepositoryUrl -or
    $head -cne $ExpectedCommit -or $checkedOutBranch -cne $Branch -or -not [string]::IsNullOrEmpty($dirty)) {
    throw 'El checkout no coincide exactamente con la version LAN aprobada'
}

$packageJsonSha = (Get-FileHash -LiteralPath (Join-Path $stagingCheckout 'supervisor-web\package.json') -Algorithm SHA256).Hash.ToLowerInvariant()
$packageLockSha = (Get-FileHash -LiteralPath (Join-Path $stagingCheckout 'supervisor-web\package-lock.json') -Algorithm SHA256).Hash.ToLowerInvariant()
if ($packageJsonSha -cne $ExpectedPackageJsonSha256 -or $packageLockSha -cne $ExpectedPackageLockSha256) {
    throw 'Los archivos de dependencias descargados no coinciden byte a byte con el contrato aprobado'
}

$lockedSources = Open-LockedSourceFiles -CheckoutRoot $stagingCheckout
try {
    Write-Host '2/4 Construyendo y verificando el reproductor desde el checkout limpio...'
    & (Join-Path $stagingCheckout 'infra\lan\client\Prepare-LanClientFromGit.ps1') `
        -CheckoutRoot $stagingCheckout -StateRoot $stagingState `
        -RepositoryUrl $RepositoryUrl -RepositoryRef $RepositoryRef `
        -ExpectedCommit $ExpectedCommit -RunId $RunId `
        -ServerIPv4 $ServerIPv4 -PrefixLength 24 -Namespace 'teremoq/live' `
        -FingerprintSha256 $FingerprintSha256

    Write-Host '3/4 Verificando version y compatibilidad local...'
    & (Join-Path $stagingCheckout 'infra\lan\client\Verify-Package.ps1') `
        -CheckoutRoot $stagingCheckout -StateRoot $stagingState

    Write-Host '4/4 Ejecutando el preflight nativo del portatil...'
    $preflightLines = @(& (Join-Path $stagingCheckout 'infra\lan\windows\Preflight-Client.ps1') `
        -RunId $RunId -SourceCommit $ExpectedCommit `
        -ServerIPv4 $ServerIPv4 -ClientIPv4 $ClientIPv4 -PrefixLength 24 `
        -NetworkProfile $networkProfile -ExpectedWslMode nat `
        -MaximumClockOffsetMs 2000 -MinimumMtu 1280 `
        -MinimumCpuCores 2 -MinimumMemoryMiB 2048 -MinimumDiskMiB 1024)
} finally {
    foreach ($stream in $lockedSources) { $stream.Dispose() }
}

$preflightJson = $preflightLines -join "`r`n"
try { $preflight = $preflightJson | ConvertFrom-Json } catch { throw 'El preflight no produjo JSON valido' }
$gate = @($preflight.checks | Where-Object { $_.check -ceq 'preflight_gate' })
if ($gate.Count -ne 1) { throw 'El preflight no contiene una decision unica' }
foreach ($path in @($checkoutRoot, $stateRoot, $preflightPath)) {
    if (Test-Path -LiteralPath $path) { throw "Una ruta final aparecio durante la instalacion: $path" }
}
[IO.Directory]::Move($stagingCheckout, $checkoutRoot)
[IO.Directory]::Move($stagingState, $stateRoot)
& (Join-Path $checkoutRoot 'infra\lan\client\Verify-Package.ps1') -CheckoutRoot $checkoutRoot -StateRoot $stateRoot
$utf8 = New-Object Text.UTF8Encoding($false, $true)
$preflightBytes = $utf8.GetBytes($preflightJson + "`r`n")
$preflightStream = New-Object IO.FileStream($preflightPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $preflightStream.Write($preflightBytes, 0, $preflightBytes.Length); $preflightStream.Flush($true) } finally { $preflightStream.Dispose() }
if ($gate[0].status -cne 'pass' -or $gate[0].value -cne 'ready') {
    throw "El preflight ha quedado bloqueado; conserva el informe: $preflightPath"
}
if (Test-Path -LiteralPath $sessionRoot) { [IO.Directory]::Delete($sessionRoot, $true) }

Write-Host ''
Write-Host 'CLIENTE LAN PREPARADO Y PREFLIGHT APROBADO' -ForegroundColor Green
Write-Host "Version: $ExpectedCommit"
Write-Host "Checkout: $checkoutRoot"
Write-Host "Estado local: $stateRoot"
Write-Host "Informe: $preflightPath"
