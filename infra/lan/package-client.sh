#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
repo='' commit='' config='' player_dir='' fingerprint='' output_dir='' git_url='' git_ref='' git_subdirectory='' player_relative_path=''
while (( $# > 0 )); do
    case "$1" in
        --repo|--commit|--config|--player-dir|--fingerprint|--output-dir|--git-url|--git-ref|--git-subdirectory|--player-relative-path)
            (( $# >= 2 )) || lan_die "$1 requires a value"
            case "$1" in
                --repo) repo="$2" ;; --commit) commit="$2" ;; --config) config="$2" ;;
                --player-dir) player_dir="$2" ;;
                --fingerprint) fingerprint="$2" ;; --output-dir) output_dir="$2" ;;
                --git-url) git_url="$2" ;; --git-ref) git_ref="$2" ;; --git-subdirectory) git_subdirectory="$2" ;; --player-relative-path) player_relative_path="$2" ;;
            esac
            shift 2 ;;
        *) lan_die "unknown package argument: $1" ;;
    esac
done
lan_die 'package-client.sh is deprecated: do not package or transfer client state; use native Git clone, the Web Git builder, and Initialize-LanClientState.ps1 on the client'
lan_load_config "${config}"
lan_validate_config
[[ "${repo}" == /* && -d "${repo}" ]] || lan_die 'repo must be an absolute directory'
[[ "${commit}" =~ ^[0-9a-f]{40}$ && "${commit}" == "${LAN_CONFIG[source_commit]}" ]] || \
    lan_die 'package commit must be the explicit config commit'
[[ "$(git -C "${repo}" rev-parse HEAD)" == "${commit}" ]] || lan_die 'package commit must equal local HEAD'
git -C "${repo}" diff --quiet && git -C "${repo}" diff --cached --quiet || lan_die 'package source worktree is dirty'
[[ -z "$(git -C "${repo}" status --porcelain --untracked-files=normal)" ]] || lan_die 'package source has untracked files'
git -C "${repo}" cat-file -e "${commit}^{commit}" 2>/dev/null || lan_die 'explicit commit is unavailable locally'
git -C "${repo}" cat-file -e "${commit}:infra/lan/client/README.md" 2>/dev/null || lan_die 'client scripts are absent from explicit commit'
for path in infra/lan/windows/Preflight-Client.ps1 infra/lan/windows/Collect-Evidence.ps1 infra/lan/windows/Preflight-Contract.ps1; do
    git -C "${repo}" cat-file -e "${commit}:${path}" 2>/dev/null || lan_die "client support script is absent from explicit commit: ${path}"
done
for path in "${player_dir}" "${output_dir}"; do [[ "${path}" == /* && -d "${path}" && ! -L "${path}" ]] || lan_die 'player/output paths must be absolute non-symlink directories'; done
[[ "${fingerprint}" == /* && -f "${fingerprint}" && ! -L "${fingerprint}" ]] || lan_die 'public identity input must be an absolute regular non-symlink file'
[[ "${git_url}" == 'https://github.com/Teremoq/teremoq' ]] || lan_die 'git-url must be the exact approved repository URL'
[[ "${git_ref}" =~ ^refs/heads/[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$ ]] || lan_die 'git-ref must be an explicit refs/heads/* name'
[[ ${#git_subdirectory} -ge 1 && ${#git_subdirectory} -le 128 && "${git_subdirectory}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] || \
    lan_die 'git-subdirectory must be a safe relative path'
IFS='/' read -r -a _lan_git_segments <<<"${git_subdirectory}"
for _lan_git_segment in "${_lan_git_segments[@]}"; do
    [[ "${_lan_git_segment}" != . && "${_lan_git_segment}" != .. ]] || lan_die 'git-subdirectory dot segments are forbidden'
done
(( $(stat -c %s -- "${fingerprint}") > 0 && $(stat -c %s -- "${fingerprint}") <= 128 )) || lan_die 'relay fingerprint byte size is outside policy'
[[ ${#player_relative_path} -ge 1 && ${#player_relative_path} -le 128 && "${player_relative_path}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] || lan_die 'player-relative-path must be safe and relative'
IFS='/' read -r -a _lan_player_segments <<<"${player_relative_path}"
for _lan_player_segment in "${_lan_player_segments[@]}"; do [[ "${_lan_player_segment}" != . && "${_lan_player_segment}" != .. ]] || lan_die 'player-relative-path dot segments are forbidden'; done
[[ "$(realpath -e -- "${player_dir}")" == "$(realpath -e -- "${repo}/${player_relative_path}")" ]] || lan_die 'player must be versioned inside the exact checkout at player-relative-path'
[[ -z "$(find "${player_dir}" -type l -print -quit)" ]] || lan_die 'player artifact may not contain symlinks'
[[ -z "$(find "${player_dir}" \( -type d -name __pycache__ -o -type f \( -name '*.pyc' -o -name '*.pyo' \) \) -print -quit)" ]] || lan_die 'player artifact may not contain Python cache files'
file_count="$(find "${player_dir}" -type f | wc -l)"
(( file_count > 0 && file_count <= 10000 )) || lan_die 'player artifact file count is outside 1..10000'
if find "${player_dir}" -type f | grep -Eiq '(/|^)(\.env|id_rsa|[^/]*\.(key|p12|pfx)|[^/]*(password|secret|token)[^/]*)$'; then
    lan_die 'player artifact contains a forbidden credential-like filename'
fi
fingerprint_value="$(head -c 129 -- "${fingerprint}" | tr -d '\r\n')"
[[ "${fingerprint_value}" =~ ^[0-9a-fA-F]{64}$ ]] || lan_die 'invalid relay fingerprint'
[[ "${output_dir}" != "${repo}" && "${output_dir}" != "${player_dir}" ]] || lan_die 'output directory must be separate'
launcher_contract="${player_dir}/lan-launcher.tsv"
[[ -e "${launcher_contract}" ]] || lan_die 'pending_owner_integration: exact nine-key LAN launcher contract is absent'
[[ -f "${launcher_contract}" && ! -L "${launcher_contract}" && $(stat -c %s -- "${launcher_contract}") -le 4096 ]] || lan_die 'LAN launcher contract is unsafe or oversized'
    declare -A launcher=()
    while IFS=$'\t' read -r key value extra || [[ -n "${key}${value}${extra}" ]]; do
        [[ -n "${key}" && "${key}" != \#* ]] || continue
        [[ -z "${extra}" && -n "${value}" && -z "${launcher[${key}]+present}" ]] || lan_die 'invalid LAN launcher contract line'
        case "${key}" in schema_version|source_commit|launcher_relative_path|launcher_sha256|actions|levels|max_clients|network_contract|loopback_http_only) ;; *) lan_die 'unknown LAN launcher contract key' ;; esac
        launcher["${key}"]="${value}"
    done <"${launcher_contract}"
    (( ${#launcher[@]} == 9 )) || lan_die 'LAN launcher contract is incomplete'
    [[ "${launcher[schema_version]}" == 1 && "${launcher[source_commit]}" == "${commit}" && \
       "${launcher[actions]}" == start,status,stop,collect && \
       "${launcher[levels]}" == 1,5,10,25 && "${launcher[max_clients]}" == 25 && \
       "${launcher[network_contract]}" == outbound_udp_14433_only && "${launcher[loopback_http_only]}" == true && \
       "${launcher[launcher_relative_path]}" =~ ^[A-Za-z0-9._-]+[.]ps1$ && \
       "${launcher[launcher_sha256]}" =~ ^[0-9a-f]{64}$ ]] || lan_die 'LAN launcher contract values are outside policy'
    launcher_path="${player_dir}/${launcher[launcher_relative_path]}"
    [[ -f "${launcher_path}" && ! -L "${launcher_path}" && "$(sha256sum "${launcher_path}" | awk '{print $1}')" == "${launcher[launcher_sha256]}" ]] || lan_die 'LAN launcher artifact/checksum mismatch'
package_version="$(python3 "${SCRIPT_DIR}/verify-standalone-manifest.py" --player-dir "${player_dir}" --source-commit "${commit}" \
    --launcher "${launcher[launcher_relative_path]}" | awk -F ': ' '$1 == "package_version" {print $2}')"
[[ -n "${package_version}" ]] || lan_die 'standalone manifest did not yield a package_version'
player_manifest_sha="$(sha256sum "${player_dir}/MANIFEST.sha256.json" | awk '{print $1}')"
launcher_contract_sha="$(sha256sum "${launcher_contract}" | awk '{print $1}')"

scratch="$(mktemp -d /tmp/teremoq-lan-package.XXXXXX)"
trap 'find "${scratch}" -depth -delete' EXIT
stage="${scratch}/stage"
mkdir -m 0700 -p -- "${stage}/public-identity" "${stage}/player"
cp -a -- "${player_dir}/." "${stage}/player/"
printf '%s\n' "${fingerprint_value,,}" >"${stage}/public-identity/relay-cert.sha256"
printf '{"schema_version":1,"run_id":"%s","source_commit":"%s","relay_url":"https://%s:%s/watch","fingerprint_sha256":"%s","prefix_length":%s,"namespace":"%s"}\n' \
    "${LAN_CONFIG[run_id]}" "${commit}" "${LAN_CONFIG[server_ipv4]}" "${LAN_CONFIG[moq_frontend_udp_port]}" "${fingerprint_value,,}" \
    "${LAN_CONFIG[prefix_length]}" "${LAN_CONFIG[moq_namespace]}" >"${stage}/LAN-CONFIG.json"
(( $(stat -c %s -- "${stage}/LAN-CONFIG.json") <= 512 )) || lan_die 'canonical public LAN-CONFIG.json exceeds 512 bytes'
lan_config_sha="$(sha256sum "${stage}/LAN-CONFIG.json" | awk '{print $1}')"
printf 'schema_version\t1\nrepository_url\t%s\nrepository_ref\t%s\nrepository_subdirectory\t%s\nplayer_relative_path\t%s\nallowed_client_commit\t%s\nsource_commit\t%s\npackage_version\t%s\nclient_protocol_version\tteremoq-lan-git-v2\nplayer_manifest_sha256\t%s\nlauncher_contract_sha256\t%s\nlan_config_sha256\t%s\n' \
    "${git_url}" "${git_ref}" "${git_subdirectory}" "${player_relative_path}" "${commit}" "${commit}" "${package_version}" \
    "${player_manifest_sha}" "${launcher_contract_sha}" "${lan_config_sha}" >"${stage}/CLIENT-COMPATIBILITY.tsv"
printf 'schema_version\t1\npackage_version\t%s\nrun_id\t%s\nsource_commit\t%s\nserver_ipv4\t%s\nmoq_url\thttps://%s:%s/watch\nplayer_manifest_sha256\t%s\nlauncher_contract_sha256\t%s\nlan_config_sha256\t%s\nplayer_evidence\tnot_measured\nload_launcher_status\tready\n' \
    "${package_version}" "${LAN_CONFIG[run_id]}" "${commit}" "${LAN_CONFIG[server_ipv4]}" \
    "${LAN_CONFIG[server_ipv4]}" "${LAN_CONFIG[moq_frontend_udp_port]}" "${player_manifest_sha}" "${launcher_contract_sha}" "${lan_config_sha}" >"${stage}/VERSION.tsv"
(
    cd "${stage}"
    find . -type f ! -name SHA256SUMS -print0 | sort -z | while IFS= read -r -d '' file; do
        sha256sum "${file#./}"
    done >SHA256SUMS
)
short_commit="${commit:0:12}"
state_root="${output_dir}/teremoq-lan-client-state-${LAN_CONFIG[run_id]}-${short_commit}"
[[ ! -e "${state_root}" ]] || lan_die 'client state output already exists'
mkdir -m 0700 -p -- "${state_root}"
cp -a -- "${stage}/." "${state_root}/"
printf 'teremoq LAN client state: %s\n' "${state_root}"
