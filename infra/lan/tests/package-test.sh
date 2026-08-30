#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
umask 077

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${TEST_DIR}/.." && pwd -P)"
source "${TEST_DIR}/test-lib.sh"
scratch="$(mktemp -d /tmp/teremoq-lan-package-test.XXXXXX)"
trap 'find "${scratch}" -depth -delete' EXIT
repo="${scratch}/repo"
mkdir -p -- "${repo}/infra/lan/windows" "${scratch}/player" "${scratch}/out-pending" "${scratch}/out-a" "${scratch}/out-b" "${scratch}/out-tamper" "${scratch}/out-secret"
cp -a -- "${ROOT}/client" "${repo}/infra/lan/client"
cp -- "${ROOT}/windows/Preflight-Client.ps1" "${ROOT}/windows/Collect-Evidence.ps1" "${repo}/infra/lan/windows/"
printf '<!doctype html><title>fixture player artifact</title>\n' >"${scratch}/player/index.html"
git -C "${repo}" init -q
git -C "${repo}" add .
git -C "${repo}" -c user.name='Teremoq test' -c user.email='test@invalid' commit -q -m 'test: client files'
commit="$(git -C "${repo}" rev-parse HEAD)"
config="${scratch}/config.tsv"
make_lan_config "${ROOT}/config/lan.example.tsv" "${config}" "${scratch}" "${commit}"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=package-test-relay' \
    -keyout "${scratch}/unused.key" -out "${scratch}/relay-cert.pem" >/dev/null 2>&1
openssl x509 -in "${scratch}/relay-cert.pem" -outform DER | sha256sum | awk '{print $1}' >"${scratch}/fingerprint"
if "${ROOT}/package-client.sh" --repo "${repo}" --commit "${commit}" --config "${config}" \
    --player-dir "${scratch}/player" --certificate "${scratch}/relay-cert.pem" \
    --fingerprint "${scratch}/fingerprint" --output-dir "${scratch}/out-pending" >/dev/null 2>&1; then
    printf 'package-test: emitted package without owner launcher contract\n' >&2; exit 1
fi
printf '%s\n' '# test fixture launcher' >"${scratch}/player/Start-TeremoqLanLoad.ps1"
printf '%s\n' '// test fixture standalone entrypoint' >"${scratch}/player/start.mjs"
launcher_sha="$(sha256sum "${scratch}/player/Start-TeremoqLanLoad.ps1" | awk '{print $1}')"
printf 'schema_version\t1\nsource_commit\t%s\nlauncher_relative_path\tStart-TeremoqLanLoad.ps1\nlauncher_sha256\t%s\nactions\tstart,status,stop,collect\nlevels\t1,5,10,25\nmax_clients\t25\nnetwork_contract\toutbound_udp_14433_only\nloopback_http_only\ttrue\n' \
    "${commit}" "${launcher_sha}" >"${scratch}/player/lan-launcher.tsv"
python3 - "${scratch}/player" "${commit}" <<'PY'
import hashlib, json, pathlib, sys
root, commit = pathlib.Path(sys.argv[1]), sys.argv[2]
files = []
for name in ("Start-TeremoqLanLoad.ps1", "index.html", "lan-launcher.tsv", "start.mjs"):
    data = (root / name).read_bytes()
    files.append({"path": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
manifest = {"schema_version": 1, "artifact": "teremoq-lan-lab-standalone", "package_version": "0.1.0-lan",
            "source_commit": commit, "entrypoint": "start.mjs", "files": files,
            "total_bytes": sum(item["bytes"] for item in files)}
(root / "MANIFEST.sha256.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
PY
for output in out-a out-b; do
    "${ROOT}/package-client.sh" --repo "${repo}" --commit "${commit}" --config "${config}" \
        --player-dir "${scratch}/player" --certificate "${scratch}/relay-cert.pem" \
        --fingerprint "${scratch}/fingerprint" --output-dir "${scratch}/${output}" >/dev/null
done
archive_a="$(find "${scratch}/out-a" -type f -name '*.tar.gz')"
archive_b="$(find "${scratch}/out-b" -type f -name '*.tar.gz')"
[[ "$(sha256sum "${archive_a}" | awk '{print $1}')" == "$(sha256sum "${archive_b}" | awk '{print $1}')" ]]
extract="${scratch}/extract"
mkdir -- "${extract}"
tar -xzf "${archive_a}" -C "${extract}"
(cd "${extract}" && sha256sum -c SHA256SUMS >/dev/null)
if command -v powershell.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(wslpath -w "${ROOT}/client/Verify-Package.ps1")" \
        -PackageRoot "$(wslpath -w "${extract}")" >/dev/null
fi
awk -F '\t' -v commit="${commit}" '$1 == "source_commit" && $2 == commit {found=1} END {exit !found}' "${extract}/VERSION.tsv"
[[ -f "${extract}/player/index.html" && -f "${extract}/public-identity/relay-cert.pem" && ! -e "${extract}/player/unused.key" ]]
[[ ! -e "${extract}/trust/root-ca.pem" ]]
[[ -f "${extract}/LAN-CONFIG.json" ]]
python3 - "${extract}/LAN-CONFIG.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text(encoding="utf-8"))
assert list(document) == ["schema_version", "run_id", "source_commit", "relay_url", "fingerprint_sha256", "prefix_length", "namespace"]
assert document["run_id"] == "lan-policy-test" and len(document["source_commit"]) == 40
assert document["relay_url"] == "https://192.168.77.10:14433/watch"
assert document["prefix_length"] == 24 and document["namespace"] == "teremoq/live"
assert path.stat().st_size <= 512
PY
grep -Fx $'player_evidence\tnot_measured' "${extract}/VERSION.tsv" >/dev/null
grep -Fx $'package_version\t0.1.0-lan' "${extract}/VERSION.tsv" >/dev/null
grep -Fx $'load_launcher_status\tready' "${extract}/VERSION.tsv" >/dev/null
[[ "$(awk -F '\t' '$1=="player_manifest_sha256" {print $2}' "${extract}/VERSION.tsv")" == "$(sha256sum "${scratch}/player/MANIFEST.sha256.json" | awk '{print $1}')" ]]
[[ "$(awk -F '\t' '$1=="launcher_contract_sha256" {print $2}' "${extract}/VERSION.tsv")" == "$(sha256sum "${scratch}/player/lan-launcher.tsv" | awk '{print $1}')" ]]
[[ "$(awk -F '\t' '$1=="lan_config_sha256" {print $2}' "${extract}/VERSION.tsv")" == "$(sha256sum "${extract}/LAN-CONFIG.json" | awk '{print $1}')" ]]
[[ "$(awk -F '\t' 'NF==2 {count++} END {print count}' "${extract}/VERSION.tsv")" == 11 ]]
printf '%s\n' 'tampered standalone' >"${scratch}/player/index.html"
if "${ROOT}/package-client.sh" --repo "${repo}" --commit "${commit}" --config "${config}" \
    --player-dir "${scratch}/player" --certificate "${scratch}/relay-cert.pem" \
    --fingerprint "${scratch}/fingerprint" --output-dir "${scratch}/out-tamper" >/dev/null 2>&1; then
    printf 'package-test: stale standalone manifest accepted\n' >&2; exit 1
fi
printf '<!doctype html><title>fixture player artifact</title>\n' >"${scratch}/player/index.html"
printf 'forbidden\n' >"${scratch}/player/secret.key"
if "${ROOT}/package-client.sh" --repo "${repo}" --commit "${commit}" --config "${config}" \
    --player-dir "${scratch}/player" --certificate "${scratch}/relay-cert.pem" \
    --fingerprint "${scratch}/fingerprint" --output-dir "${scratch}/out-secret" >/dev/null 2>&1; then
    printf 'package-test: credential-like file accepted\n' >&2; exit 1
fi
printf 'lan-package-test: pass\n'
