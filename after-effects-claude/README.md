# Claude Assistant for After Effects (CEP panel)

The After Effects sibling of the DaVinci Resolve plugin: a chat panel
(Window > Extensions) driving AE through the Claude Code CLI on your
Pro/Max subscription. Same renderer, history, approvals, and MCP bridge as
the Resolve plugin — different tool layer, and a much more open creative
API on the other side.

```
html/ (chat UI — shared design)  ── window.assistant ──  html/panel.js
   panel.js: spawns claude CLI (-p, stream-json)         (CEP Node 17,
             TCP bridge  <- bridge.js (MCP stdio)         mixed context)
             CSInterface.evalScript -> host/ae-tools.jsx (ExtendScript ES3)
```

## What it can do that the Resolve plugin can't (doc-verified + tested)

| Feature | How |
|---|---|
| Speed ramps | `speed_ramp` — real Time Remap keyframes with eases |
| Masks | `add_mask` — scriptable shapes, feather, modes |
| Titles | `add_text` — any font, styled, timed |
| Any effect, any parameter | `apply_effect` — returns each effect's real property list |
| Arbitrary keyframes | `set_keyframes` on any property path |
| Full scripting DOM | `run_extendscript` escape hatch (ES3) |

Shared honest wall: **tracking analysis is not scriptable in AE either**
(point tracker / 3D camera tracker / Warp Stabilizer — read-only after a
human runs them). Codecs are template-only from script.

## Install (macOS)

```
./install-ae-mac.sh
```
Then the two manual steps it prints (scripting pref + restart AE).
Requires AE 2021+ (CEP 11/12), the Claude Code CLI signed in, and Node.

## Honesty notes

- Headless-tested (`node test_ae_plugin.js` — the ExtendScript host runs
  under Node against a fake AE DOM), but **never yet run inside real
  After Effects**. First launch is the real test; report what you see.
- `grab_frame` uses the undocumented `saveFrameToPng` — if Adobe removed
  it in your build, the error says so plainly.
- CEP is Adobe's legacy-but-current extension platform for AE (CEP 12,
  AE 2025+); Adobe signals UXP is the future but has shipped no UXP for AE.
