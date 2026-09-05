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
import secrets
import ssl
import tempfile
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
PORT = 18443
MAX_BODY = 32 * 1024
MAX_MESSAGE = 16 * 1024
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
SENSITIVE_MARKERS = (
    "-----begin private key-----",
    "authorization: bearer",
    "github_token",
    "gh_token",
    "sudo_password",
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
    lowered = value.lower()
    if any(marker in lowered for marker in SENSITIVE_MARKERS):
        fail(f"{label} contains a blocked sensitive marker")
    return value


def exact_private_ipv4(value: str, label: str) -> str:
    try:
        address = ipaddress.ip_address(value)
    except ValueError as error:
        raise ValueError(f"{label} is not an IPv4 address") from error
    if address.version != 4 or not address.is_private or address.is_multicast or address.is_unspecified:
        fail(f"{label} must be one exact private unicast IPv4 address")
    return str(address)


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
        self.document = self._load()

    def _load(self) -> dict[str, Any]:
        document = json.loads(read_regular(self.state_path, 65536, 0o600).decode("utf-8"))
        exact_object(
            document,
            {"schema_version", "run_id", "source_commit", "client_ipv4", "paired", "session_sha256", "tasks"},
            "channel state",
        )
        if (
            document["schema_version"] != SCHEMA_VERSION
            or document["run_id"] != self.run_id
            or document["source_commit"] != self.source_commit
            or document["client_ipv4"] != self.client_ip
            or not isinstance(document["paired"], bool)
            or not isinstance(document["tasks"], list)
        ):
            fail("channel state identity differs from invocation")
        for index, task in enumerate(document["tasks"], 1):
            exact_object(task, {"sequence", "action", "completed", "last_event"}, "task")
            if task["sequence"] != index or task["action"] not in ACTIONS or not isinstance(task["completed"], bool):
                fail("invalid task state")
            if type(task["last_event"]) is not int or task["last_event"] < 0:
                fail("invalid task event counter")
        return document

    def _persist(self) -> None:
        atomic_json(self.state_path, self.document)

    def _rate_limit(self, actor: str) -> None:
        now = time.monotonic()
        if now - self.last_request[actor] < MIN_REQUEST_INTERVAL_SECONDS:
            fail("request rate exceeded")
        self.last_request[actor] = now

    def pair(self, request: dict[str, Any]) -> dict[str, Any]:
        exact_object(request, {"schema_version", "run_id", "source_commit", "pairing_code"}, "pair request")
        if request["schema_version"] != SCHEMA_VERSION or request["run_id"] != self.run_id or request["source_commit"] != self.source_commit:
            fail("pair request identity mismatch")
        candidate = bounded_text(request["pairing_code"], "pairing code", 128).encode("ascii")
        with self.lock:
            self._rate_limit("client")
            if self.document["paired"]:
                fail("pairing code was already consumed")
            expected = read_regular(self.pairing_path, 128, 0o600).strip()
            if not hmac.compare_digest(candidate, expected):
                fail("pairing rejected")
            session = secrets.token_hex(32)
            self.document["paired"] = True
            self.document["session_sha256"] = hashlib.sha256(session.encode("ascii")).hexdigest()
            self._persist()
            os.unlink(self.pairing_path)
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
        if request != {"schema_version": SCHEMA_VERSION, "run_id": self.run_id, "source_commit": self.source_commit}:
            fail("poll request identity mismatch")
        with self.lock:
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
        if request["schema_version"] != SCHEMA_VERSION or request["run_id"] != self.run_id or request["source_commit"] != self.source_commit:
            fail("event identity mismatch")
        if type(request["sequence"]) is not int or type(request["event"]) is not int or request["sequence"] < 1 or request["event"] < 1:
            fail("event counters are invalid")
        if request["action"] not in ACTIONS or request["status"] not in STATUSES:
            fail("event action or status is invalid")
        bounded_text(request["message"], "event message", MAX_MESSAGE)
        with self.lock:
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
            task["last_event"] = request["event"]
            line = (json.dumps(request, separators=(",", ":"), sort_keys=True) + "\n").encode("utf-8")
            descriptor = os.open(self.events_path, os.O_APPEND | os.O_CREAT | os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0), 0o600)
            try:
                metadata = os.fstat(descriptor)
                if metadata.st_mode & 0o777 != 0o600:
                    fail("event log permissions differ from 0600")
                os.write(descriptor, line)
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            self._persist()
            return {"schema_version": SCHEMA_VERSION, "sequence": request["sequence"], "event": request["event"], "accepted": True}

    def enqueue(self, request: dict[str, Any], management: str) -> dict[str, Any]:
        exact_object(request, {"schema_version", "run_id", "source_commit", "action"}, "management request")
        if request["schema_version"] != SCHEMA_VERSION or request["run_id"] != self.run_id or request["source_commit"] != self.source_commit:
            fail("management request identity mismatch")
        if request["action"] not in ACTIONS:
            fail("management action is outside the allowlist")
        candidate = management.encode("ascii")
        expected = read_regular(self.management_path, 128, 0o600).strip()
        if not hmac.compare_digest(candidate, expected):
            fail("management credential rejected")
        with self.lock:
            self._rate_limit("management")
            if any(not task["completed"] for task in self.document["tasks"]):
                fail("one task is already pending")
            sequence = len(self.document["tasks"]) + 1
            self.document["tasks"].append({"sequence": sequence, "action": request["action"], "completed": False, "last_event": 0})
            self._persist()
            return {"schema_version": SCHEMA_VERSION, "sequence": sequence, "action": request["action"], "accepted": True}


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
    try:
        value = json.loads(body.decode("utf-8", errors="strict"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError("invalid JSON body") from error
    if not isinstance(value, dict):
        fail("request body must be an object")
    return value


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
        "tasks": [],
    })
    print(pairing)


def enqueue(server_ip: str, certificate: Path, root: Path, run_id: str, source_commit: str, action: str) -> None:
    if action not in ACTIONS:
        fail("management action is outside the allowlist")
    management = read_regular(root / "management-token", 128, 0o600).decode("ascii").strip()
    body = json.dumps({"schema_version": SCHEMA_VERSION, "run_id": run_id, "source_commit": source_commit, "action": action}, separators=(",", ":")).encode("utf-8")
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
    for item in (initialize_parser, serve_parser, enqueue_parser):
        item.add_argument("--state-root", required=True, type=Path)
        item.add_argument("--run-id", required=True)
        item.add_argument("--source-commit", required=True)
        item.add_argument("--client-ip", required=True)
    serve_parser.add_argument("--bind", required=True)
    serve_parser.add_argument("--port", required=True, type=int)
    serve_parser.add_argument("--certificate", required=True, type=Path)
    serve_parser.add_argument("--private-key", required=True, type=Path)
    enqueue_parser.add_argument("--server-ip", required=True)
    enqueue_parser.add_argument("--certificate", required=True, type=Path)
    enqueue_parser.add_argument("--action", required=True)
    arguments = parser.parse_args()
    if not arguments.run_id.startswith("lan-") or len(arguments.run_id) > 36:
        fail("invalid run id")
    if len(arguments.source_commit) != 40 or any(character not in "0123456789abcdef" for character in arguments.source_commit):
        fail("invalid source commit")
    client_ip = exact_private_ipv4(arguments.client_ip, "client IP")
    if arguments.command == "init":
        initialize(arguments.state_root.resolve(), arguments.run_id, arguments.source_commit, client_ip)
        return
    if arguments.command == "enqueue":
        server_ip = exact_private_ipv4(arguments.server_ip, "server IP")
        enqueue(server_ip, arguments.certificate, arguments.state_root.resolve(), arguments.run_id, arguments.source_commit, arguments.action)
        return
    server_ip = exact_private_ipv4(arguments.bind, "server IP")
    if arguments.port != PORT or ipaddress.ip_network(f"{server_ip}/24", strict=False) != ipaddress.ip_network(f"{client_ip}/24", strict=False):
        fail("server/client binding differs from the exact LAN policy")
    if arguments.state_root.is_symlink() or arguments.state_root.stat().st_mode & 0o777 != 0o700:
        fail("channel state root permissions must be 0700")
    read_regular(arguments.certificate, 32768)
    read_regular(arguments.private_key, 32768, 0o600)
    state = ChannelState(arguments.state_root, arguments.run_id, arguments.source_commit, server_ip, client_ip)
    server = ThreadingHTTPServer((server_ip, PORT), make_handler(state))
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(arguments.certificate, arguments.private_key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever(poll_interval=0.25)


if __name__ == "__main__":
    main()
