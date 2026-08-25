#!/bin/bash
# Installs the Claude Assistant Workflow Integration plugin into DaVinci
# Resolve Studio on macOS. Copies the plugin folder plus Blackmagic's
# WorkflowIntegration.node (taken from YOUR Resolve install — not shipped
# here). /Library needs sudo; you'll be prompted once.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/com.jamstand.claude.assistant"
ROOT="/Library/Application Support/Blackmagic Design/DaVinci Resolve/Workflow Integration Plugins"
DEST="$ROOT/com.jamstand.claude.assistant"
NODE_MODULE="/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Workflow Integrations/Examples/SamplePlugin/WorkflowIntegration.node"

[ -f "$SRC/manifest.xml" ] || { echo "Plugin folder not found next to this script."; exit 1; }
[ -f "$NODE_MODULE" ] || {
  echo "WorkflowIntegration.node not found at:"
  echo "  $NODE_MODULE"
  echo "Is DaVinci Resolve STUDIO installed from blackmagicdesign.com?"
  exit 1
}

sudo mkdir -p "$DEST"
sudo cp -R "$SRC/." "$DEST/"
sudo cp "$NODE_MODULE" "$DEST/"
echo "[ok] plugin installed          -> $DEST"
echo "[ok] WorkflowIntegration.node  -> copied from your Resolve install"
echo
echo "Restart DaVinci Resolve, then: Workspace > Workflow Integrations > Claude Assistant"
echo "(Also needs the Claude Code CLI: npm install -g @anthropic-ai/claude-code)"
