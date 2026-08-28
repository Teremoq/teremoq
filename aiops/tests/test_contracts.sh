#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AIOPS_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
VALIDATOR="${SCRIPT_DIR}/validate_instance.sh"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

expect_valid() {
  "$VALIDATOR" "$1" "$2" >/dev/null
}

expect_invalid() {
  if "$VALIDATOR" "$1" "$2" >/dev/null 2>&1; then
    printf 'expected rejection: %s\n' "$2" >&2
    exit 1
  fi
}

expect_valid observation "${AIOPS_DIR}/fixtures/valid/observation-object-drop.json"
expect_valid observation "${AIOPS_DIR}/fixtures/valid/observation-federation-capacity.json"
expect_valid recommendation "${AIOPS_DIR}/fixtures/valid/recommendation-dry-run.json"
expect_valid model-manifest "${AIOPS_DIR}/model-manifest.json"

for fixture in \
  observation-extra-field.json \
  observation-high-cardinality.json \
  observation-sensitive-data.json \
  observation-operational-identity.json \
  observation-media-payload.json \
  observation-limits.json; do
  expect_invalid observation "${AIOPS_DIR}/fixtures/invalid/${fixture}"
done

for fixture in \
  recommendation-prompt-injection.json \
  recommendation-unauthorized-action.json \
  recommendation-malformed.json; do
  expect_invalid recommendation "${AIOPS_DIR}/fixtures/invalid/${fixture}"
done

expect_invalid execution "${AIOPS_DIR}/fixtures/invalid/execution-disabled.json"
expect_invalid model-manifest "${AIOPS_DIR}/fixtures/invalid/model-missing-license.json"

head -c 17000 /dev/zero | tr '\000' 'x' > "${TEMP_DIR}/oversized.json"
expect_invalid observation "${TEMP_DIR}/oversized.json"

jsonschema -V Draft202012Validator \
  --base-uri "file://${AIOPS_DIR}/" \
  "${AIOPS_DIR}/agents_schema.json" \
  -i "${AIOPS_DIR}/fixtures/valid/recommendation-dry-run.json" >/dev/null 2>&1

if jsonschema -V Draft202012Validator \
  --base-uri "file://${AIOPS_DIR}/" \
  "${AIOPS_DIR}/agents_schema.json" \
  -i "${AIOPS_DIR}/fixtures/invalid/legacy-agent-message.json" >/dev/null 2>&1; then
  printf '%s\n' 'legacy agent format was unexpectedly accepted' >&2
  exit 1
fi

expect_invalid recommendation "${AIOPS_DIR}/fixtures/invalid/execution-disabled.json"
printf '%s\n' 'contract tests: PASS'
