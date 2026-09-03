# Claude Assistant for After Effects (CEP panel)

The After Effects sibling of the DaVinci Resolve plugin: a chat panel
(Window > Extensions) driving AE through the Claude Code CLI on your
Pro/Max subscription. Same renderer, history, approvals, and MCP bridge as
the Resolve plugin — different tool layer, and a much more open creative
API on the other side.

```
html/ (chat UI — shared design)  ── window.assistant ──  html/panel.js
   panel.js: spawns claude CLI (-p, stream-json)         (CEP Node 17,
             hosts the MCP server IN-PROCESS over          mixed context)
             Streamable HTTP — no node binary, no child
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
Requires AE 2021+ (CEP 11/12) and the Claude Code CLI signed in. No
separate Node install: the panel's own runtime serves MCP over HTTP.

## Honesty notes

- Headless-tested (`node test_ae_plugin.js` — the ExtendScript host runs
  under Node against a fake AE DOM), but **never yet run inside real
  After Effects**. First launch is the real test; report what you see.
- `grab_frame` uses the undocumented `saveFrameToPng` — if Adobe removed
  it in your build, the error says so plainly.
- CEP is Adobe's legacy-but-current extension platform for AE (CEP 12,
  AE 2025+); Adobe signals UXP is the future but has shipped no UXP for AE.

## Tracking (Mocha Pro + SAM 3)

After Effects never lets a script start its own trackers. The panel goes
around that wall two ways:

- **`mocha_track`** — drives Mocha Pro's planar tracker headless through the
  python3 that ships inside Mocha (standalone app or the Adobe plug-in
  bundle; `mocha_status` finds and probes it). Claude picks the region in
  source pixels (`grab_frame` + `layer_info`), Mocha tracks it, and the
  exports land as native AE data: mask keyframes (via Edit → Paste Mocha
  mask, fed from the clipboard), Corner Pin / CC Power Pin keyframes, or
  Position/Scale/Rotation keyframes. `apply_track_file` applies exports you
  saved from the Mocha GUI yourself. Job files and logs live under
  `~/Library/Application Support/ClaudeAssistantAE/mocha/`.
- **`ai_segment`** — uploads the layer's source file to fal.ai, runs SAM 3
  (or 3.1) video segmentation by text prompt / points / boxes, downloads
  the segmented video and sets it as the layer's luma track matte. Paid
  (about $0.005 per 16 frames); `set_fal_key` stores the key in
  `~/.claude-assistant.json`, `dry_run: true` quotes the cost first.

Live finding (Mocha Pro 2026.5, Adobe plug-in bundle only, macOS): the
bundled python3 loads the engine and lists the AE exporters, but creating a
Project fails at RLM license checkout ("License Error: 2, ISV genarts", no
cached/roaming/file license) — a plug-in-only install has no license an
external process can check out. `mocha_status` now runs that checkout on a
probe clip and reports `license: ok|failed` with the fix list; a license
file or server goes in `~/.claude-assistant.json` as `mocha_license`
(passed to Mocha as RLM_LICENSE / genarts_LICENSE). Still unknown until a
licensed run: whether "Paste Mocha mask" places keys relative to the layer
or to the current time (`mask_paste_at` covers both), and what fal's
"segmented video" looks like (cut-out on black works as a luma matte; an
overlay does not).
