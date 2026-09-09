#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0

import importlib.util
import hashlib
import json
import os
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from types import SimpleNamespace
import sys

source = Path(__file__).parents[1] / "interactive_channel.py"
spec = importlib.util.spec_from_file_location("interactive_channel", source)
channel = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(channel)
sys.path.insert(0, str(source.parent))
import lab_runtime


def check(name, value="measured", status="observed", quality="real"):
    return {"check": name, "status": status, "value": value, "evidence_quality": quality}


def server_preflight(run_id, source_commit, server_ip, client_ip):
    checks = {name: check(name) for name in lab_runtime.SERVER_WINDOWS_CHECKS}
    checks.update({
        "preflight_gate": check("preflight_gate", "ready", "pass"),
        "capture_origin": check("capture_origin", "native_windows_powershell", "pass"),
        "network_profile": check("network_profile", "Public", "pass"),
        "clock_offset": check("clock_offset", "0.079", "pass"),
        "mtu": check("mtu", "1500", "pass"),
        "logical_cpu": check("logical_cpu", "8", "pass"),
        "physical_memory_mib": check("physical_memory_mib", "8192", "pass"),
        "free_disk_mib": check("free_disk_mib", "16384", "pass"),
        "wifi_adapter": check("wifi_adapter", "ifindex=11;physical_media=Native 802.11;ndis_medium=9", "pass"),
        "wifi_radio": check("wifi_radio", "802.11ac"),
        "wifi_band": check("wifi_band", "5 GHz", "pass"),
        "expected_wsl_mode_gate": check("expected_wsl_mode_gate", "mirrored", "pass"),
        "docker_publication_inventory": check("docker_publication_inventory", "bounded-scan", "pass"),
    })
    for port in (*lab_runtime.LEGACY_UDP_PORTS, 14433, 19000):
        checks[f"listener_udp_{port}"] = check(f"listener_udp_{port}", "free", "pass")
    for port in lab_runtime.LEGACY_TCP_PORTS:
        checks[f"listener_tcp_{port}"] = check(f"listener_tcp_{port}", "free", "pass")
    return {
        "schema_version": 2, "report_kind": "teremoq-lan-windows-preflight-v2", "run_id": run_id,
        "source_commit": source_commit, "role": "server", "server_ipv4": server_ip, "client_ipv4": client_ip,
        "prefix_length": 24, "network_profile": "Public", "expected_wsl_mode": "mirrored",
        "maximum_clock_offset_ms": 2000, "minimum_mtu": 1280, "minimum_cpu_cores": 2,
        "minimum_memory_mib": 2048, "minimum_disk_mib": 2048,
        "capture_context": {
            "schema_version": 2, "current_process_name": "powershell.exe",
            "parent_process_names": ["windowsterminal.exe", "explorer.exe"], "parent_process_count": 2,
            "traversal_depth_limit": 16, "traversal_outcome": "terminated_parent_pid_nonpositive",
            "wsl_environment_keys_present": [], "powershell_edition": "Desktop", "powershell_version_major": 5,
        },
        "checks": list(checks.values()),
    }


def post(url, body, context, headers=None):
    encoded = json.dumps(body, separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(url, data=encoded, method="POST", headers={"Content-Type": "application/json", **(headers or {})})
    with urllib.request.urlopen(request, context=context, timeout=5) as response:
        assert response.status == 200
        return json.loads(response.read().decode("utf-8"))


commit = "b" * 40
identity = {"schema_version": 1, "run_id": "lan-channel-e2e", "source_commit": commit, "client_commit": commit}
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    certificate = root / "cert.pem"
    private_key = root / "key.pem"
    subprocess.run([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=127.0.0.1",
        "-addext", "subjectAltName=IP:127.0.0.1", "-keyout", str(private_key), "-out", str(certificate),
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    private_key.chmod(0o600)
    fingerprint = hashlib.sha256(ssl.PEM_cert_to_DER_cert(certificate.read_text(encoding="ascii"))).hexdigest()
    fingerprint_path = root / "fingerprint.sha256"
    fingerprint_path.write_text(fingerprint + "\n", encoding="ascii")
    preflight_path = root / "server-preflight.json"
    preflight_path.write_text(json.dumps(server_preflight(
        identity["run_id"], commit, "192.168.77.10", "192.168.77.20"
    )), encoding="utf-8")
    firewall_path = root / "firewall.json"
    firewall = {
        "schema_version": 1, "run_id": identity["run_id"], "source_commit": commit,
        "server_ipv4": "192.168.77.10", "client_ipv4": "192.168.77.20", "network_profile": "Public",
        "protocol": "UDP", "local_port": 14433,
        "classic_rule_name": f"Teremoq-LAN-{identity['run_id']}-Defender-QUIC-UDP-14433",
        "hyperv_rule_name": f"Teremoq-LAN-{identity['run_id']}-HyperV-QUIC-UDP-14433",
        "classic_rule_count": 1, "hyperv_rule_count": 1, "edge_traversal_policy": "Block",
        "firewall_verified": True, "default_inbound_action_changed": False,
        "coordination_tls_port": 18443, "coordination_firewall_verified": True,
    }
    firewall_path.write_text(json.dumps(firewall), encoding="utf-8")
    authorization_path = root / "authorization.json"
    evidence = SimpleNamespace(
        authorization=authorization_path, server_preflight=preflight_path, firewall_attestation=firewall_path,
        fingerprint=fingerprint_path, certificate=certificate, run_id=identity["run_id"], source_commit=commit,
        output=authorization_path,
    )
    channel.create_start_authorization(evidence, "192.168.77.10", "192.168.77.20")
    assert authorization_path.stat().st_mode & 0o777 == 0o600
    channel.verify_start_evidence(evidence, "192.168.77.10", "192.168.77.20")
    tampered = json.loads(authorization_path.read_text(encoding="utf-8"))
    tampered["client_ipv4"] = "192.168.77.21"
    authorization_path.write_text(json.dumps(tampered), encoding="utf-8")
    try:
        channel.verify_start_evidence(evidence, "192.168.77.10", "192.168.77.20")
        raise AssertionError("tampered authorization was accepted")
    except ValueError:
        pass
    authorization_path.unlink()
    channel.create_start_authorization(evidence, "192.168.77.10", "192.168.77.20")
    rollback_path = root / "rollback.json"
    rollback_path.write_text(json.dumps({
        "schema_version": 1, "run_id": identity["run_id"], "source_commit": commit,
        "server_ipv4": "192.168.77.10", "client_ipv4": "192.168.77.20", "quic_udp_port": 14433,
        "coordination_tls_port": 18443, "classic_rules_absent": True, "hyperv_rules_absent": True,
        "default_inbound_action_changed": False, "status": "rolled_back",
    }), encoding="utf-8")
    channel.verify_rollback_evidence(rollback_path, identity["run_id"], commit, "192.168.77.10", "192.168.77.20")
    state_root = root / "state"
    channel.initialize(state_root, identity["run_id"], commit, "127.0.0.1")
    pairing = (state_root / "pairing-code").read_text(encoding="ascii").strip()
    management = (state_root / "management-token").read_text(encoding="ascii").strip()
    state = channel.ChannelState(state_root, identity["run_id"], commit, "127.0.0.1", "127.0.0.1")
    server = channel.BoundedThreadingHTTPServer(("127.0.0.1", 0), channel.make_handler(state))
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
        original_port = channel.PORT
        channel.PORT = server.server_port
        try:
            recovered_pairing = channel.request_pairing_recovery(
                "127.0.0.1", "127.0.0.1", certificate, state_root, identity["run_id"], commit, commit,
            )
        finally:
            channel.PORT = original_port
        assert len(recovered_pairing) == 48
        time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
        try:
            post(url + "/v1/poll", identity, client_context, {"X-Teremoq-Session": session})
            raise AssertionError("recovered channel accepted the revoked session")
        except urllib.error.HTTPError as error:
            assert error.code == 403
        time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
        pair = post(url + "/v1/pair", {
            **identity,
            "pairing_code": recovered_pairing,
        }, client_context)
        session = pair["session"]
        removed_build = {**identity, "management_sequence": 2, "request_id": "1" * 32, "action": "diagnose-build", "parameters": {}}
        try:
            post(url + "/v1/manage", removed_build, client_context, {"X-Teremoq-Management": management})
            raise AssertionError("removed diagnose-build action was accepted")
        except urllib.error.HTTPError as error:
            assert error.code == 403
        management_request = {**identity, "management_sequence": 2, "request_id": "2" * 32, "action": "prepare-client", "parameters": {}}
        managed = post(url + "/v1/manage", management_request, client_context, {"X-Teremoq-Management": management})
        assert managed["accepted"] is True
        time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
        task = post(url + "/v1/poll", identity, client_context, {"X-Teremoq-Session": session})
        assert task["action"] == "prepare-client"
        for event, status in ((1, "started"), (2, "complete")):
            time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
            event_request = {**identity, "sequence": 1, "event": event, "action": "prepare-client", "status": status, "message": status}
            result = post(url + "/v1/event", event_request, client_context, {"X-Teremoq-Session": session})
            assert result["accepted"] is True
        time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
        replay = post(url + "/v1/event", event_request, client_context, {"X-Teremoq-Session": session})
        assert replay["accepted"] is True
        time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
        try:
            post(url + "/v1/event", {**identity, "sequence": 1, "event": 3, "action": "prepare-client", "status": "complete", "message": "replay"}, client_context, {"X-Teremoq-Session": session})
            raise AssertionError("completed task replay was accepted")
        except urllib.error.HTTPError as error:
            assert error.code == 403
        time.sleep(channel.MIN_REQUEST_INTERVAL_SECONDS)
        try:
            post(url + "/v1/event", {**identity, "sequence": 1, "event": 3, "action": "prepare-client", "status": "complete", "message": "password=blocked"}, client_context, {"X-Teremoq-Session": session})
            raise AssertionError("sensitive event message was accepted")
        except urllib.error.HTTPError as error:
            assert error.code == 400
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)

    # Exercise the real pinned daemon boundary. Evidence parsing is covered
    # above; this loader narrows the test to process ownership and cleanup.
    with socket.socket() as port_probe:
        port_probe.bind(("127.0.0.1", 0))
        daemon_port = port_probe.getsockname()[1]
    daemon_root = root / "daemon-state"
    daemon_run_id = "lan-pinned-daemon"
    loader = f'''import importlib.util,sys
p={str(source)!r}
s=importlib.util.spec_from_file_location("interactive_channel_pinned",p)
m=importlib.util.module_from_spec(s)
s.loader.exec_module(m)
m.PORT={daemon_port}
m.exact_private_ipv4=lambda value,label:value
m.validate_server_arguments=lambda *values:None
m.verify_rollback_evidence=lambda *values:None
sys.argv=[p]+sys.argv[2:]
m.main()
'''.encode("utf-8")
    encoded_loader = channel.base64.b64encode(loader).decode("ascii")
    pinned_prefix = [sys.executable, "-I", "-c", channel.PINNED_LOADER_BOOTSTRAP, encoded_loader]
    common = [
        "--state-root", str(daemon_root), "--run-id", daemon_run_id, "--source-commit", commit,
        "--server-ip", "127.0.0.1", "--client-ip", "127.0.0.1",
    ]
    started = subprocess.run(pinned_prefix + [
        "daemon-start", *common, "--port", str(daemon_port), "--certificate", str(certificate),
        "--private-key", str(private_key), "--fingerprint", str(fingerprint_path),
        "--authorization", str(authorization_path), "--server-preflight", str(preflight_path),
        "--firewall-attestation", str(firewall_path),
    ], check=True, text=True, capture_output=True, timeout=10)
    assert "PAIRING_CODE=" in started.stdout
    process_record_path = daemon_root / "channel-process.json"
    original_record = json.loads(process_record_path.read_text(encoding="utf-8"))
    assert original_record["launcher_kind"] == "pinned-loader"
    assert original_record["pinned_loader_sha256"] == hashlib.sha256(loader).hexdigest()
    assert channel.matching_process(original_record, daemon_root)
    state_before_reload = (daemon_root / "channel-state.json").read_bytes()
    management_before_reload = (daemon_root / "management-token").read_bytes()
    reloaded = subprocess.run(
        pinned_prefix + [
            "daemon-reload", "--confirm-reload", *common,
            "--port", str(daemon_port), "--certificate", str(certificate),
            "--private-key", str(private_key), "--fingerprint", str(fingerprint_path),
            "--authorization", str(authorization_path), "--server-preflight", str(preflight_path),
            "--firewall-attestation", str(firewall_path),
        ],
        check=True,
        text=True,
        capture_output=True,
        timeout=10,
    )
    assert "state, credentials and network evidence retained" in reloaded.stdout
    reloaded_record = json.loads(process_record_path.read_text(encoding="utf-8"))
    assert reloaded_record["pid"] != original_record["pid"]
    assert channel.matching_process(reloaded_record, daemon_root)
    assert (daemon_root / "channel-state.json").read_bytes() == state_before_reload
    assert (daemon_root / "management-token").read_bytes() == management_before_reload
    original_record = reloaded_record
    status_command = pinned_prefix + ["status", *common]
    subprocess.run(status_command, check=True, text=True, capture_output=True, timeout=10)
    for field in ("command_sha256", "pinned_loader_sha256"):
        tampered_record = dict(original_record)
        tampered_record[field] = "0" * 64
        process_record_path.write_text(json.dumps(tampered_record), encoding="utf-8")
        process_record_path.chmod(0o600)
        rejected = subprocess.run(status_command, text=True, capture_output=True, timeout=10)
        assert rejected.returncode != 0
        process_record_path.write_text(json.dumps(original_record), encoding="utf-8")
        process_record_path.chmod(0o600)
    stopped = subprocess.run(
        pinned_prefix + ["daemon-stop", *common, "--attestation", str(rollback_path)],
        check=True, text=True, capture_output=True, timeout=10,
    )
    assert "credentials removed" in stopped.stdout
    assert not channel.matching_process(original_record, daemon_root)
    for removed in ("channel-process.json", "pairing-code", "management-token"):
        assert not (daemon_root / removed).exists()
    try:
        os.kill(original_record["pid"], 0)
        raise AssertionError("pinned coordination process survived daemon-stop")
    except ProcessLookupError:
        pass

    failed_root = root / "failed-daemon-state"
    failed_arguments = SimpleNamespace(
        state_root=failed_root, run_id="lan-failed-daemon", source_commit=commit,
        certificate=certificate, private_key=private_key, fingerprint=fingerprint_path,
        authorization=authorization_path, server_preflight=preflight_path,
        firewall_attestation=firewall_path,
    )
    original_validate = channel.validate_server_arguments
    original_command = channel.daemon_server_command
    channel.validate_server_arguments = lambda *_values: None
    channel.daemon_server_command = lambda *_values: [sys.executable, "-c", "raise SystemExit(7)"]
    try:
        try:
            channel.daemon_start(failed_arguments, "127.0.0.1", "127.0.0.1")
            raise AssertionError("failed daemon startup was accepted")
        except (FileNotFoundError, ProcessLookupError, ValueError):
            pass
        assert not failed_root.exists()
    finally:
        channel.validate_server_arguments = original_validate
        channel.daemon_server_command = original_command

    failed_cleanup_root = root / "failed-cleanup-state"
    failed_cleanup_arguments = SimpleNamespace(**{
        **vars(failed_arguments), "state_root": failed_cleanup_root, "run_id": "lan-failed-cleanup",
    })
    original_remove_root = channel.remove_new_state_root
    channel.validate_server_arguments = lambda *_values: None
    channel.daemon_server_command = lambda *_values: [sys.executable, "-c", "raise SystemExit(8)"]
    channel.remove_new_state_root = lambda *_values: (_ for _ in ()).throw(ValueError("forced cleanup failure"))
    try:
        try:
            channel.daemon_start(failed_cleanup_arguments, "127.0.0.1", "127.0.0.1")
            raise AssertionError("failed internal cleanup was accepted")
        except (FileNotFoundError, ProcessLookupError, ValueError):
            pass
        assert failed_cleanup_root.exists()
        try:
            channel.verify_channel_root_absent(failed_cleanup_root)
            raise AssertionError("residual failed-start root was reported absent")
        except ValueError:
            pass
    finally:
        channel.validate_server_arguments = original_validate
        channel.daemon_server_command = original_command
        channel.remove_new_state_root = original_remove_root
        if failed_cleanup_root.exists():
            cleanup_descriptor = channel.open_state_root(failed_cleanup_root)
            try:
                original_remove_root(failed_cleanup_root, cleanup_descriptor)
            finally:
                os.close(cleanup_descriptor)

    saved_authorization = authorization_path.with_name("authorization.verified")
    original_rename = channel.os.rename
    replacement_moved = [False]

    def replace_at_atomic_move(source_name, destination_name, **keywords):
        if source_name == authorization_path.name and not replacement_moved[0]:
            original_rename(source_name, saved_authorization.name, **keywords)
            directory = keywords["src_dir_fd"]
            foreign = os.open(source_name, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600, dir_fd=directory)
            try:
                os.write(foreign, b"{}\n")
            finally:
                os.close(foreign)
            replacement_moved[0] = True
        return original_rename(source_name, destination_name, **keywords)

    channel.os.rename = replace_at_atomic_move
    try:
        try:
            channel.revoke_start_authorization(evidence, "192.168.77.10", "192.168.77.20")
            raise AssertionError("replaced authorization was deleted")
        except ValueError:
            pass
    finally:
        channel.os.rename = original_rename
    quarantined = list(root.glob(".authorization.json.revoke-*"))
    assert replacement_moved[0] and saved_authorization.exists() and len(quarantined) == 1
    assert quarantined[0].read_text(encoding="utf-8") == "{}\n"
    try:
        channel.revoke_start_authorization(evidence, "192.168.77.10", "192.168.77.20")
        raise AssertionError("foreign orphan quarantine was ignored")
    except ValueError:
        pass
    assert quarantined[0].exists()
    quarantined[0].unlink()
    saved_authorization.rename(authorization_path)

    coexist_quarantine = root / (".authorization.json.revoke-" + "1" * 32)
    coexist_quarantine.write_bytes(authorization_path.read_bytes())
    coexist_quarantine.chmod(0o600)
    try:
        channel.revoke_start_authorization(evidence, "192.168.77.10", "192.168.77.20")
        raise AssertionError("authorization plus quarantine was accepted")
    except ValueError:
        pass
    assert authorization_path.exists() and coexist_quarantine.exists()
    coexist_quarantine.unlink()

    owned_quarantine = root / (".authorization.json.revoke-" + "2" * 32)
    authorization_path.rename(owned_quarantine)
    channel.revoke_start_authorization(evidence, "192.168.77.10", "192.168.77.20")
    assert not authorization_path.exists() and not owned_quarantine.exists()

    channel.create_start_authorization(evidence, "192.168.77.10", "192.168.77.20")
    authorization_bytes = authorization_path.read_bytes()
    recovery_quarantine = root / (".authorization.json.revoke-" + "5" * 32)
    authorization_path.rename(recovery_quarantine)
    original_unlink = channel.os.unlink

    def recreate_during_recovery(name, **keywords):
        result = original_unlink(name, **keywords)
        if name == recovery_quarantine.name:
            directory = keywords["dir_fd"]
            recreated = os.open(
                authorization_path.name, os.O_CREAT | os.O_EXCL | os.O_WRONLY,
                0o600, dir_fd=directory,
            )
            try:
                os.write(recreated, authorization_bytes)
            finally:
                os.close(recreated)
        return result

    channel.os.unlink = recreate_during_recovery
    try:
        try:
            channel.revoke_start_authorization(evidence, "192.168.77.10", "192.168.77.20")
            raise AssertionError("authorization recreated during recovery was accepted")
        except ValueError:
            pass
    finally:
        channel.os.unlink = original_unlink
    assert authorization_path.exists() and not recovery_quarantine.exists()
    channel.revoke_start_authorization(evidence, "192.168.77.10", "192.168.77.20")

    multiple_quarantines = [
        root / (".authorization.json.revoke-" + character * 32) for character in ("3", "4")
    ]
    for quarantine in multiple_quarantines:
        quarantine.write_text("{}\n", encoding="utf-8")
        quarantine.chmod(0o600)
    try:
        channel.revoke_start_authorization(evidence, "192.168.77.10", "192.168.77.20")
        raise AssertionError("multiple authorization quarantines were accepted")
    except ValueError:
        pass
    assert all(quarantine.exists() for quarantine in multiple_quarantines)
    for quarantine in multiple_quarantines:
        quarantine.unlink()

    bounded_entries = [root / f"bounded-entry-{index:03d}" for index in range(257)]
    for entry in bounded_entries:
        entry.write_text("x", encoding="ascii")
    try:
        channel.revoke_start_authorization(evidence, "192.168.77.10", "192.168.77.20")
        raise AssertionError("authorization directory entry bound was not enforced")
    except ValueError:
        pass
    for entry in bounded_entries:
        entry.unlink()
    channel.revoke_start_authorization(evidence, "192.168.77.10", "192.168.77.20")

print("lan-interactive-channel-e2e-test: PASS")
