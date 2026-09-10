#!/bin/bash
# Build a fake AC install + Documents tree for check-gearspeedo.ps1, then run it.
#   ./checker-scenario.sh <app> <python> <active> <log>
#   app:    lua | python | both | nested | nestedlua | absent | none
#   python: enabled | disabled          active: active | inactive | unlisted
#   log:    loaded | crashed | silent
#   CSP_BUILD=<n> fakes the installed CSP build (default 2650; 2500 hits the too-old path)
# Needs: pwsh (PWSH=/path/to/pwsh), see .claude/skills/verify/SKILL.md.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$HERE/.."
S="${S:-$(mktemp -d)}"; AC="$S/fakeac"; DOCS="$S/fakedocs/Assetto Corsa"; FH="$S/fakehome"
rm -rf "$AC" "$S/fakedocs" "$FH"; mkdir -p "$AC" "$DOCS/cfg" "$DOCS/logs" "$FH/.config" "$FH/Downloads"
printf 'XDG_DOCUMENTS_DIR="%s/fakedocs"\n' "$S" > "$FH/.config/user-dirs.dirs"
lua()    { mkdir -p "$AC/apps/lua" "$AC/extension/config"; cp -r "$REPO/apps/lua/GearSpeedo" "$AC/apps/lua/"; touch "$AC/dwrite.dll"; printf '[VERSION]\nSHADERS_PATCH_BUILD=%s\n' "${CSP_BUILD:-2650}" > "$AC/extension/config/data_manifest.ini"; }
python() { mkdir -p "$AC/apps/python/GearSpeedo" "$AC/content/gui/icons"; cp "$REPO/apps/python/GearSpeedo/GearSpeedo.py" "$AC/apps/python/GearSpeedo/"; touch "$AC/content/gui/icons/Gear Speedo_ON.png"; }
case "$1" in
  lua) lua ;; python) python ;; both) lua; python ;;
  nested) mkdir -p "$AC/apps/python/GearSpeedo/GearSpeedo"; cp "$REPO/apps/python/GearSpeedo/GearSpeedo.py" "$AC/apps/python/GearSpeedo/GearSpeedo/" ;;
  nestedlua) mkdir -p "$AC/apps/lua/GearSpeedo"; cp -r "$REPO/apps/lua/GearSpeedo" "$AC/apps/lua/GearSpeedo/"; touch "$AC/dwrite.dll" ;;
  absent) mkdir -p "$AC/apps/python"; touch "$FH/Downloads/GearSpeedo.zip" ;;
  none) ;;
esac
case "$2" in enabled) printf '[PYTHON]\nENABLE_PYTHON=1\n' > "$DOCS/cfg/gameplay.ini";; disabled) printf '[PYTHON]\nENABLE_PYTHON=0\n' > "$DOCS/cfg/gameplay.ini";; esac
case "$3" in
  active)   printf '[GEARS]\nACTIVE=1\n\n[GEARSPEEDO]\nACTIVE=1\n' > "$DOCS/cfg/python.ini" ;;
  inactive) printf '[GEARS]\nACTIVE=1\n\n[GEARSPEEDO]\nACTIVE=0\n' > "$DOCS/cfg/python.ini" ;;
  unlisted) printf '[GEARS]\nACTIVE=1\n' > "$DOCS/cfg/python.ini" ;;
esac
case "$4" in
  loaded)  printf 'GearSpeedo: module imported\nGearSpeedo: loaded (AC API 1.0)\n' > "$DOCS/logs/py_log.txt" ;;
  crashed) printf 'GearSpeedo: module imported\n[GearSpeedo: error] GearSpeedo: acMain failed\nTraceback (most recent call last):\n  File "apps/python/GearSpeedo/GearSpeedo.py", line 99, in acMain\nNameError: fake\n' > "$DOCS/logs/py_log.txt" ;;
  silent)  printf '[sol_config: error] unrelated\n' > "$DOCS/logs/py_log.txt" ;;
esac
HOME="$FH" "${PWSH:-pwsh}" -NoLogo -File "$REPO/check-gearspeedo.ps1" -AcRoot "$AC"
