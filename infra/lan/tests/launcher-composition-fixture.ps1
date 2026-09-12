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
        StateRoot = $scratch; PlayerRoot = $scratch; LauncherPath = $launcher; VersionPath = $version; FingerprintPath = $pin
        Version = @{schema_version='2'; run_id='lan-fixture'; player_version='0.1.0'; updater_version='2.0.0'; player_identity=('sha256:' + ('1' * 64))}
    }
    [IO.File]::WriteAllText((Join-Path $scratch 'start.mjs'), '// fixture only', $utf8)
    [IO.File]::WriteAllText((Join-Path $scratch 'dependency.ps1'), '$global:TeremoqDependencyExecuted = $true', $utf8)
    [IO.File]::WriteAllText((Join-Path $scratch 'lan-launcher.tsv'), "schema_version`t1`n", $utf8)
    function Seal-FixturePlayer {
        $files = @()
        $total = 0
        foreach ($name in @('launcher.ps1','dependency.ps1','start.mjs','lan-launcher.tsv')) {
            $path = Join-Path $scratch $name
            $length = (Get-Item -LiteralPath $path).Length
            $files += [ordered]@{path=$name; bytes=$length; sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
            $total += $length
        }
        $manifest = [ordered]@{
            schema_version=1; artifact='teremoq-lan-lab-standalone'; entrypoint='start.mjs'
            package_version='0.1.0'; updater_version='2.0.0'; player_identity=$state.Version.player_identity
            player_version='0.1.0'; config_schema_version=1; files=$files; total_bytes=$total
        }
        $manifestPath = Join-Path $scratch 'MANIFEST.sha256.json'
        [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8 -Compress), $utf8)
        $state.Version.player_manifest_sha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $state.Version.launcher_contract_sha256 = (Get-FileHash -LiteralPath (Join-Path $scratch 'lan-launcher.tsv') -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    [IO.File]::WriteAllText($launcher, @'
[CmdletBinding()]
param([string]$Action,[switch]$ValidateOnly,[string]$StateRoot,[string]$RunId,[int]$Level,[string]$VersionPath,[string]$FingerprintPath,[string]$EvidenceDirectory)
if ($Action -cne 'Start' -or -not $ValidateOnly -or $RunId -cne 'lan-fixture' -or $Level -notin @(1,5,10,25)) { throw 'invalid validation invocation' }
if ($VersionPath -cne (Join-Path $StateRoot 'versions\fixture\VERSION.tsv') -or $FingerprintPath -cne (Join-Path $StateRoot 'config\public-identity\relay-cert.sha256')) { throw 'wrapper substituted managed paths' }
if ($EvidenceDirectory -cne (Join-Path (Join-Path (Join-Path $StateRoot 'evidence') $RunId) "level-$Level")) { throw 'non-deterministic evidence directory' }
if (Test-Path -LiteralPath $EvidenceDirectory) { throw 'validation created evidence directory' }
# The approved fixture attempts mutation while the production invoker holds
# pins. This is not a product launcher and creates no process/socket.
foreach ($name in @('launcher.ps1','dependency.ps1','start.mjs','lan-launcher.tsv','MANIFEST.sha256.json')) {
    $path = Join-Path $StateRoot $name
    $denied = $false
    try { [IO.File]::WriteAllText($path, 'substitute') } catch [IO.IOException] { $denied = $true }
    if (-not $denied) { throw 'write succeeded during execution pin' }
    $denied = $false
    try { [IO.File]::Move($path, ($path + '.substitute')) } catch [IO.IOException] { $denied = $true }
    if (-not $denied) { throw 'replacement succeeded during execution pin' }
}
& (Join-Path $StateRoot 'dependency.ps1')
if (-not $global:TeremoqDependencyExecuted) { throw 'approved dependency did not execute' }
exit 0
'@, $utf8)
    Seal-FixturePlayer
    foreach ($level in @(1,5,10,25)) { Assert-TeremoqLanLauncherStartContract -StateContext $state -Level $level }
    if (Test-Path -LiteralPath (Join-Path $scratch 'evidence')) { throw 'validation mutated evidence root' }
    $heldPins = Open-TeremoqLanPlayerPins -StateContext $state
    try {
        $movedRoot = $scratch + '.moved'
        $renameDenied = $false
        try { [IO.Directory]::Move($scratch, $movedRoot) } catch [IO.IOException] { $renameDenied = $true }
        if (-not $renameDenied) {
            [IO.Directory]::Move($movedRoot, $scratch)
            throw 'player directory replacement was possible while pinned'
        }
    } finally { foreach ($held in $heldPins) { $held.Dispose() } }
    # Security F01: context has already selected approved hashes; substitute
    # bytes before invoking the REAL adapter. No substituted code may run.
    foreach ($name in @('launcher.ps1','dependency.ps1')) {
        $path = Join-Path $scratch $name
        $approved = [IO.File]::ReadAllText($path)
        $global:TeremoqSubstituteExecuted = $false
        [IO.File]::WriteAllText($path, '$global:TeremoqSubstituteExecuted = $true', $utf8)
        try { Assert-TeremoqLanLauncherStartContract -StateContext $state; throw 'substituted executable was accepted' }
        catch { if ($_.Exception.Message -notmatch 'changed after context verification') { throw } }
        foreach ($action in @('Start','Status','Stop','Collect')) {
            try { Invoke-TeremoqPinnedLanLauncher -StateContext $state -Action $action; throw 'action accepted substituted executable' }
            catch { if ($_.Exception.Message -notmatch 'changed after context verification') { throw } }
        }
        if ($global:TeremoqSubstituteExecuted) { throw 'substituted code ran before rejection' }
        # Also proves partial pins were released on failure.
        [IO.File]::WriteAllText($path, $approved, $utf8)
        foreach ($file in (Get-ChildItem -LiteralPath $scratch -File)) {
            $probe = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $probe.Dispose()
        }
    }
    $manifestPath = Join-Path $scratch 'MANIFEST.sha256.json'
    $savedManifest = [IO.File]::ReadAllText($manifestPath)
    [IO.File]::WriteAllText($manifestPath, '{}', $utf8)
    try { Assert-TeremoqLanLauncherStartContract -StateContext $state; throw 'substituted manifest accepted' }
    catch { if ($_.Exception.Message -notmatch 'manifest changed after context verification') { throw } }
    [IO.File]::WriteAllText($manifestPath, $savedManifest, $utf8)
    foreach ($content in @(
        "[CmdletBinding()]param([string]`$Action) throw 'old launcher must not be accepted'",
        'exit 17',
        "throw 'sealed parser rejection'"
    )) {
        [IO.File]::WriteAllText($launcher, $content, $utf8)
        Seal-FixturePlayer
        try { Assert-TeremoqLanLauncherStartContract -StateContext $state; throw 'incompatible launcher was accepted' }
        catch { if ($_.Exception.Message -match 'incompatible launcher was accepted') { throw } }
        # Throw/nonzero script exit must release every retained handle.
        foreach ($file in (Get-ChildItem -LiteralPath $scratch -File)) {
            $probe = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $probe.Dispose()
        }
    }
    $state.Version.schema_version = '1'
    try { Assert-TeremoqLanLauncherStartContract -StateContext $state; throw 'legacy external state was accepted' }
    catch { if ($_.Exception.Message -match 'legacy external state was accepted') { throw } }
    Write-Output 'launcher composition ADAPTER canaries: PASS (managed paths, retained launcher/dependency pins, substitution rejected before execution, partial/error cleanup; not sealed Web E2E)'
} finally {
    Remove-Variable -Scope Global -Name TeremoqSubstituteExecuted,TeremoqDependencyExecuted -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $scratch -Recurse -Force
    if (Test-Path -LiteralPath $scratch) { throw 'adapter fixture cleanup incomplete' }
}
