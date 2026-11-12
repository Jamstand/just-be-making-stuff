<#
.SYNOPSIS
    Debloat a Chromecast with Google TV / Google TV Streamer over ADB.

.DESCRIPTION
    Interactive tool. Connects to the TV over Wi-Fi, then lets you:
      1. Disable preinstalled apps and background extras (keeps the stock home screen)
      2. Replace the Google TV home screen with a clean launcher (removes home-screen ads)
      3. Undo everything this tool changed
      4. Save a list of every package on the TV
      5. Install Glass Home, a custom home screen (GlassHome.apk next to this script)
      6. Install SmartTube, a third-party YouTube app without ads
      7. Give Glass Home a YouTube API key for its video rows

    Nothing is permanently deleted. Apps are disabled for the current user only,
    option 3 turns them back on, and a factory reset restores the TV completely.

.PARAMETER TvIp
    IP address of the TV (Settings > Network & Internet > your Wi-Fi network).

.PARAMETER AdbPath
    Full path to adb.exe if you already have it somewhere unusual.

.PARAMETER DryRun
    Show what would be changed without changing anything on the TV.

.EXAMPLE
    .\Debloat-GoogleTV.ps1 -TvIp 192.168.1.50

.EXAMPLE
    .\Debloat-GoogleTV.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$TvIp,
    [string]$AdbPath,
    [switch]$DryRun
)

# Native-command stderr must not abort the script on Windows PowerShell 5.1.
$ErrorActionPreference = 'Continue'

$script:Root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:StateFile = Join-Path $script:Root 'debloat-state.json'
$script:Adb       = $null
$script:Serial    = $null
$script:IsDryRun  = [bool]$DryRun

$StockLauncher   = 'com.google.android.apps.tv.launcherx'
$SetupWraith     = 'com.google.android.tungsten.setupwraith'
$NewLauncher     = 'com.spocky.projengmenu'
$NewLauncherName = 'Projectivy Launcher'
$GlassHome       = 'tv.glasshome.launcher'

# ---------------------------------------------------------------------------
# Package catalog
#   Group 'Streaming' : asked one at a time (you may actually use some of these)
#   Group 'Extras'    : offered as one batch, safe to turn off
#   Group 'Optional'  : asked one at a time, each has a real trade-off
# Only packages that are actually installed on your TV are ever offered.
# ---------------------------------------------------------------------------
$Catalog = @(
    # --- Preinstalled streaming apps ---
    @{ Id = 'com.netflix.ninja';                        Group = 'Streaming'; Name = 'Netflix' }
    @{ Id = 'com.amazon.amazonvideo.livingroom';        Group = 'Streaming'; Name = 'Prime Video' }
    @{ Id = 'com.google.android.youtube.tvmusic';       Group = 'Streaming'; Name = 'YouTube Music' }
    @{ Id = 'com.google.android.youtube.tvunplugged';   Group = 'Streaming'; Name = 'YouTube TV (the paid live TV service)' }
    @{ Id = 'com.google.android.youtube.tvkids';        Group = 'Streaming'; Name = 'YouTube Kids' }
    @{ Id = 'com.disney.disneyplus';                    Group = 'Streaming'; Name = 'Disney+' }
    @{ Id = 'com.hulu.livingroomplus';                  Group = 'Streaming'; Name = 'Hulu' }
    @{ Id = 'com.apple.atve.androidtv.appletv';         Group = 'Streaming'; Name = 'Apple TV' }
    @{ Id = 'com.spotify.tv.android';                   Group = 'Streaming'; Name = 'Spotify' }
    @{ Id = 'com.wbd.stream';                           Group = 'Streaming'; Name = 'Max' }
    @{ Id = 'com.peacocktv.peacockandroid';             Group = 'Streaming'; Name = 'Peacock' }
    @{ Id = 'com.cbs.ott';                              Group = 'Streaming'; Name = 'Paramount+' }
    @{ Id = 'com.tubitv';                               Group = 'Streaming'; Name = 'Tubi' }
    @{ Id = 'tv.pluto.android';                         Group = 'Streaming'; Name = 'Pluto TV' }

    # --- Google extras that are safe to turn off ---
    @{ Id = 'com.google.android.play.games';            Group = 'Extras'; Name = 'Google Play Games' }
    @{ Id = 'com.google.android.videos';                Group = 'Extras'; Name = 'Google TV movie and show store app' }
    @{ Id = 'com.google.android.feedback';              Group = 'Extras'; Name = 'Google feedback reporter' }
    @{ Id = 'com.google.android.tvrecommendations';     Group = 'Extras'; Name = 'Legacy recommendations service' }
    @{ Id = 'com.google.android.partnersetup';          Group = 'Extras'; Name = 'Google partner setup' }
    @{ Id = 'com.google.android.onetimeinitializer';    Group = 'Extras'; Name = 'One-time setup helper (already done its job)' }
    @{ Id = 'com.google.android.syncadapters.calendar'; Group = 'Extras'; Name = 'Calendar sync' }
    @{ Id = 'com.google.android.syncadapters.contacts'; Group = 'Extras'; Name = 'Contacts sync' }
    @{ Id = 'com.android.printspooler';                 Group = 'Extras'; Name = 'Print spooler' }
    @{ Id = 'com.android.htmlviewer';                   Group = 'Extras'; Name = 'Basic HTML viewer' }
    @{ Id = 'com.android.dreams.basic';                 Group = 'Extras'; Name = 'Basic screensaver (not the photo one)' }

    # --- Optional: each one costs you a feature ---
    @{ Id = 'com.google.android.apps.tv.dreamx';        Group = 'Optional'; Name = 'Ambient mode screensaver';
       Note = 'The photo/art screensaver. Without it the TV just dims or sleeps.' }
    @{ Id = 'com.google.android.backdrop';              Group = 'Optional'; Name = 'Backdrop screensaver (older devices)';
       Note = 'Older version of the photo screensaver.' }
    @{ Id = 'com.google.android.marvin.talkback';       Group = 'Optional'; Name = 'TalkBack screen reader';
       Note = 'Accessibility screen reader. Leave it if anyone in the house uses it.' }
    @{ Id = 'com.google.android.katniss';               Group = 'Optional'; Name = 'Google Assistant and voice search';
       Note = 'The microphone button on the remote stops working if you turn this off.' }
)

# Never touched, listed here so nobody adds them by accident:
#   com.google.android.apps.mediashell   (casting from your phone)
#   com.google.android.tv.remote.service (Google Home / phone remote)
#   com.google.android.gms, com.android.vending (Play services and Play Store)
#   com.google.android.youtube.tv        (YouTube itself)

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Write-Title([string]$Text) {
    Write-Host ''
    Write-Host ('=' * 64) -ForegroundColor DarkCyan
    Write-Host ('  ' + $Text) -ForegroundColor Cyan
    Write-Host ('=' * 64) -ForegroundColor DarkCyan
}
function Write-Step([string]$Text) { Write-Host ('  ' + $Text) }
function Write-Ok([string]$Text)   { Write-Host ('  [ok]   ' + $Text) -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host ('  [warn] ' + $Text) -ForegroundColor Yellow }
function Write-Bad([string]$Text)  { Write-Host ('  [fail] ' + $Text) -ForegroundColor Red }

function Read-YesNo([string]$Question, [bool]$Default = $false) {
    $hint = '[y/N]'
    if ($Default) { $hint = '[Y/n]' }
    while ($true) {
        $answer = Read-Host ('  ' + $Question + ' ' + $hint)
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        $first = $answer.Trim().Substring(0, 1).ToLower()
        if ($first -eq 'y') { return $true }
        if ($first -eq 'n') { return $false }
        Write-Step 'Please answer y or n.'
    }
}

# ---------------------------------------------------------------------------
# ADB plumbing
# ---------------------------------------------------------------------------
function Find-Adb {
    if ($AdbPath) {
        if (Test-Path $AdbPath) { return (Resolve-Path $AdbPath).Path }
        Write-Bad "adb was not found at: $AdbPath"
        return $null
    }
    $local = Join-Path $script:Root 'platform-tools\adb.exe'
    if (Test-Path $local) { return $local }
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Install-PlatformTools {
    $url = 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'
    $zip = Join-Path $script:Root 'platform-tools.zip'
    Write-Step 'ADB (the tool that talks to the TV) is not installed on this computer.'
    Write-Step 'It can be downloaded from Google (about 7 MB) into this folder:'
    Write-Step "  $url"
    if (-not (Read-YesNo 'Download it now?' $true)) { return $null }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -ErrorAction Stop
        $ProgressPreference = $oldProgress
        Expand-Archive -Path $zip -DestinationPath $script:Root -Force -ErrorAction Stop
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Bad ('Download failed: ' + $_.Exception.Message)
        Write-Step 'You can download that zip by hand and unzip it next to this script.'
        return $null
    }
    $local = Join-Path $script:Root 'platform-tools\adb.exe'
    if (Test-Path $local) {
        Write-Ok 'ADB downloaded.'
        return $local
    }
    Write-Bad 'The download finished but adb.exe is not where it was expected.'
    return $null
}

# Run adb with no device selected (connect, disconnect, devices).
function Invoke-AdbRaw {
    $output = & $script:Adb @args 2>&1 | ForEach-Object { "$_" }
    return (($output -join "`n").Trim())
}

# Run adb against the connected TV.
function Invoke-Adb {
    $output = & $script:Adb -s $script:Serial @args 2>&1 | ForEach-Object { "$_" }
    return (($output -join "`n").Trim())
}

function Show-EnableDebuggingHelp {
    Write-Step 'On the TV, with the remote:'
    Write-Step '  1. Settings > System > About'
    Write-Step '  2. Scroll to "Android TV OS build" and press OK on it 7 times'
    Write-Step '     until it says you are a developer.'
    Write-Step '  3. Go back to Settings > System > Developer options'
    Write-Step '  4. Turn on "USB debugging".'
    Write-Step '  5. Find the IP address under Settings > Network & Internet >'
    Write-Step '     (your Wi-Fi network). It looks like 192.168.1.50.'
    Write-Step 'The TV and this computer must be on the same Wi-Fi/network.'
}

function Connect-Tv {
    Write-Title 'Connect to the TV'
    $ip = $TvIp
    while ($true) {
        if (-not $ip) {
            Show-EnableDebuggingHelp
            Write-Host ''
            $ip = (Read-Host '  TV IP address (or q to quit)').Trim()
        }
        if ($ip -eq 'q') { return $false }
        if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}(:\d+)?$') {
            Write-Warn "'$ip' does not look like an IP address."
            $ip = $null
            continue
        }
        $serial = $ip
        if ($serial -notmatch ':') { $serial = $serial + ':5555' }

        Write-Step "Connecting to $serial ..."
        $result = Invoke-AdbRaw connect $serial
        # "failed to authenticate" means the TV answered and is waiting for you
        # to approve this computer, so fall through to the approval loop below.
        if ($result -notmatch 'connected to|failed to authenticate') {
            Write-Bad "Could not reach the TV: $result"
            Write-Step 'Check the IP address, that USB debugging is on, and that'
            Write-Step 'both devices are on the same network.'
            $ip = $null
            continue
        }

        $script:Serial = $serial
        $authorized = $false
        for ($try = 1; $try -le 24; $try++) {
            $state = Invoke-Adb get-state
            if ($state -eq 'device') { $authorized = $true; break }
            if ($try -eq 1) {
                Write-Warn 'Look at the TV now: it is asking "Allow USB debugging?"'
                Write-Step  'Tick "Always allow from this computer" and choose Allow.'
            }
            Start-Sleep -Seconds 5
            [void](Invoke-AdbRaw disconnect $serial)
            [void](Invoke-AdbRaw connect $serial)
        }
        if (-not $authorized) {
            Write-Bad 'The TV never approved this computer.'
            if (Read-YesNo 'Try again?' $true) { continue }
            return $false
        }

        $model   = Invoke-Adb shell getprop ro.product.model
        $device  = Invoke-Adb shell getprop ro.product.device
        $android = Invoke-Adb shell getprop ro.build.version.release
        Write-Ok "Connected: $model ($device), Android $android"

        $known = @('sabrina', 'boreal', 'kirkwood')
        if ($known -notcontains $device.ToLower()) {
            Write-Warn 'This is not a Chromecast with Google TV or Google TV Streamer.'
            Write-Step  'The app list was built for those. It only ever touches apps that'
            Write-Step  'exist on your device, but some TV-maker bloat will be missed.'
            if (-not (Read-YesNo 'Continue anyway?' $true)) { return $false }
        }
        return $true
    }
}

# ---------------------------------------------------------------------------
# Package helpers
# ---------------------------------------------------------------------------
function Get-Packages([string[]]$Flags) {
    $adbArgs = @('shell', 'pm', 'list', 'packages') + $Flags + @('--user', '0')
    $raw = Invoke-Adb @adbArgs
    $list = @()
    foreach ($line in ($raw -split "`n")) {
        $line = $line.Trim()
        if ($line.StartsWith('package:')) { $list += $line.Substring(8) }
    }
    return $list
}
function Get-InstalledPackages { return @(Get-Packages @()) }
function Get-EnabledPackages   { return @(Get-Packages @('-e')) }
function Get-DisabledPackages  { return @(Get-Packages @('-d')) }

function Get-State {
    if (Test-Path $script:StateFile) {
        try {
            $loaded = Get-Content $script:StateFile -Raw | ConvertFrom-Json
            return @($loaded | Where-Object { $_ -and $_.Id })
        } catch {
            Write-Warn 'debloat-state.json could not be read; starting a fresh one.'
        }
    }
    return @()
}

function Add-State([string]$Id, [string]$Method) {
    $state = @(Get-State | Where-Object { $_.Id -ne $Id })
    $state += [pscustomobject]@{ Id = $Id; Method = $Method; When = (Get-Date).ToString('s') }
    ConvertTo-Json -InputObject @($state) | Set-Content -Path $script:StateFile -Encoding ASCII
}

function Remove-State([string]$Id) {
    $state = @(Get-State | Where-Object { $_.Id -ne $Id })
    if ($state.Count -eq 0) {
        Remove-Item $script:StateFile -Force -ErrorAction SilentlyContinue
    } else {
        ConvertTo-Json -InputObject @($state) | Set-Content -Path $script:StateFile -Encoding ASCII
    }
}

# Returns $true if the package ended up off.
function Disable-Package([string]$Id, [string]$Name) {
    $label = "$Name ($Id)"
    if ($script:IsDryRun) {
        Write-Step "[dry run] would disable $label"
        return $true
    }
    $out = Invoke-Adb shell pm disable-user --user 0 $Id
    if ($out -match 'new state:\s*disabled') {
        Add-State $Id 'disabled'
        Write-Ok "Disabled $label"
        return $true
    }
    # Some system apps refuse to be disabled but can be removed for this user.
    $out2 = Invoke-Adb shell pm uninstall --user 0 $Id
    if ($out2 -match 'Success') {
        Add-State $Id 'uninstalled'
        Write-Ok "Removed for this user: $label"
        return $true
    }
    Write-Bad "Could not turn off $label"
    Write-Step "         $out"
    return $false
}

# Returns $true if the package ended up on.
function Enable-Package([string]$Id, [string]$Method) {
    if ($script:IsDryRun) {
        Write-Step "[dry run] would re-enable $Id"
        return $true
    }
    if ($Method -eq 'uninstalled') {
        [void](Invoke-Adb shell cmd package install-existing --user 0 $Id)
    }
    $out = Invoke-Adb shell pm enable --user 0 $Id
    if ($out -match 'new state:\s*enabled') {
        Remove-State $Id
        Write-Ok "Re-enabled $Id"
        return $true
    }
    Write-Bad "Could not re-enable $Id"
    Write-Step "         $out"
    return $false
}

# ---------------------------------------------------------------------------
# Option 1: debloat, keep the stock home screen
# ---------------------------------------------------------------------------
function Invoke-Debloat {
    Write-Title 'Debloat (stock home screen stays)'
    $enabled = Get-EnabledPackages
    if ($enabled.Count -eq 0) {
        Write-Bad 'Could not read the app list from the TV.'
        return
    }
    $present = @($Catalog | Where-Object { $enabled -contains $_.Id })
    if ($present.Count -eq 0) {
        Write-Ok 'Nothing from the bloat list is active on this TV. Already clean.'
        return
    }

    $toDisable = @()

    $streaming = @($present | Where-Object { $_.Group -eq 'Streaming' })
    if ($streaming.Count -gt 0) {
        Write-Host ''
        Write-Step 'PREINSTALLED STREAMING APPS'
        Write-Step 'Say no to anything you actually watch.'
        foreach ($app in $streaming) {
            if (Read-YesNo ("Turn off " + $app.Name + "?") $false) { $toDisable += $app }
        }
    }

    $extras = @($present | Where-Object { $_.Group -eq 'Extras' })
    if ($extras.Count -gt 0) {
        Write-Host ''
        Write-Step 'GOOGLE EXTRAS (safe to turn off)'
        foreach ($app in $extras) { Write-Step ("  - " + $app.Name) }
        if (Read-YesNo 'Turn off all of these?' $true) {
            $toDisable += $extras
        } elseif (Read-YesNo 'Go through them one at a time instead?' $false) {
            foreach ($app in $extras) {
                if (Read-YesNo ("Turn off " + $app.Name + "?") $true) { $toDisable += $app }
            }
        }
    }

    $optional = @($present | Where-Object { $_.Group -eq 'Optional' })
    if ($optional.Count -gt 0) {
        Write-Host ''
        Write-Step 'OPTIONAL (each one costs you a feature)'
        foreach ($app in $optional) {
            Write-Host ''
            Write-Step ($app.Name)
            Write-Step ('  ' + $app.Note)
            if (Read-YesNo ("Turn off " + $app.Name + "?") $false) { $toDisable += $app }
        }
    }

    if ($toDisable.Count -eq 0) {
        Write-Host ''
        Write-Step 'Nothing selected. No changes made.'
        return
    }

    Write-Host ''
    Write-Step ("About to turn off " + $toDisable.Count + " app(s):")
    foreach ($app in $toDisable) { Write-Step ("  - " + $app.Name) }
    if (-not (Read-YesNo 'Go ahead?' $true)) {
        Write-Step 'Cancelled. No changes made.'
        return
    }

    Write-Host ''
    $done = 0
    foreach ($app in $toDisable) {
        if (Disable-Package $app.Id $app.Name) { $done++ }
    }
    Write-Host ''
    Write-Ok ("$done of " + $toDisable.Count + " turned off. Option 3 in the menu undoes this.")

    Write-Host ''
    Write-Step 'ABOUT THE HOME-SCREEN ADS'
    Write-Step 'The ad banner and recommendation rows are part of the Google TV home'
    Write-Step 'screen itself, so turning off apps does not remove them. Two ways:'
    Write-Step '  a) On the TV: Settings > Accounts & sign-in > (your account) >'
    Write-Step '     Apps only mode. Hides the rows, but also turns off Assistant.'
    Write-Step '  b) Option 2 in this menu: swap in a clean home screen.'
}

# ---------------------------------------------------------------------------
# Option 2: replace the launcher
# ---------------------------------------------------------------------------
function Invoke-LauncherReplace {
    Write-Title 'Replace the home screen'
    Write-Step "This installs $NewLauncherName (free, from the Play Store) and turns off"
    Write-Step 'the Google TV home screen, which is where the ads and recommendation'
    Write-Step 'rows live. Your apps, accounts and settings are not touched.'
    Write-Step 'Option 3 in the menu puts the Google home screen back.'
    Write-Host ''
    if (-not (Read-YesNo 'Continue?' $true)) { return }

    if ($script:IsDryRun) {
        Write-Step "[dry run] would check for / install $NewLauncherName"
        Write-Step "[dry run] would disable $StockLauncher"
        Write-Step "[dry run] would disable $SetupWraith"
        return
    }

    # Step 1: make sure the new launcher is installed before removing the old one.
    while ((Get-InstalledPackages) -notcontains $NewLauncher) {
        Write-Step "Opening the Play Store page for $NewLauncherName on the TV..."
        [void](Invoke-Adb shell am start -a android.intent.action.VIEW -d "market://details?id=$NewLauncher")
        Write-Step 'Use the remote to press Install on the TV and wait for it to finish.'
        Write-Step '(If the page did not open, search the Play Store on the TV for "Projectivy".)'
        $answer = Read-Host '  Press Enter when it is installed, or type q to cancel'
        if ($answer.Trim().ToLower() -eq 'q') {
            Write-Step 'Cancelled. The Google home screen was left alone.'
            return
        }
    }
    Write-Ok "$NewLauncherName is installed."

    # Step 2: open it once so it finishes its own first-run setup.
    [void](Invoke-Adb shell monkey -p $NewLauncher -c android.intent.category.LEANBACK_LAUNCHER 1)
    Write-Step "$NewLauncherName should now be open on the TV."
    Write-Step 'Click through its welcome screens with the remote.'
    [void](Read-Host '  Press Enter when you can see its home screen')

    # Step 3: turn off the stock launcher.
    Write-Host ''
    Write-Warn 'Next step turns off the Google TV home screen.'
    if (-not (Read-YesNo 'Do it?' $true)) {
        Write-Step "Left as is. $NewLauncherName is installed but the Home button still"
        Write-Step 'opens the Google home screen.'
        return
    }
    $ok = Disable-Package $StockLauncher 'Google TV home screen'
    if (-not $ok) {
        Write-Bad 'The Google home screen could not be turned off. Nothing else changed.'
        return
    }
    # Without this the TV can fall back to a "Getting ready" setup screen.
    if ((Get-EnabledPackages) -contains $SetupWraith) {
        [void](Disable-Package $SetupWraith 'Setup fallback screen')
    }

    # Step 4: verify with the real Home button, and roll back if it is wrong.
    [void](Invoke-Adb shell input keyevent KEYCODE_HOME)
    Start-Sleep -Seconds 3
    Write-Host ''
    Write-Step 'The Home button was just pressed for you.'
    if (Read-YesNo "Is the TV showing the $NewLauncherName home screen?" $true) {
        Write-Ok 'Done. The Google home screen and its ads are off.'
        Write-Step 'Tip: keep USB debugging turned on so you can always undo this.'
    } else {
        Write-Warn 'Rolling back so you are not left without a home screen...'
        Undo-Launcher
        [void](Invoke-Adb shell input keyevent KEYCODE_HOME)
        Write-Step 'The Google home screen is back on.'
    }
}

function Undo-Launcher {
    $state = Get-State
    foreach ($id in @($SetupWraith, $StockLauncher)) {
        $entry = $state | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        $method = 'disabled'
        if ($entry) { $method = $entry.Method }
        [void](Enable-Package $id $method)
    }
}

# ---------------------------------------------------------------------------
# Option 5: install Glass Home, the custom home screen
# ---------------------------------------------------------------------------
function Invoke-GlassHome {
    Write-Title 'Install Glass Home (custom home screen)'
    $apk = Join-Path $script:Root 'GlassHome.apk'
    if (-not (Test-Path $apk)) {
        Write-Bad 'GlassHome.apk was not found next to this script.'
        Write-Step "Expected it here: $apk"
        return
    }
    Write-Step 'Glass Home is a custom home screen: a slow moving gradient background,'
    Write-Step 'a clock, rows for favorite and recent apps, YouTube video rows and a'
    Write-Step 'panel with all apps.'
    Write-Step 'This installs it (or updates it) and can make it the Home button screen.'
    Write-Step 'Option 3 in the menu puts the Google home screen back.'
    Write-Host ''
    if (-not (Read-YesNo 'Continue?' $true)) { return }

    if ($script:IsDryRun) {
        Write-Step "[dry run] would install $apk"
        Write-Step "[dry run] would disable $StockLauncher"
        Write-Step "[dry run] would disable $SetupWraith"
        return
    }

    # Step 1: install or update the app.
    Write-Step 'Installing on the TV...'
    $out = Invoke-Adb install -r $apk
    if ($out -notmatch 'Success') {
        Write-Bad 'The install failed:'
        Write-Step "         $out"
        return
    }
    Write-Ok 'Glass Home is installed.'

    # Step 2: open it so you can see it before anything else changes.
    [void](Invoke-Adb shell monkey -p $GlassHome -c android.intent.category.LEANBACK_LAUNCHER 1)
    Start-Sleep -Seconds 3
    Write-Step 'Glass Home should now be open on the TV: clock at the top left,'
    Write-Step 'a row of apps along the bottom.'
    if (-not (Read-YesNo 'Can you see it?' $true)) {
        Write-Warn 'Nothing else was changed. The Google home screen is still in place.'
        Write-Step 'Tell Claude what the TV showed instead so it can be fixed.'
        return
    }

    # Step 3: make it the screen the Home button opens.
    if ((Get-EnabledPackages) -notcontains $StockLauncher) {
        [void](Invoke-Adb shell cmd package set-home-activity "$GlassHome/.MainActivity")
        Write-Ok 'Updated. The Google home screen was already off.'
        return
    }
    Write-Host ''
    Write-Step 'Right now the Home button still opens the Google home screen.'
    Write-Warn 'Next step turns the Google home screen off so Home opens Glass Home.'
    if (-not (Read-YesNo 'Do it?' $true)) {
        Write-Step 'Left as is. You can open Glass Home from your apps list any time.'
        return
    }
    if (-not (Disable-Package $StockLauncher 'Google TV home screen')) {
        Write-Bad 'The Google home screen could not be turned off. Nothing else changed.'
        return
    }
    # Without this the TV can fall back to a "Getting ready" setup screen.
    if ((Get-EnabledPackages) -contains $SetupWraith) {
        [void](Disable-Package $SetupWraith 'Setup fallback screen')
    }
    [void](Invoke-Adb shell cmd package set-home-activity "$GlassHome/.MainActivity")

    # Step 4: verify with the real Home button, and roll back if it is wrong.
    [void](Invoke-Adb shell input keyevent KEYCODE_HOME)
    Start-Sleep -Seconds 3
    Write-Host ''
    Write-Step 'The Home button was just pressed for you.'
    if (Read-YesNo 'Is the TV showing Glass Home?' $true) {
        Write-Ok 'Done. Glass Home is your home screen.'
        Write-Step 'Tip: keep USB debugging turned on so you can always undo this.'
    } else {
        Write-Warn 'Rolling back so you are not left without a home screen...'
        Undo-Launcher
        [void](Invoke-Adb shell input keyevent KEYCODE_HOME)
        Write-Step 'The Google home screen is back on.'
    }
}

# ---------------------------------------------------------------------------
# Option 6: install SmartTube (third-party YouTube app without ads)
# ---------------------------------------------------------------------------
function Invoke-SmartTube {
    Write-Title 'Install SmartTube'
    $url = 'https://github.com/yuliskov/SmartTube/releases/download/latest/smarttube_stable.apk'
    Write-Step 'SmartTube is a free, open-source YouTube app for TVs that plays videos'
    Write-Step 'without ads. It is not made by Google or by this tool.'
    Write-Warn 'Using it goes against YouTube''s terms of service. Your choice.'
    Write-Step 'It is downloaded from its developer''s official GitHub page:'
    Write-Step "  $url"
    Write-Step 'The normal YouTube app is left installed.'
    Write-Host ''
    if (-not (Read-YesNo 'Download and install it?' $false)) { return }

    if ($script:IsDryRun) {
        Write-Step '[dry run] would download SmartTube and install it on the TV'
        return
    }

    $apk = Join-Path $script:Root 'smarttube_stable.apk'
    Write-Step 'Downloading (about 25 MB)...'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $url -OutFile $apk -UseBasicParsing -ErrorAction Stop
        $ProgressPreference = $oldProgress
    } catch {
        Write-Bad ('Download failed: ' + $_.Exception.Message)
        return
    }
    if (-not (Test-Path $apk) -or ((Get-Item $apk).Length -lt 1MB)) {
        Write-Bad 'The downloaded file is missing or too small to be the app.'
        return
    }

    Write-Step 'Installing on the TV (this can take a minute)...'
    $out = Invoke-Adb install -r $apk
    if ($out -notmatch 'Success') {
        Write-Bad 'The install failed:'
        Write-Step "         $out"
        return
    }
    Remove-Item $apk -Force -ErrorAction SilentlyContinue
    Write-Ok 'SmartTube is installed.'
    Write-Step 'Find it in All Apps on Glass Home. Hold OK on it to add it to favorites.'
    Write-Step 'Videos opened from the Glass Home video rows will play in it.'
    Write-Step 'To sign in, open SmartTube and use its own sign-in screen.'
}

# ---------------------------------------------------------------------------
# Option 7: give Glass Home a YouTube API key for its video rows
# ---------------------------------------------------------------------------
function Invoke-SetYouTubeKey {
    Write-Title 'Set YouTube API key'
    if ((Get-InstalledPackages) -notcontains $GlassHome) {
        Write-Bad 'Glass Home is not installed on the TV yet. Run option 5 first.'
        return
    }
    Write-Step 'Glass Home needs a free YouTube API key to show its video rows.'
    Write-Step 'To get one:'
    Write-Step '  1. Go to https://console.cloud.google.com and sign in.'
    Write-Step '  2. Create a project (any name).'
    Write-Step '  3. APIs & Services > Library > search "YouTube Data API v3" > Enable.'
    Write-Step '  4. APIs & Services > Credentials > Create credentials > API key.'
    Write-Step '  5. Copy the key. It starts with AIza.'
    Write-Step 'The key is sent straight to your TV over your own network.'
    Write-Host ''
    $key = (Read-Host '  Paste the key here (or just press Enter to cancel)').Trim()
    if (-not $key) {
        Write-Step 'Cancelled.'
        return
    }
    if ($key -notmatch '^[0-9A-Za-z_\-]+$') {
        Write-Bad 'That contains characters an API key never has. Nothing was sent.'
        return
    }
    if ($key -notmatch '^AIza[0-9A-Za-z_\-]{30,}$') {
        Write-Warn 'That does not look like a Google API key (they start with AIza).'
        if (-not (Read-YesNo 'Send it anyway?' $false)) { return }
    }
    if ($script:IsDryRun) {
        Write-Step '[dry run] would send the key to Glass Home on the TV'
        return
    }
    $out = Invoke-Adb shell am start -n "$GlassHome/.MainActivity" --es youtube_api_key $key
    if ($out -match 'Error') {
        Write-Bad 'The TV did not accept it:'
        Write-Step "         $out"
        return
    }
    Write-Ok 'Key sent. The TV should say "YouTube key saved".'
    Write-Step 'The video rows are below Favorites and Recent: press Down on the remote.'
    Write-Step 'If a row says "Could not load videos", tell Claude the exact message.'
}

# ---------------------------------------------------------------------------
# Option 3: undo
# ---------------------------------------------------------------------------
function Invoke-Restore {
    Write-Title 'Undo everything'
    $state = Get-State
    $disabledNow = Get-DisabledPackages

    # Everything this tool recorded, plus anything from its lists that is
    # currently disabled (covers a lost or deleted state file).
    $targets = @{}
    foreach ($entry in $state) { $targets[$entry.Id] = $entry.Method }
    $known = @($Catalog | ForEach-Object { $_.Id }) + @($StockLauncher, $SetupWraith)
    foreach ($id in $known) {
        if (($disabledNow -contains $id) -and (-not $targets.ContainsKey($id))) {
            $targets[$id] = 'disabled'
        }
    }

    if ($targets.Count -eq 0) {
        Write-Ok 'Nothing to undo.'
        return
    }
    Write-Step ("This will turn " + $targets.Count + " app(s) back on:")
    foreach ($id in $targets.Keys) { Write-Step "  - $id" }
    if (-not (Read-YesNo 'Go ahead?' $true)) { return }

    Write-Host ''
    # Launcher first, so the home screen is back before anything else.
    $order = @($StockLauncher, $SetupWraith) + @($targets.Keys | Where-Object { $_ -ne $StockLauncher -and $_ -ne $SetupWraith })
    $done = 0
    foreach ($id in $order) {
        if (-not $targets.ContainsKey($id)) { continue }
        if (Enable-Package $id $targets[$id]) { $done++ }
    }
    Write-Host ''
    Write-Ok ("$done of " + $targets.Count + " turned back on.")
    if ($targets.ContainsKey($StockLauncher) -and -not $script:IsDryRun) {
        [void](Invoke-Adb shell input keyevent KEYCODE_HOME)
        Write-Step "The Google home screen is back. You can uninstall $NewLauncherName from"
        Write-Step 'Settings > Apps on the TV if you no longer want it.'
    }
}

# ---------------------------------------------------------------------------
# Option 4: export the package list
# ---------------------------------------------------------------------------
function Export-PackageList {
    Write-Title 'Save the package list'
    $all = Get-InstalledPackages | Sort-Object
    if ($all.Count -eq 0) {
        Write-Bad 'Could not read the app list from the TV.'
        return
    }
    $disabled = Get-DisabledPackages
    $lines = foreach ($id in $all) {
        if ($disabled -contains $id) { "$id   [disabled]" } else { $id }
    }
    $file = Join-Path $script:Root 'tv-packages.txt'
    $lines | Set-Content -Path $file -Encoding ASCII
    Write-Ok ("Saved " + $all.Count + " packages to:")
    Write-Step "  $file"
    Write-Step 'Paste that file into the chat to get more bloat identified for your TV.'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Title 'Google TV Debloater'
if ($script:IsDryRun) { Write-Warn 'DRY RUN: nothing on the TV will be changed.' }

$script:Adb = Find-Adb
if (-not $script:Adb -and -not $AdbPath) { $script:Adb = Install-PlatformTools }
if (-not $script:Adb) {
    Write-Bad 'ADB is required. Exiting.'
    exit 1
}
Write-Ok "Using ADB at $script:Adb"

if (-not (Connect-Tv)) {
    Write-Step 'Not connected. Exiting.'
    exit 1
}

while ($true) {
    Write-Title 'What do you want to do?'
    Write-Step '1. Debloat: turn off preinstalled apps and extras (safe, start here)'
    Write-Step '2. Replace the home screen to remove ads (bigger change)'
    Write-Step '3. Undo everything this tool changed'
    Write-Step '4. Save a list of every package on the TV'
    Write-Step '5. Install Glass Home, the custom home screen'
    Write-Step '6. Install SmartTube (YouTube without ads, third-party)'
    Write-Step '7. Set the YouTube API key for the Glass Home video rows'
    Write-Step 'q. Quit'
    Write-Host ''
    $choice = (Read-Host '  Choose').Trim().ToLower()
    switch ($choice) {
        '1' { Invoke-Debloat }
        '2' { Invoke-LauncherReplace }
        '3' { Invoke-Restore }
        '4' { Export-PackageList }
        '5' { Invoke-GlassHome }
        '6' { Invoke-SmartTube }
        '7' { Invoke-SetYouTubeKey }
        'q' {
            [void](Invoke-AdbRaw disconnect $script:Serial)
            Write-Step 'Disconnected. Bye.'
            exit 0
        }
        default { Write-Step 'Type a number from 1 to 7, or q.' }
    }
}
