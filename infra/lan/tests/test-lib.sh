#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0

make_lan_config() {
    local example="$1" output="$2" scratch="$3" commit="$4" status="${5:-pending_owner_integration}" owner_commit="${6:-unavailable}"
    local server_ip client_ip router_ip
    server_ip="192.168.$((70 + 7)).10"
    client_ip="192.168.$((70 + 7)).20"
    router_ip="192.168.$((70 + 7)).1"
    awk -F '\t' -v OFS='\t' -v scratch="${scratch}" -v commit="${commit}" \
        -v server_ip="${server_ip}" -v client_ip="${client_ip}" -v router_ip="${router_ip}" \
        -v status="${status}" -v owner_commit="${owner_commit}" '
        /^#/ {print; next}
        $1 == "run_id" {$2="lan-policy-test"}
        $1 == "source_commit" {$2=commit}
        $1 == "server_ipv4" {$2=server_ip}
        $1 == "client_ipv4" {$2=client_ip}
        $1 == "router_ipv4" {$2=router_ip}
        $1 == "prefix_length" {$2="24"}
        $1 == "server_wsl_mode" {$2="mirrored"}
        $1 == "network_profile" {$2="Public"}
        $1 == "pki_runtime_dir" {$2=scratch "/pki"}
        $1 == "client_artifact_dir" {$2=scratch "/artifacts"}
        $1 == "maximum_clock_offset_ms" {$2="25"}
        $1 == "minimum_mtu" {$2="1280"}
        $1 ~ /_minimum_cpu_cores$/ {$2="2"}
        $1 ~ /_minimum_memory_mib$/ {$2="2048"}
        $1 ~ /_minimum_disk_mib$/ {$2="4096"}
        $1 == "relay_san_integration_status" {$2=status}
        $1 == "relay_san_integration_commit" {$2=owner_commit}
        {print}
    ' "${example}" >"${output}"
}
