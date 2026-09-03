# Claude Assistant for DaVinci Resolve — agent handoff notes

Read this before touching the code. It encodes lessons learned the hard way,
several from live failures inside real Resolve on Windows.

## What this is

A chat panel that runs inside DaVinci Resolve (Workspace > Scripts) and lets
Claude drive Resolve through 70 tools. Two backends:

- **claude-code** (default): shells out to the Claude Code CLI on the user's
  Pro/Max subscription. No API key. The CLI gets the Resolve tools via MCP.
- **api**: direct Messages API calls with an Anthropic key.

Everything ships as ONE file — `Claude Assistant.py` — so installs are a single
copy into Resolve's `Fusion/Scripts/Utility` folder. Standard library only, no
pip packages, Python 3.6+ compatible. Keep it that way.

## Architecture (claude-code backend)

```
Resolve process                                external processes
┌─────────────────────────────┐
│ ChatWindow (Fusion UIManager)│
│ run_agent_turn_claude_code ──┼──spawns──> claude CLI (-p, stream-json)
│ ToolBridge                   │                 │ spawns MCP server:
│  TCP 127.0.0.1:<random>      │<──JSON-line───  │  python <this file> --mcp-bridge
│  token-gated, lock-serialised│    socket       │  OR node bridge.js (fallback)
│ execute_tool → 70 tool fns   │
└─────────────────────────────┘
```

The MCP server is this same file re-run with `--mcp-bridge` (or the embedded
`NODE_BRIDGE_JS` when no real Python exists). It forwards tools/list and
tools/call over the loopback socket to the process that owns `resolve`.

## Run the tests

```
python3 test_claude_assistant.py     # ~380 checks, mock Resolve, no deps
```

Every change must keep this green. The fakes mirror documented Resolve API
behaviour; extend them when adding tools.

## Traps that already bit us — do not rediscover these

1. **Resolve doesn't set `__file__`.** Scripts run via exec without it. Use
   `PLUGIN_PATH` (resolved from the code object's `co_filename`).
2. **`hasattr()` lies on Resolve objects.** The Python bridge fabricates a
   callable for ANY attribute name. Feature-detect with `_supports(obj, name)`
   (dir() membership) — never hasattr.
3. **Windows: `claude` is a .cmd shim; cmd.exe re-parses every argument.**
   `>` `<` `&` in an argument get interpreted as shell operators. Never put the
   prompt, system prompt, or JSON on the command line: prompt goes via stdin,
   system prompt via `--append-system-prompt-file`, MCP config via file path.
4. **Windows: `python3.exe` under `Microsoft\WindowsApps` is a fake** (Store
   advert stub). `find_python_binary` validates candidates by actually running
   `--version`; `find_node_binary` + `NODE_BRIDGE_JS` are the fallback when no
   real Python exists (Node always exists where the claude CLI works).
5. **`ANTHROPIC_API_KEY` silently overrides subscription auth in `-p` mode.**
   `claude_code_env()` strips it (and ANTHROPIC_AUTH_TOKEN). Never pass
   `--bare` (it disables OAuth entirely).
6. **`claude auth status` only proves credentials exist, not that they work.**
   An expired refresh token still reports loggedIn: true while every request
   401s.
7. **MCP protocol gotchas** (both bridges handle these; keep parity if editing
   either): id 0 is a request, `params` may be entirely absent, notifications
   must get NO reply, unknown protocolVersion → fall back to a real dated one,
   one compact JSON object per line + flush, nothing else on stdout ever.
8. **Images:** tools return pictures via `_image_b64`/`_image_media_type` (one)
   or `_images` (list) keys; `execute_tool` strips them into a side channel
   carried as MCP image blocks / API tool_result image blocks. Verified: the
   CLI forwards them to the model's vision, multi-image works, and they bypass
   the 25k-token MCP text cap.
9. **Frame grabs need the Color page** and a Gallery album; exports go to a
   home-based dir (macOS Resolve can't write /var/folders); a .drx sidecar is
   always written; GrabStill is intermittently falsy (retry); filenames are
   unpredictable (glob by extension); sniff media type from magic bytes.
10. **Resolve API hard walls** (documented, not bugs): no trim/move/razor in
    place, no colour wheels (SetCDL is write-only), no node creation, no audio
    mixing, titles can't pick a track. The system prompt tells Claude to say so.
    Workarounds that exist: interchange round-trip (EDL/XML out → transform →
    import as NEW timeline), delete+re-place, CDL, .drx looks library.
11. **resolve.* enum constants** must be validated as ints (`_resolve_const`) —
    a missing constant comes back as a fabricated callable, not None.
12. **UIManager windows have NO drag-and-drop events.** The official event list
    (Window: Close, Show, ... KeyRelease, FocusIn/Out, ContextMenu, Enter,
    Leave) contains no Drop/DragEnter; zero scripts in the whole Reactor corpus
    subscribe to them. Do not wire `ev["mimeData"]` handlers — they will never
    fire. File drag-and-drop = the watched "Claude Drop" folder (poll from the
    UI timer, two-poll size stability). The only real Resolve drop hook is a
    `Config:/DragDrop/*.fu` `Drag_Drop` action targeting the Fusion-page Nodes
    view — wrong surface for media, needs a restart; don't bother.
    Related: the transcript TextEdit is a QTextEdit rendering Qt's "Supported
    HTML Subset" ONLY — no border-radius, CSS padding works on table cells
    only, and only longhand margin/padding-* with px units are documented
    (shorthands like `margin:2px 0` work in current Qt but are off-contract).
    Cards are built as tables; code goes through `_code_card`, never through
    the markdown fence parser (a ``` inside Python code would break out).
13. **Media pool facts (verified):** `MoveClips([clips], folder)` → Bool,
    Resolve ≥16; `ImportMedia` lands in the CURRENT bin, so `SetCurrentFolder`
    first; there is NO Smart Bin creation API — write comma-separated
    `SetMetadata("Keywords", ...)` (merge, never clobber user keywords) and let
    keyword-based UI Smart Bins collect the clips; "Date Created" comes back
    verbose ('Fri Mar 18 2016 16:47:44'), not ISO; `GetClipProperty("FPS")` may
    be numeric; "Type" values worth switching on: Video, Audio,
    "Video + Audio", Still.

### Color-suite live findings (Electron plugin, Mac)

- Gallery ExportStills accepts ONLY dpx/cin/tif/jpg/png/ppm/bmp/xpm — no
  EXR. TIFF comes out 16-bit uncompressed; a distinct-value census on real
  a6700 footage shows ~10-bit effective data (source-limited, pipeline OK).
- **AddVersion COPIES the current grade** (CDL slammed on node 1 survived
  into the "fresh" version byte-for-byte). A true pre-grade image requires
  a FRESH timeline item: grab_still pre_grade builds a throwaway timeline
  from the same media pool clip, parks the matching source frame, grabs,
  deletes it. It's a write → approval-gated via needsApproval's carve-out.
- SetCurrentTimecode is rejected while the Edit page is frontmost — park
  after OpenPage("color").
- SetCDL takes SPACE-SEPARATED STRINGS ("2.0 0.6 0.3"), not arrays.
- RCM v2 pipeline truth (live A/B x3): outputDRT DaVinci only rolls off
  highlights when timelineWorkingLuminanceMode gives it over-range room
  (HDR 1000). DRT + SDR 100 = identity mapping + uniform darkening — the
  HDR 1000 setting is LOAD-BEARING with an SDR output. Gallery grabs are
  display-referred under RCM (raw source code values only when unmanaged);
  "Input Color Space" is only writable under RCM. qc_scan/match_shot pick
  their measurement model from the live pipeline.
- SetLUT resolves NO path on the Mac install (absolute, relative, Resolve
  LUT dir, even Blackmagic-shipped LUTs; SetLUT(n,"") returns true) —
  design_look treats the .cube file as the deliverable with manual-load
  guidance. Fusion via the JS proxy: comp objects are fully populated
  (~90 methods) but TOOL handles come back HOLLOW (no SetInput/SetAttrs);
  AddFusionComp works, DeleteFusionCompByName always false. apply_vignette
  drives tools through comp.Execute(lua) — LIVE-VERIFIED working (57%
  corner-darkening pixel diff). Execute's return value never marshals
  (Parse: Unknown object type for key:result) even on success: swallow
  the throw, verify via FindTool + a grabbed frame. CAUTION: that parse
  error is AMBIGUOUS — for comp.Execute/Undo the call worked and only
  the return was lost, but graph.ResetNode throws it while doing
  NOTHING (pixels byte-identical, live-verified on six signatures).
  Never treat the error as success; verify by pixels/readback per call.
  ResetNode is inert on this install; per-node grade clearing is
  UI-only (node labels survive a hand reset, so clear-then-resave is
  the clean-scaffold path). Fusion state reads
  LAG behind Execute (tool count read in the same breath was stale by
  one) — always re-read in a separate call. fu.TIME_UNDEFINED is not
  valid in Execute scope; plain SetInput(name, value) works. Known-good
  recipe: SoftGlow before MediaOut, luminance-keyed (Threshold ~0.88,
  Gain ~0.26) = per-frame light-source glow with no mask or tracking.
- Node creation stays walled, but grade_template routes around it: a .drx
  sidecar carries the FULL node graph, and Timeline.ApplyGradeFromDRX
  stamps it onto clips (whole-grade REPLACEMENT — structure setup, not
  in-place edits). Save layouts built by hand once; stamp forever.
  LIVE-VERIFIED 1->4 nodes: on the Mac install the method lives on
  item.GetNodeGraph().ApplyGradeFromDRX(path, 0) — NOT the timeline
  object; ResetAllGrades() also works there, and GetNodeLabel reads.
  Node labels are READ-ONLY (SetNodeLabel undefined on both the node
  graph and the item, live-probed): hand-label once, save the template
  — labels travel in the .drx. The Fusion comp is believed NOT to
  travel in a .drx (Color-page grade only) — verify on first stamp.
- 1080p photographic PNG proxies exceed the 4.5MB attach cap: shrinkProxy
  (Electron nativeImage → 1280px JPEG-80) runs first; plain node falls
  back to raw PNG. compare_stills settles same-image questions by bytes +
  per-channel pixel stats.

### Assemble-an-edit live findings (Lambo session)

- TimelineItem.SetProperty WORKS for transform/crop/opacity: ZoomX/Y,
  RotationAngle, CropTop/Bottom (int px), Opacity; ZoomGang wants a
  BOOLEAN. No Speed property exists -> speed ramps unreachable.
  2.39:1 letterbox = CropTop/Bottom 138 on 1080. Punch-in pops =
  per-shot Zoom deltas. Flash frame = 3-frame insert + blown CDL
  (Slope 2.4 / Offset +0.3 / Sat 0.25) — renders near-white.
- SetCDL needs EXACTLY the 5 keys (NodeIndex, Slope, Offset, Power,
  Saturation); extra/renamed keys -> false.
- Fusion CONTRADICTION, unresolved: on C0698 (comp previously opened in
  the Fusion page by the user) Execute-Lua vignette/glow WORKED,
  pixel-verified. On fresh AddFusionComp comps in the Lambo session,
  handles were hollow, FindTool missed AddTool's own creations, and
  Execute side effects never landed. HYPOTHESIS (untested): a comp only
  becomes scriptable after the Fusion page has loaded it once
  (OpenPage("fusion") with the clip current). Probe before trusting
  either behaviour. DeleteFusionCompByName always false regardless.
- macOS Resolve can't export stills to /tmp — grab_still now defaults
  to ~/ClaudeAssistantStills on darwin. GrabStill errorCode 6 is
  intermittent; an immediate retry succeeds (retry loop already does).

### Self-update (Electron plugin)

main.js selfUpdate() runs at every launch: ff-only pull of
~/just-be-making-stuff on the pinned branch, contents-copy over the
install (never deletes — WorkflowIntegration.node isn't in the repo),
then app.relaunch() once (CLAUDE_ASSISTANT_RELAUNCHED guards loops).
All best-effort: wrong branch / offline / unwritable dir degrade to a
notice card, never a blocked launch. Opt out: touch .auto-update-off
in the plugin dir. Needs one-time chown of the install dir on macOS.

### Gemini integration facts (doc-verified 2026-08)

- generateContent on v1beta, model gemini-3.7-flash, key via
  x-goog-api-key header. Interactions API deliberately avoided
  (mid-breaking-change).
- Files resumable upload: start POST returns the session URL in the
  x-goog-upload-url RESPONSE HEADER; bytes go with command
  "upload, finalize". ASYMMETRY: upload response is {file:{...}} but
  the poll GET returns a BARE File — read both. States:
  PROCESSING/ACTIVE/FAILED; 2GB/file, 48h retention (we DELETE after).
- Bad key = 400 INVALID_ARGUMENT + details reason API_KEY_INVALID (NOT
  403; 403 = valid key, no permission). 429 RESOURCE_EXHAUSTED = quota.
- videoMetadata is deprecated with an undocumented replacement — not
  used. Low res via generationConfig.mediaResolution (bare enum).
- YouTube-URL-as-fileData is unverified for generateContent — not
  shipped; local files only (study_url downloads them anyway).

## Approvals (the design's 1d flow)

- Chokepoint: execute_tool → needs_approval(name) → request_approval blocks
  the CALLING thread (bridge conn / API worker — never the UI thread) on a
  threading.Event; the UI timer notices STATE["pending_approval"], shows the
  amber card + ApprovalRow buttons, and resolve_approval sets the decision.
- READONLY_TOOLS is an explicit frozenset — new tools default to "asks".
  Keep it updated when adding read-only tools, or Ask-mode gets annoying.
- needs_approval returns False when STATE["permission_mode"] is unset: only
  the panel initialises approvals, so tests/drive.py/headless flows never
  block. The drop-folder watcher calls execute_tool(bypass_approval=True) —
  it runs ON the UI thread, where waiting would deadlock.
- The input box doubles as the keyboard path (on_send intercepts while a
  request is pending): ""/1/y = run, 2 = session-wide consent, 3/n = no,
  anything else = decline + guidance handed to the model.
- Timeout APPROVAL_TIMEOUT_S (120s) declines with an explanation — an MCP
  call must never hang the bridge forever. approval_ui_ready gates the whole
  flow off when the timer fallback is in play (sync mode would deadlock).

## Conventions

- Tool = `@tool(name, description, params, required)` on `t_*(app, ...)`;
  raise `ResolveError` with a plain-English, actionable message on failure.
- Version-gate risky methods with `_supports()` and refuse with the Resolve
  version requirement in the message.
- Destructive tools say so in their description so the model confirms first.
- After changing tools, update: fakes + checks in the test file, README tables,
  and the tool-count strings in README.

## Current status (last updated by the original build session)

- 62 of 70 tools live-verified against the real claude CLI with a mocked Resolve
  (markers created end-to-end, vision confirmed, multi-image confirmed, Node
  bridge path confirmed with Python disabled).
- Verified inside REAL Resolve (Windows 11): panel launch, UI, theming, effort
  dropdown, chat, auth-expiry diagnosis, Store-stub diagnosis. NOT yet
  confirmed in real Resolve: bridge connection after the Node fallback fix,
  `run_diagnostics` output, any actual tool execution. That confirmation is
  the next milestone — ask the user for the diagnostics report.
- Known cosmetic issue: cross-model session resume can log a benign notice.
- Newest feature: auto-sort (auto_sort_media / import_and_sort tools, WatchDrop
  checkbox + "Claude Drop" watched folder). Mock-tested only; API signatures
  research-verified against three README mirrors (see traps 12–13).
- Themes: THEMES registry + Style dropdown. Renderers read the active theme
  via _theme(); ChatWindow keeps msg_log of raw (kind, text) so switching
  re-renders the whole transcript. The user has a claude.ai/design project
  ("Resolve Assistant Options") with mockup variants meant to become themes —
  it needs to be sent into a session ("Send to Claude Code Web" from Claude
  Design) because DesignSync auth is interactive-only here. Map its variants
  onto THEMES entries when it arrives.
- Workflow Integration (research-verified, three README mirrors + shipped
  plugins): a BARE .py in
  `%PROGRAMDATA%\Blackmagic Design\DaVinci Resolve\Support\Workflow
  Integration Plugins\` (mac: `/Library/Application Support/Blackmagic
  Design/DaVinci Resolve/Workflow Integration Plugins/`, no `Support`)
  appears under Workspace > Workflow Integrations after a RESTART (startup
  scan only). Same in-process env as Workspace > Scripts plus a bonus
  `project` global. STUDIO-ONLY — and free 19.1+ blocks fusion.UIManager
  everywhere, so this panel is effectively Studio-targeted on current
  versions. Install-WorkflowIntegration.ps1 deploys both launch points.
  The Electron plugin now EXISTS: workflow-plugin/ (28 JS tools incl.
  run_javascript and the colour suite, real approval card, reused bridge.js; headless-tested,
  NOT yet run in real Resolve). Verified platform facts: Resolve Studio
  bundles its own
  Electron; a plugin = folder + manifest.xml + WorkflowIntegration.node
  COPIED FROM THE USER'S INSTALL (Developer/Workflow
  Integrations/Examples/SamplePlugin/ — don't commit it, gray-area
  redistribution); precedent repo olegkupshukov/claude-resolve spawns the
  claude CLI from the plugin's main process. Gotchas: orphaned electron.exe
  can lock the .node file on Windows; call SetAPITimeout() after init.
- Higgsfield tools (endpoint shapes verbatim from Higgsfield's OFFICIAL SDKs,
  higgsfield-client/higgsfield-js on GitHub — do not trust blog posts): base
  platform.higgsfield.ai; auth header `Authorization: Key ID:SECRET`; v1
  bodies wrapped in {"params": {...}}; POST /v1/text2image/soul,
  /v1/image2video/dop (dop-lite/turbo/standard, motions from GET /v1/motions),
  /files/generate-upload-url + PUT for inputs; async job_sets polled at GET
  /v1/job-sets/<id>, results in jobs[].results.raw.url; 401=bad key,
  403=OUT OF CREDITS (not authz), 422=validation. Tools submit + wait briefly,
  then hand back job_set_id for higgsfield_check_job (MCP calls must not block
  for minutes). Keys from cloud.higgsfield.ai, stored as cfg higgsfield_key.
  Higgsfield's own Resolve plugin is a separate Workflow Integration that
  imports into the media pool directly — no stable output folder to watch.
- Chat history: autosaves to <config dir>/chats/<uuid>.json after every
  completed turn (images stripped from the stored API messages). History
  button opens a Tree browser (ComboBox fallback). Resume semantics: the CLI
  keys sessions to its cwd, so turn spawns pin cwd to the config dir; a dead
  --resume self-heals (clears cc_session_id, notice to re-send) and the next
  turn injects build_recap(msg_log) — STATE["chat_recap"], cleared on the
  first successful result — so reopened chats continue even without the
  server-side session.

## User setup (Windows box this is deployed on)

- Repo: `C:\Users\jameg\just-be-making-stuff`, branch
  `claude/davinci-resolve-claude-plugin-bw69a6`.
- Deploy = copy `Claude Assistant.py` to
  `%APPDATA%\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Utility`,
  then close and reopen the panel (running panels keep old code).
- Machine has NO real Python (Store stub only) → bridge runs on Node.
- Claude Code CLI installed via npm, Max subscription, first-party auth.

## Clipboard (both panels)

Users could not copy Claude's replies out of the After Effects panel: CEP on
macOS routes ⌘C/⌘V to the host's Edit menu, and a bare Electron window has
no Edit menu either. Fix lives in the shared renderer (app.js): a Copy
button on every card and code block, a Copy chat button in the top bar, and
⌘/Ctrl+C/X/V/A handled by hand through `assistant.clipboard` — Electron's
clipboard over IPC here (main.js `clipboard` handler, preload exposes
write/read), pbcopy/pbpaste via child_process in the AE panel, which also
registers key-event interest with CEP so the keys reach the page at all.
Falls back to execCommand("copy") when no native route exists. The Copy
button copies the model's raw markdown (fences intact), not rendered text.

## AE tracking bridge (research-backed, not yet live-verified)

Mocha Pro's Python API is real and documented (2026.5 guide): Clip(path,
name) → Project(clip) → add_layer → add_xspline_contour → track_layers(
start_index, stop_index, layers) → exporters via
Abstract{Shape,Tracking}DataExporter.registered_exporters()[internal_name]
.do_export(...) returning {name: QByteArray} that the SCRIPT must write.
Internal names: after_effects_mask (*.shape4ae), after_effects_corner_pin,
after_effects_corner_pin_with_motion_blur, after_effects_cc_power_pin,
after_effects_transform. External scripts need a QCoreApplication and must
run under Mocha's OWN python3 (standalone: /Applications/Mocha Pro
<ver>.app/Contents/MacOS/python3; plug-in: /Library/Application Support/
Adobe/Common/Plug-ins/7.0/MediaCore/BorisFX/MochaPro<ver>/Resources/mochaui/
<app>.app/Contents/MacOS/python3). Docs say the plug-in build blocks
external RENDERING without a standalone license; tracking/export gating is
unstated → mocha_status probes it. No headless flag, no CLI tracker; the
Mocha project inside an AE effect is unreachable from script; the effect's
buttons are NO_VALUE properties ExtendScript cannot press. Shape data
enters AE only via clipboard + Edit → Paste Mocha mask (id 5007 in AE 2025,
looked up by name first). Corner Pin / Transform exports are "Adobe After
Effects 8.0 Keyframe Data" text — tracklib.parseAeKeyframeText + host
apply_keyframe_data (frame f → layer start + f/fps × stretch). fal.ai SAM
video endpoints (fal-ai/sam-3/video, sam-3-1, -rle variants) document only
a `video` output (masked MP4) + optional bbox zip; no per-frame polygons;
inputs must be URLs (fal CDN upload: rest.alpha.fal.ai/storage/upload/
initiate → PUT, multipart above 90 MB); $0.005 per 16 frames (3.1: $0.01).
AE side: setTrackMatte(layer, TrackMatteType.LUMA) is AE 23+; Property
times are COMPOSITION seconds. LIVE (josh's Mac, 2026-09): Mocha Pro 2026.5
plug-in bundle python3 3.11.12 loads mocha.* and lists exporters
(mocha_version attr is None), but Project(Clip(...)) dies at RLM checkout
"License Error: 2 ISV genarts" — empty ~/Library/Application Support/
GenArts/rlm and /Library/Application Support/BorisFX/rlm, no RLM env. The
plug-in's license lives inside AE's process only. mocha_status now does a
license_check job (tiny generated PNG → Project) so this shows before a
track; mocha_license in config → RLM_LICENSE + genarts_LICENSE env. FIX THAT WORKED: launch the Mocha GUI from the Mocha Pro effect
inside AE and sign in — RLM then caches rehost_mpp-multihost-so.lic +
.reprise under ~/Library/Application Support/GenArts/rlm/ and the headless
license_check passes (license: ok, ready: true). NEXT WALL (live): with
the guide's QCoreApplication, Project/Clip/add_layer all work but
track_layers raises "Can't obtain rendering context" — the tracker needs
an OpenGL context. FIX CONFIRMED LIVE (probe track 0.4s, ready: true): QApplication (QtWidgets) first, then
QGuiApplication, then QCoreApplication; mocha_status probe-tracks 3
generated noise frames per Qt variant (widgets → gui → widgets+offscreen
QPA → gui+offscreen → core) and stores the winner as mocha_qt.
FIRST REAL TRACK (C0768.MP4 59.94fps, 240 frames, ~real time): worked,
but (1) exporters' "Units Per Second" said 24 → panel now converts with
the source fps and sets proj.frame_rate; (2) proj.parameter([layer,
"Surface0X"]) → "No such parameter" → corner pin followed Mocha's default
surface; panel now retargets the exported quad to the requested surface
via per-frame homography (tracklib.retargetCornerPin); (3) "Paste Mocha
mask" did NOT produce a native mask — AE created/used the legacy "mocha
shape" effect (ISL MochaShapeImporter, CUSTOM_VALUE not scriptable); the
in-AE Claude parsed mask.shape4ae itself (64 pts/frame) — a real parser
+ native mask keyframes tool is the next build (format head requested
from josh); (4) the region left frame right at ~f15 and the tracker
re-locked on the road — tracklib.trackReport now flags usable range.
THEN: my "wait for IEND" $.sleep loop in grab_frame FROZE AE — ExtendScript
blocks the main thread that finishes the PNG, so the file stalls half-
written and every later evalScript queues (timeouts everywhere). Rule:
host tools return immediately; the panel (Node) waits on files
(tracklib.waitForPng). grab_source_frame added: temp __ClaudeGrab__ comp
with just the layer's source → PNG in SOURCE pixels, comp removed after.
