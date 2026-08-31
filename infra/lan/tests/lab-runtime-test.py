#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
import importlib.util
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
SPEC = importlib.util.spec_from_file_location("teremoq_lan_runtime", ROOT / "lab_runtime.py")
assert SPEC is not None and SPEC.loader is not None
RUNTIME = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = RUNTIME
SPEC.loader.exec_module(RUNTIME)

RUN_ID = "lan-runtime-test"
SOURCE_COMMIT = "a" * 40
OWNER_COMMIT = "6dadfbd8695bd1d0037568d879563eb83b7567b5"
PROVENANCE_COMMIT = "2f8fb1b3219483050bc997bee25a052c2db5f463"
SERVER_IP = "192.168.77.10"
CLIENT_IP = "192.168.77.20"
PROFILE = "Public"
MAX_CLOCK = 25
MIN_MTU = 1280
SERVER_MIN_CPU = 2
SERVER_MIN_MEMORY = 2048
SERVER_MIN_DISK = 4096
CLIENT_MIN_CPU = 2
CLIENT_MIN_MEMORY = 2048
CLIENT_MIN_DISK = 4096


def check(name: str, value: str = "measured", status: str = "observed", quality: str = "real") -> dict[str, str]:
    return {"check": name, "status": status, "value": value, "evidence_quality": quality}


def capture_context(
    interoperability: bool = False,
    *,
    parent_process_names: list[str] | None = None,
    traversal_outcome: str = "terminated_parent_pid_nonpositive",
    traversal_depth_limit: int = 16,
    parent_process_count: int | None = None,
) -> dict[str, object]:
    names = parent_process_names if parent_process_names is not None else (
        ["wslhost.exe", "bash.exe"] if interoperability else ["windowsterminal.exe", "explorer.exe"]
    )
    return {
        "schema_version": 2,
        "current_process_name": "powershell.exe",
        "parent_process_names": names,
        "parent_process_count": len(names) if parent_process_count is None else parent_process_count,
        "traversal_depth_limit": traversal_depth_limit,
        "traversal_outcome": traversal_outcome,
        "wsl_environment_keys_present": ["WSL_INTEROP"] if interoperability else [],
        "powershell_edition": "Desktop",
        "powershell_version_major": 5,
    }


def windows_preflight(role: str) -> dict[str, object]:
    names = RUNTIME.SERVER_WINDOWS_CHECKS if role == "server" else RUNTIME.CLIENT_WINDOWS_CHECKS
    checks = {name: check(name) for name in names}
    checks["preflight_gate"] = check("preflight_gate", "ready", "pass")
    checks["capture_origin"] = check("capture_origin", "native_windows_powershell", "pass")
    checks["network_profile"] = check("network_profile", PROFILE, "pass")
    checks["clock_offset"] = check("clock_offset", "0.079", "pass")
    checks["mtu"] = check("mtu", "1500", "pass")
    checks["logical_cpu"] = check("logical_cpu", "8", "pass")
    checks["physical_memory_mib"] = check("physical_memory_mib", "8192", "pass")
    checks["free_disk_mib"] = check("free_disk_mib", "16384", "pass")
    if role == "server":
        checks["wifi_adapter"] = check("wifi_adapter", "ifindex=11;physical_media=Native 802.11;ndis_medium=9", "pass")
        checks["wifi_radio"] = check("wifi_radio", "802.11ac")
        checks["wifi_band"] = check("wifi_band", "5 GHz", "pass")
        checks["expected_wsl_mode_gate"] = check("expected_wsl_mode_gate", "mirrored", "pass")
        checks["docker_publication_inventory"] = check("docker_publication_inventory", "bounded-scan", "pass")
        for port in (*RUNTIME.LEGACY_UDP_PORTS, 14433, 19000):
            checks[f"listener_udp_{port}"] = check(f"listener_udp_{port}", "free", "pass")
        for port in RUNTIME.LEGACY_TCP_PORTS:
            checks[f"listener_tcp_{port}"] = check(f"listener_tcp_{port}", "free", "pass")
    else:
        checks["wifi_radio"] = check("wifi_radio", "802.11ac")
        checks["wifi_5ghz"] = check("wifi_5ghz", "5 GHz", "pass")
        checks["wsl_ipv4_mode"] = check("wsl_ipv4_mode", "nat", "pass")
        checks["player_loopback_tcp_3000"] = check("player_loopback_tcp_3000", "free", "pass")
    return {
        "schema_version": 2, "report_kind": "teremoq-lan-windows-preflight-v2", "run_id": RUN_ID,
        "source_commit": SOURCE_COMMIT, "role": role, "server_ipv4": SERVER_IP, "client_ipv4": CLIENT_IP,
        "prefix_length": 24, "network_profile": PROFILE, "expected_wsl_mode": "mirrored" if role == "server" else "nat",
        "maximum_clock_offset_ms": MAX_CLOCK, "minimum_mtu": MIN_MTU,
        "minimum_cpu_cores": SERVER_MIN_CPU if role == "server" else CLIENT_MIN_CPU,
        "minimum_memory_mib": SERVER_MIN_MEMORY if role == "server" else CLIENT_MIN_MEMORY,
        "minimum_disk_mib": SERVER_MIN_DISK if role == "server" else CLIENT_MIN_DISK,
        "capture_context": capture_context(),
        "checks": list(checks.values()),
    }


def wsl_preflight(blocked_udp_4433: bool = False, nat: bool = False) -> bytes:
    checks = {name: check(name) for name in RUNTIME.WSL_PREFLIGHT_CHECKS}
    bindings = {
        "schema_version": "2", "report_kind": "teremoq-lan-wsl-preflight-v2", "run_id": RUN_ID,
        "source_commit": SOURCE_COMMIT, "role": "server", "server_ipv4": SERVER_IP, "client_ipv4": CLIENT_IP,
        "prefix_length": "24", "network_profile": PROFILE, "expected_wsl_mode": "mirrored",
        "maximum_clock_offset_ms": str(MAX_CLOCK), "minimum_mtu": str(MIN_MTU),
        "minimum_cpu_cores": str(SERVER_MIN_CPU), "minimum_memory_mib": str(SERVER_MIN_MEMORY),
        "minimum_disk_mib": str(SERVER_MIN_DISK),
    }
    for name, value in bindings.items():
        checks[name] = check(name, value, "pass", "configured")
    checks["clock_synchronized"] = check("clock_synchronized", "yes", "pass")
    checks["mtu"] = check("mtu", "1500", "pass")
    checks["cpu_cores"] = check("cpu_cores", "8", "pass")
    checks["available_memory_mib"] = check("available_memory_mib", "8192", "pass")
    checks["available_disk_mib"] = check("available_disk_mib", "16384", "pass")
    checks["docker_publication_inventory"] = check("docker_publication_inventory", "bounded-scan", "pass")
    checks["preflight_gate"] = check("preflight_gate", "blocked" if blocked_udp_4433 else "ready",
                                      "blocked" if blocked_udp_4433 else "pass")
    checks["windows_wsl_mode_observed"] = check("windows_wsl_mode_observed", "nat" if nat else "mirrored",
                                                 "pass" if not nat else "blocked")
    for port in (*RUNTIME.LEGACY_UDP_PORTS, 14433, 19000):
        checks[f"listener_udp_{port}"] = check(f"listener_udp_{port}", "free", "pass")
    for port in RUNTIME.LEGACY_TCP_PORTS:
        checks[f"listener_tcp_{port}"] = check(f"listener_tcp_{port}", "free", "pass")
    if blocked_udp_4433:
        checks["listener_udp_4433"] = check("listener_udp_4433", "occupied", "blocked")
    rows = ["check\tstatus\tvalue\tevidence_quality"]
    rows.extend("\t".join(record[key] for key in ("check", "status", "value", "evidence_quality")) for record in checks.values())
    return ("\n".join(rows) + "\n").encode()


def firewall_attestation() -> dict[str, object]:
    return {
        "schema_version": 1, "run_id": RUN_ID, "source_commit": SOURCE_COMMIT,
        "server_ipv4": SERVER_IP, "client_ipv4": CLIENT_IP, "network_profile": PROFILE,
        "protocol": "UDP", "local_port": 14433,
        "classic_rule_name": f"Teremoq-LAN-{RUN_ID}-Defender-QUIC-UDP-14433",
        "hyperv_rule_name": f"Teremoq-LAN-{RUN_ID}-HyperV-QUIC-UDP-14433",
        "classic_rule_count": 1, "hyperv_rule_count": 1, "edge_traversal_policy": "Block",
        "firewall_verified": True, "default_inbound_action_changed": False,
    }


class LabRuntimePolicyTest(unittest.TestCase):
    def test_runtime_explicitly_sets_the_approved_moq_namespace(self) -> None:
        source = (ROOT / "lab_runtime.py").read_text(encoding="utf-8")
        self.assertIn('"TEREMOQ_MOQ_NAMESPACE": args.moq_namespace', source)
        capability_path = Path("/tmp/teremoq-lan-runtime-test/publish-capability")
        inherited = {RUNTIME.PUBLISH_CAPABILITY_ENV: "/foreign/path", "SAFE": "yes"}
        for component in ("relay", "gateway"):
            environment = RUNTIME.environment_for_component(inherited, component, capability_path)
            self.assertEqual(environment[RUNTIME.PUBLISH_CAPABILITY_ENV], str(capability_path))
        source_environment = RUNTIME.environment_for_component(inherited, "source", capability_path)
        self.assertNotIn(RUNTIME.PUBLISH_CAPABILITY_ENV, source_environment)
        self.assertEqual(source_environment["SAFE"], "yes")
        self.assertIn('parser.add_argument("--moq-namespace", required=True)', source)
        self.assertIn('stream.write(evidence_payloads["proxy_attestation_sha256"])', source)
        self.assertIn('"--attestation", str(proxy_attestation_snapshot)', source)

    def test_lan_v2_profile_is_derived_from_canonical_server_ip(self) -> None:
        expected = "webtransport-hash-v2-lan-ip-sha256:" + RUNTIME.hashlib.sha256(b"192.168.77.10").hexdigest() + "\n"
        self.assertEqual(RUNTIME.expected_lan_identity_profile("192.168.77.10"), expected)
        self.assertNotIn("192.168.77.10", expected)
        with self.assertRaises(ValueError):
            RUNTIME.expected_lan_identity_profile("100.64.0.1")

    def test_exact_command_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact_root = root / "artifacts"
            artifact_root.mkdir()
            artifact_root.chmod(0o555)
            executable = root / "reviewed-component"
            executable.write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
            executable.chmod(0o755)
            executable_sha = hashlib.sha256(executable.read_bytes()).hexdigest()
            document = {
                "spdx_copyright": "2026 Teremoq contributors",
                "spdx_license_identifier": "Apache-2.0",
                "schema_version": 1,
                "source_commit": "a" * 40,
                "components": {
                    name: {"cwd": str(root), "command": [str(executable)], "executable_sha256": executable_sha}
                    for name in RUNTIME.COMPONENTS
                },
            }
            path = root / "commands.json"
            path.write_text(json.dumps(document), encoding="utf-8")
            manifest_sha = hashlib.sha256(path.read_bytes()).hexdigest()
            self.assertEqual(set(RUNTIME.parse_commands(path, "a" * 40, manifest_sha, root, artifact_root)), set(RUNTIME.COMPONENTS))
            path.write_text(json.dumps(document) + " ", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "manifest SHA-256"):
                RUNTIME.parse_commands(path, "a" * 40, manifest_sha, root, artifact_root)
            forbidden = root / "dash"
            forbidden.write_bytes(Path("/bin/sh").resolve().read_bytes())
            forbidden.chmod(0o755)
            document["components"]["source"]["command"] = [str(forbidden), "-c", "true"]
            document["components"]["source"]["executable_sha256"] = hashlib.sha256(forbidden.read_bytes()).hexdigest()
            path.write_text(json.dumps(document), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "runner"):
                RUNTIME.parse_commands(path, "a" * 40, hashlib.sha256(path.read_bytes()).hexdigest(), root, artifact_root)

    def test_executable_replacement_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "reviewed-component"
            executable.write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
            executable.chmod(0o755)
            expected = hashlib.sha256(executable.read_bytes()).hexdigest()
            RUNTIME.verify_executable_hash(executable, expected)
            executable.write_text("#!/bin/sh\nexit 9\n", encoding="ascii")
            with self.assertRaisesRegex(ValueError, "executable SHA-256"):
                RUNTIME.verify_executable_hash(executable, expected)

    def test_authorization_is_bounded_and_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "authorization.tsv"
            values = {
                "schema_version": "1", "run_id": RUN_ID, "source_commit": SOURCE_COMMIT,
                "owner_integration_commit": OWNER_COMMIT,
                "commands_sha256": "1" * 64,
                "publish_capability_metadata_sha256": "9" * 64,
                "wsl_preflight_sha256": "0" * 64,
                "server_preflight_sha256": "b" * 64, "client_preflight_sha256": "c" * 64,
                "firewall_attestation_sha256": "d" * 64,
                "proxy_attestation_sha256": "e" * 64,
                "owner_integrations_ready": "true", "operator_authorized": "true",
            }
            path.write_text("".join(f"{key}\t{value}\n" for key, value in values.items()), encoding="utf-8")
            self.assertEqual(RUNTIME.parse_authorization(path)["operator_authorized"], "true")
            values["owner_integration_commit"] = PROVENANCE_COMMIT
            path.write_text("".join(f"{key}\t{value}\n" for key, value in values.items()), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "exact reviewed Rust"):
                RUNTIME.parse_authorization(path)
            values["owner_integration_commit"] = OWNER_COMMIT
            path.write_text("".join(f"{key}\t{value}\n" for key, value in values.items()) + "server_preflight_gate\tpass\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "unknown or duplicate"):
                RUNTIME.parse_authorization(path)
            values["operator_authorized"] = "false"
            path.write_text("".join(f"{key}\t{value}\n" for key, value in values.items()), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "explicitly true"):
                RUNTIME.parse_authorization(path)

    def test_repository_rejects_provenance_and_unrelated_operational_overrides(self) -> None:
        integration = Path("/home/jimbomilk/teremoq-lan-integration")
        self.assertTrue(integration.is_dir(), "reviewed LAN integration worktree is required")
        status = subprocess.run(
            ["git", "-C", str(integration), "status", "--porcelain=v1", "--untracked-files=all"],
            check=True, stdout=subprocess.PIPE, text=True,
        ).stdout.strip()
        if status:
            self.skipTest("reviewed LAN integration worktree is not clean in this environment")
        integrated_head = subprocess.run(
            ["git", "-C", str(integration), "rev-parse", "HEAD"], check=True,
            stdout=subprocess.PIPE, text=True,
        ).stdout.strip()
        RUNTIME.verify_repository(integration, integrated_head, OWNER_COMMIT)
        with self.assertRaisesRegex(ValueError, "exact integrated"):
            RUNTIME.verify_repository(Path("/not/used"), SOURCE_COMMIT, PROVENANCE_COMMIT)
        with self.assertRaisesRegex(ValueError, "exact integrated"):
            RUNTIME.verify_repository(Path("/not/used"), SOURCE_COMMIT, "b" * 40)

    def test_closed_preflight_and_firewall_contracts_accept_ready_evidence(self) -> None:
        RUNTIME.parse_wsl_preflight(wsl_preflight(), RUN_ID, SOURCE_COMMIT, SERVER_IP, CLIENT_IP, 24, PROFILE,
                                    MAX_CLOCK, MIN_MTU, SERVER_MIN_CPU, SERVER_MIN_MEMORY, SERVER_MIN_DISK)
        for role in ("server", "client"):
            payload = json.dumps(windows_preflight(role)).encode()
            RUNTIME.parse_windows_preflight(
                payload, role, RUN_ID, SOURCE_COMMIT, SERVER_IP, CLIENT_IP, 24, PROFILE,
                MAX_CLOCK, MIN_MTU, SERVER_MIN_CPU if role == "server" else CLIENT_MIN_CPU,
                SERVER_MIN_MEMORY if role == "server" else CLIENT_MIN_MEMORY,
                SERVER_MIN_DISK if role == "server" else CLIENT_MIN_DISK,
            )
        RUNTIME.parse_firewall_attestation(json.dumps(firewall_attestation()).encode(), RUN_ID, SOURCE_COMMIT,
                                           SERVER_IP, CLIENT_IP, PROFILE)

    def test_hash_bound_authorization_cannot_override_blocked_legacy_listener(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "wsl-preflight.tsv"
            payload = wsl_preflight(blocked_udp_4433=True)
            path.write_bytes(payload)
            digest = hashlib.sha256(payload).hexdigest()
            authorization_path = Path(directory) / "authorization.tsv"
            authorization = {
                "schema_version": "1", "run_id": RUN_ID, "source_commit": SOURCE_COMMIT,
                "owner_integration_commit": OWNER_COMMIT, "commands_sha256": "1" * 64,
                "publish_capability_metadata_sha256": "9" * 64,
                "wsl_preflight_sha256": digest, "server_preflight_sha256": "2" * 64,
                "client_preflight_sha256": "3" * 64, "firewall_attestation_sha256": "4" * 64,
                "proxy_attestation_sha256": "5" * 64, "owner_integrations_ready": "true",
                "operator_authorized": "true",
            }
            authorization_path.write_text("".join(f"{key}\t{value}\n" for key, value in authorization.items()), encoding="utf-8")
            parsed_authorization = RUNTIME.parse_authorization(authorization_path)
            self.assertEqual(parsed_authorization["operator_authorized"], "true")
            snapshot = RUNTIME.read_bound_bytes(path, 32768, parsed_authorization["wsl_preflight_sha256"], "WSL server preflight")
            with self.assertRaisesRegex(ValueError, "not activation-ready|listener conflict"):
                RUNTIME.parse_wsl_preflight(snapshot, RUN_ID, SOURCE_COMMIT, SERVER_IP, CLIENT_IP, 24, PROFILE,
                                            MAX_CLOCK, MIN_MTU, SERVER_MIN_CPU, SERVER_MIN_MEMORY, SERVER_MIN_DISK)

    def test_nat_pending_unknown_and_unavailable_preflight_states_are_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "not activation-ready|NAT"):
            RUNTIME.parse_wsl_preflight(wsl_preflight(nat=True), RUN_ID, SOURCE_COMMIT, SERVER_IP, CLIENT_IP, 24, PROFILE,
                                        MAX_CLOCK, MIN_MTU, SERVER_MIN_CPU, SERVER_MIN_MEMORY, SERVER_MIN_DISK)
        document = windows_preflight("client")
        document["checks"][0]["status"] = "pending"  # type: ignore[index]
        document["checks"][0]["value"] = "not_measured"  # type: ignore[index]
        with self.assertRaisesRegex(ValueError, "not activation-ready"):
            RUNTIME.parse_windows_preflight(json.dumps(document).encode(), "client", RUN_ID, SOURCE_COMMIT,
                                            SERVER_IP, CLIENT_IP, 24, PROFILE,
                                            MAX_CLOCK, MIN_MTU, CLIENT_MIN_CPU, CLIENT_MIN_MEMORY, CLIENT_MIN_DISK)

    def test_every_legacy_listener_port_is_fail_closed(self) -> None:
        for protocol, ports in (("udp", RUNTIME.LEGACY_UDP_PORTS), ("tcp", RUNTIME.LEGACY_TCP_PORTS)):
            for port in ports:
                with self.subTest(protocol=protocol, port=port):
                    document = windows_preflight("server")
                    name = f"listener_{protocol}_{port}"
                    record = next(item for item in document["checks"] if item["check"] == name)  # type: ignore[union-attr]
                    record.update(status="blocked", value="occupied")
                    gate = next(item for item in document["checks"] if item["check"] == "preflight_gate")  # type: ignore[union-attr]
                    gate.update(status="blocked", value="blocked")
                    with self.assertRaisesRegex(ValueError, "not activation-ready|listener conflict"):
                        RUNTIME.parse_windows_preflight(json.dumps(document).encode(), "server", RUN_ID,
                                                        SOURCE_COMMIT, SERVER_IP, CLIENT_IP, 24, PROFILE,
                                                        MAX_CLOCK, MIN_MTU, SERVER_MIN_CPU, SERVER_MIN_MEMORY, SERVER_MIN_DISK)

    def test_firewall_edge_traversal_and_cardinality_are_fail_closed(self) -> None:
        document = firewall_attestation()
        document["edge_traversal_policy"] = "Allow"
        with self.assertRaisesRegex(ValueError, "property binding"):
            RUNTIME.parse_firewall_attestation(json.dumps(document).encode(), RUN_ID, SOURCE_COMMIT,
                                               SERVER_IP, CLIENT_IP, PROFILE)
        document = firewall_attestation()
        document["hyperv_rule_count"] = 2
        with self.assertRaisesRegex(ValueError, "property binding"):
            RUNTIME.parse_firewall_attestation(json.dumps(document).encode(), RUN_ID, SOURCE_COMMIT,
                                               SERVER_IP, CLIENT_IP, PROFILE)

    def test_preflight_binding_and_digest_tamper_are_rejected(self) -> None:
        document = windows_preflight("server")
        document["source_commit"] = "b" * 40
        with self.assertRaisesRegex(ValueError, "binding mismatch"):
            RUNTIME.parse_windows_preflight(json.dumps(document).encode(), "server", RUN_ID, SOURCE_COMMIT,
                                            SERVER_IP, CLIENT_IP, 24, PROFILE,
                                            MAX_CLOCK, MIN_MTU, SERVER_MIN_CPU, SERVER_MIN_MEMORY, SERVER_MIN_DISK)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "evidence.json"
            path.write_bytes(b"{}")
            with self.assertRaisesRegex(ValueError, "digest mismatch"):
                RUNTIME.read_bound_bytes(path, 8192, "0" * 64, "tampered preflight")

    def test_threshold_binding_and_measurement_mismatches_are_rejected(self) -> None:
        document = windows_preflight("server")
        document["maximum_clock_offset_ms"] = MAX_CLOCK + 1
        with self.assertRaisesRegex(ValueError, "threshold binding mismatch"):
            RUNTIME.parse_windows_preflight(json.dumps(document).encode(), "server", RUN_ID, SOURCE_COMMIT,
                                            SERVER_IP, CLIENT_IP, 24, PROFILE,
                                            MAX_CLOCK, MIN_MTU, SERVER_MIN_CPU, SERVER_MIN_MEMORY, SERVER_MIN_DISK)
        document = windows_preflight("client")
        record = next(item for item in document["checks"] if item["check"] == "clock_offset")  # type: ignore[union-attr]
        record.update(value="25.001")
        with self.assertRaisesRegex(ValueError, "clock offset exceeds policy"):
            RUNTIME.parse_windows_preflight(json.dumps(document).encode(), "client", RUN_ID, SOURCE_COMMIT,
                                            SERVER_IP, CLIENT_IP, 24, PROFILE,
                                            MAX_CLOCK, MIN_MTU, CLIENT_MIN_CPU, CLIENT_MIN_MEMORY, CLIENT_MIN_DISK)

    def test_capture_context_rejects_wsl_interop_and_incomplete_walks(self) -> None:
        document = windows_preflight("server")
        document["capture_context"] = capture_context(interoperability=True)
        with self.assertRaisesRegex(ValueError, "capture path is not native Windows PowerShell"):
            RUNTIME.parse_windows_preflight(json.dumps(document).encode(), "server", RUN_ID, SOURCE_COMMIT,
                                            SERVER_IP, CLIENT_IP, 24, PROFILE,
                                            MAX_CLOCK, MIN_MTU, SERVER_MIN_CPU, SERVER_MIN_MEMORY, SERVER_MIN_DISK)
        document = windows_preflight("client")
        document["capture_context"]["parent_process_names"] = ["windowsterminal.exe", "windowsterminal.exe"]  # type: ignore[index]
        with self.assertRaisesRegex(ValueError, "duplicates"):
            RUNTIME.parse_windows_preflight(json.dumps(document).encode(), "client", RUN_ID, SOURCE_COMMIT,
                                            SERVER_IP, CLIENT_IP, 24, PROFILE,
                                            MAX_CLOCK, MIN_MTU, CLIENT_MIN_CPU, CLIENT_MIN_MEMORY, CLIENT_MIN_DISK)
        document = windows_preflight("server")
        document["capture_context"] = capture_context(
            parent_process_names=["windowsterminal.exe"],
            parent_process_count=1,
            traversal_outcome="depth_limit_reached",
        )
        with self.assertRaisesRegex(ValueError, "does not prove parent-chain termination"):
            RUNTIME.parse_windows_preflight(json.dumps(document).encode(), "server", RUN_ID, SOURCE_COMMIT,
                                            SERVER_IP, CLIENT_IP, 24, PROFILE,
                                            MAX_CLOCK, MIN_MTU, SERVER_MIN_CPU, SERVER_MIN_MEMORY, SERVER_MIN_DISK)
        document = windows_preflight("client")
        document["capture_context"] = capture_context(parent_process_count=3)
        with self.assertRaisesRegex(ValueError, "cardinality is inconsistent"):
            RUNTIME.parse_windows_preflight(json.dumps(document).encode(), "client", RUN_ID, SOURCE_COMMIT,
                                            SERVER_IP, CLIENT_IP, 24, PROFILE,
                                            MAX_CLOCK, MIN_MTU, CLIENT_MIN_CPU, CLIENT_MIN_MEMORY, CLIENT_MIN_DISK)

    def test_ambiguous_or_noncanonical_wifi_band_blocks_activation(self) -> None:
        for band_value in ("2.4 GHz / 5 GHz", "not 5 GHz", "5 GHz preferred"):
            with self.subTest(band_value=band_value):
                document = windows_preflight("server")
                record = next(item for item in document["checks"] if item["check"] == "wifi_band")  # type: ignore[union-attr]
                record.update(status="observed", value=band_value)
                with self.assertRaisesRegex(ValueError, "did not prove the exact Wi-Fi interface and 5 GHz band"):
                    RUNTIME.parse_windows_preflight(json.dumps(document).encode(), "server", RUN_ID, SOURCE_COMMIT,
                                                    SERVER_IP, CLIENT_IP, 24, PROFILE,
                                                    MAX_CLOCK, MIN_MTU, SERVER_MIN_CPU, SERVER_MIN_MEMORY, SERVER_MIN_DISK)


if __name__ == "__main__":
    unittest.main()
