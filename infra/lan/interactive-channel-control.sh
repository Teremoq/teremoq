#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
action='' state_root='' run_id='' source_commit='' server_ip='' client_ip='' certificate='' private_key='' task='' target_commit=''
fingerprint='' authorization='' server_preflight='' firewall_attestation='' rollback_attestation='' confirm_start=0
while (( $# > 0 )); do
    case "$1" in
        start|enqueue|status|stop) action="$1"; shift ;;
        --confirm-start) confirm_start=1; shift ;;
        --state-root|--run-id|--source-commit|--server-ip|--client-ip|--certificate|--private-key|--fingerprint|--authorization|--server-preflight|--firewall-attestation|--rollback-attestation|--task|--target-commit)
            (( $# >= 2 )) || { printf '%s requires a value\n' "$1" >&2; exit 2; }
            case "$1" in
                --state-root) state_root="$2" ;; --run-id) run_id="$2" ;; --source-commit) source_commit="$2" ;;
                --server-ip) server_ip="$2" ;; --client-ip) client_ip="$2" ;; --certificate) certificate="$2" ;;
                --private-key) private_key="$2" ;; --task) task="$2" ;;
                --target-commit) target_commit="$2" ;;
                --fingerprint) fingerprint="$2" ;; --authorization) authorization="$2" ;;
                --server-preflight) server_preflight="$2" ;; --firewall-attestation) firewall_attestation="$2" ;;
                --rollback-attestation) rollback_attestation="$2" ;;
            esac
            shift 2 ;;
        *) printf 'unknown coordination argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done
[[ -n "${action}" && "${state_root}" == /* && "${run_id}" =~ ^lan-[a-z0-9][a-z0-9-]{0,31}$ && "${source_commit}" =~ ^[0-9a-f]{40}$ ]] || {
    printf 'action, absolute state root, run id and exact source commit are required\n' >&2; exit 2;
}
case "${action}" in
    start)
        [[ "${confirm_start}" == 1 && -n "${server_ip}" && -n "${client_ip}" && "${certificate}" == /* && "${private_key}" == /* &&
           "${fingerprint}" == /* && "${authorization}" == /* && "${server_preflight}" == /* && "${firewall_attestation}" == /* ]] || {
            printf 'start requires opt-in confirmation, exact IPs and absolute PKI/authorization/preflight/firewall evidence\n' >&2; exit 2;
        }
        python3 "${SCRIPT_DIR}/interactive_channel.py" daemon-start --state-root "${state_root}" --run-id "${run_id}" \
            --source-commit "${source_commit}" --client-ip "${client_ip}" --server-ip "${server_ip}" \
            --port 18443 --certificate "${certificate}" --private-key "${private_key}" \
            --fingerprint "${fingerprint}" --authorization "${authorization}" --server-preflight "${server_preflight}" \
            --firewall-attestation "${firewall_attestation}"
        ;;
    enqueue)
        [[ -n "${server_ip}" && "${certificate}" == /* && -n "${client_ip}" && -n "${task}" ]] || {
            printf 'enqueue requires server/client IP, certificate and task\n' >&2; exit 2;
        }
        extra=()
        if [[ "${task}" == update-client ]]; then
            [[ "${target_commit}" =~ ^[0-9a-f]{40}$ ]] || { printf 'update-client requires an exact target commit\n' >&2; exit 2; }
            extra=(--target-commit "${target_commit}")
        elif [[ -n "${target_commit}" ]]; then
            printf 'target commit is valid only for update-client\n' >&2; exit 2
        fi
        python3 "${SCRIPT_DIR}/interactive_channel.py" enqueue --state-root "${state_root}" --run-id "${run_id}" \
            --source-commit "${source_commit}" --client-ip "${client_ip}" --server-ip "${server_ip}" \
            --certificate "${certificate}" --action "${task}" "${extra[@]}"
        ;;
    status)
        [[ -n "${server_ip}" && -n "${client_ip}" ]] || { printf 'status requires exact server/client IPs\n' >&2; exit 2; }
        python3 "${SCRIPT_DIR}/interactive_channel.py" status --state-root "${state_root}" --run-id "${run_id}" \
            --source-commit "${source_commit}" --client-ip "${client_ip}" --server-ip "${server_ip}"
        ;;
    stop)
        [[ -n "${server_ip}" && -n "${client_ip}" && "${rollback_attestation}" == /* ]] || {
            printf 'stop requires exact IPs and the elevated firewall rollback attestation\n' >&2; exit 2;
        }
        python3 "${SCRIPT_DIR}/interactive_channel.py" daemon-stop --state-root "${state_root}" --run-id "${run_id}" \
            --source-commit "${source_commit}" --client-ip "${client_ip}" --server-ip "${server_ip}" \
            --attestation "${rollback_attestation}"
        ;;
esac
