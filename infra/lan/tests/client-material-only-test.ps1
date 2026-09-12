# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
# Component composition: real Prepare/Initialize/state code, synthetic Git and
# builder receipt. This is NOT a real Web build or an audiovisual receipt.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot '..\client\Client-Distribution.ps1')
. (Join-Path $PSScriptRoot '..\client\Client-Slot-State.ps1')
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('teremoq-material-fixture-'+[Guid]::NewGuid().ToString('N'))
$utf8=New-Object Text.UTF8Encoding($false)
try {
    $checkout=Join-Path $temporary 'checkout';$state=Join-Path $temporary 'state';$client=Join-Path $checkout 'infra\lan\client'
    [void][IO.Directory]::CreateDirectory($client)
    [void][IO.Directory]::CreateDirectory((Join-Path $checkout 'supervisor-web\lan-player'))
    [IO.File]::WriteAllText((Join-Path $checkout 'supervisor-web\lan-player\Build-LanPlayerFromGit.ps1'),'# fixture; never executed',$utf8)
    [IO.File]::WriteAllText((Join-Path $checkout 'supervisor-web\package-lock.json'),"fixture-lock`n",$utf8)
    foreach($name in @('Prepare-LanClientFromGit.ps1','Initialize-LanClientState.ps1','Client-Slot-State.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot ("..\client\$name")) -Destination (Join-Path $client $name)
    }
    $layout=Initialize-TeremoqLanClientLayout $state
    [void][IO.Directory]::CreateDirectory((Join-Path $layout.ConfigRoot 'public-identity'))
    $pin='a'*64
    $configuration=[pscustomobject][ordered]@{schema_version=1;run_id='lan-fixture';relay_url='https://192.168.254.2:14433/watch';fingerprint_sha256=$pin;prefix_length=24;namespace='teremoq/live'}
    [IO.File]::WriteAllText((Join-Path $layout.ConfigRoot 'LAN-CONFIG.json'),(($configuration|ConvertTo-Json -Compress)+"`n"),$utf8)
    [IO.File]::WriteAllText((Join-Path $layout.ConfigRoot 'public-identity\relay-cert.sha256'),($pin+"`n"),$utf8)
    $configHash=Get-TeremoqBoundedFileSha256 (Join-Path $layout.ConfigRoot 'LAN-CONFIG.json') 4096
    $lockHash=Get-TeremoqBoundedFileSha256 (Join-Path $checkout 'supervisor-web\package-lock.json') 1048576
    $sourceTree='5'*40;$targetCommit='4'*40
    $identity=Get-TeremoqLanPlayerIdentity $sourceTree $lockHash
    $player=Join-Path $layout.PlayersRoot $identity.Replace(':','-')
    [void][IO.Directory]::CreateDirectory($player)
    [IO.File]::WriteAllText((Join-Path $player 'start.mjs'),'// synthetic unexecuted file',$utf8)
    [IO.File]::WriteAllText((Join-Path $player 'lan-launcher.tsv'),"fixture-only`n",$utf8)
    $manifest=[ordered]@{schema_version=1;artifact='teremoq-lan-lab-standalone';entrypoint='start.mjs';package_version='0.1.0';updater_version='2.0.0';player_identity=$identity;player_version='0.1.0';config_schema_version=1;files=@();total_bytes=0}
    [IO.File]::WriteAllText((Join-Path $player 'MANIFEST.sha256.json'),($manifest|ConvertTo-Json -Compress),$utf8)
    $manifestHash=Get-TeremoqBoundedFileSha256 (Join-Path $player 'MANIFEST.sha256.json') 1048576
    $launcherHash=Get-TeremoqBoundedFileSha256 (Join-Path $player 'lan-launcher.tsv') 4096
    $source=New-TeremoqLanSlotRecord -UpdaterCommit ('1'*40) -PlayerIdentity $identity -SourceTree $sourceTree -PackageLockSha256 $lockHash `
        -PlayerManifestSha256 $manifestHash -LauncherContractSha256 $launcherHash -ConfigSha256 $configHash
    $oldVersion=Join-Path $state $source.version_relative_path
    [void][IO.Directory]::CreateDirectory($oldVersion)
    foreach($name in @('VERSION.tsv','CLIENT-COMPATIBILITY.tsv','SHA256SUMS')) {[IO.File]::WriteAllText((Join-Path $oldVersion $name),'old immutable fixture',$utf8)}
    [void](Stage-TeremoqLanClientSlot -StateRoot $state -Record $source)
    [void](Activate-TeremoqLanClientSlot -StateRoot $state)
    $activeBefore=Read-TeremoqBoundedUtf8File $layout.ActivePointer 4096
    $candidateBefore=Read-TeremoqBoundedUtf8File $layout.CandidatePointer 4096
    $buildRoot=Join-Path $state '.teremoq-web-build';[void][IO.Directory]::CreateDirectory($buildRoot)
    [IO.File]::WriteAllText((Join-Path $buildRoot 'update-state.json'),"{`"previous`":true}`n",$utf8)
    $receipt=[ordered]@{schema_version=1;status='reused';updater_version='2.0.0';player_identity=$identity;player_version='0.1.0';config_schema_version=1;build_mode='node';source_commit=$targetCommit;source_tree=$sourceTree;package_lock_sha256=$lockHash;node_version='v22.23.2';npm_version='10.9.8';platform='win32';architecture='x64';dependency_status='not-used';previous_source_commit='none';source_diff_files=0;source_diff_sha256=('0'*64);builds_executed=0;build_verification='reused-node-single';manifest_sha256=$manifestHash;launcher_contract_sha256=$launcherHash;artifact_inventory_sha256=('0'*64);player_relative_path=('players/'+$identity.Replace(':','-'))}
    $receiptBase64=[Convert]::ToBase64String($utf8.GetBytes(($receipt|ConvertTo-Json -Compress)))
    $distribution=(Join-Path $PSScriptRoot '..\client\Client-Distribution.ps1').Replace("'","''")
    $stub=@'
. '__DISTRIBUTION__'
function Get-TeremoqGitBootstrapCheckoutContext {
    param($CheckoutRoot,$RepositoryUrl,$RepositoryRef,$ExpectedCommit,$RepositorySubdirectory)
    return [pscustomobject]@{CheckoutRoot=$CheckoutRoot;Head=$ExpectedCommit}
}
function Invoke-TeremoqGit { param($CheckoutRoot,$Arguments) if($Arguments[0] -cne 'rev-parse'){throw 'unexpected fixture Git call'};return ('5'*40) }
function Invoke-TeremoqBoundedNativeProcess {
    param($FilePath,$WorkingDirectory,$Arguments,$TimeoutMilliseconds,$StdoutMaxBytes,$StderrMaxBytes)
    if($Arguments -cnotcontains 'node' -or $Arguments -cnotcontains '-BuildMode'){throw 'material fixture expected node build mode'}
    $receipt=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__RECEIPT__'))
    return [pscustomobject]@{ExitCode=0;Stdout=$receipt;Stderr=''}
}
'@
    $stub=$stub.Replace('__DISTRIBUTION__',$distribution).Replace('__RECEIPT__',$receiptBase64)
    [IO.File]::WriteAllText((Join-Path $client 'Client-Distribution.ps1'),$stub,$utf8)
    $result=& (Join-Path $client 'Prepare-LanClientFromGit.ps1') -CheckoutRoot $checkout -StateRoot $state `
        -RepositoryUrl 'https://github.com/Teremoq/teremoq' -RepositoryRef 'refs/heads/codex/lan-e2e-integration' `
        -ExpectedCommit $targetCommit -RunId 'lan-fixture' -ServerIPv4 '192.168.254.2' -PrefixLength 24 -Namespace 'teremoq/live' `
        -FingerprintSha256 $pin -MaterialOnly -Offline
    $summary=$result|ConvertFrom-Json
    if($summary.status -cne 'material-only' -or $summary.activation -cne 'not_performed'){throw 'material result claimed activation'}
    if((Read-TeremoqBoundedUtf8File $layout.ActivePointer 4096) -cne $activeBefore -or
        (Read-TeremoqBoundedUtf8File $layout.CandidatePointer 4096) -cne $candidateBefore -or
        (Test-Path -LiteralPath $layout.RollbackPointer)){throw 'material-only preparation mutated old pointers'}
    foreach($name in @('VERSION.tsv','CLIENT-COMPATIBILITY.tsv','SHA256SUMS')) {
        if((Read-TeremoqBoundedUtf8File (Join-Path $oldVersion $name) 4096) -cne 'old immutable fixture'){throw 'old version changed'}
    }
    if((Get-TeremoqBoundedFileSha256 (Join-Path $layout.ConfigRoot 'LAN-CONFIG.json') 4096) -cne $configHash){throw 'old config changed'}
    $archive=Join-Path (Join-Path $state 'material-preparation-evidence') $summary.evidence_id
    if((Read-TeremoqBoundedUtf8File (Join-Path $archive 'previous-build-state.json') 4096) -cne "{`"previous`":true}`n"){throw 'builder provenance was not preserved'}
    if((Get-TeremoqBoundedFileSha256 (Join-Path $archive 'target-record.json') 4096) -cne $summary.target_record_sha256){throw 'material target record hash mismatch'}
    [void](Read-TeremoqLanSlotPointer (Join-Path $archive 'target-record.json'))
    Write-Output 'material-only native component composition PASS: real Prepare/Initialize; synthetic Git/builder; no pointer changes, prior metadata/config preserved, immutable target and receipt retained; not real build/AV'
} finally {
    if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Recurse -Force}
    if(Test-Path -LiteralPath $temporary){throw 'material fixture cleanup incomplete'}
}
