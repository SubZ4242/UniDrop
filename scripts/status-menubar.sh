#!/bin/sh
set -eu

LAUNCHD_LABEL="com.windrop.gateway.menubar"

if ! launchctl print "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1; then
    APP_PID=$(pgrep -f "/Applications/UniDrop.app/Contents/MacOS/UniDropGateway" | sed -n '1p' || true)
    if [ -n "$APP_PID" ]; then
        printf 'Status: running\n'
        printf 'PID: %s\n' "$APP_PID"
        exit 0
    fi
    printf 'Status: stopped\n'
    exit 0
fi

launchctl print "gui/$(id -u)/$LAUNCHD_LABEL" | awk '
    /state =/ && !seen_state {
        print "Status: " $3
        seen_state = 1
    }
    /pid =/ && !seen_pid {
        print "PID: " $3
        seen_pid = 1
    }
    /runs =/ && !seen_runs {
        print "Runs: " $3
        seen_runs = 1
    }
'
