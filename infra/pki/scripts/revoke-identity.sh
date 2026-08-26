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
reason='Cessation of operation'
while (( $# > 0 )); do
  case "$1" in
    --id|--reason)
      if (( $# < 2 )); then echo "missing value for $1" >&2; exit 64; fi
      if [[ "$1" == --id ]]; then identity_id="$2"; else reason="$2"; fi
      shift 2
      ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done
if [[ ! "${identity_id}" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then echo "invalid identity ID" >&2; exit 64; fi
if [[ -z "${reason}" || ${#reason} -gt 128 || "${reason}" == *$'\n'* || "${reason}" == *$'\r'* ]]; then echo "invalid revocation reason" >&2; exit 64; fi

RUNTIME_DIR="${TEREMOQ_PKI_RUNTIME_DIR:-${PKI_ROOT}/runtime}"
NETWORK="${TEREMOQ_PKI_NETWORK:-teremoq-pki-net}"
IDENTITY_DIR="${RUNTIME_DIR}/identities/${identity_id}"
exec 9>"${RUNTIME_DIR}/.pki.lock"
flock 9
for file in cert.pem key.pem; do
  if [[ ! -f "${IDENTITY_DIR}/${file}" ]]; then echo "identity is incomplete: ${identity_id}" >&2; exit 1; fi
done

TEREMOQ_PKI_RUNTIME_DIR="${RUNTIME_DIR}" TEREMOQ_STEP_NETWORK="${NETWORK}" \
  "${SCRIPT_DIR}/step-container.sh" ca revoke \
  --cert "/runtime/identities/${identity_id}/cert.pem" \
  --key "/runtime/identities/${identity_id}/key.pem" \
  --reason "${reason}" --reasonCode CessationOfOperation \
  --ca-url https://step-ca:9443 --root /home/step/certs/root_ca.crt
echo "revocation registered for ${identity_id}"
