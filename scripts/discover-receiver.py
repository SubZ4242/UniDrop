#!/usr/bin/env -S PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin python3
"""Find a UniDrop receiver on the local /24 LAN by probing /health."""

from __future__ import annotations

import argparse
import concurrent.futures
import http.client
import ipaddress
import json
import socket
import subprocess
from dataclasses import dataclass


@dataclass(frozen=True)
class ProbeResult:
    ip: str
    receiver: str
    platform: str


def local_ip() -> str | None:
    candidates: list[str] = []
    try:
        route = subprocess.run(
            ["/sbin/route", "-n", "get", "default"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        interface = None
        for line in route.splitlines():
            fields = line.strip().split()
            if len(fields) == 2 and fields[0] == "interface:":
                interface = fields[1]
                break
        if interface:
            result = subprocess.run(
                ["/usr/sbin/ipconfig", "getifaddr", interface],
                check=False,
                capture_output=True,
                text=True,
            )
            if result.returncode == 0:
                candidates.append(result.stdout.strip())
    except Exception:
        pass

    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(("1.1.1.1", 80))
            candidates.append(sock.getsockname()[0])
    except Exception:
        pass

    for candidate in candidates:
        try:
            parsed = ipaddress.IPv4Address(candidate)
        except ipaddress.AddressValueError:
            continue
        if parsed.is_private and not parsed.is_loopback:
            return str(parsed)
    return None


def probe(ip: str, port: int, timeout: float) -> ProbeResult | None:
    try:
        connection = http.client.HTTPConnection(ip, port, timeout=timeout)
        connection.request("GET", "/health")
        response = connection.getresponse()
        body = response.read(4096)
        if not 200 <= response.status < 300:
            return None
        text = body.decode("utf-8", errors="replace")
        try:
            parsed = json.loads(text)
            app = str(parsed.get("app", ""))
            receiver = str(parsed.get("receiver", "UniDrop Receiver"))
            platform = str(parsed.get("platform", "")).lower()
        except json.JSONDecodeError:
            app = ""
            receiver = "UniDrop Receiver"
            platform = ""
        if "UniDrop" not in app and "UniDrop" not in text and "AnyDrop" not in text and "WinDrop" not in text:
            return None
        return ProbeResult(ip=ip, receiver=receiver, platform=platform)
    except OSError:
        return None
    finally:
        try:
            connection.close()  # type: ignore[possibly-undefined]
        except Exception:
            pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", help="Accepted for compatibility with app helpers.")
    parser.add_argument("--port", type=int, default=8873)
    parser.add_argument("--timeout", type=float, default=0.8)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    own_ip = local_ip()
    if own_ip is None:
        print(json.dumps({"local_ip": None, "receiver": None}) if args.json else "local_ip=")
        return 1

    network = ipaddress.IPv4Network(f"{own_ip}/24", strict=False)
    hosts = [str(host) for host in network.hosts() if str(host) != own_ip]
    found: list[ProbeResult] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=64) as executor:
        futures = [executor.submit(probe, host, args.port, args.timeout) for host in hosts]
        for future in concurrent.futures.as_completed(futures):
            result = future.result()
            if result is not None:
                found.append(result)

    found.sort(key=lambda item: (
        0 if item.platform == "android" else 1 if item.platform == "windows" else 2,
        tuple(int(part) for part in item.ip.split(".")),
    ))
    best = found[0] if found else None

    if args.json:
        print(json.dumps({
            "local_ip": own_ip,
            "receiver": None if best is None else {
                "ip": best.ip,
                "port": args.port,
                "name": best.receiver,
                "platform": best.platform,
            },
        }, sort_keys=True))
    else:
        print(f"local_ip={own_ip}")
        if best is not None:
            print(f"receiver_ip={best.ip}")
            print(f"receiver_name={best.receiver}")
            print(f"receiver_platform={best.platform}")
            for result in found:
                print(f"candidate={result.ip} {result.platform} {result.receiver}")
    return 0 if best is not None else 2


if __name__ == "__main__":
    raise SystemExit(main())
