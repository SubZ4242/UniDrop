# 💧 UniDrop

UniDrop is an experimental AirDrop-style gateway for receiving files on
Windows and Android.

Important: UniDrop currently requires a Mac on the same network. The Mac stays
AirDrop-facing, while Windows and Android receiver apps accept forwarded uploads
over the local network and save them into a configured folder.

## 🧭 How It Works

```text
iPhone / iPad / Mac
        |
        | AirDrop over AWDL
        v
macOS UniDrop Gateway
        |
        | local HTTP forwarding
        v
Windows or Android UniDrop Receiver
```

## 🍎 macOS Gateway

Easiest install: download/open `gateway-macos/UniDrop-macOS.dmg`, then drag
`UniDrop.app` onto `Applications` in the DMG window. Start `UniDrop` from
Applications afterwards. On first launch the app installs its gateway support
files into `~/Library/Application Support/UniDrop` automatically.

Build the DMG locally:

```sh
./gateway-macos/build-macos-dmg.sh
```

For a DMG that opens on another Mac without the manual
`Privacy & Security` → `Open Anyway` step, build it with an Apple
`Developer ID Application` certificate and notarize it:

```sh
UNIDROP_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
UNIDROP_NOTARY_PROFILE="unidrop-notary" \
./gateway-macos/build-macos-dmg.sh
```

Create the notary profile once with Apple's `notarytool` and your Apple
Developer account. Without Developer ID signing and notarization, macOS
Gatekeeper can still require a manual approval after downloading the DMG from
GitHub.

Manual developer install:

```sh
./scripts/install-macos-app.sh
open "/Applications/UniDrop.app"
```

The app:

- starts the gateway automatically on launch;
- shows the Mac LAN IP;
- exposes a lightweight LAN discovery endpoint at `http://<MAC-IP>:8873/gateway`;
- scans the local `/24` network for compatible Windows/Android receivers on the configured receiver port;
- publishes one AirDrop target per discovered receiver;
- keeps Windows/Android receivers on port `8873` by default;
- uses separate internal macOS AirDrop ports per visible target when multiple receivers are online.

Debug commands:

```sh
./scripts/start-discovery-test.sh
./scripts/status-discovery-test.sh
./scripts/probe-discovery-test.py .runtime/discovery-test/state.json
./scripts/stop-discovery-test.sh
```

Receiver auto-detection:

```sh
./scripts/discover-receiver.py --port 8873
```

## 🤖 Android Receiver

Build and install by USB debugging:

```sh
./scripts/build-android-apk.sh
./scripts/install-android-apk.sh
```

The Android app:

- runs a foreground service;
- keeps a CPU wake lock while the receiver is running so Samsung/Doze does not suspend the HTTP listener;
- can scan the local `/24` network for the UniDrop Mac gateway on the configured port;
- listens on the configured port, default `8873`;
- saves to `Downloads/UniDrop` by default;
- can use a manually selected Android folder through the system folder picker.

On Samsung phones, also disable battery optimization for UniDrop or whitelist it
with ADB for reliable always-on receiving:

```sh
adb shell dumpsys deviceidle whitelist +com.unidrop.receiver
```

APK output:

```text
client-android/UniDropReceiver.apk
client-android/dist/UniDropReceiver.apk
```

The repository includes `client-android/UniDropReceiver.apk` as a prebuilt
debug APK for quick manual installation.

## 🪟 Windows Receiver

Build the Windows tray app and bundled receiver:

```powershell
.\scripts\publish-windows.ps1
.\client-windows\UniDrop.exe
```

The Windows tray app can configure:

- listen URL;
- Mac gateway URL with a scan button;
- destination folder with a browse button;
- Windows autostart;
- automatic receiving;
- opening Explorer after receiving files.

The current Windows project still keeps some internal source folder names for
compatibility with the existing prototype. The downloadable Windows files are
published as `client-windows/UniDrop.exe` and `client-windows/UniDropReceiver.exe`.

## 🚧 Status

This is an early prototype. The macOS gateway can publish separate AirDrop
targets for discovered Android and Windows receivers and forward received test
uploads to them over the local network.

## 🔐 Safety

Do not store production secrets, pairing tokens, or private certificates in this
repository.
