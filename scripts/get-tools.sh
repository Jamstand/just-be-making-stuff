#!/usr/bin/env bash
#
# scripts/get-tools.sh - download the pinned Luau tool binaries WITHOUT rokit.
#
# Used where rokit cannot run: GitHub Actions (.github/workflows/luau-ci.yml) and the weekly
# agent's cloud sandbox (automation/PLAYBOOK.md). On your own PC/Mac use rokit instead
# ("rokit install", see docs/AUTOMATION.md section 5) - it puts the tools on PATH.
#
# Usage:
#   bash scripts/get-tools.sh [DIR]        # default DIR: .lint/tools
#   LUAU_TOOLS_DIR=DIR bash scripts/check.sh
#
# Versions come from rokit.toml (single source of truth). Downloads are the official release
# zips from GitHub. Only Linux x86_64 binaries are downloaded (that is what CI and the cloud
# sandbox run); on any other platform it prints how to use rokit and exits 2.
# Already-present binaries are kept (re-run is a no-op). Plain bash 3.2+, curl, unzip.
#
# Exit codes: 0 ok, 1 download/unzip failed, 2 unsupported platform or rokit.toml unreadable.

set -euo pipefail

cd "$(dirname "$0")/.."   # repo root
DIR="${1:-.lint/tools}"

if [ ! -f rokit.toml ]; then
	echo "get-tools: rokit.toml not found in $(pwd)" >&2
	exit 2
fi

case "$(uname -s)-$(uname -m)" in
	Linux-x86_64) ;;
	*)
		echo "get-tools: only Linux x86_64 is supported by this script ($(uname -s) $(uname -m) detected)." >&2
		echo "           On your own machine install rokit and run: rokit install   (docs/AUTOMATION.md, section 5)" >&2
		exit 2
		;;
esac

# version_of <tool>  -> the version pinned in rokit.toml, e.g. 7.7.0
version_of() {
	grep -E "^$1[[:space:]]*=" rokit.toml | sed -E 's/.*@([^"]+)".*/\1/'
}
ROJO_V="$(version_of rojo)"
LSP_V="$(version_of luau-lsp)"
SELENE_V="$(version_of selene)"
if [ -z "$ROJO_V" ] || [ -z "$LSP_V" ] || [ -z "$SELENE_V" ]; then
	echo "get-tools: could not read rojo / luau-lsp / selene versions from rokit.toml" >&2
	exit 2
fi

mkdir -p "$DIR"

# fetch <name> <url>  -> downloads the zip and unpacks the single binary into $DIR
fetch() {
	local name="$1" url="$2" zip="$DIR/$1.zip"
	if [ -x "$DIR/$name" ]; then
		echo "get-tools: $name already present, skipping"
		return 0
	fi
	echo "get-tools: downloading $name from $url"
	if ! curl -sSfL --retry 3 --retry-delay 2 -o "$zip" "$url"; then
		echo "get-tools: download failed for $name" >&2
		return 1
	fi
	unzip -qo "$zip" -d "$DIR"
	rm -f "$zip"
	chmod +x "$DIR/$name"
	"$DIR/$name" --version
}

fetch rojo     "https://github.com/rojo-rbx/rojo/releases/download/v${ROJO_V}/rojo-${ROJO_V}-linux-x86_64.zip"
fetch luau-lsp "https://github.com/JohnnyMorganz/luau-lsp/releases/download/${LSP_V}/luau-lsp-linux-x86_64.zip"
fetch selene   "https://github.com/Kampfkarren/selene/releases/download/${SELENE_V}/selene-${SELENE_V}-linux.zip"

echo "get-tools: ready in $DIR  ->  LUAU_TOOLS_DIR=$DIR bash scripts/check.sh"
