# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RecoveryCommit,
    [Parameter(Mandatory = $true)][string]$ChannelCommit,
    [Parameter(Mandatory = $true)][string]$ClientCommit
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$repositoryUrl = 'https://github.com/Teremoq/teremoq'
$repositoryRef = 'refs/heads/codex/lan-e2e-integration'
$serverUrl = 'https://192.168.1.130:18443'
$commitPattern = '^[0-9a-f]{40}$'
if ($RecoveryCommit -cnotmatch $commitPattern -or $ChannelCommit -cnotmatch $commitPattern -or
    $ClientCommit -cnotmatch $commitPattern) {
    throw 'recovery, channel and client commits must be exact lowercase Git commits'
}
if ($PSVersionTable.PSEdition -cne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw 'Windows PowerShell 5 is required for the updater-slot recovery'
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'updater-slot recovery must run without elevation'
}

. (Join-Path $PSScriptRoot 'Client-Distribution.ps1')
. (Join-Path $PSScriptRoot 'Client-Slot-State.ps1')

$checkoutRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..')).TrimEnd('\', '/')
[void](Get-TeremoqGitBootstrapCheckoutContext -CheckoutRoot $checkoutRoot -RepositoryUrl $repositoryUrl `
    -RepositoryRef $repositoryRef -ExpectedCommit $RecoveryCommit -RepositorySubdirectory 'infra/lan')

function Test-ExactAgentArgument {
    param(
        [Parameter(Mandatory = $true)][string]$CommandLine,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )
    $pattern = '(?i)(?:^|\s)' + [regex]::Escape($Name) + '\s+(?:"' +
        [regex]::Escape($Value) + '"|' + [regex]::Escape($Value) + ')(?=\s|$)'
    return [regex]::IsMatch($CommandLine, $pattern)
}

function Get-AgentCheckoutArgument {
    param([Parameter(Mandatory = $true)][string]$CommandLine)
    $match = [regex]::Match($CommandLine, '(?i)(?:^|\s)--checkout\s+(?:"(?<quoted>[^"]+)"|(?<plain>\S+))(?=\s|$)')
    if (-not $match.Success) { throw 'the active channel checkout argument is unavailable' }
    $value = if ($match.Groups['quoted'].Success) { $match.Groups['quoted'].Value } else { $match.Groups['plain'].Value }
    return [IO.Path]::GetFullPath($value).TrimEnd('\', '/')
}

function Get-ExactProcessArgument {
    param(
        [Parameter(Mandatory = $true)][string]$CommandLine,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $pattern = '(?i)(?:^|\s)' + [regex]::Escape($Name) + '\s+(?:"(?<quoted>[^"]+)"|(?<plain>\S+))(?=\s|$)'
    $matches = [regex]::Matches($CommandLine, $pattern)
    if ($matches.Count -ne 1) { return $null }
    if ($matches[0].Groups['quoted'].Success) { return $matches[0].Groups['quoted'].Value }
    return $matches[0].Groups['plain'].Value
}

function Test-ExactProcessPathToken {
    param(
        [Parameter(Mandatory = $true)][string]$CommandLine,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $pattern = '(?i)(?:^|\s)(?:"' + [regex]::Escape($Path) + '"|' +
        [regex]::Escape($Path) + ')(?=\s|$)'
    return [regex]::Matches($CommandLine, $pattern).Count -eq 1
}

function Assert-ReachableRecoveryCommit {
    param([Parameter(Mandatory = $true)][string]$Commit)
    if ($Commit -cnotmatch $commitPattern) { throw 'managed client process has an invalid commit argument' }
    try {
        Invoke-TeremoqGit -CheckoutRoot $checkoutRoot -Arguments @('merge-base', '--is-ancestor', $Commit, $RecoveryCommit) | Out-Null
    } catch {
        throw 'managed client process commit is not an ancestor of the recovery commit'
    }
}

function Invoke-TeremoqTaskkill {
    param(
        [Parameter(Mandatory = $true)][string]$TaskkillPath,
        [Parameter(Mandatory = $true)][int]$ProcessId
    )
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $TaskkillPath
    $startInfo.Arguments = Convert-TeremoqWindowsCommandLine -Arguments @('/PID', [string]$ProcessId, '/T', '/F')
    $startInfo.WorkingDirectory = $checkoutRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'failed to start taskkill.exe for updater recovery' }
        if (-not $process.WaitForExit(10000)) {
            try { $process.Kill() } catch {}
            if (-not $process.WaitForExit(5000)) { throw 'taskkill.exe did not terminate after timeout' }
            throw 'taskkill.exe timed out during updater recovery'
        }
        return $process.ExitCode
    } finally {
        $process.Dispose()
    }
}

function Stop-TeremoqInactiveSlotProcesses {
    param(
        [Parameter(Mandatory = $true)][string]$Slot,
        [Parameter(Mandatory = $true)][string]$Head
    )
    $launcherPath = [IO.Path]::GetFullPath((Join-Path $Slot 'infra\lan\client\Start-LanInteractiveClient.ps1'))
    $agentPath = [IO.Path]::GetFullPath((Join-Path $Slot 'infra\lan\client\Lan-Interactive-Agent.mjs'))
    $powershellPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $taskkillPath = 'C:\Windows\System32\taskkill.exe'
    $nodePath = 'C:\Program Files\nodejs\node.exe'
    foreach ($requiredExecutable in @($powershellPath, $taskkillPath, $nodePath)) {
        if (-not (Test-Path -LiteralPath $requiredExecutable -PathType Leaf)) {
            throw 'a reviewed executable required for updater recovery is unavailable'
        }
    }
    $taskkillHash = (Get-FileHash -LiteralPath $taskkillPath -Algorithm SHA256).Hash
    $managed = New-Object Collections.Generic.List[object]
    foreach ($process in @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine })) {
        $isLauncher = $process.Name -ieq 'powershell.exe' -and $process.ExecutablePath -and
            $process.ExecutablePath.Equals($powershellPath, [StringComparison]::OrdinalIgnoreCase) -and
            (Test-ExactProcessPathToken -CommandLine $process.CommandLine -Path $launcherPath)
        $isAgent = $process.Name -ieq 'node.exe' -and $process.ExecutablePath -and
            $process.ExecutablePath.Equals($nodePath, [StringComparison]::OrdinalIgnoreCase) -and
            (Test-ExactProcessPathToken -CommandLine $process.CommandLine -Path $agentPath)
        if (-not $isLauncher -and -not $isAgent) { continue }

        $processCommit = if ($isLauncher) {
            Get-ExactProcessArgument -CommandLine $process.CommandLine -Name '-ExpectedCommit'
        } else {
            Get-ExactProcessArgument -CommandLine $process.CommandLine -Name '--client-commit'
        }
        $processChannelCommit = if ($isLauncher) {
            Get-ExactProcessArgument -CommandLine $process.CommandLine -Name '-ChannelCommit'
        } else {
            Get-ExactProcessArgument -CommandLine $process.CommandLine -Name '--source-commit'
        }
        if ($processCommit -cne $Head) { throw 'managed inactive-slot process commit differs from the checkout' }
        Assert-ReachableRecoveryCommit -Commit $processChannelCommit
        if ($isAgent) {
            $declaredCheckout = Get-ExactProcessArgument -CommandLine $process.CommandLine -Name '--checkout'
            if ([string]::IsNullOrEmpty($declaredCheckout) -or
                -not ([IO.Path]::GetFullPath($declaredCheckout).TrimEnd('\', '/')).Equals($Slot, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'managed inactive-slot agent declares a different checkout'
            }
            if (-not (Test-ExactAgentArgument -CommandLine $process.CommandLine -Name '--server' -Value $serverUrl)) {
                throw 'managed inactive-slot agent declares a different server'
            }
        }
        $managed.Add($process)
    }
    if ($managed.Count -eq 0) { return }

    # Kill parent launchers first so they cannot respawn an agent while the slot is retired.
    $ordered = @($managed | Sort-Object @{ Expression = { if ($_.Name -ieq 'powershell.exe') { 0 } else { 1 } } }, ProcessId)
    foreach ($process in $ordered) {
        if (-not (Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue)) { continue }
        $exitCode = Invoke-TeremoqTaskkill -TaskkillPath $taskkillPath -ProcessId $process.ProcessId
        if ($exitCode -notin @(0, 128)) { throw 'failed to stop a verified inactive Teremoq client process' }
    }
    if ((Get-FileHash -LiteralPath $taskkillPath -Algorithm SHA256).Hash -cne $taskkillHash) {
        throw 'taskkill.exe changed during updater recovery'
    }
    for ($attempt = 1; $attempt -le 20; $attempt += 1) {
        $remaining = @($managed | Where-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
        if ($remaining.Count -eq 0) { return }
        Start-Sleep -Milliseconds 250
    }
    throw 'verified inactive Teremoq client processes did not stop before slot cleanup'
}

$nodePath = 'C:\Program Files\nodejs\node.exe'
$agents = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object {
    $_.ExecutablePath -and $_.ExecutablePath.Equals($nodePath, [StringComparison]::OrdinalIgnoreCase) -and
    $_.CommandLine -and $_.CommandLine.Contains('Lan-Interactive-Agent.mjs') -and
    (Test-ExactAgentArgument -CommandLine $_.CommandLine -Name '--server' -Value $serverUrl) -and
    (Test-ExactAgentArgument -CommandLine $_.CommandLine -Name '--source-commit' -Value $ChannelCommit) -and
    (Test-ExactAgentArgument -CommandLine $_.CommandLine -Name '--client-commit' -Value $ClientCommit)
})
if ($agents.Count -ne 1) {
    throw "expected exactly one matching active LAN channel client; found $($agents.Count)"
}

$activeCheckout = Get-AgentCheckoutArgument -CommandLine $agents[0].CommandLine
$clientRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Teremoq')).TrimEnd('\', '/')
if (-not $activeCheckout.StartsWith($clientRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'the active channel checkout is outside the managed Teremoq root'
}
$activeAgentPath = [IO.Path]::GetFullPath((Join-Path $activeCheckout 'infra\lan\client\Lan-Interactive-Agent.mjs'))
$agentPathPattern = '(?i)(?:^|\s)(?:"' + [regex]::Escape($activeAgentPath) + '"|' +
    [regex]::Escape($activeAgentPath) + ')(?=\s|$)'
if (-not [regex]::IsMatch($agents[0].CommandLine, $agentPathPattern)) {
    throw 'the active channel process does not execute the agent from its declared checkout'
}
$activeState = [pscustomobject]@{
    StateRoot = Join-Path $clientRoot '.slot-recovery-validation-state'
    Compatibility = [pscustomobject]@{
        repository_url = $repositoryUrl
        repository_ref = $repositoryRef
        repository_subdirectory = 'infra/lan'
        allowed_client_commit = $ClientCommit
    }
    RepositorySubdirectory = 'infra/lan'
}
[void](Get-TeremoqGitCheckoutContext -CheckoutRoot $activeCheckout -StateContext $activeState -RequireExactHead)

$removed = New-Object Collections.Generic.List[string]
foreach ($slotName in @('checkout-updater-a', 'checkout-updater-b')) {
    $slot = [IO.Path]::GetFullPath((Join-Path $clientRoot $slotName)).TrimEnd('\', '/')
    if ($slot.Equals($activeCheckout, [StringComparison]::OrdinalIgnoreCase)) { continue }
    if (-not (Test-Path -LiteralPath $slot)) { continue }
    if (-not (Test-Path -LiteralPath $slot -PathType Container)) {
        throw "managed inactive updater slot is not a directory: $slotName"
    }
    $item = Get-Item -LiteralPath $slot -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "managed inactive updater slot is a reparse point: $slotName"
    }
    $topLevel = [IO.Path]::GetFullPath((Invoke-TeremoqGit -CheckoutRoot $slot -Arguments @('rev-parse', '--show-toplevel'))).TrimEnd('\', '/')
    $head = Invoke-TeremoqGit -CheckoutRoot $slot -Arguments @('rev-parse', 'HEAD')
    $branch = Invoke-TeremoqGit -CheckoutRoot $slot -Arguments @('symbolic-ref', '--short', 'HEAD')
    $remote = (Invoke-TeremoqGit -CheckoutRoot $slot -Arguments @('remote', 'get-url', 'origin')).TrimEnd('/')
    $remotes = @((Invoke-TeremoqGit -CheckoutRoot $slot -Arguments @('remote')) -split "`n" |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($topLevel -cne $slot -or $head -cnotmatch $commitPattern -or
        $branch -cne 'codex/lan-e2e-integration' -or $remote -cne $repositoryUrl -or
        $remotes.Count -ne 1 -or $remotes[0] -cne 'origin') {
        throw "managed inactive updater slot has unexpected Git identity: $slotName"
    }
    try {
        Invoke-TeremoqGit -CheckoutRoot $checkoutRoot -Arguments @('merge-base', '--is-ancestor', $head, $RecoveryCommit) | Out-Null
    } catch {
        throw "managed inactive updater slot is not an ancestor of the recovery commit: $slotName"
    }
    Stop-TeremoqInactiveSlotProcesses -Slot $slot -Head $head
    Remove-TeremoqBoundedRegularTree -Path $slot -ExpectedParent $clientRoot
    $removed.Add($slotName)
}

Write-Host '[Teremoq] El canal R10 sigue abierto; no se ha cambiado su sesion ni su configuracion.'
if ($removed.Count -eq 0) {
    Write-Host '[Teremoq] No habia ranuras inactivas que reparar.'
} else {
    Write-Host ("[Teremoq] Ranuras inactivas reparadas: {0}." -f ($removed -join ', '))
}
Write-Host '[Teremoq] El servidor ya puede enviar la actualizacion por el canal existente.'
