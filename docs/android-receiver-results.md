# UniDrop Android receiver results

## Implemented

- Native Android APK under `client-android/`
- Foreground service receiver
- Minimal GUI with start/stop, port, autostart checkbox, receiver URL display,
  and Android folder picker
- Boot receiver for optional Android autostart
- HTTP API compatible with the current macOS gateway:
  - `GET /health`
  - `POST /api/transfers/archive`
- Supported upload content types:
  - `application/x-cpio`
  - `application/x-dvzip`
- Default output folder: `Downloads/UniDrop`

## Build/install

```sh
./scripts/build-android-apk.sh
./scripts/install-android-apk.sh
```

Output APK:

```text
client-android/dist/UniDropReceiver.apk
```

Installed package:

```text
com.unidrop.receiver
```

## Verification pattern

```text
GET http://PHONE_LAN_IP:8873/health
POST http://PHONE_LAN_IP:8873/api/transfers/archive
```

## Current limitations

- The macOS gateway still uses config keys named `windows_host` and
  `windows_port`; behavior is generic, naming should be cleaned up later.
- MVP spools incoming uploads to temporary files before extracting.
- Android always-on receiving depends on Foreground Service plus vendor battery
  settings.
- Pairing/TLS between Mac and Android is not implemented in this MVP.
