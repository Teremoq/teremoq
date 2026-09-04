# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$AllowMissingLeaf
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

if (-not [IO.Path]::IsPathRooted($Path) -or $Path -match "[`r`n]") {
    throw 'path policy requires one absolute path'
}

if (-not ('TeremoqPathHandle' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class TeremoqPathHandle {
    private const uint ShareRead = 0x00000001;
    private const uint ShareWrite = 0x00000002;
    private const uint ShareDelete = 0x00000004;
    private const uint OpenExisting = 3;
    private const uint BackupSemantics = 0x02000000;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string name, uint access, uint share, IntPtr security,
        uint creation, uint flags, IntPtr template);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(
        SafeFileHandle handle, StringBuilder path, uint length, uint flags);

    public static string ResolveDirectory(string path) {
        using (SafeFileHandle handle = CreateFileW(
            path, 0, ShareRead | ShareWrite | ShareDelete, IntPtr.Zero,
            OpenExisting, BackupSemantics, IntPtr.Zero)) {
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            StringBuilder output = new StringBuilder(32768);
            uint length = GetFinalPathNameByHandleW(handle, output, (uint)output.Capacity, 0);
            if (length == 0 || length >= output.Capacity) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            string value = output.ToString();
            if (value.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) {
                return @"\\" + value.Substring(8);
            }
            if (value.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase)) {
                return value.Substring(4);
            }
            return value;
        }
    }
}
'@
}

function Get-NormalizedPath([string]$Value) {
    $full = [IO.Path]::GetFullPath($Value)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { return $full.TrimEnd('\') }
    return $full
}

$canonical = Get-NormalizedPath $Path
$existing = $canonical
while (-not (Test-Path -LiteralPath $existing -PathType Container)) {
    if (-not $AllowMissingLeaf) { throw 'path policy requires an existing directory' }
    $parent = [IO.Directory]::GetParent($existing)
    if ($null -eq $parent) { throw 'path policy found no existing ancestor' }
    $existing = Get-NormalizedPath $parent.FullName
}

$rootPath = [IO.Path]::GetPathRoot($existing)
$current = Get-NormalizedPath $rootPath
$relative = $existing.Substring($rootPath.Length)
$segments = @($relative.Split([IO.Path]::DirectorySeparatorChar) | Where-Object { $_ -ne '' })
$paths = @($current)
foreach ($segment in $segments) {
    $current = Get-NormalizedPath (Join-Path $current $segment)
    $paths += $current
}

foreach ($candidate in $paths) {
    $item = Get-Item -LiteralPath $candidate -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'path policy rejects every reparse-point ancestor'
    }
    $resolved = Get-NormalizedPath ([TeremoqPathHandle]::ResolveDirectory($candidate))
    $expected = Get-NormalizedPath $candidate
    if (-not [string]::Equals($resolved, $expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'path policy handle resolution mismatch'
    }
}

Write-Output $canonical
