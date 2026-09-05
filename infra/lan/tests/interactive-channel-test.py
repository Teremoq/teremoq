#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0

import importlib.util
import json
import os
import tempfile
import time
from pathlib import Path

source = Path(__file__).parents[1] / "interactive_channel.py"
spec = importlib.util.spec_from_file_location("interactive_channel", source)
channel = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(channel)

commit = "a" * 40
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary) / "state"
    channel.initialize(root, "lan-channel-test", commit, "192.168.77.20")
    assert root.stat().st_mode & 0o777 == 0o700
    pairing = (root / "pairing-code").read_text(encoding="ascii").strip()
    state = channel.ChannelState(root, "lan-channel-test", commit, "192.168.77.10", "192.168.77.20")
    identity = {"schema_version": 1, "run_id": "lan-channel-test", "source_commit": commit}
    response = state.pair({**identity, "pairing_code": pairing})
    session = response["session"]
    assert not (root / "pairing-code").exists()
    time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
    assert state.poll(identity, session)["action"] == "wait"
    management = (root / "management-token").read_text(encoding="ascii").strip()
    time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
    assert state.enqueue({**identity, "action": "diagnose-build"}, management)["accepted"] is True
    time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
    assert state.poll(identity, session)["action"] == "diagnose-build"
    first = {**identity, "sequence": 1, "event": 1, "action": "diagnose-build", "status": "started", "message": "build started"}
    time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
    assert state.event(first, session)["accepted"] is True
    complete = {**first, "event": 2, "status": "failed", "message": "bounded diagnostic"}
    time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
    assert state.event(complete, session)["accepted"] is True
    time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
    assert state.poll(identity, session)["action"] == "wait"
    events = [json.loads(line) for line in (root / "channel-events.jsonl").read_text(encoding="utf-8").splitlines()]
    assert [event["status"] for event in events] == ["started", "failed"]
    assert (root / "channel-events.jsonl").stat().st_mode & 0o777 == 0o600
    for invalid in (
        {**identity, "sequence": 2, "event": 1, "action": "shell", "status": "complete", "message": "x"},
        {**identity, "sequence": 2, "event": 1, "action": "stop", "status": "complete", "message": "-----BEGIN PRIVATE KEY-----"},
    ):
        time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
        try:
            state.event(invalid, session)
            raise AssertionError("invalid event accepted")
        except ValueError:
            pass
    assert os.stat(root / "channel-state.json").st_mode & 0o777 == 0o600

print("lan-interactive-channel-test: PASS")
