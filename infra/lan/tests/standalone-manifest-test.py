#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("standalone_manifest", ROOT / "verify-standalone-manifest.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class StandaloneManifestTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="teremoq-lan-manifest-test.")
        self.root = Path(self.temporary.name)
        self.commit = "a" * 40
        (self.root / "start.mjs").write_text("// fixture\n", encoding="utf-8")
        (self.root / "server.js").write_text("// standalone\n", encoding="utf-8")
        (self.root / "Start-TeremoqLanLoad.ps1").write_text("# launcher\n", encoding="utf-8")
        (self.root / "lan-launcher.tsv").write_text("schema_version\t1\n", encoding="utf-8")
        self.write_manifest()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_manifest(self, source_commit: str | None = None) -> None:
        files = []
        for name in ("Start-TeremoqLanLoad.ps1", "lan-launcher.tsv", "server.js", "start.mjs"):
            data = (self.root / name).read_bytes()
            files.append({"path": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        document = {
            "schema_version": 1,
            "artifact": "teremoq-lan-lab-standalone",
            "package_version": "0.1.0-lan",
            "source_commit": source_commit or self.commit,
            "entrypoint": "start.mjs",
            "files": files,
            "total_bytes": sum(item["bytes"] for item in files),
        }
        (self.root / "MANIFEST.sha256.json").write_text(json.dumps(document) + "\n", encoding="utf-8")

    def test_accepts_exact_source_and_inventory(self) -> None:
        MODULE.verify(self.root, self.commit, "Start-TeremoqLanLoad.ps1")

    def test_rejects_stale_source_commit(self) -> None:
        self.write_manifest("b" * 40)
        with self.assertRaises(SystemExit):
            MODULE.verify(self.root, self.commit, "Start-TeremoqLanLoad.ps1")

    def test_rejects_tamper_and_unlisted_files(self) -> None:
        (self.root / "server.js").write_text("tampered\n", encoding="utf-8")
        with self.assertRaises(SystemExit):
            MODULE.verify(self.root, self.commit, "Start-TeremoqLanLoad.ps1")
        (self.root / "server.js").write_text("// standalone\n", encoding="utf-8")
        (self.root / "unlisted.txt").write_text("extra\n", encoding="utf-8")
        with self.assertRaises(SystemExit):
            MODULE.verify(self.root, self.commit, "Start-TeremoqLanLoad.ps1")

    def test_rejects_extra_schema_and_symlink(self) -> None:
        manifest = json.loads((self.root / "MANIFEST.sha256.json").read_text(encoding="utf-8"))
        manifest["unexpected"] = True
        (self.root / "MANIFEST.sha256.json").write_text(json.dumps(manifest), encoding="utf-8")
        with self.assertRaises(SystemExit):
            MODULE.verify(self.root, self.commit, "Start-TeremoqLanLoad.ps1")
        self.write_manifest()
        (self.root / "linked").symlink_to(self.root / "server.js")
        with self.assertRaises(SystemExit):
            MODULE.verify(self.root, self.commit, "Start-TeremoqLanLoad.ps1")


if __name__ == "__main__":
    unittest.main()
