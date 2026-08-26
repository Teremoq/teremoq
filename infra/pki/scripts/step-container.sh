#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PKI_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
REPO_ROOT="$(cd -- "${PKI_ROOT}/../.." && pwd -P)"
VERSIONS_FILE="${PKI_ROOT}/versions.env"

# shellcheck disable=SC1090
source "${VERSIONS_FILE}"
: "${STEP_CLI_IMAGE:?STEP_CLI_IMAGE is required}"

if (( $# == 0 )); then
  echo "usage: step-container.sh STEP_ARGUMENT..." >&2
  exit 64
fi

RUNTIME_DIR="${TEREMOQ_PKI_RUNTIME_DIR:-${PKI_ROOT}/runtime}"
CA_RUNTIME_DIR="${RUNTIME_DIR}/ca"
NETWORK="${TEREMOQ_STEP_NETWORK:-${TEREMOQ_PKI_NETWORK:-teremoq-pki-net}}"

mkdir -p -- "${CA_RUNTIME_DIR}"

exec docker run --rm \
  --user "$(id -u):$(id -g)" \
  --network "${NETWORK}" \
  --env HOME=/home/step \
  --mount "type=bind,src=${PKI_ROOT},dst=/pki,readonly" \
  --mount "type=bind,src=${RUNTIME_DIR},dst=/runtime" \
  --mount "type=bind,src=${CA_RUNTIME_DIR},dst=/home/step" \
  --workdir /home/step \
  "${STEP_CLI_IMAGE}" step "$@"
