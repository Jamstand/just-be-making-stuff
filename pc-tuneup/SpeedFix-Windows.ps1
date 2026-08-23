<#
  SpeedFix for Windows
  --------------------
  Scans your PC for the common causes of slow download speeds (and a few
  general health problems), explains what it finds in plain English, and
  offers safe, reversible fixes. NOTHING is changed without asking you first.

  How to run (from an Administrator PowerShell window):
      powershell -ExecutionPolicy Bypass -File .\SpeedFix-Windows.ps1

  Scan without being offered any fixes:
      powershell -ExecutionPolicy Bypass -File .\SpeedFix-Windows.ps1 -ScanOnly

  A full report is saved to your Desktop as SpeedFix-Report.txt.

  Works on Windows 10 and 11 (Windows PowerShell 5.1 or newer).
#>

#Requires -Version 5.1
param(
    [switch]$ScanOnly
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------- helpers ---

$script:Findings = New-Object System.Collections.ArrayList

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 62) -ForegroundColor DarkCyan
    Write-Host ("  " + $Title) -ForegroundColor Cyan
    Write-Host ("=" * 62) -ForegroundColor DarkCyan
}

function Write-Finding {
    param(
        [ValidateSet('OK', 'INFO', 'WARN', 'BAD')][string]$Level,
        [string]$Message
    )
    $color = switch ($Level) {
        'OK'   { 'Green' }
        'INFO' { 'Gray' }
        'WARN' { 'Yellow' }
        'BAD'  { 'Red' }
    }
    Write-Host ("  [{0}] {1}" -f $Level, $Message) -ForegroundColor $color
    if ($Level -eq 'WARN' -or $Level -eq 'BAD') {
        [void]$script:Findings.Add(("[{0}] {1}" -f $Level, $Message))
    }
}

function Ask-Fix {
    param(
        [string]$Description,
        [scriptblock]$Action,
        [switch]$NeedsAdmin
    )
    if ($ScanOnly) {
        Write-Host ("  (scan-only mode - skipping offered fix: {0})" -f $Description) -ForegroundColor DarkGray
        return
    }
    if ($NeedsAdmin -and -not $script:IsAdmin) {
        Write-Host ("  SKIPPED (needs Administrator): {0}" -f $Description) -ForegroundColor DarkYellow
        Write-Host "          Re-run this script from an Administrator PowerShell window to enable it." -ForegroundColor DarkYellow
        return
    }
    Write-Host ""
    Write-Host ("  OFFERED FIX: {0}" -f $Description) -ForegroundColor Magenta
    $answer = Read-Host "  Apply this fix? Type y for yes, anything else to skip"
    if ($answer -match '^[Yy]') {
        try {
            & $Action
            Write-Host "  Done." -ForegroundColor Green
        } catch {
            Write-Host ("  That fix hit an error (nothing was harmed): {0}" -f $_.Exception.Message) -ForegroundColor Red
        }
    } else {
        Write-Host "  Skipped." -ForegroundColor DarkGray
    }
}

# ------------------------------------------------------------------ set-up ---

$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$reportPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'SpeedFix-Report.txt'
$transcriptStarted = $false
try {
    Start-Transcript -Path $reportPath -Force | Out-Null
    $transcriptStarted = $true
} catch {
    Write-Host "(Could not create the Desktop report file - continuing without it.)" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "  SpeedFix for Windows" -ForegroundColor White
Write-Host "  Scans for common causes of slow downloads and offers safe fixes."
Write-Host "  Every fix asks for your permission first. Nothing runs silently."
if (-not $script:IsAdmin) {
    Write-Host ""
    Write-Host "  NOTE: You are NOT running as Administrator. The scan will work," -ForegroundColor Yellow
    Write-Host "  but some fixes will be unavailable. For the full toolkit, close" -ForegroundColor Yellow
    Write-Host "  this window, right-click the Start button, choose" -ForegroundColor Yellow
    Write-Host "  'Terminal (Admin)' or 'Windows PowerShell (Admin)', and re-run." -ForegroundColor Yellow
}

# Make sure modern HTTPS works for the speed test on older Windows 10 builds.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# ------------------------------------------------------- 1. system basics ---

Write-Section "1. System basics"
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $uptimeDays = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
    $ramGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $freeRamGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    Write-Finding INFO ("Windows: {0} (build {1})" -f $os.Caption.Trim(), $os.BuildNumber)
    Write-Finding INFO ("Memory: {0} GB installed, {1} GB free right now" -f $ramGB, $freeRamGB)
    if ($uptimeDays -ge 7) {
        Write-Finding WARN ("This PC has not restarted in {0} days. A real restart (not just sleep) clears out a lot of gunk." -f $uptimeDays)
    } else {
        Write-Finding OK ("Last restart: {0} days ago" -f $uptimeDays)
    }
    if ($freeRamGB -lt 1) {
        Write-Finding WARN "Less than 1 GB of memory is free - the whole PC (including downloads) will feel slow. Close unused apps and browser tabs."
    }
} catch {
    Write-Finding INFO "Could not read basic system info."
}

# disk space
try {
    $sys = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $freeGB = [math]::Round($sys.FreeSpace / 1GB, 1)
    $totalGB = [math]::Round($sys.Size / 1GB, 1)
    $freePct = [math]::Round(100 * $sys.FreeSpace / $sys.Size, 0)
    if ($freePct -lt 10) {
        Write-Finding BAD ("Drive C: is nearly full ({0} GB free of {1} GB). Windows slows down badly when the drive is this full." -f $freeGB, $totalGB)
        Ask-Fix -Description "Open the built-in Disk Cleanup tool so you can free up space (opens a window; you choose what to delete)" -Action {
            Start-Process cleanmgr.exe -ArgumentList '/d','C:'
        }
    } else {
        Write-Finding OK ("Drive C: has {0} GB free of {1} GB ({2}% free)" -f $freeGB, $totalGB, $freePct)
    }
} catch {
    Write-Finding INFO "Could not check disk space."
}

# pending reboot
try {
    $rebootPending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                     (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    if ($rebootPending) {
        Write-Finding WARN "Windows has updates waiting for a restart. Until you restart, Windows Update can keep using your internet in the background."
    }
} catch { }

# power plan (Power saver can throttle Wi-Fi)
try {
    $scheme = powercfg /getactivescheme 2>$null
    if ($scheme -match 'a1841308-3541-4fab-bc81-f71556f20b4a') {
        Write-Finding WARN "The 'Power saver' power plan is active. It can deliberately slow down your Wi-Fi and CPU."
        Ask-Fix -Description "Switch the power plan to 'Balanced' (the normal Windows default; you can change it back in Settings > Power)" -Action {
            powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e
        }
    } else {
        Write-Finding OK "Power plan is not set to Power saver."
    }
} catch { }

# ------------------------------------------------- 2. network connection ---

Write-Section "2. Your network connection"

$activeAdapters = @()
try {
    $activeAdapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' -and $_.Virtual -eq $false })
    if ($activeAdapters.Count -eq 0) {
        # fall back to including virtual in case detection was off
        $activeAdapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })
    }
    foreach ($a in $activeAdapters) {
        Write-Finding INFO ("Connected via: {0} ({1}) - link speed {2}" -f $a.Name, $a.InterfaceDescription, $a.LinkSpeed)
        if ($a.PhysicalMediaType -match '802\.3' -and $a.LinkSpeed -match '^100\s*Mbps') {
            Write-Finding WARN "Your wired connection linked at only 100 Mbps. That usually means an old/damaged network cable or an old port. Try a different cable (Cat5e or Cat6)."
        }
        if ($a.LinkSpeed -match '^10\s*Mbps') {
            Write-Finding BAD "This connection linked at 10 Mbps - something is wrong with the cable, port, or adapter."
        }
    }
} catch {
    Write-Finding INFO "Could not list network adapters."
}

# Wi-Fi details
$onWifi = $false
try {
    $wlan = netsh wlan show interfaces 2>$null
    if ($wlan -and ($wlan | Out-String) -match '(\d+)%') {
        $onWifi = $true
        $signal = [int]$Matches[1]
        if ($signal -lt 50) {
            Write-Finding BAD ("Wi-Fi signal is weak ({0}%). This alone can wreck download speed. Move closer to the router, or use a network cable." -f $signal)
        } elseif ($signal -lt 70) {
            Write-Finding WARN ("Wi-Fi signal is so-so ({0}%). Speeds improve a lot closer to the router." -f $signal)
        } else {
            Write-Finding OK ("Wi-Fi signal strength: {0}%" -f $signal)
        }
    }
} catch { }

# VPN check
try {
    $vpns = @(Get-VpnConnection -ErrorAction SilentlyContinue | Where-Object { $_.ConnectionStatus -eq 'Connected' })
    $vpnAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'VPN|TAP|WireGuard|OpenVPN|Tunnel'
    })
    if ($vpns.Count -gt 0 -or $vpnAdapters.Count -gt 0) {
        Write-Finding WARN "A VPN appears to be connected. VPNs often cut download speed by half or more. Try turning it off and re-testing."
    } else {
        Write-Finding OK "No VPN connection detected."
    }
} catch { }

# Proxy check (a proxy you never set up is a classic malware / leftover-app cause of slow downloads)
try {
    $proxyReg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
    $proxySuspicious = $false
    if ($proxyReg.ProxyEnable -eq 1 -and $proxyReg.ProxyServer) {
        Write-Finding WARN ("All your internet traffic is being routed through a proxy: {0}. If you did not set this up (or your workplace did not), it should be removed - it slows everything down and can even be spyware." -f $proxyReg.ProxyServer)
        $proxySuspicious = $true
    }
    if ($proxyReg.AutoConfigURL) {
        Write-Finding WARN ("A proxy auto-config script is set: {0}. If you do not recognize it, it should be removed." -f $proxyReg.AutoConfigURL)
        $proxySuspicious = $true
    }
    if (-not $proxySuspicious) {
        Write-Finding OK "No proxy is configured (good - traffic goes straight to the internet)."
    } else {
        Ask-Fix -Description "Remove the proxy settings (ONLY do this if you/your workplace did not deliberately set up a proxy)" -Action {
            Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyEnable -Value 0
            Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name AutoConfigURL -ErrorAction SilentlyContinue
            netsh winhttp reset proxy | Out-Null
        }
    }
} catch {
    Write-Finding INFO "Could not check proxy settings."
}

# TCP auto-tuning (when this is off, downloads crawl even on fast internet - a very common cause)
try {
    $tcp = Get-NetTCPSetting -SettingName Internet -ErrorAction Stop
    if ($tcp.AutoTuningLevelLocal -ne 'Normal') {
        Write-Finding BAD ("Windows TCP auto-tuning is set to '{0}' instead of 'Normal'. This is a classic cause of terrible download speeds on fast internet - often left behind by an old 'optimizer' app." -f $tcp.AutoTuningLevelLocal)
        Ask-Fix -NeedsAdmin -Description "Set TCP auto-tuning back to 'Normal' (the Windows default)" -Action {
            Set-NetTCPSetting -SettingName Internet -AutoTuningLevelLocal Normal
        }
    } else {
        Write-Finding OK "TCP auto-tuning is set to Normal (the correct default)."
    }
} catch {
    Write-Finding INFO "Could not check TCP auto-tuning."
}

# hosts file tampering
try {
    $hostsLines = @(Get-Content "$env:SystemRoot\System32\drivers\etc\hosts" -ErrorAction Stop |
        Where-Object { $_.Trim() -and $_.Trim() -notmatch '^#' })
    if ($hostsLines.Count -gt 0) {
        Write-Finding WARN ("Your 'hosts' file has {0} custom entr{1} - sometimes legitimate, but malware also uses this file to redirect or block websites. Entries found:" -f $hostsLines.Count, $(if ($hostsLines.Count -eq 1) { 'y' } else { 'ies' }))
        $hostsLines | Select-Object -First 10 | ForEach-Object { Write-Host ("        " + $_) -ForegroundColor Yellow }
    } else {
        Write-Finding OK "The 'hosts' file is clean (no custom redirects)."
    }
} catch { }

# ------------------------------------------------ 3. live speed measurements ---

Write-Section "3. Measuring your actual speeds (takes ~30 seconds)"

# ping / latency
try {
    $pings = Test-Connection -ComputerName 1.1.1.1 -Count 4 -ErrorAction Stop
    $avgPing = [math]::Round(($pings | Measure-Object -Property ResponseTime -Average).Average, 0)
    if ($avgPing -gt 100) {
        Write-Finding WARN ("Ping (response time) to the internet: {0} ms - that is high. Common on weak Wi-Fi or a congested/overloaded router." -f $avgPing)
    } else {
        Write-Finding OK ("Ping (response time) to the internet: {0} ms" -f $avgPing)
    }
} catch {
    Write-Finding BAD "Could not ping the internet at all. If web pages also do not load, restart your router first, then re-run this."
}

# DNS lookup speed
$dnsSlow = $false
try {
    $dnsMs = [math]::Round((Measure-Command { Resolve-DnsName www.microsoft.com -ErrorAction Stop }).TotalMilliseconds, 0)
    if ($dnsMs -gt 300) {
        $dnsSlow = $true
        Write-Finding WARN ("DNS lookups (turning website names into addresses) took {0} ms - slow. This makes every site feel sluggish to start." -f $dnsMs)
    } else {
        Write-Finding OK ("DNS lookup time: {0} ms" -f $dnsMs)
    }
} catch {
    $dnsSlow = $true
    Write-Finding WARN "A DNS lookup failed. Your DNS server may be having problems."
}

# actual download speed test (50 MB from Cloudflare)
$measuredMbps = $null
try {
    Write-Host "  Downloading a 50 MB test file from Cloudflare, please wait..." -ForegroundColor Gray
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add('User-Agent', 'SpeedFix-Diagnostic')
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $bytes = $wc.DownloadData('https://speed.cloudflare.com/__down?bytes=52428800')
    $sw.Stop()
    $wc.Dispose()
    $measuredMbps = [math]::Round(($bytes.Length * 8) / $sw.Elapsed.TotalSeconds / 1MB, 1)
    if ($measuredMbps -lt 10) {
        Write-Finding BAD ("Measured download speed: {0} Mbps - genuinely slow. The findings above (Wi-Fi signal, VPN, proxy, TCP tuning) are the usual suspects." -f $measuredMbps)
    } elseif ($measuredMbps -lt 50) {
        Write-Finding WARN ("Measured download speed: {0} Mbps - usable but modest. Compare this to the speed your internet plan promises." -f $measuredMbps)
    } else {
        Write-Finding OK ("Measured download speed: {0} Mbps. If a specific app downloads much slower than this, the problem is that app or its server - not your PC or internet." -f $measuredMbps)
    }
} catch {
    Write-Finding WARN "The download speed test could not run (the test server may be unreachable). You can test manually at https://speed.cloudflare.com"
}

# --------------------------------------------- 4. background bandwidth use ---

Write-Section "4. Things quietly using your PC in the background"

# Delivery Optimization (Windows Update peer-to-peer sharing)
try {
    $doSvc = Get-Service -Name DoSvc -ErrorAction Stop
    if ($doSvc.Status -eq 'Running') {
        Write-Finding INFO "Windows 'Delivery Optimization' is running. By default it can UPLOAD Windows updates to strangers' PCs, eating your bandwidth."
        Write-Host "        To turn that part off: Settings > Windows Update > Advanced options >" -ForegroundColor Gray
        Write-Host "        Delivery Optimization > switch OFF 'Allow downloads from other devices'." -ForegroundColor Gray
    }
} catch { }

# OneDrive / cloud sync
try {
    $sync = @(Get-Process -Name 'OneDrive','Dropbox','GoogleDriveFS' -ErrorAction SilentlyContinue)
    if ($sync.Count -gt 0) {
        $names = ($sync | Select-Object -ExpandProperty ProcessName -Unique) -join ', '
        Write-Finding INFO ("Cloud sync apps running: {0}. If one is busy syncing a big folder, it will eat your bandwidth while it works." -f $names)
    }
} catch { }

# startup programs
try {
    $startupNames = New-Object System.Collections.ArrayList
    foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
                     'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run') {
        if (Test-Path $key) {
            $props = Get-ItemProperty $key
            $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object { [void]$startupNames.Add($_.Name) }
        }
    }
    if ($startupNames.Count -gt 8) {
        Write-Finding WARN ("{0} programs launch automatically every time Windows starts: {1}. Each one costs speed. Review them in Task Manager > Startup apps and disable what you do not need." -f $startupNames.Count, ($startupNames -join ', '))
    } elseif ($startupNames.Count -gt 0) {
        Write-Finding INFO ("Programs that start with Windows: {0}" -f ($startupNames -join ', '))
    }
} catch { }

# top resource users right now
try {
    $topCpu = Get-Process | Sort-Object CPU -Descending | Select-Object -First 5 -Property ProcessName
    Write-Finding INFO ("Heaviest apps this session: {0}" -f (($topCpu | Select-Object -ExpandProperty ProcessName) -join ', '))
} catch { }

# ------------------------------------------------------ 5. security check ---

Write-Section "5. Quick security check"
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    if ($mp.RealTimeProtectionEnabled) {
        Write-Finding OK "Windows Defender real-time protection is ON."
    } else {
        Write-Finding BAD "Windows Defender real-time protection is OFF. Unless another antivirus you trust is installed, turn it back on in Windows Security."
    }
    $sigAgeDays = [int]((Get-Date) - $mp.AntivirusSignatureLastUpdated).TotalDays
    if ($sigAgeDays -gt 7) {
        Write-Finding WARN ("Antivirus definitions are {0} days old. Windows Update may be stuck." -f $sigAgeDays)
    }
    Ask-Fix -NeedsAdmin -Description "Run a Windows Defender QUICK scan now (takes a few minutes; this window will wait for it)" -Action {
        Start-MpScan -ScanType QuickScan
        Write-Host "  Quick scan finished. Open Windows Security to see any results." -ForegroundColor Green
    }
} catch {
    Write-Finding INFO "Could not read Windows Defender status (a third-party antivirus may be managing protection)."
}

# ----------------------------------------------------- 6. universal fixes ---

Write-Section "6. Safe clean-up fixes (recommended for everyone)"

Ask-Fix -Description "Flush the DNS cache (clears out stale website-address lookups; completely safe)" -Action {
    ipconfig /flushdns | Out-Null
}

if ($dnsSlow) {
    Ask-Fix -Description "Switch DNS to Cloudflare's fast public resolver 1.1.1.1 (often noticeably faster; to undo later run: Get-DnsClientServerAddress to view, or set your adapter back to 'Obtain DNS automatically' in Control Panel)" -NeedsAdmin -Action {
        Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Virtual -eq $false } | ForEach-Object {
            Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses '1.1.1.1','1.0.0.1'
        }
        ipconfig /flushdns | Out-Null
    }
}

Ask-Fix -NeedsAdmin -Description "Stop Windows from turning off your network adapter to save power (a frequent cause of Wi-Fi that gets slow or drops; reversible in Device Manager)" -Action {
    $changed = 0
    Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Virtual -eq $false } | ForEach-Object {
        $pnpId = $_.PnPDeviceID
        Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue |
            Where-Object { $_.InstanceName -like "$pnpId*" } |
            ForEach-Object {
                $_ | Set-CimInstance -Property @{ Enable = $false }
                $changed++
            }
    }
    if ($changed -eq 0) {
        Write-Host "  (No adapters supported this setting - nothing was changed.)" -ForegroundColor DarkGray
    }
}

Ask-Fix -NeedsAdmin -Description "Reset the Windows network stack (Winsock + TCP/IP). The classic deep fix for stubborn network weirdness. Harmless, but you MUST restart the PC afterward, and you may need to re-enter your Wi-Fi password" -Action {
    netsh winsock reset | Out-Null
    netsh int ip reset | Out-Null
    Write-Host "  Network stack reset. RESTART YOUR PC to finish this fix." -ForegroundColor Yellow
}

# ----------------------------------------------------------------- summary ---

Write-Section "Summary"
if ($script:Findings.Count -eq 0) {
    Write-Host "  No problems found on this PC. If downloads are still slow, the cause is" -ForegroundColor Green
    Write-Host "  outside this computer - see the checklist below." -ForegroundColor Green
} else {
    Write-Host ("  {0} thing(s) worth attention were found:" -f $script:Findings.Count) -ForegroundColor Yellow
    $script:Findings | ForEach-Object { Write-Host ("   - " + $_) }
}

Write-Host ""
Write-Host "  If speeds are STILL slow after the fixes, the problem is usually not the PC:" -ForegroundColor Cyan
Write-Host "   1. Restart your router: unplug it, wait 30 seconds, plug it back in."
Write-Host "   2. Test another device (phone on Wi-Fi). Slow there too = router or internet provider."
Write-Host "   3. If possible, plug the PC into the router with a network cable and re-test."
Write-Host "   4. Re-run this script afterwards to re-measure."
if ($transcriptStarted) {
    Write-Host ""
    Write-Host ("  A full report was saved to: {0}" -f $reportPath) -ForegroundColor Gray
    try { Stop-Transcript | Out-Null } catch { }
}
Write-Host ""
Read-Host "Press Enter to close"
