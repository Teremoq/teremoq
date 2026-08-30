#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
umask 077

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${TEST_DIR}/.." && pwd -P)"
source "${TEST_DIR}/test-lib.sh"
scratch="$(mktemp -d /tmp/teremoq-lan-cleanup-test.XXXXXX)"
trap 'find "${scratch}" -depth -delete' EXIT
config="${scratch}/config.tsv"
commit="$(printf 'a%.0s' {1..40})"
make_lan_config "${ROOT}/config/lan.example.tsv" "${config}" "${scratch}" "${commit}"
state_dir="/tmp/teremoq-lan-runtime-test-$$-${RANDOM}"
"${ROOT}/prepare-runtime.sh" --config "${config}" --state-dir "${state_dir}" >/dev/null
[[ -f "${state_dir}/run-id" && -f "${state_dir}/activation-status" ]]
"${ROOT}/rollback-runtime.sh" --config "${config}" --state-dir "${state_dir}" >/dev/null
[[ ! -e "${state_dir}" ]]
"${ROOT}/rollback-runtime.sh" --config "${config}" --state-dir "${state_dir}" >/dev/null
[[ ! -e "${state_dir}" ]]
ready_config="${scratch}/ready-config.tsv"
owner_commit=2f8fb1b3219483050bc997bee25a052c2db5f463
make_lan_config "${ROOT}/config/lan.example.tsv" "${ready_config}" "${scratch}" "${commit}" ready "${owner_commit}"
ready_state="/tmp/teremoq-lan-runtime-capability-test-$$-${RANDOM}"
"${ROOT}/prepare-runtime.sh" --config "${ready_config}" --state-dir "${ready_state}" >/dev/null
[[ -f "${ready_state}/publish-capability" && ! -L "${ready_state}/publish-capability" ]]
[[ "$(stat -c '%a' "${ready_state}/publish-capability")" == 600 ]]
[[ "$(wc -c <"${ready_state}/publish-capability")" == 65 ]]
grep -Fq $'run_id\tlan-policy-test' "${ready_state}/publish-capability.metadata.tsv"
grep -Eq $'^capability_sha256\t[0-9a-f]{64}$' "${ready_state}/publish-capability.metadata.tsv"
"${ROOT}/rollback-runtime.sh" --config "${ready_config}" --state-dir "${ready_state}" >/dev/null
[[ ! -e "${ready_state}" ]]
live_state="/tmp/teremoq-lan-runtime-live-test-$$-${RANDOM}"
"${ROOT}/prepare-runtime.sh" --config "${config}" --state-dir "${live_state}" >/dev/null
printf '%s\n' "$$" >"${live_state}/lab.pid"
if "${ROOT}/rollback-runtime.sh" --config "${config}" --state-dir "${live_state}" >/dev/null 2>&1; then
    printf 'runtime-cleanup-test: removed state for a live process\n' >&2; exit 1
fi
[[ -d "${live_state}" ]]
mv -- "${live_state}/lab.pid" "${scratch}/live-lab.pid"
"${ROOT}/rollback-runtime.sh" --config "${config}" --state-dir "${live_state}" >/dev/null
foreign_state="/tmp/teremoq-lan-runtime-foreign-test-$$-${RANDOM}"
"${ROOT}/prepare-runtime.sh" --config "${config}" --state-dir "${foreign_state}" >/dev/null
printf 'lan-foreign\n' >"${foreign_state}/run-id"
if "${ROOT}/rollback-runtime.sh" --config "${config}" --state-dir "${foreign_state}" >/dev/null 2>&1; then
    printf 'runtime-cleanup-test: removed foreign run state\n' >&2; exit 1
fi
[[ -d "${foreign_state}" ]]
printf '%s\n' 'lan-policy-test' >"${foreign_state}/run-id"
"${ROOT}/rollback-runtime.sh" --config "${config}" --state-dir "${foreign_state}" >/dev/null
printf 'lan-runtime-cleanup-test: pass\n'
