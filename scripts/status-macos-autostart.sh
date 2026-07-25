#!/bin/sh
set -eu
PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH

for LABEL in com.windrop.gateway.menubar.autostart com.windrop.gateway.discovery.autostart; do
    if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
        printf '%s: installed/running\n' "$LABEL"
    elif [ -f "$HOME/Library/LaunchAgents/$LABEL.plist" ]; then
        printf '%s: installed/not-loaded\n' "$LABEL"
    else
        printf '%s: not-installed\n' "$LABEL"
    fi
done
