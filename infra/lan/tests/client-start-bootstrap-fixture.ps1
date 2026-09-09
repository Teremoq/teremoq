# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ScriptPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$zeroCommit = '0' * 40
. $ScriptPath -ExpectedCommit $zeroCommit -ChannelCommit $zeroCommit

$root = Join-Path ([IO.Path]::GetTempPath()) ('teremoq-start-bootstrap-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$oldGlobal = $env:GIT_CONFIG_GLOBAL
try {
    & $script:Git -C $root init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'fixture Git init failed' }
    $ignored = Join-Path $root 'global-ignore.txt'
    [IO.File]::WriteAllText($ignored, "hidden.txt`n", (New-Object Text.UTF8Encoding($false)))
    $globalConfig = Join-Path $root 'global-config'
    [IO.File]::WriteAllText(
        $globalConfig,
        "[core]`n`texcludesfile = $($ignored.Replace('\', '/'))`n",
        (New-Object Text.UTF8Encoding($false))
    )
    $env:GIT_CONFIG_GLOBAL = $globalConfig
    [IO.File]::WriteAllText((Join-Path $root 'hidden.txt'), 'must remain visible')

    $status = Get-TeremoqGitValue -WorkingDirectory $root -Arguments @(
        'status', '--porcelain=v1', '--untracked-files=all'
    )
    if ($status -cnotmatch '\?\? hidden\.txt') {
        throw 'isolated bootstrap Git view accepted a global excludes file'
    }
    if ($env:GIT_CONFIG_GLOBAL -cne $globalConfig) {
        throw 'bootstrap Git invocation did not restore the caller environment'
    }

    $clientRoot = Join-Path $root 'client-root'
    $checkout = Join-Path $clientRoot 'checkout-updater-a'
    $clientSource = Join-Path $checkout 'infra\lan\client'
    [void][IO.Directory]::CreateDirectory($clientSource)
    [IO.File]::WriteAllText((Join-Path $clientSource 'Start-LanInteractiveClient.ps1'), 'launcher-v1')
    [IO.File]::WriteAllText((Join-Path $clientSource 'Lan-Interactive-Agent.mjs'), 'agent-v1')
    $sentinel = Join-Path $checkout 'workload-sentinel.txt'
    [IO.File]::WriteAllText($sentinel, 'untouched')
    $firstCore = Install-TeremoqStableChannelCore -ClientRoot $clientRoot -CheckoutRoot $checkout
    $secondCore = Install-TeremoqStableChannelCore -ClientRoot $clientRoot -CheckoutRoot $checkout
    if ($firstCore.Root -cne $secondCore.Root -or
        $firstCore.Root.StartsWith($checkout + '\', [StringComparison]::OrdinalIgnoreCase) -or
        [IO.File]::ReadAllText($sentinel) -cne 'untouched') {
        throw 'stable channel core was not reused independently of the workload checkout'
    }
    [IO.File]::WriteAllText((Join-Path $clientSource 'Lan-Interactive-Agent.mjs'), 'agent-v2')
    $thirdCore = Install-TeremoqStableChannelCore -ClientRoot $clientRoot -CheckoutRoot $checkout
    if ($thirdCore.Root -ceq $firstCore.Root -or -not (Test-Path -LiteralPath $firstCore.Agent -PathType Leaf) -or
        [IO.File]::ReadAllText($firstCore.Agent) -cne 'agent-v1' -or
        [IO.File]::ReadAllText($thirdCore.Agent) -cne 'agent-v2') {
        throw 'stable channel core versioning overwrote an active or prior core'
    }
    Write-Output 'client-start-bootstrap-fixture: PASS'
} finally {
    $env:GIT_CONFIG_GLOBAL = $oldGlobal
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
