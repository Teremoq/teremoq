#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AIOPS_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
BOOTSTRAP="${AIOPS_DIR}/init_agents.sh"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

mkdir "${TEMP_DIR}/bin"
printf '%s\n' '#!/usr/bin/env bash' 'printf called > "${AIOPS_FAKE_CURL_MARKER:?}"' 'exit 99' > "${TEMP_DIR}/bin/curl"
chmod 700 "${TEMP_DIR}/bin/curl"
export PATH="${TEMP_DIR}/bin:${PATH}"
export AIOPS_FAKE_CURL_MARKER="${TEMP_DIR}/curl-called"

expect_rejected() {
  if env "$@" "$BOOTSTRAP" >"${TEMP_DIR}/stdout" 2>"${TEMP_DIR}/stderr"; then
    printf 'expected bootstrap rejection\n' >&2
    exit 1
  fi
}

env -u OLLAMA_MODEL -u OLLAMA_MODEL_DIGEST \
  AIOPS_BOOTSTRAP_MODE=validate AIOPS_NETWORK_OPT_IN=false \
  "$BOOTSTRAP" >"${TEMP_DIR}/stdout" 2>"${TEMP_DIR}/stderr"
grep -Fq 'no network operation performed' "${TEMP_DIR}/stdout"

expect_rejected AIOPS_BOOTSTRAP_MODE=probe AIOPS_NETWORK_OPT_IN=false
expect_rejected AIOPS_BOOTSTRAP_MODE=pull AIOPS_NETWORK_OPT_IN=true
expect_rejected OLLAMA_HOST=http://192.0.2.1:11434
expect_rejected AIOPS_CONNECT_TIMEOUT_SECONDS=0
expect_rejected AIOPS_REQUEST_TIMEOUT_SECONDS=31
expect_rejected AIOPS_BOOTSTRAP_MODE=validate OLLAMA_MODEL=implicit-model

manifest_hash="$(sha256sum "${AIOPS_DIR}/model-manifest.json" | awk '{print $1}')"
expect_rejected \
  AIOPS_BOOTSTRAP_MODE=probe \
  AIOPS_NETWORK_OPT_IN=true \
  OLLAMA_MODEL=reviewed-model:1 \
  OLLAMA_MODEL_DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  AIOPS_MODEL_MANIFEST_SHA256="$manifest_hash"

expect_rejected OLLAMA_HOST=http://user:do-not-log@127.0.0.1:11434
if grep -Fq 'do-not-log' "${TEMP_DIR}/stderr"; then
  printf 'bootstrap leaked rejected host contents\n' >&2
  exit 1
fi

[[ ! -e "$AIOPS_FAKE_CURL_MARKER" ]] || { printf 'curl was invoked by an offline test\n' >&2; exit 1; }
printf '%s\n' 'bootstrap tests: PASS'
