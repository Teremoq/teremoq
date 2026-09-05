# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$launcher = Join-Path $PSScriptRoot '..\client\Start-LanInteractiveClient.ps1'
$zeroCommit = '0' * 40
$zeroHash = '0' * 64
. $launcher -ExpectedCommit $zeroCommit

$root = Join-Path ([IO.Path]::GetTempPath()) ('teremoq-interactive-lock-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $source = Join-Path $root 'source'
    New-Item -ItemType Directory -Path $source | Out-Null
    $entrypoint = Join-Path $source 'entrypoint.mjs'
    $replacement = Join-Path $root 'replacement.mjs'
    [IO.File]::WriteAllText($entrypoint, 'reviewed bytes', (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($replacement, 'substituted bytes', (New-Object Text.UTF8Encoding($false)))
    $expected = (Get-FileHash -LiteralPath $entrypoint -Algorithm SHA256).Hash.ToLowerInvariant()
    $hashRejected = $false
    try { Open-TeremoqPinnedFile -Path $entrypoint -ExpectedSha256 ('0' * 64) | Out-Null }
    catch { $hashRejected = $true }
    if (-not $hashRejected) { throw 'Unapproved entrypoint hash was accepted' }
    $pin = Open-TeremoqPinnedFile -Path $entrypoint -ExpectedSha256 $expected `
        -ExpectedBlobId '015e494e9ad2856ee83a283fb6dd24307b83fc29'
    try {
        $writeRejected = $false
        try { [IO.File]::WriteAllText($entrypoint, 'mutated') } catch { $writeRejected = $true }
        if (-not $writeRejected) { throw 'Pinned entrypoint remained writable' }
        $replaceRejected = $false
        try { Move-Item -LiteralPath $replacement -Destination $entrypoint -Force } catch { $replaceRejected = $true }
        if (-not $replaceRejected) { throw 'Pinned entrypoint remained replaceable' }
        $parentSwapRejected = $false
        try { Move-Item -LiteralPath $source -Destination (Join-Path $root 'moved-source') } catch { $parentSwapRejected = $true }
        if (-not $parentSwapRejected) { throw 'Pinned entrypoint parent remained replaceable' }
        if ((Get-TeremoqStreamSha256 $pin.Stream) -cne $expected) { throw 'Pinned handle bytes changed' }
    } finally { $pin.Stream.Dispose() }
    Move-Item -LiteralPath $replacement -Destination $entrypoint -Force
    if ([IO.File]::ReadAllText($entrypoint) -cne 'substituted bytes') { throw 'Canary did not exercise replacement after unlock' }
    $unprotectedExecutable = Join-Path $root 'user-owned.exe'
    [IO.File]::WriteAllText($unprotectedExecutable, 'not an approved executable')
    $aclRejected = $false
    try { Get-TeremoqProtectedExecutableSha256 -Path $unprotectedExecutable | Out-Null }
    catch { $aclRejected = $true }
    if (-not $aclRejected) { throw 'User-owned executable ACL was accepted' }
    $nodePath = 'C:\Program Files\nodejs\node.exe'
    $nodeHash = Get-TeremoqProtectedExecutableSha256 -Path $nodePath
    $executableHashRejected = $false
    try {
        Invoke-TeremoqPinnedNodeProcess -FilePath $nodePath -ExpectedSha256 $zeroHash `
            -Arguments @('-e','process.exit(0)') -WorkingDirectory $root | Out-Null
    }
    catch { $executableHashRejected = $true }
    if (-not $executableHashRejected) { throw 'Unapproved executable hash was accepted' }
    $nodeExit = Invoke-TeremoqPinnedNodeProcess -FilePath $nodePath `
        -ExpectedSha256 $nodeHash `
        -Arguments @('-e','process.exit(process.versions.node.startsWith("22.") ? 0 : 9)') `
        -WorkingDirectory $root
    if ($nodeExit -ne 0) { throw 'Approved Node executable did not start' }

    $safeStatus = '[Teremoq] Paso 1 - Preparar y verificar el cliente: en ejecucion'
    if ((Get-TeremoqSafeAgentOutput -Line $safeStatus) -cne $safeStatus) {
        throw 'Fixed local client progress was not relayed'
    }
    if ($null -ne (Get-TeremoqSafeAgentOutput -Line '[Teremoq] Paso 1 - C:\secret: en ejecucion') -or
        $null -ne (Get-TeremoqSafeAgentOutput -Line '[Teremoq] Paso 1 - Preparar y verificar el cliente: token=secret')) {
        throw 'Arbitrary agent output was relayed to the client console'
    }

    $argvCanary = Join-Path $root 'argv-canary.mjs'
    $argvCanarySource = @'
const argv = process.argv.slice(2);
const required = new Set(["--server","--fingerprint","--run-id","--source-commit","--pairing-stdin","--checkout","--state-root","--evidence-root","--git-sha256","--node-sha256","--npm-cli-sha256","--powershell-sha256","--taskkill-sha256"]);
if (argv.length !== 26) process.exit(20);
for (let index = 0; index < argv.length; index += 2) {
  if (!required.delete(argv[index]) || !argv[index + 1]) process.exit(21);
}
if (required.size !== 0) process.exit(22);
'@
    [IO.File]::WriteAllText($argvCanary, $argvCanarySource, (New-Object Text.UTF8Encoding($false)))
    $sessionHashes = @{ Git=$zeroHash; Node=$nodeHash; NpmCli=$zeroHash; PowerShell=$zeroHash; Taskkill=$zeroHash }
    $agentArguments = New-TeremoqAgentArguments -AgentPath $argvCanary -RunId 'lan-argv-canary' `
        -Commit $zeroCommit -Checkout $root -StateRoot $root -EvidenceRoot $root `
        -SessionHashes $sessionHashes
    $argumentMap = @{}
    for ($index = 1; $index -lt $agentArguments.Count; $index += 2) {
        if ($argumentMap.ContainsKey($agentArguments[$index])) { throw 'Real launcher duplicated an agent argument' }
        $argumentMap[$agentArguments[$index]] = $agentArguments[$index + 1]
    }
    if ($agentArguments.Count -ne 27 -or $argumentMap.Count -ne 13 -or
        $argumentMap['--git-sha256'] -cne $sessionHashes.Git -or
        $argumentMap['--node-sha256'] -cne $sessionHashes.Node -or
        $argumentMap['--npm-cli-sha256'] -cne $sessionHashes.NpmCli -or
        $argumentMap['--powershell-sha256'] -cne $sessionHashes.PowerShell -or
        $argumentMap['--taskkill-sha256'] -cne $sessionHashes.Taskkill) {
        throw 'Real launcher agent argv differs from its 13-pair closed contract'
    }
    $argvExit = Invoke-TeremoqPinnedNodeProcess -FilePath $nodePath -ExpectedSha256 $nodeHash `
        -Arguments $agentArguments -WorkingDirectory $root
    if ($argvExit -ne 0) { throw 'Real launcher did not produce the complete closed agent argv' }
    Write-Output 'lan-interactive-client-lock-test: PASS'
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
