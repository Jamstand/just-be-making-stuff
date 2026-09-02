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
