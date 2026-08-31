#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
"""Run-scoped private publication capability for the opt-in LAN lab."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import re
import secrets
import stat
import sys

CAPABILITY_NAME = "publish-capability"
METADATA_NAME = "publish-capability.metadata.tsv"
RUST_LAN_CAPABILITY_INTEGRATED_COMMIT = "6dadfbd8695bd1d0037568d879563eb83b7567b5"
RUST_LAN_CAPABILITY_PROVENANCE_COMMIT = "2f8fb1b3219483050bc997bee25a052c2db5f463"
RUST_LAN_CAPABILITY_PATCH_ID = "5729506f85cb640b0026e4db80e402d496cd8fd8"
METADATA_KEYS = {
    "schema_version", "run_id", "source_commit", "owner_integration_commit",
    "capability_filename", "capability_sha256", "capability_bytes", "capability_mode",
    "capability_uid", "capability_device", "capability_inode",
}


def fail(message: str) -> "NoReturn":
    raise ValueError(message)


def _validate_binding(run_id: str, source_commit: str, owner_commit: str) -> None:
    if not re.fullmatch(r"lan-[a-z0-9][a-z0-9-]{0,31}", run_id):
        fail("invalid capability run ID")
    if not re.fullmatch(r"[0-9a-f]{40}", source_commit):
        fail("invalid capability source commit")
    if owner_commit != RUST_LAN_CAPABILITY_INTEGRATED_COMMIT:
        fail("publish capability owner integration commit mismatch")


def _open_state_dir(state_dir: Path) -> int:
    if not state_dir.is_absolute() or state_dir.is_symlink() or state_dir.resolve() != state_dir:
        fail("capability state directory must be an absolute canonical non-symlink path")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(state_dir, flags)
    except OSError as error:
        raise ValueError("capability state directory is unavailable") from error
    metadata = os.fstat(descriptor)
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o700 or metadata.st_uid != os.geteuid():
        os.close(descriptor)
        fail("capability state directory must be an owned mode-0700 directory")
    return descriptor


def _read_at(directory: int, name: str, maximum: int, mode: int = 0o600) -> tuple[bytes, os.stat_result]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(name, flags, dir_fd=directory)
    except OSError as error:
        raise ValueError(f"{name} must be an available non-symlink file") from error
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or stat.S_IMODE(before.st_mode) != mode or before.st_uid != os.geteuid() or \
           before.st_size <= 0 or before.st_size > maximum:
            fail(f"{name} type, owner, mode or size is outside policy")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(4096, maximum + 1 - total))
            if not chunk:
                break
            total += len(chunk)
            if total > maximum:
                fail(f"{name} exceeds its byte limit")
            chunks.append(chunk)
        after = os.fstat(descriptor)
        stable = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns", "st_mode", "st_uid")
        if total != before.st_size or any(getattr(before, field) != getattr(after, field) for field in stable):
            fail(f"{name} changed during its single-descriptor read")
        return b"".join(chunks), after
    finally:
        os.close(descriptor)


def _require_marker(directory: int, name: str, expected: str) -> None:
    payload, _ = _read_at(directory, name, 128)
    if payload != f"{expected}\n".encode("ascii"):
        fail(f"capability state ownership marker mismatch: {name}")


def _parse_metadata(payload: bytes) -> dict[str, str]:
    try:
        text = payload.decode("ascii", errors="strict")
    except UnicodeDecodeError as error:
        raise ValueError("publish capability metadata encoding is invalid") from error
    values: dict[str, str] = {}
    lines = text.splitlines()
    if not 1 <= len(lines) <= len(METADATA_KEYS):
        fail("publish capability metadata cardinality is outside policy")
    for number, line in enumerate(lines, 1):
        fields = line.split("\t")
        if len(fields) != 2 or not all(fields):
            fail(f"invalid publish capability metadata line {number}")
        key, value = fields
        if key not in METADATA_KEYS or key in values:
            fail(f"unknown or duplicate publish capability metadata key: {key}")
        values[key] = value
    if set(values) != METADATA_KEYS:
        fail("publish capability metadata schema is incomplete")
    return values


def _write_all(descriptor: int, payload: bytes) -> None:
    offset = 0
    while offset < len(payload):
        written = os.write(descriptor, payload[offset:])
        if written <= 0:
            fail("short write while creating private publish capability")
        offset += written
    os.fsync(descriptor)


def _create_at(directory: int, name: str, payload: bytes) -> os.stat_result:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(name, flags, 0o600, dir_fd=directory)
    try:
        os.fchmod(descriptor, 0o600)
        _write_all(descriptor, payload)
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o600 or metadata.st_uid != os.geteuid():
            fail(f"created {name} does not satisfy the private-file contract")
        return metadata
    except Exception:
        try:
            os.unlink(name, dir_fd=directory)
        except FileNotFoundError:
            pass
        raise
    finally:
        os.close(descriptor)


def prepare_publish_capability(state_dir: Path, run_id: str, source_commit: str, owner_commit: str) -> None:
    _validate_binding(run_id, source_commit, owner_commit)
    directory = _open_state_dir(state_dir)
    created: list[str] = []
    try:
        _require_marker(directory, "run-id", run_id)
        _require_marker(directory, "source-commit", source_commit)
        capability = f"{secrets.token_hex(32)}\n".encode("ascii")
        metadata = _create_at(directory, CAPABILITY_NAME, capability)
        created.append(CAPABILITY_NAME)
        values = {
            "schema_version": "1",
            "run_id": run_id,
            "source_commit": source_commit,
            "owner_integration_commit": owner_commit,
            "capability_filename": CAPABILITY_NAME,
            "capability_sha256": hashlib.sha256(capability).hexdigest(),
            "capability_bytes": str(len(capability)),
            "capability_mode": "0600",
            "capability_uid": str(metadata.st_uid),
            "capability_device": str(metadata.st_dev),
            "capability_inode": str(metadata.st_ino),
        }
        metadata_payload = "".join(f"{key}\t{values[key]}\n" for key in sorted(METADATA_KEYS)).encode("ascii")
        _create_at(directory, METADATA_NAME, metadata_payload)
        created.append(METADATA_NAME)
        os.fsync(directory)
    except Exception:
        for name in reversed(created):
            try:
                os.unlink(name, dir_fd=directory)
            except FileNotFoundError:
                pass
        os.fsync(directory)
        raise
    finally:
        os.close(directory)


def _verify_at(directory: int, run_id: str, source_commit: str, owner_commit: str,
               expected_metadata_sha256: str | None) -> tuple[dict[str, str], os.stat_result, os.stat_result]:
    _require_marker(directory, "run-id", run_id)
    _require_marker(directory, "source-commit", source_commit)
    metadata_payload, metadata_file = _read_at(directory, METADATA_NAME, 4096)
    metadata_digest = hashlib.sha256(metadata_payload).hexdigest()
    if expected_metadata_sha256 is not None and metadata_digest != expected_metadata_sha256:
        fail("authorization publish capability metadata digest mismatch")
    values = _parse_metadata(metadata_payload)
    expected = {
        "schema_version": "1", "run_id": run_id, "source_commit": source_commit,
        "owner_integration_commit": owner_commit, "capability_filename": CAPABILITY_NAME,
        "capability_mode": "0600", "capability_uid": str(os.geteuid()),
    }
    if any(values.get(key) != value for key, value in expected.items()):
        fail("publish capability metadata run/commit/owner binding mismatch")
    for key in ("capability_bytes", "capability_device", "capability_inode"):
        if not re.fullmatch(r"[1-9][0-9]*", values[key]):
            fail(f"invalid publish capability metadata integer: {key}")
    if not re.fullmatch(r"[0-9a-f]{64}", values["capability_sha256"]):
        fail("invalid publish capability metadata SHA-256")
    capability, capability_metadata = _read_at(directory, CAPABILITY_NAME, 65)
    if re.fullmatch(rb"[0-9a-f]{64}\n?", capability) is None or len(capability) not in (64, 65):
        fail("publish capability content is not canonical")
    if len(capability) != int(values["capability_bytes"]) or \
       capability_metadata.st_dev != int(values["capability_device"]) or \
       capability_metadata.st_ino != int(values["capability_inode"]) or \
       hashlib.sha256(capability).hexdigest() != values["capability_sha256"]:
        fail("publish capability changed or its path no longer matches metadata")
    return values, capability_metadata, metadata_file


def verify_publish_capability(state_dir: Path, run_id: str, source_commit: str, owner_commit: str,
                              expected_metadata_sha256: str | None = None) -> None:
    _validate_binding(run_id, source_commit, owner_commit)
    if expected_metadata_sha256 is not None and re.fullmatch(r"[0-9a-f]{64}", expected_metadata_sha256) is None:
        fail("invalid authorized publish capability metadata SHA-256")
    directory = _open_state_dir(state_dir)
    try:
        _verify_at(directory, run_id, source_commit, owner_commit, expected_metadata_sha256)
    finally:
        os.close(directory)


def remove_owned_publish_capability(state_dir: Path, run_id: str, source_commit: str, owner_commit: str) -> None:
    _validate_binding(run_id, source_commit, owner_commit)
    directory = _open_state_dir(state_dir)
    try:
        absent = []
        for name in (CAPABILITY_NAME, METADATA_NAME):
            try:
                os.stat(name, dir_fd=directory, follow_symlinks=False)
                absent.append(False)
            except FileNotFoundError:
                absent.append(True)
        if all(absent):
            return
        if any(absent):
            fail("refusing partial publish capability cleanup")
        _, verified, verified_metadata = _verify_at(directory, run_id, source_commit, owner_commit, None)
        current = os.stat(CAPABILITY_NAME, dir_fd=directory, follow_symlinks=False)
        current_metadata = os.stat(METADATA_NAME, dir_fd=directory, follow_symlinks=False)
        if (current.st_dev, current.st_ino) != (verified.st_dev, verified.st_ino) or \
           (current_metadata.st_dev, current_metadata.st_ino) != (verified_metadata.st_dev, verified_metadata.st_ino):
            fail("publish capability or metadata changed before cleanup")
        os.unlink(CAPABILITY_NAME, dir_fd=directory)
        os.unlink(METADATA_NAME, dir_fd=directory)
        os.fsync(directory)
    finally:
        os.close(directory)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("prepare", "verify", "remove"))
    parser.add_argument("--state-dir", required=True, type=Path)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--owner-commit", required=True)
    parser.add_argument("--metadata-sha256")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.action == "prepare":
        if args.metadata_sha256 is not None:
            fail("prepare does not accept a metadata digest")
        prepare_publish_capability(args.state_dir, args.run_id, args.source_commit, args.owner_commit)
    elif args.action == "verify":
        verify_publish_capability(args.state_dir, args.run_id, args.source_commit, args.owner_commit,
                                  args.metadata_sha256)
    else:
        if args.metadata_sha256 is not None:
            fail("remove does not accept a metadata digest")
        remove_owned_publish_capability(args.state_dir, args.run_id, args.source_commit, args.owner_commit)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"teremoq LAN publish capability rejected: {error}", file=sys.stderr)
        raise SystemExit(2)
