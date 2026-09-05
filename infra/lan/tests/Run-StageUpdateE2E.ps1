# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceRoot,
    [Parameter(Mandatory = $true)][string]$GitExecutable
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$source = [IO.Path]::GetFullPath($SourceRoot)
. (Join-Path $source 'infra\lan\client\Client-Distribution.ps1')

function Invoke-TestGit {
    param([Parameter(Mandatory = $true)][string]$WorkingDirectory, [Parameter(Mandatory = $true)][string[]]$Arguments)
    $result = Invoke-TeremoqBoundedNativeProcess -FilePath $GitExecutable -WorkingDirectory $WorkingDirectory `
        -Arguments (@('-c','core.autocrlf=false','-c','core.eol=lf') + $Arguments) `
        -TimeoutMilliseconds 30000 -StdoutMaxBytes 131072 -StderrMaxBytes 131072
    if ($result.ExitCode -ne 0) { throw 'Git stage fixture command failed' }
    return $result.Stdout.Trim()
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('teremoq-stage-e2e-' + [Guid]::NewGuid().ToString('N'))
$oldLocalAppData = $env:LOCALAPPDATA
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
try {
    $env:LOCALAPPDATA = Join-Path $scratch 'profile'
    $clientRoot = Join-Path $env:LOCALAPPDATA 'Teremoq'
    New-Item -ItemType Directory -Path $clientRoot -Force | Out-Null
    $bare = Join-Path $scratch 'origin.git'
    $seed = Join-Path $scratch 'seed'
    $branch = 'codex/lan-e2e-integration'
    $repositoryRef = "refs/heads/$branch"
    Invoke-TestGit $scratch @('init','--bare','--initial-branch',$branch,$bare) | Out-Null
    Invoke-TestGit $scratch @('clone',$bare,$seed) | Out-Null
    Invoke-TestGit $seed @('config','user.name','Teremoq test') | Out-Null
    Invoke-TestGit $seed @('config','user.email','test@example.invalid') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $seed 'infra') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $source 'infra\lan') -Destination (Join-Path $seed 'infra\lan') -Recurse
    New-Item -ItemType Directory -Path (Join-Path $seed 'supervisor-web') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $source '.gitattributes') -Destination (Join-Path $seed '.gitattributes')
    Copy-Item -LiteralPath (Join-Path $source 'supervisor-web\package.json') -Destination (Join-Path $seed 'supervisor-web\package.json')
    Copy-Item -LiteralPath (Join-Path $source 'supervisor-web\package-lock.json') -Destination (Join-Path $seed 'supervisor-web\package-lock.json')
    [IO.File]::WriteAllText((Join-Path $seed 'update-marker.txt'), "one`n", (New-Object Text.UTF8Encoding($false)))
    Invoke-TestGit $seed @('add','.') | Out-Null
    Invoke-TestGit $seed @('commit','-m','first') | Out-Null
    Invoke-TestGit $seed @('push','origin',$branch) | Out-Null
    $first = Invoke-TestGit $seed @('rev-parse','HEAD')

    $bareUrl = 'file:///' + ($bare.Replace('\','/'))
    $env:GIT_CONFIG_COUNT = '1'
    $env:GIT_CONFIG_KEY_0 = "url.$bareUrl.insteadOf"
    $env:GIT_CONFIG_VALUE_0 = 'https://github.com/Teremoq/teremoq'
    $current = Join-Path $clientRoot ("checkout-lan-{0}" -f $first.Substring(0, 8))
    & (Join-Path $source 'infra\lan\client\Install-LanClient.ps1') -CheckoutRoot $current `
        -RepositoryUrl 'https://github.com/Teremoq/teremoq' -RepositoryRef $repositoryRef `
        -ExpectedCommit $first -RepositorySubdirectory 'infra/lan'
    [IO.File]::WriteAllText((Join-Path $clientRoot 'local-config-preserved.txt'), 'local', (New-Object Text.UTF8Encoding($false)))

    [IO.File]::AppendAllText((Join-Path $seed 'update-marker.txt'), "two`n", (New-Object Text.UTF8Encoding($false)))
    Invoke-TestGit $seed @('commit','-am','second') | Out-Null
    Invoke-TestGit $seed @('push','origin',$branch) | Out-Null
    $second = Invoke-TestGit $seed @('rev-parse','HEAD')
    $dirtyMarker = Join-Path $current 'local-untracked.txt'
    [IO.File]::WriteAllText($dirtyMarker, 'must reject', (New-Object Text.UTF8Encoding($false)))
    $dirtyRejected = $false
    try {
        & (Join-Path $current 'infra\lan\client\Stage-LanClientUpdate.ps1') -CheckoutRoot $current `
            -CurrentCommit $first -TargetCommit $second -RepositoryUrl 'https://github.com/Teremoq/teremoq' `
            -RepositoryRef $repositoryRef
    } catch { $dirtyRejected = $true }
    Remove-Item -LiteralPath $dirtyMarker -Force
    if (-not $dirtyRejected) { throw 'dirty source checkout was accepted for staged update' }
    & (Join-Path $current 'infra\lan\client\Stage-LanClientUpdate.ps1') -CheckoutRoot $current `
        -CurrentCommit $first -TargetCommit $second -RepositoryUrl 'https://github.com/Teremoq/teremoq' `
        -RepositoryRef $repositoryRef
    $target = Join-Path $clientRoot ("checkout-lan-{0}" -f $second.Substring(0, 8))
    if ((Invoke-TestGit $current @('rev-parse','HEAD')) -cne $first) { throw 'current checkout changed during staged update' }
    if ((Invoke-TestGit $target @('rev-parse','HEAD')) -cne $second) { throw 'staged checkout differs from target commit' }
    if (-not (Test-Path -LiteralPath (Join-Path $clientRoot 'local-config-preserved.txt') -PathType Leaf)) { throw 'local client configuration was overwritten' }
    if ((Invoke-TestGit $target @('status','--porcelain=v1','--untracked-files=all')) -ne '') { throw 'staged checkout is not clean' }
    $downgradeRejected = $false
    try {
        & (Join-Path $target 'infra\lan\client\Stage-LanClientUpdate.ps1') -CheckoutRoot $target `
            -CurrentCommit $second -TargetCommit $first -RepositoryUrl 'https://github.com/Teremoq/teremoq' `
            -RepositoryRef $repositoryRef
    } catch { $downgradeRejected = $true }
    if (-not $downgradeRejected) { throw 'non-fast-forward downgrade was accepted for staged update' }
    Write-Output 'lan-stage-update-e2e: PASS (side-by-side exact commit and preserved local state)'
} finally {
    $env:LOCALAPPDATA = $oldLocalAppData
    Remove-Item Env:GIT_CONFIG_COUNT -ErrorAction SilentlyContinue
    Remove-Item Env:GIT_CONFIG_KEY_0 -ErrorAction SilentlyContinue
    Remove-Item Env:GIT_CONFIG_VALUE_0 -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
