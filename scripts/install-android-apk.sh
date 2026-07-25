#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
APK="$PROJECT_ROOT/client-android/dist/UniDropReceiver-debug.apk"
ADB=${ADB:-${ANDROID_HOME:-${ANDROID_SDK_ROOT:-"$HOME/Library/Android/sdk"}}/platform-tools/adb}

if [ ! -x "$ADB" ]; then
    printf 'adb not found. Set ADB or ANDROID_HOME.\n' >&2
    exit 1
fi

if [ ! -f "$APK" ]; then
    "$SCRIPT_DIR/build-android-apk.sh"
fi

"$ADB" start-server >/dev/null
DEVICES=$("$ADB" devices | awk 'NR > 1 && $2 == "device" {print $1}')
COUNT=$(printf '%s\n' "$DEVICES" | sed '/^$/d' | wc -l | tr -d ' ')
if [ "$COUNT" -eq 0 ]; then
    printf 'No authorized Android device found. Enable USB debugging and accept the RSA prompt on the phone.\n' >&2
    "$ADB" devices -l >&2
    exit 1
fi
if [ "$COUNT" -gt 1 ]; then
    printf 'More than one Android device found. Set ADB_SERIAL.\n' >&2
    "$ADB" devices -l >&2
    exit 1
fi

SERIAL=${ADB_SERIAL:-$(printf '%s\n' "$DEVICES" | sed -n '1p')}
"$ADB" -s "$SERIAL" install -r "$APK"
"$ADB" -s "$SERIAL" shell monkey -p com.unidrop.receiver 1 >/dev/null
printf 'Installed and opened UniDrop Receiver on %s\n' "$SERIAL"
