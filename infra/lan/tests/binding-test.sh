#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
umask 077

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${TEST_DIR}/.." && pwd -P)"
source "${TEST_DIR}/test-lib.sh"
scratch="$(mktemp -d /tmp/teremoq-lan-binding-test.XXXXXX)"
trap 'find "${scratch}" -depth -delete' EXIT
commit="$(printf 'a%.0s' {1..40})"
pending="${scratch}/pending.tsv"
make_lan_config "${ROOT}/config/lan.example.tsv" "${pending}" "${scratch}" "${commit}"
set +e
"${ROOT}/lab-control.sh" --action start-plan --config "${pending}" >/dev/null 2>&1
status=$?
set -e
(( status == 3 ))
state_dir="/tmp/teremoq-lan-binding-test-$$-${RANDOM}"
"${ROOT}/prepare-runtime.sh" --config "${pending}" --state-dir "${state_dir}" >/dev/null
set +e
start_output="$("${ROOT}/start-lab.sh" --config "${pending}" --commands /absent/commands.json \
    --authorization /absent/authorization.tsv --wsl-preflight /absent/wsl.tsv --server-preflight /absent/server.json \
    --client-preflight /absent/client.json --firewall-attestation /absent/firewall.json \
    --certificate /absent/cert.pem --key /absent/key.pem --fingerprint /absent/fingerprint.sha256 \
    --identity-profile /absent/profile --proxy-attestation /absent/proxy.tsv --artifact-root /absent/artifacts \
    --state-dir "${state_dir}" 2>&1)"
start_status=$?
set -e
(( start_status == 2 ))
grep -Fq 'owner integration remains pending' <<<"${start_output}"
"${ROOT}/rollback-runtime.sh" --config "${pending}" --state-dir "${state_dir}" >/dev/null
owner_commit=6dadfbd8695bd1d0037568d879563eb83b7567b5
ready="${scratch}/ready.tsv"
make_lan_config "${ROOT}/config/lan.example.tsv" "${ready}" "${scratch}" "${commit}" ready "${owner_commit}"
plan="$("${ROOT}/lab-control.sh" --action start-plan --config "${ready}")"
[[ "${plan}" == *'UDP/14433 proxy'* && "${plan}" == *'127.0.0.1:4433'* ]]
[[ "${plan}" == *'Supervisor remains 127.0.0.1:9080'* ]]
grep -Fq 'const DEFAULT_BIND: &str = "127.0.0.1:4433";' "${ROOT}/../../gateway-rs/examples/dev_moq_relay.rs"
printf 'lan-binding-test: pass\n'
