#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
RUNTIME_DIR="$PROJECT_ROOT/.runtime/discovery-test"
PID_FILE="$RUNTIME_DIR/server.pid"
LAUNCHD_LABEL="com.windrop.gateway.discovery-test"

if ! launchctl print "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1; then
    printf 'Status: stopped\n'
    exit 1
fi

if [ ! -f "$PID_FILE" ]; then
    printf 'Status: launchd job loaded, service not ready\n'
    launchctl print "gui/$(id -u)/$LAUNCHD_LABEL" | sed -n '1,45p'
    exit 1
fi

SERVER_PID=$(sed -n '1p' "$PID_FILE")
printf 'Status: running\n'
ps -p "$SERVER_PID" -o pid=,ppid=,etime=,%cpu=,rss=,command=
printf 'launchd job:\n'
launchctl print "gui/$(id -u)/$LAUNCHD_LABEL" | rg 'state =|pid =|runs =|last exit code' || true
launchctl print "gui/$(id -u)/$LAUNCHD_LABEL" | rg 'keepalive =|KeepAlive|successful exit' || true
if [ -f "$RUNTIME_DIR/state.json" ]; then
    python3 -m json.tool "$RUNTIME_DIR/state.json"
fi
printf 'Bound listener:\n'
lsof -nP -a -p "$SERVER_PID" -iTCP -sTCP:LISTEN 2>/dev/null || true
