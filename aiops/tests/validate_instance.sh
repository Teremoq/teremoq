#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AIOPS_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

if (( $# != 2 )); then
  printf 'usage: %s observation|recommendation|execution|model-manifest FILE\n' "$0" >&2
  exit 2
fi

contract="$1"
instance="$2"
case "$contract" in
  observation)
    schema="${AIOPS_DIR}/schemas/aiops-observation-v1.schema.json"
    maximum_bytes=16384
    scan_content=true
    ;;
  recommendation)
    schema="${AIOPS_DIR}/schemas/aiops-recommendation-v1.schema.json"
    maximum_bytes=8192
    scan_content=true
    ;;
  execution)
    schema="${AIOPS_DIR}/schemas/aiops-execution-v1.schema.json"
    maximum_bytes=4096
    scan_content=true
    ;;
  model-manifest)
    schema="${AIOPS_DIR}/schemas/model-manifest-v1.schema.json"
    maximum_bytes=8192
    scan_content=false
    ;;
  *)
    printf 'unknown contract\n' >&2
    exit 2
    ;;
esac

[[ -f "$instance" && ! -L "$instance" ]] || { printf 'instance must be a regular, non-symlink file\n' >&2; exit 1; }
bytes="$(wc -c < "$instance")"
[[ "$bytes" =~ ^[0-9]+$ ]] && (( bytes > 0 && bytes <= maximum_bytes )) || { printf 'instance size rejected\n' >&2; exit 1; }
command -v jsonschema >/dev/null 2>&1 || { printf 'jsonschema command is required\n' >&2; exit 1; }
jsonschema -V Draft202012Validator "$schema" -i "$instance" >/dev/null 2>&1 || { printf 'schema validation failed\n' >&2; exit 1; }

if [[ "$scan_content" == "true" ]]; then
  if grep -Eqi '"(certificate|certificates|private_key|public_key|passphrase|password|secret|token|credential|fingerprint|principal|namespace|url|uri|payload|video|audio|customer|client_name)"[[:space:]]*:' "$instance"; then
    printf 'prohibited sensitive or operational field\n' >&2
    exit 1
  fi
  if grep -Eqi -- '-----BEGIN [A-Z ]+-----|https?://|spiffe://' "$instance"; then
    printf 'prohibited trust material or operational locator\n' >&2
    exit 1
  fi
  if grep -Eqi 'ignore (all |any )?(previous|prior)|system prompt|developer message|reveal (the )?(prompt|secret)|execute (this|a )?(command|action)|call (the )?(gateway|tool)|curl[[:space:]]|wget[[:space:]]|sudo[[:space:]]' "$instance"; then
    printf 'prompt-injection or tool-use language rejected\n' >&2
    exit 1
  fi
fi

printf 'valid %s instance: %s\n' "$contract" "$(basename -- "$instance")"
