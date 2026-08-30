#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
(( $# == 2 )) && [[ "$1" == --config ]] || lan_die 'usage: prepare-pki-plan.sh --config ABSOLUTE_TSV'
lan_load_config "$2"
lan_validate_config
[[ "${LAN_CONFIG[relay_san_integration_status]}" == ready ]] || {
    printf 'PENDING_OWNER_INTEGRATION: the Rust relay must issue the reviewed short-lived LAN SAN certificate.\n' >&2
    exit 3
}
cert="${LAN_CONFIG[pki_runtime_dir]}/relay/cert.pem"
root="${LAN_CONFIG[pki_runtime_dir]}/relay/cert.pem"
fingerprint="${LAN_CONFIG[pki_runtime_dir]}/relay/fingerprint.sha256"
profile="${LAN_CONFIG[pki_runtime_dir]}/relay/relay-webtransport-v1"
printf 'The integrated relay must create its runtime identity with DNS localhost and ordered IP SANs 127.0.0.1,%s.\n' \
    "${LAN_CONFIG[server_ipv4]}"
printf 'Do not use the 30-day Smallstep relay-server profile for this browser-facing certificate.\n'
printf 'After the owner command has created the private runtime files, run exactly:\n'
printf '%q ' "${SCRIPT_DIR}/verify-runtime-pki.sh" --config "$2" \
    --cert "${cert}" --root "${root}" --fingerprint "${fingerprint}"
printf '\n'
printf 'The relay remains bound to 127.0.0.1:4433; only the validated UDP proxy may bind LAN UDP/14433.\n'
printf 'The owner-generated identity profile marker must remain at %q and use v2 plus SHA-256 of the canonical configured LAN IP.\n' "${profile}"
