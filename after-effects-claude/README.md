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
external process can check out. Resolved by launching the Mocha GUI from the effect inside AE and
signing in: that wrote `rehost_mpp-multihost-so.lic` (plus a `.reprise`
cache) into `~/Library/Application Support/GenArts/rlm/`, after which the
headless checkout passed. `mocha_status` runs that checkout on a
probe clip and reports `license: ok|failed` with the fix list; a license
file or server goes in `~/.claude-assistant.json` as `mocha_license`
(passed to Mocha as RLM_LICENSE / genarts_LICENSE). Second live wall: `track_layers` under the guide's bare QCoreApplication
dies with "Can't obtain rendering context" — the tracker needs an OpenGL
context, which only a Qt application with a platform plugin can provide.
mocha_job.py now starts a full QApplication (falling back to QGuiApplication
/ QCoreApplication), and `mocha_status` runs a 3-frame probe track over a
ladder of variants (widgets, gui, offscreen QPA) and remembers the one that
works as `mocha_qt` in the config; `ready` is true only when that probe
track succeeds. First real track (C0768.MP4, 59.94 fps, 240 frames) taught three more
things, all now handled in the tool: Mocha's exporters wrote a 24 fps
header for 59.94 footage (the panel now converts frames with the SOURCE
rate and sets the project frame_rate); the guide's `Surface0X` parameter
path failed because Mocha's project file spells layer names with
underscores ("Claude_Track"), which the bridge now uses; the panel also
retargets the export to the requested corners through the per-frame
homography, so the applied corner pin is right either way; and a region that leaves
the frame re-locks onto whatever is left (the road), so the result carries
a `track_report` with the usable range. The mask export (`*.shape4ae`) turned out to be keyframe-data text whose
"mocha shape" block holds 64 normalised x,y points per frame for the legacy
`ISL MochaShapeImporter` effect, whose custom value AE scripting refuses;
the panel now parses those points and builds native mask keyframes
(RotoBezier-smoothed, chunked 40 frames per call) — no clipboard, no menu
command. Still unknown until a
licensed run: whether "Paste Mocha mask" places keys relative to the layer
or to the current time (`mask_paste_at` covers both), and what fal's
"segmented video" looks like (cut-out on black works as a luma matte; an
overlay does not).

## Music and beat sync

Drop songs into `~/Music/Claude Assistant` (or list folders as `music_dirs`
in `~/.claude-assistant.json`). The panel decodes them with macOS's own
`afconvert` (ffmpeg elsewhere) and analyses them locally: tempo, every beat
and downbeat, bass hits with strength, intro/build/drop sections, and the
drop time. Tools:

- **music_list / analyze_music** — the library and a song's beat map.
- **add_music** — imports the song and adds it to the comp.
- **beat_control** — a guide null named BEAT with keyframed Slider Controls
  (Beat, Bar, Bass, Energy, BPM) plus bar/drop markers on the comp, so any
  expression can follow the music.
- **cut_to_beats** — lays clips on the beat (or bar) grid with a pattern
  such as [4,4,2,2,1,1,1,1], cycling through the footage.
- **beat_effects** — punch / shake / zoom / opacity / flash expressions
  wired to the BEAT sliders; still editable in AE.
- **set_expression / add_solid / add_null / set_markers** — the plumbing,
  also usable directly.

A speed ramp into the drop is `speed_ramp` at `drop_s`. Analysis is pure
JS on PCM (biquad bass band, log-energy onsets, autocorrelation tempo with a
120 BPM prior, dynamic-programming beat tracking, adaptive peak picking);
on a synthetic 128 BPM track it lands within 1 BPM, 94% of beats within
35 ms, every kick found.

## Other MCP servers (Higgsfield and friends)

The panel runs Claude Code with only its own tools attached. To let the
same chat use another MCP server — Higgsfield for AI video, images,
background removal, upscaling — add that server to Claude Code once in a
terminal and sign in:

```
claude mcp add -s user --transport http higgsfield https://mcp.higgsfield.ai/mcp
claude            # then type /mcp, pick higgsfield, Authenticate, /exit
```

The `/mcp` path matters: the bare host answers 404, which `claude mcp list`
shows as "Failed — endpoint not found".

Then, in the panel, `connect higgsfield` (the `mcp_connect` tool). From the
next message every turn attaches that server: its tools are allowed, the
system prompt says so, and `download_file` turns the URLs it returns into
local files for `import_media` / `add_clip`. `extra_mcp` in `~/.claude-assistant.json` is the record (names
resolved against Claude Code's `~/.claude.json`, or inline `{type, url}`).

"Attached" is not "connected". Every turn the CLI reports each server's
status (`connected`, `needs-auth`, `failed`, `pending`, `disabled`) and
the tool names it actually got; the panel records that
(`mcp-observed.json` in its data folder), shows a NOTE card when a server
is not usable ("higgsfield needs sign-in: in Terminal run claude, type
/mcp, pick higgsfield, Authenticate…"), and `mcp_status` returns the real
status, the real `mcp__higgsfield__*` names and the fix. The next turn's
prompt carries the names, so Claude calls real tools instead of guessing.
A headless CLI cannot do the OAuth dance itself: `needs-auth` (or a
`pending` that repeats) always means "sign in once in a terminal".
`mcp_status` and `mcp_connect` also probe a server's URL when it is not
usable and say whether an MCP endpoint is there at all (401 asking for
OAuth = live; 404 = wrong path, with the corrected URL).

Fallback if the headless run cannot reuse the terminal sign-in:
`connect higgsfield using claude code's connections`
(`mcp_connect` with `use_claude_code_connections:true`, stored as
`extra_mcp_mode: "inherit"`). The CLI then loads everything Claude Code
has — including a claude.ai connector named higgsfield — without
`--strict-mcp-config`; slower to start, but it uses a sign-in that already
works. `mcp_status` reports the mode.
