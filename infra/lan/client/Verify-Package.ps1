# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CheckoutRoot,
    [Parameter(Mandatory = $true)][string]$StateRoot
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot 'Client-Distribution.ps1')

$state = Get-TeremoqLanStateContext -StateRoot $StateRoot
$checkout = Get-TeremoqGitCheckoutContext -CheckoutRoot $CheckoutRoot -StateContext $state -RequireExactHead

Write-Output ("Teremoq LAN Git checkout and external client state are valid for commit {0}; no trust was installed and no network action was performed." -f $checkout.Head)
