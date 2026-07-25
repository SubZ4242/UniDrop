#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
RUNTIME_DIR="$PROJECT_ROOT/.runtime/discovery-test"
SERVICE_ID=7c91d40a88f2
LAUNCHD_LABEL="com.windrop.gateway.discovery-test"

printf 'AWDL interface\n'
/sbin/ifconfig awdl0 2>&1 || true

printf '\nNative macOS AirDrop process and transport\n'
pgrep -alf '/usr/libexec/sharingd' || printf 'sharingd not found\n'
SHARINGD_PID=$(pgrep -x sharingd | sed -n '1p' || true)
if [ -n "$SHARINGD_PID" ]; then
    lsof -nP -a -p "$SHARINGD_PID" -i 2>/dev/null || true
fi
printf 'Recent native sharingd evidence involving UniDrop port 8872:\n'
/usr/bin/log show --last 10m --style compact \
    --predicate 'process == "sharingd" AND eventMessage CONTAINS "8872"' \
    2>/dev/null \
    | rg 'Bonjour|interface: awdl0|bytes in/out' \
    | tail -n 30 \
    || true

printf '\nUniDrop process, identity, endpoint, and bound interface\n'
launchctl print "gui/$(id -u)/$LAUNCHD_LABEL" 2>/dev/null | rg 'state =|pid =|program =|arguments =|runs =' || printf 'UniDrop launchd job not found\n'
if [ -f "$RUNTIME_DIR/server.pid" ]; then
    WINDROP_PID=$(sed -n '1p' "$RUNTIME_DIR/server.pid")
    ps -p "$WINDROP_PID" -o pid=,ppid=,state=,etime=,%cpu=,rss=,command= || true
fi
if [ -f "$RUNTIME_DIR/state.json" ]; then
    python3 -m json.tool "$RUNTIME_DIR/state.json"
else
    printf 'No UniDrop runtime state found.\n'
fi
if [ -f "$RUNTIME_DIR/server.pid" ]; then
    lsof -nP -a -p "$WINDROP_PID" -iTCP -sTCP:LISTEN 2>/dev/null || true
fi
if [ -f "$RUNTIME_DIR/bonjour.pid" ]; then
    BONJOUR_PID=$(sed -n '1p' "$RUNTIME_DIR/bonjour.pid")
    ps -p "$BONJOUR_PID" -o pid=,ppid=,state=,etime=,%cpu=,rss=,command= || true
fi

printf '\nObserved _airdrop._tcp services on awdl0 (4-second browse)\n'
printf 'On macOS 26.3 the native receiver is dynamic and may not publish a legacy PTR; WinDrop ID is %s.\n' "$SERVICE_ID"
dns-sd -i awdl0 -t 4 -B _airdrop._tcp local. 2>&1 || true

printf '\n_airdrop._tcp zone data on awdl0 (4-second browse)\n'
dns-sd -i awdl0 -t 4 -Z _airdrop._tcp local. 2>&1 || true

printf '\nUniDrop service resolution\n'
dns-sd -i awdl0 -t 4 -L "$SERVICE_ID" _airdrop._tcp local. 2>&1 || true

printf '\nUniDrop HTTPS /Discover probe\n'
if [ -f "$RUNTIME_DIR/state.json" ]; then
    python3 "$SCRIPT_DIR/probe-discovery-test.py" "$RUNTIME_DIR/state.json" 2>&1 || true
else
    printf 'No UniDrop runtime state found.\n'
fi

printf '\nRecent WinDrop server log\n'
if [ -f "$RUNTIME_DIR/server.log" ]; then
    tail -n 40 "$RUNTIME_DIR/server.log"
else
    printf 'No server log found.\n'
fi

printf '\nRecent WinDrop Bonjour registration log\n'
if [ -f "$RUNTIME_DIR/bonjour.log" ]; then
    tail -n 40 "$RUNTIME_DIR/bonjour.log"
else
    printf 'No Bonjour log found.\n'
fi
