#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
"""Fail-closed verifier for the TP-WEB-REALTIME LAN standalone artifact."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
from pathlib import Path, PurePosixPath

MAX_MANIFEST_BYTES = 1024 * 1024
MAX_PACKAGE_BYTES = 128 * 1024 * 1024
MAX_FILES = 10_000
MANIFEST_NAME = "MANIFEST.sha256.json"
CONTRACT_NAME = "lan-launcher.tsv"


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"standalone manifest: {message}")


def bounded_regular(path: Path, limit: int) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError:
        fail("manifest is unavailable or unsafe")
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size <= 0 or metadata.st_size > limit:
            fail("manifest size/type is outside policy")
        data = os.read(descriptor, limit + 1)
        if len(data) != metadata.st_size:
            fail("manifest changed while it was read")
        return data
    finally:
        os.close(descriptor)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError:
        fail("listed artifact is unavailable or unsafe")
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            fail("listed artifact is not a regular file")
        with os.fdopen(descriptor, "rb", closefd=False) as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()
    finally:
        os.close(descriptor)


def safe_relative(value: object) -> str:
    if not isinstance(value, str) or not value or "\\" in value or "\x00" in value:
        fail("manifest contains an invalid relative path")
    candidate = PurePosixPath(value)
    if candidate.is_absolute() or any(part in ("", ".", "..") for part in candidate.parts):
        fail("manifest path escapes player/")
    normalized = candidate.as_posix()
    if normalized != value or normalized == MANIFEST_NAME:
        fail("manifest path is not canonical or inventories itself")
    return normalized


def actual_files(root: Path) -> set[str]:
    result: set[str] = set()
    for directory, directories, files in os.walk(root, followlinks=False):
        current = Path(directory)
        for name in directories:
            if (current / name).is_symlink():
                fail("player artifact contains a symlink")
        for name in files:
            path = current / name
            try:
                metadata = path.lstat()
            except OSError:
                fail("player inventory changed while it was read")
            if not stat.S_ISREG(metadata.st_mode):
                fail("player artifact contains a non-regular file")
            result.add(path.relative_to(root).as_posix())
    return result


def verify(root: Path, source_commit: str, launcher: str) -> str:
    if not root.is_absolute() or root.is_symlink() or not root.is_dir():
        fail("player-dir must be an absolute non-symlink directory")
    if len(source_commit) != 40 or any(character not in "0123456789abcdef" for character in source_commit):
        fail("source-commit must be one lowercase full SHA")
    launcher_relative = safe_relative(launcher)
    try:
        document = json.loads(bounded_regular(root / MANIFEST_NAME, MAX_MANIFEST_BYTES).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        fail("manifest is not bounded UTF-8 JSON")
    expected_keys = {"schema_version", "artifact", "package_version", "source_commit", "entrypoint", "files", "total_bytes"}
    if not isinstance(document, dict) or set(document) != expected_keys:
        fail("manifest schema is not closed")
    if document["schema_version"] != 1 or document["artifact"] != "teremoq-lan-lab-standalone":
        fail("manifest identity is outside policy")
    if document["source_commit"] != source_commit:
        fail("manifest source_commit differs from the exact package commit")
    package_version = document["package_version"]
    if not isinstance(package_version, str) or not package_version or len(package_version) > 64 or any(
        character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-" for character in package_version
    ):
        fail("manifest package_version is outside policy")
    if document["entrypoint"] != "start.mjs":
        fail("manifest entrypoint is outside policy")
    entries = document["files"]
    if not isinstance(entries, list) or not 1 <= len(entries) <= MAX_FILES:
        fail("manifest file count is outside policy")
    if not isinstance(document["total_bytes"], int) or isinstance(document["total_bytes"], bool):
        fail("manifest total_bytes is invalid")

    listed: set[str] = set()
    total = 0
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"path", "bytes", "sha256"}:
            fail("manifest file record schema is not closed")
        relative = safe_relative(entry["path"])
        if relative in listed:
            fail("manifest contains a duplicate path")
        listed.add(relative)
        size = entry["bytes"]
        digest = entry["sha256"]
        if not isinstance(size, int) or isinstance(size, bool) or size < 0 or size > MAX_PACKAGE_BYTES:
            fail("manifest file size is outside policy")
        if not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
            fail("manifest file checksum is invalid")
        path = root.joinpath(*PurePosixPath(relative).parts)
        try:
            metadata = path.lstat()
        except OSError:
            fail("manifest lists an unavailable artifact")
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size != size or sha256_file(path) != digest:
            fail("manifest file size/checksum mismatch")
        total += size
        if total > MAX_PACKAGE_BYTES:
            fail("manifest exceeds the 128 MiB package limit")
    if total != document["total_bytes"]:
        fail("manifest total_bytes does not match its records")

    actual = actual_files(root)
    if not listed.issubset(actual) or actual - {MANIFEST_NAME} != listed:
        fail("manifest inventory is incomplete or the player contains an unlisted file")
    if "start.mjs" not in listed or CONTRACT_NAME not in listed or launcher_relative not in listed:
        fail("standalone entrypoint, nine-key contract or load launcher is missing from the closed manifest")
    return package_version


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--player-dir", required=True, type=Path)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--launcher", required=True)
    arguments = parser.parse_args()
    package_version = verify(arguments.player_dir, arguments.source_commit, arguments.launcher)
    print(f"package_version: {package_version}")


if __name__ == "__main__":
    main()
