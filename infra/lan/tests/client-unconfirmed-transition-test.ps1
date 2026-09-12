# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
# Native file/state fixtures only: no player, server, build or network.
[CmdletBinding()]
param([string]$CrashStateRoot,[string]$CrashSourceSha256,[string]$CrashTargetSha256,
    [ValidateSet('Supersede','Restore')][string]$CrashAction='Supersede')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot '..\client\Client-Distribution.ps1')
. (Join-Path $PSScriptRoot '..\client\Client-Slot-State.ps1')
$fixtureSource = Join-Path $PSScriptRoot 'client-slot-state-test.ps1'
$tokens=$null; $errors=$null
$ast = [Management.Automation.Language.Parser]::ParseFile($fixtureSource,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'slot fixture parse failed' }
foreach ($name in @('New-FixtureSlot','Get-FixturePreservationSnapshot')) {
    $definition = @($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
    if ($definition.Count -ne 1) { throw 'existing fixture helper is not unique' }
    . ([scriptblock]::Create($definition[0].Extent.Text))
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('teremoq-assisted-fixture-' + [Guid]::NewGuid().ToString('N'))
$utf8 = New-Object Text.UTF8Encoding($false)
$hash = 'a' * 64
$realCopy = (Get-Item function:Write-TeremoqTransitionCopy).ScriptBlock
$realAtomic = (Get-Item function:Write-TeremoqAtomicUtf8File).ScriptBlock
$realPointer = (Get-Item function:Write-TeremoqTransitionPointer).ScriptBlock
$script:armed=$false; $script:writes=0; $script:cut=0
function Invoke-FixtureCut {
    if ($script:armed) {
        $script:writes++
        if ($script:cut -eq $script:writes) { throw 'fixture cut AFTER a completed real durable write' }
    }
}
function Write-TeremoqTransitionCopy {
    param([string]$Path,[string]$Text)
    $existed=Test-Path -LiteralPath $Path
    & $realCopy -Path $Path -Text $Text
    if (-not $existed) { Invoke-FixtureCut }
}
function Write-TeremoqAtomicUtf8File {
    param([string]$Path,[string]$Content)
    & $realAtomic -Path $Path -Content $Content
    Invoke-FixtureCut
}
function Write-TeremoqTransitionPointer {
    param($Layout,[string]$Directory,[string]$Name,[string]$Destination,$Record)
    & $realPointer -Layout $Layout -Directory $Directory -Name $Name -Destination $Destination -Record $Record
    Invoke-FixtureCut
}
function New-TransitionFixture {
    param([string]$Name)
    $script:armed=$false
    $state=Join-Path $testRoot $Name
    $source=New-FixtureSlot -Commit ('1'*40) -Tree ('2'*40) -Lock ('3'*64) -StateRoot $state
    [void](Stage-TeremoqLanClientSlot -StateRoot $state -Record $source)
    [void](Activate-TeremoqLanClientSlot -StateRoot $state)
    $target=New-FixtureSlot -Commit ('4'*40) -Tree ('5'*40) -Lock ('6'*64) -StateRoot $state
    foreach ($record in @($source,$target)) {
        [IO.File]::WriteAllText((Join-Path (Join-Path $state $record.version_relative_path) 'SHA256SUMS'), "fixture-only`n",$utf8)
    }
    [void][IO.Directory]::CreateDirectory((Join-Path $state 'evidence'))
    [IO.File]::WriteAllText((Join-Path $state 'evidence\original.txt'),'synthetic evidence preserved, not audiovisual',$utf8)
    $targetPath=Join-Path $state 'prepared-target.json'
    [IO.File]::WriteAllText($targetPath,(ConvertTo-TeremoqLanSlotJson $target),$utf8)
    $transitionArguments=@{StateRoot=$state;TransitionId='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
        ExpectedSourceSha256=(Get-TeremoqBoundedFileSha256 (Join-Path $state 'control\active.json') 4096);
        ExpectedTargetSha256=(Get-TeremoqBoundedFileSha256 $targetPath 4096);ExpectedTargetCommit=$target.updater_commit;TargetRecordPath=$targetPath}
    $preserved=@{}
    foreach($name in @('config','versions','players','evidence')) { $preserved[$name]=Get-FixturePreservationSnapshot (Join-Path $state $name) }
    return @{Arguments=$transitionArguments;Preserved=$preserved;Source=$source;Target=$target}
}
function Assert-PreservedFixture {
    param($Fixture,[string]$ExpectedPhase)
    $transitionArguments=$Fixture.Arguments
    foreach($name in @('config','versions','players','evidence')) {
        if ((Get-FixturePreservationSnapshot (Join-Path $transitionArguments.StateRoot $name)) -cne $Fixture.Preserved[$name]) { throw "preservation failed: $name" }
    }
    if (Test-Path -LiteralPath (Join-Path $transitionArguments.StateRoot 'control\rollback.json')) { throw 'a healthy rollback was fabricated' }
    $result=Invoke-TeremoqAssistedUnconfirmedTransition -Action Status @transitionArguments
    if($result.Status -cne $ExpectedPhase -or $result.Health -cne 'not_measured') { throw 'phase or health claim mismatch' }
    [void](Get-TeremoqActiveLanClientSlot -StateRoot $transitionArguments.StateRoot -ReadOnly)
}
if ($CrashStateRoot) {
    # This dedicated child kills ONLY ITSELF immediately after a real pointer
    # replacement, so no PowerShell finally runs. Parent owns/reconciles state.
    function Write-TeremoqTransitionPointer {
        param($Layout,[string]$Directory,[string]$Name,[string]$Destination,$Record)
        & $realPointer -Layout $Layout -Directory $Directory -Name $Name -Destination $Destination -Record $Record
        if (($CrashAction -ceq 'Supersede' -and $Name -ceq 'candidate') -or
            ($CrashAction -ceq 'Restore' -and $Name -ceq 'active')) {
            Stop-Process -Id $PID -Force
        }
    }
    Invoke-TeremoqAssistedUnconfirmedTransition -Action $CrashAction -StateRoot $CrashStateRoot `
        -TransitionId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' -ExpectedSourceSha256 $CrashSourceSha256 `
        -ExpectedTargetSha256 $CrashTargetSha256 -ExpectedTargetCommit ('4'*40) `
        -TargetRecordPath (Join-Path $CrashStateRoot 'prepared-target.json') | Out-Null
    throw 'native self-termination canary did not terminate'
}
[void][IO.Directory]::CreateDirectory($testRoot)
try {
    $fixture=New-TransitionFixture 'baseline'
    $arguments=$fixture.Arguments
    $script:writes=0;$script:cut=0;$script:armed=$true
    $result=Invoke-TeremoqAssistedUnconfirmedTransition -Action Supersede @arguments
    $applyWrites=$script:writes; $script:armed=$false
    Assert-PreservedFixture $fixture 'pending-health'
    $manager=Join-Path $PSScriptRoot '..\client\Manage-LanClientSlots.ps1'
    $managerResult=(& $manager -Action UnconfirmedStatus @arguments -ConfirmTransitionId $arguments.TransitionId) | ConvertFrom-Json
    if($managerResult.Status -cne 'pending-health' -or $managerResult.Health -cne 'not_measured'){throw 'real Manage status contract differs'}
    try { & $manager -Action RestoreUnconfirmed @arguments -ConfirmTransitionId 'wrong';throw 'unconfirmed CLI action accepted' }
    catch {if($_.Exception.Message -cne 'explicit confirmation of the exact assisted transition ID is required'){throw}}
    $before=Get-FixturePreservationSnapshot $arguments.StateRoot
    try { Invoke-TeremoqAssistedUnconfirmedTransition -Action status @arguments | Out-Null;throw 'noncanonical status accepted' }
    catch {if($_.Exception.Message -cne 'explicit assisted transition identity is invalid'){throw}}
    if((Get-FixturePreservationSnapshot $arguments.StateRoot) -cne $before){throw 'noncanonical status mutated state'}
    [void](Invoke-TeremoqAssistedUnconfirmedTransition -Action Supersede @arguments)
    if((Get-FixturePreservationSnapshot $arguments.StateRoot) -cne $before) { throw 'successful supersession replay wrote state' }
    foreach($operation in @('Reset-TeremoqLanUnconfirmedCandidate','Confirm-TeremoqLanClientSlot','Rollback-TeremoqLanClientSlot','Activate-TeremoqLanClientSlot')) {
        try { & $operation -StateRoot $arguments.StateRoot | Out-Null; throw 'legacy mutator accepted transition' }
        catch { if($_.Exception.Message -notmatch '^assisted unconfirmed transition exists') { throw } }
    }
    if((Get-FixturePreservationSnapshot $arguments.StateRoot) -cne $before) { throw 'blocked legacy mutator changed state' }
    $script:writes=0;$script:armed=$true
    [void](Invoke-TeremoqAssistedUnconfirmedTransition -Action Restore @arguments)
    $restoreWrites=$script:writes;$script:armed=$false
    Assert-PreservedFixture $fixture 'restored-unconfirmed'
    $before=Get-FixturePreservationSnapshot $arguments.StateRoot
    [void](Invoke-TeremoqAssistedUnconfirmedTransition -Action Restore @arguments)
    if((Get-FixturePreservationSnapshot $arguments.StateRoot) -cne $before) { throw 'restoration replay wrote state' }
    for($cutAt=1;$cutAt -le $applyWrites;$cutAt++) {
        $fixture=New-TransitionFixture ("apply-cut-$cutAt");$arguments=$fixture.Arguments
        $script:writes=0;$script:cut=$cutAt;$script:armed=$true
        try { Invoke-TeremoqAssistedUnconfirmedTransition -Action Supersede @arguments | Out-Null; throw 'cut not reached' }
        catch { if($_.Exception.Message -cne 'fixture cut AFTER a completed real durable write') { throw } }
        $script:armed=$false
        # Alternate explicit resume and restoration even during initial sealing.
        if($cutAt % 2 -eq 0) {
            [void](Invoke-TeremoqAssistedUnconfirmedTransition -Action Restore @arguments)
            Assert-PreservedFixture $fixture 'restored-unconfirmed'
        } else {
            [void](Invoke-TeremoqAssistedUnconfirmedTransition -Action Supersede @arguments)
            Assert-PreservedFixture $fixture 'pending-health'
        }
    }
    for($cutAt=1;$cutAt -le $restoreWrites;$cutAt++) {
        $fixture=New-TransitionFixture ("restore-cut-$cutAt");$arguments=$fixture.Arguments
        [void](Invoke-TeremoqAssistedUnconfirmedTransition -Action Supersede @arguments)
        $script:writes=0;$script:cut=$cutAt;$script:armed=$true
        try { Invoke-TeremoqAssistedUnconfirmedTransition -Action Restore @arguments | Out-Null; throw 'restore cut not reached' }
        catch { if($_.Exception.Message -cne 'fixture cut AFTER a completed real durable write') { throw } }
        $script:armed=$false
        [void](Invoke-TeremoqAssistedUnconfirmedTransition -Action Restore @arguments)
        Assert-PreservedFixture $fixture 'restored-unconfirmed'
    }
    $fixture=New-TransitionFixture 'conflict';$arguments=$fixture.Arguments
    [void](Invoke-TeremoqAssistedUnconfirmedTransition -Action Supersede @arguments)
    $overrides=$arguments.Clone();$overrides.TransitionId='00000000-0000-0000-0000-000000000000'
    $before=Get-FixturePreservationSnapshot $arguments.StateRoot
    try { Invoke-TeremoqAssistedUnconfirmedTransition -Action Restore @overrides | Out-Null;throw 'ID override accepted' }
    catch { if($_.Exception.Message -cne 'transition ID or source/target override rejected') { throw } }
    if((Get-FixturePreservationSnapshot $arguments.StateRoot) -cne $before) { throw 'ID conflict changed state' }
    $copy=Join-Path $arguments.StateRoot 'unconfirmed-transition\source-0.utf8'
    [IO.File]::WriteAllText($copy,'tampered',$utf8)
    $before=Get-FixturePreservationSnapshot $arguments.StateRoot
    try { Invoke-TeremoqAssistedUnconfirmedTransition -Action Restore @arguments | Out-Null;throw 'tampered snapshot accepted' }
    catch { if($_.Exception.Message -notmatch '^preserved transition material changed') { throw } }
    if((Get-FixturePreservationSnapshot $arguments.StateRoot) -cne $before) { throw 'tamper conflict mutated state' }
    $fixture=New-TransitionFixture 'binding-mismatch';$arguments=$fixture.Arguments
    $overrides=$arguments.Clone();$overrides.ExpectedSourceSha256='0'*64
    $before=Get-FixturePreservationSnapshot $arguments.StateRoot
    try {Invoke-TeremoqAssistedUnconfirmedTransition -Action Supersede @overrides | Out-Null;throw 'source hash override accepted'}
    catch {if($_.Exception.Message -notmatch '^transition pointer conflict'){throw}}
    if((Get-FixturePreservationSnapshot $arguments.StateRoot) -cne $before){throw 'source hash rejection mutated state'}
    [void](Invoke-TeremoqAssistedUnconfirmedTransition -Action Supersede @arguments)
    [IO.File]::WriteAllText((Join-Path $arguments.StateRoot 'control\rollback.json'),(ConvertTo-TeremoqLanSlotJson $fixture.Source),$utf8)
    $before=Get-FixturePreservationSnapshot $arguments.StateRoot
    try {Invoke-TeremoqAssistedUnconfirmedTransition -Action Restore @arguments | Out-Null;throw 'invented rollback accepted'}
    catch {if($_.Exception.Message -notmatch '^transition rollback must remain absent'){throw}}
    if((Get-FixturePreservationSnapshot $arguments.StateRoot) -cne $before){throw 'rollback conflict was repaired'}
    $fixture=New-TransitionFixture 'concurrency';$arguments=$fixture.Arguments
    $before=Get-FixturePreservationSnapshot $arguments.StateRoot
    $lock=[IO.File]::Open((Join-Path $arguments.StateRoot 'control\update.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        try { Invoke-TeremoqAssistedUnconfirmedTransition -Action Supersede @arguments | Out-Null;throw 'concurrent writer accepted' }
        catch { if($_.Exception.Message -ceq 'concurrent writer accepted') { throw } }
    } finally {$lock.Dispose()}
    if((Get-FixturePreservationSnapshot $arguments.StateRoot) -cne $before) { throw 'concurrent refusal mutated state' }
    foreach($crashAction in @('Supersede','Restore')) {
        $fixture=New-TransitionFixture ("crash-$crashAction");$arguments=$fixture.Arguments
        if($crashAction -ceq 'Restore') { [void](Invoke-TeremoqAssistedUnconfirmedTransition -Action Supersede @arguments) }
        $native=Invoke-TeremoqBoundedNativeProcess -FilePath (Get-Process -Id $PID).Path -WorkingDirectory $testRoot `
            -Arguments @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$PSCommandPath,
                '-CrashStateRoot',$arguments.StateRoot,'-CrashSourceSha256',$arguments.ExpectedSourceSha256,
                '-CrashTargetSha256',$arguments.ExpectedTargetSha256,'-CrashAction',$crashAction) `
            -TimeoutMilliseconds 30000 -StdoutMaxBytes 4096 -StderrMaxBytes 4096
        if($native.ExitCode -eq 0) { throw 'crash child incorrectly completed' }
        $phase=Read-TeremoqTransitionPhase -Directory (Join-Path $arguments.StateRoot 'unconfirmed-transition')
        $expectedPhase=if($crashAction -ceq 'Supersede'){'applying-candidate'}else{'restoring-active'}
        if($phase -cne $expectedPhase) { throw 'child failed before expected real replacement cut' }
        try { Get-TeremoqActiveLanClientSlot -StateRoot $arguments.StateRoot -ReadOnly | Out-Null;throw 'partial transition allowed selection' }
        catch { if($_.Exception.Message -notmatch '^assisted transition is incomplete') { throw } }
        [void](Invoke-TeremoqAssistedUnconfirmedTransition -Action Restore @arguments)
        Assert-PreservedFixture $fixture 'restored-unconfirmed'
    }
    Write-Output "assisted transition native PASS: apply write cuts=$applyWrites; restore write cuts=$restoreWrites; two terminated native children; preservation/replay/conflict/legacy guards/concurrency; no AV"
} finally {
    $script:armed=$false
    # Only this test's newly created synthetic tree, never real client state.
    if(Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
    if(Test-Path -LiteralPath $testRoot) { throw 'assisted fixture cleanup incomplete' }
}
