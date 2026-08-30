#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail

die() {
    printf 'two-host inventory: %s\n' "$*" >&2
    exit 1
}

(( $# == 2 )) && [[ "$1" == --inventory ]] || \
    die 'usage: validate-inventory.sh --inventory ABSOLUTE_TSV'
inventory="$2"
[[ "${inventory}" == /* && -f "${inventory}" && ! -L "${inventory}" ]] || \
    die 'inventory must be an absolute regular non-symlink file'

required=(
    contract_version deployment_id
    host_a_id host_a_provider host_a_region host_a_zone host_a_address
    host_b_id host_b_provider host_b_region host_b_zone host_b_address
    origin_image distributor_image control_image
    origin_mtls_identity origin_mtls_cert_path origin_mtls_key_path
    distributor_a_mtls_identity distributor_a_mtls_cert_path distributor_a_mtls_key_path
    control_mtls_identity control_mtls_cert_path control_mtls_key_path
    distributor_b_mtls_identity distributor_b_mtls_cert_path distributor_b_mtls_key_path
    mtls_trust_bundle_path srt_ingest_udp_port moqt_udp_port control_api_tcp_port
    minimum_kernel maximum_clock_offset_ms
    host_a_minimum_cpu_cores host_a_minimum_memory_mib host_a_minimum_disk_mib
    host_a_minimum_egress_mbps host_b_minimum_cpu_cores host_b_minimum_memory_mib
    host_b_minimum_disk_mib host_b_minimum_egress_mbps
)

declare -A allowed=() values=()
for key in "${required[@]}"; do allowed["${key}"]=1; done
line_number=0
while IFS=$'\t' read -r key value extra || [[ -n "${key}${value}${extra}" ]]; do
    line_number=$(( line_number + 1 ))
    [[ -n "${key}" && "${key}" != \#* ]] || continue
    [[ -z "${extra}" && -n "${value}" ]] || die "line ${line_number} must contain exactly two non-empty TSV fields"
    [[ -n "${allowed[${key}]:-}" ]] || die "unknown key on line ${line_number}: ${key}"
    [[ -z "${values[${key}]+present}" ]] || die "duplicate key: ${key}"
    [[ "${value}" != *$'\r'* && "${value}" != *$'\n'* ]] || die "invalid control character for ${key}"
    [[ "${value}" != REQUIRED_* ]] || die "unresolved placeholder: ${key}"
    [[ "${value}" != *'-----BEGIN '* && "${value}" != *'PRIVATE KEY'* ]] || \
        die "embedded trust material is forbidden: ${key}"
    values["${key}"]="${value}"
done <"${inventory}"

for key in "${required[@]}"; do
    [[ -n "${values[${key}]:-}" ]] || die "missing key: ${key}"
done
(( ${#values[@]} == ${#required[@]} )) || die 'inventory key count mismatch'
[[ "${values[contract_version]}" == 1 ]] || die 'unsupported contract_version'

token='^[a-z0-9][a-z0-9.-]{0,62}$'
for key in deployment_id host_a_id host_a_provider host_a_region host_a_zone \
    host_b_id host_b_provider host_b_region host_b_zone; do
    [[ "${values[${key}]}" =~ ${token} ]] || die "invalid token: ${key}"
done
[[ "${values[host_a_id]}" != "${values[host_b_id]}" ]] || die 'host identities must be distinct'
for key in host_a_address host_b_address; do
    [[ "${values[${key}]}" =~ ^[A-Za-z0-9][A-Za-z0-9.:-]{0,252}$ ]] || die "invalid address: ${key}"
done
[[ "${values[host_a_address]}" != "${values[host_b_address]}" ]] || die 'host addresses must be distinct'

image_pattern='^[a-z0-9]+([._-][a-z0-9]+)*([.:/][a-z0-9]+([._-][a-z0-9]+)*)*(@sha256:[0-9a-f]{64})$'
for key in origin_image distributor_image control_image; do
    [[ "${values[${key}]}" =~ ${image_pattern} ]] || die "${key} must be an OCI reference pinned by sha256 digest"
done

identity_pattern='^[a-z][a-z0-9+.-]*://[^[:space:]]+$'
identity_keys=(origin_mtls_identity distributor_a_mtls_identity control_mtls_identity distributor_b_mtls_identity)
declare -A identities=()
for key in "${identity_keys[@]}"; do
    identity="${values[${key}]}"
    [[ "${identity}" =~ ${identity_pattern} ]] || die "invalid mTLS identity URI: ${key}"
    [[ -z "${identities[${identity}]+present}" ]] || die 'mTLS service identities must be distinct'
    identities["${identity}"]=1
done

path_keys=(
    origin_mtls_cert_path origin_mtls_key_path
    distributor_a_mtls_cert_path distributor_a_mtls_key_path
    control_mtls_cert_path control_mtls_key_path
    distributor_b_mtls_cert_path distributor_b_mtls_key_path mtls_trust_bundle_path
)
declare -A credential_paths=()
for key in "${path_keys[@]}"; do
    path="${values[${key}]}"
    [[ "${path}" == /* && "${path}" != *'/../'* && "${path}" != */.. ]] || \
        die "${key} must be a traversal-free absolute path"
    if [[ "${key}" != mtls_trust_bundle_path ]]; then
        [[ -z "${credential_paths[${path}]+present}" ]] || die 'service certificate/key paths must be distinct'
        credential_paths["${path}"]=1
    fi
done

uint_keys=(
    srt_ingest_udp_port moqt_udp_port control_api_tcp_port maximum_clock_offset_ms
    host_a_minimum_cpu_cores host_a_minimum_memory_mib host_a_minimum_disk_mib
    host_a_minimum_egress_mbps host_b_minimum_cpu_cores host_b_minimum_memory_mib
    host_b_minimum_disk_mib host_b_minimum_egress_mbps
)
for key in "${uint_keys[@]}"; do
    [[ "${values[${key}]}" =~ ^[1-9][0-9]*$ ]] || die "${key} must be a positive integer"
done
for key in srt_ingest_udp_port moqt_udp_port control_api_tcp_port; do
    (( 10#${values[${key}]} <= 65535 )) || die "${key} exceeds 65535"
done
[[ "${values[srt_ingest_udp_port]}" != "${values[moqt_udp_port]}" ]] || \
    die 'SRT and MoQT UDP ports must be distinct'
[[ "${values[minimum_kernel]}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || \
    die 'minimum_kernel must be a numeric release tuple'

printf 'two-host inventory: valid (planning only; no remote action performed)\n'
