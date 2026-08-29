# Claude Assistant — Workflow Integration plugin (Electron)

The same integration style as the Higgsfield plugin: a real HTML panel under
**Workspace > Workflow Integrations**, launched by Resolve's own bundled
Electron. This is the modern sibling of the single-file Python panel — both
can be installed side by side; they are separate entries in the menu.

```
renderer (HTML chat UI, the design-file look)
   ↕ IPC
main.js — WorkflowIntegration.node → live Resolve object
        — tools.js: 24 JS tools + run_javascript (grab_still vision, colour suite: pipeline_doctor, qc_scan, match_shot, design_look, apply_vignette)
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
| Tools | 70, incl. grading/Fusion/Higgsfield | 25 incl. `grab_still` vision, colour suite (`pipeline_doctor`, `qc_scan`, `match_shot`, `design_look`, `apply_vignette`) + `run_javascript` |
| Approvals | buttons above the input | real inline amber card, per the design |
| UI | Qt rich-text subset | full HTML/CSS (the design file, faithfully) |
| History browser | yes | yes — autosaved chats, reopen + resume, transcript recap when the session expired |
| Themes / drop folder | yes | not yet |
| Session resume | across restarts | across restarts (saved session id, recap fallback) |

`run_javascript` narrows the tool gap substantially: the JS scripting object
is the same API as Python's (`project.GetMediaPool()`, `timeline.AddMarker`,
…), so the model can do anything the API allows, with the code shown in the
transcript and gated by approvals.

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
