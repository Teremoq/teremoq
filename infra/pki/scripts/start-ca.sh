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
  echo "start-ca.sh accepts no arguments" >&2
  exit 64
fi

RUNTIME_DIR="${TEREMOQ_PKI_RUNTIME_DIR:-${PKI_ROOT}/runtime}"
PROJECT="${TEREMOQ_PKI_PROJECT:-teremoq-pki}"
NETWORK="${TEREMOQ_PKI_NETWORK:-teremoq-pki-net}"
LOCK_FILE="${RUNTIME_DIR}/.pki.lock"
CA_URL="https://step-ca:9443"

mkdir -p -- "${RUNTIME_DIR}"
exec 9>"${LOCK_FILE}"
flock 9

for required in config/ca.json certs/root_ca.crt certs/intermediate_ca.crt secrets/intermediate_ca_key secrets/password; do
  if [[ ! -f "${RUNTIME_DIR}/ca/${required}" ]]; then
    echo "CA is not complete; missing runtime/ca/${required}" >&2
    exit 1
  fi
done

STEP_CA_IMAGE="${STEP_CA_IMAGE}" \
TEREMOQ_PKI_RUNTIME_DIR="${RUNTIME_DIR}" \
TEREMOQ_PKI_UID="$(id -u)" \
TEREMOQ_PKI_GID="$(id -g)" \
TEREMOQ_PKI_NETWORK="${NETWORK}" \
docker compose --project-name "${PROJECT}" --project-directory "${PKI_ROOT}" -f "${PKI_ROOT}/compose.yaml" up -d

deadline=$((SECONDS + 90))
until TEREMOQ_PKI_RUNTIME_DIR="${RUNTIME_DIR}" TEREMOQ_STEP_NETWORK="${NETWORK}" \
  "${SCRIPT_DIR}/step-container.sh" ca health --ca-url "${CA_URL}" --root /home/step/certs/root_ca.crt >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    echo "step-ca did not become ready within 90 seconds" >&2
    STEP_CA_IMAGE="${STEP_CA_IMAGE}" TEREMOQ_PKI_RUNTIME_DIR="${RUNTIME_DIR}" TEREMOQ_PKI_NETWORK="${NETWORK}" \
      docker compose --project-name "${PROJECT}" --project-directory "${PKI_ROOT}" -f "${PKI_ROOT}/compose.yaml" ps >&2 || true
    exit 1
  fi
  sleep 2
done

echo "step-ca is healthy on loopback port ${TEREMOQ_PKI_BIND_PORT:-9443}"
