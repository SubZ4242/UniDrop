# UniDrop for Windows

The Windows client receives AirDrop transfers forwarded by the UniDrop Mac
gateway and saves them locally.

Use the tray app for normal operation:

```powershell
.\scripts\publish-windows.ps1
.\client-windows\UniDrop.exe
```

`UniDropReceiver.exe` is the background receiver service. The tray app starts it
automatically when Auto-Empfang is enabled. Both EXEs are published into
`client-windows/` for quick manual testing from GitHub.

## Tray App

The tray app provides:

- A droplet tray icon
- One large AN/AUS receiver toggle
- Mac gateway URL detection via "Mac suchen"
- Listen URL configuration
- Destination folder configuration
- Windows autostart
- Auto-Empfang
- Ordner nach Empfang oeffnen
- Remembered window size

Receiver logs are written to:

```text
%APPDATA%\UniDrop\receiver.log
```

## Receiver Service

Manual start, mainly for debugging:

```powershell
cd client-windows\src\WinDropReceiver
dotnet run -- --listen http://<WINDOWS-IP>:8873 --out "$env:USERPROFILE\Downloads\UniDrop"
```

If started without `--listen`, the receiver defaults to `http://0.0.0.0:8873`
so it can still be reached from the Mac gateway.

Optional pairing token:

```powershell
$env:WINDROP_PAIRING_TOKEN = "ein-langes-zufaelliges-token"
dotnet run -- --listen http://<WINDOWS-IP>:8873
```

The Mac gateway must use the same Windows IP and, when enabled, the same
`WINDROP_PAIRING_TOKEN`.
