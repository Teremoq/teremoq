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
grep -Fq "@('clone', '--quiet', '--origin', 'origin', '--branch', \$Branch, '--single-branch', '--no-tags'" "${bootstrap}"
grep -Fq 'status --porcelain=v1 --untracked-files=all' "${bootstrap}"
grep -Fq 'Prepare-LanClientFromGit.ps1' "${bootstrap}"
grep -Fq 'Verify-Package.ps1' "${bootstrap}"
grep -Fq 'Preflight-Client.ps1' "${bootstrap}"

if grep -Eiq 'gmail|correo|usb|invoke-webrequest|curl\.exe|wsl\.exe|netsh|firewall|remove-item|private.?key|password|credential|capability' "${bootstrap}"; then
    printf 'client-bootstrap-policy-test: prohibited transport, mutation, or secret term found\n' >&2
    exit 1
fi

printf 'client-bootstrap-policy-test: pass\n'
