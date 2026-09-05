# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ExpectedCommit
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function ConvertTo-TeremoqLowerHex([byte[]]$Bytes) {
    return ([BitConverter]::ToString($Bytes) -replace '-', '').ToLowerInvariant()
}

function Get-TeremoqSafeAgentOutput([AllowEmptyString()][string]$Line) {
    if ($null -eq $Line -or $Line.Length -gt 160) { return $null }
    $connected = '[Teremoq] Canal seguro conectado. Esperando ordenes del servidor...'
    if ($Line -ceq $connected) { return $Line }
    if ($Line -cnotmatch '^\[Teremoq\] Paso [1-9][0-9]{0,5} - ([A-Za-z ]{1,64}): ([a-z ]{1,32})$') {
        return $null
    }
    $actions = @(
        'Preparar y verificar el cliente', 'Comprobar el portatil',
        'Iniciar un reproductor', 'Probar cinco espectadores',
        'Probar diez espectadores', 'Probar veinticinco espectadores',
        'Observar la recuperacion Wi-Fi', 'Recoger resultados', 'Detener el cliente'
    )
    $stages = @('orden recibida', 'en ejecucion', 'continua en ejecucion', 'completado', 'fallo comunicado al servidor')
    if ($actions -ccontains $Matches[1] -and $stages -ccontains $Matches[2]) { return $Line }
    return $null
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

function Assert-TeremoqClientIsNotElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Interactive client must run without elevation'
    }
}

function Assert-TeremoqProtectedExecutableAcl([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    Assert-TeremoqNonReparseAncestors $full
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $protectedSids = @(
        $identity.User.Value,
        'S-1-5-32-545',
        'S-1-1-0'
    )
    [int]$dangerous = [int][Security.AccessControl.FileSystemRights]::Write -bor [int][Security.AccessControl.FileSystemRights]::Delete -bor [int][Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [int][Security.AccessControl.FileSystemRights]::ChangePermissions -bor [int][Security.AccessControl.FileSystemRights]::TakeOwnership
    $current = $full
    while ($current -and [IO.Directory]::GetParent($current)) {
        $acl = Get-Acl -LiteralPath $current
        $ownerSid = (New-Object Security.Principal.NTAccount($acl.Owner)).Translate(
            [Security.Principal.SecurityIdentifier]
        ).Value
        if ($protectedSids -contains $ownerSid) { throw 'Executable path is owned by a mutable client identity' }
        foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ($protectedSids -contains $rule.IdentityReference.Value -and
                $rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                (($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -eq 0) -and
                (($rule.FileSystemRights -band $dangerous) -ne 0)) {
                throw 'Executable ACL grants mutation to client, Users or Everyone'
            }
        }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }
        $current = $parent.FullName
    }
}

function Get-TeremoqProtectedExecutableSha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )
    Assert-TeremoqProtectedExecutableAcl $Path
    $shareMode = [Enum]::ToObject([IO.FileShare], 7)
    $stream = New-Object IO.FileStream(
        ([IO.Path]::GetFullPath($Path)),
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        $shareMode
    )
    try {
        if ($stream.Length -lt 1 -or $stream.Length -gt 134217728) { throw 'Executable size is outside contract' }
        Initialize-TeremoqHandleResolver
        $finalPath = [TeremoqInteractiveHandle]::Resolve($stream.SafeFileHandle)
        if (-not [string]::Equals(
            [IO.Path]::GetFullPath($finalPath).TrimEnd('\'),
            [IO.Path]::GetFullPath($Path).TrimEnd('\'),
            [StringComparison]::OrdinalIgnoreCase
        )) { throw 'Executable handle resolves to a different reviewed path' }
        return Get-TeremoqStreamSha256 $stream
    } finally { $stream.Dispose() }
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
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )
    if ((Get-TeremoqProtectedExecutableSha256 -Path $GitPath) -cne $ExpectedSha256) {
        throw 'Git executable changed after session approval'
    }
    $global:LASTEXITCODE = $null
    $output = @(& $GitPath @Prefix @Arguments 2>$null)
    $exitCode = $global:LASTEXITCODE
    if ($exitCode -isnot [int] -or $exitCode -ne 0) { throw 'Git provenance verification failed' }
    return $output
}

function ConvertTo-TeremoqWindowsArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value -eq '') { return '""' }
    if ($Value -cnotmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $backslashes += 1; continue }
        if ($character -eq '"') {
            [void]$builder.Append('\' * (($backslashes * 2) + 1))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) { [void]$builder.Append('\' * $backslashes); $backslashes = 0 }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) { [void]$builder.Append('\' * ($backslashes * 2)) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-TeremoqPinnedNodeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [AllowEmptyString()][string]$InputLine = ''
    )
    if ($Arguments.Count -lt 1 -or $Arguments.Count -gt 32 -or
        @($Arguments | Where-Object { $null -eq $_ -or $_.Length -gt 8192 }).Count -ne 0) {
        throw 'Pinned Node arguments are outside contract'
    }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-TeremoqWindowsArgument $_ }) -join ' ')
    $startInfo.WorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.EnvironmentVariables.Clear()
    $childEnvironment = @{
        'SystemRoot' = 'C:\Windows'; 'WINDIR' = 'C:\Windows';
        'ProgramFiles' = 'C:\Program Files';
        'LOCALAPPDATA' = $env:LOCALAPPDATA; 'TEMP' = $env:TEMP; 'TMP' = $env:TEMP;
        'USERPROFILE' = $env:USERPROFILE; 'ComSpec' = 'C:\Windows\System32\cmd.exe';
        'PATH' = 'C:\Program Files\nodejs;C:\Windows\System32;C:\Windows;C:\Program Files\Git\cmd';
        'GIT_CONFIG_NOSYSTEM' = '1'; 'GIT_CONFIG_GLOBAL' = 'NUL';
        'GIT_OPTIONAL_LOCKS' = '0'; 'NO_COLOR' = '1'
    }
    if (${env:ProgramFiles(x86)}) { $childEnvironment['ProgramFiles(x86)'] = ${env:ProgramFiles(x86)} }
    foreach ($entry in $childEnvironment.GetEnumerator()) {
        if ($null -eq $entry.Value -or [string]$entry.Value -eq '') {
            throw 'Pinned Node environment is incomplete'
        }
        $startInfo.EnvironmentVariables[$entry.Key] = [string]$entry.Value
    }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if ((Get-TeremoqProtectedExecutableSha256 -Path $FilePath) -cne $ExpectedSha256) {
            throw 'Node executable changed after session approval'
        }
        if (-not $process.Start()) { throw 'Pinned Node process did not start' }
        $process.StandardInput.WriteLine($InputLine)
        $process.StandardInput.Dispose()
        while (($line = $process.StandardOutput.ReadLine()) -ne $null) {
            $safeLine = Get-TeremoqSafeAgentOutput -Line $line
            if ($null -ne $safeLine) { Write-Host $safeLine }
        }
        $process.WaitForExit()
        return [int]$process.ExitCode
    } finally { $process.Dispose() }
}

function New-TeremoqAgentArguments {
    param(
        [Parameter(Mandatory = $true)][string]$AgentPath,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Commit,
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$EvidenceRoot,
        [Parameter(Mandatory = $true)][hashtable]$SessionHashes
    )
    return @(
        $AgentPath,
        '--server','https://192.168.1.130:18443',
        '--fingerprint','7984fd4852ec204dc16fb445d5260325fd3b686b478676767f52a1fa63a1a7bc',
        '--run-id',$RunId,'--source-commit',$Commit,'--pairing-stdin','true',
        '--checkout',$Checkout,'--state-root',$StateRoot,'--evidence-root',$EvidenceRoot,
        '--git-sha256',$SessionHashes.Git,'--node-sha256',$SessionHashes.Node,
        '--npm-cli-sha256',$SessionHashes.NpmCli,
        '--powershell-sha256',$SessionHashes.PowerShell,
        '--taskkill-sha256',$SessionHashes.Taskkill
    )
}

if ($MyInvocation.InvocationName -eq '.') { return }

if ($PSVersionTable.PSEdition -cne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $env:WSL_INTEROP -or $env:WSL_DISTRO_NAME) {
    throw 'Run this launcher in native Windows PowerShell 5 Desktop'
}
Assert-TeremoqClientIsNotElevated
if ([IO.Path]::GetFullPath($env:SystemRoot).TrimEnd('\') -ine 'C:\Windows' -or
    [IO.Path]::GetFullPath($env:ProgramFiles).TrimEnd('\') -ine 'C:\Program Files') {
    throw 'Windows roots differ from the reviewed executable locations'
}
if ($ExpectedCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'ExpectedCommit must be the exact reviewed commit supplied by the server operator' }

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
    $launcherPin = Open-TeremoqPinnedFile -Path $launcherPath
    $locks.Add($launcherPin.Stream)
    $npmCliPin = Open-TeremoqPinnedFile -Path $npmCliPath
    $locks.Add($npmCliPin.Stream)
    $sessionHashes = @{
        Git = Get-TeremoqProtectedExecutableSha256 -Path $gitPath
        Node = Get-TeremoqProtectedExecutableSha256 -Path $nodePath
        NpmCli = $npmCliPin.Sha256
        PowerShell = Get-TeremoqProtectedExecutableSha256 -Path $powershellPath
        Taskkill = Get-TeremoqProtectedExecutableSha256 -Path $taskkillPath
    }
    $nodeVersionExit = Invoke-TeremoqPinnedNodeProcess -FilePath $nodePath -ExpectedSha256 $sessionHashes.Node `
        -Arguments @('-e','process.exit(process.versions.node.startsWith("22.") ? 0 : 9)') `
        -WorkingDirectory $checkout
    if ($nodeVersionExit -ne 0) { throw 'The interactive client requires the approved Node.js 22.x runtime' }
    $gitPrefix = @('--no-replace-objects', '-c', 'core.hooksPath=NUL', '-c', 'core.fsmonitor=false', '-c', 'protocol.file.allow=never', '-C', $checkout)
    $oldNoSystem = $env:GIT_CONFIG_NOSYSTEM
    $oldGlobal = $env:GIT_CONFIG_GLOBAL
    $env:GIT_CONFIG_NOSYSTEM = '1'
    $env:GIT_CONFIG_GLOBAL = 'NUL'
    try {
        $head = (Invoke-TeremoqGitText $gitPath $gitPrefix @('rev-parse','HEAD') $sessionHashes.Git | Select-Object -First 1).Trim()
        $branch = (Invoke-TeremoqGitText $gitPath $gitPrefix @('symbolic-ref','--short','HEAD') $sessionHashes.Git | Select-Object -First 1).Trim()
        $remote = (Invoke-TeremoqGitText $gitPath $gitPrefix @('remote','get-url','origin') $sessionHashes.Git | Select-Object -First 1).Trim().TrimEnd('/')
        $dirty = @(Invoke-TeremoqGitText $gitPath $gitPrefix @('status','--porcelain=v1','--untracked-files=all') $sessionHashes.Git)
        if ($head -cne $ExpectedCommit -or $branch -cne 'codex/lan-e2e-integration' -or
            $remote -cne 'https://github.com/Teremoq/teremoq' -or $dirty.Count -ne 0) {
            throw 'The Git checkout must be clean, on the reviewed LAN branch and use the official remote'
        }
        $tree = @(Invoke-TeremoqGitText $gitPath $gitPrefix @('ls-tree','-r','--full-tree',$ExpectedCommit,'--','infra/lan','supervisor-web') $sessionHashes.Git)
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
        $headAfterLocks = (Invoke-TeremoqGitText $gitPath $gitPrefix @('rev-parse','HEAD') $sessionHashes.Git | Select-Object -First 1).Trim()
        $dirtyAfterLocks = @(Invoke-TeremoqGitText $gitPath $gitPrefix @('status','--porcelain=v1','--untracked-files=all') $sessionHashes.Git)
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
    $agentArguments = New-TeremoqAgentArguments -AgentPath (Join-Path $PSScriptRoot 'Lan-Interactive-Agent.mjs') `
        -RunId $runId -Commit $head -Checkout $checkout -StateRoot $stateRoot `
        -EvidenceRoot $evidenceRoot -SessionHashes $sessionHashes
    $agentExit = Invoke-TeremoqPinnedNodeProcess -FilePath $nodePath -WorkingDirectory $checkout `
        -ExpectedSha256 $sessionHashes.Node -InputLine $pairingCode -Arguments $agentArguments
    if ($agentExit -ne 0) { throw "Teremoq LAN interactive client stopped with exit code $agentExit" }
} finally {
    for ($index = $locks.Count - 1; $index -ge 0; $index--) { $locks[$index].Dispose() }
}
