#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONTROL_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
REPORT_DIR="${CONTROL_ROOT}/reports/latest"
CONFIG_PATH="${CONTROL_ROOT}/config/milestone-100.json"
PYCACHE_ROOT="$(mktemp -d /tmp/teremoq-control-pycache.XXXXXX)"
trap 'rm -rf -- "${PYCACHE_ROOT}"' EXIT
export PYTHONPYCACHEPREFIX="${PYCACHE_ROOT}"

python3 --version
"${CONTROL_ROOT}/bin/control-plane" --config "${CONFIG_PATH}" validate
PYTHONPATH="${CONTROL_ROOT}/src" python3 -m compileall -q "${CONTROL_ROOT}/src" "${CONTROL_ROOT}/tests"
PYTHONPATH="${CONTROL_ROOT}/src" python3 -m unittest discover -s "${CONTROL_ROOT}/tests" -v
"${CONTROL_ROOT}/bin/control-plane" --config "${CONFIG_PATH}" demo --report-dir "${REPORT_DIR}" >/dev/null

(
    cd -- "${CONTROL_ROOT}"
    find config contracts docs src tests -type f ! -name '*.pyc' -print0 \
        | sort -z \
        | xargs -0 sha256sum
    sha256sum reports/latest/actions-*.json reports/latest/milestone-100.json reports/latest/milestone-100.md
) >"${REPORT_DIR}/SHA256SUMS"

printf 'evidence=%s\n' "${REPORT_DIR}"
