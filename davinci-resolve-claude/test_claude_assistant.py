"""Mock-based smoke test for the Claude Assistant Resolve plugin.

Builds a fake Resolve object graph, imports the plugin, runs every tool,
and drives the agent loop against a scripted fake API.
"""
import importlib.util
import json
import os
import sys
import subprocess
import tempfile

PLUGIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "Claude Assistant.py")

spec = importlib.util.spec_from_file_location("claude_assistant", PLUGIN)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

FAILURES = []


def check(label, cond, detail=""):
    if cond:
        print("  ok  %s" % label)
    else:
        print("FAIL  %s  %s" % (label, detail))
        FAILURES.append((label, detail))


# ---------------------------------------------------------------- fake Resolve
class FakeMediaPoolItem:
    def __init__(self, name, props=None):
        self._name = name
        self._props = props or {"Duration": "00:00:10:00", "FPS": "24",
                                "Resolution": "1920x1080", "Type": "Video",
                                "File Path": "/media/%s" % name}

    def GetName(self):
        return self._name

    def GetClipProperty(self, key=None):
        if key is None:
            return dict(self._props)
        if key == "Frames":
            return "240"
        return self._props.get(key, "")


class FakeFolder:
    def __init__(self, name, clips=None, subs=None):
        self._name = name
        self._clips = clips or []
        self._subs = subs or []

    def GetName(self):
        return self._name

    def GetClipList(self):
        return list(self._clips)

    def GetSubFolderList(self):
        return list(self._subs)


class FakeMediaPool:
    def __init__(self, root):
        self._root = root
        self.appended = []
        self.imported = []
        self.created_timelines = []

    def GetRootFolder(self):
        return self._root

    def AddSubFolder(self, parent, name):
        f = FakeFolder(name)
        parent._subs.append(f)
        return f

    def CreateEmptyTimeline(self, name):
        tl = FakeTimeline(name)
        self.created_timelines.append(tl)
        PROJECT._timelines.append(tl)
        return tl

    def AppendToTimeline(self, clips):
        self.appended.extend(clips)
        return [object()] * len(clips)

    def ImportMedia(self, paths):
        items = [FakeMediaPoolItem(os.path.basename(p)) for p in paths]
        self.imported.extend(items)
        return items


class FakeGraph:
    def __init__(self):
        self.lut_calls = []

    def SetLUT(self, node, path):
        self.lut_calls.append((node, path))
        return True


class FakeTimelineItem:
    def __init__(self, name, start, end):
        self._name, self._start, self._end = name, start, end
        self.lut_calls = []
        self.graph = FakeGraph()

    def GetNodeGraph(self):
        return self.graph

    def GetName(self):
        return self._name

    def GetStart(self):
        return self._start

    def GetEnd(self):
        return self._end

    def GetDuration(self):
        return self._end - self._start

    def GetVersionNameList(self, vtype):
        return ["Version 1"]

    def SetLUT(self, node, path):
        self.lut_calls.append((node, path))
        return True


class FakeTimeline:
    def __init__(self, name, fps="24"):
        self._name = name
        self._fps = fps
        self._start = 86400  # 01:00:00:00 @ 24
        self._end = 86400 + 240
        self._markers = {}
        self._tc = "01:00:00:00"
        self._items = {("video", 1): [FakeTimelineItem("clipA", 86400, 86448),
                                      FakeTimelineItem("clipB", 86448, 86520)],
                       ("audio", 1): []}

    def GetName(self):
        return self._name

    def GetSetting(self, key):
        return self._fps if key == "timelineFrameRate" else ""

    def GetStartFrame(self):
        return self._start

    def GetStartTimecode(self):
        return "01:00:00:00"

    def GetEndFrame(self):
        return self._end

    def GetTrackCount(self, ttype):
        return {"video": 1, "audio": 1, "subtitle": 0}[ttype]

    def GetItemListInTrack(self, ttype, idx):
        return self._items.get((ttype, idx), [])

    def GetCurrentTimecode(self):
        return self._tc

    def SetCurrentTimecode(self, tc):
        self._tc = tc
        return True

    def GetCurrentVideoItem(self):
        return self._items[("video", 1)][0]

    def AddMarker(self, frame, color, name, note, duration, custom_data):
        # positional-only, all six args required — mirror the real API strictly
        if frame in self._markers:
            return False
        self._markers[frame] = {"color": color, "name": name, "note": note,
                                "duration": duration, "customData": custom_data}
        return True

    def GetMarkers(self):
        return dict(self._markers)

    def DeleteMarkerAtFrame(self, frame):
        return self._markers.pop(frame, None) is not None

    def DeleteMarkersByColor(self, color):
        n = len(self._markers)
        if color == "All":
            self._markers.clear()
        else:
            self._markers = {k: v for k, v in self._markers.items()
                             if v["color"] != color}
        return len(self._markers) != n


class FakeProject:
    def __init__(self):
        self._timelines = [FakeTimeline("Main TL"), FakeTimeline("Alt TL")]
        self._current = self._timelines[0]
        self._settings = {"timelineFrameRate": "24",
                          "timelineResolutionWidth": "1920",
                          "timelineResolutionHeight": "1080"}
        root = FakeFolder("Master",
                          clips=[FakeMediaPoolItem("clipA"), FakeMediaPoolItem("clipB")],
                          subs=[FakeFolder("B-roll", clips=[FakeMediaPoolItem("broll1")])])
        self._pool = FakeMediaPool(root)
        self.render_jobs = []
        self.rendering = False

    def GetName(self):
        return "Test Project"

    def GetSetting(self, key=""):
        if key in ("", None):
            return dict(self._settings)
        return self._settings.get(key, "")

    def SetSetting(self, k, v):
        self._settings[k] = v
        return True

    def GetTimelineCount(self):
        return len(self._timelines)

    def GetTimelineByIndex(self, i):
        return self._timelines[i - 1]

    def GetCurrentTimeline(self):
        return self._current

    def SetCurrentTimeline(self, tl):
        self._current = tl
        return True

    def GetMediaPool(self):
        return self._pool

    def GetRenderPresetList(self):
        return ["YouTube 1080p", "H.264 Master"]

    def LoadRenderPreset(self, name):
        return name in self.GetRenderPresetList()

    def SetRenderSettings(self, settings):
        self._render_settings = settings
        return True

    def AddRenderJob(self):
        jid = "job-%d" % (len(self.render_jobs) + 1)
        self.render_jobs.append({"JobId": jid, "RenderJobName": "Render 1",
                                 "TargetDir": "/out", "OutputFilename": "x.mov"})
        return jid

    def GetRenderJobList(self):
        return list(self.render_jobs)

    def GetRenderJobStatus(self, jid):
        return {"JobStatus": "Ready", "CompletionPercentage": 0}

    def StartRendering(self, *a, **k):
        self.rendering = bool(self.render_jobs)
        return self.rendering

    def IsRenderingInProgress(self):
        return False


class FakePM:
    def __init__(self, project):
        self._project = project

    def GetCurrentProject(self):
        return self._project

    def SaveProject(self):
        return True


class FakeResolve:
    def __init__(self, pm):
        self._pm = pm
        self.page = "edit"

    def GetProjectManager(self):
        return self._pm

    def GetVersionString(self):
        return "20.0.0"

    def GetCurrentPage(self):
        return self.page

    def OpenPage(self, p):
        self.page = p
        return True

    def Fusion(self):
        return None


PROJECT = FakeProject()
RESOLVE = FakeResolve(FakePM(PROJECT))
mod.STATE["app"] = mod.ResolveApp(RESOLVE)
mod.STATE["allow_python"] = True

print("== tool execution ==")
ok, out = mod.execute_tool("get_workspace_overview", {})
check("overview runs", ok, out)
d = json.loads(out)
check("overview current timeline", d.get("current_timeline", {}).get("name") == "Main TL", out)
check("overview start tc", d["current_timeline"]["start_timecode"] == "01:00:00:00", out)

ok, out = mod.execute_tool("open_page", {"page": "color"})
check("open_page", ok and RESOLVE.page == "color", out)

ok, out = mod.execute_tool("get_project_setting", {"name": "timelineFrameRate"})
check("get one setting", ok and json.loads(out) == {"timelineFrameRate": "24"}, out)
ok, out = mod.execute_tool("get_project_setting", {})
check("get all settings", ok and "timelineResolutionWidth" in json.loads(out), out)

ok, out = mod.execute_tool("set_project_setting", {"name": "timelineFrameRate", "value": "25"})
check("set setting", ok, out)
PROJECT._settings["timelineFrameRate"] = "24"

ok, out = mod.execute_tool("save_project", {})
check("save_project", ok, out)

ok, out = mod.execute_tool("get_timeline", {})
check("get_timeline current", ok and json.loads(out)["name"] == "Main TL", out)
ok, out = mod.execute_tool("get_timeline", {"name": "Alt TL"})
check("get_timeline by name", ok and json.loads(out)["name"] == "Alt TL", out)
ok, out = mod.execute_tool("get_timeline", {"name": "Nope"})
check("get_timeline missing errors", not ok and "No timeline named" in out, out)

ok, out = mod.execute_tool("list_timeline_items", {})
check("list items v1", ok and len(json.loads(out)["items"]) == 2, out)
d = json.loads(out)
check("item tc math", d["items"][0]["start_timecode"] == "01:00:00:00"
      and d["items"][0]["end_timecode"] == "01:00:02:00", out)
ok, out = mod.execute_tool("list_timeline_items", {"track_type": "video", "track_index": 7})
check("bad track errors", not ok, out)

ok, out = mod.execute_tool("add_marker", {"position": "01:00:01:00", "color": "red",
                                          "name": "Cut", "note": "check this"})
check("add_marker tc", ok, out)
d = json.loads(out)
check("marker frame offset", d["added_marker"]["frame_offset"] == 24, out)
check("marker color capitalized", d["added_marker"]["color"] == "Red", out)

ok, out = mod.execute_tool("add_marker", {"position": "48"})
check("add_marker frame offset", ok and json.loads(out)["added_marker"]["frame_offset"] == 48, out)
ok, out = mod.execute_tool("add_marker", {"position": "playhead", "color": "Blue"})
check("add_marker playhead", ok and json.loads(out)["added_marker"]["frame_offset"] == 0, out)
ok, out = mod.execute_tool("add_marker", {"position": "00:59:00:00"})
check("marker before start errors", not ok and "before the timeline start" in out, out)
ok, out = mod.execute_tool("add_marker", {"position": "01:00:01:00"})
check("duplicate marker errors", not ok, out)
ok, out = mod.execute_tool("add_marker", {"position": "10", "color": "Chartreuse"})
check("bad color errors", not ok and "Unknown marker color" in out, out)

ok, out = mod.execute_tool("list_markers", {})
check("list_markers", ok and len(json.loads(out)["markers"]) == 3, out)
d = json.loads(out)
check("marker list tc", d["markers"][1]["timecode"] == "01:00:01:00", out)

ok, out = mod.execute_tool("delete_markers", {"position": "01:00:01:00"})
check("delete one marker", ok, out)
ok, out = mod.execute_tool("delete_markers", {"color": "All"})
check("delete all markers", ok and json.loads(out)["deleted_count"] == 2, out)
ok, out = mod.execute_tool("delete_markers", {})
check("delete_markers no args errors", not ok, out)

ok, out = mod.execute_tool("create_timeline", {"name": "New TL"})
check("create_timeline", ok, out)
ok, out = mod.execute_tool("set_current_timeline", {"name": "Main TL"})
check("set_current_timeline", ok and PROJECT._current.GetName() == "Main TL", out)

ok, out = mod.execute_tool("move_playhead", {"timecode": "01:00:05:00"})
check("move_playhead", ok and json.loads(out)["playhead"] == "01:00:05:00", out)

ok, out = mod.execute_tool("list_media_pool", {})
check("list media root", ok, out)
d = json.loads(out)
check("root clips", [c["name"] for c in d["clips"]] == ["clipA", "clipB"], out)
check("root subfolders", d["subfolders"] == ["B-roll"], out)
ok, out = mod.execute_tool("list_media_pool", {"folder_path": "/B-roll"})
check("list subfolder", ok and json.loads(out)["clips"][0]["name"] == "broll1", out)
ok, out = mod.execute_tool("list_media_pool", {"folder_path": "/", "include_subfolders": True})
check("recursive listing", ok and len(json.loads(out)["clips"]) == 3, out)
ok, out = mod.execute_tool("list_media_pool", {"folder_path": "/Nope"})
check("missing folder errors", not ok, out)

ok, out = mod.execute_tool("get_clip_properties", {"clip_name": "broll1"})
check("clip props recursive find", ok and json.loads(out)["properties"]["FPS"] == "24", out)
ok, out = mod.execute_tool("get_clip_properties", {"clip_name": "ghost"})
check("missing clip errors", not ok and "not found" in out, out)

ok, out = mod.execute_tool("create_media_pool_folder", {"name": "Bin X"})
check("create bin", ok, out)

tmp = tempfile.NamedTemporaryFile(suffix=".mov", delete=False)
tmp.close()
ok, out = mod.execute_tool("import_media", {"paths": [tmp.name]})
check("import_media", ok, out)
os.unlink(tmp.name)
ok, out = mod.execute_tool("import_media", {"paths": ["/no/such/file.mov"]})
check("import missing path errors", not ok, out)

ok, out = mod.execute_tool("append_to_timeline", {"clip_names": ["clipA", "broll1"]})
check("append_to_timeline", ok and len(PROJECT._pool.appended) == 2, out)

ok, out = mod.execute_tool("get_current_video_item", {})
check("current video item", ok and json.loads(out)["name"] == "clipA", out)

ok, out = mod.execute_tool("apply_lut_to_current_clip", {"lut_path": "/luts/film.cube"})
check("apply lut", ok, out)
cur_item = PROJECT._current._items[("video", 1)][0]
check("lut via node graph", cur_item.graph.lut_calls == [(1, "/luts/film.cube")]
      and cur_item.lut_calls == [], str(cur_item.graph.lut_calls))

ok, out = mod.execute_tool("list_render_presets", {})
check("render presets", ok and "YouTube 1080p" in json.loads(out)["presets"], out)
ok, out = mod.execute_tool("add_render_job", {"preset_name": "YouTube 1080p",
                                              "target_dir": "/out", "custom_name": "final"})
check("add render job", ok and json.loads(out)["job_id"] == "job-1", out)
ok, out = mod.execute_tool("add_render_job", {"preset_name": "Nope"})
check("bad preset errors", not ok, out)
ok, out = mod.execute_tool("start_render", {})
check("start_render", ok, out)
ok, out = mod.execute_tool("get_render_status", {})
check("render status", ok and json.loads(out)["jobs"][0]["status"] == "Ready", out)

ok, out = mod.execute_tool("run_python", {"code": "print('hi'); result = {'n': 1+1}"})
check("run_python", ok, out)
d = json.loads(out)
check("run_python stdout+result", d["stdout"].strip() == "hi" and d["result"] == {"n": 2}, out)
mod.STATE["allow_python"] = False
ok, out = mod.execute_tool("run_python", {"code": "print(1)"})
check("run_python gated", not ok and "disabled" in out, out)
mod.STATE["allow_python"] = True
ok, out = mod.execute_tool("run_python", {"code": "raise ValueError('boom')"})
check("run_python exception reported", not ok and "ValueError" in out, out)

ok, out = mod.execute_tool("nonexistent_tool", {})
check("unknown tool", not ok and "Unknown tool" in out, out)
ok, out = mod.execute_tool("add_marker", {"position": "10", "bogus_arg": 1})
check("bad kwargs handled", not ok and "Bad arguments" in out, out)

print("== schemas ==")
schemas = mod.tool_schemas()
check("schema count", len(schemas) == len(mod.TOOLS), str(len(schemas)))
for s in schemas:
    bad = not s["name"] or not s["description"] or s["input_schema"]["type"] != "object"
    if bad:
        check("schema %s" % s["name"], False, json.dumps(s))
names = [s["name"] for s in schemas]
check("unique tool names", len(names) == len(set(names)), str(names))
check("schemas json-serializable", bool(json.dumps(schemas)))

print("== payload builder ==")
p, betas = mod._build_payload("claude-opus-5", [{"role": "user", "content": "hi"}])
check("opus5 thinking adaptive", p.get("thinking") == {"type": "adaptive"}, str(p.get("thinking")))
check("opus5 fallbacks", p.get("fallbacks") == "default" and
      "server-side-fallback-2026-07-01" in betas, str(betas))
check("system cache_control", p["system"][0]["cache_control"] == {"type": "ephemeral"})
p, betas = mod._build_payload("claude-haiku-4-5", [])
check("haiku no thinking", "thinking" not in p, str(p.keys()))
check("haiku no fallbacks", "fallbacks" not in p and not betas, str(betas))
p, betas = mod._build_payload("claude-sonnet-5", [])
check("sonnet thinking, no fallbacks", p.get("thinking") and "fallbacks" not in p, str(p))

print("== agent loop ==")


def scripted_api(responses):
    it = iter(responses)

    def fake(api_key, model, messages):
        fake.calls.append([json.loads(json.dumps(m)) for m in messages])
        return next(it)
    fake.calls = []
    return fake


def run_turn(responses, text="do things"):
    mod.STATE["messages"] = []
    events = []
    real = mod.call_claude
    mod.call_claude = scripted_api(responses)
    try:
        mod.run_agent_turn_api("key", "claude-opus-5", text,
                               lambda kind, t: events.append((kind, t)))
    finally:
        fake = mod.call_claude
        mod.call_claude = real
    return events, fake.calls


# simple text response
events, calls = run_turn([{"content": [{"type": "text", "text": "Hello!"}],
                           "stop_reason": "end_turn"}])
check("text turn emits assistant", ("assistant", "Hello!") in events, str(events))
check("context block attached", "<resolve_context>" in calls[0][0]["content"][1]["text"],
      json.dumps(calls[0][0]))
check("history has assistant", mod.STATE["messages"][-1]["role"] == "assistant")

# tool_use round then final text; two parallel tool calls in one response
PROJECT._current._markers.clear()
events, calls = run_turn([
    {"content": [
        {"type": "text", "text": "Adding markers."},
        {"type": "tool_use", "id": "tu_1", "name": "add_marker",
         "input": {"position": "01:00:01:00", "color": "Red"}},
        {"type": "tool_use", "id": "tu_2", "name": "add_marker",
         "input": {"position": "01:00:02:00", "color": "Blue"}},
     ], "stop_reason": "tool_use"},
    {"content": [{"type": "text", "text": "Done — 2 markers added."}],
     "stop_reason": "end_turn"},
])
check("both tools executed", len(PROJECT._current._markers) == 2,
      str(PROJECT._current._markers))
second_call_last = calls[1][-1]
check("tool_results single user msg",
      second_call_last["role"] == "user" and
      len(second_call_last["content"]) == 2 and
      all(b["type"] == "tool_result" for b in second_call_last["content"]),
      json.dumps(second_call_last))
check("tool_use ids preserved",
      [b["tool_use_id"] for b in second_call_last["content"]] == ["tu_1", "tu_2"],
      json.dumps(second_call_last))
check("final text emitted", ("assistant", "Done — 2 markers added.") in events, str(events))

# tool error propagates as is_error
events, calls = run_turn([
    {"content": [{"type": "tool_use", "id": "tu_9", "name": "get_timeline",
                  "input": {"name": "Ghost"}}], "stop_reason": "tool_use"},
    {"content": [{"type": "text", "text": "That timeline doesn't exist."}],
     "stop_reason": "end_turn"},
])
err_block = calls[1][-1]["content"][0]
check("tool error is_error", err_block.get("is_error") is True, json.dumps(err_block))

# refusal
events, _ = run_turn([{"content": [], "stop_reason": "refusal",
                       "stop_details": {"type": "refusal", "category": "cyber"}}])
check("refusal notice", any(k == "notice" and "declined" in t for k, t in events), str(events))
check("refusal leaves no empty assistant msg",
      all(m["role"] != "assistant" or m["content"] for m in mod.STATE["messages"]),
      json.dumps(mod.STATE["messages"]))
# conversation must continue after a refusal without a 400-shaped history
real = mod.call_claude
mod.call_claude = scripted_api([{"content": [{"type": "text", "text": "later"}],
                                 "stop_reason": "end_turn"}])
ev2 = []
mod.run_agent_turn_api("key", "claude-opus-5", "next question", lambda k, t: ev2.append((k, t)))
sent = mod.call_claude.calls[0]
mod.call_claude = real
check("post-refusal history valid",
      all(m["content"] for m in sent) and ("assistant", "later") in ev2,
      json.dumps(sent))

# empty pause_turn must not loop forever
events, calls = run_turn([{"content": [], "stop_reason": "pause_turn"}])
check("empty pause_turn bails", len(calls) == 1 and
      any(k == "notice" for k, t in events), str(events))

# mid-output fallback echo sanitization
fb_content = [
    {"type": "thinking", "thinking": "", "signature": "s1"},
    {"type": "tool_use", "id": "tu_x", "name": "list_markers", "input": {}},
    {"type": "text", "text": "partial answer"},
    {"type": "fallback", "from": {"model": "claude-opus-5"}, "to": {"model": "claude-opus-4-8"}},
    {"type": "text", "text": "continued answer"},
]
clean = mod._sanitize_assistant_content(fb_content)
check("fallback sanitize drops pre-boundary thinking/tool_use",
      [b["type"] for b in clean] == ["text", "fallback", "text"], json.dumps(clean))
no_fb = [{"type": "thinking", "thinking": "", "signature": "s"},
         {"type": "text", "text": "x"}]
check("sanitize no-op without fallback", mod._sanitize_assistant_content(no_fb) is no_fb)

# get_timeline by name with no current timeline open
saved_current = PROJECT._current
PROJECT._current = None
ok, out = mod.execute_tool("get_timeline", {"name": "Alt TL"})
check("get_timeline works with no current timeline",
      ok and json.loads(out)["playhead"] is None, out)
PROJECT._current = saved_current

# max_tokens
events, _ = run_turn([{"content": [{"type": "text", "text": "partial"}],
                       "stop_reason": "max_tokens"}])
check("max_tokens notice", any(k == "notice" and "length limit" in t for k, t in events),
      str(events))

# pause_turn continues
events, calls = run_turn([
    {"content": [{"type": "text", "text": "working"}], "stop_reason": "pause_turn"},
    {"content": [{"type": "text", "text": "done"}], "stop_reason": "end_turn"},
])
check("pause_turn re-calls", len(calls) == 2 and ("assistant", "done") in events, str(events))

# api error surfaces
mod.STATE["messages"] = []
real = mod.call_claude


def boom(*a):
    raise mod.ApiError("HTTP 500: nope")


mod.call_claude = boom
ev = []
mod.run_agent_turn_api("key", "claude-opus-5", "x", lambda k, t: ev.append((k, t)))
mod.call_claude = real
check("api error emitted", ("error", "HTTP 500: nope") in ev, str(ev))

# thinking blocks preserved in history
events, calls = run_turn([
    {"content": [
        {"type": "thinking", "thinking": "", "signature": "sig=="},
        {"type": "tool_use", "id": "tu_t", "name": "list_markers", "input": {}},
     ], "stop_reason": "tool_use"},
    {"content": [{"type": "text", "text": "ok"}], "stop_reason": "end_turn"},
])
assistant_msg = calls[1][-2]
check("thinking block echoed back",
      assistant_msg["role"] == "assistant" and
      assistant_msg["content"][0]["type"] == "thinking" and
      assistant_msg["content"][0]["signature"] == "sig==",
      json.dumps(assistant_msg))

print("== misc ==")
app = mod.STATE["app"]
check("tc round trip", app.abs_frame_to_tc(app.tc_to_abs_frame("01:02:03:04", 24.0), 24.0)
      == "01:02:03:04")
check("tc 23.976 nominal", app.tc_to_abs_frame("00:00:01:00", 23.976) == 24)
h = mod._render_markdownish("hi <b>x</b> `code` **bold**\n```python\nprint(1)\n```tail")
check("html escaped", "&lt;b&gt;" in h, h)
check("code block pre", "<pre" in h and "print(1)" in h, h)
check("inline code", "<code" in h, h)

check("_strip_none", mod._strip_none({"a": None, "b": [{"c": None, "d": 1}]}) ==
      {"b": [{"d": 1}]})
check("_short_json truncates", mod._short_json({"k": "x" * 500}).endswith("…"))

# config round-trip in a temp HOME
old_env = dict(os.environ)
with tempfile.TemporaryDirectory() as td:
    os.environ["HOME"] = td
    os.environ.pop("APPDATA", None)
    cfg = {"api_key": "sk-test", "model": "claude-opus-5"}
    mod.save_config(cfg)
    check("config saved", os.path.exists(mod.config_path()), mod.config_path())
    check("config perms", oct(os.stat(mod.config_path()).st_mode & 0o777) == "0o600")
    check("config loads", mod.load_config() == cfg)
    os.environ.pop("ANTHROPIC_API_KEY", None)
    check("get_api_key from cfg", mod.get_api_key(cfg) == "sk-test")
    os.environ["ANTHROPIC_API_KEY"] = "sk-env"
    check("env key wins", mod.get_api_key(cfg) == "sk-env")
os.environ.clear()
os.environ.update(old_env)

# ------------------------------------------------------- claude code backend
print("== claude code backend ==")

# -- backend selection --------------------------------------------------------
os.environ.pop("CLAUDE_RESOLVE_BACKEND", None)
mod._binary_cache.clear()
check("explicit cfg backend wins",
      mod.get_backend({"backend": "api"}) == mod.BACKEND_API)
os.environ["CLAUDE_RESOLVE_BACKEND"] = "claude-code"
check("env backend overrides cfg",
      mod.get_backend({"backend": "api"}) == mod.BACKEND_CLAUDE_CODE)
os.environ.pop("CLAUDE_RESOLVE_BACKEND", None)

mod._binary_cache["claude"] = "/fake/claude"
check("auto-detect prefers CLI when present",
      mod.get_backend({}) == mod.BACKEND_CLAUDE_CODE)
mod._binary_cache["claude"] = ""
check("falls back to api without CLI", mod.get_backend({}) == mod.BACKEND_API)

# -- the subscription guarantee ----------------------------------------------
os.environ["ANTHROPIC_API_KEY"] = "sk-should-not-leak"
os.environ["ANTHROPIC_AUTH_TOKEN"] = "tok-should-not-leak"
child_env = mod.claude_code_env()
check("API key stripped from CLI env", "ANTHROPIC_API_KEY" not in child_env)
check("auth token stripped from CLI env", "ANTHROPIC_AUTH_TOKEN" not in child_env)
os.environ.pop("ANTHROPIC_AUTH_TOKEN", None)

# -- command line -------------------------------------------------------------
mod._binary_cache["claude"] = "/fake/claude"
mod._binary_cache["python"] = "/fake/python3"


class StubBridge:
    port = 51234
    token = "stub-token"


argv = mod.build_claude_code_argv({}, "claude-opus-5", "hello", StubBridge())
check("uses print mode", "-p" in argv and "hello" in argv)
check("streams json", argv[argv.index("--output-format") + 1] == "stream-json")
check("ignores user MCP config", "--strict-mcp-config" in argv)
check("allowlists only resolve tools",
      argv[argv.index("--allowedTools") + 1] == "mcp__resolve__*")
check("disables built-in tools", argv[argv.index("--tools") + 1] == "")
check("never passes --bare", "--bare" not in argv)
check("no resume on first turn", "--resume" not in argv)

resumed = mod.build_claude_code_argv({}, "claude-opus-5", "hi", StubBridge(), "sess-1")
check("resumes a session", resumed[resumed.index("--resume") + 1] == "sess-1")

mcp_cfg = json.loads(argv[argv.index("--mcp-config") + 1])
server = mcp_cfg["mcpServers"]["resolve"]
check("mcp server is stdio", server["type"] == "stdio")
check("bridge runs this plugin", server["args"][-1] == mod.MCP_BRIDGE_FLAG)
check("bridge path absolute", os.path.isabs(server["args"][0]))
check("bridge port passed explicitly",
      server["env"][mod.BRIDGE_ENV_PORT] == "51234")
check("bridge token passed explicitly",
      server["env"][mod.BRIDGE_ENV_TOKEN] == "stub-token")

# -- MCP tool catalogue -------------------------------------------------------
schemas = mod.mcp_tool_schemas()
check("mcp catalogue complete", len(schemas) == len(mod.TOOLS))
check("mcp uses inputSchema key", all("inputSchema" in s for s in schemas))
check("mcp schemas are objects",
      all(s["inputSchema"].get("type") == "object" for s in schemas))

# -- stream event translation -------------------------------------------------
mod.STATE["cc_session_id"] = None
mod._handle_claude_code_event(
    {"type": "system", "subtype": "init", "session_id": "abc",
     "mcp_servers": [{"name": "resolve", "status": "connected"}]}, lambda k, t: None)
check("captures session id", mod.STATE["cc_session_id"] == "abc")

ev = []
mod._handle_claude_code_event(
    {"type": "system", "subtype": "init", "session_id": "abc",
     "mcp_servers": [{"name": "resolve", "status": "failed"}]},
    lambda k, t: ev.append((k, t)))
check("warns when bridge fails to connect",
      any(k == "notice" for k, _ in ev), str(ev))

ev = []
mod._handle_claude_code_event(
    {"type": "assistant", "message": {"content": [
        {"type": "text", "text": "done"},
        {"type": "tool_use", "name": "mcp__resolve__add_marker", "input": {"color": "Red"}},
    ]}}, lambda k, t: ev.append((k, t)))
check("emits assistant text", ("assistant", "done") in ev, str(ev))
check("strips mcp prefix in tool label",
      any(k == "tool" and t.startswith("add_marker(") for k, t in ev), str(ev))

ev = []
mod._handle_claude_code_event({"type": "result", "is_error": True, "result": "boom"},
                              lambda k, t: ev.append((k, t)))
check("surfaces result errors", ("error", "boom") in ev, str(ev))

# -- bridge + MCP server, spoken for real over stdio --------------------------
CALLS = []
_real_execute = mod.execute_tool
mod.execute_tool = lambda n, i: (CALLS.append((n, i)), (True, json.dumps({"ok": n})))[1]
bridge = mod.ToolBridge()
try:
    reply = mod._bridge_request(bridge.port, bridge.token, {"op": "list"})
    check("bridge lists tools", reply["ok"] and len(reply["tools"]) == len(mod.TOOLS))
    denied = mod._bridge_request(bridge.port, "wrong", {"op": "list"})
    check("bridge rejects bad token", denied["ok"] is False, str(denied))

    proc = subprocess.Popen(
        [sys.executable, PLUGIN, mod.MCP_BRIDGE_FLAG],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env=dict(os.environ, **{mod.BRIDGE_ENV_PORT: str(bridge.port),
                                mod.BRIDGE_ENV_TOKEN: bridge.token}))

    def rpc(obj):
        proc.stdin.write((json.dumps(obj) + "\n").encode())
        proc.stdin.flush()

    def read():
        return json.loads(proc.stdout.readline().decode())

    # id 0 is a real request id, not a notification — the classic hang.
    rpc({"jsonrpc": "2.0", "id": 0, "method": "initialize",
         "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                    "clientInfo": {"name": "test", "version": "1"}}})
    init = read()
    check("initialize answers id 0", init.get("id") == 0, str(init))
    check("echoes protocol version",
          init["result"]["protocolVersion"] == "2025-06-18", str(init))
    check("declares tools capability", "tools" in init["result"]["capabilities"])

    rpc({"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": {"protocolVersion": "1999-01-01", "capabilities": {}}})
    check("falls back on unknown protocol version",
          read()["result"]["protocolVersion"] == mod.MCP_FALLBACK_VERSION)

    # A notification must draw no reply at all; prove it by pipelining a request
    # behind it and checking the next line answers the request.
    rpc({"jsonrpc": "2.0", "method": "notifications/initialized"})
    rpc({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})   # note: no "params"
    listed = read()
    check("notification draws no reply", listed.get("id") == 2, str(listed))
    check("tools/list works without params",
          len(listed["result"]["tools"]) == len(mod.TOOLS), str(listed)[:200])

    rpc({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "list_markers", "arguments": {}}})
    called = read()
    check("tools/call round-trips through the bridge",
          called["result"]["content"][0]["text"] == json.dumps({"ok": "list_markers"}),
          str(called))
    check("successful call not flagged as error",
          called["result"]["isError"] is False)
    check("bridge executed the real tool", CALLS and CALLS[-1][0] == "list_markers")

    rpc({"jsonrpc": "2.0", "id": 4, "method": "ping"})
    check("ping answered", read()["result"] == {})

    rpc({"jsonrpc": "2.0", "id": 5, "method": "no/such/method"})
    check("unknown method -> -32601", read()["error"]["code"] == -32601)

    proc.stdin.close()
    proc.wait(timeout=10)
    check("exits cleanly on EOF", proc.returncode == 0, str(proc.returncode))
finally:
    mod.execute_tool = _real_execute
    bridge.close()

# close() must actually stop the listener. A blocked accept() does not wake when
# the socket is closed from another thread, so this regressed once already.
import socket as _socket
_b = mod.ToolBridge()
_port = _b.port
_b.close()
check("close() stops the accept thread", not _b._thread.is_alive())
try:
    _socket.create_connection(("127.0.0.1", _port), timeout=2).close()
    check("close() refuses new connections", False, "port still accepting")
except Exception:
    check("close() refuses new connections", True)

os.environ.clear()
os.environ.update(old_env)

print()
if FAILURES:
    print("%d FAILURES" % len(FAILURES))
    sys.exit(1)
print("ALL CHECKS PASSED (%s tools registered)" % len(mod.TOOLS))
