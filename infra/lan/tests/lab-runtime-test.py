#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
import importlib.util
import hashlib
import json
from pathlib import Path
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


class LabRuntimePolicyTest(unittest.TestCase):
    def test_runtime_explicitly_sets_the_approved_moq_namespace(self) -> None:
        source = (ROOT / "lab_runtime.py").read_text(encoding="utf-8")
        self.assertIn('"TEREMOQ_MOQ_NAMESPACE": args.moq_namespace', source)
        self.assertIn('parser.add_argument("--moq-namespace", required=True)', source)

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
                "schema_version": "1", "run_id": "lan-runtime-test", "source_commit": "a" * 40,
                "owner_integration_commit": "f" * 40,
                "commands_sha256": "1" * 64,
                "server_preflight_sha256": "b" * 64, "client_preflight_sha256": "c" * 64,
                "firewall_attestation_sha256": "d" * 64, "server_preflight_gate": "pass",
                "proxy_attestation_sha256": "e" * 64, "client_preflight_gate": "pass", "legacy_conflicts_absent": "true",
                "owner_integrations_ready": "true", "operator_authorized": "true",
            }
            path.write_text("".join(f"{key}\t{value}\n" for key, value in values.items()), encoding="utf-8")
            self.assertEqual(RUNTIME.parse_authorization(path)["operator_authorized"], "true")
            values["operator_authorized"] = "false"
            path.write_text("".join(f"{key}\t{value}\n" for key, value in values.items()), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "explicitly true"):
                RUNTIME.parse_authorization(path)


if __name__ == "__main__":
    unittest.main()
