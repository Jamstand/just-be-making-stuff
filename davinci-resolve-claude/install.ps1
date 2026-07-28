# Installs "Claude Assistant.py" into DaVinci Resolve's Utility scripts folder.
$ErrorActionPreference = "Stop"

$src = Join-Path $PSScriptRoot "Claude Assistant.py"
if (-not (Test-Path $src)) {
    Write-Error "'Claude Assistant.py' not found next to this script."
}

$dest = Join-Path $env:APPDATA "Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Utility"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item $src $dest -Force

Write-Host "Installed to: $dest\Claude Assistant.py"
Write-Host "In Resolve:   Workspace > Scripts > Claude Assistant"
