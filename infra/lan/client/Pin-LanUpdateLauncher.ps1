# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$LauncherPath,
    [Parameter(Mandatory = $true)][string]$ExpectedBlobId
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

if ($ExpectedBlobId -cnotmatch '^[0-9a-f]{40}$') { throw 'ExpectedBlobId is invalid' }
$full = [IO.Path]::GetFullPath($LauncherPath)
$stream = New-Object IO.FileStream(
    $full,
    [IO.FileMode]::Open,
    [IO.FileAccess]::Read,
    [IO.FileShare]::Read
)
try {
    if ($stream.Length -lt 1 -or $stream.Length -gt 1048576) { throw 'launcher size is outside contract' }
    $sha = [Security.Cryptography.SHA1]::Create()
    try {
        $header = [Text.Encoding]::ASCII.GetBytes(('blob ' + $stream.Length))
        $headerWithNull = New-Object byte[] ($header.Length + 1)
        [Array]::Copy($header, $headerWithNull, $header.Length)
        [void]$sha.TransformBlock($headerWithNull, 0, $headerWithNull.Length, $headerWithNull, 0)
        $buffer = New-Object byte[] 65536
        while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            [void]$sha.TransformBlock($buffer, 0, $count, $buffer, 0)
        }
        $empty = New-Object byte[] 0
        [void]$sha.TransformFinalBlock($empty, 0, 0)
        $actual = ([BitConverter]::ToString($sha.Hash) -replace '-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
    if ($actual -cne $ExpectedBlobId) { throw 'launcher bytes differ from the approved Git blob' }
    [Console]::Out.WriteLine('PINNED')
    [Console]::Out.Flush()
    if ([Console]::In.ReadLine() -cne 'release') { throw 'launcher pin release was not authenticated' }
} finally { $stream.Dispose() }
