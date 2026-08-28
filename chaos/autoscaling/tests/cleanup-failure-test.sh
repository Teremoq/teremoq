#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
umask 077

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${TEST_DIR}/.." && pwd -P)"
scratch="$(mktemp -d /tmp/teremoq-autoscaling-cleanup-test.XXXXXX)"
trap 'rm -rf -- "${scratch}"' EXIT

set +e
TEREMOQ_AUTOSCALING_REPORT_DIR="${scratch}" \
    TEREMOQ_AUTOSCALING_INJECT_FAILURE_AFTER_START=1 \
    timeout 120 "${ROOT}/run.sh" --profile 10 --mode simulate --compose \
    --control-replicas 1 >/dev/null 2>&1
status=$?
set -e
(( status != 0 && status != 124 )) || {
    printf 'autoscaling-cleanup-failure-test: expected bounded harness failure\n' >&2
    exit 1
}

report="$(find "${scratch}" -maxdepth 1 -type f -name '*.md')"
[[ -f "${report}" ]]
run_id="$(sed -n 's/^- Run ID: `\([^`]*\)`.*/\1/p' "${report}")"
[[ -n "${run_id}" ]]
grep -Fq -- '- Result: `fail`' "${report}"
grep -Fq '"event":"injected_harness_failure"' "${report}"
grep -Fq 'Cleanup: `true`; containers `0`; networks `0`; volumes `0`.' "${report}"
[[ "$(docker ps -aq --filter "label=teremoq.run-id=${run_id}" | wc -l)" -eq 0 ]]
[[ "$(docker network ls -q --filter "label=teremoq.run-id=${run_id}" | wc -l)" -eq 0 ]]
[[ "$(docker volume ls -q --filter "label=teremoq.run-id=${run_id}" | wc -l)" -eq 0 ]]
printf 'autoscaling-cleanup-failure-test: pass\n'
