#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BINDING_FILE="${SCRIPT_DIR}/contract/v1/control-plane-binding.env"

die() {
    printf 'control-plane binding: %s\n' "$*" >&2
    exit 1
}

(( $# == 2 )) && [[ "$1" == --repo ]] || die 'usage: verify-control-plane-binding.sh --repo ABSOLUTE_REPOSITORY'
CONTROL_REPO="$2"
[[ "${CONTROL_REPO}" == /* && -d "${CONTROL_REPO}/.git" || \
   "${CONTROL_REPO}" == /* && -f "${CONTROL_REPO}/.git" ]] || \
    die 'repository must be an absolute Git worktree path'
[[ -r "${BINDING_FILE}" ]] || die 'immutable binding file is unavailable'

# shellcheck disable=SC1090
source "${BINDING_FILE}"
[[ "${CONTROL_PLANE_TREE_SHA1:-}" =~ ^[0-9a-f]{40}$ ]] || die 'invalid expected subtree hash'
[[ "${CONTROL_PLANE_CONFIG_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || die 'invalid expected configuration hash'

observed_tree="$(git -C "${CONTROL_REPO}" rev-parse HEAD:control-plane 2>/dev/null)" || \
    die 'cannot resolve control-plane subtree'
[[ "${observed_tree}" == "${CONTROL_PLANE_TREE_SHA1}" ]] || \
    die 'control-plane subtree binding changed'
git -C "${CONTROL_REPO}" diff --quiet -- control-plane || \
    die 'control-plane source has uncommitted divergence'

config="${CONTROL_REPO}/control-plane/config/milestone-100.json"
[[ -f "${config}" ]] || die 'milestone configuration is unavailable'
observed_config="$(sha256sum "${config}" | awk '{print $1}')"
[[ "${observed_config}" == "${CONTROL_PLANE_CONFIG_SHA256}" ]] || \
    die 'milestone configuration hash changed'
