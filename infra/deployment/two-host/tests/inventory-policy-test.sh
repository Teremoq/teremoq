#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
umask 077

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${TEST_DIR}/.." && pwd -P)"
VALIDATOR="${ROOT}/validate-inventory.sh"
EXAMPLE="${ROOT}/inventory.example.tsv"
scratch="$(mktemp -d /tmp/teremoq-two-host-policy.XXXXXX)"
trap 'find "${scratch}" -depth -delete' EXIT

fail() {
    printf 'two-host-inventory-policy-test: %s\n' "$*" >&2
    exit 1
}

expect_failure() {
    "$@" >/dev/null 2>&1 && fail "unexpected success: $*"
    return 0
}

expect_failure "${VALIDATOR}" --inventory "${EXAMPLE}"
valid="${scratch}/valid.tsv"
digest="$(printf 'a%.0s' {1..64})"
awk -F '\t' -v OFS='\t' -v digest="${digest}" '
    /^#/ {print; next}
    $1 == "deployment_id" {$2="trial-two-host"}
    $1 == "host_a_id" {$2="host-a"}
    $1 == "host_a_provider" {$2="provider-a"}
    $1 == "host_a_region" {$2="region-a"}
    $1 == "host_a_zone" {$2="zone-a"}
    $1 == "host_a_address" {$2="host-a.test.invalid"}
    $1 == "host_b_id" {$2="host-b"}
    $1 == "host_b_provider" {$2="provider-b"}
    $1 == "host_b_region" {$2="region-b"}
    $1 == "host_b_zone" {$2="zone-b"}
    $1 == "host_b_address" {$2="host-b.test.invalid"}
    $1 ~ /_image$/ {$2="registry.test.invalid/teremoq/test:freeze@sha256:" digest}
    $1 ~ /_mtls_identity$/ {$2="spiffe://test.invalid/" $1}
    $1 ~ /_mtls_cert_path$/ {$2="/run/credentials/" $1 ".pem"}
    $1 ~ /_mtls_key_path$/ {$2="/run/credentials/" $1 ".pem"}
    $1 == "mtls_trust_bundle_path" {$2="/run/credentials/trust-bundle.pem"}
    $1 == "control_api_tcp_port" {$2="8443"}
    $1 == "minimum_kernel" {$2="6.1"}
    $1 == "maximum_clock_offset_ms" {$2="10"}
    $1 ~ /_minimum_cpu_cores$/ {$2="8"}
    $1 ~ /_minimum_memory_mib$/ {$2="16384"}
    $1 ~ /_minimum_disk_mib$/ {$2="102400"}
    $1 ~ /_minimum_egress_mbps$/ {$2="1000"}
    {print}
' "${EXAMPLE}" >"${valid}"
"${VALIDATOR}" --inventory "${valid}" >/dev/null

tag_only="${scratch}/tag-only.tsv"
sed 's#registry.test.invalid/teremoq/test:freeze@sha256:[a-f0-9]*#registry.test.invalid/teremoq/test:freeze#' \
    "${valid}" >"${tag_only}"
expect_failure "${VALIDATOR}" --inventory "${tag_only}"

duplicate_identity="${scratch}/duplicate-identity.tsv"
awk -F '\t' -v OFS='\t' '
    $1 == "distributor_a_mtls_identity" {$2="spiffe://test.invalid/origin_mtls_identity"}
    {print}
' "${valid}" >"${duplicate_identity}"
expect_failure "${VALIDATOR}" --inventory "${duplicate_identity}"

unknown="${scratch}/unknown.tsv"
sed '$a\unexpected_key\tvalue' "${valid}" >"${unknown}"
expect_failure "${VALIDATOR}" --inventory "${unknown}"
printf 'two-host-inventory-policy-test: pass\n'
