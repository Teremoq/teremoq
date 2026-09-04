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
        -Arguments $Arguments -TimeoutMilliseconds 30000 -StdoutMaxBytes 131072 -StderrMaxBytes 131072
    if ($result.ExitCode -ne 0) { throw "Git fixture command failed: $($result.Stderr)" }
    return $result.Stdout.Trim()
}

function Assert-Rejected {
    param([Parameter(Mandatory = $true)][scriptblock]$Action, [Parameter(Mandatory = $true)][string]$Label)
    try { & $Action; throw "$Label was accepted" } catch { if ($_.Exception.Message -match [regex]::Escape("$Label was accepted")) { throw } }
}

function New-TestClientState {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Commit,
        [Parameter(Mandatory = $true)][string]$RepositoryRef
    )
    $utf8 = New-Object Text.UTF8Encoding($false)
    $player = Join-Path $Root ("players\{0}" -f $Commit)
    New-Item -ItemType Directory -Path (Join-Path $Root 'public-identity') -Force | Out-Null
    New-Item -ItemType Directory -Path $player -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $player 'start.mjs'), "// fixture`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $player 'Start-LanLoad.ps1'), "Write-Output 'fixture'`n", $utf8)
    $launcherSha = (Get-FileHash -LiteralPath (Join-Path $player 'Start-LanLoad.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
    $launcher = @(
        "schema_version`t1", "source_commit`t$Commit", "launcher_relative_path`tStart-LanLoad.ps1", "launcher_sha256`t$launcherSha",
        "actions`tstart,status,stop,collect", "levels`t1,5,10,25", "max_clients`t25",
        "network_contract`toutbound_udp_14433_only", "loopback_http_only`ttrue"
    ) -join "`n"
    [IO.File]::WriteAllText((Join-Path $player 'lan-launcher.tsv'), $launcher + "`n", $utf8)
    $manifest = [ordered]@{ schema_version = 1; artifact = 'teremoq-lan-lab-standalone'; package_version = 'git-e2e'; source_commit = $Commit; entrypoint = 'start.mjs'; files = @(); total_bytes = 0 }
    [IO.File]::WriteAllText((Join-Path $player 'MANIFEST.sha256.json'), ($manifest | ConvertTo-Json -Compress) + "`n", $utf8)
    $manifestSha = (Get-FileHash -LiteralPath (Join-Path $player 'MANIFEST.sha256.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    $launcherContractSha = (Get-FileHash -LiteralPath (Join-Path $player 'lan-launcher.tsv') -Algorithm SHA256).Hash.ToLowerInvariant()
    $fingerprint = 'a' * 64
    [IO.File]::WriteAllText((Join-Path $Root 'public-identity\relay-cert.sha256'), $fingerprint + "`n", $utf8)
    $config = [ordered]@{ schema_version = 1; run_id = 'lan-git-e2e'; source_commit = $Commit; relay_url = 'https://192.168.1.130:14433/watch'; fingerprint_sha256 = $fingerprint; prefix_length = 24; namespace = 'teremoq/live' }
    [IO.File]::WriteAllText((Join-Path $Root 'LAN-CONFIG.json'), ($config | ConvertTo-Json -Compress) + "`n", $utf8)
    $configSha = (Get-FileHash -LiteralPath (Join-Path $Root 'LAN-CONFIG.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    $compatibility = @(
        "schema_version`t1", "repository_url`thttps://github.com/Teremoq/teremoq", "repository_ref`t$RepositoryRef", "repository_subdirectory`tinfra/lan",
        "player_relative_path`tplayers/$Commit", "allowed_client_commit`t$Commit", "source_commit`t$Commit", "package_version`tgit-e2e",
        "client_protocol_version`tteremoq-lan-git-v2", "player_manifest_sha256`t$manifestSha", "launcher_contract_sha256`t$launcherContractSha", "lan_config_sha256`t$configSha"
    ) -join "`n"
    [IO.File]::WriteAllText((Join-Path $Root 'CLIENT-COMPATIBILITY.tsv'), $compatibility + "`n", $utf8)
    $version = @(
        "schema_version`t1", "package_version`tgit-e2e", "run_id`tlan-git-e2e", "source_commit`t$Commit", "server_ipv4`t192.168.1.130",
        "moq_url`thttps://192.168.1.130:14433/watch", "player_manifest_sha256`t$manifestSha", "launcher_contract_sha256`t$launcherContractSha",
        "lan_config_sha256`t$configSha", "player_evidence`tnot_measured", "load_launcher_status`tready"
    ) -join "`n"
    [IO.File]::WriteAllText((Join-Path $Root 'VERSION.tsv'), $version + "`n", $utf8)
    $lines = Get-ChildItem -LiteralPath $Root -Recurse -Force -File | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($Root.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
        "{0}  {1}" -f ((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()), $relative
    }
    [IO.File]::WriteAllText((Join-Path $Root 'SHA256SUMS'), ($lines -join "`n") + "`n", $utf8)
}

$GitExecutable = [IO.Path]::GetFullPath($GitExecutable)
if (-not (Test-Path -LiteralPath $GitExecutable -PathType Leaf)) { throw 'Git for Windows fixture executable is missing' }
$env:Path = (Split-Path -Parent $GitExecutable) + ';' + $env:Path
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('teremoq-git-e2e-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
try {
    $bare = Join-Path $scratch 'origin.git'
    $seed = Join-Path $scratch 'seed'
    $checkout = Join-Path $scratch 'checkout'
    $state = Join-Path $scratch 'state-current'
    $branch = 'lan-e2e'
    $repositoryRef = "refs/heads/$branch"
    Invoke-TestGit -WorkingDirectory $scratch -Arguments @('init', '--bare', '--initial-branch', $branch, $bare) | Out-Null
    Invoke-TestGit -WorkingDirectory $scratch -Arguments @('clone', $bare, $seed) | Out-Null
    Invoke-TestGit -WorkingDirectory $seed -Arguments @('config', 'user.name', 'Teremoq test') | Out-Null
    Invoke-TestGit -WorkingDirectory $seed -Arguments @('config', 'user.email', 'test@example.invalid') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $seed 'infra') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $source 'infra\lan') -Destination (Join-Path $seed 'infra\lan') -Recurse
    [IO.File]::WriteAllText((Join-Path $seed 'git-e2e-marker.txt'), "one`n", (New-Object Text.UTF8Encoding($false)))
    Invoke-TestGit -WorkingDirectory $seed -Arguments @('add', '.') | Out-Null
    Invoke-TestGit -WorkingDirectory $seed -Arguments @('commit', '-m', 'first') | Out-Null
    Invoke-TestGit -WorkingDirectory $seed -Arguments @('push', 'origin', $branch) | Out-Null
    $first = Invoke-TestGit -WorkingDirectory $seed -Arguments @('rev-parse', 'HEAD')

    $bareUrl = 'file:///' + ($bare.Replace('\','/'))
    $env:GIT_CONFIG_COUNT = '1'
    $env:GIT_CONFIG_KEY_0 = "url.$bareUrl.insteadOf"
    $env:GIT_CONFIG_VALUE_0 = 'https://github.com/Teremoq/teremoq'
    & (Join-Path $source 'infra\lan\client\Install-LanClient.ps1') -CheckoutRoot $checkout `
        -RepositoryUrl 'https://github.com/Teremoq/teremoq' -RepositoryRef $repositoryRef -ExpectedCommit $first -RepositorySubdirectory 'infra/lan'
    New-TestClientState -Root $state -Commit $first -RepositoryRef $repositoryRef
    & (Join-Path $checkout 'infra\lan\client\Update-LanClient.ps1') -CheckoutRoot $checkout -StateRoot $state -ExpectedCommit $first
    $stateBefore = (Get-FileHash -LiteralPath (Join-Path $state 'SHA256SUMS') -Algorithm SHA256).Hash

    [IO.File]::AppendAllText((Join-Path $seed 'git-e2e-marker.txt'), "two`n", (New-Object Text.UTF8Encoding($false)))
    Invoke-TestGit -WorkingDirectory $seed -Arguments @('commit', '-am', 'second') | Out-Null
    Invoke-TestGit -WorkingDirectory $seed -Arguments @('push', 'origin', $branch) | Out-Null
    $second = Invoke-TestGit -WorkingDirectory $seed -Arguments @('rev-parse', 'HEAD')
    . (Join-Path $checkout 'infra\lan\client\Client-Distribution.ps1')
    [void](Invoke-TeremoqGitFastForwardUpdate -CheckoutRoot $checkout -RepositoryUrl 'https://github.com/Teremoq/teremoq' `
        -RepositoryRef $repositoryRef -RepositorySubdirectory 'infra/lan' -CurrentCommit $first -ExpectedCommit $second)
    if ((Invoke-TestGit -WorkingDirectory $checkout -Arguments @('rev-parse', 'HEAD')) -cne $second) { throw 'ff-only update did not reach the approved commit' }
    if ((Get-FileHash -LiteralPath (Join-Path $state 'SHA256SUMS') -Algorithm SHA256).Hash -cne $stateBefore) { throw 'external client state changed during Git update' }

    [IO.File]::WriteAllText((Join-Path $checkout 'untracked.txt'), 'dirty', (New-Object Text.UTF8Encoding($false)))
    Assert-Rejected -Label 'dirty checkout' -Action { Invoke-TeremoqGitFastForwardUpdate -CheckoutRoot $checkout -RepositoryUrl 'https://github.com/Teremoq/teremoq' -RepositoryRef $repositoryRef -RepositorySubdirectory 'infra/lan' -CurrentCommit $second -ExpectedCommit $second | Out-Null }
    Remove-Item -LiteralPath (Join-Path $checkout 'untracked.txt') -Force
    Invoke-TestGit -WorkingDirectory $checkout -Arguments @('remote', 'set-url', 'origin', 'file:///unexpected') | Out-Null
    Assert-Rejected -Label 'remote drift' -Action { Invoke-TeremoqGitFastForwardUpdate -CheckoutRoot $checkout -RepositoryUrl 'https://github.com/Teremoq/teremoq' -RepositoryRef $repositoryRef -RepositorySubdirectory 'infra/lan' -CurrentCommit $second -ExpectedCommit $second | Out-Null }
    Invoke-TestGit -WorkingDirectory $checkout -Arguments @('remote', 'set-url', 'origin', 'https://github.com/Teremoq/teremoq') | Out-Null
    Assert-Rejected -Label 'ref drift' -Action { Invoke-TeremoqGitFastForwardUpdate -CheckoutRoot $checkout -RepositoryUrl 'https://github.com/Teremoq/teremoq' -RepositoryRef 'refs/heads/other' -RepositorySubdirectory 'infra/lan' -CurrentCommit $second -ExpectedCommit $second | Out-Null }
    Assert-Rejected -Label 'commit mismatch' -Action { Invoke-TeremoqGitFastForwardUpdate -CheckoutRoot $checkout -RepositoryUrl 'https://github.com/Teremoq/teremoq' -RepositoryRef $repositoryRef -RepositorySubdirectory 'infra/lan' -CurrentCommit $second -ExpectedCommit ('0' * 40) | Out-Null }

    Invoke-TestGit -WorkingDirectory $checkout -Arguments @('config', 'user.name', 'Teremoq test') | Out-Null
    Invoke-TestGit -WorkingDirectory $checkout -Arguments @('config', 'user.email', 'test@example.invalid') | Out-Null
    [IO.File]::AppendAllText((Join-Path $checkout 'git-e2e-marker.txt'), "local`n", (New-Object Text.UTF8Encoding($false)))
    Invoke-TestGit -WorkingDirectory $checkout -Arguments @('commit', '-am', 'local divergence') | Out-Null
    $localCommit = Invoke-TestGit -WorkingDirectory $checkout -Arguments @('rev-parse', 'HEAD')
    [IO.File]::AppendAllText((Join-Path $seed 'git-e2e-marker.txt'), "remote`n", (New-Object Text.UTF8Encoding($false)))
    Invoke-TestGit -WorkingDirectory $seed -Arguments @('commit', '-am', 'remote divergence') | Out-Null
    Invoke-TestGit -WorkingDirectory $seed -Arguments @('push', 'origin', $branch) | Out-Null
    $remoteCommit = Invoke-TestGit -WorkingDirectory $seed -Arguments @('rev-parse', 'HEAD')
    Assert-Rejected -Label 'divergent update' -Action { Invoke-TeremoqGitFastForwardUpdate -CheckoutRoot $checkout -RepositoryUrl 'https://github.com/Teremoq/teremoq' -RepositoryRef $repositoryRef -RepositorySubdirectory 'infra/lan' -CurrentCommit $localCommit -ExpectedCommit $remoteCommit | Out-Null }
    Write-Output 'lan-git-client-e2e: PASS (native install/no-op/ff-only, preserved state and safety rejections)'
} finally {
    Remove-Item Env:GIT_CONFIG_COUNT -ErrorAction SilentlyContinue
    Remove-Item Env:GIT_CONFIG_KEY_0 -ErrorAction SilentlyContinue
    Remove-Item Env:GIT_CONFIG_VALUE_0 -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
