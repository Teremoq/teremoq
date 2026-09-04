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

function Invoke-CheckedGit {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    & $script:GitExecutable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Git failed: $($Arguments[0])" }
}

$hostPath = (Get-Process -Id $PID).Path
if (-not $hostPath -or -not $hostPath.EndsWith('powershell.exe', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Ejecuta este archivo con Windows PowerShell, no desde WSL ni PowerShell Core'
}

$clientAddresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -ceq $ClientIPv4 })
if ($clientAddresses.Count -ne 1) {
    throw "Este iniciador es exclusivamente para el portatil cliente $ClientIPv4"
}
if (@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ceq $ServerIPv4 }).Count -ne 0) {
    throw 'El iniciador del cliente no puede ejecutarse en el servidor'
}
$profiles = @(Get-NetConnectionProfile -InterfaceIndex $clientAddresses[0].InterfaceIndex -ErrorAction SilentlyContinue)
if ($profiles.Count -ne 1 -or [string]$profiles[0].NetworkCategory -notin @('Public', 'Private')) {
    throw 'No se pudo identificar de forma unica el perfil de red del portatil'
}
$networkProfile = [string]$profiles[0].NetworkCategory

$script:GitExecutable = (Get-Command git.exe -ErrorAction Stop).Source
$nodeExecutable = (Get-Command node.exe -ErrorAction Stop).Source
$nodeVersion = (& $nodeExecutable --version).Trim()
if ($LASTEXITCODE -ne 0 -or $nodeVersion -notmatch '^v22\.[0-9]+\.[0-9]+$') {
    throw 'Se requiere Node.js 22.x para preparar el reproductor LAN'
}

$root = Join-Path $env:LOCALAPPDATA 'Teremoq'
$checkoutRoot = Join-Path $root 'checkout-lan-7d19feb'
$stateRoot = Join-Path $root 'state-lan-20260831-wifi1-7d19feb'
$preflightPath = Join-Path $root 'client-preflight-7d19feb.json'
New-Item -ItemType Directory -Path $root -Force | Out-Null
foreach ($path in @($checkoutRoot, $stateRoot, $preflightPath)) {
    if (Test-Path -LiteralPath $path) {
        throw "No se sobrescribira una instalacion o evidencia existente: $path"
    }
}

Write-Host '1/4 Descargando por Git el cliente aprobado...'
Invoke-CheckedGit -Arguments @('clone', '--quiet', '--origin', 'origin', '--branch', $Branch, '--single-branch', '--no-tags', $RepositoryUrl, $checkoutRoot)

$remotes = @(& $script:GitExecutable -C $checkoutRoot remote)
if ($LASTEXITCODE -ne 0 -or $remotes.Count -ne 1 -or $remotes[0] -cne 'origin') {
    throw 'El checkout no contiene exactamente el remoto origin esperado'
}
$remoteUrl = (& $script:GitExecutable -C $checkoutRoot remote get-url origin).Trim()
$head = (& $script:GitExecutable -C $checkoutRoot rev-parse HEAD).Trim()
$checkedOutBranch = (& $script:GitExecutable -C $checkoutRoot rev-parse --abbrev-ref HEAD).Trim()
$dirty = @(& $script:GitExecutable -C $checkoutRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $remoteUrl -cne $RepositoryUrl -or $head -cne $ExpectedCommit -or
    $checkedOutBranch -cne $Branch -or $dirty.Count -ne 0) {
    throw 'El checkout no coincide exactamente con la version LAN aprobada'
}

$packageJsonSha = (Get-FileHash -LiteralPath (Join-Path $checkoutRoot 'supervisor-web\package.json') -Algorithm SHA256).Hash.ToLowerInvariant()
$packageLockSha = (Get-FileHash -LiteralPath (Join-Path $checkoutRoot 'supervisor-web\package-lock.json') -Algorithm SHA256).Hash.ToLowerInvariant()
if ($packageJsonSha -cne $ExpectedPackageJsonSha256 -or $packageLockSha -cne $ExpectedPackageLockSha256) {
    throw 'Los archivos de dependencias descargados no coinciden byte a byte con el contrato aprobado'
}

Write-Host '2/4 Construyendo y verificando el reproductor desde el checkout limpio...'
& (Join-Path $checkoutRoot 'infra\lan\client\Prepare-LanClientFromGit.ps1') `
    -CheckoutRoot $checkoutRoot -StateRoot $stateRoot `
    -RepositoryUrl $RepositoryUrl -RepositoryRef $RepositoryRef `
    -ExpectedCommit $ExpectedCommit -RunId $RunId `
    -ServerIPv4 $ServerIPv4 -PrefixLength 24 -Namespace 'teremoq/live' `
    -FingerprintSha256 $FingerprintSha256

Write-Host '3/4 Verificando version y compatibilidad local...'
& (Join-Path $checkoutRoot 'infra\lan\client\Verify-Package.ps1') `
    -CheckoutRoot $checkoutRoot -StateRoot $stateRoot

Write-Host '4/4 Ejecutando el preflight nativo del portatil...'
$preflightLines = @(& (Join-Path $checkoutRoot 'infra\lan\windows\Preflight-Client.ps1') `
    -RunId $RunId -SourceCommit $ExpectedCommit `
    -ServerIPv4 $ServerIPv4 -ClientIPv4 $ClientIPv4 -PrefixLength 24 `
    -NetworkProfile $networkProfile -ExpectedWslMode nat `
    -MaximumClockOffsetMs 2000 -MinimumMtu 1280 `
    -MinimumCpuCores 2 -MinimumMemoryMiB 2048 -MinimumDiskMiB 1024)
$preflightJson = $preflightLines -join "`r`n"
try { $preflight = $preflightJson | ConvertFrom-Json } catch { throw 'El preflight no produjo JSON valido' }
$gate = @($preflight.checks | Where-Object { $_.check -ceq 'preflight_gate' })
if ($gate.Count -ne 1) { throw 'El preflight no contiene una decision unica' }
$utf8 = New-Object Text.UTF8Encoding($false, $true)
[IO.File]::WriteAllText($preflightPath, $preflightJson + "`r`n", $utf8)
if ($gate[0].status -cne 'pass' -or $gate[0].value -cne 'ready') {
    throw "El preflight ha quedado bloqueado; conserva el informe: $preflightPath"
}

Write-Host ''
Write-Host 'CLIENTE LAN PREPARADO Y PREFLIGHT APROBADO' -ForegroundColor Green
Write-Host "Version: $ExpectedCommit"
Write-Host "Checkout: $checkoutRoot"
Write-Host "Estado local: $stateRoot"
Write-Host "Informe: $preflightPath"
