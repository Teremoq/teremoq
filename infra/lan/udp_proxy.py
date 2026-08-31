#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
"""Bounded UDP forwarder for the opt-in Teremoq LAN laboratory.

The public side is one exact RFC1918 address on UDP/14433. The backend is
always 127.0.0.1:4433. It neither parses nor logs QUIC payloads.
"""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import selectors
import signal
import socket
import ssl
import stat
import sys
import tempfile
import time
from dataclasses import dataclass

from publish_capability import RUST_LAN_CAPABILITY_INTEGRATED_COMMIT, RUST_LAN_CAPABILITY_PROVENANCE_COMMIT

FRONTEND_PORT = 14433
BACKEND = ("127.0.0.1", 4433)
MAX_CLIENTS = 25
ASSOCIATION_MARGIN = 2
MAX_DATAGRAM = 65534
ATTESTATION_KEYS = {
    "schema_version",
    "run_id",
    "source_commit",
    "server_ipv4",
    "client_ipv4",
    "network_mode",
    "network_profile",
    "windows_firewall_rule_name",
    "hyperv_firewall_rule_name",
    "firewall_verified",
    "relay_san_integration_commit",
    "certificate_fingerprint_sha256",
}


def fail(message: str) -> "NoReturn":
    raise ValueError(message)


def exact_private_ipv4(value: str, name: str) -> str:
    if "/" in value or value.lower() in {"any", "all", "broadcast"}:
        fail(f"{name} must be one exact private IPv4 address")
    try:
        parsed = ipaddress.ip_address(value)
    except ValueError as error:
        raise ValueError(f"{name} must be one exact private IPv4 address") from error
    if not isinstance(parsed, ipaddress.IPv4Address):
        fail(f"{name} must be one unicast RFC1918 IPv4 address")
    octets = parsed.packed
    rfc1918 = octets[0] == 10 or (octets[0] == 172 and 16 <= octets[1] <= 31) or (octets[0] == 192 and octets[1] == 168)
    if not rfc1918:
        fail(f"{name} must be one unicast RFC1918 IPv4 address")
    if str(parsed) != value:
        fail(f"{name} must use canonical notation")
    return value


def read_regular_limited(path: Path, maximum: int, encoding: str) -> str:
    if not path.is_absolute():
        fail("runtime input must be absolute")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ValueError("runtime input must be a readable non-symlink regular file") from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size <= 0 or metadata.st_size > maximum:
            fail("runtime input size or type is outside policy")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            payload = stream.read(maximum + 1)
        if len(payload) > maximum:
            fail("runtime input exceeds its byte limit")
        try:
            return payload.decode(encoding, errors="strict")
        except UnicodeDecodeError as error:
            raise ValueError("runtime input encoding is invalid") from error
    finally:
        os.close(descriptor)


def validate_limits(max_clients: int, margin: int, idle_timeout: int) -> None:
    if not 1 <= max_clients <= MAX_CLIENTS:
        fail("max_clients must be between 1 and 25")
    if margin != ASSOCIATION_MARGIN:
        fail("association margin is fixed to two QUIC migration/probe tuples")
    if not 5 <= idle_timeout <= 120:
        fail("idle_timeout must be between 5 and 120 seconds")


def validate_topology(server_ip: str, client_ip: str, prefix_length: int) -> None:
    if not 8 <= prefix_length <= 30:
        fail("prefix length must be between 8 and 30")
    network = ipaddress.ip_network(f"{server_ip}/{prefix_length}", strict=False)
    if ipaddress.ip_address(server_ip) in {network.network_address, network.broadcast_address} or \
       ipaddress.ip_address(client_ip) in {network.network_address, network.broadcast_address}:
        fail("server/client IP must not be the configured network or broadcast address")
    if ipaddress.ip_address(client_ip) not in network:
        fail("server and client must share the configured subnet")


def load_attestation(path: Path) -> dict[str, str]:
    text = read_regular_limited(path, 8192, "utf-8")
    values: dict[str, str] = {}
    for number, raw in enumerate(text.splitlines(), 1):
        if not raw or raw.startswith("#"):
            continue
        fields = raw.split("\t")
        if len(fields) != 2 or not all(fields):
            fail(f"invalid attestation line {number}")
        key, value = fields
        if key not in ATTESTATION_KEYS or key in values:
            fail(f"unknown or duplicate attestation key: {key}")
        values[key] = value
    if set(values) != ATTESTATION_KEYS:
        fail("attestation keys are incomplete")
    if values["schema_version"] != "1":
        fail("unsupported attestation schema")
    if values["network_mode"] != "mirrored":
        fail("WSL NAT is not allowed; a verified mirrored preflight is required")
    if values["network_profile"] not in {"Public", "Private"}:
        fail("network profile must be Public or Private")
    if values["firewall_verified"] != "true":
        fail("both exact Windows and Hyper-V firewall rules must be verified")
    if len(values["source_commit"]) != 40 or any(c not in "0123456789abcdef" for c in values["source_commit"]):
        fail("invalid source commit")
    for key in ("relay_san_integration_commit", "certificate_fingerprint_sha256"):
        expected_length = 40 if key.endswith("commit") else 64
        if len(values[key]) != expected_length or any(c not in "0123456789abcdefABCDEF" for c in values[key]):
            fail(f"invalid {key}")
    if values["relay_san_integration_commit"] != RUST_LAN_CAPABILITY_INTEGRATED_COMMIT:
        fail("attestation requires the exact integrated Rust LAN capability commit")
    run_id = values["run_id"]
    classic = f"Teremoq-LAN-{run_id}-Defender-QUIC-UDP-{FRONTEND_PORT}"
    hyperv = f"Teremoq-LAN-{run_id}-HyperV-QUIC-UDP-{FRONTEND_PORT}"
    if values["windows_firewall_rule_name"] != classic or values["hyperv_firewall_rule_name"] != hyperv:
        fail("firewall attestation rule names do not match the exact run IDs")
    return values


def verify_certificate(cert_path: Path, fingerprint_path: Path, server_ip: str, attested_fingerprint: str) -> str:
    pem = read_regular_limited(cert_path, 32768, "ascii")
    fingerprint_text = read_regular_limited(fingerprint_path, 128, "ascii")
    try:
        der = ssl.PEM_cert_to_DER_cert(pem)
        with tempfile.NamedTemporaryFile(mode="w", encoding="ascii", prefix="teremoq-lan-cert-", suffix=".pem") as certificate_copy:
            certificate_copy.write(pem)
            certificate_copy.flush()
            decoded = ssl._ssl._test_decode_cert(certificate_copy.name)  # type: ignore[attr-defined]
    except (ValueError, ssl.SSLError) as error:
        raise ValueError("cannot decode relay certificate") from error
    sans = decoded.get("subjectAltName", ())
    dns_sans = [value for kind, value in sans if kind == "DNS"]
    ip_sans = [value for kind, value in sans if kind == "IP Address"]
    if dns_sans != ["localhost"] or ip_sans != ["127.0.0.1", server_ip]:
        fail("relay certificate SANs must be exactly DNS localhost and ordered IPs 127.0.0.1, server_ipv4")
    try:
        not_before = ssl.cert_time_to_seconds(decoded["notBefore"])
        not_after = ssl.cert_time_to_seconds(decoded["notAfter"])
    except (KeyError, ValueError) as error:
        raise ValueError("relay certificate validity is unavailable") from error
    now = time.time()
    validity = not_after - not_before
    if not_before > now or not_after <= now:
        fail("relay certificate is not currently valid")
    if not 0 < validity < 14 * 24 * 60 * 60:
        fail("relay certificate total validity must be positive and strictly below 14 days")
    actual = hashlib.sha256(der).hexdigest()
    recorded = fingerprint_text.strip().lower()
    if len(recorded) != 64 or any(c not in "0123456789abcdef" for c in recorded):
        fail("invalid fingerprint file")
    if actual != recorded or actual != attested_fingerprint.lower():
        fail("relay certificate fingerprint mismatch")
    return actual


@dataclass
class Association:
    peer: tuple[str, int]
    backend: socket.socket
    last_seen: float


class BoundedUdpProxy:
    def __init__(self, frontend_ip: str, allowed_client_ip: str, max_clients: int, margin: int, idle_timeout: int) -> None:
        validate_limits(max_clients, margin, idle_timeout)
        self.frontend_ip = frontend_ip
        self.allowed_client_ip = allowed_client_ip
        self.capacity = max_clients + margin
        self.idle_timeout = idle_timeout
        self.selector = selectors.DefaultSelector()
        self.frontend: socket.socket | None = None
        self.associations: dict[tuple[str, int], Association] = {}
        self.running = True
        self.metrics = {"forwarded_frontend": 0, "forwarded_backend": 0, "rejected_source": 0, "rejected_capacity": 0, "rejected_oversize": 0, "expired": 0}

    def source_allowed(self, peer: tuple[str, int]) -> bool:
        return peer[0] == self.allowed_client_ip

    def can_create(self) -> bool:
        return len(self.associations) < self.capacity

    def bind(self) -> None:
        frontend = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            frontend.setblocking(False)
            frontend.bind((self.frontend_ip, FRONTEND_PORT))
        except Exception:
            frontend.close()
            raise
        self.frontend = frontend
        self.selector.register(frontend, selectors.EVENT_READ, None)

    def _association(self, peer: tuple[str, int], now: float) -> Association | None:
        current = self.associations.get(peer)
        if current is not None:
            current.last_seen = now
            return current
        if not self.can_create():
            self.metrics["rejected_capacity"] += 1
            return None
        backend = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        backend.setblocking(False)
        backend.connect(BACKEND)
        current = Association(peer, backend, now)
        self.associations[peer] = current
        self.selector.register(backend, selectors.EVENT_READ, current)
        return current

    def _expire(self, now: float) -> None:
        for peer, association in list(self.associations.items()):
            if now - association.last_seen < self.idle_timeout:
                continue
            self.selector.unregister(association.backend)
            association.backend.close()
            del self.associations[peer]
            self.metrics["expired"] += 1

    def step(self, timeout: float = 0.2) -> None:
        now = time.monotonic()
        for key, _ in self.selector.select(timeout):
            if key.data is None:
                assert self.frontend is not None
                data, peer = self.frontend.recvfrom(MAX_DATAGRAM + 1)
                if len(data) > MAX_DATAGRAM:
                    self.metrics["rejected_oversize"] += 1
                    continue
                if not self.source_allowed(peer):
                    self.metrics["rejected_source"] += 1
                    continue
                association = self._association(peer, now)
                if association is None:
                    continue
                association.backend.send(data)
                self.metrics["forwarded_frontend"] += 1
            else:
                association = key.data
                data = association.backend.recv(MAX_DATAGRAM + 1)
                if len(data) > MAX_DATAGRAM:
                    self.metrics["rejected_oversize"] += 1
                    continue
                if self.frontend is not None:
                    self.frontend.sendto(data, association.peer)
                    self.metrics["forwarded_backend"] += 1
                association.last_seen = now
        self._expire(time.monotonic())

    def close(self) -> None:
        for association in list(self.associations.values()):
            try:
                self.selector.unregister(association.backend)
            except Exception:
                pass
            association.backend.close()
        self.associations.clear()
        if self.frontend is not None:
            try:
                self.selector.unregister(self.frontend)
            except Exception:
                pass
            self.frontend.close()
            self.frontend = None
        self.selector.close()


def emit(event: str, proxy: BoundedUdpProxy) -> None:
    record = {"schema_version": 1, "event": event, "active_associations": len(proxy.associations), **proxy.metrics}
    print(json.dumps(record, sort_keys=True, separators=(",", ":")), flush=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--frontend-ip", required=True)
    parser.add_argument("--frontend-port", required=True, type=int)
    parser.add_argument("--allowed-client-ip", required=True)
    parser.add_argument("--prefix-length", required=True, type=int)
    parser.add_argument("--backend", required=True)
    parser.add_argument("--max-clients", required=True, type=int)
    parser.add_argument("--association-margin", required=True, type=int)
    parser.add_argument("--idle-timeout", required=True, type=int)
    parser.add_argument("--certificate", required=True, type=Path)
    parser.add_argument("--fingerprint", required=True, type=Path)
    parser.add_argument("--attestation", required=True, type=Path)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--owner-commit", required=True)
    parser.add_argument("--state-dir", required=True, type=Path)
    return parser.parse_args()


def publish_startup_state(state_dir: Path, pid: int, before_ready: object | None = None) -> tuple[Path, Path]:
    ready = state_dir / "proxy.ready"
    pid_file = state_dir / "proxy.pid"
    created: list[Path] = []
    try:
        with pid_file.open("x", encoding="ascii") as stream:
            stream.write(f"{pid}\n")
        os.chmod(pid_file, 0o600)
        created.append(pid_file)
        if callable(before_ready):
            before_ready()
        with ready.open("x", encoding="ascii") as stream:
            stream.write("ready\n")
        os.chmod(ready, 0o600)
        created.append(ready)
        return ready, pid_file
    except Exception:
        for path in reversed(created):
            path.unlink(missing_ok=True)
        raise


def main() -> int:
    args = parse_args()
    if args.owner_commit != RUST_LAN_CAPABILITY_INTEGRATED_COMMIT:
        fail("proxy owner commit override is forbidden")
    if args.frontend_port != FRONTEND_PORT or args.backend != f"{BACKEND[0]}:{BACKEND[1]}":
        fail("proxy endpoints are fixed to private UDP/14433 -> 127.0.0.1:4433")
    server_ip = exact_private_ipv4(args.frontend_ip, "frontend_ip")
    client_ip = exact_private_ipv4(args.allowed_client_ip, "allowed_client_ip")
    if server_ip == client_ip:
        fail("frontend and client IPs must differ")
    validate_topology(server_ip, client_ip, args.prefix_length)
    validate_limits(args.max_clients, args.association_margin, args.idle_timeout)
    attestation = load_attestation(args.attestation)
    if attestation["server_ipv4"] != server_ip or attestation["client_ipv4"] != client_ip:
        fail("attestation IP mismatch")
    if attestation["run_id"] != args.run_id or attestation["source_commit"] != args.source_commit or \
       attestation["relay_san_integration_commit"] != args.owner_commit:
        fail("attestation run/commit binding mismatch")
    verify_certificate(args.certificate, args.fingerprint, server_ip, attestation["certificate_fingerprint_sha256"])
    if not args.state_dir.is_absolute() or args.state_dir.is_symlink() or not args.state_dir.is_dir():
        fail("state-dir must be a pre-created absolute non-symlink directory")
    proxy = BoundedUdpProxy(server_ip, client_ip, args.max_clients, args.association_margin, args.idle_timeout)
    ready = args.state_dir / "proxy.ready"
    pid_file = args.state_dir / "proxy.pid"
    try:
        proxy.bind()  # Exact bind also proves the private IP is locally assigned and the port is free.
        ready, pid_file = publish_startup_state(args.state_dir, os.getpid())
    except Exception:
        proxy.close()
        raise
    def stop(_signum: int, _frame: object) -> None:
        proxy.running = False
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    emit("lan_udp_proxy_ready", proxy)
    try:
        last_metrics = time.monotonic()
        while proxy.running:
            proxy.step()
            if time.monotonic() - last_metrics >= 10:
                emit("lan_udp_proxy_metrics", proxy)
                last_metrics = time.monotonic()
    finally:
        proxy.close()
        ready.unlink(missing_ok=True)
        pid_file.unlink(missing_ok=True)
        emit("lan_udp_proxy_stopped", proxy)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(json.dumps({"schema_version": 1, "event": "lan_udp_proxy_rejected", "reason": str(error)}, separators=(",", ":")), file=sys.stderr)
        raise SystemExit(2)
