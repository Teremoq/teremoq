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
if (( $# != 0 )); then echo "pki-smoke.sh accepts no arguments" >&2; exit 64; fi

expected_ca='smallstep/step-ca:0.30.2@sha256:a2b17872915c193259b75a5474c398326f41bd199f0842093e52cf4182bc8270'
expected_cli='smallstep/step-cli:0.30.6@sha256:474768dd54700088e9480210eaf2c25e3041ed1e8302c7cf211725381cec9f5e'
[[ "${STEP_CA_IMAGE}" == "${expected_ca}" ]]
[[ "${STEP_CLI_IMAGE}" == "${expected_cli}" ]]
bash -n "${PKI_ROOT}/scripts/"*.sh "${PKI_ROOT}/tests/"*.sh
if rg -n 'image:[[:space:]]*[^#[:space:]]*:latest|smallstep/[^@[:space:]]+$' "${PKI_ROOT}" -g '*.yaml' -g '*.env'; then echo "floating image found" >&2; exit 1; fi

test_root="$(mktemp -d /tmp/teremoq-pki-smoke.XXXXXX)"
runtime="${test_root}/runtime"
project="teremoq-pki-smoke-$$"
network="${project}-net"
mkdir -m 0700 "${runtime}"
cleanup() {
  TEREMOQ_PKI_RUNTIME_DIR="${runtime}" TEREMOQ_PKI_PROJECT="${project}" TEREMOQ_PKI_NETWORK="${network}" TEREMOQ_PKI_BIND_PORT=0 \
    "${PKI_ROOT}/scripts/stop-ca.sh" >/dev/null 2>&1 || true
  rm -rf -- "${test_root}"
}
trap cleanup EXIT INT TERM
export TEREMOQ_PKI_RUNTIME_DIR="${runtime}"
export TEREMOQ_PKI_PROJECT="${project}"
export TEREMOQ_PKI_NETWORK="${network}"
export TEREMOQ_PKI_BIND_PORT=0

"${PKI_ROOT}/scripts/bootstrap.sh"
root_fp_before="$(tr -d '\r\n' < "${runtime}/trust/root-ca.sha256")"
gateway_fp_before="$(tr -d '\r\n' < "${runtime}/identities/gateway-dev-1/cert.sha256")"
relay_fp_before="$(tr -d '\r\n' < "${runtime}/identities/relay-dev-1/cert.sha256")"
"${PKI_ROOT}/scripts/bootstrap.sh"
[[ "${root_fp_before}" == "$(tr -d '\r\n' < "${runtime}/trust/root-ca.sha256")" ]]
[[ "${gateway_fp_before}" == "$(tr -d '\r\n' < "${runtime}/identities/gateway-dev-1/cert.sha256")" ]]
[[ "${relay_fp_before}" == "$(tr -d '\r\n' < "${runtime}/identities/relay-dev-1/cert.sha256")" ]]
"${PKI_ROOT}/scripts/verify.sh"

root="${runtime}/trust/root-ca.pem"
intermediate="${runtime}/ca/certs/intermediate_ca.crt"
gateway="${runtime}/identities/gateway-dev-1/cert.pem"
relay="${runtime}/identities/relay-dev-1/cert.pem"
openssl verify -purpose sslclient -CAfile "${root}" -untrusted "${intermediate}" "${gateway}" >/dev/null
! openssl verify -purpose sslserver -CAfile "${root}" -untrusted "${intermediate}" "${gateway}" >/dev/null 2>&1
openssl verify -purpose sslserver -CAfile "${root}" -untrusted "${intermediate}" "${relay}" >/dev/null
! openssl verify -purpose sslclient -CAfile "${root}" -untrusted "${intermediate}" "${relay}" >/dev/null 2>&1

peer_id="smoke-peer-$$"
"${PKI_ROOT}/scripts/issue-identity.sh" --profile relay-peer --id "${peer_id}" --dns "${peer_id}"
peer="${runtime}/identities/${peer_id}/cert.pem"
openssl verify -purpose sslserver -CAfile "${root}" -untrusted "${intermediate}" "${peer}" >/dev/null
openssl verify -purpose sslclient -CAfile "${root}" -untrusted "${intermediate}" "${peer}" >/dev/null
peer_text="$(openssl x509 -in "${peer}" -noout -text)"
[[ "${peer_text}" == *'TLS Web Server Authentication'* ]]
[[ "${peer_text}" == *'TLS Web Client Authentication'* ]]
[[ "${peer_text}" == *"URI:spiffe://teremoq.local/relay/${peer_id}"* ]]

grep -Fx "export TEREMOQ_MOQ_TLS_ROOT=${runtime}/trust/root-ca.pem" "${runtime}/env/gateway-dev-1.env" >/dev/null
grep -Fx "export TEREMOQ_MOQ_TLS_CLIENT_CERT=${runtime}/identities/gateway-dev-1/fullchain.pem" "${runtime}/env/gateway-dev-1.env" >/dev/null
grep -Fx "export TEREMOQ_MOQ_TLS_CLIENT_KEY=${runtime}/identities/gateway-dev-1/key.pem" "${runtime}/env/gateway-dev-1.env" >/dev/null
grep -Fx 'export TEREMOQ_MOQ_RELAY_URL=https://localhost:4443/publish' "${runtime}/env/gateway-dev-1.env" >/dev/null
grep -Fx "export TEREMOQ_DEV_MTLS_RELAY_TLS_CERT=${runtime}/identities/relay-dev-1/fullchain.pem" "${runtime}/env/relay-dev-1.env" >/dev/null
grep -Fx "export TEREMOQ_DEV_MTLS_RELAY_TLS_KEY=${runtime}/identities/relay-dev-1/key.pem" "${runtime}/env/relay-dev-1.env" >/dev/null
grep -Fx "export TEREMOQ_DEV_MTLS_RELAY_CLIENT_CA=${runtime}/trust/root-ca.pem" "${runtime}/env/relay-dev-1.env" >/dev/null
grep -Fx 'export TEREMOQ_DEV_MTLS_RELAY_BIND=127.0.0.1:4443' "${runtime}/env/relay-dev-1.env" >/dev/null
gateway_exported="$(bash -c 'source "$1"; env | sed -n "s/^TEREMOQ_MOQ_TLS_ROOT=.*/exported/p"' _ "${runtime}/env/gateway-dev-1.env")"
relay_exported="$(bash -c 'source "$1"; env | sed -n "s/^TEREMOQ_DEV_MTLS_RELAY_TLS_CERT=.*/exported/p"' _ "${runtime}/env/relay-dev-1.env")"
[[ "${gateway_exported}" == exported ]]
[[ "${relay_exported}" == exported ]]
if rg -i 'password|token' "${runtime}/env"; then echo "secret marker found in exported env" >&2; exit 1; fi

pub_dir="$(mktemp -d "${runtime}/.pubcheck.XXXXXX")"
for identity_id in gateway-dev-1 relay-dev-1; do
  TEREMOQ_STEP_NETWORK=none "${PKI_ROOT}/scripts/step-container.sh" certificate key "/runtime/identities/${identity_id}/cert.pem" --out "/runtime/$(basename -- "${pub_dir}")/${identity_id}.cert.pub"
  TEREMOQ_STEP_NETWORK=none "${PKI_ROOT}/scripts/step-container.sh" crypto key public "/runtime/identities/${identity_id}/key.pem" --out "/runtime/$(basename -- "${pub_dir}")/${identity_id}.key.pub"
  cmp "${pub_dir}/${identity_id}.cert.pub" "${pub_dir}/${identity_id}.key.pub"
done
rm -rf -- "${pub_dir}"

for directory in "${runtime}" "${runtime}/ca" "${runtime}/ca/secrets" "${runtime}/identities" "${runtime}/identities/gateway-dev-1" "${runtime}/identities/relay-dev-1"; do
  [[ "$(stat -c '%a' "${directory}")" == 700 ]]
done
for secret in "${runtime}/ca/secrets/"* "${runtime}/identities/"*/key.pem; do [[ "$(stat -c '%a' "${secret}")" == 600 ]]; done
for public_file in "${runtime}/trust/"* "${runtime}/identities/"*/cert.pem "${runtime}/identities/"*/fullchain.pem "${runtime}/identities/"*/cert.sha256 "${runtime}/identities/"*/metadata.json; do [[ "$(stat -c '%a' "${public_file}")" == 644 ]]; done

if "${PKI_ROOT}/scripts/issue-identity.sh" --profile gateway-client --id '../escape' >/dev/null 2>&1; then echo "path traversal ID accepted" >&2; exit 1; fi
if "${PKI_ROOT}/scripts/issue-identity.sh" --profile gateway-client --id $'bad\nname' >/dev/null 2>&1; then echo "newline ID accepted" >&2; exit 1; fi
if "${PKI_ROOT}/scripts/issue-identity.sh" --profile gateway-client --id gateway-dev-1 >/dev/null 2>&1; then echo "identity overwrite accepted" >&2; exit 1; fi

smoke_id="smoke-renew-$$"
"${PKI_ROOT}/scripts/issue-identity.sh" --profile gateway-client --id "${smoke_id}"
old_fp="$(tr -d '\r\n' < "${runtime}/identities/${smoke_id}/cert.sha256")"
"${PKI_ROOT}/scripts/renew-identity.sh" --id "${smoke_id}"
new_fp="$(tr -d '\r\n' < "${runtime}/identities/${smoke_id}/cert.sha256")"
[[ "${old_fp}" != "${new_fp}" ]]
"${PKI_ROOT}/scripts/revoke-identity.sh" --id "${smoke_id}" --reason 'PKI smoke test'
if "${PKI_ROOT}/scripts/renew-identity.sh" --id "${smoke_id}" >/dev/null 2>&1; then echo "revoked certificate renewed" >&2; exit 1; fi

if find "${runtime}" -type d \( -name '.issue-*' -o -name '.renew.*' -o -name '.bootstrap.*' -o -name '.pubcheck.*' \) -print -quit | grep -q .; then echo "temporary artifact remains" >&2; exit 1; fi
if find "${PKI_ROOT}" -path "${PKI_ROOT}/runtime" -prune -o -type f -print0 | \
  xargs -0 -r rg -l 'BEGIN (RSA |EC |ENCRYPTED )?PRIVATE KEY' | grep -q .; then
  echo "private key outside runtime" >&2
  exit 1
fi
if find "${PKI_ROOT}" -path "${PKI_ROOT}/runtime" -prune -o -type f \( -iname '*password*' -o -iname '*.token' -o -iname '*-token.*' \) -print -quit | grep -q .; then echo "secret-like file outside runtime" >&2; exit 1; fi

echo "PKI smoke test passed"
