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
$ClientOut = Join-Path $RepoRoot "client-windows"

function Reset-Directory([string]$Path) {
    $repoFullPath = [System.IO.Path]::GetFullPath($RepoRoot)
    $targetFullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $targetFullPath.StartsWith($repoFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to reset path outside repo: $targetFullPath"
    }
    if (Test-Path -LiteralPath $targetFullPath) {
        Remove-Item -LiteralPath $targetFullPath -Recurse -Force
    }
    New-Item -ItemType Directory -Path $targetFullPath | Out-Null
}

Reset-Directory $ReceiverOut
Reset-Directory $TrayOut

dotnet publish $ReceiverProject -c $Configuration -r $Runtime --self-contained true `
    -p:PublishSingleFile=true `
    -p:EnableCompressionInSingleFile=true `
    -p:DebugType=None `
    -p:DebugSymbols=false `
    -o $ReceiverOut
dotnet publish $TrayProject -c $Configuration -r $Runtime --self-contained true `
    -p:PublishSingleFile=true `
    -p:EnableCompressionInSingleFile=true `
    -p:DebugType=None `
    -p:DebugSymbols=false `
    -o $TrayOut

Copy-Item (Join-Path $ReceiverOut "WinDropReceiver.exe") $TrayOut -Force
Copy-Item (Join-Path $TrayOut "WinDropTray.exe") (Join-Path $ClientOut "WinDropTray.exe") -Force
Copy-Item (Join-Path $TrayOut "WinDropReceiver.exe") (Join-Path $ClientOut "WinDropReceiver.exe") -Force
Write-Host "UniDrop Tray EXE:" (Join-Path $TrayOut "WinDropTray.exe")
Write-Host "UniDrop Receiver EXE:" (Join-Path $TrayOut "WinDropReceiver.exe")
Write-Host "GitHub Windows EXEs:" (Join-Path $ClientOut "WinDropTray.exe") "and" (Join-Path $ClientOut "WinDropReceiver.exe")
