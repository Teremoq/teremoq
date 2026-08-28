#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
umask 077

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${TEST_DIR}/.." && pwd -P)"
REPO_ROOT="$(cd -- "${ROOT}/../.." && pwd -P)"
CONTROL_REPO="${TEREMOQ_CONTROL_REPO:-${REPO_ROOT}}"
scratch="$(mktemp -d /tmp/teremoq-integrated-compose-test.XXXXXX)"
trap 'find "${scratch}" -depth -delete' EXIT

fail() {
    printf 'integrated-compose-test: %s\n' "$*" >&2
    exit 1
}

TEREMOQ_CONTROL_REPO="${CONTROL_REPO}" TEREMOQ_AUTOSCALING_REPORT_DIR="${scratch}" \
    timeout 180 "${ROOT}/run-integrated.sh" --mode simulate --docker --viewers 100 >/dev/null
report="$(find "${scratch}" -maxdepth 1 -type f -name '*.md')"
[[ -f "${report}" ]] || fail 'integrated run did not produce a report'
run_id="$(sed -n 's/^- Run ID: `\([^`]*\)`.*/\1/p' "${report}")"
[[ -n "${run_id}" ]] || fail 'report has no run id'
grep -Fq -- '- Result: `pass`' "${report}" || fail 'integrated run failed'
grep -Fq 'Requested/consumed simulated viewers: `100` / `100`' "${report}" || \
    fail 'milestone viewer gate was not consumed'
grep -Fq '| Containers after control/bootstrap/scale-out/replacement | 1/3/4/4 |' "${report}" || \
    fail 'progressive topology did not create the second core from its action'
grep -Fq '| Unique/planned actions consumed | 8 |' "${report}" || \
    fail 'unexpected unique action count'
grep -Fq '| Create actions consumed | 4 |' "${report}" || fail 'unexpected create count'
grep -Fq '| Destroy actions consumed | 4 |' "${report}" || fail 'unexpected destroy count'
grep -Fq '| Sessions after replacement | 100 |' "${report}" || fail 'assignment recovery mismatch'
grep -Fq '| Simulated lost sessions | 0 |' "${report}" || fail 'simulated sessions were lost'
grep -Fq '"reason":"destroy_requires_drain_ack"' "${report}" || \
    fail 'destroy-before-drain did not expose the lifecycle reason'
grep -Fq 'Desired image identifier (Task 09 fixture)' "${report}" || \
    fail 'desired fixture identifier was not reported separately'
grep -Fq 'Mapped simulator runtime OCI' "${report}" || \
    fail 'mapped runtime OCI was not reported separately'
grep -Fq 'Cleanup: `true`; containers `0`; networks `0`; volumes `0`; provider nodes before ephemeral-root removal `0`.' "${report}" || \
    fail 'integrated cleanup was incomplete'
[[ "$(docker ps -aq --filter "label=teremoq.run-id=${run_id}" | wc -l)" -eq 0 ]] || \
    fail 'run-labelled container residue'
[[ "$(docker network ls -q --filter "label=teremoq.run-id=${run_id}" | wc -l)" -eq 0 ]] || \
    fail 'run-labelled network residue'
[[ "$(docker volume ls -q --filter "label=teremoq.run-id=${run_id}" | wc -l)" -eq 0 ]] || \
    fail 'run-labelled volume residue'
printf 'integrated-compose-test: pass\n'
