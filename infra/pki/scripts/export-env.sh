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

identity_id=''
profile=''
while (( $# > 0 )); do
  case "$1" in
    --id|--profile)
      if (( $# < 2 )); then echo "missing value for $1" >&2; exit 64; fi
      if [[ "$1" == --id ]]; then identity_id="$2"; else profile="$2"; fi
      shift 2
      ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done
if [[ ! "${identity_id}" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then echo "invalid identity ID" >&2; exit 64; fi
case "${profile}" in gateway-client|relay-server|relay-peer) ;; *) echo "invalid profile" >&2; exit 64 ;; esac

RUNTIME_DIR="${TEREMOQ_PKI_RUNTIME_DIR:-${PKI_ROOT}/runtime}"
IDENTITY_DIR="${RUNTIME_DIR}/identities/${identity_id}"
ENV_DIR="${RUNTIME_DIR}/env"
FINAL_FILE="${ENV_DIR}/${identity_id}.env"
mkdir -p -- "${ENV_DIR}"
exec 9>"${RUNTIME_DIR}/.pki.lock"
flock 9
for file in fullchain.pem key.pem; do
  if [[ ! -f "${IDENTITY_DIR}/${file}" ]]; then echo "identity is incomplete: ${identity_id}" >&2; exit 1; fi
done
if [[ ! -f "${RUNTIME_DIR}/trust/root-ca.pem" ]]; then echo "trust root is missing" >&2; exit 1; fi

temp_file="$(mktemp "${ENV_DIR}/.${identity_id}.env.XXXXXX")"
cleanup() { rm -f -- "${temp_file}"; }
trap cleanup EXIT INT TERM
if [[ "${profile}" == gateway-client ]]; then
  printf 'export TEREMOQ_MOQ_TLS_ROOT=%q\n' "${RUNTIME_DIR}/trust/root-ca.pem" > "${temp_file}"
  printf 'export TEREMOQ_MOQ_TLS_CLIENT_CERT=%q\n' "${IDENTITY_DIR}/fullchain.pem" >> "${temp_file}"
  printf 'export TEREMOQ_MOQ_TLS_CLIENT_KEY=%q\n' "${IDENTITY_DIR}/key.pem" >> "${temp_file}"
  printf 'export TEREMOQ_MOQ_RELAY_URL=%q\n' 'https://localhost:4443/publish' >> "${temp_file}"
elif [[ "${profile}" == relay-server ]]; then
  printf 'export TEREMOQ_DEV_MTLS_RELAY_TLS_CERT=%q\n' "${IDENTITY_DIR}/fullchain.pem" > "${temp_file}"
  printf 'export TEREMOQ_DEV_MTLS_RELAY_TLS_KEY=%q\n' "${IDENTITY_DIR}/key.pem" >> "${temp_file}"
  printf 'export TEREMOQ_DEV_MTLS_RELAY_CLIENT_CA=%q\n' "${RUNTIME_DIR}/trust/root-ca.pem" >> "${temp_file}"
  printf 'export TEREMOQ_DEV_MTLS_RELAY_BIND=%q\n' '127.0.0.1:4443' >> "${temp_file}"
else
  echo "relay-peer has no Task 02 env contract" >&2
  exit 64
fi
chmod 0600 "${temp_file}"
mv -- "${temp_file}" "${FINAL_FILE}"
trap - EXIT INT TERM
echo "wrote ${FINAL_FILE}"
