#!/usr/bin/env bash
# Installs "Claude Assistant.py" into DaVinci Resolve's Utility scripts folder.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SRC_DIR/Claude Assistant.py"

if [[ ! -f "$SRC" ]]; then
  echo "error: 'Claude Assistant.py' not found next to this script." >&2
  exit 1
fi

case "$(uname -s)" in
  Darwin)
    DEST="$HOME/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility"
    ;;
  Linux)
    if [[ -d "/opt/resolve/Fusion/Scripts" && -w "/opt/resolve/Fusion/Scripts" ]]; then
      DEST="/opt/resolve/Fusion/Scripts/Utility"
    else
      DEST="$HOME/.local/share/DaVinciResolve/Fusion/Scripts/Utility"
    fi
    ;;
  *)
    echo "error: unsupported OS. On Windows use install.ps1." >&2
    exit 1
    ;;
esac

mkdir -p "$DEST"
cp "$SRC" "$DEST/"
echo "Installed to: $DEST/Claude Assistant.py"
echo "In Resolve:   Workspace > Scripts > Claude Assistant"
