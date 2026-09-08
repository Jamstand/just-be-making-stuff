---
name: verify
description: How to verify the After Effects Claude Assistant panel — what can be observed headlessly vs only inside real AE.
---

# Verifying the AE panel

The surface is a CEP panel inside After Effects (Window > Extensions). It
cannot run in a Linux container. Two layers of verification exist:

## 1. Headless wiring drive (works anywhere with node)

```
node after-effects-claude/verify-drive.js
```

Sends REAL Streamable-HTTP MCP requests (what the claude CLI sends for a
`{type:"http"}` server) to the REAL in-process server in `html/panel.js`
(tool registry, approvals, history), which dispatches into the REAL
`host/ae-tools.jsx` running in a `vm`. There is no bridge.js / child node
any more — live launch #4 proved the Mac has no node binary to spawn. Only CEP's
`CSInterface`, Chromium's `Image`/canvas, and AE's `app` object are shimmed.
It prints every JSON-RPC reply; approvals are answered through
`window.assistant.approval()` — the same API `app.js` uses.

Proves: MCP framing (id 0 answered, notifications silent), tool listing,
read-only-vs-write approval gating incl. decline-with-guidance and
session-wide "always", image side channel -> MCP image block, host error
shapes (never the opaque "EvalScript error."), token gating.

Does NOT prove: CEP loads the manifest, ExtendScript engine semantics, AE's
actual DOM behaviour (inPoint/outPoint are COMP time, etc.).

## 1b. Headless UI drive (real Chromium, real HTML/CSS/app.js)

```
cd after-effects-claude && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm i playwright   # once
node verify-ui.js
```

Loads the actual `html/index.html` from `file://` (CEP's origin scheme) in
/opt/pw-browsers/chromium with panel.js replaced per case (plain Chromium
has no `require`). Cases: normal; localStorage denied (a CEP file://
trait); panel.js dying at top level; config() rejecting; and case E,
which loads the REAL panel.js (require stubbed to throw) — this is the
one that catches page-scope collisions between panel.js and app.js
(live launch #3: `Identifier 'busy' has already been declared`).
Never verify the UI with panel.js replaced only. Each must end in
either filled dropdowns + the Connected card, or a visible red card — never
silence. Screenshots land next to the script.

## 1c. Full-fidelity UI drive: the REAL panel in Electron (closest to CEP)

```
cd after-effects-claude && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm i playwright electron   # once
xvfb-run -a node verify-electron/drive.js
```

Electron with nodeIntegration is a near-twin of CEP's mixed context: the
REAL panel.js (with Node), REAL app.js, REAL DOM. `preload.js` shims
`window.__adobe_cep__`; `host-sim.js` runs the REAL host/ae-tools.jsx in a
vm in a FORKED process (vm inside a renderer crashes Blink:
"ToExecutionContext(context)"); `fakebin/claude` is a stand-in CLI that
speaks stream-json and real MCP-over-HTTP back to the panel. Drives:
connect -> send -> tool lines -> approval card -> click -> results ->
decline via Esc -> history -> new chat -> empty send -> 420/320px layout.
Screenshots land next to the script. This is the harness that would have
caught every live-launch bug so far; run it before shipping panel changes.

## 2. On the Mac (the only real surface)

```
./after-effects-claude/install-ae-mac.sh
```
then AE > Settings > Scripting & Expressions > "Allow Scripts to Write Files
and Access Network", ⌘Q and relaunch AE, Window > Extensions > Claude
Assistant. If Extensions is greyed out, CEP rejected the manifest:

```
defaults write com.adobe.CSXS.12 LogLevel 6 && killall cfprefsd
# relaunch AE, then:
grep -i -E "jamstand|claude|extension" ~/Library/Logs/CSXS/CEP12-AEFT.log | tail -40
```

## Gotchas learned

- MCP is served in-process over HTTP with a bearer token; wrong token ->
  401, GET -> 405 (no server-push stream), notifications -> 202.
- CEP caches extension JS; a "fixed" panel that still misbehaves is often
  stale. The installer now purges ~/Library/Caches/CSXS/cep_cache and the
  manifest version was bumped; bump it again on structural changes.
- CEP runs all panel <script>s in ONE shared scope — panel.js is wrapped
  in an IIFE for that reason; keep any new panel-side file wrapped too.
- Errors thrown by file:// scripts may reach window.onerror masked as
  "Script error." — the on-screen card still proves *something* threw;
  the DevTools console (http://localhost:8092 via .debug) has the detail.
- Clipboard: a CEP panel on macOS never sees ⌘C/⌘V unless it calls
  registerKeyEventsInterest (panel.js does, for A/C/V/X + meta/ctrl), and
  app.js handles the keys itself through assistant.clipboard (pbcopy /
  pbpaste via child_process; xclip on Linux — verify-electron/fakebin/xclip
  is a file-backed stand-in the drive reads back). Every card has a Copy
  button and the top bar a Copy chat button, so copying never depends on
  the keyboard route. Drive steps 3b–3f cover button, ⌘C on a selection,
  Copy chat, ⌘V into the input, and the browser fallback when the native
  tool is missing.
- Tracking bridge: mocha_track shells out to Mocha Pro's own python3
  (host/mocha_job.py; discovery in tracklib.js, override with mocha_python
  in ~/.claude-assistant.json). The drive's HOME config points at
  verify-electron/fakebin/mocha-python3, a node stand-in that writes a real
  AE keyframe .txt + a fake .shape4ae and prints CA_RESULT. Step 8 sends
  "track the car": mocha_status → import → comp → add_clip → mocha_track,
  approves once with "Yes for this session", and reads the final JSON back
  (corner pin keys per corner, masks_added via the fake xclip clipboard +
  fake "Paste Mocha mask" menu command in host-sim.js). Unit coverage:
  test_ae_tracklib.js (parser, job runner, fal client) and the tracking
  block in test_ae_plugin.js (layer_info, apply_keyframe_data,
  paste_mocha_mask, import_and_matte).
- mocha_status runs license_check per Qt variant; the fake Mocha python
  fails the probe track for qt_app "widgets" (mimicking the live "Can't
  obtain rendering context") and passes for "gui", so the drive exercises
  the fallback ladder and the saved mocha_qt config.
- grab_frame: saveFrameToPng creates the file before it finishes writing
  it (live: every capture had a black band at a different height). The
  host tool now waits until the size is stable AND the last 8 bytes start
  with IEND; the fake AE in test_ae_plugin.js reproduces the race (partial
  write, IEND appended on the 3rd $.sleep) and the never-finishes error.
- NEVER poll with $.sleep inside a host tool. ExtendScript runs on AE's
  main thread; a sleep loop stalls saveFrameToPng's own writer and queues
  every later evalScript behind it (live: "every script call times out").
  grab_frame / grab_source_frame return immediately; tracklib.waitForPng
  waits on the file from the panel side (size stable + IEND).
- grab_source_frame renders one layer's source alone in a throwaway
  __ClaudeGrab__ comp (removed by remove_temp_comp in a finally) — use it
  for tracking regions; grab_frame renders the whole stack.
- Mask export: verify-electron/fakebin/mocha-python3 writes the real
  *.shape4ae layout (mocha shape block, Bezier(Point(x,y,...)) rows) so the
  drive covers tracklib.parseMochaShapeText → apply_mask_keyframes; the
  drive prints the mask result (keys, vertices, first/last key) and
  mask_report. A track_report/mask_report warning must only fire when
  usable_until_frame < last_frame of the export, not when the fake exports
  fewer frames than requested (that is its own "Export covers" warning).
- Music: test_ae_audio.js synthesises a 128 BPM track (kicks, accents,
  quiet intro) and checks tempo, beats, downbeats, bass hits, the drop and
  the cut planner; decode goes through a recorded runner (afconvert args,
  cache hit, -c fallback). Drive step 9 ("make a beat edit"): the fake CLI
  writes a 120 BPM WAV into the harness HOME's ~/Music/Claude Assistant,
  then music_list → analyze_music → add_music → beat_control →
  cut_to_beats → beat_effects punch + flash run for real against host-sim
  (markerProperty, Slider Control effects, expressions, addNull/addSolid
  are faked there). Static values in the fake DOM live in `.value`
  (`_value`), keys in `_keys`.
- Extra MCP servers: drive step 10 writes a fake ~/.claude.json with
  "higgsfield" and extra_mcp ["higgsfield","ghost"] into the harness HOME,
  sends a turn, and reads ~/last-turn.json (the fake CLI dumps argv,
  mcp.json and the system prompt there, since turn dirs are transient):
  expect servers [higgsfield, ae], allowedTools mcp__ae__* mcp__higgsfield__*,
  and the prompt naming both the attached server and the missing "ghost".
  Step 10b: the fake CLI's init event lists every server in mcp.json as
  needs-auth (no tools) until ~/.fake-mcp-authed exists in the harness
  HOME, then connected with mcp__<name>__generate_video / jobs_wait; the
  "is higgsfield working" prompt makes it call mcp_status. Expect a NOTE
  card naming the sign-in step, mcp_status usable:false + problem text,
  then after the marker: usable:true with the real names, the next
  prompt's "higgsfield tools seen last turn: …" line, and
  <USER_DATA>/mcp-observed.json. Use fullCards() (not cards(), which
  truncates at 120 chars) to parse JSON out of a card. The fake
  ~/.claude.json points higgsfield at a local stand-in server drive.js
  starts (bare URL 404s, /mcp answers 401 + Bearer) so mcp_status's URL
  probe stays offline: expect endpoint_http 404 and a "try …/mcp" problem
  while not usable, and no probe once connected. Step 10c sets
  extra_mcp_mode "inherit": argv without --strict-mcp-config, mcp.json
  holding only ae, allowedTools still mcp__higgsfield__* (and ghost).
- Claude Music (second extension in the same bundle, html/music.html sets
  window.CLAUDE_PANEL = "music"): drive step 11 launches a SECOND Electron
  instance with AE_PAGE=music.html (verify-electron/main.js honours it),
  sends "hello" (approve the create_comp card with #ap-run or it never
  reaches Ready), then reads ~/last-turn.json for the bridge url + token
  and POSTs tools/list and a tools/call of mocha_track straight to the
  panel's MCP server. Expect title "Claude Music", the system prompt
  starting "You are Claude Music", 28 tools with the music set present,
  mocha_track / ai_segment / apply_track_file / track_history absent and
  the basics (grab_frame, grab_source_frame, add_mask, run_extendscript)
  kept, the hidden call answering isError with a pointer to Claude
  Assistant, both chats/ and chats-music/ under the harness USER_DATA, and
  music.html differing from index.html in 3 lines only (title,
  placeholder, the CLAUDE_PANEL flag — the startup error painter lives in
  the shared startup.js). The MCP POST helper is verify-electron/mcp-rpc.js,
  shared by fakebin/claude and drive.js.
