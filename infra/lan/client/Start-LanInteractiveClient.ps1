# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

if ($PSVersionTable.PSEdition -cne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $env:WSL_INTEROP -or $env:WSL_DISTRO_NAME) {
    throw 'Run this launcher in native Windows PowerShell 5 Desktop'
}

$checkout = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$git = Get-Command git.exe -ErrorAction Stop
$node = Get-Command node.exe -ErrorAction Stop
$nodeVersion = (@(& $node.Source --version 2>$null) -join '').Trim()
if ($nodeVersion -cnotmatch '^v22\.[0-9]+\.[0-9]+$') { throw 'The interactive client requires the installed Node.js 22.x runtime' }
$head = (@(& $git.Source -C $checkout rev-parse HEAD 2>$null) -join '').Trim()
$branch = (@(& $git.Source -C $checkout symbolic-ref --short HEAD 2>$null) -join '').Trim()
$remote = (@(& $git.Source -C $checkout remote get-url origin 2>$null) -join '').Trim().TrimEnd('/')
$dirty = (@(& $git.Source -C $checkout status --porcelain=v1 --untracked-files=normal 2>$null) -join '').Trim()
if ($LASTEXITCODE -ne 0 -or $head -cnotmatch '^[0-9a-f]{40}$' -or $branch -cne 'codex/lan-e2e-integration' -or
    $remote -cne 'https://github.com/Teremoq/teremoq' -or $dirty.Length -ne 0) {
    throw 'The Git checkout must be clean, on the reviewed LAN branch and use the official remote'
}

$runId = 'lan-20260831-wifi1'
$shortCommit = $head.Substring(0, 12)
$root = Join-Path $env:LOCALAPPDATA 'Teremoq'
$stateRoot = Join-Path $root ("interactive-state-{0}-{1}" -f $runId, $shortCommit)
$evidenceRoot = Join-Path $root ("interactive-evidence-{0}-{1}" -f $runId, $shortCommit)
if (-not (Test-Path -LiteralPath $root -PathType Container)) { New-Item -ItemType Directory -Path $root | Out-Null }
if (-not (Test-Path -LiteralPath $evidenceRoot -PathType Container)) { New-Item -ItemType Directory -Path $evidenceRoot | Out-Null }

Write-Host "Teremoq LAN interactive client: commit $head"
Write-Host 'The client only initiates outbound HTTPS and executes the reviewed fixed action list.'
$pairingCode = Read-Host 'Enter the one-time pairing code shown on the server'
if ($pairingCode -cnotmatch '^[0-9a-f]{48}$') { throw 'The pairing code must contain exactly 48 lowercase hexadecimal characters' }
$pairingCode | & $node.Source (Join-Path $PSScriptRoot 'Lan-Interactive-Agent.mjs') `
    --server 'https://192.168.1.130:18443' `
    --fingerprint '7984fd4852ec204dc16fb445d5260325fd3b686b478676767f52a1fa63a1a7bc' `
    --run-id $runId `
    --source-commit $head `
    --pairing-stdin 'true' `
    --checkout $checkout `
    --state-root $stateRoot `
    --evidence-root $evidenceRoot
if ($LASTEXITCODE -ne 0) { throw "Teremoq LAN interactive client stopped with exit code $LASTEXITCODE" }
