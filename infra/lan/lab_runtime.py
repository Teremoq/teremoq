#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
"""Run-owned, fail-closed lifecycle for the opt-in LAN laboratory."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import socket
import stat
import subprocess
import sys
import time
import urllib.request

from udp_proxy import exact_private_ipv4, read_regular_limited
from publish_capability import CAPABILITY_NAME, RUST_LAN_CAPABILITY_INTEGRATED_COMMIT, verify_publish_capability

COMPONENTS = ("relay", "gateway", "source")
PUBLISH_CAPABILITY_ENV = "TEREMOQ_DEV_RELAY_PUBLISH_CAPABILITY_FILE"
AUTH_KEYS = {
    "schema_version", "run_id", "source_commit", "server_preflight_sha256",
    "client_preflight_sha256", "wsl_preflight_sha256", "firewall_attestation_sha256",
    "proxy_attestation_sha256", "owner_integrations_ready", "operator_authorized",
    "owner_integration_commit", "commands_sha256",
    "publish_capability_metadata_sha256",
}
CHECK_KEYS = {"check", "status", "value", "evidence_quality"}
WINDOWS_PREFLIGHT_KEYS = {
    "schema_version", "report_kind", "run_id", "source_commit", "role", "server_ipv4",
    "client_ipv4", "prefix_length", "network_profile", "expected_wsl_mode",
    "maximum_clock_offset_ms", "minimum_mtu", "minimum_cpu_cores", "minimum_memory_mib",
    "minimum_disk_mib", "capture_context", "checks",
}
CAPTURE_CONTEXT_KEYS = {
    "schema_version", "current_process_name", "parent_process_names", "wsl_environment_keys_present",
    "parent_process_count", "traversal_depth_limit", "traversal_outcome",
    "powershell_edition", "powershell_version_major",
}
FIREWALL_ATTESTATION_KEYS = {
    "schema_version", "run_id", "source_commit", "server_ipv4", "client_ipv4",
    "network_profile", "protocol", "local_port", "classic_rule_name", "hyperv_rule_name",
    "classic_rule_count", "hyperv_rule_count", "edge_traversal_policy", "firewall_verified",
    "default_inbound_action_changed",
}
PROXY_ATTESTATION_KEYS = {
    "schema_version", "run_id", "source_commit", "server_ipv4", "client_ipv4",
    "network_mode", "network_profile", "windows_firewall_rule_name", "hyperv_firewall_rule_name",
    "firewall_verified", "relay_san_integration_commit", "certificate_fingerprint_sha256",
}
LEGACY_UDP_PORTS = (4433, 9000)
LEGACY_TCP_PORTS = (4433, 5678, 6379, 11434)
PROCESS_BASENAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,123}\.exe$")


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
    if values["owner_integration_commit"] != RUST_LAN_CAPABILITY_INTEGRATED_COMMIT:
        fail("authorization requires the exact reviewed Rust LAN capability commit")
    for key in ("commands_sha256", "publish_capability_metadata_sha256", "wsl_preflight_sha256", "server_preflight_sha256", "client_preflight_sha256", "firewall_attestation_sha256", "proxy_attestation_sha256"):
        if len(values[key]) != 64 or any(c not in "0123456789abcdef" for c in values[key]):
            fail(f"invalid authorization digest: {key}")
    for key in ("owner_integrations_ready", "operator_authorized"):
        if values[key] != "true":
            fail(f"{key} must be explicitly true")
    return values


def read_bound_bytes(path: Path, maximum: int, expected_sha256: str, label: str) -> bytes:
    """Read, hash and snapshot one evidence file through one stable descriptor."""
    if not path.is_absolute():
        fail(f"{label} path must be absolute")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ValueError(f"{label} must be a readable non-symlink regular file") from error
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_size <= 0 or before.st_size > maximum:
            fail(f"{label} size or type is outside policy")
        chunks: list[bytes] = []
        total = 0
        digest = hashlib.sha256()
        while True:
            chunk = os.read(descriptor, min(65536, maximum + 1 - total))
            if not chunk:
                break
            total += len(chunk)
            if total > maximum:
                fail(f"{label} exceeds its byte limit")
            chunks.append(chunk)
            digest.update(chunk)
        after = os.fstat(descriptor)
        stable_fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
        if any(getattr(before, field) != getattr(after, field) for field in stable_fields) or total != before.st_size:
            fail(f"{label} changed during its single-descriptor read")
        if digest.hexdigest() != expected_sha256:
            fail(f"authorization evidence digest mismatch: {label}")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def decode_json_object(payload: bytes, label: str) -> dict[str, object]:
    try:
        text = payload.decode("utf-8-sig", errors="strict")
    except UnicodeDecodeError as error:
        raise ValueError(f"{label} encoding is invalid") from error

    def reject_duplicates(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                fail(f"{label} contains a duplicate JSON property: {key}")
            result[key] = value
        return result

    try:
        document = json.loads(text, object_pairs_hook=reject_duplicates)
    except json.JSONDecodeError as error:
        raise ValueError(f"{label} is not valid JSON") from error
    if not isinstance(document, dict):
        fail(f"{label} must be one JSON object")
    return document


def forbidden_evidence_token(value: str) -> bool:
    return re.search(r"(?:^|[^a-z])(blocked|pending|unavailable|unknown|not_measured)(?:$|[^a-z])", value, re.IGNORECASE) is not None


def validate_checks(document: dict[str, object], expected_names: set[str], label: str) -> dict[str, dict[str, str]]:
    checks = document.get("checks")
    if not isinstance(checks, list) or not 1 <= len(checks) <= 64:
        fail(f"{label} check cardinality is outside policy")
    parsed: dict[str, dict[str, str]] = {}
    for index, record in enumerate(checks, 1):
        if not isinstance(record, dict) or set(record) != CHECK_KEYS:
            fail(f"{label} check {index} schema is not closed")
        if not all(isinstance(record[key], str) and 0 < len(record[key]) <= 1024 for key in CHECK_KEYS):
            fail(f"{label} check {index} has an invalid field")
        name = record["check"]
        if name == "inherited_docker_publication":
            fail(f"{label} reports an inherited Docker listener conflict")
        if name in parsed:
            fail(f"{label} contains a duplicate check: {name}")
        parsed[name] = record  # type: ignore[assignment]
        if record["status"] not in {"pass", "observed"} or record["evidence_quality"] not in {"real", "configured"} or \
           forbidden_evidence_token(record["value"]):
            fail(f"{label} check is not activation-ready: {name}")
    if set(parsed) != expected_names:
        fail(f"{label} check-name schema is incomplete or unknown")
    if parsed["preflight_gate"]["status"] != "pass" or parsed["preflight_gate"]["value"] != "ready":
        fail(f"{label} preflight gate is not pass/ready")
    return parsed


SERVER_WINDOWS_CHECKS = {
    "windows_caption", "windows_version", "configured_private_ip_present", "network_profile",
    "capture_origin", "wifi_adapter", "wifi_link_speed", "wifi_radio", "wifi_band", "wsl_mode", "expected_wsl_mode_gate",
    "clock_offset", "mtu", "logical_cpu", "physical_memory_mib", "free_disk_mib",
    "browser_msedge.exe", "browser_chrome.exe", "docker_server", "docker_publication_inventory",
    "wslconfig_present", "preflight_gate",
    *(f"listener_udp_{port}" for port in (*LEGACY_UDP_PORTS, 14433, 19000)),
    *(f"listener_tcp_{port}" for port in LEGACY_TCP_PORTS),
}
CLIENT_WINDOWS_CHECKS = {
    "windows_caption", "windows_version", "capture_origin", "client_private_ip_present", "network_profile", "mtu",
    "wifi_radio", "wifi_5ghz", "wsl_ipv4_mode", "browser_edge", "browser_chrome", "browser_gate",
    "node_runtime_22_x", "player_loopback_tcp_3000", "clock_offset", "logical_cpu",
    "physical_memory_mib", "free_disk_mib", "icmp_echo_loss_percent_approximation",
    "icmp_echo_rtt_average_ms_approximation", "inbound_client_firewall", "preflight_gate",
}
WSL_PREFLIGHT_CHECKS = {
    "schema_version", "report_kind", "run_id", "source_commit", "role", "server_ipv4", "client_ipv4",
    "prefix_length", "network_profile", "expected_wsl_mode", "maximum_clock_offset_ms",
    "minimum_mtu", "minimum_cpu_cores", "minimum_memory_mib", "minimum_disk_mib",
    "wsl_kernel", "windows_wsl_mode_observed", "clock_synchronized", "route_to_peer",
    "route_interface", "mtu", "cpu_cores", "available_memory_mib", "available_disk_mib",
    "tool_openssl", "tool_curl", "tool_sha256sum", "tool_tar", "docker_server",
    "docker_publication_inventory", "preflight_gate", *(f"listener_udp_{port}" for port in (*LEGACY_UDP_PORTS, 14433, 19000)),
    *(f"listener_tcp_{port}" for port in LEGACY_TCP_PORTS),
}


def parse_exact_int(value: object, label: str, minimum: int, maximum: int) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum or value > maximum:
        fail(f"{label} is outside policy")
    return value


def parse_decimal_string(value: str, label: str) -> float:
    if not re.fullmatch(r"-?\d+(?:\.\d{1,3})?", value):
        fail(f"{label} is not a bounded decimal")
    parsed = float(value)
    if not math.isfinite(parsed):
        fail(f"{label} is not finite")
    return parsed


def parse_check_int_value(value: str, label: str, minimum: int, maximum: int) -> int:
    if not re.fullmatch(r"\d+", value):
        fail(f"{label} is not a bounded integer")
    return parse_exact_int(int(value), label, minimum, maximum)


def validate_capture_context(context: object, label: str) -> None:
    if not isinstance(context, dict) or set(context) != CAPTURE_CONTEXT_KEYS:
        fail(f"{label} capture context schema is not closed")
    if not isinstance(context["schema_version"], int) or isinstance(context["schema_version"], bool) or context["schema_version"] != 2:
        fail(f"{label} capture context schema version is unsupported")
    current_process_name = context["current_process_name"]
    parent_process_names = context["parent_process_names"]
    parent_process_count = context["parent_process_count"]
    traversal_depth_limit = context["traversal_depth_limit"]
    traversal_outcome = context["traversal_outcome"]
    wsl_environment_keys_present = context["wsl_environment_keys_present"]
    powershell_edition = context["powershell_edition"]
    powershell_version_major = context["powershell_version_major"]
    if not isinstance(current_process_name, str) or current_process_name not in {"powershell.exe", "pwsh.exe"} or \
       current_process_name.strip() != current_process_name or PROCESS_BASENAME_RE.fullmatch(current_process_name) is None or \
       powershell_edition not in {"Desktop", "Core"}:
        fail(f"{label} capture context does not describe native Windows PowerShell")
    if not isinstance(powershell_version_major, int) or isinstance(powershell_version_major, bool) or not 5 <= powershell_version_major <= 9:
        fail(f"{label} PowerShell major version is outside policy")
    if not isinstance(parent_process_names, list) or not 1 <= len(parent_process_names) <= 16:
        fail(f"{label} parent process chain is outside policy")
    if not isinstance(parent_process_count, int) or isinstance(parent_process_count, bool) or parent_process_count != len(parent_process_names):
        fail(f"{label} parent process chain cardinality is inconsistent")
    if not isinstance(traversal_depth_limit, int) or isinstance(traversal_depth_limit, bool) or traversal_depth_limit != 16:
        fail(f"{label} capture context depth limit is not exact")
    if not isinstance(traversal_outcome, str) or traversal_outcome not in {
        "terminated_parent_pid_nonpositive",
        "terminated_after_explorer_root_missing",
    }:
        fail(f"{label} capture context does not prove parent-chain termination")
    if not isinstance(wsl_environment_keys_present, list) or len(wsl_environment_keys_present) > 3:
        fail(f"{label} WSL environment evidence is outside policy")
    blocked_ancestors = {"bash.exe", "sh.exe", "dash.exe", "wsl.exe", "wslhost.exe", "ubuntu.exe", "debian.exe", "kali.exe", "arch.exe"}
    allowed_env_keys = {"WSLENV", "WSL_INTEROP", "WSL_DISTRO_NAME"}
    normalized_parents: list[str] = []
    for entry in parent_process_names:
        if not isinstance(entry, str) or not entry or len(entry) > 128 or entry.strip() != entry or \
           PROCESS_BASENAME_RE.fullmatch(entry) is None:
            fail(f"{label} parent process entry is invalid")
        if entry in normalized_parents:
            fail(f"{label} parent process chain contains duplicates")
        normalized_parents.append(entry)
    for entry in wsl_environment_keys_present:
        if not isinstance(entry, str) or entry not in allowed_env_keys:
            fail(f"{label} WSL environment key evidence is invalid")
    if len(set(wsl_environment_keys_present)) != len(wsl_environment_keys_present):
        fail(f"{label} WSL environment key evidence contains duplicates")
    if traversal_outcome == "terminated_after_explorer_root_missing":
        if current_process_name != "powershell.exe" or normalized_parents != ["explorer.exe"] or wsl_environment_keys_present:
            fail(f"{label} capture context does not prove the trusted explorer root termination")
    if any(entry in blocked_ancestors for entry in normalized_parents) or wsl_environment_keys_present:
        fail(f"{label} capture path is not native Windows PowerShell")


def validate_listener_checks(checks: dict[str, dict[str, str]], label: str, udp_ports: tuple[int, ...], tcp_ports: tuple[int, ...]) -> None:
    for protocol, ports in (("udp", udp_ports), ("tcp", tcp_ports)):
        for port in ports:
            record = checks[f"listener_{protocol}_{port}"]
            if record["status"] != "pass" or record["value"] not in {"free", "absent"} or record["evidence_quality"] != "real":
                fail(f"{label} listener conflict remains on {protocol.upper()}/{port}")


def parse_windows_preflight(payload: bytes, role: str, run_id: str, source_commit: str, server_ip: str,
                            client_ip: str, prefix_length: int, network_profile: str,
                            maximum_clock_offset_ms: int, minimum_mtu: int, minimum_cpu_cores: int,
                            minimum_memory_mib: int, minimum_disk_mib: int) -> dict[str, dict[str, str]]:
    label = f"Windows {role} preflight"
    document = decode_json_object(payload, label)
    if set(document) != WINDOWS_PREFLIGHT_KEYS:
        fail(f"{label} top-level schema is not closed")
    expected_mode = "mirrored" if role == "server" else "nat"
    expected = {
        "schema_version": 2, "report_kind": "teremoq-lan-windows-preflight-v2", "run_id": run_id,
        "source_commit": source_commit, "role": role, "server_ipv4": server_ip, "client_ipv4": client_ip,
        "prefix_length": prefix_length, "network_profile": network_profile, "expected_wsl_mode": expected_mode,
    }
    if any(document.get(key) != value for key, value in expected.items()):
        fail(f"{label} run/IP/profile/WSL/commit binding mismatch")
    validate_capture_context(document["capture_context"], label)
    checks = validate_checks(document, SERVER_WINDOWS_CHECKS if role == "server" else CLIENT_WINDOWS_CHECKS, label)
    if checks["capture_origin"] != {
        "check": "capture_origin",
        "status": "pass",
        "value": "native_windows_powershell",
        "evidence_quality": "real",
    }:
        fail(f"{label} capture origin check is not exact")
    if checks["network_profile"] != {"check": "network_profile", "status": "pass", "value": network_profile, "evidence_quality": "real"}:
        fail(f"{label} current network profile mismatch")
    mode_key = "expected_wsl_mode_gate" if role == "server" else "wsl_ipv4_mode"
    if checks[mode_key]["status"] != "pass" or checks[mode_key]["value"] != expected_mode:
        fail(f"{label} WSL mode mismatch")
    if abs(parse_decimal_string(checks["clock_offset"]["value"], f"{label} clock offset")) > maximum_clock_offset_ms:
        fail(f"{label} clock offset exceeds policy")
    if parse_exact_int(document["minimum_mtu"], f"{label} minimum MTU binding", 576, 9000) != minimum_mtu or \
       parse_exact_int(document["minimum_cpu_cores"], f"{label} minimum CPU binding", 1, 1024) != minimum_cpu_cores or \
       parse_exact_int(document["minimum_memory_mib"], f"{label} minimum memory binding", 1, 1073741824) != minimum_memory_mib or \
       parse_exact_int(document["minimum_disk_mib"], f"{label} minimum disk binding", 1, 1073741824) != minimum_disk_mib or \
       parse_exact_int(document["maximum_clock_offset_ms"], f"{label} maximum clock binding", 1, 60000) != maximum_clock_offset_ms:
        fail(f"{label} threshold binding mismatch")
    if parse_check_int_value(checks["mtu"]["value"], f"{label} MTU", 576, 9000) < minimum_mtu or \
       parse_check_int_value(checks["logical_cpu"]["value"], f"{label} logical CPU", 1, 1024) < minimum_cpu_cores or \
       parse_check_int_value(checks["physical_memory_mib"]["value"], f"{label} physical memory", 1, 1073741824) < minimum_memory_mib or \
       parse_check_int_value(checks["free_disk_mib"]["value"], f"{label} free disk", 1, 1073741824) < minimum_disk_mib:
        fail(f"{label} measured capacity is below policy")
    if role == "server":
        if checks["wifi_adapter"]["status"] != "pass" or checks["wifi_band"] != {
            "check": "wifi_band", "status": "pass", "value": "5 GHz", "evidence_quality": "real"
        }:
            fail("Windows server preflight did not prove the exact Wi-Fi interface and 5 GHz band")
        if checks["docker_publication_inventory"] != {
            "check": "docker_publication_inventory",
            "status": "pass",
            "value": "bounded-scan",
            "evidence_quality": "real",
        }:
            fail("Windows server Docker publication inventory is not exact")
        validate_listener_checks(checks, label, (*LEGACY_UDP_PORTS, 14433, 19000), LEGACY_TCP_PORTS)
    else:
        if checks["wifi_5ghz"] != {"check": "wifi_5ghz", "status": "pass", "value": "5 GHz", "evidence_quality": "real"}:
            fail("Windows client preflight did not prove the exact 5 GHz Wi-Fi band")
        if checks["player_loopback_tcp_3000"]["status"] != "pass" or checks["player_loopback_tcp_3000"]["value"] != "free":
            fail("Windows client preflight reports loopback TCP/3000 occupied")
    return checks


def parse_wsl_preflight(payload: bytes, run_id: str, source_commit: str, server_ip: str, client_ip: str,
                        prefix_length: int, network_profile: str, maximum_clock_offset_ms: int,
                        minimum_mtu: int, minimum_cpu_cores: int, minimum_memory_mib: int,
                        minimum_disk_mib: int) -> dict[str, dict[str, str]]:
    label = "WSL server preflight"
    try:
        text = payload.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise ValueError(f"{label} encoding is invalid") from error
    lines = text.splitlines()
    if not lines or lines[0] != "check\tstatus\tvalue\tevidence_quality" or len(lines) > 65:
        fail(f"{label} header/cardinality is outside policy")
    records: list[dict[str, str]] = []
    for number, line in enumerate(lines[1:], 2):
        fields = line.split("\t")
        if len(fields) != 4 or not all(fields):
            fail(f"{label} line {number} must contain four fields")
        records.append(dict(zip(("check", "status", "value", "evidence_quality"), fields)))
    checks = validate_checks({"checks": records}, WSL_PREFLIGHT_CHECKS, label)
    bindings = {
        "schema_version": "2", "report_kind": "teremoq-lan-wsl-preflight-v2", "run_id": run_id,
        "source_commit": source_commit, "role": "server", "server_ipv4": server_ip, "client_ipv4": client_ip,
        "prefix_length": str(prefix_length), "network_profile": network_profile, "expected_wsl_mode": "mirrored",
        "maximum_clock_offset_ms": str(maximum_clock_offset_ms), "minimum_mtu": str(minimum_mtu),
        "minimum_cpu_cores": str(minimum_cpu_cores), "minimum_memory_mib": str(minimum_memory_mib),
        "minimum_disk_mib": str(minimum_disk_mib),
    }
    for name, value in bindings.items():
        if checks[name] != {"check": name, "status": "pass", "value": value, "evidence_quality": "configured"}:
            fail(f"{label} binding mismatch: {name}")
    if checks["windows_wsl_mode_observed"] != {"check": "windows_wsl_mode_observed", "status": "pass", "value": "mirrored", "evidence_quality": "real"}:
        fail("WSL server NAT/unavailable mode is forbidden")
    if checks["docker_publication_inventory"] != {
        "check": "docker_publication_inventory",
        "status": "pass",
        "value": "bounded-scan",
        "evidence_quality": "real",
    }:
        fail("WSL Docker publication inventory is not exact")
    if parse_check_int_value(checks["mtu"]["value"], f"{label} MTU", 576, 9000) < minimum_mtu or \
       parse_check_int_value(checks["cpu_cores"]["value"], f"{label} CPU cores", 1, 1024) < minimum_cpu_cores or \
       parse_check_int_value(checks["available_memory_mib"]["value"], f"{label} memory", 1, 1073741824) < minimum_memory_mib or \
       parse_check_int_value(checks["available_disk_mib"]["value"], f"{label} disk", 1, 1073741824) < minimum_disk_mib:
        fail(f"{label} measured capacity is below policy")
    validate_listener_checks(checks, label, (*LEGACY_UDP_PORTS, 14433, 19000), LEGACY_TCP_PORTS)
    return checks


def parse_firewall_attestation(payload: bytes, run_id: str, source_commit: str, server_ip: str,
                               client_ip: str, network_profile: str) -> dict[str, object]:
    label = "firewall verification"
    document = decode_json_object(payload, label)
    if set(document) != FIREWALL_ATTESTATION_KEYS:
        fail("firewall verification schema is not closed")
    classic = f"Teremoq-LAN-{run_id}-Defender-QUIC-UDP-14433"
    hyperv = f"Teremoq-LAN-{run_id}-HyperV-QUIC-UDP-14433"
    expected = {
        "schema_version": 1, "run_id": run_id, "source_commit": source_commit, "server_ipv4": server_ip,
        "client_ipv4": client_ip, "network_profile": network_profile, "protocol": "UDP", "local_port": 14433,
        "classic_rule_name": classic, "hyperv_rule_name": hyperv, "classic_rule_count": 1,
        "hyperv_rule_count": 1, "edge_traversal_policy": "Block", "firewall_verified": True,
        "default_inbound_action_changed": False,
    }
    if document != expected:
        fail("firewall verification run/rule/property binding mismatch")
    return document


def parse_closed_tsv(payload: bytes, allowed: set[str], label: str) -> dict[str, str]:
    try:
        text = payload.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise ValueError(f"{label} encoding is invalid") from error
    values: dict[str, str] = {}
    lines = text.splitlines()
    if len(lines) > len(allowed) + 16:
        fail(f"{label} cardinality is outside policy")
    for number, raw in enumerate(lines, 1):
        if not raw or raw.startswith("#"):
            continue
        fields = raw.split("\t")
        if len(fields) != 2 or not all(fields):
            fail(f"invalid {label} line {number}")
        key, value = fields
        if key not in allowed or key in values:
            fail(f"unknown or duplicate {label} key: {key}")
        values[key] = value
    if set(values) != allowed:
        fail(f"{label} schema is incomplete")
    return values


def parse_proxy_attestation(payload: bytes, run_id: str, source_commit: str, owner_commit: str,
                            server_ip: str, client_ip: str, network_profile: str) -> dict[str, str]:
    values = parse_closed_tsv(payload, PROXY_ATTESTATION_KEYS, "proxy attestation")
    classic = f"Teremoq-LAN-{run_id}-Defender-QUIC-UDP-14433"
    hyperv = f"Teremoq-LAN-{run_id}-HyperV-QUIC-UDP-14433"
    expected = {
        "schema_version": "1", "run_id": run_id, "source_commit": source_commit, "server_ipv4": server_ip,
        "client_ipv4": client_ip, "network_mode": "mirrored", "network_profile": network_profile,
        "windows_firewall_rule_name": classic, "hyperv_firewall_rule_name": hyperv,
        "firewall_verified": "true", "relay_san_integration_commit": owner_commit,
    }
    if any(values.get(key) != value for key, value in expected.items()) or \
       not re.fullmatch(r"[0-9a-f]{64}", values["certificate_fingerprint_sha256"]):
        fail("proxy attestation run/IP/profile/firewall/owner binding mismatch")
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


def environment_for_component(base: dict[str, str], name: str, capability_path: Path) -> dict[str, str]:
    if name not in COMPONENTS:
        fail("unknown LAN component environment")
    environment = base.copy()
    environment.pop(PUBLISH_CAPABILITY_ENV, None)
    if name in {"relay", "gateway"}:
        environment[PUBLISH_CAPABILITY_ENV] = str(capability_path)
    return environment


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
    if owner_commit != RUST_LAN_CAPABILITY_INTEGRATED_COMMIT:
        fail("repository verification requires the exact integrated Rust LAN capability commit")
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
    for name in ("commands", "authorization", "wsl-preflight", "server-preflight", "client-preflight", "firewall-attestation", "certificate", "key", "fingerprint", "identity-profile", "proxy-attestation", "repo-root", "artifact-root", "state-dir"):
        parser.add_argument(f"--{name}", required=True, type=Path)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--owner-commit", required=True)
    parser.add_argument("--server-ip", required=True)
    parser.add_argument("--client-ip", required=True)
    parser.add_argument("--network-profile", required=True, choices=("Public", "Private"))
    parser.add_argument("--moq-namespace", required=True)
    parser.add_argument("--prefix-length", required=True, type=int)
    parser.add_argument("--maximum-clock-offset-ms", required=True, type=int)
    parser.add_argument("--minimum-mtu", required=True, type=int)
    parser.add_argument("--server-minimum-cpu-cores", required=True, type=int)
    parser.add_argument("--server-minimum-memory-mib", required=True, type=int)
    parser.add_argument("--server-minimum-disk-mib", required=True, type=int)
    parser.add_argument("--client-minimum-cpu-cores", required=True, type=int)
    parser.add_argument("--client-minimum-memory-mib", required=True, type=int)
    parser.add_argument("--client-minimum-disk-mib", required=True, type=int)
    parser.add_argument("--max-clients", required=True, type=int)
    parser.add_argument("--association-margin", required=True, type=int)
    parser.add_argument("--idle-timeout", required=True, type=int)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    server_ip = exact_private_ipv4(args.server_ip, "server_ip")
    client_ip = exact_private_ipv4(args.client_ip, "client_ip")
    if args.prefix_length < 8 or args.prefix_length > 30:
        fail("prefix length is outside policy")
    authorization = parse_authorization(args.authorization)
    if authorization["run_id"] != args.run_id or authorization["source_commit"] != args.source_commit or \
       authorization["owner_integration_commit"] != args.owner_commit:
        fail("authorization run binding mismatch")
    verify_repository(args.repo_root, args.source_commit, args.owner_commit)
    verify_artifact_root(args.artifact_root, args.run_id, args.source_commit)
    evidence = {
        "wsl_preflight_sha256": (args.wsl_preflight, 32768, "WSL server preflight"),
        "server_preflight_sha256": (args.server_preflight, 65536, "Windows server preflight"),
        "client_preflight_sha256": (args.client_preflight, 65536, "Windows client preflight"),
        "firewall_attestation_sha256": (args.firewall_attestation, 8192, "firewall verification"),
        "proxy_attestation_sha256": (args.proxy_attestation, 8192, "proxy attestation"),
    }
    evidence_payloads = {
        key: read_bound_bytes(path, maximum, authorization[key], label)
        for key, (path, maximum, label) in evidence.items()
    }
    parse_proxy_attestation(evidence_payloads["proxy_attestation_sha256"], args.run_id, args.source_commit,
                            args.owner_commit, server_ip, client_ip, args.network_profile)
    parse_wsl_preflight(evidence_payloads["wsl_preflight_sha256"], args.run_id, args.source_commit,
                        server_ip, client_ip, args.prefix_length, args.network_profile,
                        args.maximum_clock_offset_ms, args.minimum_mtu, args.server_minimum_cpu_cores,
                        args.server_minimum_memory_mib, args.server_minimum_disk_mib)
    parse_windows_preflight(evidence_payloads["server_preflight_sha256"], "server", args.run_id,
                            args.source_commit, server_ip, client_ip, args.prefix_length, args.network_profile,
                            args.maximum_clock_offset_ms, args.minimum_mtu, args.server_minimum_cpu_cores,
                            args.server_minimum_memory_mib, args.server_minimum_disk_mib)
    parse_windows_preflight(evidence_payloads["client_preflight_sha256"], "client", args.run_id,
                            args.source_commit, server_ip, client_ip, args.prefix_length, args.network_profile,
                            args.maximum_clock_offset_ms, args.minimum_mtu, args.client_minimum_cpu_cores,
                            args.client_minimum_memory_mib, args.client_minimum_disk_mib)
    parse_firewall_attestation(evidence_payloads["firewall_attestation_sha256"], args.run_id, args.source_commit,
                               server_ip, client_ip, args.network_profile)
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
    capability_path = args.state_dir / CAPABILITY_NAME
    verify_publish_capability(args.state_dir, args.run_id, args.source_commit, args.owner_commit,
                              authorization["publish_capability_metadata_sha256"])
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
    proxy_attestation_snapshot = args.state_dir / "proxy-attestation.snapshot.tsv"
    created_state: list[Path] = []
    proxy_launched = False
    try:
        with proxy_attestation_snapshot.open("xb") as stream:
            created_state.append(proxy_attestation_snapshot)
            stream.write(evidence_payloads["proxy_attestation_sha256"])
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(proxy_attestation_snapshot, 0o400)
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
            component_environment = environment_for_component(common, name, capability_path)
            if name in {"relay", "gateway"}:
                verify_publish_capability(args.state_dir, args.run_id, args.source_commit, args.owner_commit,
                                          authorization["publish_capability_metadata_sha256"])
            log = (args.state_dir / f"{name}.log").open("xb")
            logs.append(log)
            processes[name] = subprocess.Popen(command, cwd=cwd, env=component_environment, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
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
            "--fingerprint", str(args.fingerprint), "--attestation", str(proxy_attestation_snapshot),
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
                verify_publish_capability(args.state_dir, args.run_id, args.source_commit, args.owner_commit,
                                          authorization["publish_capability_metadata_sha256"])
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
