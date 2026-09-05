#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
action='' state_root='' run_id='' source_commit='' server_ip='' client_ip='' certificate='' private_key='' task=''
while (( $# > 0 )); do
    case "$1" in
        start|enqueue|status|stop|cleanup) action="$1"; shift ;;
        --state-root|--run-id|--source-commit|--server-ip|--client-ip|--certificate|--private-key|--task)
            (( $# >= 2 )) || { printf '%s requires a value\n' "$1" >&2; exit 2; }
            case "$1" in
                --state-root) state_root="$2" ;; --run-id) run_id="$2" ;; --source-commit) source_commit="$2" ;;
                --server-ip) server_ip="$2" ;; --client-ip) client_ip="$2" ;; --certificate) certificate="$2" ;;
                --private-key) private_key="$2" ;; --task) task="$2" ;;
            esac
            shift 2 ;;
        *) printf 'unknown coordination argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done
[[ -n "${action}" && "${state_root}" == /* && "${run_id}" =~ ^lan-[a-z0-9][a-z0-9-]{0,31}$ && "${source_commit}" =~ ^[0-9a-f]{40}$ ]] || {
    printf 'action, absolute state root, run id and exact source commit are required\n' >&2; exit 2;
}
pid_file="${state_root}/channel.pid"

case "${action}" in
    start)
        [[ -n "${server_ip}" && -n "${client_ip}" && "${certificate}" == /* && "${private_key}" == /* ]] || {
            printf 'start requires exact IPs and absolute certificate/key paths\n' >&2; exit 2;
        }
        pairing="$(python3 "${SCRIPT_DIR}/interactive_channel.py" init --state-root "${state_root}" --run-id "${run_id}" --source-commit "${source_commit}" --client-ip "${client_ip}")"
        nohup python3 "${SCRIPT_DIR}/interactive_channel.py" serve --state-root "${state_root}" --run-id "${run_id}" \
            --source-commit "${source_commit}" --client-ip "${client_ip}" --bind "${server_ip}" \
            --port 18443 --certificate "${certificate}" --private-key "${private_key}" \
            >"${state_root}/channel.stdout" 2>"${state_root}/channel.stderr" &
        pid=$!
        printf '%s\n' "${pid}" >"${pid_file}"
        chmod 600 "${pid_file}" "${state_root}/channel.stdout" "${state_root}/channel.stderr"
        for _ in {1..50}; do
            kill -0 "${pid}" 2>/dev/null || { printf 'coordination server exited during startup\n' >&2; exit 1; }
            ss -H -ltn "sport = :18443" 2>/dev/null | grep -Fq "${server_ip}:18443" && break
            sleep 0.1
        done
        ss -H -ltn "sport = :18443" 2>/dev/null | grep -Fq "${server_ip}:18443" || { kill "${pid}" 2>/dev/null || true; printf 'coordination listener did not become ready\n' >&2; exit 1; }
        printf 'PAIRING_CODE=%s\n' "${pairing}"
        ;;
    enqueue)
        [[ -n "${server_ip}" && "${certificate}" == /* && -n "${client_ip}" && -n "${task}" ]] || {
            printf 'enqueue requires server/client IP, certificate and task\n' >&2; exit 2;
        }
        python3 "${SCRIPT_DIR}/interactive_channel.py" enqueue --state-root "${state_root}" --run-id "${run_id}" \
            --source-commit "${source_commit}" --client-ip "${client_ip}" --server-ip "${server_ip}" \
            --certificate "${certificate}" --action "${task}"
        ;;
    status)
        [[ -f "${pid_file}" && ! -L "${pid_file}" ]] || { printf 'coordination channel is stopped\n'; exit 0; }
        pid="$(<"${pid_file}")"
        [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || { printf 'invalid coordination pid\n' >&2; exit 1; }
        kill -0 "${pid}" 2>/dev/null || { printf 'coordination process is not running\n' >&2; exit 1; }
        if [[ -f "${state_root}/channel-events.jsonl" ]]; then tail -n 20 -- "${state_root}/channel-events.jsonl"; else printf 'coordination channel ready; no client events yet\n'; fi
        ;;
    stop)
        if [[ -f "${pid_file}" && ! -L "${pid_file}" ]]; then
            pid="$(<"${pid_file}")"
            [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || { printf 'invalid coordination pid\n' >&2; exit 1; }
            cmdline="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)"
            [[ "${cmdline}" == *"interactive_channel.py serve"* && "${cmdline}" == *"${state_root}"* ]] || {
                printf 'coordination pid ownership mismatch\n' >&2; exit 1;
            }
            kill -TERM "${pid}"
            for _ in {1..100}; do kill -0 "${pid}" 2>/dev/null || break; sleep 0.1; done
            kill -0 "${pid}" 2>/dev/null && { printf 'coordination server did not stop\n' >&2; exit 1; }
            rm -f -- "${pid_file}"
        fi
        rm -f -- "${state_root}/pairing-code" "${state_root}/management-token"
        printf 'coordination listener and credentials removed; evidence retained\n'
        ;;
    cleanup)
        [[ ! -e "${pid_file}" ]] || { printf 'stop the coordination process before cleanup\n' >&2; exit 1; }
        [[ -f "${state_root}/channel-state.json" && ! -L "${state_root}" ]] || { printf 'state ownership marker missing\n' >&2; exit 1; }
        python3 - "${state_root}/channel-state.json" "${run_id}" "${source_commit}" <<'PY'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1]); d=json.loads(p.read_text(encoding="utf-8"))
if d.get("run_id") != sys.argv[2] or d.get("source_commit") != sys.argv[3]: raise SystemExit("state identity mismatch")
PY
        find "${state_root}" -depth -delete
        printf 'coordination state and evidence removed\n'
        ;;
esac
