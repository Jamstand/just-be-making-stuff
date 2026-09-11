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
- Slash menu (drive step 6b, on the main panel at 760×560): typing "/"
  opens #slashmenu with /study,/train,/style,/help,/tools,/mcp,/new,
  /history,/copy and the first row .on; ArrowDown ×2 → /style; Esc
  closes and keeps the text; "/foo" + Enter is echoed as YOU, answered
  with "No command called /foo", and the fake claude's ~/last-turn.json
  mtime must NOT change (no CLI turn — Claude Code would answer "Unknown
  command"); "/he" + Tab runs /help locally ("Type / to pick a
  command"). Screenshot shot-6b-slash-menu. The list comes from
  slash.js (commandsFor(PANEL) via config(); the music panel hides
  study/train); slashRoute() there is the chokepoint (expand / unknown /
  text-with-path-prefix).
- /train frames come from ffmpeg OR from After Effects itself. The AE
  route (host study_open / study_sample / study_close, stylelib
  sampleFramesViaAe, pnglib) imports the video into a __ClaudeStudy__
  folder, renders a comp sized to the source shrunk by a whole factor
  (long edge ~240: 1920x1080 -> 240x135) with saveFrameToPng, decodes the
  PNGs in Node and box-averages them to 64x36 — the same picture ffmpeg's
  scale=64:36 produces, verified byte-for-byte against real ffmpeg in
  scratchpad. pnglib is checked against ffmpeg-written PNGs of every
  colour type (rgb8/rgba8/rgb16/gray8/palette) in the unit test when a
  real ffmpeg is present. host-sim now writes REAL PNGs (verify-electron/
  pngwrite.js, shared with the unit test) from the fake video's shot plan,
  so the decode path is exercised rather than stubbed.
- /train (drive step 6c): "/train <tiktok link> <instagram link>" runs
  the fake claude's study branch through the REAL tool chain: study_url
  (fakebin/yt-dlp writes a JSON "video" with a 3-shot plan) →
  study_edit (fakebin/ffmpeg answers the -i probe on stderr and emits
  rgb24 frames for -f rawvideo) → watch_video (no Gemini key → isError,
  told once) → style_profile. Expect ~/ClaudeAssistantStyle/
  car-edits.json with 2 complete edits of 2 cuts / 3 shots / 12 s,
  aggregate cuts_per_minute 10 and median shot 4 s, two files in
  ~/ClaudeAssistantStudy, one "Gemini pass skipped" card and a final
  "Studied —" card with "edits":2, and every entry sampled_with "ffmpeg"
  with NO approval card (study_edit declares readonlyWhen: ffmpeg present
  and via !== "after-effects", so it asks only when it has to touch the
  project).
- The ffmpeg-free route (drive step 6d): clicks #newchat first, because
  step 2 clicked "yes for this session" and newChat() now takes that
  back (assert the note says "approved one at a time again"). Then a
  plain message "study the downloaded file with after effects: <path>"
  makes the fake claude call study_edit with via "after-effects"; expect
  an approval card naming study_edit and after-effects, then after
  #ap-run an ae-route.json whose cuts, shot lengths and cast match the
  ffmpeg entry, no __ClaudeStudy__ folder or __ClaudeStudyFrame__ comp
  left in the project, and media_tools reporting can_download /
  can_read_frames. Unit tests: test_ae_style.js
  (measurement, profile, fakes, Gemini wire, macro/routing, the AE
  sampler over a stub host including a frame AE finishes writing late,
  downloadTo's redirect following, checksum verification, the panel's own
  bin folder winning over PATH, yt-dlp staleness; when a real
  ffmpeg exists — /usr/bin/ffmpeg here — it also encodes a three-shot
  mp4 with lavfi and checks probe + study, then truncates it at 55% and
  expects the coverage refusal). The fake ffmpeg honours a
  truncate_at field in the fake video's JSON (frames stop early, a
  "partial file" line on stderr, exit 0 — the real behaviour); the fake
  yt-dlp prints 2,000 progress lines so an undrained stdout would stall.
- Claude Music (second extension in the same bundle, html/music.html sets
  window.CLAUDE_PANEL = "music"): drive step 11 launches a SECOND Electron
  instance with AE_PAGE=music.html (verify-electron/main.js honours it),
  sends "hello" (approve the create_comp card with #ap-run or it never
  reaches Ready), then reads ~/last-turn.json for the bridge url + token
  and POSTs tools/list and a tools/call of mocha_track straight to the
  panel's MCP server. Expect title "Claude Music", the system prompt
  starting "You are Claude Music", 31 tools with the music set present,
  mocha_track / ai_segment / apply_track_file / track_history absent and
  the basics (grab_frame, grab_source_frame, add_mask, run_extendscript)
  kept, the hidden call answering isError with a pointer to Claude
  Assistant, both chats/ and chats-music/ under the harness USER_DATA.
  music.html is its own page (the designed UI, see below) that shares
  startup.js, panel.js and app.js with index.html; the drift-line count
  step 11 prints is informational. The MCP POST helper is
  verify-electron/mcp-rpc.js, shared by fakebin/claude and drive.js.
- Claude Music UI (drive step 12, a THIRD Electron instance with
  AE_PAGE=music.html at 420×680): makes comp "Ident" plus two fake clips
  (fake-logo.mp4 above fake-bg.mp4 — add_clip appends, and host-sim's
  moveToEnd now really moves to the end, so the sim orders layers like
  AE: BEAT on top, the music layer at the BOTTOM) through
  assistant.callTool, then clicks library → #tracklist2 .track → Listen →
  Apply → wires Kick → fake-logo with a FLASH solid and Bass → fake-bg
  with a punch → Write expressions (expect the punch recorded on
  fake-bg.mp4 by NAME although the solid shifted its index, layers
  BEAT, FLASH (Beat), fake-logo, fake-bg, beat-test.wav, the selects
  still naming their layers, Punch|Smooth|Smooth carrying .on) → widens
  to 940 (dateline flex, #stage 3 columns) → a "hello" turn (#ap-run) →
  Undo all → ≡ settings. Expect 119.7
  BPM, 6 bars, 110 wave bars, a comp veil, 6 bar markers (markers_written
  counts the grid only; the fake track opens at full energy so there is no
  ♪ DROP marker), 3 wiring rows,
  written ["fake-logo.mp4 › Scale, driven by Kick, punchy"], a system
  prompt carrying "Panel state right now" with track=beat-test and
  "applied: music layer", stays_on_applied_comp_after_turn true (the fake
  hello turn makes and activates "Hello Comp"; the panel must stay on
  Ident until undo), then view "results" with layers fake-logo.mp4,
  fake-bg.mp4 and "1 expression cleared" in the note.
  Step 12 THROWS (expect()) on the key facts rather than only printing
  them: .seg-opt.on carries the selected segment (CEP 12 has no :has()),
  progressEvents ≥ 3 after Listen (the step deletes the audio cache first
  so decoding → listening → done really runs), expressions recorded by
  layer NAME, wiring selects unclipped at 940 px, after undo still on
  Ident with only the clips, settings → back lands on results (a real
  comparison, not a truthy check). Step 12b places beat-test through
  add_music at start 1.5 with in_s 3 (trimmed) as if the user had,
  re-activates Ident through run_extendscript (the fake hello turn left
  Hello Comp active), picks it from "In this comp" (range + offset
  disabled, the placed note shown), and expects one "As it sits on your
  timeline" fit with in_s=3 offset_s=-1.5 from_s=1.5 until_s=10.5, apply
  adding no second audio layer (applied.layerName null, placed true,
  until_s 9 = song seconds on the timeline), every ♪ marker inside
  [1.5, 10.5] comp time (read back through run_extendscript on
  comp.markerProperty), the applied axis in comp time ("0:02" … "0:11",
  fmt rounds), and undo leaving fake-logo, fake-bg, beat-test.wav. Step
  12c then applies the SAME song from the library while the user's copy
  is still there: the panel's copy lands at the bottom
  (beat-test.wav@-1.5 then beat-test.wav@0) and undo removes only the
  @0 one — remove_layers takes {name, index, start_s} for the music
  layer and a bare name (topmost) for BEAT/FLASH. Screenshots shot-12a-track,
  shot-12b-results-narrow, shot-12c-applied-wide. Gotchas: sendUI is
  synchronous, so a throw inside a UI handler rejects the tool call in
  flight (that is how a checklist TypeError once surfaced as "I couldn't
  listen"). A Playwright click on .chooser-lib fails at ≥820 px because
  the library column replaces it; use the narrow viewport or
  #tracklist .track. The harness's Electron is far newer than CEP 12's
  Chromium 99: it will happily render :has() and color-mix(), so grep
  html/*.css for both after touching styles — neither may appear.
