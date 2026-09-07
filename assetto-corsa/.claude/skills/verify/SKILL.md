---
name: verify
description: How to actually run and drive the Gear Speedo pieces (PowerShell checker, CSP Lua app, AC Python app) on a Linux box, since the real surface -- Assetto Corsa -- cannot run here.
---

# Verifying Gear Speedo without Assetto Corsa

The true surface is AC/CSP in-game on Windows. Unreachable here. These are the
closest runtimes that do exist, with the harnesses in `verify/`.

## check-gearspeedo.ps1 — real PowerShell

```bash
S=/tmp/pw && mkdir -p $S && cd $S
curl -sSL -o pw.tgz https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/powershell-7.4.6-linux-x64.tar.gz
tar xzf pw.tgz && chmod +x pwsh
```

Two Linux gotchas, both handled by `verify/checker-scenario.sh`:

- `[Environment]::GetFolderPath("MyDocuments")` is **empty** on Linux .NET, and
  `Join-Path ""` throws. Point it somewhere via `$HOME/.config/user-dirs.dirs`
  containing `XDG_DOCUMENTS_DIR="/abs/path"`. Override `$HOME` per scenario so
  Downloads/Desktop are fake too.
- pwsh normalises `\` to `/` in paths, so a plain nested tree
  (`fakeac/apps/lua/GearSpeedo/...`) is what the script's Windows paths resolve to.

Run: `HOME=$FAKEHOME $S/pwsh -NoLogo -File check-gearspeedo.ps1 -AcRoot $FAKEAC`.
Drive the matrix: lua-only (+/- CSP marker `dwrite.dll` + `extension/`),
python-only healthy, both, incomplete lua, not ticked, unlisted, nested one too
deep, in Documents, in Downloads, zip unextracted, nothing, crashed acMain.

## apps/lua — LuaJIT (CSP's runtime family)

`apt-get install luajit`, then `cd verify && luajit drive-lua.lua`. `cspstub.lua`
fakes `ac`/`ui`/`vec2`/`rgbm` and records `RECT`/`TEXT` (as `p1`/`p2` vec2s, not
scalars). Every ui call is asserted for arity/type. Gear convention here is CSP's:
`<0`=R, `0`=N, `n`=nth — not the Python one.

## apps/python — mock `ac`/`acsys`

`cd verify && python3 drive-python.py` (mock modules alongside). Gear convention
is AC Python's: `0`=R, `1`=N, `2`=1st.

## Do not trust

Anything about the CSP Action Bar's grouping, in-game font metrics, or which
CSP build first shipped an API — none of that is observable here.
