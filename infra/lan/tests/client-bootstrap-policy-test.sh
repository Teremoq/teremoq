#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
bootstrap="${ROOT}/client/INICIAR-CLIENTE-LAN.ps1"

grep -Fq "\$RepositoryUrl = 'https://github.com/Teremoq/teremoq'" "${bootstrap}"
grep -Fq "\$ExpectedCommit = '7d19febedd91bfa30f58a577865bbd6b5b8b3f7a'" "${bootstrap}"
grep -Fq "\$ServerIPv4 = '192.168.1.130'" "${bootstrap}"
grep -Fq "\$ClientIPv4 = '192.168.1.139'" "${bootstrap}"
grep -Fq 'Este iniciador es exclusivamente para el portatil cliente' "${bootstrap}"
grep -Fq 'El iniciador del cliente no puede ejecutarse en el servidor' "${bootstrap}"
grep -Fq "@('fetch', '--quiet', '--no-tags', 'origin'" "${bootstrap}"
grep -Fq "@('merge-base', '--is-ancestor', \$ExpectedCommit, \$remoteTip)" "${bootstrap}"
grep -Fq "@('checkout', '--quiet', '-b', \$Branch, \$ExpectedCommit)" "${bootstrap}"
grep -Fq "@('status', '--porcelain=v1', '--untracked-files=all')" "${bootstrap}"
grep -Fq "\$env:GIT_CONFIG_NOSYSTEM = '1'" "${bootstrap}"
grep -Fq "'core.hooksPath' = \$disabledGitPath" "${bootstrap}"
grep -Fq "\$env:GIT_TERMINAL_PROMPT = '0'" "${bootstrap}"
grep -Fq "\$env:GIT_NO_REPLACE_OBJECTS = '1'" "${bootstrap}"
grep -Fq '& $script:GitExecutable --no-replace-objects' "${bootstrap}"
grep -Fq "'refs/replace'" "${bootstrap}"
grep -Fq "'teremoq-bootstrap-claim'" "${bootstrap}"
grep -Fq 'Assert-LockedHandlePath -Stream $checkoutClaimStream' "${bootstrap}"
grep -Fq 'GetFinalPathNameByHandle' "${bootstrap}"
grep -Fq 'Get-LockedGitBlobId -Stream $stream' "${bootstrap}"
grep -Fq 'Open-VerifiedCommitFiles -CheckoutRoot $checkoutRoot -Commit $ExpectedCommit' "${bootstrap}"
grep -Fq 'El checkout cambio mientras se bloqueaban los archivos aprobados' "${bootstrap}"
grep -Fq 'Get-ProcessEnvironmentSnapshot' "${bootstrap}"
grep -Fq 'Restore-ProcessEnvironment -Snapshot $environmentSnapshot' "${bootstrap}"
grep -Fq "'.bootstrap-lock-'" "${bootstrap}"
grep -Fq 'Assert-LockedHandlePath -Stream $rootLockStream' "${bootstrap}"
if grep -Fq '[IO.Directory]::Move(' "${bootstrap}"; then
    printf 'client-bootstrap-policy-test: checkout publication must not move unlocked trees\n' >&2
    exit 1
fi
grep -Fq '[IO.FileMode]::CreateNew' "${bootstrap}"
grep -Fq 'Prepare-LanClientFromGit.ps1' "${bootstrap}"
grep -Fq 'Verify-Package.ps1' "${bootstrap}"
grep -Fq 'Preflight-Client.ps1' "${bootstrap}"

if grep -Eiq 'gmail|correo|usb|invoke-webrequest|curl\.exe|wsl\.exe|netsh|firewall|remove-item|private.?key|password|capability' "${bootstrap}"; then
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
    fixture="$ROOT/tests/client-bootstrap-primitives-fixture.ps1"
    expected_blob="$(git -C "$ROOT/../.." rev-parse \
        7d19febedd91bfa30f58a577865bbd6b5b8b3f7a:supervisor-web/package.json)"
    bootstrap_path="$(wslpath -w "$bootstrap")"
    fixture_path="$(wslpath -w "$fixture")"
    blob_path="$(wslpath -w "$ROOT/../../supervisor-web/package.json")"
    TEREMOQ_BOOTSTRAP_PATH="$bootstrap_path" \
    TEREMOQ_FIXTURE_PATH="$fixture_path" \
    TEREMOQ_BLOB_PATH="$blob_path" \
    TEREMOQ_EXPECTED_BLOB="$expected_blob" \
    WSLENV="TEREMOQ_BOOTSTRAP_PATH:TEREMOQ_FIXTURE_PATH:TEREMOQ_BLOB_PATH:TEREMOQ_EXPECTED_BLOB" \
        powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
        -File "$fixture_path" \
        -BootstrapPath "$bootstrap_path" \
        -BlobPath "$blob_path" \
        -ExpectedBlob "$expected_blob"
fi

printf 'client-bootstrap-policy-test: pass\n'
