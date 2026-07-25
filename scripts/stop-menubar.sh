#!/bin/sh
set -eu
PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH

LAUNCHD_LABEL="com.windrop.gateway.menubar"

if ! launchctl print "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1; then
    printf 'UniDrop menubar is not running.\n'
    exit 0
fi

launchctl remove "$LAUNCHD_LABEL"
printf 'UniDrop menubar stopped.\n'
