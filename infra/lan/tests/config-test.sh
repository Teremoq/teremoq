#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
umask 077

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${TEST_DIR}/.." && pwd -P)"
# shellcheck source=test-lib.sh
source "${TEST_DIR}/test-lib.sh"
scratch="$(mktemp -d /tmp/teremoq-lan-config-test.XXXXXX)"
trap 'find "${scratch}" -depth -delete' EXIT
commit="$(printf 'a%.0s' {1..40})"
valid="${scratch}/valid.tsv"
make_lan_config "${ROOT}/config/lan.example.tsv" "${valid}" "${scratch}" "${commit}"
"${ROOT}/validate-config.sh" --config "${valid}" >/dev/null

expect_failure() { "$@" >/dev/null 2>&1 && { printf 'config-test: unexpected success\n' >&2; exit 1; }; return 0; }
expect_failure "${ROOT}/validate-config.sh" --config "${ROOT}/config/lan.example.tsv"
for spec in \
    'server_ipv4\t8.8.8.8' \
    'client_ipv4\t192.168.77.0/24' \
    'client_ipv4\t192.168.77.1' \
    'moq_frontend_udp_port\t4433' \
    'moq_namespace\tteremoq//live' \
    'player_loopback_tcp_port\t8080' \
    'network_profile\tAny' \
    'dashboard_lan_enabled\ttrue' \
    'proxy_max_clients\t26' \
    'proxy_association_margin\t3'; do
    key="${spec%%\\t*}"; replacement="${spec#*\\t}"
    invalid="${scratch}/invalid-${key}-${replacement//[^A-Za-z0-9]/_}.tsv"
    awk -F '\t' -v OFS='\t' -v key="${key}" -v replacement="${replacement}" '$1 == key {$2=replacement} {print}' "${valid}" >"${invalid}"
    expect_failure "${ROOT}/validate-config.sh" --config "${invalid}"
done
printf 'lan-config-test: pass\n'
