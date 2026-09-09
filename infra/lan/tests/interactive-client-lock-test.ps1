# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$launcher = Join-Path $PSScriptRoot '..\client\Start-LanInteractiveClient.ps1'
$repair = Join-Path $PSScriptRoot '..\client\Repair-LanUpdaterSlots.ps1'
$sourcePinHelper = Join-Path $PSScriptRoot '..\client\Pin-LanTaskSources.ps1'
$zeroCommit = '0' * 40
$zeroHash = '0' * 64
. $launcher -ExpectedCommit $zeroCommit
. $repair -RecoveryCommit $zeroCommit -ChannelCommit $zeroCommit -ClientCommit $zeroCommit

$root = Join-Path ([IO.Path]::GetTempPath()) ('teremoq-interactive-lock-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $wrappedMoveFailureObserved = $false
    try {
        [IO.Directory]::Move((Join-Path $root 'missing-slot'), (Join-Path $root 'unused-quarantine'))
    } catch {
        $wrappedMoveFailureObserved = Test-TeremoqDeferrableSlotMoveError -Exception $_.Exception
    }
    if (-not $wrappedMoveFailureObserved -or
        (Test-TeremoqDeferrableSlotMoveError -Exception (New-Object InvalidOperationException('not an IO failure'))) -or
        (Test-TeremoqDeferrableSlotMoveError -Exception (New-Object UnauthorizedAccessException('not deferrable')))) {
        throw 'Updater slot cleanup did not isolate the wrapped directory move failure'
    }

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

    $taskCheckout = Join-Path $root 'task-checkout'
    $taskSourceRoot = Join-Path $taskCheckout 'infra\lan\client'
    New-Item -ItemType Directory -Path $taskSourceRoot | Out-Null
    $taskSource = Join-Path $taskSourceRoot 'reviewed.ps1'
    [IO.File]::WriteAllText($taskSource, 'reviewed task source', (New-Object Text.UTF8Encoding($false)))
    $taskStream = New-Object IO.FileStream($taskSource, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { $taskBlob = Get-TeremoqStreamGitBlobId -Stream $taskStream }
    finally { $taskStream.Dispose() }
    $pinStart = New-Object Diagnostics.ProcessStartInfo
    $pinStart.FileName = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $pinStart.Arguments = (@(
        '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$sourcePinHelper,
        '-CheckoutRoot',$taskCheckout
    ) | ForEach-Object { ConvertTo-TeremoqWindowsArgument $_ }) -join ' '
    $pinStart.UseShellExecute = $false
    $pinStart.CreateNoWindow = $true
    $pinStart.RedirectStandardInput = $true
    $pinStart.RedirectStandardOutput = $true
    $pinStart.RedirectStandardError = $true
    $pinProcess = New-Object Diagnostics.Process
    $pinProcess.StartInfo = $pinStart
    try {
        if (-not $pinProcess.Start()) { throw 'Task source pin helper did not start' }
        $pinProcess.StandardInput.WriteLine(($taskBlob + "`tinfra/lan/client/reviewed.ps1"))
        $pinProcess.StandardInput.WriteLine('END')
        $pinProcess.StandardInput.Flush()
        if ($pinProcess.StandardOutput.ReadLine() -cne 'PINNED') {
            throw 'Task source pin helper did not report readiness'
        }
        $taskMutationRejected = $false
        try { [IO.File]::WriteAllText($taskSource, 'mutated while task runs') }
        catch { $taskMutationRejected = $true }
        if (-not $taskMutationRejected) { throw 'Task source remained mutable while its workload could run' }
        $pinProcess.StandardInput.WriteLine('release')
        $pinProcess.StandardInput.Dispose()
        if (-not $pinProcess.WaitForExit(10000) -or $pinProcess.ExitCode -ne 0) {
            throw 'Task source pin helper did not release cleanly'
        }
    } finally {
        if (-not $pinProcess.HasExited) { $pinProcess.Kill() }
        $pinProcess.Dispose()
    }
    [IO.File]::WriteAllText($taskSource, 'mutable after task')
    if ([IO.File]::ReadAllText($taskSource) -cne 'mutable after task') {
        throw 'Task source pin was not released after workload completion'
    }
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
    $windowsRootsExit = Invoke-TeremoqPinnedNodeProcess -FilePath $nodePath `
        -ExpectedSha256 $nodeHash `
        -Arguments @('-e','process.exit(process.env.SystemDrive === "C:" && process.env.ProgramData === "C:\\ProgramData" ? 0 : 8)') `
        -WorkingDirectory $root
    if ($windowsRootsExit -ne 0) { throw 'Pinned Node environment omitted canonical Windows shared-data roots' }

    $safeStatus = '[Teremoq] Paso 1 - Preparar y verificar el cliente: en ejecucion'
    if ((Get-TeremoqSafeAgentOutput -Line $safeStatus) -cne $safeStatus) {
        throw 'Fixed local client progress was not relayed'
    }
    $stableUpdateStatus = '[Teremoq] Cliente actualizado; el canal seguro permanece conectado.'
    if ((Get-TeremoqSafeAgentOutput -Line $stableUpdateStatus) -cne $stableUpdateStatus) {
        throw 'Stable channel update status was not relayed'
    }
    if ($null -ne (Get-TeremoqSafeAgentOutput -Line '[Teremoq] Paso 1 - C:\secret: en ejecucion') -or
        $null -ne (Get-TeremoqSafeAgentOutput -Line '[Teremoq] Paso 1 - Preparar y verificar el cliente: token=secret')) {
        throw 'Arbitrary agent output was relayed to the client console'
    }
    $safeError = 'Teremoq LAN agent: channel rejected request (400)'
    if ((Get-TeremoqSafeAgentError -Line $safeError) -cne $safeError -or
        $null -ne (Get-TeremoqSafeAgentError -Line 'token=secret') -or
        $null -ne (Get-TeremoqSafeAgentError -Line ('x' * 513))) {
        throw 'Agent fatal error console policy is not closed and bounded'
    }

    $argvCanary = Join-Path $root 'argv-canary.mjs'
    $argvCanarySource = @'
const argv = process.argv.slice(2);
const required = new Set(["--server","--fingerprint","--run-id","--source-commit","--client-commit","--credential-mode","--checkout","--state-root","--evidence-root","--git-sha256","--node-sha256","--npm-cli-sha256","--powershell-sha256","--taskkill-sha256","--channel-mode","--source-pin-sha256"]);
if (argv.length !== 32) process.exit(20);
for (let index = 0; index < argv.length; index += 2) {
  if (!required.delete(argv[index]) || !argv[index + 1]) process.exit(21);
}
if (required.size !== 0) process.exit(22);
'@
    [IO.File]::WriteAllText($argvCanary, $argvCanarySource, (New-Object Text.UTF8Encoding($false)))
    $sessionHashes = @{ Git=$zeroHash; Node=$nodeHash; NpmCli=$zeroHash; PowerShell=$zeroHash; Taskkill=$zeroHash }
    $agentArguments = New-TeremoqAgentArguments -AgentPath $argvCanary -RunId 'lan-argv-canary' `
        -ChannelCommit $zeroCommit -ClientCommit $zeroCommit -Checkout $root -StateRoot $root -EvidenceRoot $root `
        -SessionHashes $sessionHashes -CredentialMode 'pair' -ChannelMode 'stable' -SourcePinSha256 $zeroHash
    $argumentMap = @{}
    for ($index = 1; $index -lt $agentArguments.Count; $index += 2) {
        if ($argumentMap.ContainsKey($agentArguments[$index])) { throw 'Real launcher duplicated an agent argument' }
        $argumentMap[$agentArguments[$index]] = $agentArguments[$index + 1]
    }
    if ($agentArguments.Count -ne 33 -or $argumentMap.Count -ne 16 -or
        $argumentMap['--git-sha256'] -cne $sessionHashes.Git -or
        $argumentMap['--node-sha256'] -cne $sessionHashes.Node -or
        $argumentMap['--npm-cli-sha256'] -cne $sessionHashes.NpmCli -or
        $argumentMap['--powershell-sha256'] -cne $sessionHashes.PowerShell -or
        $argumentMap['--taskkill-sha256'] -cne $sessionHashes.Taskkill -or
        $argumentMap['--source-pin-sha256'] -cne $zeroHash) {
        throw 'Real launcher agent argv differs from its 16-pair closed contract'
    }
    $argvExit = Invoke-TeremoqPinnedNodeProcess -FilePath $nodePath -ExpectedSha256 $nodeHash `
        -Arguments $agentArguments -WorkingDirectory $root
    if ($argvExit -ne 0) { throw 'Real launcher did not produce the complete closed agent argv' }

    $ackPath = Join-Path $root ('handoff-' + [Guid]::NewGuid().ToString('N') + '.ack')
    $ackValue = 'a' * 64
    $nearMissExit = Invoke-TeremoqPinnedNodeProcess -FilePath $nodePath -ExpectedSha256 $nodeHash `
        -Arguments @('-e','console.log("[Teremoq] Canal seguro conectado.")') -WorkingDirectory $root `
        -HandoffAckPath $ackPath -HandoffAckValue $ackValue
    if ($nearMissExit -ne 0 -or (Test-Path -LiteralPath $ackPath)) {
        throw 'A non-contract status line created the handoff acknowledgement'
    }

    $launcherForJob = [IO.Path]::GetFullPath($launcher)
    $job = Start-Job -ScriptBlock {
        param($Launcher, $Commit, $Node, $NodeHash, $WorkingDirectory, $AckPath, $AckValue)
        $ErrorActionPreference = 'Stop'
        Set-StrictMode -Version 3.0
        . $Launcher -ExpectedCommit $Commit
        Invoke-TeremoqPinnedNodeProcess -FilePath $Node -ExpectedSha256 $NodeHash `
            -Arguments @('-e','setTimeout(()=>{console.log("[Teremoq] Canal seguro conectado. Esperando ordenes del servidor...");setTimeout(()=>process.exit(0),250)},1000)') `
            -WorkingDirectory $WorkingDirectory -HandoffAckPath $AckPath -HandoffAckValue $AckValue
    } -ArgumentList $launcherForJob,$zeroCommit,$nodePath,$nodeHash,$root,$ackPath,$ackValue
    try {
        Start-Sleep -Milliseconds 350
        if (Test-Path -LiteralPath $ackPath) {
            throw 'Handoff acknowledgement was written before the replacement connected'
        }
        if (-not (Wait-Job -Job $job -Timeout 10)) {
            throw 'Replacement connection canary did not finish'
        }
        $jobOutput = @(Receive-Job -Job $job -ErrorAction Stop)
        if ($job.State -cne 'Completed' -or $jobOutput[-1] -ne 0) {
            throw 'Replacement connection canary failed'
        }
        if (-not (Test-Path -LiteralPath $ackPath -PathType Leaf) -or
            [IO.File]::ReadAllText($ackPath) -cne ($ackValue + "`n")) {
            throw 'Replacement connection did not create the exact handoff acknowledgement'
        }
    } finally {
        if ($null -ne $job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
    }
    Write-Output 'lan-interactive-client-lock-test: PASS'
} finally {
    for ($attempt = 0; $attempt -lt 20 -and (Test-Path -LiteralPath $root); $attempt++) {
        try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop }
        catch { Start-Sleep -Milliseconds 100 }
    }
    if (Test-Path -LiteralPath $root) { throw 'Interactive client lock fixture cleanup did not complete' }
}
