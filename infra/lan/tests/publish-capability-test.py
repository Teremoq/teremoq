#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
import hashlib
from pathlib import Path
import re
import stat
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import publish_capability as CAPABILITY  # noqa: E402

RUN_ID = "lan-capability-test"
SOURCE_COMMIT = "a" * 40
OWNER_COMMIT = CAPABILITY.RUST_LAN_CAPABILITY_INTEGRATED_COMMIT
PROVENANCE_COMMIT = CAPABILITY.RUST_LAN_CAPABILITY_PROVENANCE_COMMIT


class PublishCapabilityTest(unittest.TestCase):
    def setUp(self) -> None:
        # Windows TEMP is a DrvFs path in this WSL host and cannot represent the
        # exact Unix 0600/0700 contract; the real LAN runtime is under WSL /tmp.
        self.temporary = tempfile.TemporaryDirectory(dir="/tmp")
        self.state = Path(self.temporary.name) / "state"
        self.state.mkdir(mode=0o700)
        self.state.chmod(0o700)
        for name, value in (("run-id", RUN_ID), ("source-commit", SOURCE_COMMIT)):
            path = self.state / name
            path.write_text(f"{value}\n", encoding="ascii")
            path.chmod(0o600)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def prepare(self) -> str:
        CAPABILITY.prepare_publish_capability(self.state, RUN_ID, SOURCE_COMMIT, OWNER_COMMIT)
        metadata = (self.state / CAPABILITY.METADATA_NAME).read_bytes()
        return hashlib.sha256(metadata).hexdigest()

    def test_csprng_capability_is_private_hash_bound_and_run_owned(self) -> None:
        digest = self.prepare()
        private_path = self.state / CAPABILITY.CAPABILITY_NAME
        payload = private_path.read_bytes()
        self.assertIsNotNone(re.fullmatch(rb"[0-9a-f]{64}\n", payload))
        self.assertEqual(stat.S_IMODE(private_path.stat().st_mode), 0o600)
        metadata = (self.state / CAPABILITY.METADATA_NAME).read_text(encoding="ascii")
        if payload.decode("ascii").strip() in metadata:
            self.fail("private capability value leaked into metadata")
        self.assertIn(f"owner_integration_commit\t{OWNER_COMMIT}\n", metadata)
        if PROVENANCE_COMMIT in metadata:
            self.fail("provenance commit leaked into the operational capability metadata")
        CAPABILITY.verify_publish_capability(self.state, RUN_ID, SOURCE_COMMIT, OWNER_COMMIT, digest)

    def test_provenance_commit_cannot_override_operational_commit(self) -> None:
        with self.assertRaisesRegex(ValueError, "owner integration commit mismatch"):
            CAPABILITY.prepare_publish_capability(self.state, RUN_ID, SOURCE_COMMIT, PROVENANCE_COMMIT)
        self.assertFalse((self.state / CAPABILITY.CAPABILITY_NAME).exists())

    def test_changed_content_mode_and_metadata_digest_are_rejected(self) -> None:
        digest = self.prepare()
        private_path = self.state / CAPABILITY.CAPABILITY_NAME
        private_path.chmod(0o640)
        with self.assertRaisesRegex(ValueError, "mode or size"):
            CAPABILITY.verify_publish_capability(self.state, RUN_ID, SOURCE_COMMIT, OWNER_COMMIT, digest)
        private_path.chmod(0o600)
        private_path.write_text("f" * 64 + "\n", encoding="ascii")
        with self.assertRaisesRegex(ValueError, "changed"):
            CAPABILITY.verify_publish_capability(self.state, RUN_ID, SOURCE_COMMIT, OWNER_COMMIT, digest)
        with self.assertRaisesRegex(ValueError, "metadata digest mismatch"):
            CAPABILITY.verify_publish_capability(self.state, RUN_ID, SOURCE_COMMIT, OWNER_COMMIT, "0" * 64)

    def test_exact_path_inode_mismatch_is_rejected(self) -> None:
        digest = self.prepare()
        private_path = self.state / CAPABILITY.CAPABILITY_NAME
        moved = self.state / "foreign-capability"
        private_path.rename(moved)
        private_path.write_bytes(moved.read_bytes())
        private_path.chmod(0o600)
        with self.assertRaisesRegex(ValueError, "path no longer matches"):
            CAPABILITY.verify_publish_capability(self.state, RUN_ID, SOURCE_COMMIT, OWNER_COMMIT, digest)

    def test_partial_creation_is_cleaned_without_residue(self) -> None:
        original = CAPABILITY._create_at

        def fail_metadata(directory: int, name: str, payload: bytes):
            if name == CAPABILITY.METADATA_NAME:
                raise OSError("injected metadata failure")
            return original(directory, name, payload)

        with mock.patch.object(CAPABILITY, "_create_at", side_effect=fail_metadata):
            with self.assertRaises(OSError):
                CAPABILITY.prepare_publish_capability(self.state, RUN_ID, SOURCE_COMMIT, OWNER_COMMIT)
        self.assertFalse((self.state / CAPABILITY.CAPABILITY_NAME).exists())
        self.assertFalse((self.state / CAPABILITY.METADATA_NAME).exists())

    def test_cleanup_is_exact_idempotent_and_refuses_partial_state(self) -> None:
        self.prepare()
        CAPABILITY.remove_owned_publish_capability(self.state, RUN_ID, SOURCE_COMMIT, OWNER_COMMIT)
        CAPABILITY.remove_owned_publish_capability(self.state, RUN_ID, SOURCE_COMMIT, OWNER_COMMIT)
        self.assertFalse((self.state / CAPABILITY.CAPABILITY_NAME).exists())
        self.prepare()
        (self.state / CAPABILITY.METADATA_NAME).unlink()
        with self.assertRaisesRegex(ValueError, "partial"):
            CAPABILITY.remove_owned_publish_capability(self.state, RUN_ID, SOURCE_COMMIT, OWNER_COMMIT)
        self.assertTrue((self.state / CAPABILITY.CAPABILITY_NAME).exists())


if __name__ == "__main__":
    unittest.main()
