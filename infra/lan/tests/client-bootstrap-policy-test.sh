#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
bootstrap="${ROOT}/client/Start-LanClientFromGit.ps1"
compatibility_launcher="${ROOT}/client/INICIAR-CLIENTE-LAN.ps1"
interactive_launcher="${ROOT}/client/Start-LanInteractiveClient.ps1"

grep -Fq "\$RepositoryUrl = 'https://github.com/Teremoq/teremoq'" "${bootstrap}"
grep -Fq '[Parameter(Mandatory = $true)][string]$ExpectedCommit' "${bootstrap}"
grep -Fq '[Parameter(Mandatory = $true)][string]$ChannelCommit' "${bootstrap}"
grep -Fq "'fetch','--no-tags','origin',\$RepositoryRef" "${bootstrap}"
grep -Fq "'merge-base', '--is-ancestor', 'HEAD', \$ExpectedCommit" "${bootstrap}"
grep -Fq "'merge', '--ff-only', \$ExpectedCommit" "${bootstrap}"
grep -Fq "'status', '--porcelain=v1', '--untracked-files=all'" "${bootstrap}"
grep -Fq '& $script:Git --no-replace-objects' "${bootstrap}"
grep -Fq "\$env:GIT_CONFIG_NOSYSTEM = '1'" "${bootstrap}"
grep -Fq "\$env:GIT_CONFIG_GLOBAL = 'NUL'" "${bootstrap}"
grep -Fq -- '-c core.attributesFile=NUL' "${bootstrap}"
grep -Fq 'Se conserva sin modificar el checkout no reutilizable' "${bootstrap}"
grep -Fq 'The selected Git checkout failed final validation:' "${bootstrap}"
grep -Fq "'channel-core-' + \$version" "${bootstrap}"
grep -Fq -- '-WorkCheckout $checkout -ChannelCoreAgentSha256 $channelCore.AgentSha256' "${bootstrap}"
grep -Fq 'Install-TeremoqStableChannelCore -ClientRoot $root -CheckoutRoot $checkout' "${bootstrap}"

grep -Fq "Join-Path \$PSScriptRoot 'Start-LanClientFromGit.ps1'" "${compatibility_launcher}"
grep -Fq -- '-ExpectedCommit $ExpectedCommit -ChannelCommit $ChannelCommit' "${compatibility_launcher}"
grep -Fq 'Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }' "${interactive_launcher}"
grep -Fq 'The Git checkout failed validation:' "${interactive_launcher}"

if grep -Eiq 'gmail|correo|usb|invoke-webrequest|curl\.exe|wsl\.exe|netsh|firewall|remove-item|private.?key|password|capability|reset[[:space:]]+--hard|clean[[:space:]]+-f' "${bootstrap}"; then
    printf 'client-bootstrap-policy-test: prohibited transport, mutation, or secret term found\n' >&2
    exit 1
fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
git -C "$scratch" init --quiet
git -C "$scratch" config user.name 'Teremoq Test'
git -C "$scratch" config user.email 'test@example.invalid'
printf 'approved\n' >"$scratch/contract.txt"
git -C "$scratch" add contract.txt
git -C "$scratch" commit --quiet -m approved
approved_commit="$(git -C "$scratch" rev-parse HEAD)"
approved_blob="$(git -C "$scratch" rev-parse "$approved_commit:contract.txt")"
printf 'replacement\n' >"$scratch/contract.txt"
git -C "$scratch" commit --quiet -am replacement
replacement_commit="$(git -C "$scratch" rev-parse HEAD)"
git -C "$scratch" replace "$approved_commit" "$replacement_commit"
replaced_blob="$(git -C "$scratch" rev-parse "$approved_commit:contract.txt")"
isolated_blob="$(GIT_NO_REPLACE_OBJECTS=1 git --no-replace-objects -C "$scratch" rev-parse "$approved_commit:contract.txt")"
if [[ "$replaced_blob" == "$approved_blob" || "$isolated_blob" != "$approved_blob" ]]; then
    printf 'client-bootstrap-policy-test: Git replace isolation canary failed\n' >&2
    exit 1
fi

if command -v powershell.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
    bootstrap_path="$(wslpath -w "$bootstrap")"
    fixture_path="$(wslpath -w "$ROOT/tests/client-start-bootstrap-fixture.ps1")"
    TEREMOQ_BOOTSTRAP_PATH="$bootstrap_path" \
    TEREMOQ_FIXTURE_PATH="$fixture_path" \
    WSLENV='TEREMOQ_BOOTSTRAP_PATH:TEREMOQ_FIXTURE_PATH' \
        powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \
        '$env:WSL_INTEROP=$null; $env:WSL_DISTRO_NAME=$null; & $env:TEREMOQ_FIXTURE_PATH -ScriptPath $env:TEREMOQ_BOOTSTRAP_PATH'
fi

printf 'client-bootstrap-policy-test: pass\n'
