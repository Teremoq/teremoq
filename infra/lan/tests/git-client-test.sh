#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${TEST_DIR}/.." && pwd -P)"
runner="${TEST_DIR}/Run-GitClientE2E.ps1"
for path in "${ROOT}/client/Install-LanClient.ps1" "${ROOT}/client/Initialize-LanClientState.ps1" "${ROOT}/client/Verify-Package.ps1" "${ROOT}/client/Update-LanClient.ps1" "${runner}"; do test -f "${path}"; done
if rg -n -- '--certificate|-StateRoot.*Install-LanClient|package-client' "${runner}"; then
    printf 'lan-git-client-test: obsolete package/Install API in native runner\n' >&2; exit 1
fi
if ! command -v powershell.exe >/dev/null 2>&1 || ! powershell.exe -NoProfile -NonInteractive -Command '$g=Get-Command git.exe -ErrorAction SilentlyContinue; if(!$g){exit 1}' >/dev/null 2>&1; then
    printf 'lan-git-client-test: SKIP (Git for Windows unavailable; native E2E fixture validated but not executed)\n'
    exit 0
fi
# The actual runner needs the approved repository/ref/commit and Web Node/npm
# environment; it is deliberately not pointed at a synthetic or remote host here.
printf 'lan-git-client-test: BLOCKED (supply approved local fixture inputs; do not treat as PASS)\n' >&2
exit 2
