#!/bin/sh
set -eu
PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
RUNTIME_DIR="${UNIDROP_RUNTIME_DIR:-$PROJECT_ROOT/.runtime/discovery-test}"
PID_FILE="$RUNTIME_DIR/server.pid"
LAUNCHD_LABEL="${UNIDROP_LAUNCHD_LABEL:-com.windrop.gateway.discovery-test}"
SERVICE_PLIST="$RUNTIME_DIR/$LAUNCHD_LABEL.plist"
CONFIG_FILE="${UNIDROP_CONFIG_FILE:-$PROJECT_ROOT/gateway-macos/config/discovery-test.toml}"
SERVER_FILE="$PROJECT_ROOT/gateway-macos/src/discovery_test.py"
STATUS_SCRIPT="${UNIDROP_STATUS_SCRIPT:-$SCRIPT_DIR/status-discovery-test.sh}"
SERVICE_NAME="${UNIDROP_SERVICE_NAME:-UniDrop discovery test}"

if launchctl print "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1; then
    printf '%s launchd job is already loaded.\n' "$SERVICE_NAME"
    "$STATUS_SCRIPT"
    exit 0
fi

PYTHON_BIN=${WINDROP_PYTHON:-$(command -v python3)}
PYTHON_VERSION=$("$PYTHON_BIN" -c 'import sys; print(sys.version_info.major * 100 + sys.version_info.minor)')
if [ "$PYTHON_VERSION" -lt 311 ]; then
    printf 'Python 3.11 or newer is required; found %s.\n' "$("$PYTHON_BIN" --version 2>&1)" >&2
    exit 1
fi

mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"
: >"$RUNTIME_DIR/server.log"
: >"$RUNTIME_DIR/stdout.log"
rm -f "$PID_FILE" "$RUNTIME_DIR/state.json" "$RUNTIME_DIR/bonjour.pid"

DEBUG_ARGUMENT=
if [ "${WINDROP_DEBUG:-0}" = "1" ]; then
    DEBUG_ARGUMENT=--debug
fi

rm -f "$SERVICE_PLIST"
/usr/bin/plutil -create xml1 "$SERVICE_PLIST"
/usr/bin/plutil -insert Label -string "$LAUNCHD_LABEL" "$SERVICE_PLIST"
/usr/bin/plutil -insert ProgramArguments -array "$SERVICE_PLIST"
/usr/bin/plutil -insert ProgramArguments.0 -string /usr/bin/caffeinate "$SERVICE_PLIST"
/usr/bin/plutil -insert ProgramArguments.1 -string -i "$SERVICE_PLIST"
/usr/bin/plutil -insert ProgramArguments.2 -string -s "$SERVICE_PLIST"
/usr/bin/plutil -insert ProgramArguments.3 -string "$PYTHON_BIN" "$SERVICE_PLIST"
/usr/bin/plutil -insert ProgramArguments.4 -string "$SERVER_FILE" "$SERVICE_PLIST"
/usr/bin/plutil -insert ProgramArguments.5 -string --config "$SERVICE_PLIST"
/usr/bin/plutil -insert ProgramArguments.6 -string "$CONFIG_FILE" "$SERVICE_PLIST"
/usr/bin/plutil -insert ProgramArguments.7 -string --runtime-dir "$SERVICE_PLIST"
/usr/bin/plutil -insert ProgramArguments.8 -string "$RUNTIME_DIR" "$SERVICE_PLIST"
if [ -n "$DEBUG_ARGUMENT" ]; then
    /usr/bin/plutil -insert ProgramArguments.9 -string "$DEBUG_ARGUMENT" "$SERVICE_PLIST"
fi
/usr/bin/plutil -insert RunAtLoad -bool true "$SERVICE_PLIST"
/usr/bin/plutil -insert KeepAlive -bool true "$SERVICE_PLIST"
/usr/bin/plutil -insert WorkingDirectory -string "$PROJECT_ROOT" "$SERVICE_PLIST"
/usr/bin/plutil -insert StandardOutPath -string "$RUNTIME_DIR/stdout.log" "$SERVICE_PLIST"
/usr/bin/plutil -insert StandardErrorPath -string "$RUNTIME_DIR/server.log" "$SERVICE_PLIST"

launchctl bootstrap "gui/$(id -u)" "$SERVICE_PLIST"

ATTEMPT=0
while [ "$ATTEMPT" -lt 160 ]; do
    if ! launchctl print "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1; then
        printf '%s failed to start.\n' "$SERVICE_NAME" >&2
        tail -n 40 "$RUNTIME_DIR/server.log" >&2
        exit 1
    fi
    if [ -f "$RUNTIME_DIR/state.json" ]; then
        SERVER_PID=$(sed -n '1p' "$PID_FILE")
        printf '%s started (PID %s).\n' "$SERVICE_NAME" "$SERVER_PID"
        "$STATUS_SCRIPT"
        exit 0
    fi
    ATTEMPT=$((ATTEMPT + 1))
    sleep 0.25
done

printf '%s did not become ready in time.\n' "$SERVICE_NAME" >&2
tail -n 40 "$RUNTIME_DIR/server.log" >&2
launchctl remove "$LAUNCHD_LABEL" 2>/dev/null || true
exit 1
