# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ExpectedCommit,
    [Parameter(Mandatory = $true)][string]$ExpectedLauncherSha256,
    [Parameter(Mandatory = $true)][string]$ExpectedGitSha256,
    [Parameter(Mandatory = $true)][string]$ExpectedNodeSha256,
    [Parameter(Mandatory = $true)][string]$ExpectedNpmCliSha256,
    [Parameter(Mandatory = $true)][string]$ExpectedPowerShellSha256,
    [Parameter(Mandatory = $true)][string]$ExpectedTaskkillSha256
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function ConvertTo-TeremoqLowerHex([byte[]]$Bytes) {
    return ([BitConverter]::ToString($Bytes) -replace '-', '').ToLowerInvariant()
}

function Assert-TeremoqNonReparseAncestors([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Pinned path contains a reparse-point ancestor'
        }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }
        $current = $parent.FullName
    }
}

function Initialize-TeremoqHandleResolver {
    if ('TeremoqInteractiveHandle' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class TeremoqInteractiveHandle {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(
        SafeFileHandle handle, StringBuilder path, uint length, uint flags);

    public static string Resolve(SafeFileHandle handle) {
        StringBuilder output = new StringBuilder(32768);
        uint length = GetFinalPathNameByHandleW(handle, output, (uint)output.Capacity, 0);
        if (length == 0 || length >= output.Capacity) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        string value = output.ToString();
        if (value.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) {
            return @"\\" + value.Substring(8);
        }
        return value.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase) ? value.Substring(4) : value;
    }
}
'@
}

function Get-TeremoqStreamSha256([IO.FileStream]$Stream) {
    $Stream.Position = 0
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ConvertTo-TeremoqLowerHex $sha.ComputeHash($Stream) }
    finally { $sha.Dispose(); $Stream.Position = 0 }
}

function Get-TeremoqStreamGitBlobId([IO.FileStream]$Stream) {
    $Stream.Position = 0
    $sha = [Security.Cryptography.SHA1]::Create()
    try {
        $headerText = 'blob ' + $Stream.Length
        $header = [Text.Encoding]::ASCII.GetBytes($headerText)
        $headerWithNull = New-Object byte[] ($header.Length + 1)
        [Array]::Copy($header, $headerWithNull, $header.Length)
        [void]$sha.TransformBlock($headerWithNull, 0, $headerWithNull.Length, $headerWithNull, 0)
        $buffer = New-Object byte[] 65536
        while (($count = $Stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            [void]$sha.TransformBlock($buffer, 0, $count, $buffer, 0)
        }
        $empty = New-Object byte[] 0
        [void]$sha.TransformFinalBlock($empty, 0, 0)
        return ConvertTo-TeremoqLowerHex $sha.Hash
    } finally {
        $sha.Dispose()
        $Stream.Position = 0
    }
}

function Open-TeremoqPinnedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$ExpectedSha256 = '',
        [string]$ExpectedBlobId = '',
        [int64]$MaximumBytes = 134217728
    )
    $full = [IO.Path]::GetFullPath($Path)
    Assert-TeremoqNonReparseAncestors $full
    $stream = New-Object IO.FileStream(
        $full,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        if ($stream.Length -lt 1 -or $stream.Length -gt $MaximumBytes) {
            throw 'Pinned file size is outside contract'
        }
        Initialize-TeremoqHandleResolver
        $finalPath = [TeremoqInteractiveHandle]::Resolve($stream.SafeFileHandle)
        if (-not [string]::Equals(
            [IO.Path]::GetFullPath($finalPath).TrimEnd('\'),
            $full.TrimEnd('\'),
            [StringComparison]::OrdinalIgnoreCase
        )) { throw 'Pinned file handle resolves to a different path' }
        $sha256 = Get-TeremoqStreamSha256 $stream
        if ($ExpectedSha256 -and $sha256 -cne $ExpectedSha256) {
            throw 'Pinned executable or launcher hash differs from approval'
        }
        if ($ExpectedBlobId -and (Get-TeremoqStreamGitBlobId $stream) -cne $ExpectedBlobId) {
            throw 'Pinned source bytes differ from the approved Git blob'
        }
        return [pscustomobject]@{ Stream = $stream; Path = $full; Sha256 = $sha256 }
    } catch {
        $stream.Dispose()
        throw
    }
}

function Invoke-TeremoqGitText {
    param(
        [Parameter(Mandatory = $true)][string]$GitPath,
        [Parameter(Mandatory = $true)][string[]]$Prefix,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $global:LASTEXITCODE = $null
    $output = @(& $GitPath @Prefix @Arguments 2>$null)
    $exitCode = $global:LASTEXITCODE
    if ($exitCode -isnot [int] -or $exitCode -ne 0) { throw 'Git provenance verification failed' }
    return $output
}

if ($MyInvocation.InvocationName -eq '.') { return }

if ($PSVersionTable.PSEdition -cne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $env:WSL_INTEROP -or $env:WSL_DISTRO_NAME) {
    throw 'Run this launcher in native Windows PowerShell 5 Desktop'
}
if ([IO.Path]::GetFullPath($env:SystemRoot).TrimEnd('\') -ine 'C:\Windows' -or
    [IO.Path]::GetFullPath($env:ProgramFiles).TrimEnd('\') -ine 'C:\Program Files') {
    throw 'Windows roots differ from the reviewed executable locations'
}
if ($ExpectedCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'ExpectedCommit must be the exact reviewed commit supplied by the server operator' }
$approvedHashes = @(
    $ExpectedLauncherSha256, $ExpectedGitSha256, $ExpectedNodeSha256,
    $ExpectedNpmCliSha256, $ExpectedPowerShellSha256, $ExpectedTaskkillSha256
)
if (@($approvedHashes | Where-Object { $_ -cnotmatch '^[0-9a-f]{64}$' }).Count -ne 0) {
    throw 'Every executable and launcher requires an approved lowercase SHA-256'
}

$checkout = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$launcherPath = [IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
$gitPath = 'C:\Program Files\Git\cmd\git.exe'
$nodePath = 'C:\Program Files\nodejs\node.exe'
$npmCliPath = 'C:\Program Files\nodejs\node_modules\npm\bin\npm-cli.js'
$powershellPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$taskkillPath = 'C:\Windows\System32\taskkill.exe'
$hostPath = [IO.Path]::GetFullPath((Get-Process -Id $PID).Path)
if (-not [string]::Equals($hostPath, $powershellPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The running PowerShell host differs from the reviewed executable'
}
$locks = New-Object Collections.Generic.List[IO.FileStream]
try {
    foreach ($specification in @(
        @($launcherPath, $ExpectedLauncherSha256),
        @($gitPath, $ExpectedGitSha256),
        @($nodePath, $ExpectedNodeSha256),
        @($npmCliPath, $ExpectedNpmCliSha256),
        @($powershellPath, $ExpectedPowerShellSha256),
        @($taskkillPath, $ExpectedTaskkillSha256)
    )) {
        $pin = Open-TeremoqPinnedFile -Path $specification[0] -ExpectedSha256 $specification[1]
        $locks.Add($pin.Stream)
    }

    $nodeVersion = (@(& $nodePath --version 2>$null) -join '').Trim()
    if ($nodeVersion -cnotmatch '^v22\.[0-9]+\.[0-9]+$') { throw 'The interactive client requires the approved Node.js 22.x runtime' }
    $gitPrefix = @('--no-replace-objects', '-c', 'core.hooksPath=NUL', '-c', 'core.fsmonitor=false', '-c', 'protocol.file.allow=never', '-C', $checkout)
    $oldNoSystem = $env:GIT_CONFIG_NOSYSTEM
    $oldGlobal = $env:GIT_CONFIG_GLOBAL
    $env:GIT_CONFIG_NOSYSTEM = '1'
    $env:GIT_CONFIG_GLOBAL = 'NUL'
    try {
        $head = (Invoke-TeremoqGitText $gitPath $gitPrefix @('rev-parse','HEAD') | Select-Object -First 1).Trim()
        $branch = (Invoke-TeremoqGitText $gitPath $gitPrefix @('symbolic-ref','--short','HEAD') | Select-Object -First 1).Trim()
        $remote = (Invoke-TeremoqGitText $gitPath $gitPrefix @('remote','get-url','origin') | Select-Object -First 1).Trim().TrimEnd('/')
        $dirty = @(Invoke-TeremoqGitText $gitPath $gitPrefix @('status','--porcelain=v1','--untracked-files=all'))
        if ($head -cne $ExpectedCommit -or $branch -cne 'codex/lan-e2e-integration' -or
            $remote -cne 'https://github.com/Teremoq/teremoq' -or $dirty.Count -ne 0) {
            throw 'The Git checkout must be clean, on the reviewed LAN branch and use the official remote'
        }
        $tree = @(Invoke-TeremoqGitText $gitPath $gitPrefix @('ls-tree','-r','--full-tree',$ExpectedCommit,'--','infra/lan','supervisor-web'))
        if ($tree.Count -lt 1 -or $tree.Count -gt 4096) { throw 'Approved client source inventory is outside limits' }
        foreach ($line in $tree) {
            if ($line -cnotmatch '^100(?:644|755) blob ([0-9a-f]{40})\t([A-Za-z0-9._/-]{1,512})$') {
                throw 'Approved client source inventory contains an unsupported entry'
            }
            $sourcePath = [IO.Path]::GetFullPath((Join-Path $checkout ($Matches[2] -replace '/', '\')))
            if (-not $sourcePath.StartsWith($checkout + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Approved source path escapes checkout'
            }
            $pin = Open-TeremoqPinnedFile -Path $sourcePath -ExpectedBlobId $Matches[1]
            $locks.Add($pin.Stream)
        }
        $headAfterLocks = (Invoke-TeremoqGitText $gitPath $gitPrefix @('rev-parse','HEAD') | Select-Object -First 1).Trim()
        $dirtyAfterLocks = @(Invoke-TeremoqGitText $gitPath $gitPrefix @('status','--porcelain=v1','--untracked-files=all'))
        if ($headAfterLocks -cne $ExpectedCommit -or $dirtyAfterLocks.Count -ne 0) {
            throw 'Checkout changed while source handles were being pinned'
        }
    } finally {
        $env:GIT_CONFIG_NOSYSTEM = $oldNoSystem
        $env:GIT_CONFIG_GLOBAL = $oldGlobal
    }

    $runId = 'lan-20260831-wifi1'
    $shortCommit = $head.Substring(0, 12)
    $root = Join-Path $env:LOCALAPPDATA 'Teremoq'
    $stateRoot = Join-Path $root ("interactive-state-{0}-{1}" -f $runId, $shortCommit)
    $evidenceRoot = Join-Path $root ("interactive-evidence-{0}-{1}" -f $runId, $shortCommit)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { New-Item -ItemType Directory -Path $root | Out-Null }
    if (-not (Test-Path -LiteralPath $evidenceRoot -PathType Container)) { New-Item -ItemType Directory -Path $evidenceRoot | Out-Null }

    Write-Host "Teremoq LAN interactive client: commit $head; $($locks.Count) immutable read handles"
    Write-Host 'The client only initiates outbound HTTPS and executes the reviewed fixed action list.'
    $pairingCode = Read-Host 'Enter the one-time pairing code shown on the server'
    if ($pairingCode -cnotmatch '^[0-9a-f]{48}$') { throw 'The pairing code must contain exactly 48 lowercase hexadecimal characters' }
    $global:LASTEXITCODE = $null
    $pairingCode | & $nodePath (Join-Path $PSScriptRoot 'Lan-Interactive-Agent.mjs') `
        --server 'https://192.168.1.130:18443' `
        --fingerprint '7984fd4852ec204dc16fb445d5260325fd3b686b478676767f52a1fa63a1a7bc' `
        --run-id $runId `
        --source-commit $head `
        --pairing-stdin 'true' `
        --checkout $checkout `
        --state-root $stateRoot `
        --evidence-root $evidenceRoot
    $agentExit = $global:LASTEXITCODE
    if ($agentExit -isnot [int] -or $agentExit -ne 0) { throw "Teremoq LAN interactive client stopped with exit code $agentExit" }
} finally {
    for ($index = $locks.Count - 1; $index -ge 0; $index--) { $locks[$index].Dispose() }
}
