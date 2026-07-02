#!/usr/bin/env python3
"""Measure WebSocket relay endpoint latency phases without logging secrets.

The script performs a direct TCP/TLS/WebSocket client probe against a relay
`wss://.../ws` URL. It optionally sends one relay-format binary probe frame
and measures the first matching reply when a server-side relay peer is present.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import secrets
import socket
import ssl
import struct
import sys
import time
import urllib.parse
from dataclasses import dataclass
from typing import Any

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
DEFAULT_PAYLOAD = b"orca-relay-latency-probe"


@dataclass(frozen=True)
class Phase:
    name: str
    ms: float


def redact_token(value: str | None) -> str:
    if not value:
        return "<missing>"
    if len(value) <= 8:
        return "<redacted>"
    return f"{value[:3]}...{value[-3:]}"


def safe_url(url: str) -> str:
    parsed = urllib.parse.urlsplit(url)
    query = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
    redacted_query = []
    secret_keys = {"token", "access_token", "authorization", "auth", "key"}
    for key, value in query:
        redacted_query.append((key, "<redacted>" if key.lower() in secret_keys else value))
    hostname = parsed.hostname or ""
    if parsed.port:
        netloc = f"{hostname}:{parsed.port}"
    else:
        netloc = hostname
    return urllib.parse.urlunsplit(
        (
            parsed.scheme,
            netloc,
            parsed.path,
            urllib.parse.urlencode(redacted_query),
            parsed.fragment,
        )
    )


def build_relay_frame(
    *,
    request_id: str,
    client_id: str,
    direction: str,
    payload: bytes = DEFAULT_PAYLOAD,
    message_type: str = "probe",
) -> bytes:
    header = {
        "v": 1,
        "type": message_type,
        "requestId": request_id,
        "clientId": client_id,
        "direction": direction,
    }
    header_json = json.dumps(header, separators=(",", ":")).encode("utf-8")
    return struct.pack("!I", len(header_json)) + header_json + payload


def parse_relay_frame(frame: bytes) -> tuple[dict[str, Any], bytes]:
    if len(frame) < 4:
        raise ValueError("frame shorter than 4-byte header length")
    header_len = struct.unpack("!I", frame[:4])[0]
    if len(frame) < 4 + header_len:
        raise ValueError("frame shorter than declared header length")
    header = json.loads(frame[4 : 4 + header_len].decode("utf-8"))
    payload = frame[4 + header_len :]
    return header, payload


def build_upgrade_request(*, host: str, target: str, token: str, websocket_key: str) -> str:
    return (
        f"GET {target} HTTP/1.1\r\n"
        f"Host: {host}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {websocket_key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        f"Authorization: Bearer {token}\r\n"
        "User-Agent: orca-relay-latency-probe/1\r\n"
        "\r\n"
    )


def recv_until(sock: socket.socket, marker: bytes, timeout_s: float) -> bytes:
    sock.settimeout(timeout_s)
    chunks: list[bytes] = []
    total = 0
    while marker not in b"".join(chunks):
        chunk = sock.recv(4096)
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
        if total > 65536:
            raise RuntimeError("HTTP upgrade response exceeded 64 KiB")
    return b"".join(chunks)


def encode_ws_frame(payload: bytes, opcode: int = 0x2) -> bytes:
    first = 0x80 | opcode
    mask_bit = 0x80
    length = len(payload)
    if length < 126:
        header = bytes([first, mask_bit | length])
    elif length <= 0xFFFF:
        header = bytes([first, mask_bit | 126]) + struct.pack("!H", length)
    else:
        header = bytes([first, mask_bit | 127]) + struct.pack("!Q", length)
    mask = secrets.token_bytes(4)
    masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    return header + mask + masked


def recv_exact(sock: socket.socket, n: int, timeout_s: float) -> bytes:
    sock.settimeout(timeout_s)
    chunks: list[bytes] = []
    remaining = n
    while remaining:
        chunk = sock.recv(remaining)
        if not chunk:
            raise ConnectionError("connection closed while reading WebSocket frame")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def read_ws_frame(sock: socket.socket, timeout_s: float) -> tuple[int, bytes]:
    header = recv_exact(sock, 2, timeout_s)
    first, second = header
    opcode = first & 0x0F
    masked = bool(second & 0x80)
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", recv_exact(sock, 2, timeout_s))[0]
    elif length == 127:
        length = struct.unpack("!Q", recv_exact(sock, 8, timeout_s))[0]
    mask = recv_exact(sock, 4, timeout_s) if masked else b""
    payload = recv_exact(sock, length, timeout_s) if length else b""
    if masked:
        payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    return opcode, payload


def ensure_client_query(url: str, client_id: str) -> str:
    parsed = urllib.parse.urlsplit(url)
    query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
    query.setdefault("role", ["client"])
    query.setdefault("clientId", [client_id])
    query.setdefault("v", ["1"])
    return urllib.parse.urlunsplit(
        (
            parsed.scheme,
            parsed.netloc,
            parsed.path or "/ws",
            urllib.parse.urlencode(query, doseq=True),
            parsed.fragment,
        )
    )


def measure(url: str, token: str, *, timeout_s: float, request_id: str, client_id: str) -> tuple[list[Phase], dict[str, Any]]:
    parsed = urllib.parse.urlsplit(ensure_client_query(url, client_id))
    if parsed.scheme != "wss":
        raise ValueError("url must use wss://")
    if not parsed.hostname:
        raise ValueError("url must include a host")
    port = parsed.port or 443
    host_header = parsed.netloc
    target = urllib.parse.urlunsplit(("", "", parsed.path or "/ws", parsed.query, ""))
    phases: list[Phase] = []

    t0 = time.perf_counter()
    raw_sock = socket.create_connection((parsed.hostname, port), timeout=timeout_s)
    phases.append(Phase("tcp_connect", (time.perf_counter() - t0) * 1000))

    try:
        ctx = ssl.create_default_context()
        t1 = time.perf_counter()
        tls_sock = ctx.wrap_socket(raw_sock, server_hostname=parsed.hostname)
        phases.append(Phase("tls_handshake", (time.perf_counter() - t1) * 1000))
    except Exception:
        raw_sock.close()
        raise

    websocket_key = base64.b64encode(secrets.token_bytes(16)).decode("ascii")
    request = build_upgrade_request(host=host_header, target=target, token=token, websocket_key=websocket_key)
    t2 = time.perf_counter()
    tls_sock.sendall(request.encode("ascii"))
    response = recv_until(tls_sock, b"\r\n\r\n", timeout_s)
    phases.append(Phase("ws_open", (time.perf_counter() - t2) * 1000))

    status_line = response.split(b"\r\n", 1)[0].decode("iso-8859-1", errors="replace")
    if not status_line.startswith("HTTP/1.1 101") and not status_line.startswith("HTTP/1.0 101"):
        tls_sock.close()
        raise RuntimeError(f"WebSocket upgrade failed: {status_line}")

    probe = build_relay_frame(
        request_id=request_id,
        client_id=client_id,
        direction="client_to_server",
        payload=DEFAULT_PAYLOAD,
        message_type="probe",
    )
    t3 = time.perf_counter()
    tls_sock.sendall(encode_ws_frame(probe))
    details: dict[str, Any] = {"requestId": request_id, "clientId": client_id}
    try:
        opcode, payload = read_ws_frame(tls_sock, timeout_s)
        phases.append(Phase("relay_round_trip", (time.perf_counter() - t3) * 1000))
        details["replyOpcode"] = opcode
        if opcode == 0x2:
            header, reply_payload = parse_relay_frame(payload)
            details["replyHeader"] = header
            details["replyPayloadBytes"] = len(reply_payload)
        else:
            details["replyPayloadBytes"] = len(payload)
    except socket.timeout:
        details["relayRoundTrip"] = "timeout waiting for server reply"
    finally:
        try:
            tls_sock.sendall(encode_ws_frame(b"", opcode=0x8))
        except OSError:
            pass
        tls_sock.close()

    return phases, details


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Measure orca-relay WebSocket endpoint latency phases")
    parser.add_argument("--url", default=os.environ.get("ORCA_RELAY_WS_URL"), help="wss://.../ws URL; may also use ORCA_RELAY_WS_URL")
    parser.add_argument("--timeout", type=float, default=float(os.environ.get("ORCA_RELAY_TIMEOUT", "10")), help="Per-phase timeout seconds")
    parser.add_argument("--client-id", default=os.environ.get("ORCA_RELAY_CLIENT_ID", f"latency-{os.getpid()}"))
    parser.add_argument("--request-id", default=os.environ.get("ORCA_RELAY_REQUEST_ID", secrets.token_hex(8)))
    args = parser.parse_args(argv)

    token = os.environ.get("ORCA_RELAY_TOKEN")
    missing = []
    if not args.url:
        missing.append("ORCA_RELAY_WS_URL or --url")
    if not token:
        missing.append("ORCA_RELAY_TOKEN")
    if missing:
        print("Missing required inputs:", file=sys.stderr)
        for item in missing:
            print(f"  - {item}", file=sys.stderr)
        print("Example: ORCA_RELAY_WS_URL=wss://relay-orca.example/ws ORCA_RELAY_TOKEN=... scripts/measure-relay-ws-latency.py", file=sys.stderr)
        return 2

    assert args.url is not None
    assert token is not None
    print(f"endpoint={safe_url(args.url)}")
    print(f"token={redact_token(token)}")
    try:
        phases, details = measure(args.url, token, timeout_s=args.timeout, request_id=args.request_id, client_id=args.client_id)
    except Exception as exc:  # noqa: BLE001 - CLI should report concise failure
        print(f"error={exc}", file=sys.stderr)
        return 1

    for phase in phases:
        print(f"{phase.name}_ms={phase.ms:.2f}")
    print("details=" + json.dumps(details, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
