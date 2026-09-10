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
$docs   = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "Assetto Corsa"

# There are two builds. The Lua one (Custom Shaders Patch) is the recommended
# install; the Python one is the fallback. Either counts as installed.
$luaDir      = Join-Path $AcRoot "apps\lua\GearSpeedo"
$luaMain     = Join-Path $luaDir "GearSpeedo.lua"
$luaManifest = Join-Path $luaDir "manifest.ini"
$appDir      = Join-Path $AcRoot "apps\python\GearSpeedo"
$appPy       = Join-Path $appDir "GearSpeedo.py"

$luaInstalled = (Test-Path $luaMain) -and (Test-Path $luaManifest)
$luaNested    = $false
$installed    = Test-Path $appPy

if ($luaInstalled) {
    Good "Lua build: apps\lua\GearSpeedo is installed (recommended build)"
} elseif (Test-Path (Join-Path $luaDir "GearSpeedo\GearSpeedo.lua")) {
    $luaNested = $true
    Bad "Lua build: the files are one folder too deep (apps\lua\GearSpeedo\GearSpeedo\...)"
    Info "CSP wants apps\lua\GearSpeedo\GearSpeedo.lua and manifest.ini side by side."
    Info "FIX: move everything from the inner GearSpeedo folder up one level, then delete the empty inner folder."
} elseif (Test-Path $luaDir) {
    Bad "Lua build: apps\lua\GearSpeedo exists but is incomplete"
    Info "It needs both GearSpeedo.lua and manifest.ini. It contains:"
    Get-ChildItem $luaDir | ForEach-Object { Info ("  " + $_.Name) }
}

if ($installed) {
    Good "Python build: apps\python\GearSpeedo\GearSpeedo.py is there"
} elseif (-not $luaInstalled -and -not $luaNested) {
    Bad "Neither build is installed."
    Info "The Lua build (recommended, needs Custom Shaders Patch) goes here:"
    Info ("  " + $luaDir)
    Info "The Python build goes here:"
    Info ("  " + $appDir)
    Say ""

    if (Test-Path $appDir) {
        Info "apps\python\GearSpeedo exists but GearSpeedo.py is not directly inside it."
        Info "It contains:"
        Get-ChildItem $appDir | ForEach-Object { Info ("  " + $_.Name) }
    }

    # A folder in the right place that is merely incomplete has already been
    # explained above; hunting would just "find" it there and tell the user
    # to move it onto itself.
    if ((Test-Path $luaDir) -or (Test-Path $appDir)) {
        Info "FIX: copy the whole folder from the zip again, so nothing is missing."
    } else {
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
        foreach ($pattern in @("GearSpeedo.lua", "GearSpeedo.py")) {
            $hits = Get-ChildItem -Path $root -Filter $pattern -Recurse -File -ErrorAction SilentlyContinue
            foreach ($h in $hits) { $found += $h.FullName }
        }
    }
    $found = $found | Select-Object -Unique

    if ($found.Count -gt 0) {
        Say ""
        Bad "Found the app files, but in the wrong place:"
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
            Info "No copy of the app files found anywhere obvious."
            Info "FIX: extract the zip and copy its 'apps' and 'content' folders into:"
            Info ("  " + $AcRoot)
        }
    }
    }
}

$icon = Join-Path $AcRoot "content\gui\icons\Gear Speedo_ON.png"
if (Test-Path $icon) { Good "sidebar icon is installed" }
elseif ($installed) { Info "sidebar icon missing (cosmetic only, the app still works)" }

# --- 2b. Lua build needs Custom Shaders Patch -------------------------------
if ($luaInstalled) {
    Say ""
    Say "1b. Custom Shaders Patch (needed by the Lua build)"
    $cspDll = Join-Path $AcRoot "dwrite.dll"
    $cspExt = Join-Path $AcRoot "extension"
    if ((Test-Path $cspDll) -and (Test-Path $cspExt)) {
        Good "Custom Shaders Patch is installed"
        # The manifest names the CSP build it needs. On an older build the app
        # is not expected to load, which would look exactly like "it isn't listed".
        $needBuild = 2514
        $rv = Select-String -Path $luaManifest -Pattern "^\s*REQUIRED_VERSION\s*=\s*(\d+)" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($rv) { $needBuild = [int]$rv.Matches[0].Groups[1].Value }
        $dm = Join-Path $AcRoot "extension\config\data_manifest.ini"
        $build = $null
        if (Test-Path $dm) {
            Select-String -Path $dm -Pattern "SHADERS_PATCH" -ErrorAction SilentlyContinue |
                ForEach-Object { Info ("  " + $_.Line.Trim()) }
            $bl = Select-String -Path $dm -Pattern "SHADERS_PATCH_BUILD\s*=\s*(\d+)" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($bl) { $build = [int]$bl.Matches[0].Groups[1].Value }
        }
        if ($null -eq $build) {
            Info "  (could not read the CSP build; the app asks for $needBuild or newer)"
        } elseif ($build -ge $needBuild) {
            Good "CSP build $build meets the app's minimum of $needBuild"
        } else {
            Bad "CSP build $build is older than the $needBuild the app asks for - not expected to load until CSP is updated"
            Info "Update Custom Shaders Patch: Content Manager -> Settings -> Custom Shaders Patch."
        }
        # Title bar and resize handle are per-window flags, so the app ships
        # one window per combination and its settings switch between them.
        $wins = @(Select-String -Path $luaManifest -Pattern "^\s*\[WINDOW_" -ErrorAction SilentlyContinue).Count
        if ($wins -ge 4) {
            Info "  $wins windows declared: title bar and resize handle are switched in the app's settings"
        } elseif ($wins -ge 1) {
            Bad "only $wins window section(s) in manifest.ini - an older copy; the title bar / resize handle switches need the current one"
            Info "Copy apps\lua\GearSpeedo from the zip again (both GearSpeedo.lua and manifest.ini)."
        } else {
            Bad "manifest.ini has no [WINDOW_...] section - CSP has nothing to show"
        }
        $fl = Select-String -Path $luaManifest -Pattern "^\s*FLAGS\s*=\s*(.+)$" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($fl) {
            $flags = ($fl.Matches[0].Groups[1].Value -split ";")[0].Trim()
            Info "  main window flags: $flags"
            if ($flags -match "NO_TITLE_BAR") {
                Info "  main window has no title bar at all (edited manifest)"
            } elseif ($flags -match "FLOATING_TITLE_BAR") {
                if ($wins -ge 4) { Info "  title bar hidden until you point the mouse at the window; settings can hide it for good" }
                else             { Info "  title bar hidden until you point the mouse at the window" }
            } else {
                Info "  title bar always shown (FLOATING_TITLE_BAR removed from the manifest)"
            }
        }
        if ($null -eq $build -or $build -ge $needBuild) {
            Info "Nothing to activate: CSP loads Lua apps straight from the folder."
            Info "Start a session and look under 'Your apps' for 'Gear Speedo'."
        } else {
            Info "Once CSP is updated, start a session and look under 'Your apps' for 'Gear Speedo'."
        }
    } else {
        Bad "Custom Shaders Patch does not look installed (no dwrite.dll / extension folder)"
        Info "Lua apps only run under CSP. Install it from Content Manager"
        Info "(Settings -> Custom Shaders Patch), or use the Python build instead."
    }
    if (-not $installed) {
        Say ""
        Info "The Python-build checks below do not apply to the Lua build."
        Say ""
        Say "Done."
        Say ""
        return
    }
}

# --- 3. Is Python enabled at all? ------------------------------------------
Say ""
Say "2. Assetto Corsa settings (Python build)"
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
