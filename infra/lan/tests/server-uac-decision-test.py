#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
"""Offline synthetic contracts; no host attestation, listeners or firewall."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("runtime_fixture", Path(__file__).with_name("lab-runtime-test.py"))
FIXTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FIXTURE)
RUNTIME = FIXTURE.RUNTIME


def original():
    result = FIXTURE.windows_preflight("server")
    result["capture_context"] = FIXTURE.capture_context(parent_process_names=[], traversal_outcome="parent_process_missing")
    for record in result["checks"]:
        if record["check"] == "configured_private_ip_present":
            record.update(status="pass", value=FIXTURE.SERVER_IP, evidence_quality="real")
        if record["check"] in {"capture_origin", "preflight_gate"}:
            record.update(status="blocked", value="wsl_or_ambiguous_capture" if record["check"] == "capture_origin" else "blocked")
    return result


def envelope(report=None):
    report = original() if report is None else report
    raw = json.dumps(report, indent=2) + "\n"
    return {
        "schema_version": 1, "report_kind": "teremoq-server-uac-capture-decision-v1",
        "disposition": "warning:verified-elevated-host-parent-unobserved",
        "raw_preflight_utf8": raw, "raw_preflight_sha256": hashlib.sha256(raw.encode()).hexdigest(),
        "independent_evidence": {
            "collector": "preflight-lan-same-process-v1", "elevated": True, "architecture": "x64",
            "host_path": "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
            "host_sha256": "3247bcfd60f6dd25f34cb74b5889ab10ef1b3ec72b4d4b3d95b5b25b534560b8",
            "checkout_kind": "local-clean-git", "source_commit": report["source_commit"],
            "configuration_binding": "original-report-sha256",
        },
    }


def parse(document, role="server"):
    return RUNTIME.parse_windows_preflight(json.dumps(document).encode(), role, FIXTURE.RUN_ID,
        FIXTURE.SOURCE_COMMIT, FIXTURE.SERVER_IP, FIXTURE.CLIENT_IP, 24, FIXTURE.PROFILE,
        FIXTURE.MAX_CLOCK, FIXTURE.MIN_MTU, FIXTURE.SERVER_MIN_CPU, FIXTURE.SERVER_MIN_MEMORY, FIXTURE.SERVER_MIN_DISK)


class ServerUacDecisionTests(unittest.TestCase):
    def test_channel_uses_same_gate_and_keeps_firewall_authorization_without_binding(self):
        spec = importlib.util.spec_from_file_location("channel_gate_only", Path(__file__).parents[1] / "interactive_channel.py")
        channel = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(channel)
        report = original()
        report.update(maximum_clock_offset_ms=2000, minimum_disk_mib=2048)
        decision = envelope(report)
        firewall = {
            "schema_version": 1, "run_id": FIXTURE.RUN_ID, "source_commit": FIXTURE.SOURCE_COMMIT,
            "server_ipv4": FIXTURE.SERVER_IP, "client_ipv4": FIXTURE.CLIENT_IP, "network_profile": "Public",
            "protocol": "UDP", "local_port": 14433,
            "classic_rule_name": f"Teremoq-LAN-{FIXTURE.RUN_ID}-Defender-QUIC-UDP-14433",
            "hyperv_rule_name": f"Teremoq-LAN-{FIXTURE.RUN_ID}-HyperV-QUIC-UDP-14433",
            "classic_rule_count": 1, "hyperv_rule_count": 1, "edge_traversal_policy": "Block",
            "firewall_verified": True, "default_inbound_action_changed": False,
            "coordination_tls_port": 18443, "coordination_firewall_verified": True,
        }
        with tempfile.TemporaryDirectory() as directory, patch.object(channel.socket, "socket", side_effect=AssertionError("no sockets in gate tests")):
            root = Path(directory)
            arguments = SimpleNamespace(server_preflight=root / "decision.json", firewall_attestation=root / "firewall.json",
                certificate=root / "certificate.pem", fingerprint=root / "fingerprint", run_id=FIXTURE.RUN_ID,
                source_commit=FIXTURE.SOURCE_COMMIT)
            # Encoding-only synthetic bytes: no claim to validate a TLS certificate.
            arguments.certificate.write_text("-----BEGIN CERTIFICATE-----\nMA==\n-----END CERTIFICATE-----\n")
            arguments.fingerprint.write_text(hashlib.sha256(b"0").hexdigest())
            arguments.server_preflight.write_text(json.dumps(decision))
            arguments.firewall_attestation.write_text(json.dumps(firewall))
            result = channel.expected_start_authorization(arguments, FIXTURE.SERVER_IP, FIXTURE.CLIENT_IP)
            self.assertEqual(result["server_preflight_sha256"], hashlib.sha256(arguments.server_preflight.read_bytes()).hexdigest())
            firewall["classic_rule_count"] = 0
            arguments.firewall_attestation.write_text(json.dumps(firewall))
            with self.assertRaises(ValueError):
                channel.expected_start_authorization(arguments, FIXTURE.SERVER_IP, FIXTURE.CLIENT_IP)
            arguments.server_preflight.write_text(json.dumps(report))
            with self.assertRaises(ValueError):
                channel.expected_start_authorization(arguments, FIXTURE.SERVER_IP, FIXTURE.CLIENT_IP)

    def test_exact_case_warning_preserves_original_bytes_and_blocked_checks(self):
        document = envelope()
        before = copy.deepcopy(document)
        result = parse(document)
        self.assertEqual(result["capture_origin"]["status"], "blocked")
        self.assertEqual(result["preflight_gate"]["status"], "blocked")
        self.assertEqual(document, before)

    def test_original_missing_parent_is_still_rejected_without_independent_evidence(self):
        with self.assertRaises(ValueError):
            parse(original())
        with self.assertRaises(ValueError):
            RUNTIME.validate_capture_context(original()["capture_context"], "original")

    def test_context_is_exact_no_generic_missing_parent_or_wsl_exception(self):
        for key, value in (("parent_process_names", ["explorer.exe"]), ("parent_process_count", 1),
            ("wsl_environment_keys_present", ["WSL_INTEROP"]), ("powershell_edition", "Core"),
            ("current_process_name", "pwsh.exe"), ("traversal_outcome", "cim_query_failed"),
            ("parent_process_count", False), ("schema_version", 2.0)):
            with self.subTest(key=key, value=value):
                report = original()
                report["capture_context"][key] = value
                with self.assertRaises(ValueError):
                    parse(envelope(report))

    def test_independent_evidence_is_closed_and_pinned(self):
        for key, value in (("elevated", False), ("elevated", 1), ("architecture", "arm64"),
            ("host_path", "C:\\Temp\\powershell.exe"), ("host_sha256", "f" * 64),
            ("source_commit", "b" * 40), ("checkout_kind", "unc-git"), ("collector", "operator-asserted"),
            ("configuration_binding", "other"), ("extra", True)):
            with self.subTest(key=key, value=value):
                document = envelope()
                document["independent_evidence"][key] = value
                with self.assertRaises(ValueError):
                    parse(document)

    def test_tamper_duplicate_schema_and_byte_budgets(self):
        for key, value in (("raw_preflight_sha256", "0" * 64), ("raw_preflight_utf8", " " * 24577),
            ("disposition", "pass"), ("schema_version", True), ("extra", 1)):
            document = envelope()
            document[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                parse(document)
        document = envelope()
        document["raw_preflight_utf8"] = document["raw_preflight_utf8"].replace('"role": "server"', '"role": "server", "role": "server"')
        document["raw_preflight_sha256"] = hashlib.sha256(document["raw_preflight_utf8"].encode()).hexdigest()
        with self.assertRaises(ValueError):
            parse(document)
        with self.assertRaises(ValueError):
            RUNTIME.parse_windows_preflight(b" " * 65537, "server", "", "", "", "", 24, "Public", 1, 1, 1, 1, 1)

    def test_other_failures_binding_and_client_stay_rejected(self):
        for name in ("configured_private_ip_present", "network_profile", "wifi_adapter", "clock_offset",
                     "expected_wsl_mode_gate", "docker_publication_inventory", "listener_udp_14433", "listener_tcp_18443"):
            report = original()
            next(record for record in report["checks"] if record["check"] == name).update(status="blocked", value="blocked")
            with self.subTest(name=name), self.assertRaises(ValueError):
                parse(envelope(report))
        for key, value in (("run_id", "lan-other"), ("source_commit", "b" * 40),
                           ("server_ipv4", "192.168.77.11"), ("minimum_mtu", 1500)):
            report = original()
            report[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                parse(envelope(report))
        with self.assertRaises(ValueError):
            parse(envelope(), "client")

    def test_required_check_removal_and_fake_pass_rejected(self):
        report = original()
        report["checks"] = report["checks"][:-1]
        with self.assertRaises(ValueError):
            parse(envelope(report))
        report = original()
        next(record for record in report["checks"] if record["check"] == "capture_origin").update(status="pass", value="native_windows_powershell")
        with self.assertRaises(ValueError):
            parse(envelope(report))


if __name__ == "__main__":
    unittest.main()
