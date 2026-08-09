# Claude Assistant for DaVinci Resolve Studio

A chat panel that runs **inside DaVinci Resolve** and lets Claude actually drive
Resolve for you — not just answer questions. Ask it things like:

- *"Add a red marker at every cut on V1 with a note saying 'review color'."*
- *"What's in my media pool? Make a bin called Selects and tell me what you'd put in it."*
- *"Look at the frame I'm parked on — is it overexposed?"* (Claude actually **sees** the frame)
- *"Queue a YouTube 1080p render of this timeline to ~/Renders and start it."*
- *"Switch to the color page and tell me which clip I'm parked on."*
- *"Why does my 23.976 footage stutter on a 25fps timeline?"* (plain advice — no tools needed)

Claude sees a live snapshot of your session (current page, project, timeline,
playhead) with every message, and works through **70 purpose-built tools**
covering markers, timelines, the media pool, clip properties, project settings,
color (current clip / LUTs), and the render queue — plus an optional
`run_python` escape hatch for anything the tools don't cover.

---

## Install

**1. Copy `Claude Assistant.py` into Resolve's Utility scripts folder:**

| OS | Path |
|---|---|
| macOS | `~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/` |
| Windows | `%APPDATA%\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Utility\` |
| Linux | `~/.local/share/DaVinciResolve/Fusion/Scripts/Utility/` |

Or run the installer from this folder:

```bash
# macOS / Linux
./install.sh

# Windows (PowerShell)
.\install.ps1
```

**2. Choose how the panel reaches Claude** — either works:

| Backend | What it uses | Cost |
|---|---|---|
| **Claude Code** *(default when detected)* | Your existing Claude **Pro/Max subscription** | Included in your plan — no API key |
| **API key** | The Anthropic Messages API | Billed per token |

*For the Claude Code backend*, install the CLI and sign in once:

```bash
npm install -g @anthropic-ai/claude-code
claude          # sign in with your Claude account, then /exit
```

*For the API-key backend*, get a key from
[platform.claude.com](https://platform.claude.com) (Console → API keys).

**3. Launch Resolve → `Workspace` → `Scripts` → `Claude Assistant`.**

If the Claude Code CLI is installed, the panel uses it automatically and never
asks for a key. Otherwise the first launch offers both options and stores your
choice in a private config file
(`~/.config/claude-resolve-assistant/config.json`, or
`%APPDATA%\ClaudeResolveAssistant\config.json` on Windows).

To force a backend, set `backend` to `claude-code` or `api` in that config file,
or set the `CLAUDE_RESOLVE_BACKEND` environment variable.

### How the Claude Code backend works

Claude Code runs as a separate process, so it can't touch Resolve directly —
only the in-Resolve panel holds that connection. The panel therefore starts a
loopback tool server (random port, random token, `127.0.0.1` only) and hands
Claude Code a small MCP server that forwards tool calls back to it. Claude Code
is launched with `--strict-mcp-config`, `--tools ""` and
`--allowedTools mcp__resolve__*`, so it gets **the 70 Resolve tools and nothing
else** — no filesystem access, no shell, and none of your other MCP servers.

Note that `ANTHROPIC_API_KEY` is deliberately **removed** from the CLI's
environment. In headless mode an API key silently overrides subscription auth,
which would bill API credits to someone who picked this backend precisely to
avoid that.

### Requirements

- DaVinci Resolve **Studio** (the supported target; recent free versions can
  also run Workspace-menu scripts).
- A Python 3 installation that Resolve can see
  (`Preferences → System → General`). **No pip packages are required** — the
  plugin speaks to the Anthropic API with Python's standard library. If the
  official `anthropic` SDK happens to be installed, it's used automatically.
- Internet access to `api.anthropic.com`.
- For the Claude Code backend: the `claude` CLI on PATH (or set
  `claude_code_bin` in the config / `CLAUDE_CODE_BIN` in the environment), plus
  an active Claude subscription.

---

## Using it

- **Model picker** — defaults to `claude-opus-5`. `claude-fable-5` is the most
  capable (and priciest on the API backend); `claude-sonnet-5` is faster/cheaper
  and `claude-haiku-4-5` is for quick lookups.
- **Effort** — how hard Claude thinks before acting: `low`/`medium`/`high`
  (default)/`xhigh`/`max`. Lower is faster and cheaper; raise it for complex
  multi-step jobs. Ignored on Haiku, which doesn't take an effort setting.
- **Enter to send.** Claude may take several tool steps per request; each tool
  call is shown in the transcript as it happens.
- **New chat** clears the conversation (Claude's memory of this session).
- **Allow Python execution** — when checked, Claude may run short Python
  snippets inside Resolve for requests the built-in tools don't cover. Every
  snippet is printed in the transcript before it runs. Uncheck to restrict
  Claude to the curated tools only.
- **Style** — switches the panel's look: `Resolve` (native graphite — cards
  with coloured caps labels, code cards with a language header), `Console`
  (dense one-row-per-event, code collapsed to chips), `Contrast`, `Compact`
  and `Terminal`. Switching restyles the whole transcript instantly and is
  remembered across sessions. Toggles render as switches, Send carries the
  accent colour, and after each turn the status strip shows
  `Ready · N tool calls · M:SS`.
- **History** — every chat saves itself after each completed turn. The
  History button opens a browser of past chats (double-click to reopen one
  and keep going). On the Claude Code backend the original session is resumed
  when it still exists; when it doesn't, the next message quietly carries a
  transcript recap so the conversation still continues. The newest 100 chats
  are kept, in `ClaudeResolveAssistant/chats` next to the config file.

### Workspace > Workflow Integrations (Resolve Studio)

The same file can also be registered as a **Workflow Integration**, so the
assistant appears under `Workspace > Workflow Integrations > Claude Assistant`
like a native plugin. Run `Install-WorkflowIntegration.ps1` (right-click →
Run with PowerShell — it asks for admin because the folder lives in
ProgramData), or copy manually:

```
%PROGRAMDATA%\Blackmagic Design\DaVinci Resolve\Support\Workflow Integration Plugins\
```

Create the folder if it doesn't exist, drop `Claude Assistant.py` in as a bare
file, and restart Resolve (this menu is scanned only at startup). The script
runs in the same in-process environment either way — same panel, same tools.

Caveat: workflow integrations are a **DaVinci Resolve Studio** feature; the
free edition never shows the menu (and free 19.1+ also blocks UIManager
panels generally). If the menu doesn't appear, keep using Workspace > Scripts.

### What Claude can do out of the box

| Area | Tools |
|---|---|
| Orientation | workspace overview, switch pages, timeline details, clips per track |
| Markers | add / list / delete (by position or color), timecode or frame positions |
| Timelines | create, switch, move playhead, append clips |
| Media pool | browse folders, clip properties, create bins, import media from disk |
| Editing | place clips at exact frame/track with in/out points, delete (with ripple), add tracks |
| Transforms | zoom/punch-in, pan, tilt, rotation, crop, opacity, flip on any clip |
| Titles & Fusion | insert a title and set its text, add Fusion effect nodes with parameters |
| Color | current clip info, copy a grade to other clips, colour versions, LUT on a node, reset, ASC CDL |
| **Vision** | `view_frame` — Claude looks at the actual frame (playhead or any timecode) as an image; `survey_clip` — several frames across a range in one go, for scanning a clip or checking continuity |
| Audio | transcribe clips/bins, auto-caption the timeline (read the text via the subtitle track), auto-sync audio to camera clips (19.1+) |
| Timeline ops | export/import AAF·EDL·XML·FCPXML·OTIO·DRT·CSV·ALE, duplicate timeline, compound clips, rename/lock/enable tracks |
| Organisation | clip colors and flags on any clips |
| Colour extras | colour groups (19+), bake a grade to a .cube LUT (19+), **looks library** — save any clip's grade as a named look, apply it to other clips later |
| Deeper editing | automatic scene-cut detection, take selectors (audition alternates in place), **interchange round-trip** — read the timeline as EDL/XML text, transform it, apply as a new timeline (the only route to trims/moves/splits) |
| Audio extras | AI Voice Isolation per clip (20.1+ Studio), proxy link/unlink, AI speech generation (21+) |
| Render setup | list formats/codecs, set format/codec and any render setting, save render presets |
| Projects | list/create/open projects |
| **Auto-sorting** | `auto_sort_media` — sort the pool into bins by type/resolution/fps/camera/date (with dry-run preview); `import_and_sort` — import files and bin them in one step; the **Drop folder** checkbox watches `~/Videos/Claude Drop` and auto-imports+sorts anything you drop there. `watch_folder` adds extra watched folders — point it at an AI generator's output directory (Higgsfield, etc.) and every clip it saves lands in your bins automatically. Clips get Keywords metadata so UI **Smart Bins** matching those keywords collect them automatically (the API can't create Smart Bin rules itself). |
| **Higgsfield AI** | Generate media without leaving the chat, on your Higgsfield account: `higgsfield_generate_image` (Soul text-to-image), `higgsfield_animate_image` (DoP image-to-video with cinematic camera moves — animate a grabbed frame or any still), `higgsfield_list_motions` (camera presets), `higgsfield_check_job` (long renders), `higgsfield_setup` (store your `KEY_ID:KEY_SECRET` from cloud.higgsfield.ai). Results download and auto-sort into bins. Endpoint shapes verified against Higgsfield's official SDKs. |
| Search | `find_clips` — find clips by name, clip color or flag across the media pool and timeline, returning positions other tools accept directly |
| Diagnostics | `run_diagnostics` — reports what THIS Resolve version supports per capability; `live=true` also exercises a scratch timeline end-to-end and cleans up after itself |
| Deliver | list presets, queue render jobs (preset/target/filename), start, status |
| Project | read/change project settings, save project |
| Anything else | `run_python` (optional, shown in transcript, toggleable) |

Claude is instructed to **ask before destructive things** — bulk-deleting
markers, changing timeline resolution mid-project, starting renders you didn't
ask for, or any `run_python` that touches files on disk.

### What Resolve's API genuinely cannot do

These are limits of Blackmagic's scripting API, not of the plugin. Claude is told
about them so it says so plainly instead of failing silently:

| Not possible | Detail |
|---|---|
| Trim / slip / roll / razor / move a clip / speed changes **in place** | Clips can only be **added** and **deleted**. Simulating a move means delete + re-add, which loses that clip's grade, Fusion comp and transforms. The interchange round-trip (EDL/XML out → transform → import) supports arbitrary re-editing, but always as a **new** timeline. |
| Colour wheels — lift/gamma/gain/contrast/temp/tint | No API exists in any version. `set_cdl` (ASC CDL slope/offset/power) is the only numeric colour control, and it's **write-only** — no read-back, so every call is an absolute overwrite, never a nudge. A colour version is auto-saved first as an undo net. |
| Create/reorder nodes, power windows, qualifiers, grade keyframes | No API surface at all. |
| Audio mixing — clip volume, fades, EQ, dynamics, LUFS/levels | Nothing exists in any version. Audio *tracks* can be added and managed; nothing inside them can be adjusted. |
| Choose a title's track or duration at insert | Titles land on the lowest video track. |

> Beware third-party Resolve integrations advertising clip-volume or colour-wheel
> control — the API methods they call don't exist, and Resolve returns failure
> silently. This plugin only ships tools built on methods verified against
> Blackmagic's own scripting README.

### Timecode notes

Positions accept `HH:MM:SS:FF` timecode, a frame offset from the start of the
timeline, or `playhead`. Frame math for drop-frame rates (23.976/29.97/59.94)
uses the nominal rate, which is exact for marker placement in Resolve's model;
when moving the playhead the timecode string is passed to Resolve unmodified.

---

## Privacy & safety

- Your prompts, the tool results Claude requests (timeline/clip metadata,
  settings), and the session snapshot are sent to the Anthropic API. Your media
  files are never uploaded — with one deliberate exception: when Claude uses
  `view_frame` (because you asked about how something looks), that single
  grabbed frame is sent as an image so Claude can see it.
- `view_frame` briefly flips to the Color page to grab the still (Resolve
  requirement) and flips back; the grabbed still is deleted from your Gallery
  and the temp file from disk immediately after export. If the full-resolution
  grab fails, it falls back to the Color-page thumbnail.
- The API key is stored with `0600` permissions in your user config folder and
  never leaves your machine except as the auth header to `api.anthropic.com`.
- On the Claude Code backend there's no key to store — the CLI uses your own
  signed-in session. The tool bridge listens on `127.0.0.1` only, on an
  ephemeral port, and rejects any request without the per-session random token.
- `run_python` executes with the same permissions as Resolve. Leave it enabled
  for maximum capability, or uncheck it for a strictly-curated toolset.
- On `claude-opus-5`, server-side refusal fallbacks are enabled so a
  false-positive safety decline transparently retries on a recommended model
  instead of dead-ending your request.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Script doesn't appear in Workspace → Scripts | Wrong folder — double-check the path table above (note `Fusion/Scripts/Utility`), then restart Resolve. |
| "Could not connect to DaVinci Resolve" | Run it from the Scripts menu inside Resolve. For external runs: Preferences → System → General → *External scripting using* → **Local** (Studio only). |
| Window opens but nothing sends / "Invalid API key" | Re-check the key; delete the config file to be re-prompted. |
| "Claude Code CLI not found" | Install it (`npm install -g @anthropic-ai/claude-code`). If it *is* installed, Resolve may be launching with a trimmed PATH — set `claude_code_bin` in the config file to the CLI's full path. |
| "Claude Code is installed but not signed in" | Run `claude` in a terminal, sign in, then reopen the panel. |
| "The Resolve tool bridge did not connect" | The notice now includes a diagnosis. The bridge runs on Python 3 when a real one exists, and **falls back to Node.js automatically** (Node is present wherever the Claude Code CLI works). Windows note: the `python3.exe` under `Microsoft\WindowsApps` is a Store advert, not Python — the plugin detects and skips it. Escape hatch: set `"python_bin"` in the config file to a real interpreter. |
| TLS certificate error (macOS) | Run `Install Certificates.command` inside your `/Applications/Python 3.x/` folder, or `pip3 install certifi`, then restart Resolve. |
| UI freezes while Claude works | Your Resolve build lacks UI timers, so the plugin falls back to synchronous calls — it will unfreeze when the answer arrives. |
| No Python found by Resolve | Install Python 3 from python.org (macOS/Windows) and restart Resolve. |

## Development

Everything lives in one file on purpose (`Claude Assistant.py`) so installs are
a single copy. A mock-Resolve test harness exercises every tool and the agent
loop without needing Resolve; the Anthropic integration uses the Messages API
with tool use, prompt caching on the system prompt, and adaptive thinking.
