#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
umask 077

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${TEST_DIR}/.." && pwd -P)"
source "${TEST_DIR}/test-lib.sh"
have_windows_git() {
    powershell.exe -NoProfile -NonInteractive -Command '
    $candidate = @("git.exe","git.cmd","git.bat","git") | ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
    if($candidate){exit 0}
    exit 1
    ' >/dev/null 2>&1
}
if ! command -v powershell.exe >/dev/null 2>&1 || ! command -v wslpath >/dev/null 2>&1 || ! have_windows_git; then
    printf 'lan-git-client-test: skipped (Windows PowerShell runtime or Git for Windows unavailable)\n'
    exit 0
fi
scratch="$(mktemp -d /tmp/teremoq-lan-git-client-test.XXXXXX)"
trap 'find "${scratch}" -depth -delete' EXIT
source_repo="${scratch}/source"
remote_repo="${scratch}/remote.git"
work_repo="${scratch}/work"
checkout_root="${scratch}/checkout"
player="${scratch}/player"
state_a_out="${scratch}/state-a-out"
state_b_out="${scratch}/state-b-out"
mkdir -p -- "${source_repo}/infra/lan/windows" "${player}" "${state_a_out}" "${state_b_out}"
cp -a -- "${ROOT}/client" "${source_repo}/infra/lan/client"
cp -- "${ROOT}/windows/Preflight-Client.ps1" "${ROOT}/windows/Collect-Evidence.ps1" "${ROOT}/windows/Preflight-Contract.ps1" "${source_repo}/infra/lan/windows/"
git -C "${source_repo}" init -q -b codex/lan-client
git -C "${source_repo}" remote add origin https://github.com/Teremoq/teremoq
printf '%s\n' '# launcher A' >"${player}/Start-TeremoqLanLoad.ps1"
printf '%s\n' '// start A' >"${player}/start.mjs"
printf '<!doctype html><title>player A</title>\n' >"${player}/index.html"
create_manifest() {
    local dir="$1" commit="$2" version="$3"
    local launcher_sha
    launcher_sha="$(sha256sum "${dir}/Start-TeremoqLanLoad.ps1" | awk '{print $1}')"
    printf 'schema_version\t1\nsource_commit\t%s\nlauncher_relative_path\tStart-TeremoqLanLoad.ps1\nlauncher_sha256\t%s\nactions\tstart,status,stop,collect\nlevels\t1,5,10,25\nmax_clients\t25\nnetwork_contract\toutbound_udp_14433_only\nloopback_http_only\ttrue\n' \
        "${commit}" "${launcher_sha}" >"${dir}/lan-launcher.tsv"
    python3 - "${dir}" "${commit}" "${version}" <<'PY'
import hashlib, json, pathlib, sys
root, commit, version = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
files = []
for name in ("Start-TeremoqLanLoad.ps1", "index.html", "lan-launcher.tsv", "start.mjs"):
    data = (root / name).read_bytes()
    files.append({"path": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
manifest = {"schema_version": 1, "artifact": "teremoq-lan-lab-standalone", "package_version": version,
            "source_commit": commit, "entrypoint": "start.mjs", "files": files,
            "total_bytes": sum(item["bytes"] for item in files)}
(root / "MANIFEST.sha256.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
PY
}
printf 'seed\n' >"${source_repo}/infra/lan/client/seed.txt"
git -C "${source_repo}" add .
git -C "${source_repo}" -c user.name='Teremoq test' -c user.email='test@invalid' commit -q -m 'test: lan git v1'
commit_a="$(git -C "${source_repo}" rev-parse HEAD)"
create_manifest "${player}" "${commit_a}" '0.1.0-lan'
config_a="${scratch}/config-a.tsv"
make_lan_config "${ROOT}/config/lan.example.tsv" "${config_a}" "${scratch}" "${commit_a}"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=git-client-test-relay' \
    -keyout "${scratch}/unused.key" -out "${scratch}/relay-cert.pem" >/dev/null 2>&1
openssl x509 -in "${scratch}/relay-cert.pem" -outform DER | sha256sum | awk '{print $1}' >"${scratch}/fingerprint"
git init --bare "${remote_repo}" >/dev/null
git -C "${source_repo}" push "${remote_repo}" HEAD:refs/heads/codex/lan-client >/dev/null
"${ROOT}/package-client.sh" --repo "${source_repo}" --commit "${commit_a}" --config "${config_a}" \
    --player-dir "${player}" --certificate "${scratch}/relay-cert.pem" --fingerprint "${scratch}/fingerprint" \
    --git-url https://github.com/Teremoq/teremoq --git-ref refs/heads/codex/lan-client --git-subdirectory infra/lan \
    --output-dir "${state_a_out}" >/dev/null
state_a="$(find "${state_a_out}" -mindepth 1 -maxdepth 1 -type d -name 'teremoq-lan-client-state-*')"
git_config_global="${scratch}/gitconfig"
cat >"${git_config_global}" <<EOF
[url "${remote_repo}"]
	insteadOf = https://github.com/Teremoq/teremoq
EOF
export GIT_CONFIG_GLOBAL="${git_config_global}"
export GIT_CONFIG_NOSYSTEM=1
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(wslpath -w "${ROOT}/client/Install-LanClient.ps1")" \
    -StateRoot "$(wslpath -w "${state_a}")" -CheckoutRoot "$(wslpath -w "${checkout_root}")" >/dev/null
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(wslpath -w "${ROOT}/client/Verify-Package.ps1")" \
    -CheckoutRoot "$(wslpath -w "${checkout_root}")" -StateRoot "$(wslpath -w "${state_a}")" >/dev/null
printf 'update\n' >"${source_repo}/infra/lan/client/update.txt"
git -C "${source_repo}" add infra/lan/client/update.txt
git -C "${source_repo}" -c user.name='Teremoq test' -c user.email='test@invalid' commit -q -m 'test: lan git v2'
commit_b="$(git -C "${source_repo}" rev-parse HEAD)"
printf '%s\n' '# launcher B' >"${player}/Start-TeremoqLanLoad.ps1"
printf '%s\n' '// start B' >"${player}/start.mjs"
printf '<!doctype html><title>player B</title>\n' >"${player}/index.html"
create_manifest "${player}" "${commit_b}" '0.1.1-lan'
config_b="${scratch}/config-b.tsv"
make_lan_config "${ROOT}/config/lan.example.tsv" "${config_b}" "${scratch}" "${commit_b}"
git -C "${source_repo}" push "${remote_repo}" HEAD:refs/heads/codex/lan-client >/dev/null
"${ROOT}/package-client.sh" --repo "${source_repo}" --commit "${commit_b}" --config "${config_b}" \
    --player-dir "${player}" --certificate "${scratch}/relay-cert.pem" --fingerprint "${scratch}/fingerprint" \
    --git-url https://github.com/Teremoq/teremoq --git-ref refs/heads/codex/lan-client --git-subdirectory infra/lan \
    --output-dir "${state_b_out}" >/dev/null
state_b="$(find "${state_b_out}" -mindepth 1 -maxdepth 1 -type d -name 'teremoq-lan-client-state-*')"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(wslpath -w "${ROOT}/client/Update-LanClient.ps1")" \
    -StateRoot "$(wslpath -w "${state_b}")" -CheckoutRoot "$(wslpath -w "${checkout_root}")" >/dev/null
[[ "$(git -C "${checkout_root}" rev-parse HEAD)" == "${commit_b}" ]]
printf 'dirty\n' >>"${checkout_root}/infra/lan/client/seed.txt"
if powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(wslpath -w "${ROOT}/client/Update-LanClient.ps1")" \
    -StateRoot "$(wslpath -w "${state_b}")" -CheckoutRoot "$(wslpath -w "${checkout_root}")" >/dev/null 2>&1; then
    printf 'git-client-test: dirty checkout accepted by update\n' >&2; exit 1
fi
git -C "${checkout_root}" checkout -- infra/lan/client/seed.txt
bad_url_state="${scratch}/bad-url-state"
cp -a -- "${state_b}" "${bad_url_state}"
python3 - "${bad_url_state}/CLIENT-COMPATIBILITY.tsv" <<'PY'
from pathlib import Path
path = Path(__import__("sys").argv[1])
text = path.read_text(encoding="utf-8").replace("https://github.com/Teremoq/teremoq", "https://github.com/Teremoq/other", 1)
path.write_text(text, encoding="utf-8")
PY
if powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(wslpath -w "${ROOT}/client/Verify-Package.ps1")" \
    -CheckoutRoot "$(wslpath -w "${checkout_root}")" -StateRoot "$(wslpath -w "${bad_url_state}")" >/dev/null 2>&1; then
    printf 'git-client-test: unexpected repository URL accepted\n' >&2; exit 1
fi
bad_ref_state="${scratch}/bad-ref-state"
cp -a -- "${state_b}" "${bad_ref_state}"
python3 - "${bad_ref_state}/CLIENT-COMPATIBILITY.tsv" <<'PY'
from pathlib import Path
path = Path(__import__("sys").argv[1])
text = path.read_text(encoding="utf-8").replace("refs/heads/codex/lan-client", "refs/tags/lan-client", 1)
path.write_text(text, encoding="utf-8")
PY
if powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(wslpath -w "${ROOT}/client/Verify-Package.ps1")" \
    -CheckoutRoot "$(wslpath -w "${checkout_root}")" -StateRoot "$(wslpath -w "${bad_ref_state}")" >/dev/null 2>&1; then
    printf 'git-client-test: unexpected repository ref accepted\n' >&2; exit 1
fi
bad_commit_state="${scratch}/bad-commit-state"
cp -a -- "${state_b}" "${bad_commit_state}"
python3 - "${bad_commit_state}/CLIENT-COMPATIBILITY.tsv" <<'PY'
from pathlib import Path
path = Path(__import__("sys").argv[1])
text = path.read_text(encoding="utf-8").replace("allowed_client_commit\t", "allowed_client_commit\tf", 1)
path.write_text(text, encoding="utf-8")
PY
if powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(wslpath -w "${ROOT}/client/Verify-Package.ps1")" \
    -CheckoutRoot "$(wslpath -w "${checkout_root}")" -StateRoot "$(wslpath -w "${bad_commit_state}")" >/dev/null 2>&1; then
    printf 'git-client-test: unexpected allowed client commit accepted\n' >&2; exit 1
fi
nested_checkout="${state_b}/nested-checkout"
mkdir -- "${nested_checkout}"
if powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(wslpath -w "${ROOT}/client/Verify-Package.ps1")" \
    -CheckoutRoot "$(wslpath -w "${nested_checkout}")" -StateRoot "$(wslpath -w "${state_b}")" >/dev/null 2>&1; then
    printf 'git-client-test: nested checkout/state roots accepted\n' >&2; exit 1
fi
printf 'local divergence\n' >"${checkout_root}/infra/lan/client/local.txt"
git -C "${checkout_root}" add infra/lan/client/local.txt
git -C "${checkout_root}" -c user.name='Teremoq test' -c user.email='test@invalid' commit -q -m 'test: local divergence'
if powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(wslpath -w "${ROOT}/client/Update-LanClient.ps1")" \
    -StateRoot "$(wslpath -w "${state_b}")" -CheckoutRoot "$(wslpath -w "${checkout_root}")" >/dev/null 2>&1; then
    printf 'git-client-test: divergent checkout accepted by update\n' >&2; exit 1
fi
printf 'lan-git-client-test: pass\n'
