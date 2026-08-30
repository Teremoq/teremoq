#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
config='' cert='' root='' fingerprint=''
while (( $# > 0 )); do
    case "$1" in
        --config|--cert|--root|--fingerprint)
            (( $# >= 2 )) || lan_die "$1 requires a value"
            case "$1" in --config) config="$2" ;; --cert) cert="$2" ;; --root) root="$2" ;; --fingerprint) fingerprint="$2" ;; esac
            shift 2 ;;
        *) lan_die "unknown PKI verification argument: $1" ;;
    esac
done
lan_load_config "${config}"
lan_validate_config
for path in "${cert}" "${root}" "${fingerprint}"; do
    [[ "${path}" == /* && -f "${path}" && ! -L "${path}" ]] || lan_die 'PKI inputs must be absolute regular non-symlink files'
done
(( $(stat -c %s -- "${cert}") > 0 && $(stat -c %s -- "${cert}") <= 32768 )) || lan_die 'certificate byte size is outside policy'
(( $(stat -c %s -- "${root}") > 0 && $(stat -c %s -- "${root}") <= 65536 )) || lan_die 'root byte size is outside policy'
(( $(stat -c %s -- "${fingerprint}") > 0 && $(stat -c %s -- "${fingerprint}") <= 128 )) || lan_die 'fingerprint byte size is outside policy'
command -v openssl >/dev/null 2>&1 || lan_die 'openssl is unavailable'
openssl verify -CAfile "${root}" "${cert}" >/dev/null || lan_die 'certificate chain verification failed'
san="$(openssl x509 -in "${cert}" -noout -ext subjectAltName 2>/dev/null)" || lan_die 'certificate SAN is unavailable'
dns_sans="$(grep -o 'DNS:[^,[:space:]]*' <<<"${san}" | sed 's/^DNS://')"
ip_sans="$(grep -o 'IP Address:[0-9.]*' <<<"${san}" | sed 's/IP Address://')"
[[ "${dns_sans}" == localhost ]] || lan_die 'certificate DNS SAN must be exactly localhost'
expected_ip_sans="$(printf '127.0.0.1\n%s' "${LAN_CONFIG[server_ipv4]}")"
[[ "${ip_sans}" == "${expected_ip_sans}" ]] || \
    lan_die 'certificate IP SANs must be exactly ordered 127.0.0.1 then server_ipv4'
not_before="$(openssl x509 -in "${cert}" -noout -startdate | sed 's/^notBefore=//')"
not_after="$(openssl x509 -in "${cert}" -noout -enddate | sed 's/^notAfter=//')"
start_epoch="$(date -u -d "${not_before}" +%s 2>/dev/null)" || lan_die 'certificate start time is unavailable'
end_epoch="$(date -u -d "${not_after}" +%s 2>/dev/null)" || lan_die 'certificate expiry is unavailable'
now_epoch="$(date -u +%s)"
(( start_epoch <= now_epoch && now_epoch < end_epoch )) || lan_die 'certificate is not currently valid'
duration=$(( end_epoch - start_epoch ))
(( duration > 0 && duration < 14 * 24 * 60 * 60 )) || \
    lan_die 'certificate total validity must be positive and strictly below 14 days'
expected="$(head -c 129 -- "${fingerprint}" | tr -d '\r\n')"
[[ "${expected}" =~ ^[0-9a-fA-F]{64}$ ]] || lan_die 'invalid fingerprint file'
actual="$(openssl x509 -in "${cert}" -outform DER | sha256sum | awk '{print $1}')"
[[ "${actual,,}" == "${expected,,}" ]] || lan_die 'certificate fingerprint mismatch'
printf 'teremoq LAN PKI: chain, exact DNS/IP SAN order, short validity and fingerprint valid\n'
