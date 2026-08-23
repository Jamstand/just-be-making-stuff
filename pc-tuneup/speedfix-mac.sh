#!/bin/bash
#
# SpeedFix for Mac
# ----------------
# Scans your Mac for the common causes of slow download speeds, explains
# what it finds in plain English, and offers safe, reversible fixes.
# NOTHING is changed without asking you first.
#
# How to run:  open Terminal (press Cmd+Space, type Terminal, press Enter), then:
#     bash ~/Downloads/speedfix-mac.sh
#
# Scan without being offered any fixes:
#     bash ~/Downloads/speedfix-mac.sh --scan-only
#
# A full report is saved to your Desktop as speedfix-report.txt.

SCAN_ONLY=0
[ "$1" = "--scan-only" ] && SCAN_ONLY=1

REPORT="$HOME/Desktop/speedfix-report.txt"
FINDINGS=()

# ------------------------------------------------------------- helpers ------

say() {           # say <text>  - print and log
  printf '%s\n' "$1" | tee -a "$REPORT"
}

finding() {       # finding <OK|INFO|WARN|BAD> <message>
  local level="$1"; shift
  local msg="$1"
  case "$level" in
    OK)   printf '  \033[32m[OK]\033[0m %s\n'   "$msg" ;;
    INFO) printf '  \033[90m[INFO]\033[0m %s\n' "$msg" ;;
    WARN) printf '  \033[33m[WARN]\033[0m %s\n' "$msg" ;;
    BAD)  printf '  \033[31m[BAD]\033[0m %s\n'  "$msg" ;;
  esac
  printf '  [%s] %s\n' "$level" "$msg" >> "$REPORT"
  if [ "$level" = "WARN" ] || [ "$level" = "BAD" ]; then
    FINDINGS+=("[$level] $msg")
  fi
}

section() {
  say ""
  say "=============================================================="
  say "  $1"
  say "=============================================================="
}

ask_fix() {       # ask_fix <description> <command...>
  local desc="$1"; shift
  if [ "$SCAN_ONLY" = "1" ]; then
    say "  (scan-only mode - skipping offered fix: $desc)"
    return
  fi
  echo ""
  printf '  \033[35mOFFERED FIX:\033[0m %s\n' "$desc"
  printf '  Apply this fix? Type y for yes, anything else to skip: '
  read -r answer
  if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
    if "$@"; then
      say "  Done."
    else
      say "  That fix hit an error (nothing was harmed)."
    fi
  else
    say "  Skipped."
  fi
}

# --------------------------------------------------------------- set-up -----

: > "$REPORT" 2>/dev/null || REPORT=/dev/null
say ""
say "  SpeedFix for Mac"
say "  Scans for common causes of slow downloads and offers safe fixes."
say "  Every fix asks for your permission first. Nothing runs silently."
say "  (Fixes may ask for your Mac login password - that is macOS asking,"
say "   the password is not seen or stored by this script.)"

if [ "$(uname)" != "Darwin" ]; then
  say ""
  say "  NOTE: This looks like Linux, not a Mac. The scan mostly still works,"
  say "  but the fixes are Mac-specific and will be skipped if they fail."
fi

# ------------------------------------------------- 1. system basics ---------

section "1. System basics"
if command -v sw_vers >/dev/null 2>&1; then
  finding INFO "macOS version: $(sw_vers -productVersion 2>/dev/null)"
fi
finding INFO "Uptime: $(uptime | sed 's/.*up */up /; s/,.*user.*//')"

DISK_PCT=$(df -P / | awk 'NR==2 {gsub("%",""); print $5}')
DISK_AVAIL=$(df -Ph / | awk 'NR==2 {print $4}')
if [ -n "$DISK_PCT" ] && [ "$DISK_PCT" -ge 90 ] 2>/dev/null; then
  finding BAD "The startup disk is ${DISK_PCT}% full (only ${DISK_AVAIL} free). Macs slow down badly when the disk is this full. Open  > About This Mac > Storage to clean up."
else
  finding OK "Startup disk has ${DISK_AVAIL} free."
fi

# ------------------------------------------------- 2. network connection ----

section "2. Your network connection"

IFACE=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
if [ -z "$IFACE" ]; then
  IFACE=$(ip route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' | head -1)
fi
if [ -n "$IFACE" ]; then
  finding INFO "Active network interface: $IFACE"
else
  finding BAD "No default internet route found. If web pages do not load either, restart your router first."
fi

# Wi-Fi signal (best-effort; Apple keeps moving this around between versions)
WIFI_INFO=""
AIRPORT="/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
if [ -x "$AIRPORT" ]; then
  WIFI_INFO=$("$AIRPORT" -I 2>/dev/null)
fi
if [ -n "$WIFI_INFO" ]; then
  RSSI=$(printf '%s\n' "$WIFI_INFO" | awk '/ agrCtlRSSI:/{print $2}')
  if [ -n "$RSSI" ]; then
    if [ "$RSSI" -le -75 ] 2>/dev/null; then
      finding BAD "Wi-Fi signal is weak (${RSSI} dBm). This alone can wreck download speed. Move closer to the router, or use a network cable."
    elif [ "$RSSI" -le -65 ] 2>/dev/null; then
      finding WARN "Wi-Fi signal is so-so (${RSSI} dBm). Speeds improve a lot closer to the router."
    else
      finding OK "Wi-Fi signal is strong (${RSSI} dBm)."
    fi
  fi
elif command -v system_profiler >/dev/null 2>&1; then
  SIGNAL_LINE=$(system_profiler SPAirPortDataType 2>/dev/null | grep -m1 'Signal / Noise' | sed 's/^ *//')
  [ -n "$SIGNAL_LINE" ] && finding INFO "Wi-Fi $SIGNAL_LINE (closer to 0 is better; below -75 dBm is weak)"
fi

# Proxy check (a proxy you never set up is a classic cause of slow downloads)
if command -v scutil >/dev/null 2>&1; then
  PROXY_ON=$(scutil --proxies 2>/dev/null | grep -E 'HTTPEnable|HTTPSEnable|SOCKSEnable|ProxyAutoConfigEnable' | grep -c ': 1')
  if [ "$PROXY_ON" -gt 0 ] 2>/dev/null; then
    finding WARN "A proxy is switched ON in your network settings. If you (or your workplace) did not set this up deliberately, it slows everything down and can even be spyware. Turn it off in System Settings > Wi-Fi > Details > Proxies."
  else
    finding OK "No proxy is configured (good - traffic goes straight to the internet)."
  fi
fi

# VPN check
if ifconfig 2>/dev/null | grep -qE '^(utun[0-9]+|ppp0|ipsec0).*<UP' ; then
  finding INFO "A VPN-style tunnel may be active (utun interface up). Note: macOS also uses these for iCloud Private Relay. If you use a VPN app, try turning it off and re-testing - VPNs often cut speed in half."
fi

# ------------------------------------------- 3. live speed measurements -----

section "3. Measuring your actual speeds (takes ~30 seconds)"

# ping / latency
PING_AVG=$(ping -c 4 -t 10 1.1.1.1 2>/dev/null | awk -F'/' '/round-trip|rtt/{printf "%.0f", $5}')
if [ -n "$PING_AVG" ]; then
  if [ "$PING_AVG" -gt 100 ] 2>/dev/null; then
    finding WARN "Ping (response time) to the internet: ${PING_AVG} ms - that is high. Common on weak Wi-Fi or a congested router."
  else
    finding OK "Ping (response time) to the internet: ${PING_AVG} ms"
  fi
else
  finding BAD "Could not ping the internet at all. If web pages also do not load, restart your router first, then re-run this."
fi

# DNS lookup speed
DNS_SLOW=0
if command -v dig >/dev/null 2>&1; then
  DNS_MS=$(dig +tries=1 +time=5 www.apple.com 2>/dev/null | awk '/Query time:/{print $4}')
  if [ -n "$DNS_MS" ]; then
    if [ "$DNS_MS" -gt 300 ] 2>/dev/null; then
      DNS_SLOW=1
      finding WARN "DNS lookups (turning website names into addresses) took ${DNS_MS} ms - slow. This makes every site feel sluggish to start."
    else
      finding OK "DNS lookup time: ${DNS_MS} ms"
    fi
  else
    DNS_SLOW=1
    finding WARN "A DNS lookup failed. Your DNS server may be having problems."
  fi
fi

# actual download speed test (50 MB from Cloudflare)
say "  Downloading a 50 MB test file from Cloudflare, please wait..."
SPEED_BPS=$(curl -sS --max-time 90 -o /dev/null -w '%{speed_download}' 'https://speed.cloudflare.com/__down?bytes=52428800' 2>/dev/null)
if [ -n "$SPEED_BPS" ]; then
  MBPS=$(printf '%s' "$SPEED_BPS" | awk '{printf "%.1f", $1 * 8 / 1000000}')
  MBPS_INT=$(printf '%s' "$MBPS" | cut -d. -f1)
  if [ "$MBPS_INT" -lt 10 ] 2>/dev/null; then
    finding BAD "Measured download speed: ${MBPS} Mbps - genuinely slow. The findings above (Wi-Fi signal, VPN, proxy) are the usual suspects."
  elif [ "$MBPS_INT" -lt 50 ] 2>/dev/null; then
    finding WARN "Measured download speed: ${MBPS} Mbps - usable but modest. Compare this to the speed your internet plan promises."
  else
    finding OK "Measured download speed: ${MBPS} Mbps. If a specific app downloads much slower than this, the problem is that app or its server - not your Mac or internet."
  fi
else
  finding WARN "The download speed test could not run (the test server may be unreachable). You can test manually at https://speed.cloudflare.com"
fi

# ------------------------------------------------------------- 4. fixes -----

section "4. Safe clean-up fixes"

flush_dns() {
  sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
}
ask_fix "Flush the DNS cache (clears out stale website-address lookups; completely safe; asks for your Mac password)" flush_dns

if [ "$DNS_SLOW" = "1" ] && command -v networksetup >/dev/null 2>&1; then
  set_fast_dns() {
    local svc changed=0
    while IFS= read -r svc; do
      case "$svc" in "An asterisk"*|\**) continue ;; esac
      if networksetup -setdnsservers "$svc" 1.1.1.1 1.0.0.1 2>/dev/null; then
        changed=1
        say "  DNS updated for: $svc"
      fi
    done < <(networksetup -listallnetworkservices 2>/dev/null | tail -n +2)
    [ "$changed" = "1" ]
  }
  ask_fix "Switch DNS to Cloudflare's fast public resolver 1.1.1.1 (often noticeably faster; to undo later run: networksetup -setdnsservers \"Wi-Fi\" empty)" set_fast_dns
fi

if [ -n "$IFACE" ] && command -v ipconfig >/dev/null 2>&1 && [ "$(uname)" = "Darwin" ]; then
  renew_dhcp() {
    sudo ipconfig set "$IFACE" DHCP
  }
  ask_fix "Ask the router for a fresh network address (renew DHCP; briefly interrupts the connection for a few seconds)" renew_dhcp
fi

# ------------------------------------------------------------- summary ------

section "Summary"
if [ "${#FINDINGS[@]}" -eq 0 ]; then
  say "  No problems found on this Mac. If downloads are still slow, the cause is"
  say "  outside this computer - see the checklist below."
else
  say "  ${#FINDINGS[@]} thing(s) worth attention were found:"
  for f in "${FINDINGS[@]}"; do say "   - $f"; done
fi

say ""
say "  If speeds are STILL slow after the fixes, the problem is usually not the Mac:"
say "   1. Restart your router: unplug it, wait 30 seconds, plug it back in."
say "   2. Test another device (phone on Wi-Fi). Slow there too = router or internet provider."
say "   3. If possible, plug the Mac into the router with a network cable and re-test."
say "   4. Also check background uploads: photos syncing to iCloud, Time Machine backups,"
say "      and cloud drives (Dropbox/Google Drive) can quietly eat your bandwidth."
say "   5. Re-run this script afterwards to re-measure."
if [ "$REPORT" != "/dev/null" ]; then
  say ""
  say "  A full report was saved to: $REPORT"
fi
echo ""
printf 'Press Enter to close'
read -r _
