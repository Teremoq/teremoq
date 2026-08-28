#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AIOPS_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

bash -n "${AIOPS_DIR}/init_agents.sh" "${SCRIPT_DIR}"/*.sh
"${SCRIPT_DIR}/test_contracts.sh"
"${SCRIPT_DIR}/test_bootstrap.sh"

if rg -n --glob '*.json' --glob '!**/fixtures/invalid/**' -- \
  '-----BEGIN [A-Z ]+-----|spiffe://|"(certificate|private_key|passphrase|password|secret|token|credential|fingerprint|principal|namespace|payload|video|audio|customer)"[[:space:]]*:' \
  "$AIOPS_DIR"; then
  printf 'prohibited material found outside controlled negative fixtures\n' >&2
  exit 1
fi

if find "$AIOPS_DIR" -type d \( -name __pycache__ -o -name node_modules -o -name .pytest_cache \) -print -quit | grep -q .; then
  printf 'generated cache or dependency directory found\n' >&2
  exit 1
fi

printf '%s\n' 'AIOps offline suite: PASS'
