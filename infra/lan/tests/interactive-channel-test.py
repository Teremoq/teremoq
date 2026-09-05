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
assert channel.process_start_ticks(os.getpid()) > 0
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
    invalid_first = {**identity, "management_sequence": 1, "request_id": "0" * 32, "action": "load-25"}
    try:
        state.enqueue(invalid_first, management)
        raise AssertionError("progressive gate accepted load-25 as the first action")
    except ValueError:
        pass
    time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
    management_request = {**identity, "management_sequence": 1, "request_id": "1" * 32, "action": "diagnose-build"}
    assert state.enqueue(management_request, management)["accepted"] is True
    reloaded = channel.ChannelState(root, "lan-channel-test", commit, "192.168.77.10", "192.168.77.20")
    assert reloaded.document["management_sequence"] == 1
    assert reloaded.document["last_management_request"] == "1" * 32
    assert reloaded.document["tasks"][0]["management_request_id"] == "1" * 32
    time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
    assert state.poll(identity, session)["action"] == "diagnose-build"
    first = {**identity, "sequence": 1, "event": 1, "action": "diagnose-build", "status": "started", "message": "build started"}
    time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
    assert state.event(first, session)["accepted"] is True
    time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
    stop_request = {**identity, "management_sequence": 2, "request_id": "2" * 32, "action": "stop"}
    cancellation = state.enqueue(stop_request, management)
    assert cancellation["action"] == "stop" and cancellation["cancellation_sequence"] == 1
    complete = {**first, "event": 2, "status": "failed", "message": "bounded diagnostic"}
    time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
    assert state.event(complete, session)["cancel_requested"] is True
    time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
    try:
        state.enqueue(management_request, management)
        raise AssertionError("management replay accepted")
    except ValueError:
        pass
    time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
    assert state.poll(identity, session)["action"] == "stop"
    events = [json.loads(line) for line in (root / "channel-events.jsonl").read_text(encoding="utf-8").splitlines()]
    assert [event["status"] for event in events] == ["started", "failed"]
    assert (root / "channel-events.jsonl").stat().st_mode & 0o777 == 0o600
    for invalid in (
        {**identity, "sequence": 2, "event": 1, "action": "shell", "status": "complete", "message": "x"},
        {**identity, "sequence": 2, "event": 1, "action": "stop", "status": "complete", "message": "-----BEGIN PRIVATE KEY-----"},
        {**identity, "sequence": 2, "event": 1, "action": "stop", "status": "complete", "message": "-----BEGIN RSA PRIVATE KEY-----"},
        {**identity, "sequence": 2, "event": 1, "action": "stop", "status": "complete", "message": "password=not-a-real-secret"},
    ):
        time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
        try:
            state.event(invalid, session)
            raise AssertionError("invalid event accepted")
        except ValueError:
            pass
    for payload in (
        b'{"schema_version":true,"run_id":"lan-channel-test","source_commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}',
        b'{"schema_version":1,"schema_version":1,"run_id":"lan-channel-test","source_commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}',
    ):
        try:
            channel.decode_json_object(payload, "negative fixture")
            if b'true' not in payload:
                raise AssertionError("duplicate JSON key accepted")
            parsed = channel.decode_json_object(payload, "negative fixture")
            state.poll(parsed, session)
            raise AssertionError("boolean schema version accepted")
        except ValueError:
            pass
    original = root.with_name("state-original")
    replacement = root.with_name("replacement")
    replacement.mkdir()
    root.rename(original)
    root.symlink_to(replacement, target_is_directory=True)
    try:
        time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
        try:
            state.poll(identity, session)
            raise AssertionError("replaced state root accepted")
        except ValueError:
            pass
        assert not (replacement / "channel-events.jsonl").exists()
    finally:
        root.unlink()
        original.rename(root)
    assert os.stat(root / "channel-state.json").st_mode & 0o777 == 0o600

print("lan-interactive-channel-test: PASS")
