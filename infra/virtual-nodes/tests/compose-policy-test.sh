#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
umask 077

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${TEST_DIR}/.." && pwd -P)"
# shellcheck disable=SC1091
source "${ROOT}/versions.env"
export VIRTUAL_NODE_IMAGE TEREMOQ_RUN_ID=t10-compose-policy

docker compose --project-name t10composepolicy --project-directory "${ROOT}" \
    -f "${ROOT}/compose.yaml" config --quiet

if grep -Eq '^[[:space:]]*ports:|privileged:|cap_add:' "${ROOT}/compose.yaml"; then
    printf 'compose-policy-test: forbidden container exposure found\n' >&2
    exit 1
fi
(( $(grep -c 'read_only: true' "${ROOT}/compose.yaml") >= 1 )) || {
    printf 'compose-policy-test: common read-only policy missing\n' >&2
    exit 1
}
[[ "$(grep -c 'internal: true' "${ROOT}/compose.yaml")" -eq 2 ]] || {
    printf 'compose-policy-test: both networks must be internal\n' >&2
    exit 1
}
grep -Fq "${VIRTUAL_NODE_IMAGE}" "${ROOT}/versions.env"
runtime_sha="$(sha256sum "${ROOT}/node-runtime.sh" | awk '{print $1}')"
[[ "${runtime_sha}" == "${VIRTUAL_NODE_RUNTIME_SHA256}" ]] || {
    printf 'compose-policy-test: runtime hash does not match versions.env\n' >&2
    exit 1
}
grep -Fq 'pull_policy: never' "${ROOT}/compose.yaml"
grep -Fq 'no-new-privileges:true' "${ROOT}/compose.yaml"
grep -Fq 'pids_limit: 32' "${ROOT}/compose.yaml"
grep -Fq 'teremoq.run-id:' "${ROOT}/compose.yaml"
mapfile -t image_mappings < <(awk -F '\t' '$0 !~ /^#/ && NF == 3 {print}' \
    "${ROOT}/contract/v1/image-map.tsv")
(( ${#image_mappings[@]} == 1 )) || {
    printf 'compose-policy-test: simulator image map must have exactly one reviewed entry\n' >&2
    exit 1
}
IFS=$'\t' read -r desired_identifier mapped_oci mapped_id <<<"${image_mappings[0]}"
[[ "${desired_identifier}" =~ ^sha256:[0-9a-f]{64}$ && \
   "${mapped_oci}" == "${VIRTUAL_NODE_IMAGE}" && "${mapped_id}" == "${VIRTUAL_NODE_IMAGE_ID}" ]] || {
    printf 'compose-policy-test: simulator image map is inconsistent\n' >&2
    exit 1
}
[[ "${desired_identifier}" != "${mapped_id}" ]] || {
    printf 'compose-policy-test: fixture identifier was conflated with simulator image ID\n' >&2
    exit 1
}
printf 'compose-policy-test: pass\n'
