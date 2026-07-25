#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
MENUBAR_PLIST="$LAUNCH_AGENTS_DIR/com.windrop.gateway.menubar.autostart.plist"
DISCOVERY_PLIST="$LAUNCH_AGENTS_DIR/com.windrop.gateway.discovery.autostart.plist"
APP_BINARY="/Applications/UniDrop.app/Contents/MacOS/UniDropGateway"

mkdir -p "$LAUNCH_AGENTS_DIR"
rm -f "$MENUBAR_PLIST" "$DISCOVERY_PLIST"

/usr/bin/plutil -create xml1 "$MENUBAR_PLIST"
/usr/bin/plutil -insert Label -string com.windrop.gateway.menubar.autostart "$MENUBAR_PLIST"
if [ -x "$APP_BINARY" ]; then
    /usr/bin/plutil -insert ProgramArguments -json "[\"$APP_BINARY\"]" "$MENUBAR_PLIST"
else
    /usr/bin/plutil -insert ProgramArguments -json "[\"$PROJECT_ROOT/scripts/start-menubar.sh\"]" "$MENUBAR_PLIST"
fi
/usr/bin/plutil -insert RunAtLoad -bool true "$MENUBAR_PLIST"
/usr/bin/plutil -insert StandardOutPath -string "$PROJECT_ROOT/.runtime/menubar/autostart.out.log" "$MENUBAR_PLIST"
/usr/bin/plutil -insert StandardErrorPath -string "$PROJECT_ROOT/.runtime/menubar/autostart.err.log" "$MENUBAR_PLIST"

/usr/bin/plutil -create xml1 "$DISCOVERY_PLIST"
/usr/bin/plutil -insert Label -string com.windrop.gateway.discovery.autostart "$DISCOVERY_PLIST"
/usr/bin/plutil -insert ProgramArguments -json "[\"$PROJECT_ROOT/scripts/start-discovery-test.sh\"]" "$DISCOVERY_PLIST"
/usr/bin/plutil -insert RunAtLoad -bool true "$DISCOVERY_PLIST"
/usr/bin/plutil -insert KeepAlive -json '{"SuccessfulExit":false}' "$DISCOVERY_PLIST"
/usr/bin/plutil -insert StandardOutPath -string "$PROJECT_ROOT/.runtime/discovery-test/autostart.out.log" "$DISCOVERY_PLIST"
/usr/bin/plutil -insert StandardErrorPath -string "$PROJECT_ROOT/.runtime/discovery-test/autostart.err.log" "$DISCOVERY_PLIST"

launchctl bootstrap "gui/$(id -u)" "$MENUBAR_PLIST" 2>/dev/null || launchctl kickstart -k "gui/$(id -u)/com.windrop.gateway.menubar.autostart"
launchctl bootstrap "gui/$(id -u)" "$DISCOVERY_PLIST" 2>/dev/null || launchctl kickstart -k "gui/$(id -u)/com.windrop.gateway.discovery.autostart"

printf 'UniDrop macOS autostart installed for menubar and discovery.\n'
