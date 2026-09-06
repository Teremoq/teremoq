# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Activate','Confirm','Rollback','Resolve')][string]$Action,
    [Parameter(Mandatory = $true)][string]$StateRoot
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot 'Client-Distribution.ps1')
. (Join-Path $PSScriptRoot 'Client-Slot-State.ps1')

$result = switch ($Action) {
    'Activate' { Activate-TeremoqLanClientSlot -StateRoot $StateRoot }
    'Confirm' { Confirm-TeremoqLanClientSlot -StateRoot $StateRoot }
    'Rollback' { Rollback-TeremoqLanClientSlot -StateRoot $StateRoot }
    'Resolve' { Get-TeremoqActiveLanClientSlot -StateRoot $StateRoot }
}
$result | ConvertTo-Json -Compress -Depth 4
