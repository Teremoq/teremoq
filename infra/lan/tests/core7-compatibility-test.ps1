# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
# Isolated fixtures, never native preflight or product activation.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
if ($PSVersionTable.PSEdition -cne 'Core' -or $PSVersionTable.PSVersion.ToString() -cne '7.6.6' -or
    [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() -cne 'X64' -or
    [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'exact Windows Core7.6.6 x64 fixture required' }
. (Join-Path $PSScriptRoot '..\client\Client-Distribution.ps1')
. (Join-Path $PSScriptRoot '..\client\Client-Slot-State.ps1')
function Assert-Rejected([scriptblock]$Action) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'negative fixture was accepted' }
}
function Get-Definition([string]$Path, [string]$Name) {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw 'fixture source parse failed' }
    $nodes=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$true))
    if ($nodes.Count -ne 1) { throw 'fixture source definition not unique' }
    return [scriptblock]::Create($nodes[0].Extent.Text)
}
. (Get-Definition (Join-Path $PSScriptRoot '..\client\Import-BrowserObservation.ps1') 'Parse-CanonicalUtc')
foreach ($name in @('Test-TeremoqCaptureContextEvidence','Test-TeremoqTrustedExplorerRootTermination')) {
    . (Get-Definition (Join-Path $PSScriptRoot '..\windows\Preflight-Contract.ps1') $name)
}
$json='{"schema_version":1,"started_at_utc":"2026-09-12T15:00:00.000Z"}'
$default=$json | ConvertFrom-Json
if ($default.started_at_utc -isnot [datetime] -or $default.schema_version -isnot [long]) { throw 'Core7 reproduction differs' }
Assert-Rejected { Parse-CanonicalUtc $default.started_at_utc 'timestamp' }
$parsed=$json | ConvertFrom-TeremoqLanJson
if ($parsed.started_at_utc -isnot [string] -or $parsed.started_at_utc -cne '2026-09-12T15:00:00.000Z') { throw 'JSON string bytes were reinterpreted' }
[void](Parse-CanonicalUtc $parsed.started_at_utc 'timestamp')
foreach ($bad in @($null,$true,1,[datetime]::UtcNow,'2026-09-12T15:00:00Z')) { Assert-Rejected { Parse-CanonicalUtc $bad 'timestamp' } }
$record=New-TeremoqLanSlotRecord -UpdaterCommit ('1'*40) -PlayerIdentity (Get-TeremoqLanPlayerIdentity -SourceTree ('2'*40) -PackageLockSha256 ('3'*64)) `
    -SourceTree ('2'*40) -PackageLockSha256 ('3'*64) -PlayerManifestSha256 ('4'*64) -LauncherContractSha256 ('5'*64) -ConfigSha256 ('6'*64)
$canonical=ConvertTo-TeremoqLanSlotJson $record
$roundtrip=$canonical | ConvertFrom-TeremoqLanJson
Assert-TeremoqTransitionSlotTypes $roundtrip
if ((ConvertTo-TeremoqLanSlotJson $roundtrip) -cne $canonical) { throw 'slot raw canonical roundtrip differs' }
foreach ($bad in @($true,'1',[double]1,[decimal]1,[single]1,0,2,$null)) {
    $negative=$canonical | ConvertFrom-TeremoqLanJson
    $negative.schema_version=$bad
    Assert-Rejected { Assert-TeremoqTransitionSlotTypes $negative }
}
foreach ($good in @([byte]1,[sbyte]1,[int16]1,[uint16]1,[int32]1,[uint32]1,[int64]1,[uint64]1)) {
    $roundtrip.schema_version=$good; Assert-TeremoqTransitionSlotTypes $roundtrip
}
$extra=$canonical | ConvertFrom-TeremoqLanJson
$extra | Add-Member unexpected 'reject'
Assert-Rejected { Assert-TeremoqTransitionSlotTypes $extra }
$context=[ordered]@{schema_version=2;current_process_name='pwsh.exe';parent_process_names=@('explorer.exe');parent_process_count=1;
    traversal_depth_limit=16;traversal_outcome='terminated_after_explorer_root_missing';wsl_environment_keys_present=@();powershell_edition='Core';powershell_version_major=7}
if (-not (Test-TeremoqCaptureContextEvidence $context)) { throw 'closed Core7 pair rejected' }
foreach ($mutation in @(@('powershell_edition','Desktop'),@('current_process_name','powershell.exe'),@('powershell_version_major',5),
    @('powershell_version_major','7'),@('powershell_version_major',[double]7),@('powershell_version_major',$true),
    @('parent_process_names',@('explorer.exe','wslhost.exe')),@('wsl_environment_keys_present',@('WSL_INTEROP')))) {
    $copy=[ordered]@{}; foreach($key in $context.Keys){$copy[$key]=$context[$key]};$copy[$mutation[0]]=$mutation[1]
    if (Test-TeremoqCaptureContextEvidence $copy) { throw 'capture pair/type/WSL mutation accepted' }
}
# Runtime guards are evaluated BEFORE any dot-source. No copied helper can run
# Exercise the unchanged double-query/CIM traversal with the new runtime pair.
# Its names are synthetic; this does not assert native capture from this host.
& {
    . (Join-Path $PSScriptRoot '..\windows\Preflight-Contract.ps1')
    foreach ($mode in @('stable','changed-parent','changed-date','query-failed','wsl')) {
        $current=[ordered]@{ProcessId=[int64]211;ParentProcessId=[int64]210;Name='pwsh.exe';CreationDate='20260831100000.000000+000'}
        $parent=[ordered]@{ProcessId=[int64]210;ParentProcessId=[int64]209;Name='explorer.exe';CreationDate='20260831095900.000000+000'}
        $counter=@{Parent=0}
        $resolver={param($ProcessId)
            if ($ProcessId -eq 211) { return [ordered]@{Status='ok';RequestedProcessId=[int64]211;Process=$current} }
            if ($ProcessId -eq 210) {
                $counter.Parent++
                if ($counter.Parent -eq 2) {
                    if ($mode -ceq 'query-failed') { return [ordered]@{Status='cim_query_failed';RequestedProcessId=[int64]210;Process=$null} }
                    if ($mode -ceq 'changed-parent') { $parent.ParentProcessId=[int64]208 }
                    if ($mode -ceq 'changed-date') { $parent.CreationDate='20260831095800.000000+000' }
                }
                return [ordered]@{Status='ok';RequestedProcessId=[int64]210;Process=$parent}
            }
            return [ordered]@{Status='process_missing';RequestedProcessId=[int64]$ProcessId;Process=$null}
        }.GetNewClosure()
        $envKeys=if($mode -ceq 'wsl'){@('WSL_INTEROP')}else{@()}
        $result=New-TeremoqCaptureContext -CurrentProcessId 211 -CurrentResult ([ordered]@{Status='ok';RequestedProcessId=[int64]211;Process=$current}) `
            -ResolveProcess $resolver -ObservedEnvKeys @($envKeys)
        if ($mode -ceq 'stable') {
            if ($result.traversal_outcome -cne 'terminated_after_explorer_root_missing' -or
                -not (Test-TeremoqCaptureContextEvidence $result)) { throw 'stable Core7 producer rejected' }
        } elseif (Test-TeremoqCaptureContextEvidence $result) { throw 'unstable/WSL Core7 producer accepted' }
    }
}
# Runtime guards are evaluated BEFORE any dot-source. No copied helper can run
# on a rejected host; this is verified by AST order plus the real Desktop child.
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('teremoq-core7-guard-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
try {
    $prepare=Join-Path $PSScriptRoot '..\client\Prepare-LanClientFromGit.ps1'
    $initialize=Join-Path $PSScriptRoot '..\client\Initialize-LanClientState.ps1'
    foreach($path in @($prepare,$initialize)) {
        $text=[IO.File]::ReadAllText($path)
        if ($text.IndexOf("if (`$PSVersionTable.PSEdition") -ge $text.IndexOf(". (Join-Path `$PSScriptRoot")) { throw 'runtime guard follows helper load' }
    }
    $desktop=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # A fixture-only local wrapper makes Desktop's error transport UTF-8;
    # the actual production entrypoint is still invoked unchanged under PS5.
    $child=@'
$ErrorActionPreference='Stop'
$utf8=New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding=$utf8
$errWriter=New-Object IO.StreamWriter([Console]::OpenStandardError(),$utf8)
$errWriter.AutoFlush=$true
[Console]::SetError($errWriter)
try {
    & '__PREPARE__' -CheckoutRoot '__SCRATCH__\checkout' -StateRoot '__SCRATCH__\state' `
        -RepositoryUrl 'https://github.com/Teremoq/teremoq' -RepositoryRef 'refs/heads/codex/lan-e2e-integration' -ExpectedCommit ('1'*40) `
        -RunId 'lan-core7-fixture' -ServerIPv4 '192.168.77.10' -PrefixLength 24 -Namespace 'teremoq/live' -FingerprintSha256 ('2'*64) -MaterialOnly
    exit 0
} catch { [Console]::Error.Write($_.Exception.Message); exit 17 }
'@
    $child=$child.Replace('__PREPARE__',$prepare.Replace("'","''")).Replace('__SCRATCH__',$scratch.Replace("'","''"))
    $childPath=Join-Path $scratch 'reject-desktop.ps1'
    [IO.File]::WriteAllText($childPath,$child,(New-Object Text.UTF8Encoding($true)))
    $argsBase=@('-NoProfile','-NonInteractive','-File',$childPath)
    $result=Invoke-TeremoqBoundedNativeProcess -FilePath $desktop -WorkingDirectory $scratch -Arguments $argsBase -TimeoutMilliseconds 10000
    if ($result.ExitCode -eq 0 -or $result.Stderr -notmatch 'requires the selected Windows x64 PowerShell Core 7.6.6 host') { throw 'Desktop guard did not fail at the expected boundary' }
    if (@(Get-ChildItem -LiteralPath $scratch -Force).Count -ne 1 -or
        (Get-Item -LiteralPath $childPath).Length -le 0) { throw 'rejected host wrote state' }
} finally { [IO.Directory]::Delete($scratch,$true) }
Write-Output 'core7-compatibility-test: PASS (actual Core7.6.6 x64; synthetic JSON/types/context; Desktop pre-effects reject; no product activation)'
