#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${TEST_DIR}/../../.." && pwd -P)"
expected_commit=7160d2b7318dea74dc7e593641c015266fa13dc4
mode="${1:---source}"
[[ "${mode}" =~ ^--(source|integrated)$ ]] || { printf 'usage: rust-owner-contract-test.sh --source|--integrated\n' >&2; exit 2; }
git -C "${REPO_ROOT}" cat-file -e "${expected_commit}^{commit}" 2>/dev/null || {
    printf 'PENDING_OWNER_INTEGRATION: Rust LAN certificate contract commit is unavailable\n' >&2
    exit 3
}
source_text="$(git -C "${REPO_ROOT}" show "${expected_commit}:gateway-rs/examples/dev_moq_relay.rs")"
grep -Fq 'TEREMOQ_DEV_RELAY_LAN_IP_SAN' <<<"${source_text}"
grep -Fq 'webtransport-hash-v2-lan-ip-sha256' <<<"${source_text}"
grep -Fq 'sha256_hex(lan_ip_san.to_string().as_bytes())' <<<"${source_text}"
if [[ "${mode}" == --integrated ]]; then
    integrated_text="$(git -C "${REPO_ROOT}" show 'HEAD:gateway-rs/examples/dev_moq_relay.rs')"
    for contract in TEREMOQ_DEV_RELAY_LAN_IP_SAN webtransport-hash-v2-lan-ip-sha256 'sha256_hex(lan_ip_san.to_string().as_bytes())'; do
        grep -Fq "${contract}" <<<"${integrated_text}" || {
            printf 'PENDING_OWNER_INTEGRATION: Rust LAN certificate contract or equivalent is not integrated in HEAD\n' >&2
            exit 3
        }
    done
fi
printf 'lan-rust-owner-contract-test: %s pass\n' "${mode#--}"
