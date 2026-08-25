# Installs the Claude Assistant Workflow Integration plugin (Electron) into
# DaVinci Resolve Studio on Windows.
#
# What it does, in order:
#   1. Copies the plugin folder to Resolve's Workflow Integration Plugins
#      directory (ProgramData — that's why it needs admin).
#   2. Copies WorkflowIntegration.node from YOUR Resolve install's
#      Developer\Workflow Integrations\Examples\SamplePlugin folder into the
#      plugin. That file is Blackmagic's own bridge module — it is not
#      shipped with this repo and must come from your installation.
#   3. Reminds you to restart Resolve (the menu is scanned at startup only).
#
# Right-click > Run with PowerShell.

$ErrorActionPreference = "Stop"

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting administrator rights (ProgramData copy)..."
    Start-Process powershell.exe -Verb RunAs -ArgumentList `
        "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`""
    exit
}

$src = Join-Path $PSScriptRoot "com.jamstand.claude.assistant"
if (-not (Test-Path (Join-Path $src "manifest.xml"))) {
    Write-Host "Plugin folder not found next to this installer." -ForegroundColor Red
    Read-Host "Press Enter to close"; exit 1
}

$pluginRoot = Join-Path $env:ProgramData `
    "Blackmagic Design\DaVinci Resolve\Support\Workflow Integration Plugins"
$dest = Join-Path $pluginRoot "com.jamstand.claude.assistant"

$nodeModule = Join-Path $env:ProgramData ("Blackmagic Design\DaVinci Resolve\" +
    "Support\Developer\Workflow Integrations\Examples\SamplePlugin\" +
    "WorkflowIntegration.node")
if (-not (Test-Path $nodeModule)) {
    Write-Host "WorkflowIntegration.node not found at:" -ForegroundColor Red
    Write-Host "  $nodeModule"
    Write-Host "Is DaVinci Resolve STUDIO installed? (This file ships with it.)"
    Read-Host "Press Enter to close"; exit 1
}

New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item (Join-Path $src "*") $dest -Recurse -Force
Copy-Item $nodeModule $dest -Force
Write-Host "[ok] plugin installed          -> $dest"
Write-Host "[ok] WorkflowIntegration.node  -> copied from your Resolve install"
Write-Host ""
Write-Host "Restart DaVinci Resolve, then: Workspace > Workflow Integrations > Claude Assistant"
Write-Host "(Also needs the Claude Code CLI: npm install -g @anthropic-ai/claude-code)"
Read-Host "Press Enter to close"
