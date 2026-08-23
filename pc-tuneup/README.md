# PC Tune-Up — fix slow downloads

Two small scripts that scan your computer for the common causes of **slow
download speeds on fast internet** (plus a few general health problems),
explain what they find in plain English, and offer to fix them.

**Safety promises:**

- Every fix **asks you y/n first** — nothing changes without your permission.
- Every fix is a standard, reversible Windows/macOS setting change. No files
  are deleted, no software is installed.
- A full report of everything found is saved to your **Desktop** so you can
  read it later or show it to someone.
- The scripts are short and readable — you (or anyone helping you) can open
  them and see exactly what they do before running them.

---

## Windows (Windows 10 / 11)

1. Download **`SpeedFix-Windows.ps1`** from this folder
   (open the file on GitHub → click the **Download raw file** button, the
   down-arrow icon at the top right of the file view). It lands in your
   **Downloads** folder.
2. Right-click the **Start button** → choose **Terminal (Admin)** or
   **Windows PowerShell (Admin)** → click **Yes** when Windows asks.
3. Copy-paste this line and press Enter:

   ```powershell
   powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Downloads\SpeedFix-Windows.ps1"
   ```

4. Read what it finds, and answer **y** or **n** to each offered fix.

> Prefer to just look first? Add ` -ScanOnly` to the end of the command and
> it will only report, never offer fixes.

### What the Windows version checks

- **Actual download speed** (measured against Cloudflare) — so you know the
  real number, not a guess
- **Wi-Fi signal strength** and wired link speed (a bad cable or weak signal
  is the #1 cause of "fast internet, slow computer")
- **Hidden proxy settings** — leftover apps and some malware quietly route
  all your traffic through a slow middleman
- **TCP auto-tuning disabled** — a classic leftover from "PC optimizer" apps
  that makes downloads crawl
- **VPN connections** eating your speed
- Slow **DNS** (the "phone book" of the internet)
- **Power-saver settings** that throttle Wi-Fi
- Nearly **full disk**, week-old **uptime**, **startup program** bloat,
  cloud-sync apps, a tampered **hosts file**, and **Windows Defender** status

### Fixes it can offer (each one asks first)

Flush DNS cache · switch to fast public DNS (1.1.1.1) · remove rogue proxy
settings · restore TCP auto-tuning · stop Windows powering down the network
adapter · switch off Power-saver plan · reset the network stack (the classic
deep fix) · run a Defender quick scan · open Disk Cleanup

---

## Mac

1. Download **`speedfix-mac.sh`** from this folder into **Downloads**.
2. Open **Terminal** (press `Cmd+Space`, type `Terminal`, press Enter).
3. Copy-paste this line and press Enter:

   ```bash
   bash ~/Downloads/speedfix-mac.sh
   ```

4. Read what it finds, and answer **y** or **n** to each offered fix.
   (Fixes may ask for your Mac login password — that's macOS asking, the
   script never sees or stores it.)

> Scan-only mode: `bash ~/Downloads/speedfix-mac.sh --scan-only`

The Mac version checks download speed, ping, Wi-Fi signal, proxies, VPN
tunnels, DNS speed, and disk space; it can flush the DNS cache, switch to
fast public DNS, and renew your network lease.

---

## What no script can fix (the honest part)

If the scan finds nothing and your measured speed is still far below what
you pay for, the problem is almost always **outside the computer**:

1. **Restart your router** — unplug it, wait 30 seconds, plug it back in.
   This fixes a remarkable number of "slow internet" problems.
2. **Test a second device** (your phone, on Wi-Fi). Slow there too? It's the
   router or your internet provider — call them and quote the measured
   speed from the report on your Desktop.
3. **Try a network cable** instead of Wi-Fi. If cable is fast and Wi-Fi is
   slow, the fix is router placement, a mesh kit, or a newer router.
4. **One app slow, everything else fast?** (e.g. game launchers, app
   stores) — that app's servers are the bottleneck, and nothing on your
   side will change it.
