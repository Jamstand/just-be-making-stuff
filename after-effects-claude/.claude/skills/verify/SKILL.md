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

Spawns the REAL `bridge.js` as an MCP stdio server, connects it over REAL
TCP to the REAL `html/panel.js` (tool registry, approvals, history), which
dispatches into the REAL `host/ae-tools.jsx` running in a `vm`. Only CEP's
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
trait); panel.js dying at top level; config() rejecting. Each must end in
either filled dropdowns + the Connected card, or a visible red card — never
silence. Screenshots land next to the script.

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

- `bridge.js` is shared verbatim with the Resolve plugin: serverInfo name
  and "Resolve bridge unreachable" text are Resolve-branded; harmless to the
  CLI (namespaces by mcp.json key `ae`).
- The wrong-token path reports "bridge error" — the panel's `{error:"bad
  token"}` reply is not read by bridge.js (it reads `content`).
- CEP caches extension JS; a "fixed" panel that still misbehaves is often
  stale. The installer now purges ~/Library/Caches/CSXS/cep_cache and the
  manifest version was bumped; bump it again on structural changes.
- Errors thrown by file:// scripts may reach window.onerror masked as
  "Script error." — the on-screen card still proves *something* threw;
  the DevTools console (http://localhost:8092 via .debug) has the detail.
