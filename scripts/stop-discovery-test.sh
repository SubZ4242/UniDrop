#!/bin/sh
set -eu
PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
RUNTIME_DIR="${UNIDROP_RUNTIME_DIR:-$PROJECT_ROOT/.runtime/discovery-test}"
PID_FILE="$RUNTIME_DIR/server.pid"
LAUNCHD_LABEL="${UNIDROP_LAUNCHD_LABEL:-com.windrop.gateway.discovery-test}"
SERVICE_NAME="${UNIDROP_SERVICE_NAME:-UniDrop discovery test}"

if ! launchctl print "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1; then
    rm -f "$PID_FILE" "$RUNTIME_DIR/bonjour.pid" "$RUNTIME_DIR/state.json"
    printf '%s is not running (launchd job absent).\n' "$SERVICE_NAME"
    exit 0
fi

SERVER_PID=$(sed -n '1p' "$PID_FILE" 2>/dev/null || true)
launchctl remove "$LAUNCHD_LABEL"
ATTEMPT=0
while launchctl print "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1 && [ "$ATTEMPT" -lt 40 ]; do
    ATTEMPT=$((ATTEMPT + 1))
    sleep 0.25
done

if launchctl print "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1; then
    printf 'launchd job did not unload in time; no force-kill was attempted.\n' >&2
    exit 1
fi

rm -f "$PID_FILE" "$RUNTIME_DIR/bonjour.pid" "$RUNTIME_DIR/state.json"
printf '%s stopped (former PID %s). TLS material and logs remain in %s for reuse/inspection.\n' "$SERVICE_NAME" "${SERVER_PID:-unknown}" "$RUNTIME_DIR"
