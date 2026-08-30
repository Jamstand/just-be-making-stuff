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
$docs   = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "Assetto Corsa"

$installed = $false
if (Test-Path $appPy) {
    Good "apps\python\GearSpeedo\GearSpeedo.py is there"
    $installed = $true
} else {
    Bad "apps\python\GearSpeedo\GearSpeedo.py is MISSING"
    Info "It needs to be exactly here:"
    Info ("  " + $appPy)
    Say ""

    if (Test-Path $appDir) {
        Info "That folder exists but the .py file is not directly inside it."
        Info "It contains:"
        Get-ChildItem $appDir | ForEach-Object { Info ("  " + $_.Name) }
    }

    # Go hunting. The overwhelmingly common mistake is dropping 'apps' into
    # Documents\Assetto Corsa (settings) instead of steamapps\common\assettocorsa
    # (the game). Both are called "Assetto Corsa", so this is easy to get wrong.
    Info "Looking for a copy that landed somewhere else..."
    $searchRoots = @(
        $docs,
        (Join-Path ([Environment]::GetFolderPath("UserProfile")) "Downloads"),
        (Join-Path ([Environment]::GetFolderPath("UserProfile")) "Desktop"),
        (Join-Path ([Environment]::GetFolderPath("UserProfile")) "Documents"),
        $AcRoot
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    $found = @()
    foreach ($root in $searchRoots) {
        $hits = Get-ChildItem -Path $root -Filter "GearSpeedo.py" -Recurse -File -ErrorAction SilentlyContinue
        foreach ($h in $hits) { $found += $h.FullName }
    }
    $found = $found | Select-Object -Unique

    if ($found.Count -gt 0) {
        Say ""
        Bad "Found GearSpeedo.py, but in the wrong place:"
        foreach ($f in $found) { Info ("  " + $f) }
        Say ""
        Info "FIX: move the 'apps' folder (and 'content') so they end up at:"
        Info ("  " + (Join-Path $AcRoot "apps"))
        Info ("  " + (Join-Path $AcRoot "content"))
        if ($found | Where-Object { $_ -like ($docs + "*") }) {
            Say ""
            Bad "Note: a copy is under Documents\Assetto Corsa."
            Info "That is the SETTINGS folder, not the game. Apps do not load from"
            Info "there. The game folder is the one this script found above:"
            Info ("  " + $AcRoot)
        }
    } else {
        $zips = @()
        foreach ($root in $searchRoots) {
            $z = Get-ChildItem -Path $root -Filter "GearSpeedo*.zip" -Recurse -File -ErrorAction SilentlyContinue
            foreach ($h in $z) { $zips += $h.FullName }
        }
        if ($zips.Count -gt 0) {
            Bad "Found the zip, but it was never extracted:"
            $zips | Select-Object -Unique | ForEach-Object { Info ("  " + $_) }
            Say ""
            Info "FIX: right-click the zip -> Extract All, then copy the 'apps' and"
            Info "'content' folders from inside it into:"
            Info ("  " + $AcRoot)
        } else {
            Info "No copy of GearSpeedo.py found anywhere obvious."
            Info "FIX: extract the zip and copy its 'apps' and 'content' folders into:"
            Info ("  " + $AcRoot)
        }
    }
}

$icon = Join-Path $AcRoot "content\gui\icons\Gear Speedo_ON.png"
if (Test-Path $icon) { Good "sidebar icon is installed" }
elseif ($installed) { Info "sidebar icon missing (cosmetic only, the app still works)" }

# --- 3. Is Python enabled at all? ------------------------------------------
Say ""
Say "2. Assetto Corsa settings"
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
            # The traceback lines under a failure do not contain 'GearSpeedo',
            # so pull each failure line WITH the lines that follow it.
            $detail = Select-String -Path $pyLog -Pattern "GearSpeedo.*failed" -Context 0,10
            foreach ($d in ($detail | Select-Object -Last 2)) {
                Info ("  " + $d.Line)
                $d.Context.PostContext | ForEach-Object { Info ("  " + $_) }
            }
        }
    }
} else {
    Info "py_log.txt not found - drive a session once, then re-run this"
}

Say ""
Say "Done."
Say ""
