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
    [switch]$Offline
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot 'Client-Distribution.ps1')

function ConvertFrom-TeremoqWebBuilderReceipt {
    param([Parameter(Mandatory = $true)][string]$Output, [Parameter(Mandatory = $true)][string]$ExpectedCommit)
    if ($Output.Length -lt 2 -or $Output.Length -gt 131072) { throw 'Web builder output is outside the bounded receipt policy' }
    $jsonLines = @($Output -split "`r?`n" | Where-Object { $_.Length -le 4096 -and $_.StartsWith('{') -and $_.EndsWith('}') })
    if ($jsonLines.Count -ne 1) { throw 'Web Git builder did not emit exactly one closed JSON receipt' }
    try { $receipt = $jsonLines[0] | ConvertFrom-Json } catch { throw 'Web Git builder receipt is not JSON' }
    $allowed = @('status','source_commit','source_tree','package_lock_sha256','dependency_mode','previous_source_commit','source_diff_files','source_diff_sha256','independent_builds','byte_identical','manifest_sha256','player_relative_path')
    $keys = @($receipt.PSObject.Properties.Name)
    if ($keys.Count -ne $allowed.Count -or @($keys | Where-Object { $allowed -notcontains $_ }).Count -ne 0 -or
        $receipt.status -cne 'built-from-clean-git-source' -or $receipt.source_commit -cne $ExpectedCommit -or
        $receipt.source_tree -cnotmatch '^[0-9a-f]{40}$' -or $receipt.package_lock_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $receipt.manifest_sha256 -cnotmatch '^[0-9a-f]{64}$' -or $receipt.player_relative_path -cne "players/$ExpectedCommit" -or
        $receipt.dependency_mode -cnotin @('initial-npm-ci','reused-lock-cache','explicit-lock-refresh') -or
        $receipt.previous_source_commit -isnot [string] -or $receipt.source_diff_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $receipt.source_diff_files -is [bool] -or $receipt.source_diff_files -isnot [ValueType] -or [int]$receipt.source_diff_files -lt 0 -or
        $receipt.independent_builds -is [bool] -or $receipt.independent_builds -isnot [ValueType] -or [int]$receipt.independent_builds -ne 2 -or
        $receipt.byte_identical -isnot [bool] -or -not $receipt.byte_identical) { throw 'Web Git builder receipt is outside policy' }
    return [pscustomobject]@{ Receipt = $receipt; CanonicalJson = $jsonLines[0] }
}

$checkout = Get-TeremoqGitBootstrapCheckoutContext -CheckoutRoot $CheckoutRoot -RepositoryUrl $RepositoryUrl -RepositoryRef $RepositoryRef -ExpectedCommit $ExpectedCommit -RepositorySubdirectory infra/lan
$state = [IO.Path]::GetFullPath($StateRoot)
$stateParent = Split-Path -Parent $state
if (Test-Path -LiteralPath $state) { throw 'StateRoot must be absent; prebuilt or partially built state is not accepted' }
[void](Get-TeremoqNonReparseDirectoryPath -Path $stateParent)
Assert-TeremoqRootsSeparated -CheckoutRoot $checkout.CheckoutRoot -StateRoot $state
$builder = Assert-TeremoqNonReparseFilePath -Path (Join-Path $checkout.CheckoutRoot 'supervisor-web\lan-player\Build-LanPlayerFromGit.ps1')
$hostPath = (Get-Process -Id $PID).Path
if (-not $hostPath -or -not $hostPath.EndsWith('powershell.exe', [StringComparison]::OrdinalIgnoreCase)) { throw 'the Windows PowerShell host is required to execute the reviewed Web builder' }
$arguments = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$builder,'-CheckoutRoot',$checkout.CheckoutRoot,'-StateRoot',$state,'-RepositoryUrl',$RepositoryUrl,'-RepositoryRef',$RepositoryRef,'-SourceCommit',$ExpectedCommit)
if ($RefreshDependencies) { $arguments += '-RefreshDependencies' }
if ($Offline) { $arguments += '-Offline' }
$result = Invoke-TeremoqBoundedNativeProcess -FilePath $hostPath -WorkingDirectory $checkout.CheckoutRoot -Arguments $arguments -TimeoutMilliseconds 60000 -StdoutMaxBytes 131072 -StderrMaxBytes 131072
if ($result.ExitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($result.Stderr)) { throw 'Web Git builder failed or emitted stderr' }
$parsed = ConvertFrom-TeremoqWebBuilderReceipt -Output $result.Stdout -ExpectedCommit $ExpectedCommit
if (-not (Test-Path -LiteralPath $state -PathType Container)) { throw 'Web Git builder did not create StateRoot' }
[void](Get-TeremoqNonReparseDirectoryPath -Path $state)
$receiptBytes = (New-Object Text.UTF8Encoding($false, $true)).GetBytes($parsed.CanonicalJson + "`n")
$sha = [Security.Cryptography.SHA256]::Create()
try { $receiptDigest = ([BitConverter]::ToString($sha.ComputeHash($receiptBytes)) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() }
$receiptPath = Join-Path $stateParent ('.teremoq-web-builder-receipt.' + [Guid]::NewGuid().ToString('N') + '.json')
try {
    $receiptStream = New-Object IO.FileStream($receiptPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $receiptStream.Write($receiptBytes, 0, $receiptBytes.Length); $receiptStream.Flush($true) } finally { $receiptStream.Dispose() }
    & (Join-Path $PSScriptRoot 'Initialize-LanClientState.ps1') -CheckoutRoot $checkout.CheckoutRoot -StateRoot $state -RepositoryUrl $RepositoryUrl -RepositoryRef $RepositoryRef -ExpectedCommit $ExpectedCommit -RepositorySubdirectory infra/lan -PlayerRelativePath $parsed.Receipt.player_relative_path -RunId $RunId -ServerIPv4 $ServerIPv4 -PrefixLength $PrefixLength -Namespace $Namespace -FingerprintSha256 $FingerprintSha256 -BuilderReceiptPath $receiptPath -BuilderReceiptSha256 $receiptDigest
} finally {
    if (Test-Path -LiteralPath $receiptPath) { Remove-Item -LiteralPath $receiptPath -Force -ErrorAction SilentlyContinue }
}
