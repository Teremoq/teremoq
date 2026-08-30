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
mkdir -- "${repo}"
git -C "${repo}" init -q
printf 'base\n' >"${repo}/tracked.txt"
git -C "${repo}" add tracked.txt
git -C "${repo}" -c user.name='Teremoq test' -c user.email='test@invalid' commit -q -m base
owner="$(git -C "${repo}" rev-parse HEAD)"
printf 'integrated\n' >>"${repo}/tracked.txt"
git -C "${repo}" add tracked.txt
git -C "${repo}" -c user.name='Teremoq test' -c user.email='test@invalid' commit -q -m integrated
source_commit="$(git -C "${repo}" rev-parse HEAD)"
lan_require_clean_integrated_source "${repo}" "${source_commit}" "${owner}"
printf 'dirty\n' >>"${repo}/tracked.txt"
if (lan_require_clean_integrated_source "${repo}" "${source_commit}" "${owner}") >/dev/null 2>&1; then
    printf 'source-integrity-test: dirty tracked source accepted\n' >&2; exit 1
fi
git -C "${repo}" add tracked.txt
git -C "${repo}" -c user.name='Teremoq test' -c user.email='test@invalid' commit -q -m dirty-fixture-cleanup
source_commit="$(git -C "${repo}" rev-parse HEAD)"
printf 'untracked\n' >"${repo}/untracked.txt"
if (lan_require_clean_integrated_source "${repo}" "${source_commit}" "${owner}") >/dev/null 2>&1; then
    printf 'source-integrity-test: untracked source accepted\n' >&2; exit 1
fi
mv -- "${repo}/untracked.txt" "${scratch}/untracked.txt"
empty_tree="$(git -C "${repo}" mktree </dev/null)"
unrelated="$(printf 'unrelated\n' | git -C "${repo}" -c user.name='Teremoq test' -c user.email='test@invalid' commit-tree "${empty_tree}")"
if (lan_require_clean_integrated_source "${repo}" "${source_commit}" "${unrelated}") >/dev/null 2>&1; then
    printf 'source-integrity-test: unrelated owner commit accepted\n' >&2; exit 1
fi
if (lan_require_clean_integrated_source "${repo}" "${owner}" "${owner}") >/dev/null 2>&1; then
    printf 'source-integrity-test: non-HEAD source commit accepted\n' >&2; exit 1
fi
printf 'lan-source-integrity-test: pass\n'
