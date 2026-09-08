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
    if ($topLevel -cne $slot -or $head -cnotmatch $commitPattern -or
        $branch -cne 'codex/lan-e2e-integration' -or $remote -cne $repositoryUrl) {
        throw "managed inactive updater slot has unexpected Git identity: $slotName"
    }
    try {
        Invoke-TeremoqGit -CheckoutRoot $slot -Arguments @('merge-base', '--is-ancestor', $head, $RecoveryCommit) | Out-Null
    } catch {
        throw "managed inactive updater slot is not an ancestor of the recovery commit: $slotName"
    }
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
