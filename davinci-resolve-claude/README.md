# Claude Assistant for DaVinci Resolve Studio

A chat panel that runs **inside DaVinci Resolve** and lets Claude actually drive
Resolve for you — not just answer questions. Ask it things like:

- *"Add a red marker at every cut on V1 with a note saying 'review color'."*
- *"What's in my media pool? Make a bin called Selects and tell me what you'd put in it."*
- *"Queue a YouTube 1080p render of this timeline to ~/Renders and start it."*
- *"Switch to the color page and tell me which clip I'm parked on."*
- *"Why does my 23.976 footage stutter on a 25fps timeline?"* (plain advice — no tools needed)

Claude sees a live snapshot of your session (current page, project, timeline,
playhead) with every message, and works through **25 purpose-built tools**
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

**2. Get an Anthropic API key** from
[platform.claude.com](https://platform.claude.com) (Console → API keys).

**3. Launch Resolve → `Workspace` → `Scripts` → `Claude Assistant`.**
The first launch asks for your API key and stores it in a private config file
(`~/.config/claude-resolve-assistant/config.json`, or
`%APPDATA%\ClaudeResolveAssistant\config.json` on Windows). Setting the
`ANTHROPIC_API_KEY` environment variable works too and takes precedence.

### Requirements

- DaVinci Resolve **Studio** (the supported target; recent free versions can
  also run Workspace-menu scripts).
- A Python 3 installation that Resolve can see
  (`Preferences → System → General`). **No pip packages are required** — the
  plugin speaks to the Anthropic API with Python's standard library. If the
  official `anthropic` SDK happens to be installed, it's used automatically.
- Internet access to `api.anthropic.com`.

---

## Using it

- **Model picker** — defaults to `claude-opus-5` (most capable). Switch to
  `claude-sonnet-5` for faster/cheaper or `claude-haiku-4-5` for quick lookups.
- **Enter to send.** Claude may take several tool steps per request; each tool
  call is shown in the transcript as it happens.
- **New chat** clears the conversation (Claude's memory of this session).
- **Allow Python execution** — when checked, Claude may run short Python
  snippets inside Resolve for requests the built-in tools don't cover. Every
  snippet is printed in the transcript before it runs. Uncheck to restrict
  Claude to the curated tools only.

### What Claude can do out of the box

| Area | Tools |
|---|---|
| Orientation | workspace overview, switch pages, timeline details, clips per track |
| Markers | add / list / delete (by position or color), timecode or frame positions |
| Timelines | create, switch, move playhead, append clips |
| Media pool | browse folders, clip properties, create bins, import media from disk |
| Color | current clip info + grade versions, apply LUT to a node |
| Deliver | list presets, queue render jobs (preset/target/filename), start, status |
| Project | read/change project settings, save project |
| Anything else | `run_python` (optional, shown in transcript, toggleable) |

Claude is instructed to **ask before destructive things** — bulk-deleting
markers, changing timeline resolution mid-project, starting renders you didn't
ask for, or any `run_python` that touches files on disk.

### Timecode notes

Positions accept `HH:MM:SS:FF` timecode, a frame offset from the start of the
timeline, or `playhead`. Frame math for drop-frame rates (23.976/29.97/59.94)
uses the nominal rate, which is exact for marker placement in Resolve's model;
when moving the playhead the timecode string is passed to Resolve unmodified.

---

## Privacy & safety

- Your prompts, the tool results Claude requests (timeline/clip metadata,
  settings), and the session snapshot are sent to the Anthropic API. Media
  itself is never uploaded.
- The API key is stored with `0600` permissions in your user config folder and
  never leaves your machine except as the auth header to `api.anthropic.com`.
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
| TLS certificate error (macOS) | Run `Install Certificates.command` inside your `/Applications/Python 3.x/` folder, or `pip3 install certifi`, then restart Resolve. |
| UI freezes while Claude works | Your Resolve build lacks UI timers, so the plugin falls back to synchronous calls — it will unfreeze when the answer arrives. |
| No Python found by Resolve | Install Python 3 from python.org (macOS/Windows) and restart Resolve. |

## Development

Everything lives in one file on purpose (`Claude Assistant.py`) so installs are
a single copy. A mock-Resolve test harness exercises every tool and the agent
loop without needing Resolve; the Anthropic integration uses the Messages API
with tool use, prompt caching on the system prompt, and adaptive thinking.
