#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
"""Bounded HTTPS control channel for the two-host LAN laboratory."""

from __future__ import annotations

import argparse
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import ssl
import stat
import tempfile
import threading
import time
import urllib.request
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
sys.path.insert(0, str(Path(__file__).resolve().parent))
from lab_runtime import parse_windows_preflight

SCHEMA_VERSION = 1
PORT = 18443
MAX_BODY = 32 * 1024
MAX_MESSAGE = 16 * 1024
MAX_TASKS = 32
MAX_EVENTS_PER_TASK = 256
MAX_EVENT_LOG = 8 * 1024 * 1024
READ_TIMEOUT_SECONDS = 10
MIN_REQUEST_INTERVAL_SECONDS = 0.1
ACTIONS = (
    "diagnose-build",
    "prepare-client",
    "preflight",
    "player-1",
    "load-5",
    "load-10",
    "load-25",
    "wifi-observe",
    "collect",
    "stop",
)
STATUSES = ("started", "progress", "complete", "blocked", "failed")
SENSITIVE_PATTERNS = (
    re.compile(r"-----begin [a-z0-9 ]*private key-----", re.IGNORECASE),
    re.compile(r"authorization\s*:\s*bearer\s+\S+", re.IGNORECASE),
    re.compile(r"(?:ghp_|github_pat_)[a-z0-9_]+", re.IGNORECASE),
    re.compile(r"(?:password|passwd|token|secret|api[_-]?key)\s*[=:]\s*\S+", re.IGNORECASE),
)


def fail(message: str) -> None:
    raise ValueError(message)


def exact_object(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        fail(f"{label} schema differs from the closed contract")
    return value


def bounded_text(value: Any, label: str, maximum: int) -> str:
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > maximum:
        fail(f"{label} is outside the byte policy")
    if any(ord(character) < 32 and character not in "\r\n\t" for character in value):
        fail(f"{label} contains a control character")
    if any(pattern.search(value) for pattern in SENSITIVE_PATTERNS):
        fail(f"{label} contains a blocked sensitive marker")
    return value


def exact_private_ipv4(value: str, label: str) -> str:
    try:
        address = ipaddress.ip_address(value)
    except ValueError as error:
        raise ValueError(f"{label} is not an IPv4 address") from error
    private_networks = (
        ipaddress.ip_network("10.0.0.0/8"),
        ipaddress.ip_network("172.16.0.0/12"),
        ipaddress.ip_network("192.168.0.0/16"),
    )
    if address.version != 4 or not any(address in network for network in private_networks):
        fail(f"{label} must be one exact private unicast IPv4 address")
    return str(address)


def decode_json_object(data: bytes, label: str) -> dict[str, Any]:
    def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, item in pairs:
            if key in value:
                fail(f"{label} contains a duplicate key")
            value[key] = item
        return value

    try:
        value = json.loads(data.decode("utf-8", errors="strict"), object_pairs_hook=reject_duplicates)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"invalid {label} JSON") from error
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    return value


def read_regular(path: Path, maximum: int, mode: int | None = None) -> bytes:
    if path.is_symlink() or not path.is_file():
        fail(f"unsafe file: {path}")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        metadata = os.fstat(descriptor)
        if mode is not None and metadata.st_mode & 0o777 != mode:
            fail(f"unsafe permissions: {path}")
        if metadata.st_size < 1 or metadata.st_size > maximum:
            fail(f"file size outside policy: {path}")
        chunks = []
        remaining = metadata.st_size
        while remaining:
            chunk = os.read(descriptor, min(remaining, 65536))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        if len(data) != metadata.st_size:
            fail(f"file changed while reading: {path}")
        return data
    finally:
        os.close(descriptor)


def read_regular_at(directory: int, name: str, maximum: int, mode: int | None = None) -> bytes:
    descriptor = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=directory)
    try:
        metadata = os.fstat(descriptor)
        if mode is not None and metadata.st_mode & 0o777 != mode:
            fail(f"unsafe permissions: {name}")
        if metadata.st_size < 1 or metadata.st_size > maximum:
            fail(f"file size outside policy: {name}")
        data = bytearray()
        while len(data) < metadata.st_size:
            chunk = os.read(descriptor, min(metadata.st_size - len(data), 65536))
            if not chunk:
                break
            data.extend(chunk)
        if len(data) != metadata.st_size:
            fail(f"file changed while reading: {name}")
        return bytes(data)
    finally:
        os.close(descriptor)


def atomic_json(path: Path, value: Any) -> None:
    encoded = (json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n").encode("utf-8")
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb", closefd=True) as output:
            output.write(encoded)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def atomic_json_at(directory: int, name: str, value: Any) -> None:
    encoded = (json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n").encode("utf-8")
    temporary = f".{name}.{secrets.token_hex(12)}"
    descriptor = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0), 0o600, dir_fd=directory)
    try:
        with os.fdopen(descriptor, "wb", closefd=True) as output:
            output.write(encoded)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, name, src_dir_fd=directory, dst_dir_fd=directory)
    finally:
        try:
            os.unlink(temporary, dir_fd=directory)
        except FileNotFoundError:
            pass


def sha256_file(path: Path, maximum: int) -> tuple[bytes, str]:
    payload = read_regular(path, maximum)
    return payload, hashlib.sha256(payload).hexdigest()


def expected_start_authorization(arguments: argparse.Namespace, server_ip: str, client_ip: str) -> dict[str, Any]:
    preflight_payload, preflight_sha = sha256_file(arguments.server_preflight, 131072)
    firewall_payload, firewall_sha = sha256_file(arguments.firewall_attestation, 16384)
    fingerprint = read_regular(arguments.fingerprint, 128).decode("ascii").strip().lower()
    certificate = read_regular(arguments.certificate, 32768).decode("ascii")
    actual_fingerprint = hashlib.sha256(ssl.PEM_cert_to_DER_cert(certificate)).hexdigest()
    if not re.fullmatch(r"[0-9a-f]{64}", fingerprint) or fingerprint != actual_fingerprint:
        fail("coordination certificate fingerprint differs from the verified public pin")

    # Reuse the runtime's complete, closed native contract.  Do not duplicate a
    # permissive subset here: bind, authorization, and serve use this same gate.
    parse_windows_preflight(preflight_payload, "server", arguments.run_id, arguments.source_commit,
                            server_ip, client_ip, 24, "Public", 25, 1280, 2, 2048, 4096)

    firewall = decode_json_object(firewall_payload, "coordination firewall attestation")
    expected_firewall = {
        "schema_version": 1, "run_id": arguments.run_id, "source_commit": arguments.source_commit,
        "server_ipv4": server_ip, "client_ipv4": client_ip, "network_profile": "Public",
        "protocol": "UDP", "local_port": 14433,
        "classic_rule_name": f"Teremoq-LAN-{arguments.run_id}-Defender-QUIC-UDP-14433",
        "hyperv_rule_name": f"Teremoq-LAN-{arguments.run_id}-HyperV-QUIC-UDP-14433",
        "classic_rule_count": 1, "hyperv_rule_count": 1, "edge_traversal_policy": "Block",
        "firewall_verified": True, "default_inbound_action_changed": False,
        "coordination_tls_port": PORT, "coordination_firewall_verified": True,
    }
    if firewall != expected_firewall:
        fail("coordination firewall attestation differs from the exact rule plan")

    return {
        "schema_version": 1, "run_id": arguments.run_id, "source_commit": arguments.source_commit,
        "server_ipv4": server_ip, "client_ipv4": client_ip, "coordination_tls_port": PORT,
        "server_preflight_sha256": preflight_sha, "firewall_attestation_sha256": firewall_sha,
        "certificate_fingerprint_sha256": fingerprint, "authorized": True,
    }


def create_start_authorization(arguments: argparse.Namespace, server_ip: str, client_ip: str) -> None:
    output = arguments.output
    if not output.is_absolute() or output.exists() or output.parent.is_symlink() or not output.parent.is_dir():
        fail("authorization output must be a new absolute file in an existing private directory")
    if output.parent.stat().st_mode & 0o777 != 0o700:
        fail("authorization output directory permissions must be 0700")
    atomic_json(output, expected_start_authorization(arguments, server_ip, client_ip))


def verify_start_evidence(arguments: argparse.Namespace, server_ip: str, client_ip: str) -> None:
    authorization_payload, _authorization_sha = sha256_file(arguments.authorization, 8192)
    authorization = decode_json_object(authorization_payload, "coordination authorization")
    exact_object(authorization, {
        "schema_version", "run_id", "source_commit", "server_ipv4", "client_ipv4", "coordination_tls_port",
        "server_preflight_sha256", "firewall_attestation_sha256", "certificate_fingerprint_sha256", "authorized",
    }, "coordination authorization")
    if authorization != expected_start_authorization(arguments, server_ip, client_ip):
        fail("coordination authorization is not bound to exact activation evidence")


def verify_rollback_evidence(path: Path, run_id: str, source_commit: str, server_ip: str, client_ip: str) -> None:
    document = decode_json_object(read_regular(path, 8192), "firewall rollback attestation")
    expected = {
        "schema_version": 1, "run_id": run_id, "source_commit": source_commit,
        "server_ipv4": server_ip, "client_ipv4": client_ip, "quic_udp_port": 14433,
        "coordination_tls_port": PORT, "classic_rules_absent": True, "hyperv_rules_absent": True,
        "default_inbound_action_changed": False, "status": "rolled_back",
    }
    if document != expected:
        fail("firewall rollback attestation differs from the exact closed contract")


class ChannelState:
    def __init__(self, root: Path, run_id: str, source_commit: str, server_ip: str, client_ip: str):
        self.root = root
        self.run_id = run_id
        self.source_commit = source_commit
        self.server_ip = server_ip
        self.client_ip = client_ip
        self.lock = threading.Lock()
        self.last_request = {"client": 0.0, "management": 0.0}
        self.state_path = root / "channel-state.json"
        self.events_path = root / "channel-events.jsonl"
        self.pairing_path = root / "pairing-code"
        self.management_path = root / "management-token"
        self.root_descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0))
        root_metadata = os.fstat(self.root_descriptor)
        self.root_identity = (root_metadata.st_dev, root_metadata.st_ino)
        self.document = self._load()

    def _verify_root(self) -> None:
        if self.root.is_symlink():
            fail("channel state root was replaced")
        path_metadata = os.lstat(self.root)
        descriptor_metadata = os.fstat(self.root_descriptor)
        if not stat.S_ISDIR(path_metadata.st_mode) or (path_metadata.st_dev, path_metadata.st_ino) != self.root_identity or (descriptor_metadata.st_dev, descriptor_metadata.st_ino) != self.root_identity:
            fail("channel state root identity changed")

    def _load(self) -> dict[str, Any]:
        self._verify_root()
        document = decode_json_object(read_regular_at(self.root_descriptor, "channel-state.json", 65536, 0o600), "channel state")
        exact_object(
            document,
            {"schema_version", "run_id", "source_commit", "client_ipv4", "paired", "session_sha256", "management_sequence", "last_management_request", "tasks"},
            "channel state",
        )
        if (
            type(document["schema_version"]) is not int
            or document["schema_version"] != SCHEMA_VERSION
            or document["run_id"] != self.run_id
            or document["source_commit"] != self.source_commit
            or document["client_ipv4"] != self.client_ip
            or not isinstance(document["paired"], bool)
            or type(document["management_sequence"]) is not int
            or document["management_sequence"] < 0
            or not isinstance(document["last_management_request"], str)
            or not isinstance(document["tasks"], list)
            or len(document["tasks"]) > MAX_TASKS
            or (document["paired"] and (not isinstance(document["session_sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", document["session_sha256"])))
            or ((not document["paired"]) and document["session_sha256"] is not None)
            or (document["management_sequence"] == 0 and document["last_management_request"] != "")
        ):
            fail("channel state identity differs from invocation")
        for index, task in enumerate(document["tasks"], 1):
            exact_object(task, {"sequence", "action", "completed", "last_event", "terminal_status", "management_request_id", "cancel_requested"}, "task")
            if type(task["sequence"]) is not int or task["sequence"] != index or task["action"] not in ACTIONS or not isinstance(task["completed"], bool):
                fail("invalid task state")
            if type(task["last_event"]) is not int or task["last_event"] < 0:
                fail("invalid task event counter")
            if task["terminal_status"] not in ("pending", "complete", "blocked", "failed") or not isinstance(task["management_request_id"], str) or not isinstance(task["cancel_requested"], bool):
                fail("invalid task terminal state")
            if not re.fullmatch(r"(?:|[0-9a-f]{64})", task["management_request_id"]) or (task["completed"] != (task["terminal_status"] != "pending")):
                fail("task state coherence differs from closed contract")
        return document

    def _persist(self) -> None:
        self._verify_root()
        atomic_json_at(self.root_descriptor, "channel-state.json", self.document)

    def _rate_limit(self, actor: str) -> None:
        now = time.monotonic()
        if now - self.last_request[actor] < MIN_REQUEST_INTERVAL_SECONDS:
            fail("request rate exceeded")
        self.last_request[actor] = now

    def pair(self, request: dict[str, Any]) -> dict[str, Any]:
        exact_object(request, {"schema_version", "run_id", "source_commit", "pairing_code"}, "pair request")
        if type(request["schema_version"]) is not int or request["schema_version"] != SCHEMA_VERSION or request["run_id"] != self.run_id or request["source_commit"] != self.source_commit:
            fail("pair request identity mismatch")
        candidate = bounded_text(request["pairing_code"], "pairing code", 128).encode("ascii")
        with self.lock:
            self._verify_root()
            self._rate_limit("client")
            if self.document["paired"]:
                fail("pairing code was already consumed")
            expected = read_regular_at(self.root_descriptor, "pairing-code", 128, 0o600).strip()
            if not hmac.compare_digest(candidate, expected):
                fail("pairing rejected")
            session = secrets.token_hex(32)
            self.document["paired"] = True
            self.document["session_sha256"] = hashlib.sha256(session.encode("ascii")).hexdigest()
            self._persist()
            os.unlink("pairing-code", dir_fd=self.root_descriptor)
            return {"schema_version": SCHEMA_VERSION, "run_id": self.run_id, "source_commit": self.source_commit, "session": session}

    def authenticate(self, session: str) -> None:
        if not isinstance(session, str) or len(session) != 64 or any(character not in "0123456789abcdef" for character in session):
            fail("invalid session credential")
        expected = self.document["session_sha256"]
        if not self.document["paired"] or not isinstance(expected, str):
            fail("channel is not paired")
        actual = hashlib.sha256(session.encode("ascii")).hexdigest()
        if not hmac.compare_digest(actual, expected):
            fail("session rejected")

    def poll(self, request: dict[str, Any], session: str) -> dict[str, Any]:
        exact_object(request, {"schema_version", "run_id", "source_commit"}, "poll request")
        if type(request["schema_version"]) is not int or request != {"schema_version": SCHEMA_VERSION, "run_id": self.run_id, "source_commit": self.source_commit}:
            fail("poll request identity mismatch")
        with self.lock:
            self._verify_root()
            self._rate_limit("client")
            self.authenticate(session)
            task = next((item for item in self.document["tasks"] if not item["completed"]), None)
            action = "wait" if task is None else task["action"]
            sequence = 0 if task is None else task["sequence"]
            return {"schema_version": SCHEMA_VERSION, "run_id": self.run_id, "source_commit": self.source_commit, "sequence": sequence, "action": action}

    def event(self, request: dict[str, Any], session: str) -> dict[str, Any]:
        exact_object(
            request,
            {"schema_version", "run_id", "source_commit", "sequence", "event", "action", "status", "message"},
            "event request",
        )
        if type(request["schema_version"]) is not int or request["schema_version"] != SCHEMA_VERSION or request["run_id"] != self.run_id or request["source_commit"] != self.source_commit:
            fail("event identity mismatch")
        if type(request["sequence"]) is not int or type(request["event"]) is not int or request["sequence"] < 1 or request["event"] < 1 or request["event"] > MAX_EVENTS_PER_TASK:
            fail("event counters are invalid")
        if request["action"] not in ACTIONS or request["status"] not in STATUSES:
            fail("event action or status is invalid")
        bounded_text(request["message"], "event message", MAX_MESSAGE)
        with self.lock:
            self._verify_root()
            self._rate_limit("client")
            self.authenticate(session)
            tasks = self.document["tasks"]
            if request["sequence"] > len(tasks):
                fail("event references an unknown task")
            task = tasks[request["sequence"] - 1]
            if task["action"] != request["action"] or task["completed"] or request["event"] != task["last_event"] + 1:
                fail("event does not match the active task")
            if request["status"] in ("complete", "blocked", "failed"):
                task["completed"] = True
                task["terminal_status"] = request["status"]
            task["last_event"] = request["event"]
            line = (json.dumps(request, separators=(",", ":"), sort_keys=True) + "\n").encode("utf-8")
            try:
                log_size = os.stat("channel-events.jsonl", dir_fd=self.root_descriptor, follow_symlinks=False).st_size
            except FileNotFoundError:
                log_size = 0
            if log_size + len(line) > MAX_EVENT_LOG:
                fail("event log quota exceeded")
            descriptor = os.open("channel-events.jsonl", os.O_APPEND | os.O_CREAT | os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0), 0o600, dir_fd=self.root_descriptor)
            try:
                metadata = os.fstat(descriptor)
                if metadata.st_mode & 0o777 != 0o600:
                    fail("event log permissions differ from 0600")
                written = 0
                while written < len(line):
                    count = os.write(descriptor, line[written:])
                    if count < 1:
                        fail("event log write was partial")
                    written += count
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            self._persist()
            return {"schema_version": SCHEMA_VERSION, "sequence": request["sequence"], "event": request["event"], "accepted": True, "cancel_requested": task["cancel_requested"]}

    def enqueue(self, request: dict[str, Any], management: str) -> dict[str, Any]:
        exact_object(request, {"schema_version", "run_id", "source_commit", "management_sequence", "request_id", "action"}, "management request")
        if type(request["schema_version"]) is not int or request["schema_version"] != SCHEMA_VERSION or request["run_id"] != self.run_id or request["source_commit"] != self.source_commit:
            fail("management request identity mismatch")
        if request["action"] not in ACTIONS:
            fail("management action is outside the allowlist")
        if type(request["management_sequence"]) is not int or request["management_sequence"] < 1 or not re.fullmatch(r"[0-9a-f]{32}", request["request_id"]):
            fail("management sequence or request id is invalid")
        candidate = management.encode("ascii")
        with self.lock:
            self._verify_root()
            expected = read_regular_at(self.root_descriptor, "management-token", 128, 0o600).strip()
            if not hmac.compare_digest(candidate, expected):
                fail("management credential rejected")
            self._rate_limit("management")
            if request["management_sequence"] != self.document["management_sequence"] + 1 or request["request_id"] == self.document["last_management_request"]:
                fail("management replay or sequence gap rejected")
            tasks = self.document["tasks"]
            pending = next((task for task in tasks if not task["completed"]), None)
            if pending is not None:
                if request["action"] != "stop" or pending["action"] == "stop":
                    fail("one task is already pending")
                if len(tasks) >= MAX_TASKS:
                    fail("task quota exceeded")
                pending["cancel_requested"] = True
                sequence = len(tasks) + 1
                self.document["management_sequence"] = request["management_sequence"]
                self.document["last_management_request"] = request["request_id"]
                tasks.append({"sequence": sequence, "action": "stop", "completed": False, "last_event": 0,
                              "terminal_status": "pending", "management_request_id": request["request_id"], "cancel_requested": False})
                self._persist()
                return {"schema_version": SCHEMA_VERSION, "sequence": sequence, "action": "stop", "accepted": True,
                        "cancellation_sequence": pending["sequence"]}
            if not tasks:
                allowed = {"diagnose-build"}
            else:
                previous = tasks[-1]
                if previous["terminal_status"] in ("failed", "blocked"):
                    allowed = {previous["action"], "stop"}
                elif previous["action"] == "diagnose-build":
                    allowed = {"prepare-client", "stop"}
                elif previous["action"] == "prepare-client":
                    allowed = {"preflight", "stop"}
                elif previous["action"] == "preflight":
                    allowed = {"player-1", "stop"}
                elif previous["action"] in ("player-1", "load-5", "load-10", "load-25", "wifi-observe"):
                    allowed = {"collect", "stop"}
                elif previous["action"] == "collect":
                    measured = next((task["action"] for task in reversed(tasks[:-1]) if task["action"] != "collect"), "")
                    allowed = {"player-1": "load-5", "load-5": "load-10", "load-10": "load-25", "load-25": "wifi-observe", "wifi-observe": "stop"}.get(measured, "stop")
                    allowed = {allowed, "stop"}
                else:
                    allowed = set()
            if request["action"] not in allowed:
                fail("management action violates the progressive LAN gate")
            if len(self.document["tasks"]) >= MAX_TASKS:
                fail("task quota exceeded")
            sequence = len(self.document["tasks"]) + 1
            self.document["management_sequence"] = request["management_sequence"]
            self.document["last_management_request"] = request["request_id"]
            self.document["tasks"].append({"sequence": sequence, "action": request["action"], "completed": False, "last_event": 0,
                                           "terminal_status": "pending", "management_request_id": request["request_id"], "cancel_requested": False})
            self._persist()
            return {"schema_version": SCHEMA_VERSION, "sequence": sequence, "action": request["action"], "accepted": True}


class BoundedThreadingHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 4

    def __init__(self, *arguments: Any, **keywords: Any):
        self._workers = threading.BoundedSemaphore(4)
        super().__init__(*arguments, **keywords)

    def process_request(self, request: Any, client_address: Any) -> None:
        if not self._workers.acquire(blocking=False):
            self.shutdown_request(request)
            return
        super().process_request(request, client_address)

    def process_request_thread(self, request: Any, client_address: Any) -> None:
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._workers.release()


def parse_body(handler: BaseHTTPRequestHandler) -> dict[str, Any]:
    if handler.headers.get("Content-Type") != "application/json":
        fail("content type must be application/json")
    length_text = handler.headers.get("Content-Length")
    if not length_text or not length_text.isdigit():
        fail("missing content length")
    length = int(length_text)
    if length < 2 or length > MAX_BODY:
        fail("body size outside policy")
    body = handler.rfile.read(length)
    if len(body) != length:
        fail("partial request body")
    return decode_json_object(body, "request")


def make_handler(state: ChannelState):
    class Handler(BaseHTTPRequestHandler):
        server_version = "TeremoqLanChannel/1"
        sys_version = ""

        def log_message(self, _format: str, *_arguments: Any) -> None:
            return

        def _response(self, status: int, value: dict[str, Any] | None = None) -> None:
            encoded = b"" if value is None else json.dumps(value, separators=(",", ":"), sort_keys=True).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            self.end_headers()
            if encoded:
                self.wfile.write(encoded)

        def do_POST(self) -> None:
            try:
                self.connection.settimeout(READ_TIMEOUT_SECONDS)
                request = parse_body(self)
                if self.path == "/v1/manage":
                    if self.client_address[0] != state.server_ip:
                        fail("management source address rejected")
                    response = state.enqueue(request, self.headers.get("X-Teremoq-Management", ""))
                elif self.path == "/v1/pair":
                    if self.client_address[0] != state.client_ip:
                        fail("client source address rejected")
                    response = state.pair(request)
                elif self.path == "/v1/poll":
                    if self.client_address[0] != state.client_ip:
                        fail("client source address rejected")
                    response = state.poll(request, self.headers.get("X-Teremoq-Session", ""))
                elif self.path == "/v1/event":
                    if self.client_address[0] != state.client_ip:
                        fail("client source address rejected")
                    response = state.event(request, self.headers.get("X-Teremoq-Session", ""))
                else:
                    fail("path rejected")
                self._response(200, response)
            except Exception:
                self._response(403)

        def do_GET(self) -> None:
            self._response(405)

    return Handler


def initialize(root: Path, run_id: str, source_commit: str, client_ip: str) -> None:
    if root.exists():
        fail("channel state root must be absent")
    root.mkdir(mode=0o700, parents=True)
    pairing = secrets.token_hex(24)
    management = secrets.token_hex(32)
    pairing_path = root / "pairing-code"
    pairing_path.write_text(pairing + "\n", encoding="ascii")
    os.chmod(pairing_path, 0o600)
    management_path = root / "management-token"
    management_path.write_text(management + "\n", encoding="ascii")
    os.chmod(management_path, 0o600)
    atomic_json(root / "channel-state.json", {
        "schema_version": SCHEMA_VERSION,
        "run_id": run_id,
        "source_commit": source_commit,
        "client_ipv4": client_ip,
        "paired": False,
        "session_sha256": None,
        "management_sequence": 0,
        "last_management_request": "",
        "tasks": [],
    })
    print(pairing)


def enqueue(server_ip: str, certificate: Path, root: Path, run_id: str, source_commit: str, action: str) -> None:
    if action not in ACTIONS:
        fail("management action is outside the allowlist")
    management = read_regular(root / "management-token", 128, 0o600).decode("ascii").strip()
    document = decode_json_object(read_regular(root / "channel-state.json", 65536, 0o600), "channel state")
    management_sequence = document.get("management_sequence")
    if type(management_sequence) is not int or management_sequence < 0:
        fail("management state sequence is invalid")
    body = json.dumps({"schema_version": SCHEMA_VERSION, "run_id": run_id, "source_commit": source_commit,
                       "management_sequence": management_sequence + 1, "request_id": secrets.token_hex(16), "action": action}, separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(
        f"https://{server_ip}:{PORT}/v1/manage",
        data=body,
        method="POST",
        headers={"Content-Type": "application/json", "X-Teremoq-Management": management},
    )
    context = ssl.create_default_context(cafile=str(certificate))
    with urllib.request.urlopen(request, context=context, timeout=READ_TIMEOUT_SECONDS) as response:
        reply = json.loads(response.read(MAX_BODY + 1).decode("utf-8"))
    if response.status != 200 or reply.get("accepted") is not True or reply.get("action") != action:
        fail("management enqueue was not acknowledged")
    print(json.dumps(reply, separators=(",", ":"), sort_keys=True))


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    initialize_parser = subparsers.add_parser("init")
    serve_parser = subparsers.add_parser("serve")
    enqueue_parser = subparsers.add_parser("enqueue")
    rollback_parser = subparsers.add_parser("verify-rollback")
    authorize_parser = subparsers.add_parser("authorize")
    for item in (initialize_parser, serve_parser, enqueue_parser, rollback_parser):
        item.add_argument("--state-root", required=True, type=Path)
        item.add_argument("--run-id", required=True)
        item.add_argument("--source-commit", required=True)
        item.add_argument("--client-ip", required=True)
    authorize_parser.add_argument("--run-id", required=True)
    authorize_parser.add_argument("--source-commit", required=True)
    authorize_parser.add_argument("--server-ip", required=True)
    authorize_parser.add_argument("--client-ip", required=True)
    authorize_parser.add_argument("--certificate", required=True, type=Path)
    authorize_parser.add_argument("--fingerprint", required=True, type=Path)
    authorize_parser.add_argument("--server-preflight", required=True, type=Path)
    authorize_parser.add_argument("--firewall-attestation", required=True, type=Path)
    authorize_parser.add_argument("--output", required=True, type=Path)
    authorize_parser.add_argument("--confirm-authorize", required=True, action="store_true")
    serve_parser.add_argument("--bind", required=True)
    serve_parser.add_argument("--port", required=True, type=int)
    serve_parser.add_argument("--certificate", required=True, type=Path)
    serve_parser.add_argument("--private-key", required=True, type=Path)
    serve_parser.add_argument("--fingerprint", required=True, type=Path)
    serve_parser.add_argument("--authorization", required=True, type=Path)
    serve_parser.add_argument("--server-preflight", required=True, type=Path)
    serve_parser.add_argument("--firewall-attestation", required=True, type=Path)
    enqueue_parser.add_argument("--server-ip", required=True)
    enqueue_parser.add_argument("--certificate", required=True, type=Path)
    enqueue_parser.add_argument("--action", required=True)
    rollback_parser.add_argument("--server-ip", required=True)
    rollback_parser.add_argument("--attestation", required=True, type=Path)
    arguments = parser.parse_args()
    if not arguments.run_id.startswith("lan-") or len(arguments.run_id) > 36:
        fail("invalid run id")
    if len(arguments.source_commit) != 40 or any(character not in "0123456789abcdef" for character in arguments.source_commit):
        fail("invalid source commit")
    client_ip = exact_private_ipv4(arguments.client_ip, "client IP")
    if arguments.command == "authorize":
        server_ip = exact_private_ipv4(arguments.server_ip, "server IP")
        create_start_authorization(arguments, server_ip, client_ip)
        print('{"status":"authorized"}')
        return
    if arguments.command == "init":
        initialize(arguments.state_root.resolve(), arguments.run_id, arguments.source_commit, client_ip)
        return
    if arguments.command == "enqueue":
        server_ip = exact_private_ipv4(arguments.server_ip, "server IP")
        enqueue(server_ip, arguments.certificate, arguments.state_root.resolve(), arguments.run_id, arguments.source_commit, arguments.action)
        return
    if arguments.command == "verify-rollback":
        server_ip = exact_private_ipv4(arguments.server_ip, "server IP")
        verify_rollback_evidence(arguments.attestation, arguments.run_id, arguments.source_commit, server_ip, client_ip)
        print('{"status":"verified"}')
        return
    server_ip = exact_private_ipv4(arguments.bind, "server IP")
    if arguments.port != PORT or ipaddress.ip_network(f"{server_ip}/24", strict=False) != ipaddress.ip_network(f"{client_ip}/24", strict=False):
        fail("server/client binding differs from the exact LAN policy")
    if arguments.state_root.is_symlink() or arguments.state_root.stat().st_mode & 0o777 != 0o700:
        fail("channel state root permissions must be 0700")
    read_regular(arguments.certificate, 32768)
    read_regular(arguments.private_key, 32768, 0o600)
    verify_start_evidence(arguments, server_ip, client_ip)
    state = ChannelState(arguments.state_root, arguments.run_id, arguments.source_commit, server_ip, client_ip)
    server = BoundedThreadingHTTPServer((server_ip, PORT), make_handler(state))
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(arguments.certificate, arguments.private_key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever(poll_interval=0.25)


if __name__ == "__main__":
    main()
