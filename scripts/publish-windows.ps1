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

Copy-Item (Join-Path $ReceiverOut "UniDropReceiver.exe") $TrayOut -Force
Copy-Item (Join-Path $TrayOut "UniDrop.exe") (Join-Path $ClientOut "UniDrop.exe") -Force
Copy-Item (Join-Path $TrayOut "UniDropReceiver.exe") (Join-Path $ClientOut "UniDropReceiver.exe") -Force
Write-Host "UniDrop Tray EXE:" (Join-Path $TrayOut "UniDrop.exe")
Write-Host "UniDrop Receiver EXE:" (Join-Path $TrayOut "UniDropReceiver.exe")
Write-Host "GitHub Windows EXEs:" (Join-Path $ClientOut "UniDrop.exe") "and" (Join-Path $ClientOut "UniDropReceiver.exe")
