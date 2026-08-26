#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PKI_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
REPO_ROOT="$(cd -- "${PKI_ROOT}/../.." && pwd -P)"
# shellcheck disable=SC1091
source "${PKI_ROOT}/versions.env"
: "${STEP_CA_IMAGE:?STEP_CA_IMAGE is required}"
: "${STEP_CLI_IMAGE:?STEP_CLI_IMAGE is required}"

if (( $# != 0 )); then
  echo "stop-ca.sh accepts no arguments" >&2
  exit 64
fi

RUNTIME_DIR="${TEREMOQ_PKI_RUNTIME_DIR:-${PKI_ROOT}/runtime}"
PROJECT="${TEREMOQ_PKI_PROJECT:-teremoq-pki}"
NETWORK="${TEREMOQ_PKI_NETWORK:-teremoq-pki-net}"
mkdir -p -- "${RUNTIME_DIR}"
exec 9>"${RUNTIME_DIR}/.pki.lock"
flock 9

STEP_CA_IMAGE="${STEP_CA_IMAGE}" \
TEREMOQ_PKI_RUNTIME_DIR="${RUNTIME_DIR}" \
TEREMOQ_PKI_UID="$(id -u)" \
TEREMOQ_PKI_GID="$(id -g)" \
TEREMOQ_PKI_NETWORK="${NETWORK}" \
docker compose --project-name "${PROJECT}" --project-directory "${PKI_ROOT}" -f "${PKI_ROOT}/compose.yaml" down --remove-orphans
