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

profile=''
identity_id=''
declare -a dns_names=()
declare -a ip_addresses=()
declare -a requested_uris=()

while (( $# > 0 )); do
  case "$1" in
    --profile|--id|--dns|--ip|--uri)
      if (( $# < 2 )); then echo "missing value for $1" >&2; exit 64; fi
      case "$1" in
        --profile) profile="$2" ;;
        --id) identity_id="$2" ;;
        --dns) dns_names+=("$2") ;;
        --ip) ip_addresses+=("$2") ;;
        --uri) requested_uris+=("$2") ;;
      esac
      shift 2
      ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

if [[ ! "${identity_id}" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
  echo "invalid identity ID" >&2
  exit 64
fi
case "${profile}" in
  gateway-client|relay-server|relay-peer) ;;
  *) echo "invalid profile" >&2; exit 64 ;;
esac

for dns in "${dns_names[@]}"; do
  if [[ ! "${dns}" =~ ^[A-Za-z0-9.-]{1,253}$ || "${dns}" == .* || "${dns}" == *. ]]; then
    echo "invalid DNS SAN" >&2
    exit 64
  fi
done
for ip in "${ip_addresses[@]}"; do
  if [[ ! "${ip}" =~ ^[0-9A-Fa-f:.]{2,45}$ ]]; then
    echo "invalid IP SAN" >&2
    exit 64
  fi
done

case "${profile}" in
  gateway-client)
    expected_uri="spiffe://teremoq.local/gateway/${identity_id}"
    if (( ${#dns_names[@]} != 0 || ${#ip_addresses[@]} != 0 )); then
      echo "gateway-client accepts only its required URI SAN" >&2
      exit 64
    fi
    ;;
  relay-server|relay-peer)
    expected_uri="spiffe://teremoq.local/relay/${identity_id}"
    ;;
esac
for uri in "${requested_uris[@]}"; do
  if [[ "${uri}" != "${expected_uri}" ]]; then
    echo "profile requires URI SAN ${expected_uri}" >&2
    exit 64
  fi
done

RUNTIME_DIR="${TEREMOQ_PKI_RUNTIME_DIR:-${PKI_ROOT}/runtime}"
NETWORK="${TEREMOQ_PKI_NETWORK:-teremoq-pki-net}"
CA_URL="https://step-ca:9443"
IDENTITIES_DIR="${RUNTIME_DIR}/identities"
FINAL_DIR="${IDENTITIES_DIR}/${identity_id}"
mkdir -p -- "${IDENTITIES_DIR}"
exec 9>"${RUNTIME_DIR}/.pki.lock"
flock 9

if [[ -e "${FINAL_DIR}" ]]; then
  echo "identity already exists: ${identity_id}" >&2
  exit 1
fi

temp_dir="$(mktemp -d "${IDENTITIES_DIR}/.issue-${identity_id}.XXXXXX")"
cleanup() { rm -rf -- "${temp_dir}"; }
trap cleanup EXIT INT TERM

declare -a san_args=(--san "${expected_uri}")
for dns in "${dns_names[@]}"; do san_args+=(--san "${dns}"); done
for ip in "${ip_addresses[@]}"; do san_args+=(--san "${ip}"); done

TEREMOQ_PKI_RUNTIME_DIR="${RUNTIME_DIR}" TEREMOQ_STEP_NETWORK="${NETWORK}" \
  "${SCRIPT_DIR}/step-container.sh" ca certificate "${identity_id}" \
  "/runtime/identities/$(basename -- "${temp_dir}")/cert.pem" \
  "/runtime/identities/$(basename -- "${temp_dir}")/key.pem" \
  --provisioner "${profile}" \
  --provisioner-password-file "/home/step/secrets/${profile}-password" \
  --ca-url "${CA_URL}" --root /home/step/certs/root_ca.crt \
  --kty EC --curve P-256 --not-after "${TEREMOQ_PKI_LEAF_DURATION}" \
  "${san_args[@]}"

TEREMOQ_PKI_RUNTIME_DIR="${RUNTIME_DIR}" TEREMOQ_STEP_NETWORK=none \
  "${SCRIPT_DIR}/step-container.sh" certificate bundle \
  "/runtime/identities/$(basename -- "${temp_dir}")/cert.pem" \
  /home/step/certs/intermediate_ca.crt \
  "/runtime/identities/$(basename -- "${temp_dir}")/fullchain.pem"
TEREMOQ_PKI_RUNTIME_DIR="${RUNTIME_DIR}" TEREMOQ_STEP_NETWORK=none \
  "${SCRIPT_DIR}/step-container.sh" certificate fingerprint \
  "/runtime/identities/$(basename -- "${temp_dir}")/cert.pem" > "${temp_dir}/cert.sha256"

fingerprint="$(tr -d '\r\n' < "${temp_dir}/cert.sha256")"
printf '{\n  "schema_version": 1,\n  "id": "%s",\n  "profile": "%s",\n  "uri_san": "%s",\n  "certificate_fingerprint_sha256": "%s"\n}\n' \
  "${identity_id}" "${profile}" "${expected_uri}" "${fingerprint}" > "${temp_dir}/metadata.json"

chmod 0600 "${temp_dir}/key.pem"
chmod 0644 "${temp_dir}/cert.pem" "${temp_dir}/fullchain.pem" "${temp_dir}/cert.sha256" "${temp_dir}/metadata.json"
chmod 0700 "${temp_dir}"
mv -- "${temp_dir}" "${FINAL_DIR}"
trap - EXIT INT TERM
echo "issued ${profile} identity ${identity_id}; fingerprint ${fingerprint}"
