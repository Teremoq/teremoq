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
        $lines = @(& $script:GitExecutable --no-replace-objects -C $WorkingDirectory @Arguments 2>&1)
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

if (-not ('TeremoqLockedFile' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class TeremoqLockedFile {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandle(
        SafeFileHandle handle, StringBuilder path, uint pathLength, uint flags);

    public static string FinalPath(SafeFileHandle handle) {
        var path = new StringBuilder(32768);
        uint length = GetFinalPathNameByHandle(handle, path, (uint)path.Capacity, 0);
        if (length == 0 || length >= path.Capacity) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        string value = path.ToString();
        if (value.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) {
            return @"\\" + value.Substring(8);
        }
        if (value.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase)) {
            return value.Substring(4);
        }
        return value;
    }
}
'@
}

function Assert-LockedHandlePath {
    param([Parameter(Mandatory = $true)][IO.FileStream]$Stream,
          [Parameter(Mandatory = $true)][string]$ExpectedPath)
    $expected = [IO.Path]::GetFullPath($ExpectedPath)
    $actual = [IO.Path]::GetFullPath([TeremoqLockedFile]::FinalPath($Stream.SafeFileHandle))
    if (-not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "El archivo abierto fue redirigido o sustituido: $expected"
    }
}

function Get-LockedGitBlobId {
    param([Parameter(Mandatory = $true)][IO.FileStream]$Stream)
    if ($Stream.Length -gt 4194304) { throw 'Un archivo fuente supera el limite de 4 MiB' }
    $position = $Stream.Position
    $Stream.Position = 0
    $sha1 = [Security.Cryptography.SHA1]::Create()
    try {
        $header = [Text.Encoding]::ASCII.GetBytes("blob $($Stream.Length)" + [char]0)
        [void]$sha1.TransformBlock($header, 0, $header.Length, $header, 0)
        $buffer = New-Object byte[] 65536
        while (($read = $Stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            [void]$sha1.TransformBlock($buffer, 0, $read, $buffer, 0)
        }
        [void]$sha1.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        return (($sha1.Hash | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $sha1.Dispose()
        $Stream.Position = $position
    }
}

function Open-VerifiedCommitFiles {
    param([Parameter(Mandatory = $true)][string]$CheckoutRoot,
          [Parameter(Mandatory = $true)][string]$Commit)
    $listing = Get-ExactGitOutput -WorkingDirectory $CheckoutRoot -Arguments @(
        'ls-tree', '-r', '--name-only', $Commit, '--',
        'infra/lan/client', 'infra/lan/windows', 'supervisor-web'
    )
    $relativePaths = @($listing -split [char]10 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($relativePaths.Count -lt 10 -or $relativePaths.Count -gt 512) {
        throw 'El conjunto de archivos fuente no tiene una cardinalidad valida'
    }
    $streams = New-Object Collections.Generic.List[IO.FileStream]
    try {
        foreach ($relativePath in $relativePaths) {
            if ($relativePath -notmatch '^[A-Za-z0-9_.+@ -]+(?:/[A-Za-z0-9_.+@ -]+)*$') {
                throw "Git devolvio una ruta fuente no admitida: $relativePath"
            }
            $expectedPath = Join-Path $CheckoutRoot ($relativePath.Replace('/', '\'))
            $regular = Assert-RegularFile -Path $expectedPath
            $stream = [IO.File]::Open($regular, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            try {
                Assert-LockedHandlePath -Stream $stream -ExpectedPath $regular
                $expectedBlob = Get-ExactGitOutput -WorkingDirectory $CheckoutRoot -Arguments @(
                    'rev-parse', ('{0}:{1}' -f $Commit, $relativePath)
                )
                if ((Get-LockedGitBlobId -Stream $stream) -cne $expectedBlob) {
                    throw "El archivo abierto no coincide con el objeto Git aprobado: $relativePath"
                }
                $streams.Add($stream)
            } catch {
                $stream.Dispose()
                throw
            }
        }
        $dirtyAfterLocks = Get-ExactGitOutput -WorkingDirectory $CheckoutRoot -Arguments @(
            'status', '--porcelain=v1', '--untracked-files=all'
        )
        if (-not [string]::IsNullOrEmpty($dirtyAfterLocks)) {
            throw 'El checkout cambio mientras se bloqueaban los archivos aprobados'
        }
        $replaceRefsAfterLocks = Get-ExactGitOutput -WorkingDirectory $CheckoutRoot -Arguments @(
            'for-each-ref', '--format=%(refname)', 'refs/replace'
        )
        if (-not [string]::IsNullOrEmpty($replaceRefsAfterLocks)) {
            throw 'El checkout contiene objetos Git de reemplazo'
        }
        return $streams
    } catch {
        foreach ($stream in $streams) { $stream.Dispose() }
        throw
    }
}

function Get-ProcessEnvironmentSnapshot {
    $snapshot = @{}
    foreach ($entry in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()) {
        $snapshot[[string]$entry.Key] = [string]$entry.Value
    }
    return $snapshot
}

function Restore-ProcessEnvironment {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Snapshot)
    foreach ($name in @([Environment]::GetEnvironmentVariables('Process').Keys)) {
        if (-not $Snapshot.Contains([string]$name)) {
            [Environment]::SetEnvironmentVariable([string]$name, $null, 'Process')
        }
    }
    foreach ($entry in $Snapshot.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, 'Process')
    }
}

function Assert-LockedLocalGitConfig {
    param([Parameter(Mandatory = $true)][string]$CheckoutRoot,
          [Parameter(Mandatory = $true)][IO.FileStream]$ConfigStream,
          [Parameter(Mandatory = $true)][string]$Branch,
          [Parameter(Mandatory = $true)][string]$RepositoryUrl,
          [Parameter(Mandatory = $true)][string]$RepositoryRef,
          [Parameter(Mandatory = $true)][string]$FetchSpec)
    $expectedLocalConfig = @(
        "branch.$Branch.merge=$RepositoryRef",
        "branch.$Branch.remote=origin",
        'core.bare=false',
        'core.filemode=false',
        'core.ignorecase=true',
        'core.logallrefupdates=true',
        'core.repositoryformatversion=0',
        'core.symlinks=false',
        "remote.origin.fetch=$FetchSpec",
        "remote.origin.url=$RepositoryUrl"
    ) | Sort-Object
    $actualLocalConfig = @(
        (Get-ExactGitOutput -WorkingDirectory $CheckoutRoot -Arguments @('config', '--local', '--list')) -split [char]10 |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    ) | Sort-Object
    $configDifferences = @(Compare-Object -CaseSensitive $expectedLocalConfig $actualLocalConfig)
    if ($actualLocalConfig.Count -ne $expectedLocalConfig.Count -or $configDifferences.Count -ne 0) {
        throw 'La configuracion Git local contiene claves inesperadas'
    }
    if ($ConfigStream.Length -gt 4096) { throw 'La configuracion Git local supera el limite permitido' }
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

$environmentSnapshot = Get-ProcessEnvironmentSnapshot
$sessionRoot = $null
$rootLockPath = $null
$isolationStreams = New-Object Collections.Generic.List[IO.FileStream]
try {
    $rootLockPath = Join-Path $root ('.bootstrap-lock-' + [Guid]::NewGuid().ToString('N'))
    $rootLockStream = New-Object IO.FileStream(
        $rootLockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read
    )
    $isolationStreams.Add($rootLockStream)
    Assert-LockedHandlePath -Stream $rootLockStream -ExpectedPath $rootLockPath
    $rootLockStream.Flush($true)

    $sessionRoot = Join-Path $root ('.bootstrap-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($sessionRoot)
    [void](Assert-SafePathChain -Path $sessionRoot -MustExist)
    $isolatedHome = Join-Path $sessionRoot 'home'
    [void][IO.Directory]::CreateDirectory($isolatedHome)
    $emptyConfig = Join-Path $sessionRoot 'empty.gitconfig'
    $emptyAttributes = Join-Path $sessionRoot 'empty.gitattributes'
    [IO.File]::WriteAllBytes($emptyConfig, (New-Object byte[] 0))
    [IO.File]::WriteAllBytes($emptyAttributes, (New-Object byte[] 0))
    foreach ($path in @($emptyConfig, $emptyAttributes)) {
        $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $isolationStreams.Add($stream)
        Assert-LockedHandlePath -Stream $stream -ExpectedPath $path
        if ($stream.Length -ne 0) { throw 'Un archivo de aislamiento Git no esta vacio' }
    }
    $disabledGitPath = Join-Path $emptyConfig 'disabled'

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
    $env:GIT_NO_REPLACE_OBJECTS = '1'
    $env:HOME = $isolatedHome
    $env:USERPROFILE = $isolatedHome
    $env:XDG_CONFIG_HOME = $isolatedHome
    $env:PATH = "$(Split-Path -Parent $script:GitExecutable);$(Split-Path -Parent $nodeExecutable);$env:SystemRoot\System32;$env:SystemRoot"
    $gitConfig = [ordered]@{
        'core.hooksPath' = $disabledGitPath
        'core.attributesFile' = $emptyAttributes
        'core.fsmonitor' = 'false'
        'core.autocrlf' = 'false'
        'core.eol' = 'lf'
        'protocol.file.allow' = 'never'
        'protocol.ext.allow' = 'never'
        'init.templateDir' = $disabledGitPath
    }
    $env:GIT_CONFIG_COUNT = [string]$gitConfig.Count
    $index = 0
    foreach ($pair in $gitConfig.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable("GIT_CONFIG_KEY_$index", [string]$pair.Key, 'Process')
        [Environment]::SetEnvironmentVariable("GIT_CONFIG_VALUE_$index", [string]$pair.Value, 'Process')
        $index += 1
    }

    Write-Host '1/4 Descargando por Git el cliente aprobado...'
    [void](Assert-SafePathChain -Path $root -MustExist)
    foreach ($path in @($checkoutRoot, $stateRoot, $preflightPath)) {
        if (Test-Path -LiteralPath $path) { throw "Una ruta final aparecio durante la instalacion: $path" }
    }
    [void][IO.Directory]::CreateDirectory($checkoutRoot)
    [void](Assert-SafePathChain -Path $checkoutRoot -MustExist)
    $gitDirectory = Join-Path $checkoutRoot '.git'
    [void][IO.Directory]::CreateDirectory($gitDirectory)
    [void](Assert-SafePathChain -Path $gitDirectory -MustExist)
    $checkoutClaimPath = Join-Path $gitDirectory 'teremoq-bootstrap-claim'
    $checkoutClaimStream = New-Object IO.FileStream(
        $checkoutClaimPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read
    )
    $isolationStreams.Add($checkoutClaimStream)
    Assert-LockedHandlePath -Stream $checkoutClaimStream -ExpectedPath $checkoutClaimPath
    $checkoutClaimStream.Flush($true)
    $checkoutChildren = @(Get-ChildItem -LiteralPath $checkoutRoot -Force)
    $gitChildren = @(Get-ChildItem -LiteralPath $gitDirectory -Force)
    if ($checkoutChildren.Count -ne 1 -or $checkoutChildren[0].Name -cne '.git' -or
        $gitChildren.Count -ne 1 -or $gitChildren[0].Name -cne 'teremoq-bootstrap-claim') {
        throw 'El destino Git no estaba vacio al reclamarlo'
    }
    [void](Invoke-IsolatedGit -WorkingDirectory $root -Arguments @('init', '--quiet', '--initial-branch', $Branch, $checkoutRoot))
    [void](Invoke-IsolatedGit -WorkingDirectory $checkoutRoot -Arguments @('remote', 'add', 'origin', $RepositoryUrl))
    $fetchSpec = '+{0}:refs/remotes/origin/{1}' -f $RepositoryRef, $Branch
    [void](Invoke-IsolatedGit -WorkingDirectory $checkoutRoot -Arguments @('config', 'remote.origin.fetch', $fetchSpec))
    [void](Invoke-IsolatedGit -WorkingDirectory $checkoutRoot -Arguments @('config', "branch.$Branch.remote", 'origin'))
    [void](Invoke-IsolatedGit -WorkingDirectory $checkoutRoot -Arguments @('config', "branch.$Branch.merge", $RepositoryRef))

    $localConfigPath = Join-Path $gitDirectory 'config'
    $localConfigStream = [IO.File]::Open(
        (Assert-RegularFile -Path $localConfigPath),
        [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read
    )
    $isolationStreams.Add($localConfigStream)
    Assert-LockedHandlePath -Stream $localConfigStream -ExpectedPath $localConfigPath
    $configValidation = @{
        CheckoutRoot = $checkoutRoot
        ConfigStream = $localConfigStream
        Branch = $Branch
        RepositoryUrl = $RepositoryUrl
        RepositoryRef = $RepositoryRef
        FetchSpec = $fetchSpec
    }
    Assert-LockedLocalGitConfig @configValidation

    [void](Invoke-IsolatedGit -WorkingDirectory $checkoutRoot -Arguments @('fetch', '--quiet', '--no-tags', 'origin', $fetchSpec))
    $replaceRefs = Get-ExactGitOutput -WorkingDirectory $checkoutRoot -Arguments @(
        'for-each-ref', '--format=%(refname)', 'refs/replace'
    )
    if (-not [string]::IsNullOrEmpty($replaceRefs)) {
        throw 'El checkout contiene objetos Git de reemplazo'
    }
    $remoteTip = Get-ExactGitOutput -WorkingDirectory $checkoutRoot -Arguments @('rev-parse', "refs/remotes/origin/$Branch")
    [void](Invoke-IsolatedGit -WorkingDirectory $checkoutRoot -Arguments @('cat-file', '-e', ('{0}^{commit}' -f $ExpectedCommit)))
    [void](Invoke-IsolatedGit -WorkingDirectory $checkoutRoot -Arguments @('merge-base', '--is-ancestor', $ExpectedCommit, $remoteTip))
    [void](Invoke-IsolatedGit -WorkingDirectory $checkoutRoot -Arguments @('checkout', '--quiet', '-b', $Branch, $ExpectedCommit))

    $remotes = @((Get-ExactGitOutput -WorkingDirectory $checkoutRoot -Arguments @('remote')) -split [char]10)
    $remoteUrl = Get-ExactGitOutput -WorkingDirectory $checkoutRoot -Arguments @('remote', 'get-url', 'origin')
    $head = Get-ExactGitOutput -WorkingDirectory $checkoutRoot -Arguments @('rev-parse', 'HEAD')
    $checkedOutBranch = Get-ExactGitOutput -WorkingDirectory $checkoutRoot -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')
    $upstream = Get-ExactGitOutput -WorkingDirectory $checkoutRoot -Arguments @('rev-parse', '@{upstream}')
    $dirty = Get-ExactGitOutput -WorkingDirectory $checkoutRoot -Arguments @('status', '--porcelain=v1', '--untracked-files=all')
    if ($remotes.Count -ne 1 -or $remotes[0] -cne 'origin' -or $remoteUrl -cne $RepositoryUrl -or
        $head -cne $ExpectedCommit -or $checkedOutBranch -cne $Branch -or $upstream -cne $remoteTip -or
        -not [string]::IsNullOrEmpty($dirty)) {
        throw 'El checkout no coincide exactamente con la version LAN aprobada'
    }

    $packageJsonSha = (Get-FileHash -LiteralPath (Join-Path $checkoutRoot 'supervisor-web\package.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    $packageLockSha = (Get-FileHash -LiteralPath (Join-Path $checkoutRoot 'supervisor-web\package-lock.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($packageJsonSha -cne $ExpectedPackageJsonSha256 -or $packageLockSha -cne $ExpectedPackageLockSha256) {
        throw 'Los archivos de dependencias descargados no coinciden byte a byte con el contrato aprobado'
    }

    $lockedSources = Open-VerifiedCommitFiles -CheckoutRoot $checkoutRoot -Commit $ExpectedCommit
    try {
        Write-Host '2/4 Construyendo y verificando el reproductor desde el checkout limpio...'
        $prepareArguments = @{
            CheckoutRoot = $checkoutRoot
            StateRoot = $stateRoot
            RepositoryUrl = $RepositoryUrl
            RepositoryRef = $RepositoryRef
            ExpectedCommit = $ExpectedCommit
            RunId = $RunId
            ServerIPv4 = $ServerIPv4
            PrefixLength = 24
            Namespace = 'teremoq/live'
            FingerprintSha256 = $FingerprintSha256
        }
        & (Join-Path $checkoutRoot 'infra\lan\client\Prepare-LanClientFromGit.ps1') @prepareArguments

        Write-Host '3/4 Verificando version y compatibilidad local...'
        & (Join-Path $checkoutRoot 'infra\lan\client\Verify-Package.ps1') -CheckoutRoot $checkoutRoot -StateRoot $stateRoot

        Write-Host '4/4 Ejecutando el preflight nativo del portatil...'
        $preflightArguments = @{
            RunId = $RunId
            SourceCommit = $ExpectedCommit
            ServerIPv4 = $ServerIPv4
            ClientIPv4 = $ClientIPv4
            PrefixLength = 24
            NetworkProfile = $networkProfile
            ExpectedWslMode = 'nat'
            MaximumClockOffsetMs = 2000
            MinimumMtu = 1280
            MinimumCpuCores = 2
            MinimumMemoryMiB = 2048
            MinimumDiskMiB = 1024
        }
        $preflightLines = @(& (Join-Path $checkoutRoot 'infra\lan\windows\Preflight-Client.ps1') @preflightArguments)
        $preflightJson = $preflightLines -join [Environment]::NewLine
        try { $preflight = $preflightJson | ConvertFrom-Json } catch { throw 'El preflight no produjo JSON valido' }
        $gate = @($preflight.checks | Where-Object { $_.check -ceq 'preflight_gate' })
        if ($gate.Count -ne 1) { throw 'El preflight no contiene una decision unica' }

        [void](Assert-SafePathChain -Path $root -MustExist)
        [void](Assert-SafePathChain -Path $checkoutRoot -MustExist)
        [void](Assert-SafePathChain -Path $stateRoot -MustExist)
        if (Test-Path -LiteralPath $preflightPath) { throw "Una evidencia final aparecio durante la instalacion: $preflightPath" }
        $utf8 = New-Object Text.UTF8Encoding($false, $true)
        $preflightBytes = $utf8.GetBytes($preflightJson + [Environment]::NewLine)
        $preflightStream = New-Object IO.FileStream($preflightPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            Assert-LockedHandlePath -Stream $preflightStream -ExpectedPath $preflightPath
            $preflightStream.Write($preflightBytes, 0, $preflightBytes.Length)
            $preflightStream.Flush($true)
        } finally {
            $preflightStream.Dispose()
        }
        if ($gate[0].status -cne 'pass' -or $gate[0].value -cne 'ready') {
            throw "El preflight ha quedado bloqueado; conserva el informe: $preflightPath"
        }
    } finally {
        foreach ($stream in $lockedSources) { $stream.Dispose() }
    }
} finally {
    foreach ($stream in $isolationStreams) { $stream.Dispose() }
    Restore-ProcessEnvironment -Snapshot $environmentSnapshot
    if ($sessionRoot -and (Test-Path -LiteralPath $sessionRoot)) {
        [void](Assert-SafePathChain -Path $sessionRoot -MustExist)
        [IO.Directory]::Delete($sessionRoot, $true)
    }
    if ($rootLockPath -and (Test-Path -LiteralPath $rootLockPath)) {
        [void](Assert-RegularFile -Path $rootLockPath)
        [IO.File]::Delete($rootLockPath)
    }
}

Write-Host ''
Write-Host 'CLIENTE LAN PREPARADO Y PREFLIGHT APROBADO' -ForegroundColor Green
Write-Host "Version: $ExpectedCommit"
Write-Host "Checkout: $checkoutRoot"
Write-Host "Estado local: $stateRoot"
Write-Host "Informe: $preflightPath"
