# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CheckoutRoot,
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [Parameter(Mandatory = $true)][string]$RepositoryUrl,
    [Parameter(Mandatory = $true)][string]$RepositoryRef,
    [Parameter(Mandatory = $true)][string]$ExpectedCommit,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$ServerIPv4,
    [Parameter(Mandatory = $true)][int]$PrefixLength,
    [Parameter(Mandatory = $true)][string]$Namespace,
    [Parameter(Mandatory = $true)][string]$FingerprintSha256,
    [switch]$RefreshDependencies,
    [switch]$Offline,
    [switch]$MaterialOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
# Reject an unselected host BEFORE loading helpers or touching any run state.
if ($PSVersionTable.PSEdition -cne 'Core' -or
    $PSVersionTable.PSVersion.ToString() -cne '7.6.6' -or
    [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
    [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() -cne 'X64') {
    throw 'LAN preparation requires the selected Windows x64 PowerShell Core 7.6.6 host'
}
$hostPath = Join-Path ([IO.Path]::GetFullPath($PSHOME)) 'pwsh.exe'
$hostProcess = [Diagnostics.Process]::GetCurrentProcess()
try {
    if (-not [string]::Equals([IO.Path]::GetFullPath($hostProcess.MainModule.FileName),
            $hostPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'LAN preparation host executable does not match selected PSHOME'
    }
} finally { $hostProcess.Dispose() }
$hostEntry = Get-Item -LiteralPath $hostPath -Force
if ($hostEntry.PSIsContainer -or ($hostEntry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'LAN preparation host must be a regular executable'
}
. (Join-Path $PSScriptRoot 'Client-Distribution.ps1')
. (Join-Path $PSScriptRoot 'Client-Slot-State.ps1')

function Assert-TeremoqPreparationPreservesInitialCandidate {
    param([Parameter(Mandatory = $true)][string]$StateRoot)

    # A read-only precondition, deliberately BEFORE layout initialization,
    # recovery, Git/bootstrap or the builder. This is not health confirmation.
    $layout = Get-TeremoqLanClientLayout -StateRoot $StateRoot
    if (-not (Test-Path -LiteralPath $layout.StateRoot)) { return }
    [void](Get-TeremoqNonReparseDirectoryPath -Path $layout.StateRoot)
    if (-not (Test-Path -LiteralPath $layout.ControlRoot)) { return }
    [void](Get-TeremoqNonReparseDirectoryPath -Path $layout.ControlRoot)
    $pins = New-Object 'Collections.Generic.List[IO.FileStream]'
    try {
        # Never create/open an operation lock for writing during this guard.
        # Existing files stay pinned while all three records are interpreted.
        foreach ($path in @((Join-Path $layout.ControlRoot 'update.lock'),
                $layout.ActivePointer, $layout.CandidatePointer, $layout.RollbackPointer)) {
            if (Test-Path -LiteralPath $path) {
                $pins.Add((Open-TeremoqVerifiedRegularFile -Path $path -MaxBytes 4096))
            }
        }
        $active = Read-TeremoqLanSlotPointer -Path $layout.ActivePointer -AllowMissing
        $candidate = Read-TeremoqLanSlotPointer -Path $layout.CandidatePointer -AllowMissing
        $rollback = Read-TeremoqLanSlotPointer -Path $layout.RollbackPointer -AllowMissing
        if ($null -ne $active -and $null -ne $candidate -and $null -eq $rollback -and
            $active.slot_id -ceq $candidate.slot_id) {
            throw 'LAN preparation blocked: initial candidate is unconfirmed and has no rollback; existing state and material must be preserved'
        }
    } finally {
        foreach ($pin in $pins) { $pin.Dispose() }
    }
}

function ConvertFrom-TeremoqWebBuilderReceipt {
    param([Parameter(Mandatory = $true)][string]$Output, [Parameter(Mandatory = $true)][string]$ExpectedCommit)
    if ($Output.Length -lt 2 -or $Output.Length -gt 131072) { throw 'Web builder output is outside the bounded receipt policy' }
    $jsonLines = @($Output -split "`r?`n" | Where-Object { $_.Length -le 8192 -and $_.StartsWith('{') -and $_.EndsWith('}') })
    if ($jsonLines.Count -ne 1) { throw 'Web Git builder did not emit exactly one closed JSON receipt' }
    try { $receipt = $jsonLines[0] | ConvertFrom-TeremoqLanJson } catch { throw 'Web Git builder receipt is not JSON' }
    $allowed = @(
        'schema_version','status','updater_version','player_identity','player_version','config_schema_version',
        'build_mode','source_commit','source_tree','package_lock_sha256','node_version','npm_version','platform',
        'architecture','dependency_status','previous_source_commit','source_diff_files','source_diff_sha256',
        'builds_executed','build_verification','manifest_sha256','launcher_contract_sha256',
        'artifact_inventory_sha256','player_relative_path'
    )
    $keys = @($receipt.PSObject.Properties.Name)
    $countIsInteger = $receipt.builds_executed -is [ValueType] -and $receipt.builds_executed -isnot [bool] -and
        [int]$receipt.builds_executed -eq $receipt.builds_executed
    $built = $receipt.status -ceq 'built' -and $countIsInteger -and [int]$receipt.builds_executed -eq 1 -and
        $receipt.build_verification -ceq 'single-build' -and
        $receipt.dependency_status -cin @('snapshot-created','snapshot-reused-verified')
    $reused = $receipt.status -ceq 'reused' -and $countIsInteger -and [int]$receipt.builds_executed -eq 0 -and
        $receipt.build_verification -cin @('reused-integration-double','reused-node-single') -and
        $receipt.dependency_status -ceq 'not-used'
    if ($keys.Count -ne $allowed.Count -or @($keys | Where-Object { $allowed -cnotcontains $_ }).Count -ne 0 -or
        $receipt.schema_version -ne 1 -or -not ($built -or $reused) -or
        $receipt.updater_version -cne (Get-TeremoqLanUpdaterVersion) -or
        $receipt.player_identity -cnotmatch '^sha256:[0-9a-f]{64}$' -or
        $receipt.player_version -cnotmatch '^[0-9]+[.][0-9]+[.][0-9]+(?:-[0-9A-Za-z.-]+)?$' -or
        $receipt.config_schema_version -ne 1 -or $receipt.build_mode -cne 'node' -or
        $receipt.source_commit -cne $ExpectedCommit -or $receipt.source_tree -cnotmatch '^[0-9a-f]{40}$' -or
        $receipt.package_lock_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $receipt.node_version -cnotmatch '^v22[.][0-9]+[.][0-9]+$' -or
        $receipt.npm_version -cnotmatch '^10[.][0-9]+[.][0-9]+$' -or
        $receipt.platform -cne 'win32' -or $receipt.architecture -cne 'x64' -or
        $receipt.previous_source_commit -cnotmatch '^(none|[0-9a-f]{40})$' -or
        $receipt.source_diff_files -is [bool] -or $receipt.source_diff_files -isnot [ValueType] -or
        [int]$receipt.source_diff_files -ne $receipt.source_diff_files -or
        [int]$receipt.source_diff_files -lt 0 -or [int]$receipt.source_diff_files -gt 4096 -or
        $receipt.source_diff_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $receipt.manifest_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $receipt.launcher_contract_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $receipt.artifact_inventory_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $receipt.player_identity -cne (Get-TeremoqLanPlayerIdentity -SourceTree $receipt.source_tree `
            -PackageLockSha256 $receipt.package_lock_sha256) -or
        $receipt.player_relative_path -cne ('players/' + $receipt.player_identity.Replace(':','-'))) {
        throw 'Web Git builder receipt is outside the node update policy'
    }
    return [pscustomobject]@{ Receipt = $receipt; CanonicalJson = $jsonLines[0] }
}

if (-not $MaterialOnly) { Assert-TeremoqPreparationPreservesInitialCandidate -StateRoot $StateRoot }
Assert-TeremoqNoAssistedTransition -StateRoot $StateRoot
$checkout = Get-TeremoqGitBootstrapCheckoutContext -CheckoutRoot $CheckoutRoot -RepositoryUrl $RepositoryUrl `
    -RepositoryRef $RepositoryRef -ExpectedCommit $ExpectedCommit -RepositorySubdirectory infra/lan
$state = [IO.Path]::GetFullPath($StateRoot)
$stateParent = Split-Path -Parent $state
[void](Get-TeremoqNonReparseDirectoryPath -Path $stateParent)
Assert-TeremoqRootsSeparated -CheckoutRoot $checkout.CheckoutRoot -StateRoot $state
$layout = Initialize-TeremoqLanClientLayout -StateRoot $state
if ($MaterialOnly) {
    if ($RunId -cnotmatch '^lan-[a-z0-9][a-z0-9-]{0,31}$') { throw 'material-only preparation requires a bounded run ID' }
    # Preserve the mutable Web build-state provenance before invoking builder.
    # This archive is never control state and is never automatically cleaned.
    $archiveParent = Join-Path $state 'material-preparation-evidence'
    New-TeremoqPrivateTransitionDirectory -Path $archiveParent
    $materialEvidence = Join-Path $archiveParent ($RunId + '-' + [Guid]::NewGuid().ToString('N'))
    New-TeremoqPrivateTransitionDirectory -Path $materialEvidence
    $buildState = Join-Path $state '.teremoq-web-build\update-state.json'
    if (Test-Path -LiteralPath $buildState) {
        $heldBuildState = Open-TeremoqVerifiedRegularFile -Path $buildState -MaxBytes 1048576
        try {
            Write-TeremoqTransitionCopy -Path (Join-Path $materialEvidence 'previous-build-state.json') `
                -Text (Read-TeremoqBoundedUtf8File -Path $buildState -MaxBytes 1048576)
        } finally { $heldBuildState.Dispose() }
    } else {
        Write-TeremoqTransitionCopy -Path (Join-Path $materialEvidence 'previous-build-state.absent') -Text "absent`n"
    }
} else {
    $candidateRecovery = Reset-TeremoqLanUnconfirmedCandidate -StateRoot $state
}
$builder = Assert-TeremoqNonReparseFilePath -Path (Join-Path $checkout.CheckoutRoot 'supervisor-web\lan-player\Build-LanPlayerFromGit.ps1')
$arguments = @(
    '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$builder,
    '-CheckoutRoot',$checkout.CheckoutRoot,'-StateRoot',$state,'-RepositoryUrl',$RepositoryUrl,
    '-RepositoryRef',$RepositoryRef,'-SourceCommit',$ExpectedCommit,'-BuildMode','node'
)
if ($RefreshDependencies) { $arguments += '-RefreshDependencies' }
if ($Offline) { $arguments += '-Offline' }
$result = Invoke-TeremoqBoundedNativeProcess -FilePath $hostPath -WorkingDirectory $checkout.CheckoutRoot `
    -Arguments $arguments -TimeoutMilliseconds 900000 -StdoutMaxBytes 131072 -StderrMaxBytes 131072
if ($result.ExitCode -ne 0) {
    [Console]::Error.WriteLine('Web Git builder bounded stdout:')
    [Console]::Error.WriteLine($result.Stdout)
    [Console]::Error.WriteLine('Web Git builder bounded stderr:')
    [Console]::Error.WriteLine($result.Stderr)
    throw 'Web Git builder failed; bounded diagnostics were emitted above'
}
$parsed = ConvertFrom-TeremoqWebBuilderReceipt -Output $result.Stdout -ExpectedCommit $ExpectedCommit
$receiptBytes = (New-Object Text.UTF8Encoding($false, $true)).GetBytes($parsed.CanonicalJson + "`n")
$sha = [Security.Cryptography.SHA256]::Create()
try { $receiptDigest = ([BitConverter]::ToString($sha.ComputeHash($receiptBytes)) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() }
$receiptPath = Join-Path $stateParent ('.teremoq-builder-receipt-' + [Guid]::NewGuid().ToString('N') + '.json')
$receiptStream = New-Object IO.FileStream($receiptPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $receiptStream.Write($receiptBytes, 0, $receiptBytes.Length); $receiptStream.Flush($true) } finally { $receiptStream.Dispose() }
try {
    $initialization = @{ CheckoutRoot=$checkout.CheckoutRoot; StateRoot=$state; RepositoryUrl=$RepositoryUrl;
        RepositoryRef=$RepositoryRef; ExpectedCommit=$ExpectedCommit; RepositorySubdirectory='infra/lan';
        RunId=$RunId; ServerIPv4=$ServerIPv4; PrefixLength=$PrefixLength; Namespace=$Namespace;
        FingerprintSha256=$FingerprintSha256; BuilderReceiptPath=$receiptPath; BuilderReceiptSha256=$receiptDigest }
    if ($MaterialOnly) {
        Write-TeremoqTransitionCopy -Path (Join-Path $materialEvidence 'builder-receipt.json') -Text ($parsed.CanonicalJson + "`n")
        $recordJson = & (Join-Path $PSScriptRoot 'Initialize-LanClientState.ps1') @initialization -MaterialOnly
        Write-TeremoqTransitionCopy -Path (Join-Path $materialEvidence 'target-record.json') -Text $recordJson
        $targetHash = Get-TeremoqTransitionTextHash -Text $recordJson
        [ordered]@{ status='material-only'; source_commit=$ExpectedCommit; target_record_sha256=$targetHash;
            evidence_id=(Split-Path -Leaf $materialEvidence); health='not_measured'; activation='not_performed' } | ConvertTo-Json -Compress
        return
    }
    & (Join-Path $PSScriptRoot 'Initialize-LanClientState.ps1') @initialization
    $activation = Activate-TeremoqLanClientSlot -StateRoot $state
    try {
        $active = Get-TeremoqLanStateContext -StateRoot $state
        if ($active.Compatibility.allowed_client_commit -cne $ExpectedCommit) {
            throw 'activated client state does not match the requested updater commit'
        }
        Assert-TeremoqLanLauncherStartContract -StateContext $active
    } catch {
        if ($activation.Status -ceq 'activated-pending-health') {
            try { [void](Rollback-TeremoqLanClientSlot -StateRoot $state) }
            catch { throw 'candidate validation failed and rollback did not complete' }
        }
        throw
    }
    Write-Output ("LAN client candidate activated pending health: updater={0}, player={1}, build={2}." -f `
        $ExpectedCommit.Substring(0, 8), $parsed.Receipt.player_identity, $parsed.Receipt.status)
    if ($candidateRecovery.Status -cne 'clean') {
        Write-Output ("Recovered prior unconfirmed LAN client state: {0}." -f $candidateRecovery.Status)
    }
} finally {
    if (Test-Path -LiteralPath $receiptPath) { Remove-Item -LiteralPath $receiptPath -Force -ErrorAction SilentlyContinue }
}
