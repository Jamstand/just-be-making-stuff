#Requires -Version 5
<#
    JoinWhenFree - one-shot installer for Windows PowerShell.

    What it does:
      1. Checks that git and Node.js are installed
      2. Sets up pnpm (Vencord's package manager)
      3. Clones Vencord (into your home folder, reused if already there)
      4. Drops this plugin into Vencord/src/userplugins/joinWhenFree
      5. Builds Vencord and injects it into Discord

    Run it from this folder with:
      powershell -ExecutionPolicy Bypass -File .\setup.ps1
#>

$ErrorActionPreference = "Stop"

function Require-Command($name, $hint) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        Write-Host ""
        Write-Host "  [X] '$name' is not installed or not on your PATH." -ForegroundColor Red
        Write-Host "      $hint" -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
}

Write-Host ""
Write-Host "=== JoinWhenFree installer ===" -ForegroundColor Cyan
Write-Host ""

# 1. Prerequisites (a freshly-installed tool only appears after you open a NEW PowerShell window)
Require-Command git  "Install it:  winget install Git.Git          then open a NEW PowerShell window and re-run this."
Require-Command node "Install it:  winget install OpenJS.NodeJS.LTS  then open a NEW PowerShell window and re-run this."

# 2. pnpm. Try corepack (ships with Node) first; if that needs admin rights we
#    don't have (Node installed in C:\Program Files), fall back to pnpm's
#    admin-free standalone installer and make it usable in this session.
if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
    Write-Host "Setting up pnpm..." -ForegroundColor Cyan

    corepack enable 2>$null
    corepack prepare pnpm@latest --activate 2>$null

    if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
        Write-Host "corepack needs admin; using pnpm's standalone installer instead (no admin needed)..." -ForegroundColor Cyan
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest https://get.pnpm.io/install.ps1 -UseBasicParsing | Invoke-Expression
        if (-not $env:PNPM_HOME) { $env:PNPM_HOME = Join-Path $env:LOCALAPPDATA "pnpm" }
        # the pnpm.exe location varies by version (PNPM_HOME or PNPM_HOME\bin) - add both
        $env:Path = "$($env:PNPM_HOME)\bin;$($env:PNPM_HOME);$($env:Path)"
    }
}
Require-Command pnpm "Could not set up pnpm. Install it from https://pnpm.io/installation then re-run this."

# 3. Clone Vencord (reused if it already exists)
$vencord = Join-Path $HOME "Vencord"
if (Test-Path $vencord) {
    Write-Host "Using existing Vencord at $vencord" -ForegroundColor DarkGray
} else {
    Write-Host "Cloning Vencord into $vencord ..." -ForegroundColor Cyan
    git clone https://github.com/Vendicated/Vencord $vencord
}

# 4. Copy this plugin in ($PSScriptRoot is the folder this script lives in)
$dest = Join-Path $vencord "src\userplugins\joinWhenFree"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot "index.tsx") -Destination $dest -Force
Write-Host "Copied plugin -> $dest" -ForegroundColor Green

# 5. Build + inject
Set-Location $vencord
Write-Host "Installing dependencies (first run takes a minute or two)..." -ForegroundColor Cyan
pnpm install --frozen-lockfile
Write-Host "Building Vencord..." -ForegroundColor Cyan
pnpm build
Write-Host "Injecting into Discord (pick your Discord install when asked)..." -ForegroundColor Cyan
pnpm inject

Write-Host ""
Write-Host "=== Done! ===" -ForegroundColor Green
Write-Host "Fully QUIT Discord (right-click the tray icon -> Quit), reopen it," -ForegroundColor Green
Write-Host "then enable JoinWhenFree in:  Settings -> Vencord -> Plugins" -ForegroundColor Green
Write-Host ""
