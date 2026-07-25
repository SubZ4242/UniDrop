#!/bin/sh
set -eu
PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
APP_PATH="/Applications/UniDrop.app"
CONTENTS_DIR="$APP_PATH/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
RUNTIME_DIR="$PROJECT_ROOT/.runtime/macos-app"
ICONSET_DIR="$RUNTIME_DIR/UniDrop.iconset"
SOURCE_FILE="$PROJECT_ROOT/gateway-macos/src/windrop_menubar.swift"
BINARY_FILE="$MACOS_DIR/UniDropGateway"
ICON_FILE="$RESOURCES_DIR/UniDrop.icns"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$ICONSET_DIR"

swiftc -framework AppKit "$SOURCE_FILE" -o "$BINARY_FILE"
chmod 755 "$BINARY_FILE"

python3 - "$ICONSET_DIR" <<'PY'
import math
import struct
import sys
import zlib
from pathlib import Path

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)

def inside_drop(x, y):
    # Coordinate system: 0/0 top-left, 1/1 bottom-right.
    cx, cy, r = 0.5, 0.58, 0.29
    circle = (x - cx) ** 2 + (y - cy) ** 2 <= r ** 2
    if y < 0.58:
        width = max(0.03, 0.25 * (y - 0.12) / 0.46)
        triangle = abs(x - 0.5) <= width and y >= 0.12
    else:
        triangle = False
    return circle or triangle

def png_bytes(size):
    scale = 4
    pixels = []
    for py in range(size):
        row = bytearray()
        row.append(0)
        for px in range(size):
            covered = 0
            for sy in range(scale):
                for sx in range(scale):
                    x = (px + (sx + 0.5) / scale) / size
                    y = (py + (sy + 0.5) / scale) / size
                    if inside_drop(x, y):
                        covered += 1
            alpha = round(255 * covered / (scale * scale))
            if alpha:
                row.extend((0, 122, 255, alpha))
            else:
                row.extend((0, 0, 0, 0))
        pixels.append(bytes(row))
    raw = b"".join(pixels)

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )

for point, scale in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]:
    px = point * scale
    suffix = f"_{scale}x" if scale == 2 else ""
    (out / f"icon_{point}x{point}{suffix}.png").write_bytes(png_bytes(px))
PY

iconutil -c icns "$ICONSET_DIR" -o "$ICON_FILE"

/usr/bin/plutil -create xml1 "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string UniDropGateway "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string com.unidrop.gateway.app "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleName -string "UniDrop" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleDisplayName -string "UniDrop" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundlePackageType -string APPL "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string 0.1.0 "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string 1 "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleIconFile -string UniDrop "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert LSUIElement -bool true "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert UniDropProjectRoot -string "$PROJECT_ROOT" "$CONTENTS_DIR/Info.plist"

printf 'Installed %s\n' "$APP_PATH"
