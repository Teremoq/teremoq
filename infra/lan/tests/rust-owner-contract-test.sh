#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${TEST_DIR}/.." && pwd -P)"
REPO_ROOT="$(cd -- "${ROOT}/../.." && pwd -P)"
# shellcheck source=../lib.sh
source "${ROOT}/lib.sh"

operational_commit="${LAN_RUST_CAPABILITY_INTEGRATED_COMMIT}"
provenance_commit="${LAN_RUST_CAPABILITY_PROVENANCE_COMMIT}"
expected_patch_id=5729506f85cb640b0026e4db80e402d496cd8fd8
reviewed_integration_head=5ae08b3716f169b47013dd0e320716329a4bcb0d
integration_repo=/home/jimbomilk/teremoq-lan-integration
mode="${1:---source}"
[[ "${mode}" =~ ^--(source|integrated)$ ]] || {
    printf 'usage: rust-owner-contract-test.sh --source|--integrated\n' >&2
    exit 2
}

for commit in "${provenance_commit}" "${operational_commit}"; do
    git -C "${REPO_ROOT}" cat-file -e "${commit}^{commit}" 2>/dev/null || {
        printf 'PENDING_OWNER_INTEGRATION: Rust LAN capability contract commit is unavailable: %s\n' "${commit}" >&2
        exit 3
    }
done

source_text="$(git -C "${REPO_ROOT}" show "${operational_commit}:gateway-rs/examples/dev_moq_relay.rs")"
capability_text="$(git -C "${REPO_ROOT}" show "${operational_commit}:gateway-rs/src/security/dev_relay_capability.rs")"
config_text="$(git -C "${REPO_ROOT}" show "${operational_commit}:gateway-rs/src/config.rs")"
grep -Fq 'TEREMOQ_DEV_RELAY_LAN_IP_SAN' <<<"${source_text}"
grep -Fq 'webtransport-hash-v2-lan-ip-sha256' <<<"${source_text}"
grep -Fq 'sha256_hex(lan_ip_san.to_string().as_bytes())' <<<"${source_text}"
grep -Fq 'TEREMOQ_DEV_RELAY_PUBLISH_CAPABILITY_FILE' <<<"${capability_text}"
grep -Fq 'const MAX_CAPABILITY_FILE_BYTES: u64 = 65;' <<<"${capability_text}"
grep -Fq 'connection_path == Some("/publish")' <<<"${source_text}"
grep -Fq 'resolve_scope(Some("/publish")).await.is_err()' <<<"${source_text}"
grep -Fq 'apply_to_local_publish_url(&mut relay_url)' <<<"${config_text}"
grep -Fq '"https://127.0.0.1:4433/publish"' <<<"${capability_text}"

provenance_patch_id="$(git -C "${REPO_ROOT}" show "${provenance_commit}" --pretty=format: | git patch-id --stable | awk '{print $1}')"
operational_patch_id="$(git -C "${REPO_ROOT}" show "${operational_commit}" --pretty=format: | git patch-id --stable | awk '{print $1}')"
[[ "${provenance_patch_id}" == "${expected_patch_id}" && "${operational_patch_id}" == "${expected_patch_id}" ]] || {
    printf 'Rust LAN provenance/integration stable patch-id mismatch\n' >&2
    exit 1
}

if [[ "${mode}" == --integrated ]]; then
    [[ -d "${integration_repo}/.git" || -f "${integration_repo}/.git" ]] || integration_repo="${REPO_ROOT}"
    integrated_head="$(git -C "${integration_repo}" rev-parse HEAD)"
    git -C "${integration_repo}" merge-base --is-ancestor "${reviewed_integration_head}" "${integrated_head}" || {
        printf 'reviewed LAN integration HEAD is not in the tested topology\n' >&2
        exit 1
    }
    lan_require_clean_integrated_source "${integration_repo}" "${integrated_head}" "${operational_commit}"
    if (lan_require_clean_integrated_source "${integration_repo}" "${integrated_head}" "${provenance_commit}") >/dev/null 2>&1; then
        printf 'provenance commit was accepted as an operational override\n' >&2
        exit 1
    fi
    if (lan_require_clean_integrated_source "${integration_repo}" "${integrated_head}" f64830a5416c7bc03940a5595dc450f41e7693e2) >/dev/null 2>&1; then
        printf 'unrelated ancestor was accepted as an operational override\n' >&2
        exit 1
    fi
fi

printf 'lan-rust-owner-contract-test: %s pass; operational=%s provenance_patch_id=%s\n' \
    "${mode#--}" "${operational_commit}" "${expected_patch_id}"
