# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ExpectedCommit,
    [Parameter(Mandatory = $true)][string]$ChannelCommit
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$bootstrap = Join-Path $PSScriptRoot 'Start-LanClientFromGit.ps1'
if (-not (Test-Path -LiteralPath $bootstrap -PathType Leaf)) {
    throw 'The reviewed Git bootstrap is missing from this checkout'
}

& $bootstrap -ExpectedCommit $ExpectedCommit -ChannelCommit $ChannelCommit
