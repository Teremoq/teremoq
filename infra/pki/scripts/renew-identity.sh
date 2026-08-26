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
while (( $# > 0 )); do
  case "$1" in
    --id) if (( $# < 2 )); then echo "missing value for --id" >&2; exit 64; fi; identity_id="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done
if [[ ! "${identity_id}" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then echo "invalid identity ID" >&2; exit 64; fi

RUNTIME_DIR="${TEREMOQ_PKI_RUNTIME_DIR:-${PKI_ROOT}/runtime}"
NETWORK="${TEREMOQ_PKI_NETWORK:-teremoq-pki-net}"
IDENTITY_DIR="${RUNTIME_DIR}/identities/${identity_id}"
exec 9>"${RUNTIME_DIR}/.pki.lock"
flock 9
for file in cert.pem fullchain.pem key.pem cert.sha256 metadata.json; do
  if [[ ! -f "${IDENTITY_DIR}/${file}" ]]; then echo "identity is incomplete: ${identity_id}" >&2; exit 1; fi
done

profile="$(sed -n 's/^[[:space:]]*"profile": "\([a-z-]*\)",*$/\1/p' "${IDENTITY_DIR}/metadata.json")"
case "${profile}" in gateway-client|relay-server|relay-peer) ;; *) echo "invalid identity metadata" >&2; exit 1 ;; esac
uri="$(sed -n 's/^[[:space:]]*"uri_san": "\([^"]*\)",*$/\1/p' "${IDENTITY_DIR}/metadata.json")"

temp_dir="$(mktemp -d "${IDENTITY_DIR}/.renew.XXXXXX")"
cleanup() { rm -rf -- "${temp_dir}"; }
trap cleanup EXIT INT TERM

TEREMOQ_PKI_RUNTIME_DIR="${RUNTIME_DIR}" TEREMOQ_STEP_NETWORK="${NETWORK}" \
  "${SCRIPT_DIR}/step-container.sh" ca renew \
  "/runtime/identities/${identity_id}/cert.pem" "/runtime/identities/${identity_id}/key.pem" \
  --out "/runtime/identities/${identity_id}/$(basename -- "${temp_dir}")/cert.pem" \
  --force --ca-url https://step-ca:9443 --root /home/step/certs/root_ca.crt
TEREMOQ_PKI_RUNTIME_DIR="${RUNTIME_DIR}" TEREMOQ_STEP_NETWORK=none \
  "${SCRIPT_DIR}/step-container.sh" certificate bundle \
  "/runtime/identities/${identity_id}/$(basename -- "${temp_dir}")/cert.pem" \
  /home/step/certs/intermediate_ca.crt \
  "/runtime/identities/${identity_id}/$(basename -- "${temp_dir}")/fullchain.pem"
TEREMOQ_PKI_RUNTIME_DIR="${RUNTIME_DIR}" TEREMOQ_STEP_NETWORK=none \
  "${SCRIPT_DIR}/step-container.sh" certificate fingerprint \
  "/runtime/identities/${identity_id}/$(basename -- "${temp_dir}")/cert.pem" > "${temp_dir}/cert.sha256"

fingerprint="$(tr -d '\r\n' < "${temp_dir}/cert.sha256")"
printf '{\n  "schema_version": 1,\n  "id": "%s",\n  "profile": "%s",\n  "uri_san": "%s",\n  "certificate_fingerprint_sha256": "%s"\n}\n' \
  "${identity_id}" "${profile}" "${uri}" "${fingerprint}" > "${temp_dir}/metadata.json"
chmod 0644 "${temp_dir}/cert.pem" "${temp_dir}/fullchain.pem" "${temp_dir}/cert.sha256" "${temp_dir}/metadata.json"

mv -- "${temp_dir}/cert.pem" "${IDENTITY_DIR}/cert.pem"
mv -- "${temp_dir}/fullchain.pem" "${IDENTITY_DIR}/fullchain.pem"
mv -- "${temp_dir}/cert.sha256" "${IDENTITY_DIR}/cert.sha256"
mv -- "${temp_dir}/metadata.json" "${IDENTITY_DIR}/metadata.json"
trap - EXIT INT TERM
rmdir -- "${temp_dir}"
echo "renewed ${identity_id}; fingerprint ${fingerprint}"
