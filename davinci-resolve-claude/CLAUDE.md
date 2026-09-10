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

- Colour suite v2 (built after the Colourlab comparison; headless-verified
  only, no live Resolve run yet). Measurement: tiffStats now returns
  per-channel percentiles (P_LEVELS) and one joint pixel pass (jointStats:
  HSV saturation, chroma p90, luma median, greyness-weighted neutral means,
  12 chroma-weighted hue sectors + a 72-bin count hue histogram with
  per-bin mean colour, YCbCr skin cluster with its vectorscope angle vs
  the 123° skin line); measureBuffer adds DI-log samples (sampleDi, ~40k px).
  Matching: fitCdl = per-channel least squares of (slope*x+offset)^power
  over p05..p95 in DI-log (power grid 0.5-2 with a pull toward 1);
  refineCdl = coordinate descent of all 10 CDL numbers against the goal
  curves + reference chroma p90 through simStats (the node simulated on
  the grab's own pixels — the only way to see how saturation mixes
  channels); runCdlLoop = write, regrab, shift the goal by the residual,
  refit, with a regression guard that restores the best round. Lessons
  paid for: HSV mean saturation is a bad yardstick (a cast inflates it),
  chroma p90 is not; saturation estimated before the cast is removed is
  wrong; a per-channel percentile fit rewards desaturation whenever it is
  imperfect (hence the chroma term); hard 30° hue sectors flip membership
  between frames (soft membership + CDF-matched hue mapping fixed it;
  count-weighted histogram because chroma weighting makes mass content-
  dependent); a hue recipe must be verified by simulation (refineHueRecipe:
  greedy add, 0.5% per step, 25% overall gain or nothing) or it invents
  shifts on near-identical frames; a hue pass is refused while the global
  gap is > 3% (a hue map over a level mismatch corrects the wrong thing).
  bench_match.js (ColorChecker scene, ΔE2000 over 24 patches, the tools'
  own pipeline model): -0.7 stop + warm 8.9 → 0.47; +0.5 stop + cool +
  contrast 6.0 → 0.68; tungsten-vs-daylight 9.3 → 0.68 (worst patch 6.1);
  3 stops under = refused; greens-only cast with match_hues alone 0.54/4.5
  → 0.16/1.7, after match_shot then match_hues 0.63/1.6; sat 0.7 + contrast
  1.2 + tungsten stays ~8 (order of operations: the CDL applies sat AFTER
  its RGB terms, the disturbance did the reverse — documented limit).
  auto_balance: warm cast 3.3/-3.8% → -0.2/0.1%, neutral frame left alone
  (gains 0.9995/1.0011, 0 stops); exposure only moves a luma median outside
  the 30-55% band. Skin: a 12° rotation reads as -8.9° off the line.
  bench_photos.js (OpenCV sample photos portrait/fruits/baboon at 256 px,
  ΔE2000 over EVERY pixel, mean / p95): exposure+WB 7.9 → 0.18, 6.5 → 0.40,
  9.1 → 0.22; over+cool+flat 5.7 → 0.38 / 0.51 / 0.42; tungsten 8.8 → 0.77,
  5.2 → 0.36, 9.6 → 0.75 (p95 ≤ 2.4) — invisible. The verified hue pass
  correctly does nothing on those. sat 0.7 + contrast + tungsten stays
  3.6-5.7 (visible). DIFFERENT FRAMING (left 60% vs right 60% crop, same
  shift) is the real weakness of statistics matching: 8.4 → 6.8, 6.0 →
  10.5 (worse), 9.1 → 4.8; an offsets-only neutral-pixel/median variant
  did not fix it (fruits 6.0 → 21) because the two crops' "neutral"
  content differs — this is what a neural matcher (Colourlab) is for, and
  match_shot's description should keep saying "same scene". auto_balance
  refuses colourful frames with no neutrals (portrait 0%, fruits 0.7%
  neutral weight) rather than guess. Different subjects: match_hues
  refuses (global gap 27%), match_shot runs (by design).
  compare_grades (head-to-head vs Colourlab): loads each local version of
  the target (GetVersionNameList / GetCurrentVersion / LoadVersionByName,
  versionType 0 — documented API, NOT yet live-probed here), grabs, scores
  against the reference grab: tiffDeltaE (per-pixel ΔE2000, same media +
  source frame, auto-detected via media pool name + left offset) or
  statsDistance (curve RMS + mean diff + chroma p90 + hue overlap + skin
  angle) for different shots; restores the active version in a finally.
  Tool surface: match_shot (power/saturation params), match_timeline (hero
  given or medoid, one approval), auto_balance, match_hues (.cube via the
  look designer, SetLUT dead on the Mac → manual load), qc_scan skin-cast
  flag. Test fake renders scene frames through the last SetCDL
  (grabState.scene) so the closed loop is exercised for real.

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
- AE panel + other MCP servers (Higgsfield via `claude mcp add --transport
  http higgsfield https://mcp.higgsfield.ai`): the panel merges the server
  into its per-turn mcp.json and allows mcp__<name>__*. Documented CLI
  facts (code.claude.com/docs/en/agent-sdk/mcp): the stream-json
  system/init event carries mcp_servers [{name,status}] with status one of
  pending/connected/failed/needs-auth/disabled, plus tools[] where MCP
  tools are mcp__<server>__<tool>; a server whose OAuth token is missing
  reports needs-auth (init may still say pending) and its tools are simply
  absent — headless runs cannot sign in. Live symptom before this was
  handled: mcp_status said attached, every guessed mcp__higgsfield__* call
  got "No such tool available". Now observeMcpInit/mcpAdvice (tracklib)
  record status + names per server, a NOTE card names the fix, mcp_status
  reports usable/tools/problem, the next prompt lists the seen names
  (KNOWN_MCP_TOOLS gives Higgsfield's core names before any turn). Live
  root cause on Josh's Mac: `claude mcp list` showed the claude.ai
  connector "higgsfield" connected but a local entry "higgsfield" at
  https://mcp.higgsfield.ai failing "endpoint not found" — the real
  endpoint is https://mcp.higgsfield.ai/mcp (POST there: 401 with
  WWW-Authenticate Bearer resource_metadata=…/.well-known/oauth-protected-
  resource/mcp; the bare host and /sse: 404). The panel resolves the LOCAL
  entry, so it inherited the dead URL. probeMcpEndpoint/classifyMcpProbe
  now say so from mcp_status/mcp_connect (KNOWN_MCP_URLS carries the fix).
  --strict-mcp-config hides claude.ai connectors from the panel; the
  extra_mcp_mode "inherit" fallback drops it (CLI loads all of Claude
  Code's servers, only ae is added) so the connector's working sign-in can
  be used. LIVE 2026-09-09 (Josh's Mac): after `claude mcp remove
  higgsfield`, `claude mcp add -s user --transport http higgsfield
  https://mcp.higgsfield.ai/mcp` and /mcp Authenticate, the AE panel
  reported Higgsfield connected and working — the first live proof of the
  extra-MCP path (which mode, strict or inherit, was not recorded; a
  generation through it has not been run yet).
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
"Surface0X"]) → "No such parameter" — REVIEW FOUND WHY: Mocha's project
file spells layer names with underscores ("Claude Track" → "Claude_Track";
the Python guide says so), so the guide's path was right and the name was
wrong; mocha_job.py now tries the underscored name first and also sets
SurfaceFrame; the panel still retargets the exported quad via per-frame
homography (tracklib.retargetCornerPin) — exact and idempotent; (3) "Paste Mocha
mask" did NOT produce a native mask — AE created/used the legacy "mocha
shape" effect (ISL MochaShapeImporter, CUSTOM_VALUE not scriptable); the
in-AE Claude parsed mask.shape4ae itself (64 pts/frame) — FORMAT (josh's file, 975 KB / 240 frames):
"Adobe After Effects 6.0 Keyframe Data", header (Units Per Second 24!,
Source Width/Height), block "Effects<TAB>mocha shape #1<TAB>Shape data",
"<TAB>Frame", rows "<TAB>f<TAB>Bezier(Point(x,y,0,0.5,a,b,c,d)Point(...)...)"
with x,y normalised to source size (64 points/frame; the six extra
numbers are spline data, ignored — RotoBezier smooths the polygon).
tracklib.parseMochaShapeText + host apply_mask_keyframes (chunks of 40)
replace the clipboard/Paste-Mocha-mask route; (4) the region left frame right at ~f15 and the tracker
re-locked on the road — tracklib.trackReport now flags usable range.
THEN: my "wait for IEND" $.sleep loop in grab_frame FROZE AE — ExtendScript
blocks the main thread that finishes the PNG, so the file stalls half-
written and every later evalScript queues (timeouts everywhere). Rule:
host tools return immediately; the panel (Node) waits on files
(tracklib.waitForPng). grab_source_frame added: temp __ClaudeGrab__ comp
with just the layer's source → PNG in SOURCE pixels, comp removed after.

ADVERSARIAL REVIEW (34 agents, 2026-09-04) of the day's AE work: 13
confirmed → all fixed: underscore layer name for Surface params; corner
order canonicalised by geometry (tracklib.cornersFromQuad — a user passing
AE order UL,UR,LL,LR used to get a bow-tie); apply_keyframe_data with
effect_name only reuses ITS OWN labelled effect (never the first Corner
Pin on the layer); start_s ≥ end_s now errors instead of a 1-frame track;
paste_mocha_mask activates the comp first; grab_source_frame removes its
temp comp on host failure and the panel sweeps all __ClaudeGrab__ comps;
ai_segment keeps the paid result when import_and_matte fails; Mocha
children are killed on panel unload and mocha_cancel exists; track_report
is computed on the RETARGETED quad (mocha_surface_report keeps Mocha's
view); ⌘V flattens line breaks; windowsHide on every child process;
plus lows: CA_RESULT on its own line, fail() traceback only inside
except, non-finite/degenerate retarget guards, edge-touching first frame
not condemned, normalised mask export scaled by source size, U+2028/9
escaped in evalScript, run_javascript code in Copy chat, Copy button safe
on the "assistant missing" card. Left alone (documented): run folders /
history growth, one approval slot for parallel modifying calls, motion
blur export semantics (refuted as a defect).

## AE music / beat sync (built 2026-09-04, harness-verified, not yet live)

audiolib.js: afconvert (`-f WAVE -d LEI16@22050 -c 1`, fallback without
-c) or ffmpeg → WAV → parseWav (8/16/24/32-bit, float, extensible) →
analyze(): 2× biquad LP 150 Hz for bass, hop 512 @ 22.05 kHz, rectified
log-energy onsets (full + 1.5×bass), autocorrelation tempo with log-normal
prior at 120 BPM + octave sanity (80–170), Ellis DP beat tracker
(tightness 300), downbeat phase = max bass onset over 4 phases, bass hits =
adaptive peaks (mean+1.5σ over ±1 s, 110 ms min gap, strength/p95),
sections per bar (relative to loudest BAR, not loudest transient — that
was the first bug), drop = first sustained "high" after something lower.
Synthetic 128 BPM test: 128.4 BPM, 94% beats ≤35 ms, 35/35 kicks. Panel
tools: music_list (~/Music/Claude Assistant + music_dirs), analyze_music
(cache USER_DATA/audio/<sha1 of path|size|mtime>.json), add_music,
beat_control (BEAT guide null: Beat/Bar/Bass/Energy sliders via
set_slider_keys in chunks of 400 with setValuesAtTimes, BPM static; ♪
markers cleared by prefix), cut_to_beats (planCuts on beats/downbeats,
items cycle with per-item source cursor, add_clip), beat_effects
(expressions reading thisComp.layer("BEAT").effect("Bass")("Slider")),
plus set_expression/add_solid/add_null/set_markers/find_layer hosts.
Unknown until live: afconvert -c support on josh's macOS, MarkerValue on
comp.markerProperty in AE 2026, expression text accepted verbatim.

## Claude Music panel UI (built 2026-09-09 from the Claude Design "Claude Music Panel" project, harness-verified, not yet live)

html/music.html + music.css + music.js over the shared panel.js/app.js;
html/broadsheet.css is the design system's styles.css with the Google
Fonts @import removed (a blocking @import hung the whole page offline —
the font now comes from a non-blocking <link media="print" onload>).
music.js is a state machine, S.view ∈ empty / library / track /
listening / results / applied / settings; it wraps A.onEvent so
music_progress events and the "done" comp refresh run before app.js's
handler, and A.setContext(contextText()) puts the panel state into the
system prompt ("Panel state right now: …"). Fits: six bars before the
drop (only when the drop is past 37.5 % of the comp), start from the top,
start at the break; drop_s ≤ 0.5 counts as "no drop". Wiring rows Kick /
Bass / Energy → beat_effects (punch 8/4, zoom 6/3, shake 12/6, opacity
and flash 60/30 by feel); music_undo removes the music layer, BEAT, FLASH
solids, the listed expressions and ♪ markers, nothing else. Two bugs the
harness found: renderChecklist read a.bars when the "done" progress event
(pct 100) arrived before S.analysis was set, and because sendUI is
synchronous that throw rejected analyze_music itself ("I couldn't
listen…"); and undo used the ACTIVE comp, so a turn that made another
comp (the fake "hello" makes Hello Comp) broke it — S.applied.comp now
anchors refreshComp, expressions and undo to the comp the music is on,
and a deleted comp clears the applied state with a note. Deliberate
departures from the design: no stems (Kick/Bass/Energy come from the
mix), no key detection, no API-key field, "Bake keyframes instead" and
"Markers on the audio layer" disabled.

Review round (5 lenses, adversarially verified where the usage limit
allowed) and what changed: CEP 12 = Chromium 99, which has NO :has() and
NO color-mix() — the harness's Electron renders both, so it cannot catch
them; broadsheet.css/music.css now use rgba() and a JS-kept .seg-opt.on /
.focus class (syncSegs in music.js); grep both files for the two
functions after any style change. Flash rows insert a solid above their
layer and shift every index below, so writeExpressions sorts flash rows
last, resolves each row by NAME against a fresh list_layers just before
writing, and records expressions by name (music_undo resolves names via
find_layer). remove_layers now removes ONE layer per name, the topmost
(all_matches:true for every one) — the panel's layers are added at the
top, a user's same-named layer below survives. A song picked from the
comp ("Use this comp's audio" / In this comp) is never re-added: the fit
is "As it sits on your timeline" (in_s = layer in − start, offset_s =
start), applied.layerName is null and undo leaves the layer. Tool results
may carry panel-only fields under keys starting with "_": the MCP path
strips them before the model sees the JSON, assistant.callTool merges
_panel up (summary() puts downbeats + wave there; music_list puts the
cached waves there and adds library_dir, the folder the user chose —
musicDirs() always lists the default first, which is why the settings
field once always showed the default). withBusy serialises apply / write
/ undo; listen is cancellable and shares one in-flight analysis per file;
refreshComp runs before listen/apply/comp-audio and on window focus
because AE gives a panel no comp-changed event; "done" re-renders and
re-sends the panel context; back/≡ compute the home view from state;
beat_control's markers_written counts only the grid asked for
(markers_total, drop_marker alongside) and skips the ♪ DROP marker when
drop_s ≤ 0.5. Unverified findings still open (verifiers hit the usage
limit): the "renamed comp counts as deleted" note (comps are matched by
name; get_project_overview has no id), and host-sim footage reporting
has_audio=false where AE would say true for clips with soundtracks.

Review round 2 (4 lenses, 21 confirmed, all fixed): the "topmost layer
per name" undo was WRONG for the music layer — add_clip ends with
layer.moveToEnd(), so the panel's song sits at the BOTTOM and a user's
same-named layer above it would have been deleted; host-sim's
moveToEnd() was a no-op, which is why the harness never saw it (now it
really moves the layer, and the step-12 order is BEAT, clips, music).
remove_layers takes {name, index, start_s} (the layer at index if the
name/startTime match, else the bottom-most match; misses reported) and
undoAllNow finds its copy by name + offset_s from a fresh list_layers;
bare names keep the topmost rule for BEAT/FLASH. The placed-song fit is
matched by name + file (placedLayer(), index only as a tiebreaker) and
says "That layer is no longer in <comp>" instead of falling through to
add_music; its maths: in_s = inPoint − startTime, offset_s = startTime,
from_s = inPoint, until_s = min(comp, outPoint) in COMP time, and
applied.until_s = until − offset − in_s (song seconds on the timeline);
drop comp time = drop_s + offset_s, gated on beat_control's drop_marker;
the applied axis is comp time (axisFrom = −offset_s). beat_control
gained from_s so nothing lands on a trimmed, inaudible head. Range and
Offset are disabled for a placed song (whole/offset ignored, context
says so). writeExpressions has no index fallback; renderWiring selects
by name and re-syncs w.layer and the .on class. S.listening keeps
Back/≡ on the listening view mid-analysis. markers/kind are read once
per apply and body.busy fades the controls that feed an action.

## Resolve panel slash menu (2026-09-10)

Typing "/" in the Resolve panel's input opens #slashmenu (renderer/app.js:
renderSlash/acceptSlash/localCommand): the list is tools.SLASH_COMMANDS,
sent with the config IPC so the two never drift. /study and /train are the
same macro (expandSlash is typo-tolerant for both: /stuudy, /trainn);
help/new/history/copy are local:true and never reach the model. Rows fill
the command in with a trailing space when it takes arguments, or submit at
once when it does not; mousedown (not click) on a row so the input keeps
focus; the menu hides once the caret is past the first space. There is no
Electron harness for the Resolve renderer — the slash menu was checked
with a Playwright page over renderer/index.html with a stubbed
window.assistant (scratchpad), plus test_plugin.js for expandSlash.
Round 2 (the user saw "Unknown command: /train"): that string is Claude
Code's — the CLI reads a leading "/" as one of its own commands. Both
panels now route every line before the CLI sees it: tools.slashRoute
(Resolve) / slashRoute in panel.js (AE) → expand a macro, answer an
unknown /word with a NOTE (no turn, "done" sent so the UI un-busies), or
pass text through with "Message from the panel (a path, not a command): "
prefixed when it starts with "/". The AE panels (both pages, shared
app.js) got the same "/" menu with /help /tools /mcp /new /history /copy;
/train and /study there answer "that's a Resolve panel command". AE
harness step 6b covers it; manifest 1.0.21.
