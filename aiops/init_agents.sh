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

validate_json_contract() {
  python3 - "$@" <<'PY'
import json
import re
import sys


class DuplicateKeyError(ValueError):
    pass


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateKeyError("duplicate JSON key")
        result[key] = value
    return result


def load_document(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle, object_pairs_hook=reject_duplicate_keys)


def require(condition):
    if not condition:
        raise ValueError("JSON contract rejected")


def validate_bounded_value(value, depth=0):
    require(depth <= 6)
    if isinstance(value, dict):
        require(len(value) <= 32)
        for key, child in value.items():
            require(isinstance(key, str) and 1 <= len(key) <= 64)
            validate_bounded_value(child, depth + 1)
    elif isinstance(value, list):
        require(len(value) <= 256)
        for child in value:
            validate_bounded_value(child, depth + 1)
    elif isinstance(value, str):
        require(len(value) <= 4096)
    elif value is None or isinstance(value, bool):
        return
    elif isinstance(value, int):
        require(-(2**63) <= value <= 2**63 - 1)
    else:
        raise ValueError("unsupported JSON value type")


mode = sys.argv[1]
document = load_document(sys.argv[2])
validate_bounded_value(document)

if mode == "duplicates-only":
    require(isinstance(document, dict))
elif mode == "manifest-binding":
    expected_name = sys.argv[3]
    expected_digest = sys.argv[4]
    required_keys = {
        "exact_name", "digest", "source", "weights_license",
        "weights_size_bytes", "context_tokens", "reviewed_on",
        "reviewed_by_role", "allowed_use", "approval_state",
    }
    require(isinstance(document, dict))
    require(set(document) == {"manifest_version", "model"})
    require(document["manifest_version"] == "1.0")
    model = document["model"]
    require(isinstance(model, dict) and set(model) == required_keys)
    require(model["exact_name"] == expected_name)
    require(model["digest"] == expected_digest)
    require(model["approval_state"] == "approved")
    require(model["allowed_use"] == "offline_observation_and_recommendation_only")
elif mode == "ollama-tags-binding":
    expected_name = sys.argv[3]
    expected_digest = sys.argv[4]
    allowed_model_keys = {"name", "model", "modified_at", "size", "digest", "details"}
    name_pattern = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}\Z")
    digest_pattern = re.compile(r"sha256:[a-f0-9]{64}\Z")
    require(isinstance(document, dict) and set(document) == {"models"})
    models = document["models"]
    require(isinstance(models, list) and 1 <= len(models) <= 256)
    matching_name = []
    for model in models:
        require(isinstance(model, dict))
        require({"name", "digest"} <= set(model) <= allowed_model_keys)
        require(isinstance(model["name"], str) and name_pattern.fullmatch(model["name"]) is not None)
        require(isinstance(model["digest"], str) and digest_pattern.fullmatch(model["digest"]) is not None)
        if "model" in model:
            require(isinstance(model["model"], str) and name_pattern.fullmatch(model["model"]) is not None)
        if "modified_at" in model:
            require(isinstance(model["modified_at"], str) and len(model["modified_at"]) <= 64)
        if "size" in model:
            require(isinstance(model["size"], int) and not isinstance(model["size"], bool))
            require(0 <= model["size"] <= 1099511627776)
        if "details" in model:
            require(isinstance(model["details"], dict))
            validate_bounded_value(model["details"], 1)
        if model["name"] == expected_name:
            matching_name.append(model)
    require(len(matching_name) == 1)
    require(matching_name[0]["digest"] == expected_digest)
else:
    raise ValueError("unknown JSON contract mode")
PY
}

validate_manifest() {
  [[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] || fail "model manifest must be a regular, non-symlink file"
  validate_uint_range "model manifest bytes" "$(wc -c < "$MANIFEST")" 1 8192
  command -v python3 >/dev/null 2>&1 || fail "Python 3 standard JSON parser is required"
  validate_json_contract duplicates-only "$MANIFEST" >/dev/null 2>&1 || fail "model manifest contains invalid JSON or duplicate keys"
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

    validate_json_contract manifest-binding "$MANIFEST" "$MODEL" "$MODEL_DIGEST" >/dev/null 2>&1 || fail "requested model and digest are not one exact approved manifest entry"

    command -v curl >/dev/null 2>&1 || fail "curl is required for an explicitly opted-in probe"
    response_file="$(mktemp)"
    trap 'rm -f -- "$response_file"' EXIT
    curl --fail --silent --show-error --retry 0 \
      --connect-timeout "$CONNECT_TIMEOUT_SECONDS" \
      --max-time "$REQUEST_TIMEOUT_SECONDS" \
      --output "$response_file" \
      "${OLLAMA_HOST}/api/tags" || fail "loopback Ollama probe failed"
    validate_uint_range "Ollama response bytes" "$(wc -c < "$response_file")" 1 1048576
    validate_json_contract ollama-tags-binding "$response_file" "$MODEL" "$MODEL_DIGEST" >/dev/null 2>&1 || fail "Ollama response does not contain one exact approved name-digest pair"
    printf '%s\n' 'Approved local model is present with the expected digest; no pull or generation was performed.'
    ;;
  *)
    fail "AIOPS_BOOTSTRAP_MODE must be validate or probe"
    ;;
esac
