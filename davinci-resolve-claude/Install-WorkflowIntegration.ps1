# Installs Claude Assistant into DaVinci Resolve — both launch points:
#
#   1. Workspace > Scripts > Claude Assistant            (all versions)
#   2. Workspace > Workflow Integrations > Claude Assistant
#      (DaVinci Resolve STUDIO only — the free edition does not load
#       workflow integrations at all)
#
# The Workflow Integration folder lives under C:\ProgramData, which needs
# administrator rights — this script relaunches itself elevated if needed.
# Right-click > "Run with PowerShell", or from a terminal:
#   powershell -ExecutionPolicy Bypass -File .\Install-WorkflowIntegration.ps1

$ErrorActionPreference = "Stop"

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting administrator rights (needed for the ProgramData copy)..."
    Start-Process powershell.exe -Verb RunAs -ArgumentList `
        "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`""
    exit
}

$plugin = Join-Path $PSScriptRoot "Claude Assistant.py"
if (-not (Test-Path $plugin)) {
    Write-Host "Could not find 'Claude Assistant.py' next to this installer." -ForegroundColor Red
    Read-Host "Press Enter to close"
    exit 1
}

# 1. Per-user Scripts menu (works on free and Studio alike)
$scripts = Join-Path $env:APPDATA `
    "Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Utility"
New-Item -ItemType Directory -Force -Path $scripts | Out-Null
Copy-Item $plugin $scripts -Force
Write-Host "[ok] Workspace > Scripts             -> $scripts"

# 2. Workflow Integrations menu (Studio only; scanned once at startup)
$wfi = Join-Path $env:ProgramData `
    "Blackmagic Design\DaVinci Resolve\Support\Workflow Integration Plugins"
New-Item -ItemType Directory -Force -Path $wfi | Out-Null
Copy-Item $plugin $wfi -Force
Write-Host "[ok] Workspace > Workflow Integrations -> $wfi"

Write-Host ""
Write-Host "Done. Restart DaVinci Resolve to pick up the Workflow Integrations entry"
Write-Host "(the Scripts entry updates without a restart)."
Write-Host ""
Write-Host "Note: if 'Workflow Integrations' never appears in the Workspace menu,"
Write-Host "you are on the free edition of Resolve - use Workspace > Scripts;"
Write-Host "the panel is identical either way."
Read-Host "Press Enter to close"
