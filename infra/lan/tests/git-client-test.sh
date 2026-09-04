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
scratch="$(mktemp -d /tmp/teremoq-lan-git.XXXXXX)"
trap 'rm -rf -- "${scratch}"' EXIT
bare="${scratch}/origin.git"; seed="${scratch}/seed"; clone="${scratch}/clone"; outside="${scratch}/outside"
git init --bare --initial-branch lan-test "${bare}" >/dev/null
git clone "${bare}" "${seed}" >/dev/null 2>&1
git -C "${seed}" config user.name test; git -C "${seed}" config user.email test@example.invalid
printf 'one\n' >"${seed}/tracked"; git -C "${seed}" add tracked; git -C "${seed}" commit -m one >/dev/null; git -C "${seed}" push origin lan-test >/dev/null
# The test stays offline.  This is the exact insteadOf shape used by the native
# runner when Git for Windows is present; it maps the approved URL to this bare remote.
git -c "url.file://${bare}.insteadOf=https://github.com/Teremoq/teremoq" clone --branch lan-test https://github.com/Teremoq/teremoq "${clone}" >/dev/null
git -C "${clone}" config "url.file://${bare}.insteadOf" https://github.com/Teremoq/teremoq
first="$(git -C "${clone}" rev-parse HEAD)"; mkdir -p "${outside}"; printf keep >"${outside}/marker"
git -C "${clone}" fetch --no-tags origin refs/heads/lan-test >/dev/null; test "$(git -C "${clone}" rev-parse HEAD)" = "${first}"
printf 'two\n' >>"${seed}/tracked"; git -C "${seed}" commit -am two >/dev/null; git -C "${seed}" push origin lan-test >/dev/null
next="$(git -C "${seed}" rev-parse HEAD)"; git -C "${clone}" fetch --no-tags origin refs/heads/lan-test >/dev/null; git -C "${clone}" merge --ff-only FETCH_HEAD >/dev/null
test "$(git -C "${clone}" rev-parse HEAD)" = "${next}"; test "$(cat "${outside}/marker")" = keep
printf dirty >"${clone}/dirty"; test -n "$(git -C "${clone}" status --porcelain)"; rm -f "${clone}/dirty"
git -C "${clone}" remote set-url origin file:///unexpected; test "$(git -C "${clone}" remote get-url origin)" != https://github.com/Teremoq/teremoq; git -C "${clone}" remote set-url origin https://github.com/Teremoq/teremoq
git -C "${clone}" checkout -q --detach HEAD; test "$(git -C "${clone}" symbolic-ref -q --short HEAD || true)" = ''; git -C "${clone}" checkout -q lan-test
printf 'lan-git-client-test: PASS (offline clone/no-op/ff-only and safety negatives)\n'
