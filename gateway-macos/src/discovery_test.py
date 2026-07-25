#!/usr/bin/env python3
"""Minimal, discovery-only legacy AirDrop receiver for macOS/AWDL tests."""

from __future__ import annotations

import argparse
import dataclasses
import http.client
import ipaddress
import json
import logging
import os
import plistlib
import re
import shutil
import signal
import select
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import tomllib
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


LOGGER = logging.getLogger("windrop.discovery")
SO_RECV_ANYIF = 0x1104
IPV6_BOUND_IF = 125
MAX_DISCOVER_REQUEST_BYTES = 1_048_576
MAX_ASK_REQUEST_BYTES = 1_048_576
UPLOAD_IDLE_TIMEOUT_SECONDS = 20
SERVICE_TYPE = "_airdrop._tcp"
ADDRESS_SAFETY_CHECK_SECONDS = 60
SUPPORTED_UPLOAD_CONTENT_TYPES = {
    "application/x-cpio",
    "application/x-dvzip",
}
MAX_DVZIP_CHUNK_BYTES = 256 * 1024 * 1024


@dataclasses.dataclass(frozen=True)
class DvZipChunkHeader:
    length: int
    raw: bool = False


@dataclasses.dataclass(frozen=True)
class DiscoveryConfig:
    display_name: str
    model_name: str
    service_id: str
    bonjour_host: str
    interface: str
    port: int
    windows_host: str
    windows_port: int
    forwarding_enabled: bool
    pairing_token_env: str
    health_timeout_seconds: int
    upload_timeout_seconds: int
    log_level: str

    @classmethod
    def load(cls, path: Path) -> "DiscoveryConfig":
        with path.open("rb") as handle:
            raw = tomllib.load(handle)
        config = cls(
            display_name=str(raw["receiver"]["display_name"]),
            model_name=str(raw["receiver"]["model_name"]),
            service_id=str(raw["receiver"]["service_id"]).lower(),
            bonjour_host=str(raw["receiver"]["bonjour_host"]).rstrip("."),
            interface=str(raw["network"]["interface"]),
            port=int(raw["network"]["port"]),
            windows_host=str(raw["network"].get("windows_host", "")).strip(),
            windows_port=int(raw["network"].get("windows_port", 8873)),
            forwarding_enabled=bool(raw.get("forwarding", {}).get("enabled", False)),
            pairing_token_env=str(raw.get("forwarding", {}).get("pairing_token_env", "WINDROP_PAIRING_TOKEN")),
            health_timeout_seconds=int(raw.get("forwarding", {}).get("health_timeout_seconds", 2)),
            upload_timeout_seconds=int(raw.get("forwarding", {}).get("upload_timeout_seconds", 600)),
            log_level=str(raw.get("logging", {}).get("level", "warn")).lower(),
        )
        config.validate()
        return config

    def validate(self) -> None:
        if not self.display_name.strip() or len(self.display_name) > 255:
            raise ValueError("receiver.display_name must contain 1 to 255 characters")
        if not self.model_name.strip() or len(self.model_name) > 255:
            raise ValueError("receiver.model_name must contain 1 to 255 characters")
        if re.fullmatch(r"[0-9a-f]{12}", self.service_id) is None:
            raise ValueError("receiver.service_id must be exactly 12 hexadecimal characters")
        if re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", self.bonjour_host) is None:
            raise ValueError("receiver.bonjour_host must be one valid DNS label")
        if re.fullmatch(r"[A-Za-z0-9_.-]+", self.interface) is None:
            raise ValueError("network.interface contains unsupported characters")
        if not 1024 <= self.port <= 65535:
            raise ValueError("network.port must be between 1024 and 65535")
        if not 1024 <= self.windows_port <= 65535:
            raise ValueError("network.windows_port must be between 1024 and 65535")
        if self.health_timeout_seconds < 1 or self.upload_timeout_seconds < 1:
            raise ValueError("forwarding timeouts must be positive")
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", self.pairing_token_env) is None:
            raise ValueError("forwarding.pairing_token_env must be an environment variable name")
        if self.log_level not in {"debug", "info", "warn", "warning", "error"}:
            raise ValueError("logging.level must be debug, info, warn, warning, or error")

    @property
    def pairing_token(self) -> str | None:
        token = os.environ.get(self.pairing_token_env, "").strip()
        return token or None


@dataclasses.dataclass(frozen=True)
class ReceiverProbe:
    host: str
    name: str
    platform: str = ""


def interface_ipv6(interface: str) -> tuple[str, int]:
    interface_index = socket.if_nametoindex(interface)
    completed = subprocess.run(
        ["/sbin/ifconfig", interface],
        check=True,
        capture_output=True,
        text=True,
    )
    for line in completed.stdout.splitlines():
        fields = line.strip().split()
        if len(fields) >= 2 and fields[0] == "inet6":
            address = fields[1].split("%", 1)[0]
            parsed = ipaddress.IPv6Address(address)
            if parsed.is_link_local:
                return str(parsed), interface_index
    raise RuntimeError(f"{interface} has no link-local IPv6 address")


def build_discover_response(config: DiscoveryConfig) -> bytes:
    capabilities = json.dumps(
        {"Version": 1},
        separators=(",", ":"),
    ).encode("utf-8")
    return plistlib.dumps(
        {
            "ReceiverMediaCapabilities": capabilities,
            "ReceiverComputerName": config.display_name,
            "ReceiverModelName": config.model_name,
        },
        fmt=plistlib.FMT_BINARY,
        sort_keys=True,
    )


def build_ask_response(config: DiscoveryConfig) -> bytes:
    return plistlib.dumps(
        {
            "ReceiverComputerName": config.display_name,
            "ReceiverModelName": config.model_name,
        },
        fmt=plistlib.FMT_BINARY,
        sort_keys=True,
    )


def looks_like_cpio_or_gzip(path: Path) -> bool:
    with path.open("rb") as handle:
        header = handle.read(6)
    return header.startswith(b"\x1f\x8b") or header in {b"070701", b"070702", b"070707"}


def parse_dvzip_chunk_length(length_bytes: bytes) -> int:
    return parse_dvzip_chunk_header(length_bytes).length


def parse_dvzip_chunk_header(length_bytes: bytes) -> DvZipChunkHeader:
    if len(length_bytes) != 4:
        raise EOFError("Incomplete DVZip chunk length")
    big_endian = int.from_bytes(length_bytes, "big", signed=True)
    if 0 <= big_endian <= MAX_DVZIP_CHUNK_BYTES:
        return DvZipChunkHeader(big_endian, raw=False)
    flagged_big_endian = big_endian & 0x7FFFFFFF
    if 0 < flagged_big_endian <= MAX_DVZIP_CHUNK_BYTES:
        return DvZipChunkHeader(flagged_big_endian, raw=True)
    little_endian = int.from_bytes(length_bytes, "little", signed=True)
    if 0 <= little_endian <= MAX_DVZIP_CHUNK_BYTES:
        return DvZipChunkHeader(little_endian, raw=False)
    raise ValueError(f"Invalid DVZip chunk length {big_endian}")


def dvzip_diagnostics(path: Path) -> dict[str, Any]:
    data = path.read_bytes()[:128]
    candidates: list[dict[str, Any]] = []
    for offset in range(0, min(32, max(0, len(data) - 3))):
        chunk = data[offset : offset + 4]
        big_unsigned = int.from_bytes(chunk, "big", signed=False)
        big_signed = int.from_bytes(chunk, "big", signed=True)
        little_signed = int.from_bytes(chunk, "little", signed=True)
        flagged_big = big_signed & 0x7FFFFFFF
        plausible = [
            value
            for value in (big_signed, flagged_big, little_signed)
            if 0 < value <= MAX_DVZIP_CHUNK_BYTES
        ]
        if plausible:
            candidates.append(
                {
                    "offset": offset,
                    "hex": chunk.hex(),
                    "be_unsigned": big_unsigned,
                    "be_signed": big_signed,
                    "be_flagged": flagged_big,
                    "le_signed": little_signed,
                    "plausible": plausible,
                }
            )
    return {
        "size": path.stat().st_size,
        "first_64_hex": data[:64].hex(),
        "ascii_preview": "".join(chr(byte) if 32 <= byte <= 126 else "." for byte in data[:64]),
        "length_candidates": candidates[:12],
    }


def expand_dvzip_to_cpio(input_path: Path, output_path: Path) -> int:
    total = 0
    with input_path.open("rb") as source, output_path.open("wb") as output:
        chunk_index = 0
        while True:
            length_bytes = source.read(4)
            if not length_bytes:
                break
            header = parse_dvzip_chunk_header(length_bytes)
            if header.length == 0:
                break
            compressed = source.read(header.length)
            if len(compressed) != header.length:
                raise EOFError("DVZip chunk ended before advertised length")
            decompressed = compressed if header.raw else decompress_dvzip_chunk(compressed, chunk_index)
            output.write(decompressed)
            total += len(decompressed)
            chunk_index += 1
    return total


def decompress_dvzip_chunk(compressed: bytes, chunk_index: int) -> bytes:
    if compressed.startswith((b"070701", b"070702", b"070707")):
        return compressed

    errors: list[str] = []
    for label, window_bits in (
        ("zlib", zlib.MAX_WBITS),
        ("zlib_or_gzip", zlib.MAX_WBITS | 32),
        ("raw_deflate", -zlib.MAX_WBITS),
    ):
        try:
            decompressor = zlib.decompressobj(window_bits)
            data = decompressor.decompress(compressed)
            data += decompressor.flush()
            if data:
                return data
            errors.append(f"{label}: empty output")
        except zlib.error as exc:
            errors.append(f"{label}: {exc}")

    raise zlib.error(f"Could not decompress DVZip chunk {chunk_index}: {'; '.join(errors)}")


def windows_headers(config: DiscoveryConfig) -> dict[str, str]:
    headers = {
        "User-Agent": "UniDrop-Gateway/0.1",
        "X-UniDrop-Receiver": config.display_name,
    }
    token = config.pairing_token
    if token is not None:
        headers["X-UniDrop-Token"] = token
    return headers


def probe_receiver(config: DiscoveryConfig, host: str, timeout: float | None = None) -> ReceiverProbe | None:
    connection: http.client.HTTPConnection | None = None
    try:
        connection = http.client.HTTPConnection(
            host,
            config.windows_port,
            timeout=timeout if timeout is not None else config.health_timeout_seconds,
        )
        connection.request("GET", "/health", headers=windows_headers(config))
        response = connection.getresponse()
        body = response.read(4096)
        if not 200 <= response.status < 300:
            return None
        text = body.decode("utf-8", errors="replace")
        try:
            parsed = json.loads(text)
            app = str(parsed.get("app", ""))
            receiver = str(parsed.get("receiver", ""))
            platform = str(parsed.get("platform", "")).lower()
        except json.JSONDecodeError:
            app = ""
            receiver = text
            platform = ""
        if "UniDrop" not in app and "UniDrop" not in text and "WinDrop" not in text and "AnyDrop" not in text:
            return None
        return ReceiverProbe(host=host, name=receiver or "UniDrop Receiver", platform=platform)
    except OSError:
        return None
    finally:
        if connection is not None:
            connection.close()


def discover_receiver(config: DiscoveryConfig) -> ReceiverProbe | None:
    own_ip = local_lan_ipv4()
    if own_ip is None:
        LOGGER.warning("Could not auto-discover receiver because Mac LAN IP is unknown")
        return None
    try:
        network = ipaddress.IPv4Network(f"{own_ip}/24", strict=False)
    except ValueError:
        return None

    found: list[ReceiverProbe] = []
    hosts = [str(host) for host in network.hosts() if str(host) != own_ip]

    def worker(host: str) -> ReceiverProbe | None:
        return probe_receiver(config, host, timeout=0.45)

    import concurrent.futures

    with concurrent.futures.ThreadPoolExecutor(max_workers=64) as executor:
        futures = [executor.submit(worker, host) for host in hosts]
        for future in concurrent.futures.as_completed(futures):
            result = future.result()
            if result is not None and receiver_matches_display_target(config, result):
                found.append(result)

    found.sort(key=lambda item: (
        0 if item.platform == "android" else 1 if item.platform == "windows" else 2,
        tuple(int(part) for part in item.host.split(".")),
    ))
    if found:
        LOGGER.warning(
            "Auto-discovered receiver %s at %s:%d",
            found[0].name,
            found[0].host,
            config.windows_port,
        )
        return found[0]
    LOGGER.warning("No UniDrop receiver found on local /24 port %d", config.windows_port)
    return None


def normalized_target(value: str) -> str:
    return re.sub(r"\s+", " ", value.strip().lower())


def receiver_matches_display_target(config: DiscoveryConfig, receiver: ReceiverProbe) -> bool:
    display_name = normalized_target(config.display_name)
    receiver_name = normalized_target(receiver.name)
    model_name = normalized_target(config.model_name)
    if display_name in {"", "unidrop", "unidrop gateway"}:
        return True
    if receiver_name == display_name:
        return True
    if "android" in model_name:
        return receiver.platform == "android"
    if "windows" in model_name:
        return receiver.platform == "windows" or "windows" in receiver_name
    return False


def resolve_receiver(config: DiscoveryConfig) -> ReceiverProbe | None:
    if not config.forwarding_enabled:
        return None
    if config.windows_host:
        result = probe_receiver(config, config.windows_host)
        if result is None:
            LOGGER.warning("Configured receiver is not reachable: %s:%d", config.windows_host, config.windows_port)
        elif not receiver_matches_display_target(config, result):
            LOGGER.warning(
                "Configured receiver %s at %s does not match visible AirDrop target %s",
                result.name,
                result.host,
                config.display_name,
            )
            return None
        return result
    return discover_receiver(config)


def check_windows_receiver(config: DiscoveryConfig) -> bool:
    if not config.forwarding_enabled:
        return False
    return resolve_receiver(config) is not None


class DiscoveryRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "UniDrop-Discovery/0.1"
    sys_version = ""

    @property
    def discovery_config(self) -> DiscoveryConfig:
        return self.server.discovery_config  # type: ignore[attr-defined]

    def _read_limited_body(self, max_bytes: int) -> bytes | None:
        raw_length = self.headers.get("Content-Length")
        transfer_encoding = self.headers.get("Transfer-Encoding", "").lower()
        if raw_length is None and transfer_encoding == "chunked":
            return self._read_chunked_body(max_bytes)
        if raw_length is None:
            self.send_error(411, "Content-Length required")
            return None
        try:
            length = int(raw_length)
        except ValueError:
            self.send_error(400, "Invalid Content-Length")
            return None
        if length < 0 or length > max_bytes:
            self.send_error(413, "Request too large")
            return None
        return self.rfile.read(length)

    def _read_chunked_body(self, max_bytes: int) -> bytes | None:
        body = bytearray()
        while True:
            size_line = self.rfile.readline(128)
            if not size_line or len(size_line) >= 128:
                self.send_error(400, "Invalid chunk header")
                return None
            try:
                chunk_size = int(size_line.split(b";", 1)[0].strip(), 16)
            except ValueError:
                self.send_error(400, "Invalid chunk size")
                return None
            if chunk_size < 0 or len(body) + chunk_size > max_bytes:
                self.send_error(413, "Request too large")
                return None
            if chunk_size == 0:
                while True:
                    trailer = self.rfile.readline(8192)
                    if trailer in {b"\r\n", b"\n", b""}:
                        return bytes(body)
                    if len(trailer) >= 8192:
                        self.send_error(400, "Invalid chunk trailer")
                        return None
            chunk = self.rfile.read(chunk_size)
            terminator = self.rfile.read(2)
            if len(chunk) != chunk_size or terminator != b"\r\n":
                self.send_error(400, "Truncated chunk")
                return None
            body.extend(chunk)

    def _send_bytes(self, status: int, payload: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)
        self.close_connection = True

    def do_HEAD(self) -> None:
        self._send_bytes(200, b"", "application/octet-stream")

    def do_GET(self) -> None:
        self._send_bytes(200, b"\n", "text/plain; charset=utf-8")

    def do_POST(self) -> None:
        if self.path == "/Discover":
            self._handle_discover()
        elif self.path == "/Ask":
            self._handle_ask()
        elif self.path == "/Upload":
            self._handle_upload()
        else:
            body = self._read_limited_body(MAX_ASK_REQUEST_BYTES)
            if body is None:
                return
            LOGGER.warning("Rejected non-discovery request %s from %s", self.path, self.client_address[0])
            self._send_bytes(503, b"", "application/octet-stream")

    def _handle_discover(self) -> None:
        body = self._read_limited_body(MAX_DISCOVER_REQUEST_BYTES)
        if body is None:
            return
        if LOGGER.isEnabledFor(logging.DEBUG):
            try:
                parsed: Any = plistlib.loads(body) if body else {}
                keys = sorted(str(key) for key in parsed) if isinstance(parsed, dict) else []
                LOGGER.debug(
                    "Discover request from %s: %d bytes, plist keys=%s",
                    self.client_address[0],
                    len(body),
                    keys,
                )
            except plistlib.InvalidFileException:
                LOGGER.debug("Discover request from %s is not a plist (%d bytes)", self.client_address[0], len(body))

        payload = build_discover_response(self.discovery_config)
        LOGGER.info("Answered /Discover for %s to %s", self.discovery_config.display_name, self.client_address[0])
        self._send_bytes(200, payload, "application/octet-stream")

    def _handle_ask(self) -> None:
        body = self._read_limited_body(MAX_ASK_REQUEST_BYTES)
        if body is None:
            return
        try:
            parsed: Any = plistlib.loads(body) if body else {}
        except plistlib.InvalidFileException:
            self.send_error(400, "Invalid Ask plist")
            return
        if not isinstance(parsed, dict):
            self.send_error(400, "Invalid Ask payload")
            return

        files = parsed.get("Files", [])
        items = parsed.get("Items", [])
        sender_name = str(parsed.get("SenderComputerName", "unknown"))
        LOGGER.warning(
            "Received /Ask from %s with %d file entries and %d item entries",
            sender_name,
            len(files) if isinstance(files, list) else 0,
            len(items) if isinstance(items, list) else 0,
        )

        if not check_windows_receiver(self.discovery_config):
            LOGGER.warning("Rejected /Ask because no receiver is available or forwarding is disabled")
            self._send_bytes(503, b"", "application/octet-stream")
            return

        payload = build_ask_response(self.discovery_config)
        self._send_bytes(200, payload, "application/octet-stream")

    def _handle_upload(self) -> None:
        if not self.discovery_config.forwarding_enabled:
            LOGGER.warning("Rejected /Upload because forwarding is disabled")
            self._send_bytes(503, b"", "application/octet-stream")
            return
        if self.headers.get("Expect", "").lower() == "100-continue":
            self.send_response_only(100)
            self.send_header("Content-Length", "0")
            self.end_headers()
        content_type = self.headers.get("Content-Type", "").split(";", 1)[0].lower()
        if content_type not in SUPPORTED_UPLOAD_CONTENT_TYPES:
            LOGGER.warning("Rejected /Upload with unsupported content type %s", self.headers.get("Content-Type"))
            self._send_bytes(406, b"", "application/octet-stream")
            return

        upload_path: Path | None = None
        forward_path: Path | None = None
        try:
            upload_path, total = self._spool_upload_body()
            forward_content_type, forward_path, forward_total = self._prepare_upload_for_forwarding(
                content_type,
                upload_path,
                total,
            )
            status = self._forward_upload_to_windows(forward_content_type, forward_path, forward_total)
        except TimeoutError:
            LOGGER.warning("Upload from %s timed out before the archive was complete", self.client_address[0])
            self._send_bytes(408, b"", "application/octet-stream")
            return
        except Exception:
            LOGGER.exception("Forwarding /Upload to receiver failed")
            self._send_bytes(502, b"", "application/octet-stream")
            return
        finally:
            if forward_path is not None and upload_path is not None and forward_path != upload_path:
                forward_path.unlink(missing_ok=True)
            if upload_path is not None:
                upload_path.unlink(missing_ok=True)
        if 200 <= status < 300:
            self._send_bytes(200, b"", "application/octet-stream")
        else:
            LOGGER.warning("Receiver rejected upload with HTTP %d", status)
            self._send_bytes(502, b"", "application/octet-stream")

    def _spool_upload_body(self) -> tuple[Path, int]:
        previous_timeout = self.connection.gettimeout()
        self.connection.settimeout(UPLOAD_IDLE_TIMEOUT_SECONDS)
        descriptor, raw_path = tempfile.mkstemp(prefix="windrop-upload-", suffix=".archive")
        path = Path(raw_path)
        try:
            with os.fdopen(descriptor, "wb") as output:
                transfer_encoding = self.headers.get("Transfer-Encoding", "").lower()
                if transfer_encoding == "chunked":
                    total = self._pipe_chunked_body(output)
                else:
                    total = self._pipe_content_length_body(output)
            return path, total
        except socket.timeout as exc:
            path.unlink(missing_ok=True)
            raise TimeoutError("Upload body timed out") from exc
        except Exception:
            path.unlink(missing_ok=True)
            raise
        finally:
            self.connection.settimeout(previous_timeout)

    def _forward_upload_to_windows(self, content_type: str, upload_path: Path, content_length: int) -> int:
        config = self.discovery_config
        receiver = resolve_receiver(config)
        if receiver is None:
            raise RuntimeError("No reachable UniDrop receiver")
        connection = http.client.HTTPConnection(
            receiver.host,
            config.windows_port,
            timeout=config.upload_timeout_seconds,
        )
        try:
            connection.putrequest("POST", "/api/transfers/archive")
            for key, value in windows_headers(config).items():
                connection.putheader(key, value)
            connection.putheader("Content-Type", content_type)
            connection.putheader("Content-Length", str(content_length))
            connection.endheaders()

            with upload_path.open("rb") as body:
                while chunk := body.read(256 * 1024):
                    connection.send(chunk)
            response = connection.getresponse()
            response_body = response.read(4096).decode("utf-8", errors="replace")
            LOGGER.warning(
                "Forwarded /Upload to %s at %s:%d: %d bytes, HTTP %d%s",
                receiver.name,
                receiver.host,
                config.windows_port,
                content_length,
                response.status,
                f", response={response_body[:500]}" if response_body else "",
            )
            return response.status
        finally:
            connection.close()

    def _pipe_chunked_body(self, output: Any) -> int:
        total = 0
        while True:
            size_line = self.rfile.readline(128)
            if not size_line or len(size_line) >= 128:
                raise ValueError("Invalid upload chunk header")
            chunk_size = int(size_line.split(b";", 1)[0].strip(), 16)
            if chunk_size == 0:
                while True:
                    trailer = self.rfile.readline(8192)
                    if trailer in {b"\r\n", b"\n", b""}:
                        return total
                    if len(trailer) >= 8192:
                        raise ValueError("Invalid upload chunk trailer")
            chunk = self.rfile.read(chunk_size)
            terminator = self.rfile.read(2)
            if len(chunk) != chunk_size or terminator != b"\r\n":
                raise ValueError("Truncated upload chunk")
            output.write(chunk)
            total += len(chunk)

    def _pipe_content_length_body(self, output: Any) -> int:
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            raise ValueError("Upload requires Content-Length or chunked transfer encoding")
        remaining = int(raw_length)
        total = 0
        while remaining > 0:
            chunk = self.rfile.read(min(remaining, 256 * 1024))
            if not chunk:
                raise ValueError("Truncated upload body")
            output.write(chunk)
            remaining -= len(chunk)
            total += len(chunk)
        return total

    def _prepare_upload_for_forwarding(self, content_type: str, upload_path: Path, total: int) -> tuple[str, Path, int]:
        if content_type != "application/x-dvzip":
            return content_type, upload_path, total
        if looks_like_cpio_or_gzip(upload_path):
            LOGGER.warning("Received /Upload as DVZip but payload already looks like CPIO/GZip; forwarding as CPIO")
            return "application/x-cpio", upload_path, total

        descriptor, raw_path = tempfile.mkstemp(prefix="windrop-dvzip-expanded-", suffix=".cpio")
        cpio_path = Path(raw_path)
        os.close(descriptor)
        try:
            cpio_total = expand_dvzip_to_cpio(upload_path, cpio_path)
        except Exception:
            LOGGER.warning("DVZip diagnostics after conversion failure: %s", json.dumps(dvzip_diagnostics(upload_path)))
            cpio_path.unlink(missing_ok=True)
            raise
        LOGGER.warning("Expanded DVZip upload before forwarding: %d bytes -> %d bytes CPIO", total, cpio_total)
        return "application/x-cpio", cpio_path, cpio_total

    def log_message(self, format_string: str, *args: object) -> None:
        if LOGGER.isEnabledFor(logging.DEBUG):
            LOGGER.debug("%s - %s", self.client_address[0], format_string % args)


class ScopedIPv6HTTPServer(ThreadingHTTPServer):
    address_family = socket.AF_INET6
    daemon_threads = True
    allow_reuse_address = True

    def __init__(
        self,
        address: str,
        port: int,
        interface_index: int,
        handler: type[BaseHTTPRequestHandler],
        discovery_config: DiscoveryConfig,
    ) -> None:
        super().__init__(
            (address, port, 0, interface_index),
            handler,
            bind_and_activate=False,
        )
        self.discovery_config = discovery_config
        self.socket.setsockopt(socket.IPPROTO_IPV6, IPV6_BOUND_IF, interface_index)
        self.socket.setsockopt(socket.SOL_SOCKET, SO_RECV_ANYIF, 1)
        self.server_bind()
        self.server_activate()


class LanStatusRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "UniDrop-LAN/0.1"
    sys_version = ""

    @property
    def discovery_config(self) -> DiscoveryConfig:
        return self.server.discovery_config  # type: ignore[attr-defined]

    @property
    def lan_address(self) -> str:
        return self.server.lan_address  # type: ignore[attr-defined]

    def _send_json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        self.close_connection = True

    def do_HEAD(self) -> None:
        self._send_json(200, {})

    def do_GET(self) -> None:
        if self.path not in {"/", "/health", "/gateway"}:
            self._send_json(404, {"status": "not_found"})
            return
        config = self.discovery_config
        self._send_json(
            200,
            {
                "status": "ok",
                "app": "UniDrop",
                "role": "mac-gateway",
                "name": config.display_name,
                "version": "0.1.0",
                "gatewayHost": self.lan_address,
                "gatewayPort": config.port,
                "receiverPort": config.windows_port,
                "airdropPort": config.port,
            },
        )

    def do_POST(self) -> None:
        self._send_json(405, {"status": "method_not_allowed"})

    def log_message(self, format_string: str, *args: object) -> None:
        if LOGGER.isEnabledFor(logging.DEBUG):
            LOGGER.debug("lan %s - %s", self.client_address[0], format_string % args)


class LanStatusHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(
        self,
        address: str,
        port: int,
        handler: type[BaseHTTPRequestHandler],
        discovery_config: DiscoveryConfig,
    ) -> None:
        super().__init__((address, port), handler, bind_and_activate=False)
        self.discovery_config = discovery_config
        self.lan_address = address
        self.server_bind()
        self.server_activate()


def ensure_certificate(runtime_dir: Path, common_name: str) -> tuple[Path, Path]:
    key_path = runtime_dir / "tls-key.pem"
    certificate_path = runtime_dir / "tls-certificate.pem"
    if key_path.exists() and certificate_path.exists() and certificate_matches(certificate_path, common_name):
        return certificate_path, key_path

    openssl = shutil.which("openssl")
    if openssl is None:
        raise RuntimeError("openssl was not found")
    if key_path.exists() or certificate_path.exists():
        backup_suffix = time.strftime("%Y%m%d%H%M%S")
        for path in (key_path, certificate_path):
            if path.exists():
                path.rename(path.with_name(f"{path.name}.{backup_suffix}.bak"))
    command = [
        openssl,
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-sha256",
        "-nodes",
        "-days",
        "30",
        "-keyout",
        str(key_path),
        "-out",
        str(certificate_path),
        "-subj",
        f"/CN={common_name}",
        "-addext",
        f"subjectAltName=DNS:{common_name}",
    ]
    subprocess.run(command, check=True, capture_output=True)
    key_path.chmod(0o600)
    certificate_path.chmod(0o600)
    return certificate_path, key_path


def certificate_matches(certificate_path: Path, common_name: str) -> bool:
    openssl = shutil.which("openssl")
    if openssl is None:
        return False
    try:
        completed = subprocess.run(
            [
                openssl,
                "x509",
                "-in",
                str(certificate_path),
                "-noout",
                "-subject",
                "-ext",
                "subjectAltName",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError:
        return False
    return f"DNS:{common_name}" in completed.stdout


class BonjourRegistration:
    def __init__(
        self,
        config: DiscoveryConfig,
        ipv6_address: str,
        runtime_dir: Path,
    ) -> None:
        self.config = config
        self.ipv6_address = ipv6_address
        self.runtime_dir = runtime_dir
        self.process: subprocess.Popen[bytes] | None = None
        self.log_handle: Any = None

    def start(self) -> None:
        log_path = self.runtime_dir / "bonjour.log"
        self.log_handle = log_path.open("ab", buffering=0)
        command = [
            "/usr/bin/dns-sd",
            "-i",
            self.config.interface,
            "-P",
            self.config.service_id,
            SERVICE_TYPE,
            "local.",
            str(self.config.port),
            f"{self.config.bonjour_host}.local.",
            self.ipv6_address,
            "flags=136",
        ]
        self.process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=self.log_handle,
            stderr=subprocess.STDOUT,
            close_fds=True,
        )
        (self.runtime_dir / "bonjour.pid").write_text(f"{self.process.pid}\n", encoding="ascii")
        time.sleep(0.8)
        if self.process.poll() is not None:
            raise RuntimeError(f"dns-sd registration exited with status {self.process.returncode}")

    def stop(self) -> None:
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                LOGGER.warning("dns-sd did not stop after SIGTERM")
        if self.log_handle is not None:
            self.log_handle.close()


def write_state(
    runtime_dir: Path,
    config: DiscoveryConfig,
    ipv6_address: str,
    interface_index: int,
    server_pid: int,
    bonjour_pid: int,
    lan_ipv4: str | None = None,
) -> None:
    state = {
        "server_pid": server_pid,
        "bonjour_pid": bonjour_pid,
        "display_name": config.display_name,
        "model_name": config.model_name,
        "service_id": config.service_id,
        "service_type": f"{SERVICE_TYPE}.local.",
        "bonjour_host": f"{config.bonjour_host}.local.",
        "interface": config.interface,
        "interface_index": interface_index,
        "ipv6_address": f"{ipv6_address}%{config.interface}",
        "port": config.port,
        "lan_ipv4": lan_ipv4,
        "lan_gateway_url": f"http://{lan_ipv4}:{config.port}/gateway" if lan_ipv4 else None,
        "txt": {"flags": "136"},
        "transport": "HTTPS/TLS (discovery only)",
    }
    state_path = runtime_dir / "state.json"
    state_path.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    state_path.chmod(0o600)
    pid_path = runtime_dir / "server.pid"
    pid_path.write_text(f"{server_pid}\n", encoding="ascii")
    pid_path.chmod(0o600)


def local_lan_ipv4() -> str | None:
    try:
        completed = subprocess.run(
            ["/sbin/ifconfig"],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None

    current_interface = ""
    for raw_line in completed.stdout.splitlines():
        if raw_line and not raw_line.startswith(("\t", " ")):
            current_interface = raw_line.split(":", 1)[0]
            continue
        if current_interface.startswith(("lo", "awdl", "llw", "utun", "bridge")):
            continue
        fields = raw_line.strip().split()
        if len(fields) >= 2 and fields[0] == "inet":
            try:
                address = ipaddress.IPv4Address(fields[1])
            except ipaddress.AddressValueError:
                continue
            if address.is_private and not address.is_loopback and not address.is_link_local:
                return str(address)
    return None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--runtime-dir", type=Path, required=True)
    parser.add_argument("--debug", action="store_true")
    return parser.parse_args()


def run() -> int:
    args = parse_args()
    os.umask(0o077)
    args.runtime_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    args.runtime_dir.chmod(0o700)

    config = DiscoveryConfig.load(args.config)
    configured_level = "debug" if args.debug else config.log_level
    log_levels = {
        "debug": logging.DEBUG,
        "info": logging.INFO,
        "warn": logging.WARNING,
        "warning": logging.WARNING,
        "error": logging.ERROR,
    }
    logging.basicConfig(
        level=log_levels[configured_level],
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    ipv6_address, interface_index = interface_ipv6(config.interface)
    certificate_path, key_path = ensure_certificate(
        args.runtime_dir,
        f"{config.bonjour_host}.local",
    )

    tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls_context.minimum_version = ssl.TLSVersion.TLSv1_2
    tls_context.load_cert_chain(certificate_path, key_path)

    def start_https_server(
        address: str,
        index: int,
    ) -> tuple[ScopedIPv6HTTPServer, threading.Thread]:
        https_server = ScopedIPv6HTTPServer(
            address,
            config.port,
            index,
            DiscoveryRequestHandler,
            config,
        )
        https_server.socket = tls_context.wrap_socket(
            https_server.socket,
            server_side=True,
        )
        thread = threading.Thread(
            target=https_server.serve_forever,
            name="https-server",
            daemon=True,
        )
        thread.start()
        return https_server, thread

    def start_lan_status_server() -> tuple[LanStatusHTTPServer, threading.Thread, str] | None:
        lan_ipv4 = local_lan_ipv4()
        if lan_ipv4 is None:
            LOGGER.warning("No private LAN IPv4 address found; gateway auto-discovery endpoint disabled")
            return None
        try:
            lan_server = LanStatusHTTPServer(
                lan_ipv4,
                config.port,
                LanStatusRequestHandler,
                config,
            )
        except OSError as exc:
            LOGGER.warning(
                "Could not bind LAN gateway auto-discovery endpoint on %s:%d: %s",
                lan_ipv4,
                config.port,
                exc,
            )
            return None
        thread = threading.Thread(
            target=lan_server.serve_forever,
            name="lan-status-server",
            daemon=True,
        )
        thread.start()
        LOGGER.warning("LAN gateway auto-discovery endpoint ready at http://%s:%d/gateway", lan_ipv4, config.port)
        return lan_server, thread, lan_ipv4

    server, server_thread = start_https_server(ipv6_address, interface_index)
    lan_status = start_lan_status_server()

    registration = BonjourRegistration(config, ipv6_address, args.runtime_dir)
    registration.start()
    assert registration.process is not None
    write_state(
        args.runtime_dir,
        config,
        ipv6_address,
        interface_index,
        os.getpid(),
        registration.process.pid,
        lan_status[2] if lan_status else None,
    )

    stop_event = threading.Event()

    def request_stop(signum: int, _frame: object) -> None:
        LOGGER.info("Received signal %d", signum)
        stop_event.set()

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)

    LOGGER.info(
        "Discovery test ready: %s, %s%%%s:%d, service %s",
        config.display_name,
        ipv6_address,
        config.interface,
        config.port,
        config.service_id,
    )

    route_socket = socket.socket(socket.AF_ROUTE, socket.SOCK_RAW, 0)
    route_socket.setblocking(False)
    last_address_check = time.monotonic()

    try:
        while not stop_event.is_set():
            readable, _, _ = select.select([route_socket], [], [], 5)
            now = time.monotonic()
            registration_stopped = (
                registration.process is None or registration.process.poll() is not None
            )
            address_check_due = (
                registration_stopped
                or (readable and now - last_address_check >= 2)
                or now - last_address_check >= ADDRESS_SAFETY_CHECK_SECONDS
            )
            if not address_check_due:
                continue

            if readable:
                try:
                    while route_socket.recv(65_536):
                        pass
                except BlockingIOError:
                    pass

            last_address_check = now
            current_address, current_index = interface_ipv6(config.interface)
            if (
                registration_stopped
                or current_address != ipv6_address
                or current_index != interface_index
            ):
                LOGGER.info(
                    "Refreshing Bonjour registration after AWDL change: %s -> %s",
                    ipv6_address,
                    current_address,
                )
                address_changed = (
                    current_address != ipv6_address or current_index != interface_index
                )
                registration.stop()
                if address_changed:
                    server.shutdown()
                    server.server_close()
                    server_thread.join(timeout=3)
                    server, server_thread = start_https_server(
                        current_address,
                        current_index,
                    )
                registration = BonjourRegistration(config, current_address, args.runtime_dir)
                registration.start()
                assert registration.process is not None
                ipv6_address = current_address
                interface_index = current_index
                write_state(
                    args.runtime_dir,
                    config,
                    ipv6_address,
                    interface_index,
                    os.getpid(),
                    registration.process.pid,
                    lan_status[2] if lan_status else None,
                )
    finally:
        route_socket.close()
        if lan_status is not None:
            lan_status[0].shutdown()
            lan_status[0].server_close()
        server.shutdown()
        server.server_close()
        registration.stop()
        if lan_status is not None:
            lan_status[1].join(timeout=3)
        server_thread.join(timeout=3)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(run())
    except Exception:
        LOGGER.exception("Discovery test failed")
        raise SystemExit(1)
