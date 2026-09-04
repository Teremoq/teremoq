#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
umask 077

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${TEST_DIR}/.." && pwd -P)"
source "${TEST_DIR}/test-lib.sh"
scratch="$(mktemp -d /tmp/teremoq-lan-package-test.XXXXXX)"
trap 'find "${scratch}" -depth -delete' EXIT
repo="${scratch}/repo"
external_player="${scratch}/external-player"
mkdir -p -- "${repo}/infra/lan/client" "${repo}/infra/lan/windows" "${external_player}" "${scratch}/out"
cp -a -- "${ROOT}/client/." "${repo}/infra/lan/client/"
cp -- "${ROOT}/windows/Preflight-Client.ps1" "${ROOT}/windows/Collect-Evidence.ps1" "${ROOT}/windows/Preflight-Contract.ps1" "${repo}/infra/lan/windows/"
git -C "${repo}" init -q -b codex/lan-client
git -C "${repo}" remote add origin https://github.com/Teremoq/teremoq
git -C "${repo}" add .
git -C "${repo}" -c user.name='Teremoq test' -c user.email='test@invalid' commit -q -m 'test: client source'
commit="$(git -C "${repo}" rev-parse HEAD)"
config="${scratch}/config.tsv"
make_lan_config "${ROOT}/config/lan.example.tsv" "${config}" "${scratch}" "${commit}"
printf 'a%.0s' {1..64} >"${scratch}/fingerprint"
printf 'external player must never be packaged\n' >"${external_player}/placeholder"
if "${ROOT}/package-client.sh" --repo "${repo}" --commit "${commit}" --config "${config}" \
    --player-dir "${external_player}" --player-relative-path supervisor-web/lan-player \
    --fingerprint "${scratch}/fingerprint" --git-url https://github.com/Teremoq/teremoq \
    --git-ref refs/heads/codex/lan-client --git-subdirectory infra/lan --output-dir "${scratch}/out" >/dev/null 2>&1; then
    printf 'package-test: external player directory was accepted\n' >&2
    exit 1
fi
if find "${scratch}/out" -mindepth 1 -print -quit | grep -q .; then
    printf 'package-test: rejected external player left a state artifact\n' >&2
    exit 1
fi
printf 'lan-package-test: pass\n'
