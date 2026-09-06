# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ExpectedCommit
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
    $ErrorActionPreference = 'Continue'
    try {
        $global:LASTEXITCODE = $null
        $lines = @(& $script:Git --no-replace-objects `
            -c core.hooksPath=NUL -c core.fsmonitor=false `
            -c core.autocrlf=false -c core.eol=lf `
            -c protocol.file.allow=never -C $WorkingDirectory @Arguments 2>&1)
        $exitCode = $global:LASTEXITCODE
    } finally {
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
        return $true
    } catch {
        return $false
    }
}

$root = Join-Path $env:LOCALAPPDATA 'Teremoq'
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    [void][IO.Directory]::CreateDirectory($root)
}
$root = [IO.Path]::GetFullPath($root)

Write-Host '1/4 Buscando un checkout oficial reutilizable...' -ForegroundColor Cyan
$checkout = $null
$candidates = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -in @('checkout-updater-a','checkout-updater-b') -or $_.Name -match '^checkout-lan-[0-9a-f]{8}(?:-[0-9a-f]{8})?$' } |
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
    if ($null -eq $checkout) { throw 'Both updater A/B slots exist but neither is safely reusable' }
    [void](Invoke-TeremoqClientGit -WorkingDirectory $root -Arguments @(
        'clone', '--branch', $Branch, '--single-branch', '--no-tags', $RepositoryUrl, $checkout
    ))
} else {
    Write-Host '2/4 No es necesario clonar de nuevo.' -ForegroundColor Green
}

Write-Host '3/4 Verificando el commit y la limpieza finales...' -ForegroundColor Cyan
$head = Get-TeremoqGitValue -WorkingDirectory $checkout -Arguments @('rev-parse','HEAD')
$branchName = Get-TeremoqGitValue -WorkingDirectory $checkout -Arguments @('symbolic-ref','--short','HEAD')
$remote = (Get-TeremoqGitValue -WorkingDirectory $checkout -Arguments @('remote','get-url','origin')).TrimEnd('/')
$dirtyFinal = Get-TeremoqGitValue -WorkingDirectory $checkout -Arguments @(
    'status', '--porcelain=v1', '--untracked-files=all'
)
if ($head -cne $ExpectedCommit -or $branchName -cne $Branch -or $remote -cne $RepositoryUrl -or
    -not [string]::IsNullOrEmpty($dirtyFinal)) {
    throw 'The selected Git checkout does not match the exact reviewed client source'
}

Write-Host ("4/4 Iniciando cliente Teremoq en commit {0}..." -f $head.Substring(0, 8)) -ForegroundColor Green
& (Join-Path $checkout 'infra\lan\client\Start-LanInteractiveClient.ps1') -ExpectedCommit $ExpectedCommit
