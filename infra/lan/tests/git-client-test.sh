#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${TEST_DIR}/../../.." && pwd -P)"
runner="${TEST_DIR}/Run-GitClientE2E.ps1"
stage_runner="${TEST_DIR}/Run-StageUpdateE2E.ps1"
for path in "${ROOT}/infra/lan/client/Install-LanClient.ps1" "${ROOT}/infra/lan/client/Update-LanClient.ps1" "${runner}"; do test -f "${path}"; done

# Always run the PS5 API regression, including hosts without Git for Windows.
# This is static evidence only, never a substitute for the native argv test.
if rg -n '^\s*\$[A-Za-z0-9_]+\.ArgumentList\b' "${ROOT}/infra/lan/client"/*.ps1 >/dev/null; then
    printf 'lan-git-client-test: incompatible ProcessStartInfo.ArgumentList API\n' >&2
    exit 1
fi
printf 'lan-git-client-test: static PS5 ArgumentList exclusion PASS\n'

git_exe="${TEREMOQ_TEST_GIT_EXE:-}"
if [[ -z "${git_exe}" ]]; then
    for candidate in "/mnt/c/Program Files/Git/cmd/git.exe" "/mnt/c/Program Files/Git/bin/git.exe" "/mnt/c/Users/${USERNAME:-Lenovo}/AppData/Local/Programs/Git/cmd/git.exe"; do
        if [[ -f "${candidate}" ]]; then git_exe="${candidate}"; break; fi
    done
fi
if [[ -z "${git_exe}" || ! -f "${git_exe}" ]]; then
    printf 'lan-git-client-test: WARNING (Git for Windows unavailable; native E2E not executed)\n'
    exit 0
fi

runner_win="$(wslpath -w "${runner}")"
root_win="$(wslpath -w "${ROOT}")"
git_win="$(wslpath -w "${git_exe}")"
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${runner_win}" -SourceRoot "${root_win}" -GitExecutable "${git_win}"
stage_runner_win="$(wslpath -w "${stage_runner}")"
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${stage_runner_win}" -SourceRoot "${root_win}" -GitExecutable "${git_win}"
printf 'lan-git-client-test: PASS (Windows PowerShell 5 and Git for Windows)\n'
