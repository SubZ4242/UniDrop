#!/usr/bin/env -S PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin python3
"""Update UniDrop forwarding settings in the local discovery config."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def replace_value(text: str, section: str, key: str, value: str) -> str:
    pattern = re.compile(
        rf"(^\[{re.escape(section)}\]\n(?:[^\[]*\n)*?^{re.escape(key)}\s*=\s*).*$",
        re.MULTILINE,
    )
    replacement = rf"\g<1>{value}"
    updated, count = pattern.subn(replacement, text, count=1)
    if count != 1:
        raise RuntimeError(f"Could not update [{section}] {key}")
    return updated


def quote_toml(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--windows-host", default="")
    parser.add_argument("--windows-port", type=int, default=8873)
    parser.add_argument("--gateway-port", type=int)
    parser.add_argument("--display-name")
    parser.add_argument("--model-name")
    parser.add_argument("--enabled", choices=["true", "false"], default="true")
    args = parser.parse_args()

    gateway_port = args.gateway_port if args.gateway_port is not None else args.windows_port
    if not 1024 <= args.windows_port <= 65535:
        raise SystemExit("windows port must be between 1024 and 65535")
    if not 1024 <= gateway_port <= 65535:
        raise SystemExit("gateway port must be between 1024 and 65535")
    if args.windows_host and not re.fullmatch(r"[A-Za-z0-9_.:-]+", args.windows_host):
        raise SystemExit("windows host contains unsupported characters")

    text = args.config.read_text(encoding="utf-8")
    if args.display_name:
        text = replace_value(text, "receiver", "display_name", quote_toml(args.display_name[:255]))
    if args.model_name:
        text = replace_value(text, "receiver", "model_name", quote_toml(args.model_name[:255]))
    text = replace_value(text, "network", "port", str(gateway_port))
    text = replace_value(text, "network", "windows_host", quote_toml(args.windows_host))
    text = replace_value(text, "network", "windows_port", str(args.windows_port))
    text = replace_value(text, "forwarding", "enabled", args.enabled)
    args.config.write_text(text, encoding="utf-8")
    print(f"Configured receiver: {args.windows_host}:{args.windows_port}, forwarding={args.enabled}")
    print("Restart the discovery service for changes to take effect.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
