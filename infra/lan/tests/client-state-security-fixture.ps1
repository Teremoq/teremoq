# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ScriptPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. $ScriptPath
$root = Join-Path ([IO.Path]::GetTempPath()) ('teremoq-client-state-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
try {
    $generation = Join-Path $root 'generation.tsv'
    [IO.File]::WriteAllText($generation, "schema_version`t1`n", (New-Object Text.UTF8Encoding($false)))
    foreach ($content in @('', "schema_version`t1`nunknown`tx`n", "schema_version`t1`nschema_version`t1`n")) {
        [IO.File]::WriteAllText($generation, $content, (New-Object Text.UTF8Encoding($false)))
        try { Read-TeremoqClosedTsv -Path $generation -MaxBytes 256 -AllowedKeys @('schema_version') -Label 'fixture' | Out-Null; throw 'invalid generation TSV accepted' } catch { if ($_.Exception.Message -match 'invalid generation TSV accepted') { throw } }
    }
    [IO.File]::WriteAllText($generation, "schema_version`t1`n", (New-Object Text.UTF8Encoding($false)))
    $stream = New-Object IO.FileStream($generation, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        $denied = $false
        try { [IO.File]::WriteAllText($generation, "schema_version`t2`n") } catch [IO.IOException] { $denied = $true }
        if (-not $denied) { throw 'exclusive state reader allowed replacement' }
    } finally { $stream.Dispose() }
    # Every producer-side binding is parsed through the same exclusive reader;
    # a writer cannot replace generation, manifest, or launcher mid-validation.
    foreach ($name in @('generation.tsv', 'MANIFEST.sha256.json', 'lan-launcher.tsv')) {
        $path = Join-Path $root $name
        [IO.File]::WriteAllText($path, "x`n", (New-Object Text.UTF8Encoding($false)))
        $handle = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try {
            $replaced = $false
            try { [IO.File]::Move($path, ($path + '.replacement')) } catch [IO.IOException] { $replaced = $true }
            if (-not $replaced) { throw "replacement during $name validation was accepted" }
        } finally { $handle.Dispose() }
    }
    $target = Join-Path $root 'target'
    $alias = Join-Path $root 'alias'
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    New-Item -ItemType Junction -Path $alias -Target $target -ErrorAction Stop | Out-Null
    if (-not (Test-Path -LiteralPath $alias -PathType Container)) { throw 'junction fixture could not be created' }
    try { Get-TeremoqNonReparseDirectoryPath -Path $alias | Out-Null; throw 'junction parent accepted' } catch { if ($_.Exception.Message -match 'junction parent accepted') { throw } }
    $nested = Join-Path $root 'nested'
    New-Item -ItemType Directory -Path $nested -Force | Out-Null
    $nestedAlias = Join-Path $nested 'generation-link'
    New-Item -ItemType Junction -Path $nestedAlias -Target $target -ErrorAction Stop | Out-Null
    try { Get-TeremoqNonReparseDirectoryPath -Path $nestedAlias | Out-Null; throw 'intermediate junction accepted' } catch { if ($_.Exception.Message -match 'intermediate junction accepted') { throw } }
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
