#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
import importlib.util
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

MODULE_PATH = Path(__file__).resolve().parents[1] / "udp_proxy.py"
sys.path.insert(0, str(MODULE_PATH.parent))
SPEC = importlib.util.spec_from_file_location("teremoq_lan_udp_proxy", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
PROXY = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PROXY
SPEC.loader.exec_module(PROXY)


class ProxyPolicyTest(unittest.TestCase):
    def attestation(self, owner_commit: str = PROXY.RUST_LAN_CAPABILITY_INTEGRATED_COMMIT) -> dict[str, str]:
        run_id = "lan-policy-test"
        return {
            "schema_version": "1", "run_id": run_id, "source_commit": "a" * 40,
            "server_ipv4": "192.168.77.10", "client_ipv4": "192.168.77.20",
            "network_mode": "mirrored", "network_profile": "Public",
            "windows_firewall_rule_name": f"Teremoq-LAN-{run_id}-Defender-QUIC-UDP-14433",
            "hyperv_firewall_rule_name": f"Teremoq-LAN-{run_id}-HyperV-QUIC-UDP-14433",
            "firewall_verified": "true", "relay_san_integration_commit": owner_commit,
            "certificate_fingerprint_sha256": "c" * 64,
        }

    def test_source_allowlist_and_capacity(self) -> None:
        proxy = PROXY.BoundedUdpProxy("127.0.0.1", "192.168.77.20", 25, 2, 30)
        self.assertTrue(proxy.source_allowed(("192.168.77.20", 50000)))
        self.assertFalse(proxy.source_allowed(("192.168.77.21", 50000)))
        for offset in range(27):
            self.assertIsNotNone(proxy._association(("192.168.77.20", 40000 + offset), 1.0))
        self.assertIsNone(proxy._association(("192.168.77.20", 50000), 1.0))
        self.assertEqual(proxy.metrics["rejected_capacity"], 1)
        proxy.close()

    def test_client_limit_above_25_rejected(self) -> None:
        with self.assertRaises(ValueError):
            PROXY.validate_limits(26, 2, 30)
        with self.assertRaises(ValueError):
            PROXY.validate_limits(25, 3, 30)

    def test_exact_bind_and_cleanup(self) -> None:
        first = PROXY.BoundedUdpProxy("127.0.0.1", "192.168.77.20", 1, 2, 5)
        first.bind()
        self.assertEqual(first.frontend.getsockname(), ("127.0.0.1", 14433))
        second = PROXY.BoundedUdpProxy("127.0.0.1", "192.168.77.20", 1, 2, 5)
        with self.assertRaises(OSError):
            second.bind()
        second.close()
        first.close()
        third = PROXY.BoundedUdpProxy("127.0.0.1", "192.168.77.20", 1, 2, 5)
        third.bind()
        third.close()

    def test_nat_attestation_rejected(self) -> None:
        values = {
            "schema_version": "1", "run_id": "lan-policy-test", "source_commit": "a" * 40,
            "server_ipv4": "192.168.77.10", "client_ipv4": "192.168.77.20", "network_mode": "nat",
            "network_profile": "Public", "windows_firewall_rule_name": "x", "hyperv_firewall_rule_name": "y",
            "firewall_verified": "true", "relay_san_integration_commit": "b" * 40,
            "certificate_fingerprint_sha256": "c" * 64,
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "attestation.tsv"
            path.write_text("".join(f"{key}\t{value}\n" for key, value in values.items()), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "NAT"):
                PROXY.load_attestation(path)

    def test_attestation_rejects_origin_and_unrelated_operational_overrides(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "attestation.tsv"
            for owner_commit in (PROXY.RUST_LAN_CAPABILITY_PROVENANCE_COMMIT, "b" * 40):
                values = self.attestation(owner_commit)
                path.write_text("".join(f"{key}\t{value}\n" for key, value in values.items()), encoding="utf-8")
                with self.subTest(owner_commit=owner_commit), self.assertRaisesRegex(ValueError, "exact integrated"):
                    PROXY.load_attestation(path)
            values = self.attestation()
            path.write_text("".join(f"{key}\t{value}\n" for key, value in values.items()), encoding="utf-8")
            self.assertEqual(PROXY.load_attestation(path)["relay_san_integration_commit"],
                             PROXY.RUST_LAN_CAPABILITY_INTEGRATED_COMMIT)

    def test_non_exact_or_non_private_frontend_rejected(self) -> None:
        for value in ("0.0.0.0", "8.8.8.8", "100.64.0.1", "169.254.1.2", "192.0.0.1", "224.0.0.1", "192.168.77.0/24", "any"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                PROXY.exact_private_ipv4(value, "frontend")
        with self.assertRaisesRegex(ValueError, "network or broadcast"):
            PROXY.validate_topology("192.168.77.0", "192.168.77.20", 24)
        with self.assertRaisesRegex(ValueError, "share"):
            PROXY.validate_topology("192.168.77.10", "192.168.78.20", 24)

    def test_real_compatible_certificate_contract(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cert = root / "cert.pem"
            key = root / "key.pem"
            fingerprint = root / "fingerprint.sha256"
            subprocess.run(
                [
                    "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                    "-subj", "/CN=teremoq-lan-proxy-test",
                    "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:192.168.77.10",
                    "-keyout", str(key), "-out", str(cert),
                ],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            pem = cert.read_text(encoding="ascii")
            digest = hashlib.sha256(PROXY.ssl.PEM_cert_to_DER_cert(pem)).hexdigest()
            fingerprint.write_text(f"{digest}\n", encoding="ascii")
            self.assertEqual(
                PROXY.verify_certificate(cert, fingerprint, "192.168.77.10", digest),
                digest,
            )

    def test_bounded_inputs_and_partial_startup_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            oversized = root / "oversized.tsv"
            oversized.write_text("x" * 8193, encoding="ascii")
            with self.assertRaisesRegex(ValueError, "size"):
                PROXY.load_attestation(oversized)
            target = root / "target.tsv"
            target.write_text("schema_version\t1\n", encoding="ascii")
            symlink = root / "symlink.tsv"
            symlink.symlink_to(target)
            with self.assertRaisesRegex(ValueError, "non-symlink"):
                PROXY.load_attestation(symlink)
            def startup_failure() -> None:
                raise OSError("startup canary")
            with self.assertRaisesRegex(OSError, "startup canary"):
                PROXY.publish_startup_state(root, 12345, startup_failure)
            self.assertFalse((root / "proxy.pid").exists())
            self.assertFalse((root / "proxy.ready").exists())
            (root / "proxy.pid").write_text("foreign\n", encoding="ascii")
            with self.assertRaises(FileExistsError):
                PROXY.publish_startup_state(root, 12345)
            self.assertEqual((root / "proxy.pid").read_text(encoding="ascii"), "foreign\n")


if __name__ == "__main__":
    unittest.main()
