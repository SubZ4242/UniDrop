#!/bin/sh
set -eu
PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH

LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
MENUBAR_LABEL="com.windrop.gateway.menubar.autostart"
DISCOVERY_LABEL="com.windrop.gateway.discovery.autostart"
MENUBAR_PLIST="$LAUNCH_AGENTS_DIR/$MENUBAR_LABEL.plist"
DISCOVERY_PLIST="$LAUNCH_AGENTS_DIR/$DISCOVERY_LABEL.plist"

launchctl bootout "gui/$(id -u)/$MENUBAR_LABEL" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$DISCOVERY_LABEL" 2>/dev/null || true
rm -f "$MENUBAR_PLIST" "$DISCOVERY_PLIST"

printf 'UniDrop macOS autostart uninstalled.\n'
