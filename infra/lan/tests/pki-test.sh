#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
umask 077

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${TEST_DIR}/.." && pwd -P)"
source "${TEST_DIR}/test-lib.sh"
scratch="$(mktemp -d /tmp/teremoq-lan-pki-test.XXXXXX)"
trap 'find "${scratch}" -depth -delete' EXIT
commit="$(printf 'a%.0s' {1..40})"
config="${scratch}/config.tsv"
make_lan_config "${ROOT}/config/lan.example.tsv" "${config}" "${scratch}" "${commit}"
server_ip="$(awk -F '\t' '$1=="server_ipv4" {print $2}' "${config}")"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=teremoq-lan-test' \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:${server_ip}" \
    -keyout "${scratch}/key.pem" -out "${scratch}/cert.pem" >/dev/null 2>&1
openssl x509 -in "${scratch}/cert.pem" -outform DER | sha256sum | awk '{print $1}' >"${scratch}/fingerprint"
"${ROOT}/verify-runtime-pki.sh" --config "${config}" --cert "${scratch}/cert.pem" \
    --root "${scratch}/cert.pem" --fingerprint "${scratch}/fingerprint" >/dev/null
printf '0%.0s' {1..64} >"${scratch}/wrong-fingerprint"
if "${ROOT}/verify-runtime-pki.sh" --config "${config}" --cert "${scratch}/cert.pem" \
    --root "${scratch}/cert.pem" --fingerprint "${scratch}/wrong-fingerprint" >/dev/null 2>&1; then
    printf 'pki-test: fingerprint mismatch accepted\n' >&2; exit 1
fi
openssl req -x509 -newkey rsa:2048 -nodes -days 14 -subj '/CN=teremoq-lan-long-test' \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:${server_ip}" \
    -keyout "${scratch}/long-key.pem" -out "${scratch}/long-cert.pem" >/dev/null 2>&1
openssl x509 -in "${scratch}/long-cert.pem" -outform DER | sha256sum | awk '{print $1}' >"${scratch}/long-fingerprint"
if "${ROOT}/verify-runtime-pki.sh" --config "${config}" --cert "${scratch}/long-cert.pem" \
    --root "${scratch}/long-cert.pem" --fingerprint "${scratch}/long-fingerprint" >/dev/null 2>&1; then
    printf 'pki-test: 14-day certificate accepted\n' >&2; exit 1
fi
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=teremoq-lan-extra-test' \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:${server_ip},IP:192.168.77.99" \
    -keyout "${scratch}/extra-key.pem" -out "${scratch}/extra-cert.pem" >/dev/null 2>&1
openssl x509 -in "${scratch}/extra-cert.pem" -outform DER | sha256sum | awk '{print $1}' >"${scratch}/extra-fingerprint"
if "${ROOT}/verify-runtime-pki.sh" --config "${config}" --cert "${scratch}/extra-cert.pem" \
    --root "${scratch}/extra-cert.pem" --fingerprint "${scratch}/extra-fingerprint" >/dev/null 2>&1; then
    printf 'pki-test: extra SAN accepted\n' >&2; exit 1
fi
printf 'lan-pki-test: pass\n'
