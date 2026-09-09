# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RecoveryCommit
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$repositoryUrl = 'https://github.com/Teremoq/teremoq'
$repositoryRef = 'refs/heads/codex/lan-e2e-integration'
$branch = 'codex/lan-e2e-integration'
$channelCommit = '50e60ea00d87ebd03f855c5e1c17c1ac9e447598'
$clientCommit = '309f38981a8d2adabbbea6757d715f72f284cb8d'
$commitPattern = '^[0-9a-f]{40}$'

if ($PSVersionTable.PSEdition -cne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or
    $env:WSL_INTEROP -or $env:WSL_DISTRO_NAME) {
    throw 'Ejecuta esta orden en Windows PowerShell 5, no dentro de WSL.'
}
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Ejecuta esta recuperacion en una ventana PowerShell normal, no como administrador.'
}

$git = 'C:\Program Files\Git\cmd\git.exe'
if (-not (Test-Path -LiteralPath $git -PathType Leaf)) {
    throw 'No se encontro Git for Windows en Program Files.'
}
$gitHash = (Get-FileHash -LiteralPath $git -Algorithm SHA256).Hash

function Invoke-RecoveryGit {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    if ((Get-FileHash -LiteralPath $git -Algorithm SHA256).Hash -cne $gitHash) {
        throw 'git.exe cambio durante la recuperacion.'
    }
    $saved = @{}
    foreach ($name in @('GIT_CONFIG_NOSYSTEM','GIT_CONFIG_GLOBAL','GIT_NO_REPLACE_OBJECTS','GIT_TERMINAL_PROMPT','GCM_INTERACTIVE')) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $env:GIT_CONFIG_NOSYSTEM = '1'
        $env:GIT_CONFIG_GLOBAL = 'NUL'
        $env:GIT_NO_REPLACE_OBJECTS = '1'
        $env:GIT_TERMINAL_PROMPT = '0'
        $env:GCM_INTERACTIVE = 'Never'
        $global:LASTEXITCODE = $null
        $lines = @(& $git --no-replace-objects -c core.hooksPath=NUL -c core.fsmonitor=false `
            -c core.attributesFile=NUL -c core.autocrlf=false -c core.eol=lf -c core.safecrlf=true `
            -c protocol.file.allow=never -c protocol.ext.allow=never -C $WorkingDirectory @Arguments 2>&1)
        $exitCode = $global:LASTEXITCODE
    } finally {
        foreach ($name in $saved.Keys) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
        }
        $ErrorActionPreference = $previousPreference
    }
    $output = (($lines | ForEach-Object { [string]$_ }) -join "`n").Trim()
    if ($output.Length -gt 32768) { throw 'La salida de Git excedio el limite de recuperacion.' }
    if ($exitCode -isnot [int] -or $exitCode -ne 0) {
        throw ("Git rechazo la operacion {0}." -f $Arguments[0])
    }
    return $output
}

function Get-RemoteCommit {
    param([Parameter(Mandatory = $true)][string]$WorkingDirectory)
    $line = Invoke-RecoveryGit -WorkingDirectory $WorkingDirectory -Arguments @(
        'ls-remote', '--exit-code', '--refs', $repositoryUrl, $repositoryRef
    )
    if ($line -cnotmatch ('^(?<commit>[0-9a-f]{40})\t' + [regex]::Escape($repositoryRef) + '$')) {
        throw 'GitHub devolvio una referencia LAN inesperada.'
    }
    return $Matches['commit']
}

$root = Join-Path $env:LOCALAPPDATA 'Teremoq'
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    [void][IO.Directory]::CreateDirectory($root)
}
$root = [IO.Path]::GetFullPath($root).TrimEnd('\', '/')

Write-Host '[Teremoq] 1/4 Consultando la version revisada en GitHub...' -ForegroundColor Cyan
$remoteBeforeClone = Get-RemoteCommit -WorkingDirectory $root
if ($RecoveryCommit -cnotmatch $commitPattern -or $remoteBeforeClone -cne $RecoveryCommit) {
    throw 'La rama LAN ya no apunta al commit exacto solicitado.'
}
$checkout = Join-Path $root ("channel-recovery-{0}-{1}" -f $recoveryCommit.Substring(0, 8), [Guid]::NewGuid().ToString('N').Substring(0, 8))

Write-Host '[Teremoq] 2/4 Descargando una copia limpia y temporal...' -ForegroundColor Cyan
[void](Invoke-RecoveryGit -WorkingDirectory $root -Arguments @(
    'clone', '--branch', $branch, '--single-branch', '--no-tags', $repositoryUrl, $checkout
))

Write-Host '[Teremoq] 3/4 Verificando commit, remoto y limpieza...' -ForegroundColor Cyan
$head = (Invoke-RecoveryGit -WorkingDirectory $checkout -Arguments @('rev-parse','HEAD')).Trim()
$checkedBranch = (Invoke-RecoveryGit -WorkingDirectory $checkout -Arguments @('symbolic-ref','--short','HEAD')).Trim()
$remote = (Invoke-RecoveryGit -WorkingDirectory $checkout -Arguments @('remote','get-url','origin')).Trim().TrimEnd('/')
$dirty = (Invoke-RecoveryGit -WorkingDirectory $checkout -Arguments @('status','--porcelain=v1','--untracked-files=all')).Trim()
$remoteAfterClone = Get-RemoteCommit -WorkingDirectory $checkout
if ($head -cne $recoveryCommit -or $remoteAfterClone -cne $recoveryCommit -or
    $checkedBranch -cne $branch -or $remote -cne $repositoryUrl -or -not [string]::IsNullOrEmpty($dirty)) {
    throw 'La copia descargada no coincide con la rama LAN revisada y limpia.'
}

Write-Host '[Teremoq] 4/4 Retirando solamente procesos y ranuras antiguas...' -ForegroundColor Cyan
$repair = Join-Path $checkout 'infra\lan\client\Repair-LanUpdaterSlots.ps1'
if (-not (Test-Path -LiteralPath $repair -PathType Leaf)) { throw 'La herramienta revisada de recuperacion no existe.' }
& $repair -RecoveryCommit $recoveryCommit -ChannelCommit $channelCommit -ClientCommit $clientCommit

Write-Host ("RECUPERACION {0} COMPLETA" -f $recoveryCommit.Substring(0, 8)) -ForegroundColor Green
