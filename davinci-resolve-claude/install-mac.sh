#!/usr/bin/env bash
# One installer for everything Claude Assistant on macOS. Run it from a
# terminal:   ./install-mac.sh
#
# It always installs the chat panel into Workspace > Scripts (per-user, no
# password needed), then OFFERS the two optional launch points that need an
# admin password because they live in /Library:
#   - Workspace > Workflow Integrations > Claude Assistant  (same panel,
#     registered like a plugin; Resolve Studio only)
#   - the Electron plugin (the Higgsfield-style HTML panel; Studio only)
# Say n to either and nothing outside your home folder is touched.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANEL="$HERE/Claude Assistant.py"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer is for macOS. Use install.ps1 / Install-Plugin.ps1 on Windows." >&2
  exit 1
fi
[[ -f "$PANEL" ]] || { echo "error: 'Claude Assistant.py' not found next to this script." >&2; exit 1; }

echo "== 1/4  Chat panel -> Workspace > Scripts (per-user, no password) =="
SCRIPTS="$HOME/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility"
mkdir -p "$SCRIPTS"
cp "$PANEL" "$SCRIPTS/"
echo "  [ok] $SCRIPTS/Claude Assistant.py"

echo
echo "== 2/4  Workspace > Workflow Integrations entry (optional, Studio only) =="
echo "  Registers the same panel like a native plugin. Needs sudo (/Library)."
read -r -p "  Install it? [Y/n] " REPLY
if [[ ! "$REPLY" =~ ^[Nn] ]]; then
  WFI="/Library/Application Support/Blackmagic Design/DaVinci Resolve/Workflow Integration Plugins"
  sudo mkdir -p "$WFI"
  sudo cp "$PANEL" "$WFI/"
  echo "  [ok] $WFI/Claude Assistant.py"
else
  echo "  skipped"
fi

echo
echo "== 3/4  Electron plugin — the Higgsfield-style HTML panel (optional) =="
if [[ -x "$HERE/workflow-plugin/install-plugin.sh" || -f "$HERE/workflow-plugin/install-plugin.sh" ]]; then
  read -r -p "  Install it? [y/N] " REPLY
  if [[ "$REPLY" =~ ^[Yy] ]]; then
    bash "$HERE/workflow-plugin/install-plugin.sh"
  else
    echo "  skipped (run workflow-plugin/install-plugin.sh any time)"
  fi
else
  echo "  (workflow-plugin folder not found — pull the latest repo)"
fi

echo
echo "== 4/4  Claude Code CLI check =="
if command -v claude >/dev/null 2>&1; then
  echo "  [ok] claude CLI found: $(command -v claude)"
else
  echo "  [!] claude CLI not found. The panel needs it (or an API key):"
  echo "        npm install -g @anthropic-ai/claude-code"
  echo "        claude   # sign in once with your Claude account, then /exit"
fi

echo
echo "Done. Restart DaVinci Resolve, then look in:"
echo "  Workspace > Scripts > Claude Assistant                (always)"
echo "  Workspace > Workflow Integrations > Claude Assistant  (if installed; Studio)"
echo "Note: the Workflow Integrations menu is scanned at startup only — a full"
echo "restart of Resolve is required before entries appear."
