#!/usr/bin/env python3
"""Narrow tests for relay deploy/test support scripts.

These tests do not touch the network. They verify safe defaults, token redaction,
and relay frame construction for the helper scripts in this directory.
"""

from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import struct
import subprocess
import sys

sys.dont_write_bytecode = True

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
LATENCY = SCRIPTS / "measure-relay-ws-latency.py"
CF_MODE = SCRIPTS / "cloudflare-relay-mode.sh"


def load_latency_module():
    spec = importlib.util.spec_from_file_location("measure_relay_ws_latency", LATENCY)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def test_relay_frame_is_big_endian_length_header_json_and_opaque_payload():
    module = load_latency_module()
    payload = b"opaque\x00payload"
    frame = module.build_relay_frame(
        request_id="req-123",
        client_id="client-a",
        direction="client_to_server",
        payload=payload,
        message_type="probe",
    )

    header_len = struct.unpack("!I", frame[:4])[0]
    header = json.loads(frame[4 : 4 + header_len])

    assert header == {
        "v": 1,
        "type": "probe",
        "requestId": "req-123",
        "clientId": "client-a",
        "direction": "client_to_server",
    }
    assert frame[4 + header_len :] == payload


def test_upgrade_request_contains_authorization_but_log_redaction_hides_token():
    module = load_latency_module()
    token = "secret-token-value"
    request = module.build_upgrade_request(
        host="relay.example.test",
        target="/ws?role=client&serverId=s&clientId=c&v=1",
        token=token,
        websocket_key="dGVzdGtleTEyMzQ1Ng==",
    )

    assert f"Authorization: Bearer {token}\r\n" in request
    assert token not in module.redact_token(token)
    assert token not in module.safe_url("wss://relay.example.test/ws?token=secret-token-value")
    assert token not in module.safe_url("wss://secret-token-value@example.test/ws")


def test_cloudflare_mode_script_reports_missing_env_without_leaking_present_token():
    env = {key: value for key, value in os.environ.items() if not key.startswith("CF_")}
    env.pop("ALI_VPS_IP", None)
    env["CF_API_TOKEN"] = "should-not-appear"

    result = subprocess.run(
        [str(CF_MODE), "orange"],
        cwd=str(ROOT),
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )

    assert result.returncode != 0
    assert "CF_ZONE_ID" in result.stdout
    assert "CF_RECORD_ID" in result.stdout
    assert "ALI_VPS_IP" in result.stdout
    assert "should-not-appear" not in result.stdout



def test_latency_probe_requires_relay_token_from_environment_without_argv_path():
    latency_source = LATENCY.read_text()
    env = {key: value for key, value in os.environ.items() if key != "ORCA_RELAY_TOKEN"}
    env["ORCA_RELAY_WS_URL"] = "wss://relay.example.test/ws"

    result = subprocess.run(
        [sys.executable, str(LATENCY)],
        cwd=str(ROOT),
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )

    assert result.returncode == 2
    assert "ORCA_RELAY_TOKEN" in result.stdout
    assert "--token" not in result.stdout
    assert "--token" not in latency_source


def test_compare_script_invokes_latency_probe_without_token_argv():
    compare = (SCRIPTS / "compare-cloudflare-relay-latency.sh").read_text()

    assert "ORCA_RELAY_TOKEN" in compare
    assert "--token" not in compare
    assert 'scripts/measure-relay-ws-latency.py --url "$URL"' in compare

def main() -> int:
    tests = [
        test_relay_frame_is_big_endian_length_header_json_and_opaque_payload,
        test_upgrade_request_contains_authorization_but_log_redaction_hides_token,
        test_cloudflare_mode_script_reports_missing_env_without_leaking_present_token,
        test_latency_probe_requires_relay_token_from_environment_without_argv_path,
        test_compare_script_invokes_latency_probe_without_token_argv,
    ]
    failures = 0
    for test in tests:
        try:
            test()
            print(f"ok {test.__name__}")
        except Exception as exc:  # noqa: BLE001 - simple dependency-free test runner
            failures += 1
            print(f"not ok {test.__name__}: {exc}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
