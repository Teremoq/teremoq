#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
umask 077

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${TEST_DIR}/.." && pwd -P)"
ADAPTER="${ROOT}/provider-adapter.sh"
TOPOLOGY="${ROOT}/topology/default.tsv"
scratch="$(mktemp -d /tmp/teremoq-provider-test.XXXXXX)"
trap 'rm -rf -- "${scratch}"' EXIT
state_dir="${scratch}/state"
sequence=0

fail() {
    printf 'provider-adapter-test: %s\n' "$*" >&2
    exit 1
}

invoke() {
    local mode="$1" operation="$2" node="$3"
    shift 3
    sequence=$(( sequence + 1 ))
    "${ADAPTER}" --contract-version 1 --mode "${mode}" \
        --operation "${operation}" \
        --request-id "test-${sequence}-${operation}" --run-id t10-adapter-test \
        --node "${node}" --state-dir "${state_dir}" --topology "${TOPOLOGY}" "$@"
}

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        fail "unexpected success: $*"
    fi
}

expect_failure "${ADAPTER}" --contract-version 2 --mode dry-run \
    --operation plan --request-id invalid-version --run-id t10-adapter-test \
    --node distributor-a --state-dir "${state_dir}" --topology "${TOPOLOGY}"
expect_failure "${ADAPTER}" --contract-version 1 --mode dry-run \
    --operation plan --request-id 'INVALID/REQUEST' --run-id t10-adapter-test \
    --node distributor-a --state-dir "${state_dir}" --topology "${TOPOLOGY}"
expect_failure "${ADAPTER}" --contract-version 1 --mode dry-run \
    --operation plan --request-id invalid-node --run-id t10-adapter-test \
    --node '../bad' --state-dir "${state_dir}" --topology "${TOPOLOGY}"
expect_failure "${ADAPTER}" --contract-version 1 --mode dry-run \
    --operation plan --request-id invalid-root --run-id t10-adapter-test \
    --node distributor-a --state-dir / --topology "${TOPOLOGY}"
expect_failure "${ADAPTER}" --contract-version 1 --mode dry-run \
    --operation plan --request-id invalid-traversal --run-id t10-adapter-test \
    --node distributor-a --state-dir "${scratch}/parent/../escaped" \
    --topology "${TOPOLOGY}"
mkdir -p -- "${scratch}/outside"
ln -s -- "${scratch}/outside" "${scratch}/linked-state"
expect_failure "${ADAPTER}" --contract-version 1 --mode simulate \
    --operation create --request-id invalid-symlink --run-id t10-adapter-test \
    --node distributor-a --state-dir "${scratch}/linked-state" \
    --topology "${TOPOLOGY}"
[[ -z "$(find "${scratch}/outside" -mindepth 1 -print -quit)" ]] || \
    fail 'rejected symlink path mutated its target'
expect_failure "${ADAPTER}" --contract-version 1 --mode dry-run \
    --operation create --request-id unknown-template --run-id t10-adapter-test \
    --node distributor-z --template-node missing-template \
    --state-dir "${state_dir}" --topology "${TOPOLOGY}"
[[ ! -e "${state_dir}" ]] || fail 'rejected dry-run mutated state'

output="$(invoke dry-run create distributor-a)"
[[ "${output}" == *'"result":"planned"'* ]] || fail 'dry-run was not planned'
[[ ! -e "${state_dir}" ]] || fail 'dry-run mutated state'

output="$(invoke simulate plan distributor-a)"
[[ "${output}" == *'"reason":"desired_state_valid"'* ]] || fail 'plan failed'
[[ ! -e "${state_dir}" ]] || fail 'plan mutated state'

output="$(invoke simulate create distributor-a)"
[[ "${output}" == *'"result":"changed"'* ]] || fail 'first create did not change state'
output="$(invoke simulate create distributor-a)"
[[ "${output}" == *'"result":"unchanged"'* ]] || fail 'second create was not idempotent'

invoke simulate configure distributor-a --capacity 40 >/dev/null
output="$(invoke simulate configure distributor-a --capacity 40)"
[[ "${output}" == *'"result":"unchanged"'* ]] || fail 'configure was not idempotent'
invoke simulate health distributor-a >/dev/null
output="$(invoke simulate health distributor-a)"
[[ "${output}" == *'"state":"healthy"'* ]] || fail 'health did not converge'
invoke simulate drain distributor-a >/dev/null
output="$(invoke simulate drain distributor-a)"
[[ "${output}" == *'"result":"unchanged"'* ]] || fail 'drain was not idempotent'

invoke simulate create distributor-a-r1 --template-node distributor-a >/dev/null
[[ "$(<"${state_dir}/nodes/distributor-a-r1/provider")" == local-a ]] || \
    fail 'replacement did not inherit provider template'

invoke simulate destroy distributor-a-r1 >/dev/null
output="$(invoke simulate destroy distributor-a-r1)"
[[ "${output}" == *'"reason":"already_absent"'* ]] || fail 'destroy was not idempotent'
invoke simulate destroy distributor-a >/dev/null

invoke simulate create control >/dev/null
invoke simulate create control-r2 --template-node control >/dev/null
invoke simulate create control-r3 --template-node control >/dev/null
[[ -d "${state_dir}/nodes/control" && -d "${state_dir}/nodes/control-r2" && \
   -d "${state_dir}/nodes/control-r3" ]] || fail 'unique control identities were not created'
[[ "$(<"${state_dir}/nodes/control-r2/role")" == control ]] || \
    fail 'control replica did not inherit its template'
for control_node in control control-r2 control-r3; do
    invoke simulate destroy "${control_node}" >/dev/null
done

invoke simulate create viewer-edge-r1 --template-node viewer-edge-template >/dev/null
[[ "$(<"${state_dir}/nodes/viewer-edge-r1/tier")" == viewer-edge ]] || \
    fail 'viewer-edge template tier was not preserved'
[[ "$(<"${state_dir}/nodes/viewer-edge-r1/region")" == eu-local-3 ]] || \
    fail 'viewer-edge template region was not preserved'
invoke simulate destroy viewer-edge-r1 >/dev/null

invoke simulate create distributor-b >/dev/null
if invoke simulate health distributor-b >/dev/null 2>&1; then
    fail 'health accepted an unconfigured node'
fi
invoke simulate destroy distributor-b >/dev/null

remaining="$(find "${state_dir}/nodes" -mindepth 1 -maxdepth 1 -type d | wc -l)"
(( remaining == 0 )) || fail 'test left provider nodes behind'
printf 'provider-adapter-test: pass\n'
