# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
# Adapter canaries only: the real sealed Web composition is a separate gate.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot '..\client\Client-Distribution.ps1')
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('teremoq-launcher-composition-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
$utf8 = New-Object Text.UTF8Encoding($false)
try {
    $launcher = Join-Path $scratch 'launcher.ps1'
    $version = Join-Path $scratch 'versions\fixture\VERSION.tsv'
    $pin = Join-Path $scratch 'config\public-identity\relay-cert.sha256'
    $state = [pscustomobject]@{
        StateRoot = $scratch; LauncherPath = $launcher; VersionPath = $version; FingerprintPath = $pin
        Version = @{schema_version='2'; run_id='lan-fixture'}
    }
    [IO.File]::WriteAllText($launcher, @'
[CmdletBinding()]
param([string]$Action,[switch]$ValidateOnly,[string]$StateRoot,[string]$RunId,[int]$Level,[string]$VersionPath,[string]$FingerprintPath,[string]$EvidenceDirectory)
if ($Action -cne 'Start' -or -not $ValidateOnly -or $RunId -cne 'lan-fixture' -or $Level -notin @(1,5,10,25)) { throw 'invalid validation invocation' }
if ($VersionPath -cne (Join-Path $StateRoot 'versions\fixture\VERSION.tsv') -or $FingerprintPath -cne (Join-Path $StateRoot 'config\public-identity\relay-cert.sha256')) { throw 'wrapper substituted managed paths' }
if ($EvidenceDirectory -cne (Join-Path (Join-Path (Join-Path $StateRoot 'evidence') $RunId) "level-$Level")) { throw 'non-deterministic evidence directory' }
if (Test-Path -LiteralPath $EvidenceDirectory) { throw 'validation created evidence directory' }
exit 0
'@, $utf8)
    foreach ($level in @(1,5,10,25)) { Assert-TeremoqLanLauncherStartContract -StateContext $state -Level $level }
    if (Test-Path -LiteralPath (Join-Path $scratch 'evidence')) { throw 'validation mutated evidence root' }
    foreach ($content in @(
        "[CmdletBinding()]param([string]`$Action) throw 'old launcher must not be accepted'",
        'exit 17',
        "throw 'sealed parser rejection'"
    )) {
        [IO.File]::WriteAllText($launcher, $content, $utf8)
        try { Assert-TeremoqLanLauncherStartContract -StateContext $state; throw 'incompatible launcher was accepted' }
        catch { if ($_.Exception.Message -match 'incompatible launcher was accepted') { throw } }
    }
    $state.Version.schema_version = '1'
    try { Assert-TeremoqLanLauncherStartContract -StateContext $state; throw 'legacy external state was accepted' }
    catch { if ($_.Exception.Message -match 'legacy external state was accepted') { throw } }
    Write-Output 'launcher composition ADAPTER canaries: PASS (managed paths, ValidateOnly, levels, rejection propagation; not sealed Web E2E)'
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force
    if (Test-Path -LiteralPath $scratch) { throw 'adapter fixture cleanup incomplete' }
}
