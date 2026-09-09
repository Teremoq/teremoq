# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ExpectedCommit,
    [Parameter(Mandatory = $true)][string]$ChannelCommit
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$RepositoryUrl = 'https://github.com/Teremoq/teremoq'
$RepositoryRef = 'refs/heads/codex/lan-e2e-integration'
$Branch = 'codex/lan-e2e-integration'

if ($PSVersionTable.PSEdition -cne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or
    $env:WSL_INTEROP -or $env:WSL_DISTRO_NAME) {
    throw 'Run this bootstrap in native Windows PowerShell 5 Desktop'
}
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this bootstrap in a normal, non-administrator PowerShell window'
}
if ($ExpectedCommit -cnotmatch '^[0-9a-f]{40}$') {
    throw 'ExpectedCommit must be an exact lowercase Git commit'
}
if ($ChannelCommit -cnotmatch '^[0-9a-f]{40}$') {
    throw 'ChannelCommit must be an exact lowercase Git commit'
}

$script:Git = 'C:\Program Files\Git\cmd\git.exe'
if (-not (Test-Path -LiteralPath $script:Git -PathType Leaf)) {
    throw 'Git for Windows is required in Program Files'
}
$script:GitSha256 = (Get-FileHash -LiteralPath $script:Git -Algorithm SHA256).Hash

function Invoke-TeremoqClientGit {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int[]]$AllowedExitCodes = @(0)
    )
    if ((Get-FileHash -LiteralPath $script:Git -Algorithm SHA256).Hash -cne $script:GitSha256) {
        throw 'git.exe changed during client preparation'
    }
    $previousPreference = $ErrorActionPreference
    $gitEnvironment = @{}
    foreach ($name in @(
        'GIT_CONFIG_NOSYSTEM', 'GIT_CONFIG_GLOBAL', 'GIT_NO_REPLACE_OBJECTS',
        'GIT_TERMINAL_PROMPT', 'GCM_INTERACTIVE'
    )) {
        $gitEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    $ErrorActionPreference = 'Continue'
    try {
        $env:GIT_CONFIG_NOSYSTEM = '1'
        $env:GIT_CONFIG_GLOBAL = 'NUL'
        $env:GIT_NO_REPLACE_OBJECTS = '1'
        $env:GIT_TERMINAL_PROMPT = '0'
        $env:GCM_INTERACTIVE = 'Never'
        $global:LASTEXITCODE = $null
        $lines = @(& $script:Git --no-replace-objects `
            -c core.hooksPath=NUL -c core.fsmonitor=false `
            -c core.attributesFile=NUL -c core.autocrlf=false `
            -c core.eol=lf -c core.safecrlf=true `
            -c protocol.file.allow=never -c protocol.ext.allow=never `
            -C $WorkingDirectory @Arguments 2>&1)
        $exitCode = $global:LASTEXITCODE
    } finally {
        foreach ($name in $gitEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $gitEnvironment[$name], 'Process')
        }
        $ErrorActionPreference = $previousPreference
    }
    $output = (($lines | ForEach-Object { [string]$_ }) -join "`n").Trim()
    if ($output.Length -gt 16384) { throw 'Git output exceeded the client bootstrap limit' }
    if ($exitCode -isnot [int] -or $AllowedExitCodes -notcontains $exitCode) {
        if ([string]::IsNullOrWhiteSpace($output)) { $output = 'no additional detail' }
        throw "Git rejected $($Arguments[0]): $output"
    }
    return $output
}

function Get-TeremoqGitValue {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    return (Invoke-TeremoqClientGit -WorkingDirectory $WorkingDirectory -Arguments $Arguments).Trim()
}

function Test-TeremoqReusableCheckout {
    param([Parameter(Mandatory = $true)][string]$CheckoutRoot)
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $CheckoutRoot '.git') -PathType Container)) { return $false }
        $item = Get-Item -LiteralPath $CheckoutRoot -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        $dirty = Get-TeremoqGitValue -WorkingDirectory $CheckoutRoot -Arguments @(
            'status', '--porcelain=v1', '--untracked-files=all'
        )
        if (-not [string]::IsNullOrEmpty($dirty)) { return $false }
        if ((Get-TeremoqGitValue -WorkingDirectory $CheckoutRoot -Arguments @('remote','get-url','origin')).TrimEnd('/') -cne $RepositoryUrl) { return $false }
        if ((Get-TeremoqGitValue -WorkingDirectory $CheckoutRoot -Arguments @('symbolic-ref','--short','HEAD')) -cne $Branch) { return $false }
        [void](Invoke-TeremoqClientGit -WorkingDirectory $CheckoutRoot -Arguments @('fetch','--no-tags','origin',$RepositoryRef))
        if ((Get-TeremoqGitValue -WorkingDirectory $CheckoutRoot -Arguments @('rev-parse','FETCH_HEAD')) -cne $ExpectedCommit) { return $false }
        [void](Invoke-TeremoqClientGit -WorkingDirectory $CheckoutRoot -Arguments @(
            'merge-base', '--is-ancestor', 'HEAD', $ExpectedCommit
        ))
        [void](Invoke-TeremoqClientGit -WorkingDirectory $CheckoutRoot -Arguments @(
            'merge', '--ff-only', $ExpectedCommit
        ))
        $head = Get-TeremoqGitValue -WorkingDirectory $CheckoutRoot -Arguments @('rev-parse','HEAD')
        $branch = Get-TeremoqGitValue -WorkingDirectory $CheckoutRoot -Arguments @('symbolic-ref','--short','HEAD')
        $remote = (Get-TeremoqGitValue -WorkingDirectory $CheckoutRoot -Arguments @('remote','get-url','origin')).TrimEnd('/')
        $dirtyAfterUpdate = Get-TeremoqGitValue -WorkingDirectory $CheckoutRoot -Arguments @(
            'status', '--porcelain=v1', '--untracked-files=all'
        )
        return ($head -ceq $ExpectedCommit -and $branch -ceq $Branch -and
            $remote -ceq $RepositoryUrl -and [string]::IsNullOrEmpty($dirtyAfterUpdate))
    } catch {
        return $false
    }
}

function Get-TeremoqCheckoutValidation {
    param([Parameter(Mandatory = $true)][string]$CheckoutRoot)
    $headValue = Get-TeremoqGitValue -WorkingDirectory $CheckoutRoot -Arguments @('rev-parse','HEAD')
    $branchValue = Get-TeremoqGitValue -WorkingDirectory $CheckoutRoot -Arguments @('symbolic-ref','--short','HEAD')
    $remoteValue = (Get-TeremoqGitValue -WorkingDirectory $CheckoutRoot -Arguments @('remote','get-url','origin')).TrimEnd('/')
    $dirtyValue = Get-TeremoqGitValue -WorkingDirectory $CheckoutRoot -Arguments @(
        'status', '--porcelain=v1', '--untracked-files=all'
    )
    return [pscustomobject]@{
        Valid = ($headValue -ceq $ExpectedCommit -and $branchValue -ceq $Branch -and
            $remoteValue -ceq $RepositoryUrl -and [string]::IsNullOrEmpty($dirtyValue))
        Head = $headValue
        Branch = $branchValue
        Remote = $remoteValue
        Dirty = -not [string]::IsNullOrEmpty($dirtyValue)
    }
}

function Install-TeremoqStableChannelCore {
    param(
        [Parameter(Mandatory = $true)][string]$ClientRoot,
        [Parameter(Mandatory = $true)][string]$CheckoutRoot
    )
    $clientRootFull = [IO.Path]::GetFullPath($ClientRoot).TrimEnd('\', '/')
    $checkoutFull = [IO.Path]::GetFullPath($CheckoutRoot).TrimEnd('\', '/')
    $sourceLauncher = Join-Path $checkoutFull 'infra\lan\client\Start-LanInteractiveClient.ps1'
    $sourceAgent = Join-Path $checkoutFull 'infra\lan\client\Lan-Interactive-Agent.mjs'
    $launcherSha256 = (Get-FileHash -LiteralPath $sourceLauncher -Algorithm SHA256).Hash.ToLowerInvariant()
    $agentSha256 = (Get-FileHash -LiteralPath $sourceAgent -Algorithm SHA256).Hash.ToLowerInvariant()
    $identityBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($launcherSha256 + "`n" + $agentSha256 + "`n")
    $identityHash = [Security.Cryptography.SHA256]::Create()
    try {
        $version = (([BitConverter]::ToString($identityHash.ComputeHash($identityBytes)) -replace '-', '').ToLowerInvariant()).Substring(0, 16)
    } finally { $identityHash.Dispose() }
    $channelRoot = [IO.Path]::GetFullPath((Join-Path $clientRootFull ('channel-core-' + $version))).TrimEnd('\', '/')
    if (-not $channelRoot.StartsWith($clientRootFull + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase) -or $channelRoot.StartsWith($checkoutFull + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Stable channel core path overlaps a mutable checkout'
    }

    if (-not (Test-Path -LiteralPath $channelRoot)) {
        $staging = Join-Path $clientRootFull ('.channel-core-next-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($staging)
        [IO.File]::Copy($sourceLauncher, (Join-Path $staging 'Start-LanInteractiveClient.ps1'), $false)
        [IO.File]::Copy($sourceAgent, (Join-Path $staging 'Lan-Interactive-Agent.mjs'), $false)
        if ((Get-FileHash -LiteralPath (Join-Path $staging 'Start-LanInteractiveClient.ps1') -Algorithm SHA256).Hash.ToLowerInvariant() -cne $launcherSha256 -or
            (Get-FileHash -LiteralPath (Join-Path $staging 'Lan-Interactive-Agent.mjs') -Algorithm SHA256).Hash.ToLowerInvariant() -cne $agentSha256) {
            throw 'Stable channel core copy failed verification'
        }
        [IO.Directory]::Move($staging, $channelRoot)
    }
    $channelLauncher = Join-Path $channelRoot 'Start-LanInteractiveClient.ps1'
    $channelAgent = Join-Path $channelRoot 'Lan-Interactive-Agent.mjs'
    if ((Get-FileHash -LiteralPath $channelLauncher -Algorithm SHA256).Hash.ToLowerInvariant() -cne $launcherSha256 -or
        (Get-FileHash -LiteralPath $channelAgent -Algorithm SHA256).Hash.ToLowerInvariant() -cne $agentSha256) {
        throw 'Existing stable channel core differs from the reviewed version'
    }
    return [pscustomobject]@{
        Version = $version
        Root = $channelRoot
        Launcher = $channelLauncher
        Agent = $channelAgent
        AgentSha256 = $agentSha256
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }

$root = Join-Path $env:LOCALAPPDATA 'Teremoq'
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    [void][IO.Directory]::CreateDirectory($root)
}
$root = [IO.Path]::GetFullPath($root)

Write-Host '1/4 Buscando un checkout oficial reutilizable...' -ForegroundColor Cyan
$checkout = $null
$candidates = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -in @('checkout-updater-a','checkout-updater-b') -or $_.Name -match '^checkout-lan-[0-9a-f]{8}(?:-[a-z0-9-]{1,24})?$' } |
    Sort-Object LastWriteTimeUtc -Descending)
foreach ($candidate in $candidates) {
    if (Test-TeremoqReusableCheckout -CheckoutRoot $candidate.FullName) {
        $checkout = [IO.Path]::GetFullPath($candidate.FullName)
        Write-Host 'Checkout limpio actualizado mediante fast-forward.' -ForegroundColor Green
        break
    }
    Write-Host ("Se conserva sin modificar el checkout no reutilizable: {0}" -f $candidate.Name) -ForegroundColor Yellow
}

if ($null -eq $checkout) {
    Write-Host '2/4 No hay checkout limpio; creando automaticamente uno nuevo...' -ForegroundColor Cyan
    $availableSlots = @((Join-Path $root 'checkout-updater-a'), (Join-Path $root 'checkout-updater-b'))
    $checkout = $availableSlots | Where-Object { -not (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if ($null -eq $checkout) {
        $checkout = Join-Path $root ("checkout-lan-{0}-{1}" -f $ExpectedCommit.Substring(0, 8), [Guid]::NewGuid().ToString('N').Substring(0, 8))
    }
    [void](Invoke-TeremoqClientGit -WorkingDirectory $root -Arguments @(
        'clone', '--branch', $Branch, '--single-branch', '--no-tags', $RepositoryUrl, $checkout
    ))
} else {
    Write-Host '2/4 No es necesario clonar de nuevo.' -ForegroundColor Green
}

Write-Host '3/4 Verificando el commit y la limpieza finales...' -ForegroundColor Cyan
$validation = Get-TeremoqCheckoutValidation -CheckoutRoot $checkout
if (-not $validation.Valid) {
    $reasons = New-Object Collections.Generic.List[string]
    if ($validation.Head -cne $ExpectedCommit) { $reasons.Add('commit') }
    if ($validation.Branch -cne $Branch) { $reasons.Add('branch') }
    if ($validation.Remote -cne $RepositoryUrl) { $reasons.Add('remote') }
    if ($validation.Dirty) { $reasons.Add('local changes') }
    throw ("The selected Git checkout failed final validation: {0}" -f ($reasons -join ', '))
}
$head = $validation.Head

$channelCore = Install-TeremoqStableChannelCore -ClientRoot $root -CheckoutRoot $checkout
Write-Host ("4/4 Iniciando canal estable {0} con cliente {1}..." -f $channelCore.Version, $head.Substring(0, 8)) -ForegroundColor Green
& $channelCore.Launcher -ExpectedCommit $ExpectedCommit -ChannelCommit $ChannelCommit `
    -WorkCheckout $checkout -ChannelCoreAgentSha256 $channelCore.AgentSha256
