# Resolve MCP server for Claude Code (macOS)

Drive DaVinci Resolve Studio from Claude Code: describe an effect in plain
English, and the model builds and verifies the Fusion comp through these
tools. External scripting over Blackmagic's `fusionscript` bridge — nothing
is installed into Resolve; the server is a plain Python process Resolve
lets in through a socket.

## How the pieces fit

```
Claude Code ── MCP (stdio) ──> resolve_mcp.py ── fusionscript.so ──> Resolve
```

- `fusionscript.so` ships inside the Resolve app bundle; Blackmagic's
  `DaVinciResolveScript` Python module (in the Developer folder) loads it
  and returns a live `Resolve` object.
- The connection requires **Resolve Studio** (the free edition refuses
  external scripting) and **Preferences > System > General > "External
  scripting using" = Local**. That preference is the one Resolve setting
  this project asks you to change, and you change it yourself.

## Step 1 — verify the machine (before anything else)

With Resolve open, run:

```bash
cd davinci-resolve-claude/mac-mcp
python3 check_resolve.py
```

It confirms the API paths, imports the bridge, connects, and reads your
project — read-only, and each failure mode prints its exact fix. Don't go
past this step until it prints `[OK]`.

## Step 2 — register the server with Claude Code

```bash
claude mcp add resolve -- python3 "$(pwd)/resolve_mcp.py"
```

That writes one entry to Claude Code's own MCP config (your shell profile
and Resolve are untouched). Restart your Claude Code session and check the
tools are listed with `/mcp`.

## Step 3 — smoke test

In Claude Code, with Resolve open and the playhead parked on any test clip:

> run the resolve smoke_test tool and show me the report

It adds one Blur between MediaIn and MediaOut, sets a static value, writes
two keyframes, reads the whole graph back, verifies each step, and then
deletes the Blur and restores the original wiring — the comp ends as it
began. The report lists every step with pass/fail.

## The tools

| Tool | What it does |
|---|---|
| `get_state` | project, timeline, fps, page, clip under the playhead |
| `list_clips` | video clips per track |
| `open_comp` | open (or create) a clip's Fusion comp, list its nodes |
| `add_node` | add a Fusion tool by internal id (Blur, Merge, TextPlus…) |
| `connect_nodes` | wire an output into a named input |
| `set_node_input` | static values; `[r,g,b(,a)]` lists fan out to colour components |
| `animate_input` | attach a BezierSpline and set `{frame, value}` keys |
| `read_graph` | nodes, connections, keyframes, chosen input values — for self-verification |
| `delete_node` | remove a node |
| `smoke_test` | the end-to-end check above |

## What Resolve's API does NOT expose (verified, not guessed)

Your instincts are right, and it's worse than just windows and the tracker.

**Color page — the big wall.** The API cannot: create or arrange Color-page
nodes, draw or read **Power Windows**, run or read the **tracker**, use
qualifiers, read back grade values (SetCDL exists but is write-only), or set
grade keyframes. Your CST-based pipeline (CST in → grade → CST out → look
LUT) is therefore not scriptable on the Color page — a script can apply a
LUT to a clip, save/apply stills and .drx looks, copy grades between clips,
and set CDL slope/offset/power/sat, and that is the whole list.

**The practical consequence for you is good news, though:** Fusion runs
*before* the Color page in Resolve's image pipeline. Effects this server
builds land upstream of your CST-in, so your grade keeps working exactly as
designed, and the Fusion comp sees the same S-Log3 image your CST expects.

**Fusion page — mostly open, with edges.** Creating tools, naming, wiring,
setting inputs, and keyframing via BezierSpline all work (that's this
server). Not reliably scriptable: kicking off a **Fusion Tracker node's
analysis pass** (you can add and configure the node; pressing its
track-forward button has no API), drawing Polygon mask *shapes* point-by-
point (possible in raw Fusion scripting but fiddly — treat as advanced),
and anything that is really a viewer interaction.

**Edit page.** No in-place trim, razor, slip, or move of existing clips —
the workaround is an interchange round-trip (export EDL/XML, transform,
import as a new timeline). Titles can't choose their video track at insert.

**Audio.** Nothing inside a track is adjustable: no clip volume, fades, EQ,
or level reads. Track add/remove only.

**Delivery** is well covered (render presets, queue, start/monitor) and so
is media management (import, bins, metadata, proxies).

## Troubleshooting

- `check_resolve.py` fails at step 3 → it prints the three causes in order
  of likelihood; it's almost always the External-scripting preference.
- Tools suddenly failing mid-session → Resolve was closed or the project
  switched; the server reconnects on the next call.
- `add_node` rejects a type → Fusion's internal ids differ from UI names
  (e.g. `TextPlus`, not "Text+"). Ask Claude for the id or check the Fusion
  documentation.
