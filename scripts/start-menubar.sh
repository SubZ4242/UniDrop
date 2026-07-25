#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
RUNTIME_DIR="$PROJECT_ROOT/.runtime/menubar"
SOURCE_FILE="$PROJECT_ROOT/gateway-macos/src/windrop_menubar.swift"
BINARY_FILE="$RUNTIME_DIR/windrop-menubar"
LAUNCHD_LABEL="com.windrop.gateway.menubar"

if launchctl print "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1; then
    printf 'UniDrop menubar is already running.\n'
    "$SCRIPT_DIR/status-menubar.sh"
    exit 0
fi

mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"

if [ ! -x "$BINARY_FILE" ] || [ "$SOURCE_FILE" -nt "$BINARY_FILE" ]; then
    swiftc -framework AppKit "$SOURCE_FILE" -o "$BINARY_FILE"
    chmod 700 "$BINARY_FILE"
fi

: >"$RUNTIME_DIR/stdout.log"
: >"$RUNTIME_DIR/stderr.log"

launchctl submit \
    -l "$LAUNCHD_LABEL" \
    -o "$RUNTIME_DIR/stdout.log" \
    -e "$RUNTIME_DIR/stderr.log" \
    -- "$BINARY_FILE" --project-root "$PROJECT_ROOT"

sleep 0.5
"$SCRIPT_DIR/status-menubar.sh"
