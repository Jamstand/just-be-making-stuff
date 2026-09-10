# Claude Assistant — Workflow Integration plugin (Electron)

The same integration style as the Higgsfield plugin: a real HTML panel under
**Workspace > Workflow Integrations**, launched by Resolve's own bundled
Electron. This is the modern sibling of the single-file Python panel — both
can be installed side by side; they are separate entries in the menu.

```
renderer (HTML chat UI, the design-file look)
   ↕ IPC
main.js — WorkflowIntegration.node → live Resolve object
        — tools.js: 35 JS tools + run_javascript (grab_still vision, colour suite: pipeline_doctor, qc_scan, match_shot, match_timeline, auto_balance, match_hues, design_look, apply_vignette)
        — spawns claude CLI (-p, stream-json) on your subscription
             └─ bridge.js (MCP stdio) → TCP loopback → tools.js
```

## Install

Windows: right-click `Install-Plugin.ps1` → Run with PowerShell (admin
prompt is expected — the plugin folder lives in ProgramData).
macOS: `./install-plugin.sh` (sudo for /Library).

Both copy the plugin folder **plus `WorkflowIntegration.node` from your own
Resolve install** (Blackmagic's bridge module is not distributed in this
repo). Then restart Resolve — the Workflow Integrations menu is scanned at
startup only. Requires **Resolve Studio** (hard product gate: the free
edition does not load workflow integrations) and the Claude Code CLI
(`npm install -g @anthropic-ai/claude-code`, signed in once).

## What v1 has vs. the Python panel

| | Python panel (Scripts menu) | This plugin |
|---|---|---|
| Tools | 70, incl. grading/Fusion/Higgsfield | 36 incl. `grab_still` vision, colour suite (`pipeline_doctor`, `qc_scan`, `match_shot`, `match_timeline`, `auto_balance`, `match_hues`, `design_look`, `apply_vignette`) + `run_javascript` |
| Approvals | buttons above the input | real inline amber card, per the design |
| UI | Qt rich-text subset | full HTML/CSS (the design file, faithfully) |
| History browser | yes | yes — autosaved chats, reopen + resume, transcript recap when the session expired |
| Themes / drop folder | yes | not yet |
| Session resume | across restarts | across restarts (saved session id, recap fallback) |

`run_javascript` narrows the tool gap substantially: the JS scripting object
is the same API as Python's (`project.GetMediaPool()`, `timeline.AddMarker`,
…), so the model can do anything the API allows, with the code shown in the
transcript and gated by approvals.

## Colour suite (what it does, measured)

`bench_match.js` renders a 24-patch ColorChecker scene, disturbs it
camera-side (exposure, white balance, contrast, saturation, a greens-only
cast) and runs the panel's own code path — the same measurement, fit and
closed loop the tools use — reporting ΔE2000 over the patches (under 1 is
invisible). It is the tool's pipeline model, not a live Resolve grab.

- `match_shot`: fits slope, offset, power per channel and saturation to the
  two frames' percentile curves in DaVinci Intermediate log, refines the
  candidate on the grab's own pixels (simulated node), then a
  measure-apply-regrab loop with a regression guard. Refuses night-vs-day.
- `match_timeline`: measures every clip on a track, picks the hero (given
  or the medoid), gates and matches each clip; one approval, one log.
- `auto_balance`: no reference; greyness-weighted grey-world + white-patch
  white balance and a luma-median exposure band, as a slope-1 CDL (offsets
  in log = gains), closed loop on the cast of the near-neutral pixels.
- `match_hues`: per-hue correction as a .cube (hue shift / saturation /
  value per 15° sector) from CDF-matched hue histograms, kept only where a
  simulation on the target's pixels moves it toward the reference. Colour
  based only — no windows, no tracking. SetLUT is dead on the Mac install,
  so the .cube is loaded by hand (the tool says how).
- `qc_scan` now also reports saturation, the cast on near-neutral pixels
  and the skin-tone cluster's angle off the vectorscope skin line.
- `compare_grades`: the head-to-head. Make local versions of a clip
  (e.g. "Colourlab" and "Claude"), name a reference clip, and it loads each
  version, grabs it and scores it: per-pixel ΔE2000 when the target is
  the same media and frame as the reference (a duplicate you deliberately
  mis-graded), or a distribution distance (levels, curves, chroma, hue
  overlap, skin angle) for two different shots of a scene. Restores the
  active version afterwards.

## Honesty notes

- Built against Blackmagic's documented plugin contract (manifest schema,
  sandboxed Electron pattern, `WorkflowIntegration.node` API) and the same
  CLI/bridge architecture the Python panel has proven live — but this plugin
  has NOT yet run inside a real Resolve. The tool layer and MCP bridge are
  fully tested headlessly (`node test_plugin.js`). First-launch
  issues will show in the plugin window; report what you see.
- Quit handling calls `CleanUp()` and destroys the window on close and on
  Resolve quit — the known Windows failure mode is an orphaned electron.exe
  keeping `WorkflowIntegration.node` locked.
- `ANTHROPIC_API_KEY` is stripped from the CLI environment (it silently
  overrides subscription auth), and the CLI's working directory is pinned so
  sessions survive Resolve restarts.

## Slash commands

Type `/` in the chat box and a menu opens, like Claude's: arrow keys to
choose, Enter or Tab to fill the command in, Esc to close. `/study <link>
<link>` (or `/train`, the same thing) downloads finished edits (TikTok,
Instagram, YouTube), builds a study timeline and analyses each one into
your style profile. `/help`, `/new`, `/history` and `/copy` are handled by
the panel itself. An unknown `/word` is answered by the panel ("No command
called /word") rather than reaching Claude Code, which would reply
"Unknown command"; a line starting with a file path is passed to Claude as
a message. Anything else you type goes to Claude as it is.
