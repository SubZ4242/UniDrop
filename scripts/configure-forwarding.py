#!/usr/bin/env python3
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
    parser.add_argument("--windows-host", required=True)
    parser.add_argument("--windows-port", type=int, default=8873)
    parser.add_argument("--enabled", choices=["true", "false"], default="true")
    args = parser.parse_args()

    if not 1024 <= args.windows_port <= 65535:
        raise SystemExit("windows port must be between 1024 and 65535")
    if not re.fullmatch(r"[A-Za-z0-9_.:-]+", args.windows_host):
        raise SystemExit("windows host contains unsupported characters")

    text = args.config.read_text(encoding="utf-8")
    text = replace_value(text, "network", "windows_host", quote_toml(args.windows_host))
    text = replace_value(text, "network", "windows_port", str(args.windows_port))
    text = replace_value(text, "forwarding", "enabled", args.enabled)
    args.config.write_text(text, encoding="utf-8")
    print(f"Configured receiver: {args.windows_host}:{args.windows_port}, forwarding={args.enabled}")
    print("Restart the discovery service for changes to take effect.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
