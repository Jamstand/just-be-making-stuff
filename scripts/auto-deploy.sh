#!/usr/bin/env bash
# Polled by systemd timer (see subs-auto-deploy.timer). Pulls the latest
# commit from origin on the currently checked-out branch and restarts subs
# if anything changed. Refuses to pull when the working tree is dirty so
# local debug edits aren't silently overwritten.
set -euo pipefail

REPO="${REPO:-$HOME/just-be-making-stuff}"
SERVICE="${SERVICE:-subs.service}"

cd "$REPO"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git fetch origin "$BRANCH" --quiet

LOCAL="$(git rev-parse HEAD)"
REMOTE="$(git rev-parse "origin/$BRANCH")"

if [ "$LOCAL" = "$REMOTE" ]; then
  exit 0
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "auto-deploy: working tree dirty, skipping pull on $BRANCH"
  exit 1
fi

echo "auto-deploy: $LOCAL -> $REMOTE on $BRANCH"
git pull --ff-only origin "$BRANCH"
sudo /bin/systemctl restart "$SERVICE"
echo "auto-deploy: restarted $SERVICE"
