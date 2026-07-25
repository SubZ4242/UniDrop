#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BUILD_ROOT="$PROJECT_ROOT/.runtime/macos-dmg"
DMG_PATH="$SCRIPT_DIR/UniDrop-macOS.dmg"
VOLUME_NAME="UniDrop macOS"
APP_NAME="UniDrop.app"
APP_SUPPORT_TARGET="~/Library/Application Support/UniDrop"
CODESIGN_IDENTITY="${UNIDROP_CODESIGN_IDENTITY:--}"
NOTARY_PROFILE="${UNIDROP_NOTARY_PROFILE:-}"

STAGE_DIR="$BUILD_ROOT/stage"
APP_PATH="$STAGE_DIR/$APP_NAME"
CONTENTS_DIR="$APP_PATH/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
SUPPORT_DIR="$RESOURCES_DIR/Support"
ICONSET_DIR="$BUILD_ROOT/UniDrop.iconset"
SOURCE_FILE="$PROJECT_ROOT/gateway-macos/src/windrop_menubar.swift"
BINARY_FILE="$MACOS_DIR/UniDropGateway"
ICON_FILE="$RESOURCES_DIR/UniDrop.icns"

rm -rf "$BUILD_ROOT" "$DMG_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$ICONSET_DIR" "$SUPPORT_DIR/gateway-macos" "$SUPPORT_DIR/scripts"

swiftc -framework AppKit "$SOURCE_FILE" -o "$BINARY_FILE"
chmod 755 "$BINARY_FILE"

python3 - "$ICONSET_DIR" <<'PY'
import struct
import sys
import zlib
from pathlib import Path

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)

def inside_drop(x, y):
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
    rows = []
    for py in range(size):
        row = bytearray([0])
        for px in range(size):
            covered = 0
            for sy in range(scale):
                for sx in range(scale):
                    x = (px + (sx + 0.5) / scale) / size
                    y = (py + (sy + 0.5) / scale) / size
                    if inside_drop(x, y):
                        covered += 1
            alpha = round(255 * covered / (scale * scale))
            row.extend((0, 122, 255, alpha) if alpha else (0, 0, 0, 0))
        rows.append(bytes(row))
    raw = b"".join(rows)

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
/usr/bin/plutil -insert UniDropProjectRoot -string "$APP_SUPPORT_TARGET" "$CONTENTS_DIR/Info.plist"

mkdir -p "$SUPPORT_DIR/gateway-macos/src" "$SUPPORT_DIR/gateway-macos/config"
cp "$PROJECT_ROOT/gateway-macos/src/discovery_test.py" "$SUPPORT_DIR/gateway-macos/src/"
cp "$PROJECT_ROOT/gateway-macos/config/discovery-test.toml" "$SUPPORT_DIR/gateway-macos/config/"
if [ -f "$PROJECT_ROOT/gateway-macos/config/discovery-windows.toml" ]; then
    cp "$PROJECT_ROOT/gateway-macos/config/discovery-windows.toml" "$SUPPORT_DIR/gateway-macos/config/"
fi
cp "$PROJECT_ROOT"/scripts/*.sh "$SUPPORT_DIR/scripts/"
cp "$PROJECT_ROOT"/scripts/*.py "$SUPPORT_DIR/scripts/"
chmod 755 "$SUPPORT_DIR"/scripts/*.sh "$SUPPORT_DIR"/scripts/*.py "$SUPPORT_DIR/gateway-macos/src/discovery_test.py"

/usr/bin/plutil -insert NSLocalNetworkUsageDescription -string "UniDrop sucht lokale Windows- und Android-Empfänger und leitet AirDrop-Dateien an sie weiter." "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert NSBonjourServices -array "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert NSBonjourServices.0 -string "_airdrop._tcp" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert NSBonjourServices.1 -string "_http._tcp" "$CONTENTS_DIR/Info.plist"

if [ "${UNIDROP_SKIP_CODESIGN:-0}" != "1" ]; then
    /usr/bin/codesign --force --deep --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP_PATH" 2>/dev/null \
        || /usr/bin/codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP_PATH"
fi

ln -s /Applications "$STAGE_DIR/Applications"

BACKGROUND_DIR="$STAGE_DIR/.background"
BACKGROUND_FILE="$BACKGROUND_DIR/background.png"
mkdir -p "$BACKGROUND_DIR"
python3 - "$BACKGROUND_FILE" <<'PY'
import math
import random
import struct
import sys
import zlib
from pathlib import Path

path = Path(sys.argv[1])
width, height = 760, 420
random.seed(42)

def blend(a, b, t):
    return tuple(round(a[i] * (1 - t) + b[i] * t) for i in range(3))

def in_panel(x, y, x1, y1, x2, y2):
    return x1 <= x <= x2 and y1 <= y <= y2

def draw_rect(pixel, color, alpha):
    return tuple(round(pixel[i] * (1 - alpha) + color[i] * alpha) for i in range(3))

rows = []
for y in range(height):
    row = bytearray([0])
    for x in range(width):
        t = y / max(1, height - 1)
        base = blend((31, 25, 38), (14, 15, 20), t)
        wave = int(10 * math.sin((x + y * 0.7) / 42.0))
        noise = random.randint(-7, 7)
        color = tuple(max(0, min(255, c + wave + noise)) for c in base)

        for panel in ((72, 88, 272, 292), (488, 88, 688, 292)):
            if in_panel(x, y, *panel):
                color = draw_rect(color, (220, 220, 235), 0.08)
                x1, y1, x2, y2 = panel
                border = x in {x1, x1 + 1, x2 - 1, x2} or y in {y1, y1 + 1, y2 - 1, y2}
                if border:
                    color = draw_rect(color, (235, 235, 245), 0.28)

        if 327 <= x <= 435 and 190 <= y <= 230:
            color = draw_rect(color, (180, 180, 190), 0.25)
        if 435 < x <= 470 and abs(y - 210) <= (x - 435) * 0.55:
            color = draw_rect(color, (180, 180, 190), 0.25)

        row.extend((*color, 255))
    rows.append(bytes(row))

raw = b"".join(rows)

def chunk(kind, data):
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

path.write_bytes(
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(raw, 9))
    + chunk(b"IEND", b"")
)
PY

if command -v SetFile >/dev/null 2>&1; then
    SetFile -a V "$BACKGROUND_DIR" || true
fi

RW_DMG="$BUILD_ROOT/UniDrop-macOS-rw.dmg"
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGE_DIR" -ov -format UDRW "$RW_DMG"

MOUNT_DIR="$BUILD_ROOT/mount"
mkdir -p "$MOUNT_DIR"
hdiutil attach "$RW_DMG" -nobrowse -mountpoint "$MOUNT_DIR"

osascript <<OSA &
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {120, 120, 880, 540}
        set theOptions to icon view options of container window
        set arrangement of theOptions to not arranged
        set icon size of theOptions to 96
        set background picture of theOptions to (POSIX file "$MOUNT_DIR/.background/background.png" as alias)
        set position of item "UniDrop.app" of container window to {170, 210}
        set position of item "Applications" of container window to {590, 210}
        close
    end tell
end tell
OSA
OSASCRIPT_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! kill -0 "$OSASCRIPT_PID" 2>/dev/null; then
        break
    fi
    sleep 0.5
done
if kill -0 "$OSASCRIPT_PID" 2>/dev/null; then
    kill "$OSASCRIPT_PID" 2>/dev/null || true
fi
wait "$OSASCRIPT_PID" 2>/dev/null || true

sync
hdiutil detach "$MOUNT_DIR"
hdiutil convert "$RW_DMG" -format UDZO -ov -o "$DMG_PATH"

if [ "${UNIDROP_SKIP_CODESIGN:-0}" != "1" ] && [ "$CODESIGN_IDENTITY" != "-" ]; then
    /usr/bin/codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG_PATH" 2>/dev/null || true
fi

if [ -n "$NOTARY_PROFILE" ]; then
    if [ "$CODESIGN_IDENTITY" = "-" ]; then
        printf 'UNIDROP_NOTARY_PROFILE requires UNIDROP_CODESIGN_IDENTITY with a Developer ID Application certificate.\n' >&2
        exit 1
    fi
    /usr/bin/xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    /usr/bin/xcrun stapler staple "$DMG_PATH"
fi

printf 'Built %s\n' "$DMG_PATH"
