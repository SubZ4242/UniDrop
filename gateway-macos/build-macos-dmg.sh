#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BUILD_ROOT="$PROJECT_ROOT/.runtime/macos-dmg"
DMG_PATH="$SCRIPT_DIR/UniDrop-macOS.dmg"
VOLUME_NAME="UniDrop macOS"
APP_NAME="UniDrop.app"
SUPPORT_NAME="UniDrop Support"
SUPPORT_INSTALLER_NAME="Install Support.command"
APP_SUPPORT_TARGET="~/Library/Application Support/UniDrop"

STAGE_DIR="$BUILD_ROOT/stage"
APP_PATH="$STAGE_DIR/$APP_NAME"
SUPPORT_DIR="$STAGE_DIR/.support/$SUPPORT_NAME"
CONTENTS_DIR="$APP_PATH/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
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

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP_PATH"
fi

mkdir -p "$SUPPORT_DIR/gateway-macos/src" "$SUPPORT_DIR/gateway-macos/config"
cp "$PROJECT_ROOT/gateway-macos/src/discovery_test.py" "$SUPPORT_DIR/gateway-macos/src/"
cp "$PROJECT_ROOT/gateway-macos/config/discovery-test.toml" "$SUPPORT_DIR/gateway-macos/config/"
if [ -f "$PROJECT_ROOT/gateway-macos/config/discovery-windows.toml" ]; then
    cp "$PROJECT_ROOT/gateway-macos/config/discovery-windows.toml" "$SUPPORT_DIR/gateway-macos/config/"
fi
cp "$PROJECT_ROOT"/scripts/*.sh "$SUPPORT_DIR/scripts/"
cp "$PROJECT_ROOT"/scripts/*.py "$SUPPORT_DIR/scripts/"
chmod 755 "$SUPPORT_DIR"/scripts/*.sh "$SUPPORT_DIR"/scripts/*.py "$SUPPORT_DIR/gateway-macos/src/discovery_test.py"

ln -s /Applications "$STAGE_DIR/Applications"

cat > "$STAGE_DIR/$SUPPORT_INSTALLER_NAME" <<'SH'
#!/bin/sh
set -eu

SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SUPPORT_SOURCE="$SOURCE_DIR/.support/UniDrop Support"
SUPPORT_TARGET="$HOME/Library/Application Support/UniDrop"

mkdir -p "$SUPPORT_TARGET"
ditto "$SUPPORT_SOURCE" "$SUPPORT_TARGET"

printf 'UniDrop Support wurde installiert.\n'
printf 'Support-Dateien: %s\n' "$SUPPORT_TARGET"
printf 'Ziehe UniDrop.app danach in Applications und starte die App dort.\n'
SH
chmod 755 "$STAGE_DIR/$SUPPORT_INSTALLER_NAME"

cat > "$STAGE_DIR/README.txt" <<'TXT'
UniDrop macOS Gateway

Installation:
1. UniDrop.app auf Applications ziehen.
2. "Install Support.command" starten.
3. UniDrop aus Applications starten.

Falls macOS warnt: Rechtsklick -> Oeffnen.

Die Gateway-Support-Dateien werden nach
~/Library/Application Support/UniDrop kopiert.

Zum Entfernen:
1. UniDrop beenden.
2. /Applications/UniDrop.app loeschen.
3. ~/Library/Application Support/UniDrop loeschen.
TXT

hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

printf 'Built %s\n' "$DMG_PATH"
