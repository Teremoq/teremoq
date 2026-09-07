#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0

import importlib.util
import base64
import json
import os
import sys
import tempfile
import time
from types import SimpleNamespace
from pathlib import Path

source = Path(__file__).parents[1] / "interactive_channel.py"
spec = importlib.util.spec_from_file_location("interactive_channel", source)
channel = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(channel)

commit = "a" * 40
assert channel.process_start_ticks(os.getpid()) > 0

pinned_loader = b"print('pinned loader canary')"
encoded_loader = base64.b64encode(pinned_loader).decode("ascii")
pinned_prefix = channel.daemon_child_prefix([
    sys.executable, "-I", "-c", channel.PINNED_LOADER_BOOTSTRAP, encoded_loader,
    "daemon-start", "--state-root", "/private/state",
])
assert pinned_prefix == [
    sys.executable, "-I", "-c", channel.PINNED_LOADER_BOOTSTRAP, encoded_loader,
]
assert pinned_prefix + ["serve-fd"] == [
    sys.executable, "-I", "-c", channel.PINNED_LOADER_BOOTSTRAP, encoded_loader, "serve-fd",
]
server_arguments = SimpleNamespace(
    state_root=Path("/private/state"), run_id="lan-pinned-command",
    source_commit="a" * 40, certificate=Path("/private/cert.pem"),
    private_key=Path("/private/key.pem"), fingerprint=Path("/private/fingerprint.sha256"),
    authorization=Path("/private/authorization.json"),
    server_preflight=Path("/private/server-preflight.json"),
    firewall_attestation=Path("/private/firewall.json"),
)
server_command = channel.daemon_server_command(server_arguments, 7, "192.168.77.10", "192.168.77.20", [
    sys.executable, "-I", "-c", channel.PINNED_LOADER_BOOTSTRAP, encoded_loader, "daemon-start",
])
assert server_command[:5] == pinned_prefix and server_command[5] == "serve-fd"
assert server_command.count(encoded_loader) == 1 and server_command.count("serve-fd") == 1
assert server_command[server_command.index("--state-fd") + 1] == "7"
assert server_command[server_command.index("--source-commit") + 1] == "a" * 40
assert server_command[server_command.index("--server-ip") + 1] == "192.168.77.10"
assert server_command[server_command.index("--client-ip") + 1] == "192.168.77.20"
process_identity = channel.pinned_process_identity(server_command, Path("/private/state"))
assert process_identity is not None
assert process_identity["launcher_kind"] == "pinned-loader"
assert process_identity["command_sha256"] == channel.hashlib.sha256(
    channel.process_command_bytes(server_command)
).hexdigest()
assert process_identity["pinned_loader_sha256"] == channel.hashlib.sha256(pinned_loader).hexdigest()
for index, replacement in (
    (2, "import sys"),
    (4, base64.b64encode(b"print('different loader')").decode("ascii")),
    (server_command.index("--state-root") + 1, "/private/other-state"),
):
    tampered_command = list(server_command)
    tampered_command[index] = replacement
    try:
        identity = channel.pinned_process_identity(tampered_command, Path("/private/state"))
        if identity == process_identity:
            raise AssertionError("tampered pinned process identity was accepted")
    except ValueError:
        pass
for invalid_loader in ("not-base64!", base64.b64encode(b"x" * (channel.MAX_PINNED_LOADER_BYTES + 1)).decode("ascii")):
    try:
        channel.daemon_child_prefix([
            sys.executable, "-I", "-c", channel.PINNED_LOADER_BOOTSTRAP, invalid_loader,
        ])
        raise AssertionError("invalid pinned loader was accepted")
    except ValueError:
        pass
assert channel.daemon_child_prefix([sys.executable, str(Path(channel.__file__))]) == [
    sys.executable, str(Path(channel.__file__).resolve()),
]
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary) / "state"
    channel.initialize(root, "lan-channel-test", commit, "192.168.77.20")
    assert root.stat().st_mode & 0o777 == 0o700
    pairing = (root / "pairing-code").read_text(encoding="ascii").strip()
    state = channel.ChannelState(root, "lan-channel-test", commit, "192.168.77.10", "192.168.77.20")
    identity = {"schema_version": 1, "run_id": "lan-channel-test", "source_commit": commit, "client_commit": commit}
    response = state.pair({**identity, "pairing_code": pairing})
    session = response["session"]
    assert not (root / "pairing-code").exists()
    time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
    assert state.poll(identity, session)["action"] == "wait"
    management = (root / "management-token").read_text(encoding="ascii").strip()
    time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
    invalid_first = {**identity, "management_sequence": 1, "request_id": "0" * 32, "action": "load-25", "parameters": {}}
    try:
        state.enqueue(invalid_first, management)
        raise AssertionError("progressive gate accepted load-25 as the first action")
    except ValueError:
        pass
    time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
    removed_build = {**identity, "management_sequence": 1, "request_id": "f" * 32, "action": "diagnose-build", "parameters": {}}
    try:
        state.enqueue(removed_build, management)
        raise AssertionError("removed diagnose-build action was accepted")
    except ValueError:
        pass
    management_request = {**identity, "management_sequence": 1, "request_id": "1" * 32, "action": "prepare-client", "parameters": {}}
    assert state.enqueue(management_request, management)["accepted"] is True
    reloaded = channel.ChannelState(root, "lan-channel-test", commit, "192.168.77.10", "192.168.77.20")
    assert reloaded.document["management_sequence"] == 1
    assert reloaded.document["last_management_request"] == "1" * 32
    assert reloaded.document["tasks"][0]["management_request_id"] == "1" * 32
    time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
    assert state.poll(identity, session)["action"] == "prepare-client"
    first = {**identity, "sequence": 1, "event": 1, "action": "prepare-client", "status": "started", "message": "preparation started"}
    time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
    assert state.event(first, session)["accepted"] is True
    event_log_size = (root / "channel-events.jsonl").stat().st_size
    time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
    assert state.event(first, session)["accepted"] is True
    assert (root / "channel-events.jsonl").stat().st_size == event_log_size
    time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
    try:
        state.event({**first, "message": "modified replay"}, session)
        raise AssertionError("modified event replay accepted")
    except ValueError:
        pass
    time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
    stop_request = {**identity, "management_sequence": 2, "request_id": "2" * 32, "action": "stop", "parameters": {}}
    cancellation = state.enqueue(stop_request, management)
    assert cancellation["action"] == "stop" and cancellation["cancellation_sequence"] == 1
    complete = {**first, "event": 2, "status": "failed", "message": "bounded diagnostic"}
    time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
    assert state.event(complete, session)["cancel_requested"] is True
    completed_log_size = (root / "channel-events.jsonl").stat().st_size
    time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
    assert state.event(complete, session)["cancel_requested"] is True
    assert (root / "channel-events.jsonl").stat().st_size == completed_log_size
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

    original_getfqdn = channel.socket.getfqdn
    server = None
    channel.socket.getfqdn = lambda _address: (_ for _ in ()).throw(AssertionError("reverse DNS lookup attempted"))
    try:
        server = channel.BoundedThreadingHTTPServer(("127.0.0.1", 0), channel.make_handler(state))
        assert server.server_name == "127.0.0.1"
        assert server.server_port == server.server_address[1]
    finally:
        if server is not None:
            server.server_close()
        channel.socket.getfqdn = original_getfqdn

    update_root = Path(temporary) / "update-state"
    target = "b" * 40
    channel.initialize(update_root, "lan-update-test", commit, "192.168.77.20")
    update_pairing = (update_root / "pairing-code").read_text(encoding="ascii").strip()
    update_management = (update_root / "management-token").read_text(encoding="ascii").strip()
    update_state = channel.ChannelState(update_root, "lan-update-test", commit, "192.168.77.10", "192.168.77.20")
    update_identity = {"schema_version": 1, "run_id": "lan-update-test", "source_commit": commit, "client_commit": commit}
    update_session = update_state.pair({**update_identity, "pairing_code": update_pairing})["session"]
    parameters = {
        "repository_url": channel.UPDATE_REPOSITORY_URL,
        "repository_ref": channel.UPDATE_REPOSITORY_REF,
        "target_commit": target,
    }
    for invalid_parameters in (
        {**parameters, "repository_url": "https://example.invalid/repository"},
        {**parameters, "repository_ref": "refs/heads/main"},
        {**parameters, "target_commit": commit},
        {**parameters, "extra": "forbidden"},
    ):
        time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
        try:
            update_state.enqueue({**update_identity, "management_sequence": 1, "request_id": "4" * 32,
                "action": "update-client", "parameters": invalid_parameters}, update_management)
            raise AssertionError("invalid update parameters were accepted")
        except ValueError:
            pass
    time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
    update_request = {**update_identity, "management_sequence": 1, "request_id": "3" * 32,
                      "action": "update-client", "parameters": parameters}
    assert update_state.enqueue(update_request, update_management)["accepted"] is True
    time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
    update_task = update_state.poll(update_identity, update_session)
    assert update_task["action"] == "update-client" and update_task["parameters"] == parameters
    for event, status in ((1, "started"), (2, "complete")):
        time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
        transition = update_state.event({**update_identity, "sequence": 1, "event": event,
            "action": "update-client", "status": status, "message": status}, update_session)
    assert transition["source_commit"] == commit and transition["client_commit"] == target
    new_identity = {**update_identity, "client_commit": target}
    time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
    assert update_state.poll(new_identity, update_session)["action"] == "wait"
    reloaded_update = channel.ChannelState(update_root, "lan-update-test", commit, "192.168.77.10", "192.168.77.20")
    assert reloaded_update.document["source_commit"] == commit
    assert reloaded_update.document["client_commit"] == target
    try:
        time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
        update_state.poll(update_identity, update_session)
        raise AssertionError("old source identity remained valid after update")
    except ValueError:
        pass

print("lan-interactive-channel-test: PASS")
