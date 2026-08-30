# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Plan', 'RollbackPlan')][string]$Action,
    [Parameter(Mandatory = $true)][string]$RunId
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
if ($RunId -notmatch '^lan-[a-z0-9][a-z0-9-]{0,31}$') { throw 'invalid RunId' }
$path = Join-Path $env:USERPROFILE '.wslconfig'
$backup = Join-Path $env:USERPROFILE ".wslconfig.teremoq-$RunId.bak"
$marker = Join-Path $env:USERPROFILE ".wslconfig.teremoq-$RunId.marker"
if ($Action -eq 'Plan') {
    Write-Output "# Requires elevation review and an explicit maintenance window. Not executed by this script."
    Write-Output "if (Test-Path -LiteralPath '$path') { throw 'Refuse to overwrite existing .wslconfig; review/merge manually' }"
    Write-Output ("Set-Content -LiteralPath '{0}' -Value `"[wsl2]``r``nnetworkingMode=mirrored``r``n`" -NoNewline -Encoding ASCII" -f $path)
    Write-Output "Set-Content -LiteralPath '$marker' -Value '$RunId' -NoNewline -Encoding ASCII"
    Write-Output "wsl.exe --shutdown"
    Write-Output "# Re-run Windows and WSL preflights; NAT must no longer be reported before firewall Apply."
    exit 0
}
Write-Output "if ((Get-Content -LiteralPath '$marker' -Raw -ErrorAction Stop) -ne '$RunId') { throw 'mirrored marker mismatch' }"
Write-Output "Remove-Item -LiteralPath '$path' -Force"
Write-Output "Remove-Item -LiteralPath '$marker' -Force"
Write-Output "if (Test-Path -LiteralPath '$backup') { Move-Item -LiteralPath '$backup' -Destination '$path' }"
Write-Output "wsl.exe --shutdown"
Write-Output "# Verify NAT restoration and remove only the exact classic/Hyper-V firewall rule names separately."
