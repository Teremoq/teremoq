# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CheckoutRoot,
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [Parameter(Mandatory = $true)][string]$RepositoryUrl,
    [Parameter(Mandatory = $true)][string]$RepositoryRef,
    [Parameter(Mandatory = $true)][string]$SourceCommit,
    [switch]$RefreshDependencies,
    [switch]$Offline
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

# Windows PowerShell 5 otherwise formats native diagnostics with the active OEM
# code page, while the bounded parent process deliberately accepts UTF-8 only.
$utf8NoBom = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

if (-not [IO.Path]::IsPathRooted($CheckoutRoot) -or
    -not [IO.Path]::IsPathRooted($StateRoot) -or
    $RepositoryUrl -cne 'https://github.com/Teremoq/teremoq' -or
    $RepositoryRef -cnotmatch '^refs/heads/[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$' -or
    $SourceCommit -cnotmatch '^[0-9a-f]{40}$' -or
    @(@($CheckoutRoot, $StateRoot, $RepositoryUrl, $RepositoryRef, $SourceCommit) |
        Where-Object { $_ -match "[`r`n]" }).Count -ne 0) {
    throw 'LAN Git distribution parameters are outside the closed policy'
}

$checkout = [IO.Path]::GetFullPath($CheckoutRoot)
$project = [IO.Path]::GetFullPath((Join-Path $checkout 'supervisor-web'))
$expectedScriptRoot = [IO.Path]::GetFullPath((Join-Path $project 'lan-player'))
if ($expectedScriptRoot -cne [IO.Path]::GetFullPath($PSScriptRoot) -or
    -not (Test-Path -LiteralPath $project -PathType Container)) {
    throw 'launcher must run from supervisor-web/lan-player in the exact checkout'
}

$node = Join-Path $env:ProgramFiles 'nodejs\node.exe'
$npm = Join-Path $env:ProgramFiles 'nodejs\npm.cmd'
$npmCli = Join-Path $env:ProgramFiles 'nodejs\node_modules\npm\bin\npm-cli.js'
if (-not (Test-Path -LiteralPath $node -PathType Leaf) -or
    -not (Test-Path -LiteralPath $npm -PathType Leaf) -or
    -not (Test-Path -LiteralPath $npmCli -PathType Leaf)) {
    throw 'Node 22.x and npm 10.x are required in Program Files'
}
$nodeVersionOutput = @(& $node --version)
$nodeVersionExit = $LASTEXITCODE
if ($nodeVersionExit -ne 0 -or $nodeVersionOutput.Count -ne 1) {
    throw 'Node runtime version could not be determined'
}
$nodeVersion = ([string]$nodeVersionOutput[0]).Trim()
if ($nodeVersion -cnotmatch '^v22[.][0-9]+[.][0-9]+$') {
    throw 'Node runtime must be exact major 22'
}
$npmVersionOutput = @(& $node $npmCli --version)
$npmVersionExit = $LASTEXITCODE
if ($npmVersionExit -ne 0 -or $npmVersionOutput.Count -ne 1) {
    throw 'npm runtime version could not be determined'
}
$npmVersion = ([string]$npmVersionOutput[0]).Trim()
if ($npmVersion -cnotmatch '^10[.][0-9]+[.][0-9]+$') {
    throw 'npm runtime must be exact major 10'
}

$arguments = @(
    'run', 'distribute:lan', '--',
    '--checkout-root', $checkout,
    '--state-root', [IO.Path]::GetFullPath($StateRoot),
    '--repository-url', $RepositoryUrl,
    '--repository-ref', $RepositoryRef,
    '--source-commit', $SourceCommit
)
if ($RefreshDependencies) { $arguments += '--refresh-dependencies' }
if ($Offline) { $arguments += '--offline' }

Push-Location -LiteralPath $project
try {
    & $npm @arguments
    if ($LASTEXITCODE -ne 0) { throw 'local source build/package failed closed' }
} finally {
    Pop-Location
}
