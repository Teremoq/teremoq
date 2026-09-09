# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$CheckoutRoot)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Assert-TeremoqTaskSourcePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Task source path contains a reparse point'
        }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }
        $current = $parent.FullName
    }
}

function Get-TeremoqTaskSourceBlobId {
    param([Parameter(Mandatory = $true)][IO.FileStream]$Stream)
    if ($Stream.Length -lt 1 -or $Stream.Length -gt 134217728) {
        throw 'Task source size is outside contract'
    }
    $sha = [Security.Cryptography.SHA1]::Create()
    try {
        $header = [Text.Encoding]::ASCII.GetBytes(('blob ' + $Stream.Length))
        $headerWithNull = New-Object byte[] ($header.Length + 1)
        [Array]::Copy($header, $headerWithNull, $header.Length)
        [void]$sha.TransformBlock($headerWithNull, 0, $headerWithNull.Length, $headerWithNull, 0)
        $buffer = New-Object byte[] 65536
        while (($count = $Stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            [void]$sha.TransformBlock($buffer, 0, $count, $buffer, 0)
        }
        $empty = New-Object byte[] 0
        [void]$sha.TransformFinalBlock($empty, 0, 0)
        return ([BitConverter]::ToString($sha.Hash) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
        $Stream.Position = 0
    }
}

$root = [IO.Path]::GetFullPath($CheckoutRoot).TrimEnd('\', '/')
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    throw 'Task checkout is absent'
}
Assert-TeremoqTaskSourcePath -Path $root

$locks = New-Object Collections.Generic.List[IO.FileStream]
$seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
$terminated = $false
try {
    for ($index = 0; $index -lt 4096; $index += 1) {
        $line = [Console]::In.ReadLine()
        if ($null -eq $line) { throw 'Task source manifest ended before its terminator' }
        if ($line -ceq 'END') {
            if ($locks.Count -lt 1) { throw 'Task source manifest is empty' }
            $terminated = $true
            break
        }
        if ($line -cnotmatch '^([0-9a-f]{40})\t([A-Za-z0-9._/-]{1,512})$') {
            throw 'Task source manifest entry is outside contract'
        }
        $blob = $Matches[1]
        $relative = $Matches[2]
        $segments = @($relative -split '/')
        if (($relative -cnotmatch '^(?:infra/lan|supervisor-web)/') -or
            @($segments | Where-Object { $_ -in @('', '.', '..') }).Count -ne 0 -or
            -not $seen.Add($relative)) {
            throw 'Task source manifest path is not unique and contained'
        }
        $path = [IO.Path]::GetFullPath((Join-Path $root ($relative -replace '/', '\')))
        if (-not $path.StartsWith($root + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Task source path escapes checkout'
        }
        Assert-TeremoqTaskSourcePath -Path $path
        $stream = New-Object IO.FileStream(
            $path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        try {
            if ((Get-TeremoqTaskSourceBlobId -Stream $stream) -cne $blob) {
                throw 'Task source bytes differ from the approved Git blob'
            }
            $locks.Add($stream)
        } catch {
            $stream.Dispose()
            throw
        }
    }
    if (-not $terminated) { throw 'Task source manifest exceeded its file limit' }
    [Console]::Out.WriteLine('PINNED')
    [Console]::Out.Flush()
    if ([Console]::In.ReadLine() -cne 'release') {
        throw 'Task source pin release was not authenticated'
    }
} finally {
    for ($index = $locks.Count - 1; $index -ge 0; $index -= 1) {
        $locks[$index].Dispose()
    }
}
