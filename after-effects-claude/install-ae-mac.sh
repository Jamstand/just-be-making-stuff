#!/bin/bash
# Install/update Claude Assistant for After Effects (macOS, CEP panel).
set -e
REPO="$HOME/just-be-making-stuff"
SRC="$REPO/after-effects-claude/com.jamstand.claude.ae"
DEST="$HOME/Library/Application Support/Adobe/CEP/extensions/com.jamstand.claude.ae"

echo "Claude Assistant for After Effects — installer"
[ -d "$SRC" ] || { echo "✗ Repo not found at $SRC — clone it first."; exit 1; }

mkdir -p "$DEST"
cp -R "$SRC/." "$DEST/"
# history.js/bridge.js live one level up from html/ in the extension
echo "✓ Panel copied to: $DEST"

# Unsigned-extension debug mode for every CEP era AE 2021+ might use.
for v in 11 12; do
  defaults write com.adobe.CSXS.$v PlayerDebugMode 1
done
killall cfprefsd 2>/dev/null || true
echo "✓ PlayerDebugMode enabled (CSXS 11 + 12)"
# CEP caches extension JS aggressively; stale panel.js/app.js after an update
# looks exactly like a broken panel. Purge it.
rm -rf "$HOME/Library/Caches/CSXS/cep_cache" 2>/dev/null || true
echo "✓ CEP cache purged"

command -v claude >/dev/null 2>&1 || [ -x /opt/homebrew/bin/claude ] || [ -x /usr/local/bin/claude ] \
  && echo "✓ claude CLI found" \
  || echo "⚠ claude CLI not found — npm install -g @anthropic-ai/claude-code, then run 'claude' once to sign in"

cat <<'NOTES'

Two manual steps, one-time:
1. Open After Effects > Settings > Scripting & Expressions and enable
   "Allow Scripts to Write Files and Access Network" (frame grabs and
   renders need it — the panel will tell you if it's off).
2. Restart After Effects, then open:  Window > Extensions > Claude Assistant

Update later: git pull in the repo, re-run this script, close+reopen the panel.
NOTES
