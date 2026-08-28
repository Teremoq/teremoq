#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
umask 077

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${TEST_DIR}/.." && pwd -P)"
REPO_ROOT="$(cd -- "${ROOT}/../.." && pwd -P)"
CONTROL_REPO="${TEREMOQ_CONTROL_REPO:-${REPO_ROOT}}"
scratch="$(mktemp -d /tmp/teremoq-integrated-cleanup-test.XXXXXX)"
trap 'find "${scratch}" -depth -delete' EXIT

set +e
TEREMOQ_CONTROL_REPO="${CONTROL_REPO}" TEREMOQ_AUTOSCALING_REPORT_DIR="${scratch}" \
    TEREMOQ_INTEGRATED_INJECT_FAILURE_AFTER_BOOTSTRAP=1 \
    timeout 180 "${ROOT}/run-integrated.sh" --mode simulate --docker --viewers 100 \
    >/dev/null 2>&1
status=$?
set -e
(( status != 0 && status != 124 )) || {
    printf 'integrated-cleanup-failure-test: expected a bounded injected failure\n' >&2
    exit 1
}
report="$(find "${scratch}" -maxdepth 1 -type f -name '*.md')"
[[ -f "${report}" ]]
run_id="$(sed -n 's/^- Run ID: `\([^`]*\)`.*/\1/p' "${report}")"
[[ -n "${run_id}" ]]
grep -Fq -- '- Result: `fail`' "${report}"
grep -Fq '"event":"injected_integrated_failure"' "${report}"
grep -Fq 'Cleanup: `true`; containers `0`; networks `0`; volumes `0`' "${report}"
[[ "$(docker ps -aq --filter "label=teremoq.run-id=${run_id}" | wc -l)" -eq 0 ]]
[[ "$(docker network ls -q --filter "label=teremoq.run-id=${run_id}" | wc -l)" -eq 0 ]]
[[ "$(docker volume ls -q --filter "label=teremoq.run-id=${run_id}" | wc -l)" -eq 0 ]]
printf 'integrated-cleanup-failure-test: pass\n'
