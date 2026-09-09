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
    Write-Output 'client-start-bootstrap-fixture: PASS'
} finally {
    $env:GIT_CONFIG_GLOBAL = $oldGlobal
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
