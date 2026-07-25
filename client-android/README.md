# UniDrop Android Receiver

Small native Android receiver for the UniDrop macOS gateway.

The app listens on the local network and implements the same MVP API as the
Windows receiver:

- `GET /health`
- `POST /api/transfers/archive`

Received AirDrop archives are extracted into the native Android Downloads
collection under `Downloads/UniDrop`.

## Build

```sh
./scripts/build-android-apk.sh
```

Output:

```text
client-android/dist/UniDropReceiver-debug.apk
```

## Install by USB

Enable Developer Options and USB debugging on the Android phone, accept the RSA
prompt, then run:

```sh
./scripts/install-android-apk.sh
```

## Runtime

Open UniDrop Receiver on the phone, press "Empfänger starten", then configure
the macOS gateway to forward to the displayed phone URL, usually:

```toml
[network]
windows_host = "PHONE_WIFI_IP"
windows_port = 8873

[forwarding]
enabled = true
```

The Android app uses a foreground service for reliable receiving. Android may
still require disabling battery optimization for always-on behavior on Samsung
devices.

The Android UI also has a "Mac suchen" button. It scans the phone's local `/24`
network for the Mac gateway endpoint, defaulting to:

```text
http://<MAC-IP>:8872/gateway
```

This discovery is informational/configuration support for the receiver app; the
actual AirDrop-facing receiver still runs on the Mac gateway.
