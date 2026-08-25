#!/usr/bin/env python3
"""MCP server that drives DaVinci Resolve's scripting API — Fusion-first.

Register with Claude Code (from this folder):

    claude mcp add resolve -- python3 "$(pwd)/resolve_mcp.py"

Then, in any Claude Code session, describe an effect and let the model build
the Fusion comp with these tools. Standard library only; talks to Resolve
over Blackmagic's fusionscript bridge, which requires Resolve Studio running
with Preferences > System > General > External scripting = Local.

Design notes, so you can read this as a map rather than a mystery:
- Connection is lazy and self-healing: nothing touches Resolve until the
  first tool call, and a dead handle reconnects on the next one.
- In Fusion's scripting model, `SetInput(name, X)` does double duty: a
  number/string sets a value, a tool object CONNECTS that tool's output.
  connect_nodes and set_node_input both ride on it.
- Keyframes: an input must carry a BezierSpline modifier before it can hold
  keys. animate_input attaches one, then SetInput(name, value, frame) per
  key. read_graph reads keys back via the spline's GetKeyFrames().
- Everything the server writes to stdout is MCP JSON-RPC, one compact object
  per line; diagnostics go to stderr. That is the protocol contract.
"""
import json
import os
import sys
import traceback

API_CANDIDATES = [
    "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting",
    os.path.expanduser("~/Library/Application Support/Blackmagic Design/"
                       "DaVinci Resolve/Developer/Scripting"),
]
LIB_CANDIDATES = [
    "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/"
    "Fusion/fusionscript.so",
]

_resolve = None


class ResolveError(Exception):
    """Raised with a plain-English, actionable message."""


def log(msg):
    sys.stderr.write("[resolve-mcp] %s\n" % msg)
    sys.stderr.flush()


def _bootstrap_env():
    api = os.environ.get("RESOLVE_SCRIPT_API") or next(
        (p for p in API_CANDIDATES if os.path.isdir(p)), None)
    lib = os.environ.get("RESOLVE_SCRIPT_LIB") or next(
        (p for p in LIB_CANDIDATES if os.path.isfile(p)), None)
    if not api or not lib:
        raise ResolveError(
            "Resolve's scripting API was not found on this Mac. Run "
            "check_resolve.py first — it pinpoints what is missing.")
    os.environ["RESOLVE_SCRIPT_API"] = api
    os.environ["RESOLVE_SCRIPT_LIB"] = lib
    modules = os.path.join(api, "Modules")
    if modules not in sys.path:
        sys.path.insert(0, modules)


def get_resolve():
    """Live Resolve handle; reconnects if Resolve was restarted."""
    global _resolve
    if _resolve is not None:
        try:
            _resolve.GetProductName()
            return _resolve
        except Exception:
            _resolve = None
    _bootstrap_env()
    import DaVinciResolveScript as dvr
    _resolve = dvr.scriptapp("Resolve")
    if _resolve is None:
        raise ResolveError(
            "Could not connect to Resolve. Is it running, is this Resolve "
            "STUDIO, and is Preferences > System > General > 'External "
            "scripting using' set to Local?")
    return _resolve


def get_project():
    project = get_resolve().GetProjectManager().GetCurrentProject()
    if project is None:
        raise ResolveError("No project is open in Resolve.")
    return project


def get_timeline():
    timeline = get_project().GetCurrentTimeline()
    if timeline is None:
        raise ResolveError("The project has no current timeline.")
    return timeline


def _current_item(clip_name=None):
    timeline = get_timeline()
    if clip_name:
        for track in range(1, int(timeline.GetTrackCount("video")) + 1):
            for item in timeline.GetItemListInTrack("video", track) or []:
                if item.GetName() == clip_name:
                    return item
        raise ResolveError("No video clip named %r on this timeline." % clip_name)
    item = timeline.GetCurrentVideoItem()
    if item is None:
        raise ResolveError("No clip under the playhead — park on one, or pass "
                           "clip_name.")
    return item


def get_comp(clip_name=None):
    """The clip's Fusion comp (created on first access), with Fusion page up
    so you can watch the graph grow."""
    item = _current_item(clip_name)
    get_resolve().OpenPage("fusion")
    count = int(item.GetFusionCompCount() or 0)
    comp = item.GetFusionCompByIndex(1) if count else item.AddFusionComp()
    if comp is None:
        raise ResolveError("Resolve returned no Fusion comp for %r."
                           % item.GetName())
    return comp, item


def _tool_name(tool):
    try:
        return tool.GetAttrs()["TOOLS_Name"]
    except Exception:
        return "?"


def find_tool(comp, name):
    for tool in (comp.GetToolList() or {}).values():
        if _tool_name(tool) == name:
            return tool
    raise ResolveError("No node named %r in this comp. read_graph lists what "
                       "exists." % name)


def _plain(value, depth=0):
    """Fusion proxies hand back tables/numbers/strings; make them JSON-safe."""
    if depth > 4:
        return str(value)
    if isinstance(value, (int, float, str, bool)) or value is None:
        return value
    try:
        return {str(k): _plain(v, depth + 1) for k, v in dict(value).items()}
    except Exception:
        return str(value)


def _input_by_id(tool, input_id):
    for inp in (tool.GetInputList() or {}).values():
        attrs = inp.GetAttrs() or {}
        if attrs.get("INPS_ID") == input_id or attrs.get("INPS_Name") == input_id:
            return inp
    return None


def _ensure_animated(comp, tool, input_id):
    """Attach a BezierSpline so the input can hold keyframes (the scripting
    equivalent of right-click > Animate)."""
    inp = _input_by_id(tool, input_id)
    if inp is not None and inp.GetConnectedOutput() is not None:
        return                              # already animated or connected
    spline = comp.BezierSpline()
    if spline is None:
        raise ResolveError("Could not create a BezierSpline modifier — this "
                           "Resolve build may name it differently. Tell me the "
                           "Resolve version and I'll adjust.")
    tool.SetInput(input_id, spline)


# ---------------------------------------------------------------------- tools
TOOLS = []


def tool(name, description, params=None, required=None):
    def wrap(fn):
        TOOLS.append({"name": name, "description": description,
                      "params": params or {}, "required": required or [],
                      "fn": fn})
        return fn
    return wrap


@tool("get_state", "Project, timeline, fps, current page and the clip under "
                   "the playhead — orient yourself before editing.")
def t_get_state():
    resolve = get_resolve()
    project = get_project()
    timeline = project.GetCurrentTimeline()
    out = {"product": "%s %s" % (resolve.GetProductName(),
                                 resolve.GetVersionString()),
           "project": project.GetName(), "page": resolve.GetCurrentPage()}
    if timeline:
        out["timeline"] = timeline.GetName()
        out["fps"] = timeline.GetSetting("timelineFrameRate")
        item = timeline.GetCurrentVideoItem()
        if item:
            out["current_clip"] = item.GetName()
    return out


@tool("list_clips", "Video clips on the current timeline, per track.")
def t_list_clips():
    timeline = get_timeline()
    out = []
    for track in range(1, int(timeline.GetTrackCount("video")) + 1):
        for item in timeline.GetItemListInTrack("video", track) or []:
            out.append({"track": track, "name": item.GetName(),
                        "start": item.GetStart(), "duration": item.GetDuration(),
                        "fusion_comps": int(item.GetFusionCompCount() or 0)})
    return {"clips": out}


@tool("open_comp",
      "Open a clip's Fusion comp (created if it has none) and list its nodes. "
      "Defaults to the clip under the playhead.",
      params={"clip_name": {"type": "string",
                            "description": "Optional exact clip name."}})
def t_open_comp(clip_name=None):
    comp, item = get_comp(clip_name)
    return {"clip": item.GetName(),
            "nodes": [_tool_name(t) for t in (comp.GetToolList() or {}).values()]}


@tool("add_node",
      "Add a Fusion node to the current clip's comp. tool_type is Fusion's "
      "internal id: Blur, Merge, Transform, Background, TextPlus, "
      "ColorCorrector, Glow, DirectionalBlur, SoftGlow, Polygon (mask), "
      "BrightnessContrast, ChannelBooleans, Tracker...",
      params={"tool_type": {"type": "string"},
              "name": {"type": "string", "description": "Optional node name."},
              "clip_name": {"type": "string"}},
      required=["tool_type"])
def t_add_node(tool_type, name=None, clip_name=None):
    comp, _ = get_comp(clip_name)
    node = comp.AddTool(str(tool_type), -32768, -32768)  # let Fusion place it
    if node is None:
        raise ResolveError("Fusion rejected tool type %r — the internal id "
                           "may differ from the UI name." % tool_type)
    if name:
        node.SetAttrs({"TOOLS_Name": str(name)})
    return {"added": _tool_name(node), "type": str(tool_type)}


@tool("connect_nodes",
      "Wire source node's output into dest node's input (default input "
      "'Input'; Merge uses 'Background'/'Foreground'; masks connect to "
      "'EffectMask').",
      params={"source": {"type": "string"}, "dest": {"type": "string"},
              "dest_input": {"type": "string"}, "clip_name": {"type": "string"}},
      required=["source", "dest"])
def t_connect_nodes(source, dest, dest_input="Input", clip_name=None):
    comp, _ = get_comp(clip_name)
    src = find_tool(comp, source)
    dst = find_tool(comp, dest)
    dst.SetInput(str(dest_input), src)
    inp = _input_by_id(dst, str(dest_input))
    ok = inp is not None and inp.GetConnectedOutput() is not None
    if not ok:
        raise ResolveError("Connection did not take — check the input name "
                           "with read_graph (include_inputs).")
    return {"connected": "%s -> %s.%s" % (source, dest, dest_input)}


@tool("set_node_input",
      "Set a node input to a static value. Numbers, strings and booleans "
      "pass through; colours are [r,g,b] or [r,g,b,a] floats 0-1 applied to "
      "the Red/Green/Blue(/Alpha) component inputs when the base name is "
      "given (e.g. 'TopLeft' colour on Background).",
      params={"node": {"type": "string"}, "input": {"type": "string"},
              "value": {"description": "number | string | bool | [r,g,b(,a)]"},
              "clip_name": {"type": "string"}},
      required=["node", "input", "value"])
def t_set_node_input(node, input, value, clip_name=None):
    comp, _ = get_comp(clip_name)
    target = find_tool(comp, node)
    if isinstance(value, list):
        channels = ["Red", "Green", "Blue", "Alpha"]
        for channel, component in zip(channels, value):
            target.SetInput("%s%s" % (input, channel), float(component))
        return {"set": "%s.%s%s" % (node, input, "RGBA"[:len(value)]),
                "value": value}
    target.SetInput(str(input), value)
    return {"set": "%s.%s" % (node, input), "value": value,
            "reads_back_as": _plain(target.GetInput(str(input)))}


@tool("animate_input",
      "Keyframe a node input: attaches a BezierSpline modifier if needed, "
      "then sets one key per {frame, value}. Frames are comp-local (comp "
      "time starts at the clip's first frame).",
      params={"node": {"type": "string"}, "input": {"type": "string"},
              "keyframes": {"type": "array",
                            "items": {"type": "object",
                                      "properties": {"frame": {"type": "number"},
                                                     "value": {"type": "number"}},
                                      "required": ["frame", "value"]}},
              "clip_name": {"type": "string"}},
      required=["node", "input", "keyframes"])
def t_animate_input(node, input, keyframes, clip_name=None):
    comp, _ = get_comp(clip_name)
    target = find_tool(comp, node)
    _ensure_animated(comp, target, str(input))
    for key in keyframes:
        target.SetInput(str(input), float(key["value"]), float(key["frame"]))
    return {"animated": "%s.%s" % (node, input), "keys": len(keyframes),
            "readback": _read_keys(target, str(input))}


def _read_keys(target, input_id):
    inp = _input_by_id(target, input_id)
    if inp is None:
        return None
    out = inp.GetConnectedOutput()
    if out is None:
        return None
    try:
        return _plain(out.GetTool().GetKeyFrames())
    except Exception:
        return None


@tool("read_graph",
      "The comp's node graph, for verifying your own work: every node with "
      "type and name, every connection, and (optionally) chosen input values "
      "and keyframes.",
      params={"include_inputs": {"type": "array", "items": {"type": "string"},
                                 "description": "Input ids to read on every "
                                                "node, e.g. ['Blur','Blend']."},
              "clip_name": {"type": "string"}})
def t_read_graph(include_inputs=None, clip_name=None):
    comp, item = get_comp(clip_name)
    nodes = []
    for tool_obj in (comp.GetToolList() or {}).values():
        attrs = tool_obj.GetAttrs() or {}
        entry = {"name": attrs.get("TOOLS_Name"),
                 "type": attrs.get("TOOLS_RegID")}
        connections = {}
        animated = {}
        for inp in (tool_obj.GetInputList() or {}).values():
            in_attrs = inp.GetAttrs() or {}
            in_id = in_attrs.get("INPS_ID")
            out = inp.GetConnectedOutput()
            if out is not None:
                src = out.GetTool()
                src_attrs = src.GetAttrs() or {}
                if src_attrs.get("TOOLS_RegID") == "BezierSpline":
                    animated[in_id] = _plain(src.GetKeyFrames())
                else:
                    connections[in_id] = src_attrs.get("TOOLS_Name")
        if connections:
            entry["connected"] = connections
        if animated:
            entry["keyframes"] = animated
        if include_inputs:
            values = {}
            for wanted in include_inputs:
                try:
                    values[wanted] = _plain(tool_obj.GetInput(str(wanted)))
                except Exception:
                    pass
            if values:
                entry["inputs"] = values
        nodes.append(entry)
    return {"clip": item.GetName(), "nodes": nodes}


@tool("delete_node", "Remove a node from the comp.",
      params={"node": {"type": "string"}, "clip_name": {"type": "string"}},
      required=["node"])
def t_delete_node(node, clip_name=None):
    comp, _ = get_comp(clip_name)
    find_tool(comp, node).Delete()
    return {"deleted": node}


@tool("smoke_test",
      "End-to-end self check on the clip under the playhead: add a Blur "
      "between MediaIn and MediaOut, set and keyframe its strength, read the "
      "graph back, verify every step, then remove the Blur. Leaves the comp "
      "as it was found.")
def t_smoke_test():
    comp, item = get_comp()
    report = {"clip": item.GetName(), "steps": []}

    def step(label, ok, detail=""):
        report["steps"].append({"step": label, "ok": bool(ok),
                                "detail": detail})
        if not ok:
            raise ResolveError("Smoke test failed at %r: %s\nReport so far: %s"
                               % (label, detail, json.dumps(report)))

    tools_by_type = {}
    for tool_obj in (comp.GetToolList() or {}).values():
        tools_by_type.setdefault((tool_obj.GetAttrs() or {}).get("TOOLS_RegID"),
                                 tool_obj)
    media_in = tools_by_type.get("MediaIn")
    media_out = tools_by_type.get("MediaOut")
    step("find MediaIn/MediaOut", media_in is not None and media_out is not None,
         "types present: %s" % sorted(k for k in tools_by_type if k))

    blur = comp.AddTool("Blur", -32768, -32768)
    step("add Blur", blur is not None)
    blur.SetAttrs({"TOOLS_Name": "SmokeTestBlur"})
    blur.SetInput("Input", media_in)
    media_out.SetInput("Input", blur)
    blur.SetInput("XBlurSize", 2.5)

    read = blur.GetInput("XBlurSize")
    step("static value round-trip", abs(float(read) - 2.5) < 0.001,
         "wrote 2.5, read %r" % read)

    _ensure_animated(comp, blur, "XBlurSize")
    blur.SetInput("XBlurSize", 0.0, 0)
    blur.SetInput("XBlurSize", 10.0, 24)
    keys = _read_keys(blur, "XBlurSize")
    step("keyframes round-trip", bool(keys) and len(keys) >= 2,
         "keys read back: %s" % json.dumps(keys)[:200])

    graph = t_read_graph(include_inputs=["XBlurSize"])
    names = [n.get("name") for n in graph["nodes"]]
    step("graph readback sees the Blur", "SmokeTestBlur" in names,
         "nodes: %s" % names)
    wired = any(n.get("name") == "SmokeTestBlur"
                and "MediaIn" in json.dumps(n.get("connected", {}))
                for n in graph["nodes"])
    step("connection readback", wired)

    media_out.SetInput("Input", media_in)     # restore original wiring
    blur.Delete()
    still_there = any(_tool_name(t) == "SmokeTestBlur"
                      for t in (comp.GetToolList() or {}).values())
    step("cleanup", not still_there)
    report["result"] = "PASS — the full write/read/verify loop works."
    return report


# ------------------------------------------------------------- MCP plumbing
# One compact JSON-RPC object per stdout line. Rules learned the hard way:
# id 0 is a real request ("id" in msg, not truthiness), params may be absent,
# notifications get NO reply, unknown protocolVersion falls back to a dated
# one, and nothing but protocol ever touches stdout.

def _schema(entry):
    return {"name": entry["name"], "description": entry["description"],
            "inputSchema": {"type": "object", "properties": entry["params"],
                            "required": entry["required"]}}


def _reply(msg_id, result=None, error=None):
    out = {"jsonrpc": "2.0", "id": msg_id}
    if error is not None:
        out["error"] = error
    else:
        out["result"] = result
    sys.stdout.write(json.dumps(out, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def main():
    log("serving %d Resolve tools over MCP stdio" % len(TOOLS))
    index = {t["name"]: t for t in TOOLS}
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            msg = json.loads(raw)
        except ValueError:
            continue
        if "id" not in msg:
            continue                        # notification: no reply, ever
        method = msg.get("method") or ""
        params = msg.get("params") or {}
        try:
            if method == "initialize":
                version = params.get("protocolVersion") or "2024-11-05"
                _reply(msg["id"], {
                    "protocolVersion": version,
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "resolve", "version": "1.0"}})
            elif method == "tools/list":
                _reply(msg["id"], {"tools": [_schema(t) for t in TOOLS]})
            elif method == "tools/call":
                entry = index.get((params.get("name") or ""))
                if entry is None:
                    _reply(msg["id"], {"content": [{"type": "text",
                                                    "text": "Unknown tool"}],
                                       "isError": True})
                    continue
                try:
                    result = entry["fn"](**(params.get("arguments") or {}))
                    text = json.dumps(result, default=str)
                    _reply(msg["id"], {"content": [{"type": "text",
                                                    "text": text}]})
                except ResolveError as exc:
                    _reply(msg["id"], {"content": [{"type": "text",
                                                    "text": str(exc)}],
                                       "isError": True})
                except Exception:
                    _reply(msg["id"], {"content": [
                        {"type": "text",
                         "text": "Crashed:\n%s" % traceback.format_exc(limit=5)}],
                        "isError": True})
            elif method == "ping":
                _reply(msg["id"], {})
            else:
                _reply(msg["id"], error={"code": -32601,
                                         "message": "Unknown method %s" % method})
        except Exception:
            log("handler error:\n%s" % traceback.format_exc(limit=5))


if __name__ == "__main__":
    main()
