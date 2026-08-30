#!/bin/bash
# One-command update for the Claude Assistant plugin on macOS.
# One-time setup so no sudo is ever needed here:
#   sudo chown -R "$USER" "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Workflow Integration Plugins/com.jamstand.claude.assistant"
set -e
REPO="$HOME/just-be-making-stuff"
BRANCH="claude/davinci-resolve-claude-plugin-bw69a6"
DEST="/Library/Application Support/Blackmagic Design/DaVinci Resolve/Workflow Integration Plugins/com.jamstand.claude.assistant"

cd "$REPO"
if [ "$(git branch --show-current)" != "$BRANCH" ]; then
  echo "Switching to $BRANCH (was on $(git branch --show-current))"
  git checkout "$BRANCH"
fi
git pull

if [ ! -d "$DEST" ]; then
  echo "✗ Plugin not installed at: $DEST"
  echo "  Run the installer first: davinci-resolve-claude/workflow-plugin/install-plugin.sh"
  exit 1
fi
if [ ! -w "$DEST" ]; then
  echo "✗ No write permission on the plugin folder. One-time fix:"
  echo "  sudo chown -R \"\$USER\" \"$DEST\""
  echo "Then re-run this script — no sudo ever again."
  exit 1
fi

# Copy contents over the install; never delete the folder — it holds the
# WorkflowIntegration.node copied from Resolve, which is not in the repo.
cp -R "$REPO/davinci-resolve-claude/workflow-plugin/com.jamstand.claude.assistant/." "$DEST/"
echo "✓ Updated. Close and reopen the Claude Assistant window in Resolve"
echo "  (Workspace > Workflow Integrations) — open panels keep old code."
