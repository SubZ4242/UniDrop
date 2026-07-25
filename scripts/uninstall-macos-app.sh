#!/bin/sh
set -eu

APP_PATH="/Applications/UniDrop.app"

if [ -d "$APP_PATH" ]; then
    rm -rf "$APP_PATH"
    printf 'Removed %s\n' "$APP_PATH"
else
    printf '%s is not installed.\n' "$APP_PATH"
fi
