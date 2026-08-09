# Claude Assistant for DaVinci Resolve — agent handoff notes

Read this before touching the code. It encodes lessons learned the hard way,
several from live failures inside real Resolve on Windows.

## What this is

A chat panel that runs inside DaVinci Resolve (Workspace > Scripts) and lets
Claude drive Resolve through 64 tools. Two backends:

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
│ execute_tool → 64 tool fns   │
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

## Conventions

- Tool = `@tool(name, description, params, required)` on `t_*(app, ...)`;
  raise `ResolveError` with a plain-English, actionable message on failure.
- Version-gate risky methods with `_supports()` and refuse with the Resolve
  version requirement in the message.
- Destructive tools say so in their description so the model confirms first.
- After changing tools, update: fakes + checks in the test file, README tables,
  and the tool-count strings in README.

## Current status (last updated by the original build session)

- 62 of 64 tools live-verified against the real claude CLI with a mocked Resolve
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
  Future Electron milestone (verified): Resolve Studio bundles its own
  Electron; a plugin = folder + manifest.xml + WorkflowIntegration.node
  COPIED FROM THE USER'S INSTALL (Developer/Workflow
  Integrations/Examples/SamplePlugin/ — don't commit it, gray-area
  redistribution); precedent repo olegkupshukov/claude-resolve spawns the
  claude CLI from the plugin's main process. Gotchas: orphaned electron.exe
  can lock the .node file on Windows; call SetAPITimeout() after init.
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
