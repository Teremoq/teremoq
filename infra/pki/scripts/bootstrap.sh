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
if (( $# != 0 )); then echo "bootstrap.sh accepts no arguments" >&2; exit 64; fi

RUNTIME_DIR="${TEREMOQ_PKI_RUNTIME_DIR:-${PKI_ROOT}/runtime}"
mkdir -p -- "${RUNTIME_DIR}"
chmod 0700 "${RUNTIME_DIR}"
exec 9>"${RUNTIME_DIR}/.pki.lock"
flock 9

command -v docker >/dev/null || { echo "Docker is required" >&2; exit 1; }
docker info >/dev/null
for image in "${STEP_CA_IMAGE}" "${STEP_CLI_IMAGE}"; do
  docker pull "${image}" >/dev/null
  docker image inspect "${image}" >/dev/null
done

ca_complete=true
for required in config/ca.json certs/root_ca.crt certs/intermediate_ca.crt secrets/root_ca_key secrets/intermediate_ca_key secrets/password secrets/gateway-client-password secrets/relay-server-password secrets/relay-peer-password templates/gateway-client.tpl templates/relay-server.tpl templates/relay-peer.tpl; do
  [[ -f "${RUNTIME_DIR}/ca/${required}" ]] || ca_complete=false
done

if [[ -e "${RUNTIME_DIR}/ca" && "${ca_complete}" != true ]]; then
  echo "partial CA state detected; refusing to replace keys" >&2
  exit 1
fi

if [[ "${ca_complete}" != true ]]; then
  for path in trust identities env; do
    if [[ -e "${RUNTIME_DIR}/${path}" ]]; then echo "partial runtime state detected: ${path}" >&2; exit 1; fi
  done
  stage="$(mktemp -d "${RUNTIME_DIR}/.bootstrap.XXXXXX")"
  cleanup() { rm -rf -- "${stage}"; }
  trap cleanup EXIT INT TERM
  mkdir -m 0700 -p -- "${stage}/ca/certs" "${stage}/ca/config" "${stage}/ca/db" "${stage}/ca/secrets" "${stage}/ca/templates"

  for secret in password gateway-client-password relay-server-password relay-peer-password; do
    TEREMOQ_PKI_RUNTIME_DIR="${stage}" TEREMOQ_STEP_NETWORK=none \
      "${SCRIPT_DIR}/step-container.sh" crypto rand 64 --format alphanumeric > "${stage}/ca/secrets/${secret}"
    chmod 0600 "${stage}/ca/secrets/${secret}"
  done

  TEREMOQ_PKI_RUNTIME_DIR="${stage}" TEREMOQ_STEP_NETWORK=none \
    "${SCRIPT_DIR}/step-container.sh" ca init --deployment-type standalone \
    --name 'Teremoq Development CA' --dns localhost --dns step-ca --address ':9443' \
    --provisioner bootstrap \
    --password-file /home/step/secrets/password \
    --provisioner-password-file /home/step/secrets/password

  # step ca init intentionally creates the complete two-level layout first. Its
  # built-in CA lifetimes are then replaced inside this unpublished staging
  # directory using the official certificate profiles and configured durations.
  TEREMOQ_PKI_RUNTIME_DIR="${stage}" TEREMOQ_STEP_NETWORK=none \
    "${SCRIPT_DIR}/step-container.sh" certificate create 'Teremoq Development Root CA' \
    /home/step/certs/root_ca.new.crt /home/step/secrets/root_ca_key.new \
    --profile root-ca --not-after "${TEREMOQ_PKI_ROOT_DURATION}" --kty EC --curve P-256 \
    --password-file /home/step/secrets/password
  TEREMOQ_PKI_RUNTIME_DIR="${stage}" TEREMOQ_STEP_NETWORK=none \
    "${SCRIPT_DIR}/step-container.sh" certificate create 'Teremoq Development Intermediate CA' \
    /home/step/certs/intermediate_ca.new.crt /home/step/secrets/intermediate_ca_key.new \
    --profile intermediate-ca --ca /home/step/certs/root_ca.new.crt --ca-key /home/step/secrets/root_ca_key.new \
    --ca-password-file /home/step/secrets/password --password-file /home/step/secrets/password \
    --not-after "${TEREMOQ_PKI_INTERMEDIATE_DURATION}" --kty EC --curve P-256
  mv -- "${stage}/ca/certs/root_ca.new.crt" "${stage}/ca/certs/root_ca.crt"
  mv -- "${stage}/ca/secrets/root_ca_key.new" "${stage}/ca/secrets/root_ca_key"
  mv -- "${stage}/ca/certs/intermediate_ca.new.crt" "${stage}/ca/certs/intermediate_ca.crt"
  mv -- "${stage}/ca/secrets/intermediate_ca_key.new" "${stage}/ca/secrets/intermediate_ca_key"

  cp -- "${PKI_ROOT}/config/templates/gateway-client.tpl" "${stage}/ca/templates/gateway-client.tpl"
  cp -- "${PKI_ROOT}/config/templates/relay-server.tpl" "${stage}/ca/templates/relay-server.tpl"
  cp -- "${PKI_ROOT}/config/templates/relay-peer.tpl" "${stage}/ca/templates/relay-peer.tpl"
  cp -- "${PKI_ROOT}/config/ca-policy.json" "${stage}/ca/config/teremoq-policy.json"

  for profile in gateway-client relay-server relay-peer; do
    TEREMOQ_PKI_RUNTIME_DIR="${stage}" TEREMOQ_STEP_NETWORK=none \
      "${SCRIPT_DIR}/step-container.sh" ca provisioner add "${profile}" --type JWK --create \
      --ca-config /home/step/config/ca.json \
      --password-file "/home/step/secrets/${profile}-password" \
      --x509-template "/home/step/templates/${profile}.tpl" \
      --x509-min-dur 5m --x509-default-dur "${TEREMOQ_PKI_LEAF_DURATION}" --x509-max-dur "${TEREMOQ_PKI_LEAF_DURATION}"
  done
  TEREMOQ_PKI_RUNTIME_DIR="${stage}" TEREMOQ_STEP_NETWORK=none \
    "${SCRIPT_DIR}/step-container.sh" ca provisioner remove bootstrap --ca-config /home/step/config/ca.json

  find "${stage}/ca" -type d -exec chmod 0700 {} +
  find "${stage}/ca" -type f -exec chmod 0600 {} +
  chmod 0644 "${stage}/ca/certs/root_ca.crt" "${stage}/ca/certs/intermediate_ca.crt" "${stage}/ca/templates/"*.tpl
  mv -- "${stage}/ca" "${RUNTIME_DIR}/ca"
  trap - EXIT INT TERM
  rmdir -- "${stage}"
fi

mkdir -m 0700 -p -- "${RUNTIME_DIR}/trust" "${RUNTIME_DIR}/identities" "${RUNTIME_DIR}/env"
trust_temp="$(mktemp "${RUNTIME_DIR}/trust/.root-ca.pem.XXXXXX")"
fingerprint_temp="$(mktemp "${RUNTIME_DIR}/trust/.root-ca.sha256.XXXXXX")"
cleanup_trust() { rm -f -- "${trust_temp}" "${fingerprint_temp}"; }
trap cleanup_trust EXIT INT TERM
cp -- "${RUNTIME_DIR}/ca/certs/root_ca.crt" "${trust_temp}"
TEREMOQ_PKI_RUNTIME_DIR="${RUNTIME_DIR}" TEREMOQ_STEP_NETWORK=none \
  "${SCRIPT_DIR}/step-container.sh" certificate fingerprint /home/step/certs/root_ca.crt > "${fingerprint_temp}"
chmod 0644 "${trust_temp}" "${fingerprint_temp}"
mv -- "${trust_temp}" "${RUNTIME_DIR}/trust/root-ca.pem"
mv -- "${fingerprint_temp}" "${RUNTIME_DIR}/trust/root-ca.sha256"
trap - EXIT INT TERM

# Release the bootstrap lock before invoking scripts that acquire the same lock.
flock -u 9
"${SCRIPT_DIR}/start-ca.sh"

if [[ ! -e "${RUNTIME_DIR}/identities/relay-dev-1" ]]; then
  "${SCRIPT_DIR}/issue-identity.sh" --profile relay-server --id relay-dev-1 \
    --dns localhost --dns relay-dev-1 --dns moq-relay --ip 127.0.0.1 --ip ::1 \
    --uri spiffe://teremoq.local/relay/relay-dev-1
fi
if [[ ! -e "${RUNTIME_DIR}/identities/gateway-dev-1" ]]; then
  "${SCRIPT_DIR}/issue-identity.sh" --profile gateway-client --id gateway-dev-1 \
    --uri spiffe://teremoq.local/gateway/gateway-dev-1
fi

"${SCRIPT_DIR}/export-env.sh" --profile relay-server --id relay-dev-1
"${SCRIPT_DIR}/export-env.sh" --profile gateway-client --id gateway-dev-1
"${SCRIPT_DIR}/verify.sh"
echo "Teremoq development PKI bootstrap complete"
