#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODE="${AIOPS_BOOTSTRAP_MODE:-validate}"
NETWORK_OPT_IN="${AIOPS_NETWORK_OPT_IN:-false}"
OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
MODEL="${OLLAMA_MODEL:-}"
MODEL_DIGEST="${OLLAMA_MODEL_DIGEST:-}"
MANIFEST="${AIOPS_MODEL_MANIFEST:-${SCRIPT_DIR}/model-manifest.json}"
MANIFEST_SHA256="${AIOPS_MODEL_MANIFEST_SHA256:-}"
CONNECT_TIMEOUT_SECONDS="${AIOPS_CONNECT_TIMEOUT_SECONDS:-2}"
REQUEST_TIMEOUT_SECONDS="${AIOPS_REQUEST_TIMEOUT_SECONDS:-5}"

fail() {
  printf 'AIOps bootstrap refused: %s\n' "$1" >&2
  exit 1
}

validate_uint_range() {
  local name="$1"
  local value="$2"
  local minimum="$3"
  local maximum="$4"
  [[ "$value" =~ ^[0-9]+$ ]] || fail "${name} must be an integer"
  (( value >= minimum && value <= maximum )) || fail "${name} is outside its allowed range"
}

validate_loopback_host() {
  local port
  if [[ "$OLLAMA_HOST" =~ ^http://127\.0\.0\.1:([0-9]{1,5})$ ]]; then
    port="${BASH_REMATCH[1]}"
  elif [[ "$OLLAMA_HOST" =~ ^http://\[::1\]:([0-9]{1,5})$ ]]; then
    port="${BASH_REMATCH[1]}"
  else
    fail "OLLAMA_HOST must be an explicit HTTP loopback endpoint with a port"
  fi
  validate_uint_range "OLLAMA_HOST port" "$port" 1 65535
}

validate_manifest() {
  [[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] || fail "model manifest must be a regular, non-symlink file"
  validate_uint_range "model manifest bytes" "$(wc -c < "$MANIFEST")" 1 8192
  command -v jsonschema >/dev/null 2>&1 || fail "jsonschema validator is required"
  jsonschema -V Draft202012Validator \
    "${SCRIPT_DIR}/schemas/model-manifest-v1.schema.json" \
    -i "$MANIFEST" >/dev/null 2>&1 || fail "model manifest does not satisfy the approved schema"
}

validate_loopback_host
validate_uint_range "AIOPS_CONNECT_TIMEOUT_SECONDS" "$CONNECT_TIMEOUT_SECONDS" 1 10
validate_uint_range "AIOPS_REQUEST_TIMEOUT_SECONDS" "$REQUEST_TIMEOUT_SECONDS" 1 30
validate_manifest

case "$MODE" in
  validate)
    [[ "$NETWORK_OPT_IN" == "false" ]] || fail "network opt-in is not accepted in validate mode"
    [[ -z "$MODEL" && -z "$MODEL_DIGEST" ]] || fail "validate mode does not enable a model"
    printf '%s\n' 'AIOps configuration valid; no model enabled and no network operation performed.'
    ;;
  probe)
    [[ "$NETWORK_OPT_IN" == "true" ]] || fail "probe mode requires AIOPS_NETWORK_OPT_IN=true"
    [[ "$MODEL" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$ ]] || fail "OLLAMA_MODEL must be an exact bounded model name"
    [[ "$MODEL_DIGEST" =~ ^sha256:[a-f0-9]{64}$ ]] || fail "OLLAMA_MODEL_DIGEST must be an exact sha256 digest"
    [[ "$MANIFEST_SHA256" =~ ^[a-f0-9]{64}$ ]] || fail "AIOPS_MODEL_MANIFEST_SHA256 is required"
    [[ "$(sha256sum "$MANIFEST" | awk '{print $1}')" == "$MANIFEST_SHA256" ]] || fail "model manifest hash mismatch"

    manifest_compact="$(tr -d '[:space:]' < "$MANIFEST")"
    [[ "$manifest_compact" != *'"model":null'* ]] || fail "no model is approved in the manifest"
    [[ "$manifest_compact" == *"\"exact_name\":\"${MODEL}\""* ]] || fail "requested model is not the approved exact name"
    [[ "$manifest_compact" == *"\"digest\":\"${MODEL_DIGEST}\""* ]] || fail "requested digest is not approved"
    [[ "$manifest_compact" == *'"approval_state":"approved"'* ]] || fail "model approval is absent"

    command -v curl >/dev/null 2>&1 || fail "curl is required for an explicitly opted-in probe"
    response_file="$(mktemp)"
    trap 'rm -f -- "$response_file"' EXIT
    curl --fail --silent --show-error --retry 0 \
      --connect-timeout "$CONNECT_TIMEOUT_SECONDS" \
      --max-time "$REQUEST_TIMEOUT_SECONDS" \
      --output "$response_file" \
      "${OLLAMA_HOST}/api/tags" || fail "loopback Ollama probe failed"
    validate_uint_range "Ollama response bytes" "$(wc -c < "$response_file")" 1 1048576
    response_compact="$(tr -d '[:space:]' < "$response_file")"
    [[ "$response_compact" == *"\"name\":\"${MODEL}\""* ]] || fail "approved model is not present locally"
    [[ "$response_compact" == *"\"digest\":\"${MODEL_DIGEST}\""* ]] || fail "local model digest does not match approval"
    printf '%s\n' 'Approved local model is present with the expected digest; no pull or generation was performed.'
    ;;
  *)
    fail "AIOPS_BOOTSTRAP_MODE must be validate or probe"
    ;;
esac
