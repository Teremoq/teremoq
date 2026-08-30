#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
"""Run-owned, fail-closed lifecycle for the opt-in LAN laboratory."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import stat
import subprocess
import sys
import time
import urllib.request

from udp_proxy import exact_private_ipv4, read_regular_limited

COMPONENTS = ("relay", "gateway", "source")
AUTH_KEYS = {
    "schema_version", "run_id", "source_commit", "server_preflight_sha256",
    "client_preflight_sha256", "firewall_attestation_sha256", "server_preflight_gate",
    "client_preflight_gate", "proxy_attestation_sha256", "legacy_conflicts_absent", "owner_integrations_ready",
    "operator_authorized", "owner_integration_commit", "commands_sha256",
}


def fail(message: str) -> "NoReturn":
    raise ValueError(message)


def expected_lan_identity_profile(server_ip: str) -> str:
    canonical = exact_private_ipv4(server_ip, "server_ip")
    digest = hashlib.sha256(canonical.encode("ascii")).hexdigest()
    return f"webtransport-hash-v2-lan-ip-sha256:{digest}\n"


def sha256_bounded(path: Path, maximum: int = 1_048_576) -> str:
    if not path.is_absolute():
        fail("evidence paths must be absolute")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ValueError("evidence must be a readable non-symlink regular file") from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size <= 0 or metadata.st_size > maximum:
            fail("evidence size or type is outside policy")
        digest = hashlib.sha256()
        remaining = maximum + 1
        while remaining:
            chunk = os.read(descriptor, min(65536, remaining))
            if not chunk:
                break
            digest.update(chunk)
            remaining -= len(chunk)
        if remaining == 0 and os.read(descriptor, 1):
            fail("evidence exceeds its byte limit")
        return digest.hexdigest()
    finally:
        os.close(descriptor)


def parse_authorization(path: Path) -> dict[str, str]:
    text = read_regular_limited(path, 8192, "utf-8")
    values: dict[str, str] = {}
    for number, raw in enumerate(text.splitlines(), 1):
        if not raw or raw.startswith("#"):
            continue
        fields = raw.split("\t")
        if len(fields) != 2 or not all(fields):
            fail(f"invalid authorization line {number}")
        key, value = fields
        if key not in AUTH_KEYS or key in values:
            fail(f"unknown or duplicate authorization key: {key}")
        values[key] = value
    if set(values) != AUTH_KEYS or values["schema_version"] != "1":
        fail("authorization schema is incomplete or unsupported")
    if not values["run_id"].startswith("lan-") or len(values["run_id"]) > 36:
        fail("invalid authorization run ID")
    if len(values["source_commit"]) != 40 or any(c not in "0123456789abcdef" for c in values["source_commit"]):
        fail("invalid authorization commit")
    if len(values["owner_integration_commit"]) != 40 or any(c not in "0123456789abcdef" for c in values["owner_integration_commit"]):
        fail("invalid owner integration commit")
    for key in ("commands_sha256", "server_preflight_sha256", "client_preflight_sha256", "firewall_attestation_sha256", "proxy_attestation_sha256"):
        if len(values[key]) != 64 or any(c not in "0123456789abcdef" for c in values[key]):
            fail(f"invalid authorization digest: {key}")
    for key in ("server_preflight_gate", "client_preflight_gate"):
        if values[key] != "pass":
            fail(f"{key} must be pass")
    for key in ("legacy_conflicts_absent", "owner_integrations_ready", "operator_authorized"):
        if values[key] != "true":
            fail(f"{key} must be explicitly true")
    return values


def path_within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def verify_executable_hash(path: Path, expected: str) -> None:
    if sha256_bounded(path, 1_073_741_824) != expected:
        fail("component executable SHA-256 mismatch")


def parse_commands(
    path: Path,
    source_commit: str,
    expected_manifest_sha256: str,
    repo_root: Path,
    artifact_root: Path,
) -> dict[str, tuple[Path, list[str], Path, str]]:
    text = read_regular_limited(path, 16384, "utf-8")
    if hashlib.sha256(text.encode("utf-8")).hexdigest() != expected_manifest_sha256:
        fail("command manifest SHA-256 mismatch")
    try:
        document = json.loads(text)
    except json.JSONDecodeError as error:
        raise ValueError("command manifest is not valid JSON") from error
    if set(document) != {"spdx_copyright", "spdx_license_identifier", "schema_version", "source_commit", "components"} or \
       document["spdx_copyright"] != "2026 Teremoq contributors" or \
       document["spdx_license_identifier"] != "Apache-2.0" or document["schema_version"] != 1:
        fail("command manifest top-level schema mismatch")
    if document["source_commit"] != source_commit:
        fail("command manifest commit mismatch")
    components = document["components"]
    if not isinstance(components, dict) or set(components) != set(COMPONENTS):
        fail("command manifest must contain exactly relay, gateway and source")
    parsed: dict[str, tuple[Path, list[str], Path, str]] = {}
    for name in COMPONENTS:
        record = components[name]
        if not isinstance(record, dict) or set(record) != {"cwd", "command", "executable_sha256"}:
            fail(f"invalid {name} command record")
        cwd = Path(record["cwd"])
        command = record["command"]
        executable_sha256 = record["executable_sha256"]
        if not isinstance(executable_sha256, str) or len(executable_sha256) != 64 or any(c not in "0123456789abcdef" for c in executable_sha256):
            fail(f"invalid {name} executable SHA-256")
        if not cwd.is_absolute() or not cwd.is_dir() or cwd.is_symlink() or cwd.resolve() != cwd:
            fail(f"{name} cwd must be an absolute canonical non-symlink directory")
        if not isinstance(command, list) or not 1 <= len(command) <= 64 or not all(isinstance(item, str) and item and len(item) <= 4096 for item in command):
            fail(f"{name} command must be a bounded argv array")
        executable = Path(command[0])
        if not executable.is_absolute() or not executable.is_file() or executable.is_symlink() or executable.resolve() != executable or not os.access(executable, os.X_OK):
            fail(f"{name} executable must be an absolute executable regular file")
        if not (path_within(executable, repo_root) or path_within(executable, artifact_root)) or \
           not (path_within(cwd, repo_root) or path_within(cwd, artifact_root)):
            fail(f"{name} executable/cwd is outside the clean worktree and immutable artifact root")
        if executable.name.lower() in {"sh", "bash", "dash", "env", "cargo", "rustc", "python", "python3", "node", "perl", "ruby", "java", "busybox", "cmd.exe", "powershell.exe", "pwsh"}:
            fail(f"{name} may not use a generic local command runner")
        if path_within(executable, artifact_root) and stat.S_IMODE(executable.stat().st_mode) & 0o222:
            fail(f"{name} artifact executable must be immutable during activation")
        if any("PRIVATE KEY" in item or "password=" in item.lower() or "token=" in item.lower() for item in command):
            fail(f"{name} command contains credential-like text")
        verify_executable_hash(executable, executable_sha256)
        parsed[name] = (executable, command, cwd, executable_sha256)
    return parsed


def verify_repository(repo_root: Path, source_commit: str, owner_commit: str) -> None:
    if not repo_root.is_absolute() or not (repo_root / ".git").exists() or repo_root.resolve() != repo_root:
        fail("repo root must be the canonical integrated worktree")
    def git(*arguments: str) -> str:
        result = subprocess.run(["git", "-C", str(repo_root), *arguments], check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        if result.returncode != 0:
            fail("cannot validate integrated source repository")
        return result.stdout.strip()
    if git("rev-parse", "HEAD") != source_commit:
        fail("source commit differs from exact HEAD")
    git("merge-base", "--is-ancestor", owner_commit, source_commit)
    if git("status", "--porcelain=v1", "--untracked-files=all"):
        fail("source worktree must be clean, including untracked files")


def verify_artifact_root(artifact_root: Path, run_id: str, source_commit: str) -> None:
    if not artifact_root.is_absolute() or not artifact_root.is_dir() or artifact_root.is_symlink() or artifact_root.resolve() != artifact_root:
        fail("artifact root must be an absolute canonical non-symlink directory")
    if stat.S_IMODE(artifact_root.stat().st_mode) & 0o222:
        fail("artifact root must have no write bits during activation")
    run_marker = artifact_root / "run-id"
    commit_marker = artifact_root / "source-commit"
    if any(stat.S_IMODE(path.stat().st_mode) & 0o222 for path in (run_marker, commit_marker)):
        fail("immutable artifact ownership markers must have no write bits")
    if read_regular_limited(run_marker, 128, "ascii") != f"{run_id}\n" or \
       read_regular_limited(commit_marker, 128, "ascii") != f"{source_commit}\n":
        fail("immutable artifact root ownership markers mismatch")


def require_free_udp(host: str, port: int) -> None:
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.bind((host, port))
    except OSError as error:
        raise ValueError(f"required UDP endpoint is unavailable: {port}") from error
    finally:
        probe.close()


def require_free_tcp(host: str, port: int) -> None:
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        probe.bind((host, port))
    except OSError as error:
        raise ValueError(f"required TCP endpoint is unavailable: {port}") from error
    finally:
        probe.close()


def udp_occupied(host: str, port: int) -> bool:
    try:
        require_free_udp(host, port)
    except ValueError:
        return True
    return False


def wait_until(description: str, predicate: object, processes: dict[str, subprocess.Popen[bytes]], timeout: float = 30.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for name, process in processes.items():
            if process.poll() is not None:
                fail(f"{name} exited before {description}")
        if callable(predicate) and predicate():
            return
        time.sleep(0.2)
    fail(f"timeout waiting for {description}")


def health_ready() -> bool:
    try:
        with urllib.request.urlopen("http://127.0.0.1:9080/healthz", timeout=0.5) as response:
            return response.status == 200
    except Exception:
        return False


def terminate_owned(processes: dict[str, subprocess.Popen[bytes]]) -> None:
    def group_alive(process: subprocess.Popen[bytes]) -> bool:
        try:
            os.killpg(process.pid, 0)
            return True
        except ProcessLookupError:
            return False
    for name in ("source", "proxy", "gateway", "relay"):
        process = processes.get(name)
        if process is not None and group_alive(process):
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline and any(group_alive(process) for process in processes.values()):
        time.sleep(0.1)
    for process in processes.values():
        if group_alive(process):
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    for process in processes.values():
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass


def process_metrics(processes: dict[str, subprocess.Popen[bytes]]) -> str:
    values = []
    for name in sorted(processes):
        status = Path(f"/proc/{processes[name].pid}/status")
        rss = "unavailable"
        try:
            for line in status.read_text(encoding="ascii").splitlines():
                if line.startswith("VmRSS:"):
                    rss = line.split()[1]
                    break
        except (OSError, UnicodeError):
            pass
        values.append(f"{name}_rss_kib={rss}")
    return ";".join(values)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    for name in ("commands", "authorization", "server-preflight", "client-preflight", "firewall-attestation", "certificate", "key", "fingerprint", "identity-profile", "proxy-attestation", "repo-root", "artifact-root", "state-dir"):
        parser.add_argument(f"--{name}", required=True, type=Path)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--owner-commit", required=True)
    parser.add_argument("--server-ip", required=True)
    parser.add_argument("--client-ip", required=True)
    parser.add_argument("--moq-namespace", required=True)
    parser.add_argument("--prefix-length", required=True, type=int)
    parser.add_argument("--max-clients", required=True, type=int)
    parser.add_argument("--association-margin", required=True, type=int)
    parser.add_argument("--idle-timeout", required=True, type=int)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    authorization = parse_authorization(args.authorization)
    if authorization["run_id"] != args.run_id or authorization["source_commit"] != args.source_commit or \
       authorization["owner_integration_commit"] != args.owner_commit:
        fail("authorization run binding mismatch")
    verify_repository(args.repo_root, args.source_commit, args.owner_commit)
    verify_artifact_root(args.artifact_root, args.run_id, args.source_commit)
    evidence = {
        "server_preflight_sha256": args.server_preflight,
        "client_preflight_sha256": args.client_preflight,
        "firewall_attestation_sha256": args.firewall_attestation,
        "proxy_attestation_sha256": args.proxy_attestation,
    }
    for key, path in evidence.items():
        if sha256_bounded(path) != authorization[key]:
            fail(f"authorization evidence digest mismatch: {key}")
    commands = parse_commands(args.commands, args.source_commit, authorization["commands_sha256"], args.repo_root, args.artifact_root)
    for path, maximum in ((args.key, 32768), (args.certificate, 32768), (args.fingerprint, 128)):
        read_regular_limited(path, maximum, "ascii")
    profile_text = read_regular_limited(args.identity_profile, 128, "ascii")
    if profile_text != expected_lan_identity_profile(args.server_ip):
        fail("relay LAN identity profile v2 marker mismatch")
    namespace_segments = args.moq_namespace.split("/")
    if not args.moq_namespace or len(args.moq_namespace.encode("ascii", errors="ignore")) != len(args.moq_namespace) or \
       len(args.moq_namespace) > 256 or any(not segment or segment in (".", "..") or \
       any(not (character.isascii() and (character.isalnum() or character in "-_.")) for character in segment) \
       for segment in namespace_segments):
        fail("MoQT namespace differs from the bounded Gateway path contract")
    if not args.state_dir.is_absolute() or args.state_dir.is_symlink() or not args.state_dir.is_dir():
        fail("state directory must be an absolute pre-created non-symlink directory")
    if any((args.state_dir / name).exists() for name in ("lab.pid", "lab.ready", "proxy.pid", "proxy.ready")):
        fail("lab/proxy state already exists")
    require_free_udp("127.0.0.1", 4433)
    require_free_udp("127.0.0.1", 19000)
    require_free_udp(args.server_ip, 14433)
    require_free_tcp("127.0.0.1", 9080)

    stop = False
    def request_stop(_signum: int, _frame: object) -> None:
        nonlocal stop
        stop = True
    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)
    processes: dict[str, subprocess.Popen[bytes]] = {}
    logs: list[object] = []
    pid_file = args.state_dir / "lab.pid"
    ready_file = args.state_dir / "lab.ready"
    metrics_file = args.state_dir / "runtime-metrics.tsv"
    created_state: list[Path] = []
    proxy_launched = False
    try:
        with pid_file.open("x", encoding="ascii") as stream:
            stream.write(f"{os.getpid()}\n")
        created_state.append(pid_file)
        os.chmod(pid_file, 0o600)
        common = os.environ.copy()
        common.update({
            "TEREMOQ_DEV_RELAY_BIND": "127.0.0.1:4433",
            "TEREMOQ_DEV_RELAY_LAN_IP_SAN": args.server_ip,
            "TEREMOQ_DEV_RELAY_TLS_CERT": str(args.certificate),
            "TEREMOQ_DEV_RELAY_TLS_KEY": str(args.key),
            "TEREMOQ_DEV_RELAY_TLS_FINGERPRINT": str(args.fingerprint),
            "TEREMOQ_DEV_RELAY_TLS_PROFILE": str(args.identity_profile),
            "TEREMOQ_SRT_BIND_ADDR": "127.0.0.1:19000",
            "TEREMOQ_SUPERVISOR_BIND_ADDR": "127.0.0.1:9080",
            "TEREMOQ_MOQ_RELAY_URL": "https://127.0.0.1:4433/publish",
            "TEREMOQ_MOQ_NAMESPACE": args.moq_namespace,
            "TEREMOQ_SUPERVISOR_MOQ_FINGERPRINT_PATH": str(args.fingerprint),
            "TEREMOQ_PREVIEW_GATEWAY_SRT_URL": "srt://127.0.0.1:19000?mode=caller&streamid=teremoq-main&latency=120000",
            "TEREMOQ_PREVIEW_OBSERVER_SRT_URL": "srt://127.0.0.1:19001?mode=caller&streamid=teremoq-observer-disabled&latency=120000",
        })
        for name in ("relay", "gateway", "source"):
            executable, command, cwd, executable_sha256 = commands[name]
            verify_executable_hash(executable, executable_sha256)
            log = (args.state_dir / f"{name}.log").open("xb")
            logs.append(log)
            processes[name] = subprocess.Popen(command, cwd=cwd, env=common, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            if name == "relay":
                wait_until("loopback relay UDP/4433", lambda: udp_occupied("127.0.0.1", 4433), processes)
            elif name == "gateway":
                wait_until("loopback Gateway health and SRT/19000", lambda: health_ready() and udp_occupied("127.0.0.1", 19000), processes)
            else:
                stable_at = time.monotonic() + 2
                wait_until("source two-second liveness", lambda: time.monotonic() >= stable_at, processes, 3)
        proxy_command = [
            sys.executable, str(Path(__file__).with_name("udp_proxy.py")), "--frontend-ip", args.server_ip,
            "--frontend-port", "14433", "--allowed-client-ip", args.client_ip, "--backend", "127.0.0.1:4433",
            "--prefix-length", str(args.prefix_length),
            "--max-clients", str(args.max_clients), "--association-margin", str(args.association_margin),
            "--idle-timeout", str(args.idle_timeout), "--certificate", str(args.certificate),
            "--fingerprint", str(args.fingerprint), "--attestation", str(args.proxy_attestation),
            "--state-dir", str(args.state_dir), "--run-id", args.run_id, "--source-commit", args.source_commit,
            "--owner-commit", args.owner_commit,
        ]
        proxy_log = (args.state_dir / "proxy.log").open("xb")
        logs.append(proxy_log)
        processes["proxy"] = subprocess.Popen(proxy_command, stdin=subprocess.DEVNULL, stdout=proxy_log, stderr=subprocess.STDOUT, start_new_session=True)
        proxy_launched = True
        wait_until("exact LAN proxy readiness", lambda: (args.state_dir / "proxy.ready").is_file(), processes)
        with ready_file.open("x", encoding="ascii") as stream:
            stream.write("ready\n")
        created_state.append(ready_file)
        os.chmod(ready_file, 0o600)
        with metrics_file.open("x", encoding="ascii") as metrics:
            metrics.write("timestamp_utc\tprocess_rss_kib\n")
            while not stop:
                for name, process in processes.items():
                    if process.poll() is not None:
                        fail(f"{name} exited during the LAN run")
                metrics.write(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\t{process_metrics(processes)}\n")
                metrics.flush()
                time.sleep(1)
    finally:
        terminate_owned(processes)
        if proxy_launched:
            (args.state_dir / "proxy.ready").unlink(missing_ok=True)
            (args.state_dir / "proxy.pid").unlink(missing_ok=True)
        for path in reversed(created_state):
            path.unlink(missing_ok=True)
        for log in logs:
            log.close()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"teremoq LAN activation rejected: {error}", file=sys.stderr)
        raise SystemExit(2)
