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
grep -Fq "'core.hooksPath' = \$emptyHooks" "${bootstrap}"
grep -Fq "\$env:GIT_TERMINAL_PROMPT = '0'" "${bootstrap}"
grep -Fq '[IO.Directory]::Move($stagingCheckout, $checkoutRoot)' "${bootstrap}"
grep -Fq '[IO.FileMode]::CreateNew' "${bootstrap}"
grep -Fq 'Prepare-LanClientFromGit.ps1' "${bootstrap}"
grep -Fq 'Verify-Package.ps1' "${bootstrap}"
grep -Fq 'Preflight-Client.ps1' "${bootstrap}"

if grep -Eiq 'gmail|correo|usb|invoke-webrequest|curl\.exe|wsl\.exe|netsh|firewall|remove-item|private.?key|password|capability' "${bootstrap}"; then
    printf 'client-bootstrap-policy-test: prohibited transport, mutation, or secret term found\n' >&2
    exit 1
fi

printf 'client-bootstrap-policy-test: pass\n'
