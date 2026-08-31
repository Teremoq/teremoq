#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${TEST_DIR}/.." && pwd -P)"
# shellcheck source=../lib.sh
source "${ROOT}/lib.sh"
scratch="$(mktemp -d /tmp/teremoq-lan-source-integrity.XXXXXX)"
trap 'find "${scratch}" -depth -delete' EXIT
repo="${scratch}/repo"
REPO_ROOT="$(cd -- "${ROOT}/../.." && pwd -P)"
git clone -q --no-checkout "${REPO_ROOT}" "${repo}"
git -C "${repo}" checkout -q --detach "${LAN_RUST_CAPABILITY_INTEGRATED_COMMIT}"
printf 'integrated topology test\n' >"${repo}/platform-test-marker.txt"
git -C "${repo}" add platform-test-marker.txt
git -C "${repo}" -c user.name='Teremoq test' -c user.email='test@invalid' commit -q -m integrated
source_commit="$(git -C "${repo}" rev-parse HEAD)"
lan_require_clean_integrated_source "${repo}" "${source_commit}" "${LAN_RUST_CAPABILITY_INTEGRATED_COMMIT}"
printf 'dirty\n' >>"${repo}/platform-test-marker.txt"
if (lan_require_clean_integrated_source "${repo}" "${source_commit}" "${LAN_RUST_CAPABILITY_INTEGRATED_COMMIT}") >/dev/null 2>&1; then
    printf 'source-integrity-test: dirty tracked source accepted\n' >&2; exit 1
fi
git -C "${repo}" add platform-test-marker.txt
git -C "${repo}" -c user.name='Teremoq test' -c user.email='test@invalid' commit -q -m dirty-fixture-cleanup
source_commit="$(git -C "${repo}" rev-parse HEAD)"
printf 'untracked\n' >"${repo}/untracked.txt"
if (lan_require_clean_integrated_source "${repo}" "${source_commit}" "${LAN_RUST_CAPABILITY_INTEGRATED_COMMIT}") >/dev/null 2>&1; then
    printf 'source-integrity-test: untracked source accepted\n' >&2; exit 1
fi
mv -- "${repo}/untracked.txt" "${scratch}/untracked.txt"
for forbidden_owner in "${LAN_RUST_CAPABILITY_PROVENANCE_COMMIT}" f64830a5416c7bc03940a5595dc450f41e7693e2; do
    if (lan_require_clean_integrated_source "${repo}" "${source_commit}" "${forbidden_owner}") >/dev/null 2>&1; then
        printf 'source-integrity-test: provenance/unrelated owner override accepted\n' >&2; exit 1
    fi
done
if (lan_require_clean_integrated_source "${repo}" "${LAN_RUST_CAPABILITY_INTEGRATED_COMMIT}" \
    "${LAN_RUST_CAPABILITY_INTEGRATED_COMMIT}") >/dev/null 2>&1; then
    printf 'source-integrity-test: non-HEAD source commit accepted\n' >&2; exit 1
fi
if env LAN_RUST_CAPABILITY_INTEGRATED_COMMIT="${LAN_RUST_CAPABILITY_PROVENANCE_COMMIT}" \
    bash -c 'source "$1"' _ "${ROOT}/lib.sh" >/dev/null 2>&1; then
    printf 'source-integrity-test: environment operational commit override was accepted\n' >&2; exit 1
fi
printf 'lan-source-integrity-test: pass\n'
