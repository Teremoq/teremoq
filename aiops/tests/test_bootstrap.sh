#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AIOPS_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
BOOTSTRAP="${AIOPS_DIR}/init_agents.sh"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

TEST_MODEL='test/model:1'
TEST_DIGEST='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
OTHER_DIGEST='sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

mkdir "${TEMP_DIR}/bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'output_file=' \
  'while (( $# > 0 )); do' \
  '  if [[ "$1" == "--output" ]]; then output_file="$2"; shift 2; else shift; fi' \
  'done' \
  '[[ -n "$output_file" ]]' \
  'echo called >> "${AIOPS_FAKE_CURL_MARKER:?}"' \
  'cp -- "${AIOPS_FAKE_CURL_RESPONSE:?}" "$output_file"' > "${TEMP_DIR}/bin/curl"
chmod 700 "${TEMP_DIR}/bin/curl"
export PATH="${TEMP_DIR}/bin:${PATH}"
export AIOPS_FAKE_CURL_MARKER="${TEMP_DIR}/curl-called"

expect_rejected() {
  if env "$@" "$BOOTSTRAP" >"${TEMP_DIR}/stdout" 2>"${TEMP_DIR}/stderr"; then
    printf 'expected bootstrap rejection\n' >&2
    exit 1
  fi
}

curl_calls() {
  if [[ -f "$AIOPS_FAKE_CURL_MARKER" ]]; then
    wc -l < "$AIOPS_FAKE_CURL_MARKER"
  else
    printf '0\n'
  fi
}

write_approved_manifest() {
  local destination="$1"
  printf '%s\n' \
    '{' \
    '  "manifest_version": "1.0",' \
    '  "model": {' \
    "    \"exact_name\": \"${TEST_MODEL}\"," \
    "    \"digest\": \"${TEST_DIGEST}\"," \
    '    "source": "https://models.invalid/test-only",' \
    '    "weights_license": "Apache-2.0",' \
    '    "weights_size_bytes": 1024,' \
    '    "context_tokens": 1024,' \
    '    "reviewed_on": "2026-08-28",' \
    '    "reviewed_by_role": "model_risk_owner",' \
    '    "allowed_use": "offline_observation_and_recommendation_only",' \
    '    "approval_state": "approved"' \
    '  }' \
    '}' > "$destination"
}

run_probe() {
  local manifest="$1"
  local response="$2"
  local manifest_hash
  manifest_hash="$(sha256sum "$manifest" | awk '{print $1}')"
  env \
    AIOPS_BOOTSTRAP_MODE=probe \
    AIOPS_NETWORK_OPT_IN=true \
    AIOPS_MODEL_MANIFEST="$manifest" \
    AIOPS_MODEL_MANIFEST_SHA256="$manifest_hash" \
    AIOPS_FAKE_CURL_RESPONSE="$response" \
    OLLAMA_MODEL="$TEST_MODEL" \
    OLLAMA_MODEL_DIGEST="$TEST_DIGEST" \
    "$BOOTSTRAP"
}

expect_probe_rejected() {
  if run_probe "$1" "$2" >"${TEMP_DIR}/stdout" 2>"${TEMP_DIR}/stderr"; then
    printf 'expected probe rejection\n' >&2
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

empty_manifest_hash="$(sha256sum "${AIOPS_DIR}/model-manifest.json" | awk '{print $1}')"
expect_rejected \
  AIOPS_BOOTSTRAP_MODE=probe \
  AIOPS_NETWORK_OPT_IN=true \
  OLLAMA_MODEL="$TEST_MODEL" \
  OLLAMA_MODEL_DIGEST="$TEST_DIGEST" \
  AIOPS_MODEL_MANIFEST_SHA256="$empty_manifest_hash"

expect_rejected OLLAMA_HOST=http://user:do-not-log@127.0.0.1:11434
if grep -Fq 'do-not-log' "${TEMP_DIR}/stderr"; then
  printf 'bootstrap leaked rejected host contents\n' >&2
  exit 1
fi
[[ "$(curl_calls)" == 0 ]] || { printf 'curl was invoked before an approved probe\n' >&2; exit 1; }

approved_manifest="${TEMP_DIR}/approved-manifest.json"
write_approved_manifest "$approved_manifest"

valid_response="${TEMP_DIR}/valid-response.json"
printf '{"models":[{"name":"%s","digest":"%s"}]}\n' "$TEST_MODEL" "$TEST_DIGEST" > "$valid_response"
run_probe "$approved_manifest" "$valid_response" >"${TEMP_DIR}/stdout" 2>"${TEMP_DIR}/stderr"
grep -Fq 'expected digest' "${TEMP_DIR}/stdout"
[[ "$(curl_calls)" == 1 ]] || { printf 'valid probe did not invoke fake curl exactly once\n' >&2; exit 1; }

split_response="${TEMP_DIR}/split-response.json"
printf '{"models":[{"name":"%s","digest":"%s"},{"name":"other/model:1","digest":"%s"}]}\n' \
  "$TEST_MODEL" "$OTHER_DIGEST" "$TEST_DIGEST" > "$split_response"
expect_probe_rejected "$approved_manifest" "$split_response"

duplicate_response="${TEMP_DIR}/duplicate-response.json"
printf '{"models":[{"name":"%s","name":"other/model:1","digest":"%s"}]}\n' \
  "$TEST_MODEL" "$TEST_DIGEST" > "$duplicate_response"
expect_probe_rejected "$approved_manifest" "$duplicate_response"

malformed_response="${TEMP_DIR}/malformed-response.json"
printf '{"models":[{"name":"%s","digest":"%s"}]\n' "$TEST_MODEL" "$TEST_DIGEST" > "$malformed_response"
expect_probe_rejected "$approved_manifest" "$malformed_response"

duplicate_manifest="${TEMP_DIR}/duplicate-manifest.json"
write_approved_manifest "$duplicate_manifest"
sed -i 's/"approval_state": "approved"/"approval_state": "approved", "approval_state": "approved"/' "$duplicate_manifest"
calls_before="$(curl_calls)"
expect_probe_rejected "$duplicate_manifest" "$valid_response"
[[ "$(curl_calls)" == "$calls_before" ]] || { printf 'duplicate manifest reached curl\n' >&2; exit 1; }

ambiguous_manifest="${TEMP_DIR}/ambiguous-manifest.json"
printf '{"manifest_version":"1.0","model":[null,null]}\n' > "$ambiguous_manifest"
calls_before="$(curl_calls)"
expect_probe_rejected "$ambiguous_manifest" "$valid_response"
[[ "$(curl_calls)" == "$calls_before" ]] || { printf 'ambiguous manifest reached curl\n' >&2; exit 1; }

printf '%s\n' 'bootstrap tests: PASS'
