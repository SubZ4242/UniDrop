#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
ANDROID_ROOT="$PROJECT_ROOT/client-android"
APP_ROOT="$ANDROID_ROOT/app/src/main"
BUILD_DIR="$ANDROID_ROOT/build"
DIST_DIR="$ANDROID_ROOT/dist"
KEY_DIR="$ANDROID_ROOT/.debug"

SDK_ROOT=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-"$HOME/Library/Android/sdk"}}
if [ ! -d "$SDK_ROOT" ]; then
    printf 'Android SDK not found. Set ANDROID_HOME or ANDROID_SDK_ROOT.\n' >&2
    exit 1
fi

PLATFORM_DIR=$(find "$SDK_ROOT/platforms" -maxdepth 1 -type d -name 'android-*' | sort -V | tail -n 1)
BUILD_TOOLS_DIR=$(find "$SDK_ROOT/build-tools" -maxdepth 1 -type d | sort -V | tail -n 1)
ANDROID_JAR="$PLATFORM_DIR/android.jar"
AAPT2="$BUILD_TOOLS_DIR/aapt2"
D8="$BUILD_TOOLS_DIR/d8"
ZIPALIGN="$BUILD_TOOLS_DIR/zipalign"
APKSIGNER="$BUILD_TOOLS_DIR/apksigner"

for tool in "$ANDROID_JAR" "$AAPT2" "$D8" "$ZIPALIGN" "$APKSIGNER"; do
    if [ ! -e "$tool" ]; then
        printf 'Required Android build tool missing: %s\n' "$tool" >&2
        exit 1
    fi
done

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/compiled-res" "$BUILD_DIR/gen" "$BUILD_DIR/classes" "$BUILD_DIR/dex" "$DIST_DIR" "$KEY_DIR"

"$AAPT2" compile --dir "$APP_ROOT/res" -o "$BUILD_DIR/compiled-res/resources.zip"
"$AAPT2" link \
    -I "$ANDROID_JAR" \
    --manifest "$APP_ROOT/AndroidManifest.xml" \
    --java "$BUILD_DIR/gen" \
    --min-sdk-version 26 \
    --target-sdk-version 35 \
    --version-code 1 \
    --version-name 0.1.0 \
    -o "$BUILD_DIR/resources.apk" \
    "$BUILD_DIR/compiled-res/resources.zip"

find "$APP_ROOT/java" "$BUILD_DIR/gen" -name '*.java' -print0 \
    | xargs -0 javac --release 17 -encoding UTF-8 -classpath "$ANDROID_JAR" -d "$BUILD_DIR/classes"

(cd "$BUILD_DIR/classes" && "$D8" --min-api 26 --lib "$ANDROID_JAR" --output "$BUILD_DIR/dex" $(find . -name '*.class'))

cp "$BUILD_DIR/resources.apk" "$BUILD_DIR/with-dex.apk"
(cd "$BUILD_DIR/dex" && zip -q -r "$BUILD_DIR/with-dex.apk" classes.dex)

"$ZIPALIGN" -f 4 "$BUILD_DIR/with-dex.apk" "$BUILD_DIR/aligned.apk"

KEYSTORE="$KEY_DIR/unidrop-debug.keystore"
if [ ! -f "$KEYSTORE" ]; then
    keytool -genkeypair \
        -keystore "$KEYSTORE" \
        -storepass android \
        -keypass android \
        -alias unidropdebug \
        -keyalg RSA \
        -keysize 2048 \
        -validity 10000 \
        -dname "CN=UniDrop Debug,O=UniDrop,C=DE" >/dev/null 2>&1
fi

"$APKSIGNER" sign \
    --ks "$KEYSTORE" \
    --ks-pass pass:android \
    --key-pass pass:android \
    --out "$DIST_DIR/UniDropReceiver-debug.apk" \
    "$BUILD_DIR/aligned.apk"

"$APKSIGNER" verify "$DIST_DIR/UniDropReceiver-debug.apk"
cp "$DIST_DIR/UniDropReceiver-debug.apk" "$ANDROID_ROOT/UniDropReceiver-debug.apk"
printf 'Built %s\n' "$DIST_DIR/UniDropReceiver-debug.apk"
printf 'Copied %s\n' "$ANDROID_ROOT/UniDropReceiver-debug.apk"
