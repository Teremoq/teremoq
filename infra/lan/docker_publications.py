#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
"""Fail-closed Docker publication inventory for the LAN laboratory."""

from __future__ import annotations

import ipaddress
import re
import sys

CONFLICTS = {
    ("4433", "tcp"),
    ("5678", "tcp"),
    ("6379", "tcp"),
    ("11434", "tcp"),
    ("4433", "udp"),
    ("9000", "udp"),
    ("14433", "udp"),
    ("19000", "udp"),
}
SERVICE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
INTERNAL_RE = re.compile(r"^(?P<container>\d{1,5})/(?P<protocol>tcp|udp)$")
PUBLISHED_RE = re.compile(
    r"^(?P<host>localhost|\d{1,3}(?:\.\d{1,3}){3}|\[[0-9A-Fa-f:.]+\]|::|\*)"
    r":(?P<host_port>\d{1,5})->(?P<container>\d{1,5})/(?P<protocol>tcp|udp)$"
)


def fail(message: str) -> "NoReturn":
    raise ValueError(message)


def read_snapshot() -> str:
    data = sys.stdin.buffer.read(65537)
    if len(data) > 65536:
        fail("Docker publication snapshot exceeds 65536 bytes")
    try:
        return data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise ValueError("Docker publication snapshot is not valid UTF-8") from error


def parse_port(text: str, label: str) -> int:
    if not text.isdigit():
        fail(f"Docker publication {label} is not numeric")
    value = int(text, 10)
    if value < 1 or value > 65535:
        fail(f"Docker publication {label} is outside 1..65535")
    return value


def validate_host_literal(text: str) -> None:
    if text in {"localhost", "*", "::"}:
        return
    if text.startswith("[") and text.endswith("]"):
        candidate = text[1:-1]
    else:
        candidate = text
    try:
        parsed = ipaddress.ip_address(candidate)
    except ValueError as error:
        raise ValueError("Docker publication host literal is invalid") from error
    if parsed.version == 4 and parsed.exploded != candidate:
        fail("Docker publication IPv4 host must be canonical")


def parse_rows(text: str) -> list[str]:
    conflicts: list[str] = []
    seen: set[str] = set()
    lines = text.splitlines()
    if len(lines) > 128:
        fail("Docker publication row count exceeds 128")
    for line_number, row in enumerate(lines, 1):
        if not row:
            continue
        if len(row.encode("utf-8")) > 4096:
            fail(f"Docker publication row {line_number} exceeds 4096 bytes")
        fields = row.split("\t")
        if len(fields) != 2:
            fail(f"Docker publication row {line_number} must contain one TAB")
        service, ports_field = fields
        if not SERVICE_RE.fullmatch(service):
            fail(f"Docker publication service name is invalid on row {line_number}")
        if len(ports_field.encode("utf-8")) > 3072:
            fail(f"Docker publication port field exceeds 3072 bytes on row {line_number}")
        if not ports_field:
            continue
        tokens = [token.strip() for token in ports_field.split(",")]
        if len(tokens) > 256:
            fail(f"Docker publication token count exceeds 256 on row {line_number}")
        for token in tokens:
            if not token:
                fail(f"Docker publication token is empty on row {line_number}")
            internal = INTERNAL_RE.fullmatch(token)
            if internal is not None:
                parse_port(internal.group("container"), "container port")
                continue
            published = PUBLISHED_RE.fullmatch(token)
            if published is None:
                fail(f"Docker publication token is malformed on row {line_number}")
            validate_host_literal(published.group("host"))
            host_port = str(parse_port(published.group("host_port"), "host port"))
            parse_port(published.group("container"), "container port")
            conflict = f"{host_port}/{published.group('protocol')}"
            if (host_port, published.group("protocol")) not in CONFLICTS:
                continue
            record = f"service={service};port={conflict}"
            if record not in seen:
                conflicts.append(record)
                seen.add(record)
    return conflicts


def main() -> int:
    for record in parse_rows(read_snapshot()):
        print(record)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as error:
        print(f"teremoq LAN Docker publication inventory rejected: {error}", file=sys.stderr)
        raise SystemExit(2)
