param(
    [string]$Configuration = "Release",
    [string]$Runtime = "win-x64"
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$PublishRoot = Join-Path $RepoRoot "dist\windows"
$ReceiverProject = Join-Path $RepoRoot "client-windows\src\WinDropReceiver\WinDropReceiver.csproj"
$TrayProject = Join-Path $RepoRoot "client-windows\src\WinDropTray\WinDropTray.csproj"
$ReceiverOut = Join-Path $PublishRoot "receiver"
$TrayOut = Join-Path $PublishRoot "tray"

dotnet publish $ReceiverProject -c $Configuration -r $Runtime --self-contained false -o $ReceiverOut
dotnet publish $TrayProject -c $Configuration -r $Runtime --self-contained false -o $TrayOut

Copy-Item (Join-Path $ReceiverOut "*") $TrayOut -Force
Write-Host "UniDrop Tray EXE:" (Join-Path $TrayOut "WinDropTray.exe")
