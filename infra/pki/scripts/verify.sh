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
if (( $# != 0 )); then echo "verify.sh accepts no arguments" >&2; exit 64; fi

RUNTIME_DIR="${TEREMOQ_PKI_RUNTIME_DIR:-${PKI_ROOT}/runtime}"
NETWORK="${TEREMOQ_PKI_NETWORK:-teremoq-pki-net}"
root="${RUNTIME_DIR}/trust/root-ca.pem"
intermediate="${RUNTIME_DIR}/ca/certs/intermediate_ca.crt"

TEREMOQ_PKI_RUNTIME_DIR="${RUNTIME_DIR}" TEREMOQ_STEP_NETWORK="${NETWORK}" \
  "${SCRIPT_DIR}/step-container.sh" ca health --ca-url https://step-ca:9443 --root /home/step/certs/root_ca.crt >/dev/null

for identity_id in gateway-dev-1 relay-dev-1; do
  identity_dir="${RUNTIME_DIR}/identities/${identity_id}"
  for file in cert.pem fullchain.pem key.pem cert.sha256 metadata.json; do
    [[ -f "${identity_dir}/${file}" ]] || { echo "missing ${identity_id}/${file}" >&2; exit 1; }
  done
  TEREMOQ_PKI_RUNTIME_DIR="${RUNTIME_DIR}" TEREMOQ_STEP_NETWORK=none \
    "${SCRIPT_DIR}/step-container.sh" certificate verify "/runtime/identities/${identity_id}/fullchain.pem" \
    --roots /home/step/certs/root_ca.crt
  expected="$(TEREMOQ_PKI_RUNTIME_DIR="${RUNTIME_DIR}" TEREMOQ_STEP_NETWORK=none "${SCRIPT_DIR}/step-container.sh" certificate fingerprint "/runtime/identities/${identity_id}/cert.pem" | tr -d '\r\n')"
  actual="$(tr -d '\r\n' < "${identity_dir}/cert.sha256")"
  [[ "${expected}" == "${actual}" ]] || { echo "fingerprint mismatch for ${identity_id}" >&2; exit 1; }
done

gateway_text="$(openssl x509 -in "${RUNTIME_DIR}/identities/gateway-dev-1/cert.pem" -noout -text)"
relay_text="$(openssl x509 -in "${RUNTIME_DIR}/identities/relay-dev-1/cert.pem" -noout -text)"
[[ "${gateway_text}" == *'TLS Web Client Authentication'* ]]
[[ "${gateway_text}" != *'TLS Web Server Authentication'* ]]
[[ "${gateway_text}" == *'CA:FALSE'* ]]
[[ "${gateway_text}" == *'ASN1 OID: prime256v1'* ]]
[[ "${gateway_text}" == *'URI:spiffe://teremoq.local/gateway/gateway-dev-1'* ]]
[[ "${relay_text}" == *'TLS Web Server Authentication'* ]]
[[ "${relay_text}" != *'TLS Web Client Authentication'* ]]
[[ "${relay_text}" == *'CA:FALSE'* ]]
[[ "${relay_text}" == *'ASN1 OID: prime256v1'* ]]
for san in 'DNS:localhost' 'DNS:relay-dev-1' 'DNS:moq-relay' 'IP Address:127.0.0.1' 'IP Address:0:0:0:0:0:0:0:1' 'URI:spiffe://teremoq.local/relay/relay-dev-1'; do
  [[ "${relay_text}" == *"${san}"* ]] || { echo "relay SAN missing: ${san}" >&2; exit 1; }
done
openssl verify -purpose sslclient -CAfile "${root}" -untrusted "${intermediate}" "${RUNTIME_DIR}/identities/gateway-dev-1/cert.pem" >/dev/null
if openssl verify -purpose sslserver -CAfile "${root}" -untrusted "${intermediate}" "${RUNTIME_DIR}/identities/gateway-dev-1/cert.pem" >/dev/null 2>&1; then echo "gateway incorrectly valid for sslserver" >&2; exit 1; fi
openssl verify -purpose sslserver -CAfile "${root}" -untrusted "${intermediate}" "${RUNTIME_DIR}/identities/relay-dev-1/cert.pem" >/dev/null
if openssl verify -purpose sslclient -CAfile "${root}" -untrusted "${intermediate}" "${RUNTIME_DIR}/identities/relay-dev-1/cert.pem" >/dev/null 2>&1; then echo "relay incorrectly valid for sslclient" >&2; exit 1; fi

echo "PKI verification passed"
