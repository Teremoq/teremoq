#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
umask 077

required=(NODE_ID NODE_ROLE NODE_TIER NODE_PROVIDER NODE_REGION TEREMOQ_RUN_ID)
for name in "${required[@]}"; do
    [[ -n "${!name:-}" ]] || {
        printf 'virtual node: missing %s\n' "${name}" >&2
        exit 2
    }
done

if (( $(id -u) == 0 )); then
    printf 'virtual node: refusing to run as root\n' >&2
    exit 2
fi

ready_file=/tmp/teremoq-virtual-node.ready
printf '%s\n' "${NODE_ID}" >"${ready_file}"
printf '{"schema_version":1,"event":"virtual_node_ready","run_id":"%s","node_id":"%s","role":"%s","tier":"%s","provider":"%s","region":"%s","simulation":true}\n' \
    "${TEREMOQ_RUN_ID}" "${NODE_ID}" "${NODE_ROLE}" "${NODE_TIER}" \
    "${NODE_PROVIDER}" "${NODE_REGION}"

stopping=0
stop_node() {
    stopping=1
}
trap stop_node INT TERM
trap 'rm -f -- "${ready_file}"' EXIT

while (( stopping == 0 )); do
    sleep 1 &
    wait "$!" || true
done

printf '{"schema_version":1,"event":"virtual_node_stopped","run_id":"%s","node_id":"%s","simulation":true}\n' \
    "${TEREMOQ_RUN_ID}" "${NODE_ID}"
