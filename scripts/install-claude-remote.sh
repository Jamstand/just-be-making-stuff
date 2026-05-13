#!/usr/bin/env bash
# One-shot installer for Claude-remote-access on the Pi:
#   1. Generates ADMIN_TOKEN if absent.
#   2. Sets up auto-deploy systemd timer (git pull every 30s, restart subs).
#   3. Configures Tailscale Funnel on :443 so /admin/* is reachable from
#      outside the tailnet (gated by ADMIN_TOKEN bearer auth).
#
# Re-runnable; existing config is preserved.
set -euo pipefail

REPO_DIR="${REPO_DIR:-$HOME/just-be-making-stuff}"
USER_NAME="${USER_NAME:-$USER}"
SERVICE="subs.service"

if [ ! -d "$REPO_DIR" ]; then
  echo "error: $REPO_DIR not found"
  exit 1
fi
cd "$REPO_DIR"

echo "── 1. ADMIN_TOKEN"
if ! grep -q '^ADMIN_TOKEN=' .env 2>/dev/null; then
  TOKEN="$(openssl rand -hex 32)"
  printf '\nADMIN_TOKEN=%s\n' "$TOKEN" >> .env
  echo "   generated new ADMIN_TOKEN"
else
  TOKEN="$(grep '^ADMIN_TOKEN=' .env | head -1 | sed 's/^ADMIN_TOKEN=//')"
  echo "   keeping existing ADMIN_TOKEN"
fi

echo
echo "── 2. Passwordless sudo for service restart (narrow rule)"
SUDO_RULE="/etc/sudoers.d/subs-auto-deploy"
sudo tee "$SUDO_RULE" > /dev/null <<EOF
$USER_NAME ALL=(root) NOPASSWD: /bin/systemctl restart $SERVICE
EOF
sudo chmod 0440 "$SUDO_RULE"
echo "   installed $SUDO_RULE"

echo
echo "── 3. Auto-deploy systemd timer (every 30s)"
sudo tee /etc/systemd/system/subs-auto-deploy.service > /dev/null <<EOF
[Unit]
Description=Auto-deploy subs from git
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$USER_NAME
WorkingDirectory=$REPO_DIR
ExecStart=/bin/bash $REPO_DIR/scripts/auto-deploy.sh
EOF

sudo tee /etc/systemd/system/subs-auto-deploy.timer > /dev/null <<'EOF'
[Unit]
Description=Auto-deploy subs every 30s

[Timer]
OnBootSec=30
OnUnitActiveSec=30s
AccuracySec=5s
Unit=subs-auto-deploy.service

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now subs-auto-deploy.timer
echo "   timer enabled and active"

echo
echo "── 4. Tailscale Funnel on :443 (exposes admin endpoints publicly,"
echo "      protected by ADMIN_TOKEN). Existing serve mappings unchanged."
echo "   note: requires Funnel to be allowed for this node in the Tailscale"
echo "   admin console (https://login.tailscale.com/admin/acls)."
if sudo tailscale funnel --bg --https=443 http://127.0.0.1:3000 2>&1; then
  echo "   funnel configured"
else
  echo "   warning: funnel command failed — enable Funnel in admin console and re-run"
fi

echo
echo "── 5. Restart subs to pick up ADMIN_TOKEN"
sudo systemctl restart "$SERVICE"
sleep 1
systemctl is-active "$SERVICE" >/dev/null && echo "   $SERVICE is active" || echo "   warning: $SERVICE is not active"

TAILNET="$(tailscale status --json 2>/dev/null \
  | grep -o '"MagicDNSSuffix":"[^"]*"' \
  | sed 's/.*:"//; s/"$//' || true)"
HOSTNAME_S="$(hostname)"
URL="https://${HOSTNAME_S}.${TAILNET}"

cat <<EOF

================================================================
  Claude remote access configured
================================================================
  Admin URL:    $URL
  Admin token:  $TOKEN

  Quick sanity check from your laptop (or anywhere):
    curl -s -H "Authorization: Bearer $TOKEN" \\
      $URL/admin/status

  Share these two values with Claude when you want hands-off
  debugging. Rotate at any time by deleting the ADMIN_TOKEN line
  from .env and re-running this script.
================================================================
EOF
