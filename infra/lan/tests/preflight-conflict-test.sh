#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
umask 077

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${TEST_DIR}/.." && pwd -P)"
source "${TEST_DIR}/test-lib.sh"
scratch="$(mktemp -d /tmp/teremoq-lan-preflight-test.XXXXXX)"
trap 'find "${scratch}" -depth -delete' EXIT
config="${scratch}/config.tsv"
make_lan_config "${ROOT}/config/lan.example.tsv" "${config}" "${scratch}" "$(printf 'a%.0s' {1..40})"
mkdir -- "${scratch}/bin"
for command_name in ss docker; do
    cp /bin/true "${scratch}/bin/${command_name}"
done
test_support="${scratch}/support"
mkdir -- "${test_support}"
printf '%s\n' '#!/usr/bin/env bash' 'case "$*" in *":4433"*|*":9000"*|*":5678"*) printf "listener\\n" ;; esac' >"${test_support}/ss"
printf '%s\n' '#!/usr/bin/env bash' \
    'if [[ "$1" == version ]]; then printf "28.3.3\n"; elif [[ "$1" == ps ]]; then printf "legacy-relay\t0.0.0.0:4433->4433/udp, 0.0.0.0:5678->5678/tcp\n"; fi' \
    >"${test_support}/docker"
chmod +x "${test_support}/ss" "${test_support}/docker"
PATH="${test_support}:${PATH}" "${ROOT}/preflight-wsl.sh" --role server --config "${config}" >"${scratch}/report.tsv"
grep -Fq $'listener_udp_4433\tblocked\toccupied\treal' "${scratch}/report.tsv"
grep -Fq $'listener_tcp_5678\tblocked\toccupied\treal' "${scratch}/report.tsv"
grep -Fq $'docker_publication_inventory\tpass\tbounded-scan\treal' "${scratch}/report.tsv"
grep -Fq 'service=legacy-relay;port=4433/udp' "${scratch}/report.tsv"
grep -Fq 'service=legacy-relay;port=5678/tcp' "${scratch}/report.tsv"
grep -Fq $'preflight_gate\tblocked\tblocked\treal' "${scratch}/report.tsv"
! grep -Eiq 'pid=|process_id' "${scratch}/report.tsv"
printf 'tramiteplus-redis-1\t6379/tcp\n' | python3 "${ROOT}/docker_publications.py" >"${scratch}/internal-only.txt"
[[ ! -s "${scratch}/internal-only.txt" ]]
printf 'tramiteplus-redis-1\t127.0.0.1:6379->6379/tcp\n' | python3 "${ROOT}/docker_publications.py" >"${scratch}/loopback.txt"
grep -Fx 'service=tramiteplus-redis-1;port=6379/tcp' "${scratch}/loopback.txt" >/dev/null
printf 'legacy-ollama\t[::]:11434->11434/tcp\n' | python3 "${ROOT}/docker_publications.py" >"${scratch}/ipv6.txt"
grep -Fx 'service=legacy-ollama;port=11434/tcp' "${scratch}/ipv6.txt" >/dev/null
printf 'bad\t0.0.0.0:6379-6380->6379/tcp\n' >"${scratch}/malformed.txt"
if python3 "${ROOT}/docker_publications.py" <"${scratch}/malformed.txt" >/dev/null 2>&1; then
    printf 'preflight-conflict-test: malformed docker publication token accepted\n' >&2
    exit 1
fi
printf 'lan-preflight-conflict-test: pass\n'
