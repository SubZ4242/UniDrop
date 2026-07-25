#!/usr/bin/env python3
"""Probe the running UniDrop /Discover endpoint over its scoped AWDL address."""

from __future__ import annotations

import argparse
import http.client
import json
import plistlib
import socket
import ssl
from pathlib import Path


IPV6_BOUND_IF = 125


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("state_file", type=Path)
    args = parser.parse_args()
    state = json.loads(args.state_file.read_text(encoding="utf-8"))
    address = state["ipv6_address"].split("%", 1)[0]
    interface_index = int(state["interface_index"])
    port = int(state["port"])

    body = plistlib.dumps({"UniDropProbe": True}, fmt=plistlib.FMT_BINARY)
    raw_socket = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    raw_socket.settimeout(5)
    raw_socket.setsockopt(
        socket.IPPROTO_IPV6,
        IPV6_BOUND_IF,
        interface_index,
    )
    raw_socket.connect((address, port, 0, interface_index))

    tls_context = ssl.create_default_context()
    tls_context.check_hostname = False
    tls_context.verify_mode = ssl.CERT_NONE
    with tls_context.wrap_socket(
        raw_socket,
        server_hostname=state["bonjour_host"].rstrip("."),
    ) as tls_socket:
        headers = (
            "POST /Discover HTTP/1.1\r\n"
            f"Host: {state['bonjour_host']}\r\n"
            "User-Agent: UniDrop-Probe/0.1\r\n"
            "Transfer-Encoding: chunked\r\n"
            "Connection: close\r\n\r\n"
        ).encode("ascii")
        request_body = (
            f"{len(body):x}\r\n".encode("ascii")
            + body
            + b"\r\n0\r\n\r\n"
        )
        tls_socket.sendall(headers + request_body)
        response = http.client.HTTPResponse(tls_socket)
        response.begin()
        payload = response.read()
        parsed = plistlib.loads(payload)

    print(f"HTTP status: {response.status}")
    print(f"ReceiverComputerName: {parsed.get('ReceiverComputerName')}")
    print(f"ReceiverModelName: {parsed.get('ReceiverModelName')}")
    capabilities = parsed.get("ReceiverMediaCapabilities", b"")
    print(f"ReceiverMediaCapabilities: {capabilities.decode('utf-8', errors='replace')}")

    loopback_socket = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    loopback_socket.settimeout(1)
    try:
        loopback_socket.connect(("::1", port, 0, 0))
    except OSError:
        print("Loopback isolation: blocked as expected")
    else:
        print("Loopback isolation: FAILED")
        return 1
    finally:
        loopback_socket.close()

    return 0 if response.status == 200 else 1


if __name__ == "__main__":
    raise SystemExit(main())

