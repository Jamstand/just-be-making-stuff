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
