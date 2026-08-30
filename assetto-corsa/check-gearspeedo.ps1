# Gear Speedo installation checker.
#
# Read-only: this script only looks at files and prints what it finds. It
# never edits anything.
#
# Run it by right-clicking the file -> "Run with PowerShell", or from a
# PowerShell window:
#     .\check-gearspeedo.ps1
#     .\check-gearspeedo.ps1 -AcRoot "D:\Steam\steamapps\common\assettocorsa"

param([string]$AcRoot = "")

function Say($text)  { Write-Host $text }
function Good($text) { Write-Host ("  OK    " + $text) -ForegroundColor Green }
function Bad($text)  { Write-Host ("  WRONG " + $text) -ForegroundColor Red }
function Info($text) { Write-Host ("        " + $text) -ForegroundColor Gray }

Say ""
Say "Gear Speedo installation check"
Say "============================="
Say ""

# --- 1. Find the Assetto Corsa install ------------------------------------
if ($AcRoot -eq "") {
    $guesses = @(
        "C:\Program Files (x86)\Steam\steamapps\common\assettocorsa",
        "C:\Program Files\Steam\steamapps\common\assettocorsa",
        "C:\Steam\steamapps\common\assettocorsa",
        "D:\Steam\steamapps\common\assettocorsa",
        "D:\SteamLibrary\steamapps\common\assettocorsa",
        "E:\Steam\steamapps\common\assettocorsa",
        "E:\SteamLibrary\steamapps\common\assettocorsa",
        "F:\SteamLibrary\steamapps\common\assettocorsa"
    )
    foreach ($g in $guesses) {
        if (Test-Path $g) { $AcRoot = $g; break }
    }
}

if ($AcRoot -eq "" -or -not (Test-Path $AcRoot)) {
    Bad "Could not find your Assetto Corsa folder."
    Info "Find it in Content Manager under Settings -> Assetto Corsa, then run:"
    Info '  .\check-gearspeedo.ps1 -AcRoot "YOUR\PATH\HERE"'
    Say ""
    return
}
Good ("Assetto Corsa found at: " + $AcRoot)

# --- 2. Are the app files in the right place? ------------------------------
Say ""
Say "1. App files"
$appDir = Join-Path $AcRoot "apps\python\GearSpeedo"
$appPy  = Join-Path $appDir "GearSpeedo.py"

$installed = $false
if (Test-Path $appPy) {
    Good "apps\python\GearSpeedo\GearSpeedo.py is there"
    $installed = $true
} else {
    Bad "apps\python\GearSpeedo\GearSpeedo.py is MISSING"
    if (Test-Path $appDir) {
        Info "The folder exists but the .py file is not in it. Found instead:"
        Get-ChildItem $appDir | ForEach-Object { Info ("  " + $_.Name) }
        Info "The file must be named exactly GearSpeedo.py"
    } else {
        Info "The folder apps\python\GearSpeedo does not exist at all."
        Info "Copy the 'apps' folder from the zip into: $AcRoot"
        # Maybe it landed somewhere odd - go looking.
        $stray = Get-ChildItem -Path (Join-Path $AcRoot "apps\python") -Filter "GearSpeedo*" -Recurse -ErrorAction SilentlyContinue
        if ($stray) {
            Info "But something similar was found:"
            $stray | ForEach-Object { Info ("  " + $_.FullName) }
        }
    }
}

$icon = Join-Path $AcRoot "content\gui\icons\Gear Speedo_ON.png"
if (Test-Path $icon) { Good "sidebar icon is installed" }
else { Info "sidebar icon missing (cosmetic only, the app still works)" }

# --- 3. Is Python enabled at all? ------------------------------------------
Say ""
Say "2. Assetto Corsa settings"
$docs = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "Assetto Corsa"
$gameplay = Join-Path $docs "cfg\gameplay.ini"

if (Test-Path $gameplay) {
    $line = Select-String -Path $gameplay -Pattern "ENABLE_PYTHON" -ErrorAction SilentlyContinue
    if ($line -and ($line.Line -match "1")) {
        Good "Python apps are enabled"
    } else {
        Bad "Python apps are DISABLED - nothing will load"
        Info "Content Manager -> Settings -> Assetto Corsa -> Apps -> tick 'Enable Python apps'"
    }
} else {
    Info "gameplay.ini not found - launch AC once, then re-run this"
}

# --- 4. Is this specific app activated? ------------------------------------
$pythonIni = Join-Path $docs "cfg\python.ini"
if (Test-Path $pythonIni) {
    $text = Get-Content $pythonIni -Raw
    if ($text -match "(?ms)^\s*\[GEARSPEEDO\]\s*(.*?)(?=^\s*\[|\z)") {
        $section = $Matches[1]
        if ($section -match "ACTIVE\s*=\s*1") {
            Good "Gear Speedo is activated"
        } else {
            Bad "Gear Speedo is listed but NOT ticked"
            Info "Content Manager -> Settings -> Assetto Corsa -> Apps -> tick 'Gear Speedo'"
        }
    } else {
        Bad "Gear Speedo is not in python.ini - AC has never seen it"
        if ($installed) {
            Info "The files are installed, so AC just has not rescanned yet."
            Info "Restart Content Manager, then tick it under Settings -> Assetto Corsa -> Apps."
        } else {
            Info "Install the files first (see section 1 above)."
        }
        Info "Apps AC currently knows about:"
        Select-String -Path $pythonIni -Pattern "^\[" | ForEach-Object { Info ("  " + $_.Line) }
    }
} else {
    Info "python.ini not found - launch AC once, then re-run this"
}

# --- 5. What did the game actually do with it? ------------------------------
Say ""
Say "3. What happened last time you drove"
$pyLog = Join-Path $docs "logs\py_log.txt"
if (Test-Path $pyLog) {
    $hits = Select-String -Path $pyLog -Pattern "GearSpeedo" -ErrorAction SilentlyContinue
    if (-not $hits) {
        Bad "py_log.txt never mentions GearSpeedo"
        Info "AC did not even try to load it. That is an activation problem, not a"
        Info "problem with the app - see sections 1 and 2 above."
    } else {
        $loaded   = $hits | Where-Object { $_.Line -match "loaded" }
        $imported = $hits | Where-Object { $_.Line -match "module imported" }
        $failed   = $hits | Where-Object { $_.Line -match "failed" }
        if ($loaded) {
            Good "The app loaded successfully"
            Info "So it IS running. Look for it in the app bar at the right screen edge,"
            Info "under 'Your apps' as 'Gear Speedo'."
        } elseif ($imported) {
            Bad "The file loaded but starting up failed"
        } else {
            Bad "Something went wrong while loading"
        }
        if ($failed) {
            Say ""
            Info "Error detail from py_log.txt (send this to Claude):"
            $hits | Select-Object -Last 25 | ForEach-Object { Info ("  " + $_.Line) }
        }
    }
} else {
    Info "py_log.txt not found - drive a session once, then re-run this"
}

Say ""
Say "Done."
Say ""
