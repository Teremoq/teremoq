#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0

import importlib.util
import json
import ssl
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

source = Path(__file__).parents[1] / "interactive_channel.py"
spec = importlib.util.spec_from_file_location("interactive_channel", source)
channel = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(channel)


def post(url, body, context, headers=None):
    encoded = json.dumps(body, separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(url, data=encoded, method="POST", headers={"Content-Type": "application/json", **(headers or {})})
    with urllib.request.urlopen(request, context=context, timeout=5) as response:
        assert response.status == 200
        return json.loads(response.read().decode("utf-8"))


commit = "b" * 40
identity = {"schema_version": 1, "run_id": "lan-channel-e2e", "source_commit": commit}
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    certificate = root / "cert.pem"
    private_key = root / "key.pem"
    subprocess.run([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=127.0.0.1",
        "-addext", "subjectAltName=IP:127.0.0.1", "-keyout", str(private_key), "-out", str(certificate),
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    private_key.chmod(0o600)
    state_root = root / "state"
    channel.initialize(state_root, identity["run_id"], commit, "127.0.0.1")
    pairing = (state_root / "pairing-code").read_text(encoding="ascii").strip()
    management = (state_root / "management-token").read_text(encoding="ascii").strip()
    state = channel.ChannelState(state_root, identity["run_id"], commit, "127.0.0.1", "127.0.0.1")
    server = channel.ThreadingHTTPServer(("127.0.0.1", 0), channel.make_handler(state))
    tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls_context.load_cert_chain(certificate, private_key)
    server.socket = tls_context.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f"https://127.0.0.1:{server.server_port}"
    client_context = ssl.create_default_context(cafile=str(certificate))
    try:
        pair = post(url + "/v1/pair", {**identity, "pairing_code": pairing}, client_context)
        session = pair["session"]
        managed = post(url + "/v1/manage", {**identity, "action": "diagnose-build"}, client_context, {"X-Teremoq-Management": management})
        assert managed["accepted"] is True
        time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
        task = post(url + "/v1/poll", identity, client_context, {"X-Teremoq-Session": session})
        assert task["action"] == "diagnose-build"
        for event, status in ((1, "started"), (2, "complete")):
            time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
            result = post(url + "/v1/event", {**identity, "sequence": 1, "event": event, "action": "diagnose-build", "status": status, "message": status}, client_context, {"X-Teremoq-Session": session})
            assert result["accepted"] is True
        time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
        try:
            post(url + "/v1/event", {**identity, "sequence": 1, "event": 3, "action": "diagnose-build", "status": "complete", "message": "replay"}, client_context, {"X-Teremoq-Session": session})
            raise AssertionError("completed task replay was accepted")
        except urllib.error.HTTPError as error:
            assert error.code == 403
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)

print("lan-interactive-channel-e2e-test: PASS")
