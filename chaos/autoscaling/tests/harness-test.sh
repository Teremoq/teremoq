#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
umask 077

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${TEST_DIR}/.." && pwd -P)"
scratch="$(mktemp -d /tmp/teremoq-autoscaling-test.XXXXXX)"
trap 'rm -rf -- "${scratch}"' EXIT

fail() {
    printf 'autoscaling-harness-test: %s\n' "$*" >&2
    exit 1
}

for profile in 10 25 50 100; do
    report_dir="${scratch}/reports-${profile}"
    mkdir -p -- "${report_dir}"
    TEREMOQ_AUTOSCALING_REPORT_DIR="${report_dir}" \
        timeout 30 "${ROOT}/run.sh" --profile "${profile}" --mode simulate >/dev/null
    mapfile -t reports < <(find "${report_dir}" -maxdepth 1 -type f -name '*.md')
    (( ${#reports[@]} == 1 )) || fail "profile ${profile} did not create one report"
    report="${reports[0]}"
    grep -Fq -- '- Result: `pass`' "${report}" || fail "profile ${profile} failed"
    grep -Fq "Requested and consumed simulated viewers: \`${profile}\` / \`${profile}\`" "${report}" || \
        fail "profile ${profile} was not consumed"
    grep -Fq '| Simulated lost sessions | 0 |' "${report}" || fail "profile ${profile} lost sessions"
    grep -Fq 'Cleanup: `true`; containers `0`; networks `0`; volumes `0`.' "${report}" || \
        fail "profile ${profile} cleanup failed"
    for event in node_unhealthy sessions_reassigned drain_complete rollback_complete simulation_complete; do
        grep -Fq "\"event\":\"${event}\"" "${report}" || fail "profile ${profile} missed ${event}"
    done
    if (( profile >= 50 )); then
        grep -Fq '"event":"capacity_configuration_requested"' "${report}" || \
            fail "profile ${profile} did not request a capacity configuration change"
    fi
done

dry_dir="${scratch}/dry-run"
mkdir -p -- "${dry_dir}"
TEREMOQ_AUTOSCALING_REPORT_DIR="${dry_dir}" \
    timeout 30 "${ROOT}/run.sh" --profile 100 --mode dry-run >/dev/null
dry_report="$(find "${dry_dir}" -maxdepth 1 -type f -name '*.md')"
grep -Fq '"event":"dry_run_complete"' "${dry_report}" || fail 'dry-run event missing'
grep -Fq -- '- Result: `pass`' "${dry_report}" || fail 'dry-run failed'

replica_dir="${scratch}/replicas"
mkdir -p -- "${replica_dir}"
TEREMOQ_AUTOSCALING_REPORT_DIR="${replica_dir}" \
    TEREMOQ_AUTOSCALING_MAX_CONTROL_REPLICAS=4 \
    timeout 30 "${ROOT}/run.sh" --profile 10 --mode simulate \
    --control-replicas 4 >/dev/null
replica_report="$(find "${replica_dir}" -maxdepth 1 -type f -name '*.md')"
grep -Fq 'Control replicas requested/observed: `4` / `4`' "${replica_report}" || \
    fail 'unique simulated control replica count did not match'
for control_node in control control-r2 control-r3 control-r4; do
    grep -Fq "\"node_id\":\"${control_node}\"" "${replica_report}" || \
        fail "missing unique simulated identity ${control_node}"
done

if TEREMOQ_AUTOSCALING_REPORT_DIR="${scratch}/invalid-replicas" \
    TEREMOQ_AUTOSCALING_MAX_CONTROL_REPLICAS=3 \
    "${ROOT}/run.sh" --profile 10 --control-replicas 4 >/dev/null 2>&1; then
    fail 'run accepted a control replica count above its configured safety ceiling'
fi
printf 'autoscaling-harness-test: pass\n'
