#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${TEST_DIR}/../../.." && pwd -P)"
expected_commit=2f8fb1b3219483050bc997bee25a052c2db5f463
mode="${1:---source}"
[[ "${mode}" =~ ^--(source|integrated)$ ]] || { printf 'usage: rust-owner-contract-test.sh --source|--integrated\n' >&2; exit 2; }
git -C "${REPO_ROOT}" cat-file -e "${expected_commit}^{commit}" 2>/dev/null || {
    printf 'PENDING_OWNER_INTEGRATION: Rust LAN certificate contract commit is unavailable\n' >&2
    exit 3
}
source_text="$(git -C "${REPO_ROOT}" show "${expected_commit}:gateway-rs/examples/dev_moq_relay.rs")"
capability_text="$(git -C "${REPO_ROOT}" show "${expected_commit}:gateway-rs/src/security/dev_relay_capability.rs")"
config_text="$(git -C "${REPO_ROOT}" show "${expected_commit}:gateway-rs/src/config.rs")"
grep -Fq 'TEREMOQ_DEV_RELAY_LAN_IP_SAN' <<<"${source_text}"
grep -Fq 'webtransport-hash-v2-lan-ip-sha256' <<<"${source_text}"
grep -Fq 'sha256_hex(lan_ip_san.to_string().as_bytes())' <<<"${source_text}"
grep -Fq 'TEREMOQ_DEV_RELAY_PUBLISH_CAPABILITY_FILE' <<<"${capability_text}"
grep -Fq 'const MAX_CAPABILITY_FILE_BYTES: u64 = 65;' <<<"${capability_text}"
grep -Fq 'connection_path == Some("/publish")' <<<"${source_text}"
grep -Fq 'resolve_scope(Some("/publish")).await.is_err()' <<<"${source_text}"
grep -Fq 'apply_to_local_publish_url(&mut relay_url)' <<<"${config_text}"
grep -Fq '"https://127.0.0.1:4433/publish"' <<<"${capability_text}"
if [[ "${mode}" == --integrated ]]; then
    git -C "${REPO_ROOT}" merge-base --is-ancestor "${expected_commit}" HEAD || {
        printf 'PENDING_OWNER_INTEGRATION: exact Rust LAN capability commit is not an ancestor of HEAD\n' >&2
        exit 3
    }
    integrated_text="$(git -C "${REPO_ROOT}" show 'HEAD:gateway-rs/examples/dev_moq_relay.rs')"
    for contract in TEREMOQ_DEV_RELAY_LAN_IP_SAN TEREMOQ_DEV_RELAY_PUBLISH_CAPABILITY_FILE webtransport-hash-v2-lan-ip-sha256 'sha256_hex(lan_ip_san.to_string().as_bytes())'; do
        grep -Fq "${contract}" <<<"${integrated_text}" || {
            printf 'PENDING_OWNER_INTEGRATION: Rust LAN certificate contract or equivalent is not integrated in HEAD\n' >&2
            exit 3
        }
    done
fi
printf 'lan-rust-owner-contract-test: %s pass\n' "${mode#--}"
