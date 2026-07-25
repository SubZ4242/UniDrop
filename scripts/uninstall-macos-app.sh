#!/bin/sh
set -eu
PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH

APP_PATH="/Applications/UniDrop.app"

if [ -d "$APP_PATH" ]; then
    rm -rf "$APP_PATH"
    printf 'Removed %s\n' "$APP_PATH"
else
    printf '%s is not installed.\n' "$APP_PATH"
fi
