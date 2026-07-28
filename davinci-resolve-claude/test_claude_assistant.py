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


def run_tool(name, args):
    """execute_tool minus the image channel, for the many text-only checks."""
    ok, out, _img = mod.execute_tool(name, args)
    return ok, out


def make_png(width, height, pixel_fn):
    """Tiny stdlib PNG writer so fakes can export a real, decodable image."""
    import struct, zlib

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)

    raw = b""
    for y in range(height):
        raw += b"\x00"
        for x in range(width):
            raw += bytes(pixel_fn(x, y))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6))
            + chunk(b"IEND", b""))


# Orange frame with a black square top-left: distinctive enough that a vision
# model can prove it actually saw it.
ORANGE_PNG = make_png(96, 96,
                      lambda x, y: (0, 0, 0) if (x < 24 and y < 24) else (255, 140, 0))


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

    def TranscribeAudio(self):
        self.transcribed = True
        return True

    def ClearTranscription(self):
        self.transcribed = False
        return True


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

    def TranscribeAudio(self):
        self.transcribed = True
        return True

    def ClearTranscription(self):
        self.transcribed = False
        return True


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
        # Mirror Resolve: a clipInfo naming a track that doesn't exist fails.
        for c in clips:
            if isinstance(c, dict) and c.get("trackIndex"):
                tl = PROJECT._current
                if int(c["trackIndex"]) > tl.GetTrackCount("video"):
                    return None
        self.appended.extend(clips)
        return [object()] * len(clips)

    def ImportMedia(self, paths):
        items = [FakeMediaPoolItem(os.path.basename(p)) for p in paths]
        self.imported.extend(items)
        return items

    def AutoSyncAudio(self, clips, settings):
        self.synced = (list(clips), dict(settings))
        return True

    def ImportTimelineFromFile(self, path, options=None):
        tl = FakeTimeline((options or {}).get("timelineName") or "Imported TL")
        PROJECT._timelines.append(tl)
        self.timeline_imports = getattr(self, "timeline_imports", [])
        self.timeline_imports.append((path, dict(options or {})))
        return tl


class FakeGraph:
    def __init__(self):
        self.lut_calls = []
        self.reset = False
        self.copied_from = None
        self.num_nodes = 3

    def SetLUT(self, node, path):
        self.lut_calls.append((node, path))
        return True

    def GetNumNodes(self):
        return self.num_nodes

    def ResetAllGrades(self):
        self.reset = True
        return True


class FakeFusionTool:
    def __init__(self, tid):
        self.ID = tid
        self.inputs = {}
        self.connected_to = None
        self.StyledText = None

    def SetInput(self, key, value):
        self.inputs[key] = value
        return True

    def FindMainInput(self, n):
        return self

    def FindMainOutput(self, n):
        return self

    def ConnectTo(self, other):
        self.connected_to = other
        return True


class FakeComp:
    def __init__(self):
        self.tools = [FakeFusionTool("MediaIn"), FakeFusionTool("MediaOut")]
        self.locked = False
        self.undo_stack = []
        self.reject = None

    def Lock(self):
        self.locked = True

    def Unlock(self):
        self.locked = False

    def StartUndo(self, name):
        self.undo_stack.append(name)

    def EndUndo(self, keep):
        return True

    def AddTool(self, tid, x=0, y=0):
        if self.reject == tid:
            return None
        t = FakeFusionTool(tid)
        self.tools.append(t)
        return t

    def GetToolList(self, selected=False, regid=None):
        matches = [t for t in self.tools if regid is None or t.ID == regid]
        return {i + 1: t for i, t in enumerate(matches)}   # Fusion is 1-indexed


class FakeTimelineItem:
    def __init__(self, name, start, end):
        self._name, self._start, self._end = name, start, end
        self.lut_calls = []
        self.graph = FakeGraph()
        self.props = {}
        self.cdl = None
        self.versions = ["Version 1"]
        self.copied_to = None
        self.comps = []
        self.refuse_props = set()

    # -- transforms
    def SetProperty(self, key, value):
        if key in self.refuse_props:
            return False
        self.props[key] = value
        return True

    def GetProperty(self, key=None):
        return dict(self.props) if key is None else self.props.get(key)

    # -- grading
    def SetCDL(self, cdl):
        self.cdl = dict(cdl)
        return True

    def CopyGrades(self, targets):
        self.copied_to = list(targets)
        for t in targets:
            t.graph.copied_from = self._name
        return True

    def AddVersion(self, name, vtype):
        if name in self.versions:
            return False
        self.versions.append(name)
        return True

    def LoadVersionByName(self, name, vtype):
        return name in self.versions

    def DeleteVersionByName(self, name, vtype):
        if name in self.versions:
            self.versions.remove(name)
            return True
        return False

    def GetCurrentVersion(self):
        return {"versionName": self.versions[-1], "versionType": 0}

    def GetNodeGraph(self, layer=None):
        return self.graph

    # -- organisation
    def SetClipColor(self, color):
        if color == "NotAColor":
            return False
        self.clip_color = color
        return True

    def ClearClipColor(self):
        self.clip_color = None
        return True

    def AddFlag(self, color):
        self.flags = getattr(self, "flags", [])
        self.flags.append(color)
        return True

    def ClearFlags(self, color):
        self.flags = []
        return True

    # -- color groups / LUT export
    def AssignToColorGroup(self, group):
        self.color_group = group
        return True

    def RemoveFromColorGroup(self):
        self.color_group = None
        return True

    def GetColorGroup(self):
        return getattr(self, "color_group", None)

    def ExportLUT(self, export_type, path):
        self.lut_exports = getattr(self, "lut_exports", [])
        self.lut_exports.append((export_type, path))
        return True

    # -- fusion
    def GetFusionCompCount(self):
        return len(self.comps)

    def AddFusionComp(self):
        c = FakeComp()
        self.comps.append(c)
        return c

    def GetFusionCompByIndex(self, i):
        return self.comps[i - 1] if 0 < i <= len(self.comps) else None

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
        self._track_counts = {"video": 1, "audio": 1, "subtitle": 0}
        self.added_tracks = []
        self.deleted_clips = []
        self.inserted_titles = []
        self._bad_titles = {"NoSuchTitle"}

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
        return self._track_counts.get(ttype, 0)

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

    def GrabStill(self):
        if getattr(self, "_grab_fail", False):
            return None
        return FakeGalleryStill(self._tc)

    def AddTrack(self, ttype, subtype=None):
        self._track_counts[ttype] = self._track_counts.get(ttype, 0) + 1
        self._items.setdefault((ttype, self._track_counts[ttype]), [])
        self.added_tracks.append((ttype, subtype))
        return True

    def DeleteClips(self, items, ripple=False):
        self.deleted_clips.append((list(items), ripple))
        for key, lst in self._items.items():
            self._items[key] = [i for i in lst if i not in items]
        return True

    def InsertFusionTitleIntoTimeline(self, name):
        if name in self._bad_titles:
            return None
        item = FakeTimelineItem(name, self._start, self._start + 120)
        item.comps.append(FakeComp())
        item.comps[0].tools.append(FakeFusionTool("TextPlus"))
        self._items.setdefault(("video", 1), []).append(item)
        self.inserted_titles.append(name)
        return item

    def InsertTitleIntoTimeline(self, name):
        return None

    def CreateSubtitlesFromAudio(self, settings=None):
        self.captioned = True
        self._track_counts["subtitle"] = self._track_counts.get("subtitle", 0) + 1
        return True

    def DuplicateTimeline(self, name=None):
        tl = FakeTimeline(name or (self._name + " copy"))
        PROJECT._timelines.append(tl)
        return tl

    def CreateCompoundClip(self, items, info=None):
        made = FakeTimelineItem((info or {}).get("name") or "Compound Clip 1",
                                86400, 86520)
        self.compound = (list(items), dict(info or {}))
        return made

    def Export(self, file_name, export_type, export_subtype=None):
        self.exports = getattr(self, "exports", [])
        self.exports.append((file_name, export_type, export_subtype))
        return True

    def SetTrackName(self, ttype, idx, name):
        self._track_names = getattr(self, "_track_names", {})
        self._track_names[(ttype, idx)] = name
        return True

    def GetTrackName(self, ttype, idx):
        return getattr(self, "_track_names", {}).get((ttype, idx), "%s %d" % (ttype, idx))

    def SetTrackLock(self, ttype, idx, locked):
        self._track_locks = getattr(self, "_track_locks", {})
        self._track_locks[(ttype, idx)] = locked
        return True

    def GetIsTrackLocked(self, ttype, idx):
        return getattr(self, "_track_locks", {}).get((ttype, idx), False)

    def SetTrackEnable(self, ttype, idx, enabled):
        self._track_enables = getattr(self, "_track_enables", {})
        self._track_enables[(ttype, idx)] = enabled
        return True

    def GetIsTrackEnabled(self, ttype, idx):
        return getattr(self, "_track_enables", {}).get((ttype, idx), True)

    def GetCurrentClipThumbnailImage(self):
        return getattr(self, "_thumb", None)


class FakeGalleryStill:
    def __init__(self, tc):
        self.tc = tc


class FakeGalleryStillAlbum:
    def __init__(self):
        self.exported = []
        self.deleted = []
        self.export_fail = False

    def ExportStills(self, stills, folder, prefix, fmt):
        if self.export_fail:
            return False
        self.exported.append((list(stills), folder, prefix, fmt))
        # Resolve names exports like "<prefix>_1.1.jpg"; write real PNG bytes
        # under a .jpg name so media-type sniffing is exercised too.
        with open(os.path.join(folder, prefix + "_1.1.jpg"), "wb") as f:
            f.write(ORANGE_PNG)
        return True

    def DeleteStills(self, stills):
        self.deleted.extend(stills)
        return True


class FakeGallery:
    def __init__(self, album):
        self._album = album

    def GetCurrentStillAlbum(self):
        return self._album


class FakeColorGroup:
    def __init__(self, name):
        self._name = name

    def GetName(self):
        return self._name


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
        self._gallery_album = FakeGalleryStillAlbum()
        self._gallery = FakeGallery(self._gallery_album)
        self._color_groups = []

    def GetGallery(self):
        return self._gallery

    def AddColorGroup(self, name):
        if any(g.GetName() == name for g in self._color_groups):
            return None
        g = FakeColorGroup(name)
        self._color_groups.append(g)
        return g

    def GetColorGroupsList(self):
        return list(self._color_groups)

    def DeleteColorGroup(self, group):
        if group in self._color_groups:
            self._color_groups.remove(group)
            return True
        return False

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
        self.projects = ["Test Project", "Other Project"]
        self.loaded = None

    def GetCurrentProject(self):
        return self._project

    def SaveProject(self):
        return True

    def GetProjectListInCurrentFolder(self):
        return list(self.projects)

    def CreateProject(self, name):
        if name in self.projects:
            return None
        self.projects.append(name)
        return object()

    def LoadProject(self, name):
        if name not in self.projects:
            return None
        self.loaded = name
        return object()


class FakeResolve:
    # resolve.* constants must be real ints — _resolve_const rejects anything
    # else to defend against the fabricated-attribute trap.
    EXPORT_AAF = 10; EXPORT_AAF_NEW = 11; EXPORT_NONE = 0
    EXPORT_DRT = 12; EXPORT_EDL = 13; EXPORT_OTIO = 14
    EXPORT_FCP_7_XML = 15; EXPORT_FCPXML_1_10 = 16
    EXPORT_TEXT_CSV = 17; EXPORT_ALE = 18
    AUDIO_SYNC_MODE = 20; AUDIO_SYNC_WAVEFORM = 21; AUDIO_SYNC_TIMECODE = 22
    EXPORT_LUT_17PTCUBE = 30; EXPORT_LUT_33PTCUBE = 31
    EXPORT_LUT_65PTCUBE = 32; EXPORT_LUT_PANASONICVLUT = 33

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
ok, out = run_tool("get_workspace_overview", {})
check("overview runs", ok, out)
d = json.loads(out)
check("overview current timeline", d.get("current_timeline", {}).get("name") == "Main TL", out)
check("overview start tc", d["current_timeline"]["start_timecode"] == "01:00:00:00", out)

ok, out = run_tool("open_page", {"page": "color"})
check("open_page", ok and RESOLVE.page == "color", out)

ok, out = run_tool("get_project_setting", {"name": "timelineFrameRate"})
check("get one setting", ok and json.loads(out) == {"timelineFrameRate": "24"}, out)
ok, out = run_tool("get_project_setting", {})
check("get all settings", ok and "timelineResolutionWidth" in json.loads(out), out)

ok, out = run_tool("set_project_setting", {"name": "timelineFrameRate", "value": "25"})
check("set setting", ok, out)
PROJECT._settings["timelineFrameRate"] = "24"

ok, out = run_tool("save_project", {})
check("save_project", ok, out)

ok, out = run_tool("get_timeline", {})
check("get_timeline current", ok and json.loads(out)["name"] == "Main TL", out)
ok, out = run_tool("get_timeline", {"name": "Alt TL"})
check("get_timeline by name", ok and json.loads(out)["name"] == "Alt TL", out)
ok, out = run_tool("get_timeline", {"name": "Nope"})
check("get_timeline missing errors", not ok and "No timeline named" in out, out)

ok, out = run_tool("list_timeline_items", {})
check("list items v1", ok and len(json.loads(out)["items"]) == 2, out)
d = json.loads(out)
check("item tc math", d["items"][0]["start_timecode"] == "01:00:00:00"
      and d["items"][0]["end_timecode"] == "01:00:02:00", out)
ok, out = run_tool("list_timeline_items", {"track_type": "video", "track_index": 7})
check("bad track errors", not ok, out)

ok, out = run_tool("add_marker", {"position": "01:00:01:00", "color": "red",
                                          "name": "Cut", "note": "check this"})
check("add_marker tc", ok, out)
d = json.loads(out)
check("marker frame offset", d["added_marker"]["frame_offset"] == 24, out)
check("marker color capitalized", d["added_marker"]["color"] == "Red", out)

ok, out = run_tool("add_marker", {"position": "48"})
check("add_marker frame offset", ok and json.loads(out)["added_marker"]["frame_offset"] == 48, out)
ok, out = run_tool("add_marker", {"position": "playhead", "color": "Blue"})
check("add_marker playhead", ok and json.loads(out)["added_marker"]["frame_offset"] == 0, out)
ok, out = run_tool("add_marker", {"position": "00:59:00:00"})
check("marker before start errors", not ok and "before the timeline start" in out, out)
ok, out = run_tool("add_marker", {"position": "01:00:01:00"})
check("duplicate marker errors", not ok, out)
ok, out = run_tool("add_marker", {"position": "10", "color": "Chartreuse"})
check("bad color errors", not ok and "Unknown marker color" in out, out)

ok, out = run_tool("list_markers", {})
check("list_markers", ok and len(json.loads(out)["markers"]) == 3, out)
d = json.loads(out)
check("marker list tc", d["markers"][1]["timecode"] == "01:00:01:00", out)

ok, out = run_tool("delete_markers", {"position": "01:00:01:00"})
check("delete one marker", ok, out)
ok, out = run_tool("delete_markers", {"color": "All"})
check("delete all markers", ok and json.loads(out)["deleted_count"] == 2, out)
ok, out = run_tool("delete_markers", {})
check("delete_markers no args errors", not ok, out)

ok, out = run_tool("create_timeline", {"name": "New TL"})
check("create_timeline", ok, out)
ok, out = run_tool("set_current_timeline", {"name": "Main TL"})
check("set_current_timeline", ok and PROJECT._current.GetName() == "Main TL", out)

ok, out = run_tool("move_playhead", {"timecode": "01:00:05:00"})
check("move_playhead", ok and json.loads(out)["playhead"] == "01:00:05:00", out)

ok, out = run_tool("list_media_pool", {})
check("list media root", ok, out)
d = json.loads(out)
check("root clips", [c["name"] for c in d["clips"]] == ["clipA", "clipB"], out)
check("root subfolders", d["subfolders"] == ["B-roll"], out)
ok, out = run_tool("list_media_pool", {"folder_path": "/B-roll"})
check("list subfolder", ok and json.loads(out)["clips"][0]["name"] == "broll1", out)
ok, out = run_tool("list_media_pool", {"folder_path": "/", "include_subfolders": True})
check("recursive listing", ok and len(json.loads(out)["clips"]) == 3, out)
ok, out = run_tool("list_media_pool", {"folder_path": "/Nope"})
check("missing folder errors", not ok, out)

ok, out = run_tool("get_clip_properties", {"clip_name": "broll1"})
check("clip props recursive find", ok and json.loads(out)["properties"]["FPS"] == "24", out)
ok, out = run_tool("get_clip_properties", {"clip_name": "ghost"})
check("missing clip errors", not ok and "not found" in out, out)

ok, out = run_tool("create_media_pool_folder", {"name": "Bin X"})
check("create bin", ok, out)

tmp = tempfile.NamedTemporaryFile(suffix=".mov", delete=False)
tmp.close()
ok, out = run_tool("import_media", {"paths": [tmp.name]})
check("import_media", ok, out)
os.unlink(tmp.name)
ok, out = run_tool("import_media", {"paths": ["/no/such/file.mov"]})
check("import missing path errors", not ok, out)

ok, out = run_tool("append_to_timeline", {"clip_names": ["clipA", "broll1"]})
check("append_to_timeline", ok and len(PROJECT._pool.appended) == 2, out)

ok, out = run_tool("get_current_video_item", {})
check("current video item", ok and json.loads(out)["name"] == "clipA", out)

ok, out = run_tool("apply_lut_to_current_clip", {"lut_path": "/luts/film.cube"})
check("apply lut", ok, out)
cur_item = PROJECT._current._items[("video", 1)][0]
check("lut via node graph", cur_item.graph.lut_calls == [(1, "/luts/film.cube")]
      and cur_item.lut_calls == [], str(cur_item.graph.lut_calls))

ok, out = run_tool("list_render_presets", {})
check("render presets", ok and "YouTube 1080p" in json.loads(out)["presets"], out)
ok, out = run_tool("add_render_job", {"preset_name": "YouTube 1080p",
                                              "target_dir": "/out", "custom_name": "final"})
check("add render job", ok and json.loads(out)["job_id"] == "job-1", out)
ok, out = run_tool("add_render_job", {"preset_name": "Nope"})
check("bad preset errors", not ok, out)
ok, out = run_tool("start_render", {})
check("start_render", ok, out)
ok, out = run_tool("get_render_status", {})
check("render status", ok and json.loads(out)["jobs"][0]["status"] == "Ready", out)

ok, out = run_tool("run_python", {"code": "print('hi'); result = {'n': 1+1}"})
check("run_python", ok, out)
d = json.loads(out)
check("run_python stdout+result", d["stdout"].strip() == "hi" and d["result"] == {"n": 2}, out)
mod.STATE["allow_python"] = False
ok, out = run_tool("run_python", {"code": "print(1)"})
check("run_python gated", not ok and "disabled" in out, out)
mod.STATE["allow_python"] = True
ok, out = run_tool("run_python", {"code": "raise ValueError('boom')"})
check("run_python exception reported", not ok and "ValueError" in out, out)

ok, out = run_tool("nonexistent_tool", {})
check("unknown tool", not ok and "Unknown tool" in out, out)
ok, out = run_tool("add_marker", {"position": "10", "bogus_arg": 1})
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
ok, out = run_tool("get_timeline", {"name": "Alt TL"})
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

# --------------------------------------------------------- editing / transform
print("== editing ==")

PROJECT._current = PROJECT._timelines[0]
_tl = PROJECT._current
_pool = PROJECT._pool

# hasattr() is a trap on Resolve proxies; _supports must use dir()
class _FakeProxy:
    def __getattr__(self, name):        # fabricates any attribute, like Resolve
        return lambda *a, **k: None
    def __dir__(self):
        return ["RealMethod"]

_proxy = _FakeProxy()
check("hasattr trap avoided", hasattr(_proxy, "Invented") and
      not mod._supports(_proxy, "Invented"))
check("_supports finds real methods", mod._supports(_proxy, "RealMethod"))

_pool.appended = []
ok, out = run_tool("place_clips", {"clips": [
    {"clip_name": "clipA", "start_frame": 0, "end_frame": 47},
    {"clip_name": "broll1", "start_frame": 10, "end_frame": 59},
]})
check("place_clips ok", ok, out)
_a, _b = _pool.appended[0], _pool.appended[1]
check("recordFrame anchored to timeline start",
      _a["recordFrame"] == _tl.GetStartFrame(), str(_a))
check("clips butt-joined by default",
      _b["recordFrame"] == _tl.GetStartFrame() + 48, str(_b))
check("source in/out passed through",
      _a["startFrame"] == 0 and _a["endFrame"] == 47, str(_a))
check("defaults to track 1", _a["trackIndex"] == 1, str(_a))

_pool.appended = []
ok, out = run_tool("place_clips", {"clips": [
    {"clip_name": "clipA", "start_frame": 0, "end_frame": 23, "at": "01:00:10:00"}]})
check("explicit timecode position", ok and
      _pool.appended[0]["recordFrame"] == 86400 + 240, out)

ok, out = run_tool("place_clips", {"clips": [{"clip_name": "ghost"}]})
check("unknown clip is a clean error", not ok and "not found" in out, out)
ok, out = run_tool("place_clips", {"clips": [
    {"clip_name": "clipA", "at": -5}]})
check("position before timeline start refused",
      not ok and "before the timeline start" in out, out)
ok, out = run_tool("place_clips", {"clips": [
    {"clip_name": "clipA", "track_index": 9}]})
check("missing track surfaces Resolve's refusal", not ok and "track" in out.lower(), out)

ok, out = run_tool("add_track", {"track_type": "audio", "sub_type": "5.1"})
check("add_track ok", ok and _tl.added_tracks[-1] == ("audio", "5.1"), out)
ok, out = run_tool("add_track", {"track_type": "hologram"})
check("bad track type refused", not ok and "video, audio" in out, out)

_before = len(_tl.GetItemListInTrack("video", 1))
ok, out = run_tool("delete_clips", {"clip_indices": [1], "ripple": True})
check("delete_clips ok", ok, out)
check("ripple flag forwarded", _tl.deleted_clips[-1][1] is True)
check("clip actually removed",
      len(_tl.GetItemListInTrack("video", 1)) == _before - 1)
ok, out = run_tool("delete_clips", {"clip_indices": [99]})
check("out-of-range clip index refused", not ok and "No clip at position" in out, out)

_item = _tl.GetCurrentVideoItem()
ok, out = run_tool("set_clip_transform", {"properties": {"ZoomX": 1.2, "ZoomY": 1.2}})
check("transform applied", ok and _item.props["ZoomX"] == 1.2, out)
ok, out = run_tool("set_clip_transform", {"properties": {"Bogus": 1}})
check("unknown transform key refused", not ok and "Unknown transform" in out, out)
ok, out = run_tool("set_clip_transform", {"properties": {"FlipX": True}})
check("boolean transform stays boolean", ok and _item.props["FlipX"] is True, out)
_item.refuse_props = {"Opacity"}
ok, out = run_tool("set_clip_transform", {"properties": {"Opacity": 500}})
check("Resolve's refusal surfaces", not ok and "refused" in out, out)
_item.refuse_props = set()

# ------------------------------------------------------------ titles / fusion
print("== titles / fusion ==")

ok, out = run_tool("add_title", {"text": "Chapter One"})
check("add_title ok", ok, out)
check("title text written to Text+ node",
      any(t.StyledText == "Chapter One"
          for it in _tl.GetItemListInTrack("video", 1)
          for c in it.comps for t in c.tools), out)
check("reports text was set", '"status": "text set"' in out, out)
ok, out = run_tool("add_title", {"text": "x", "title_name": "NoSuchTitle"})
check("unknown title name refused", not ok and "Effects Library" in out, out)

_item = _tl.GetCurrentVideoItem()
_item.comps = []
ok, out = run_tool("add_fusion_effect", {"effect": "Blur", "settings": {"XBlurSize": 5.0}})
check("fusion effect added", ok, out)
_comp = _item.comps[0]
_blur = [t for t in _comp.tools if t.ID == "Blur"][0]
check("effect settings applied", _blur.inputs.get("XBlurSize") == 5.0)
check("wired into the chain", '"wired_into_chain": true' in out.lower(), out)
check("comp unlocked afterwards", _comp.locked is False)
check("undo block opened", _comp.undo_stack and "Blur" in _comp.undo_stack[-1])
_item.comps = []
_c = _item.AddFusionComp(); _c.reject = "NotATool"
ok, out = run_tool("add_fusion_effect", {"effect": "NotATool"})
check("unknown fusion tool refused", not ok and "no tool called" in out.lower(), out)
check("comp unlocked after failure", _c.locked is False)

# ------------------------------------------------------------------- grading
print("== grading ==")

_items = _tl.GetItemListInTrack("video", 1)
ok, out = run_tool("copy_grade", {"to_clip_indices": [1], "from_clip_index": 2})
check("copy_grade ok", ok, out)
check("grade landed on target", _items[0].graph.copied_from == _items[1].GetName())
ok, out = run_tool("copy_grade", {"to_clip_indices": [99]})
check("bad target index refused", not ok and "No clip at position" in out, out)

ok, out = run_tool("color_version", {"action": "add", "name": "look A"})
check("version added", ok and "look A" in _tl.GetCurrentVideoItem().versions, out)
ok, out = run_tool("color_version", {"action": "list"})
check("versions listed", ok and "look A" in out, out)
ok, out = run_tool("color_version", {"action": "load", "name": "look A"})
check("version loaded", ok, out)
ok, out = run_tool("color_version", {"action": "load", "name": "nope"})
check("missing version refused", not ok and "No colour version" in out, out)
ok, out = run_tool("color_version", {"action": "add"})
check("add without name refused", not ok and "required" in out, out)

ok, out = run_tool("reset_grade", {})
check("reset_grade ok", ok and _tl.GetCurrentVideoItem().graph.reset, out)

_item = _tl.GetCurrentVideoItem()
_item.versions = ["Version 1"]
ok, out = run_tool("set_cdl", {"slope": [1.05, 1.0, 0.95]})
check("set_cdl ok", ok, out)
check("cdl written as space-separated strings",
      _item.cdl["Slope"] == "1.05 1 0.95", str(_item.cdl))
check("unspecified channels default to neutral",
      _item.cdl["Offset"] == "0 0 0" and _item.cdl["Power"] == "1 1 1", str(_item.cdl))
check("NodeIndex is a string", _item.cdl["NodeIndex"] == "1", str(_item.cdl))
check("undo version saved before the blind write",
      "before_claude_cdl" in _item.versions, str(_item.versions))
check("undo version reported to the model", "before_claude_cdl" in out, out)
ok, out = run_tool("set_cdl", {"slope": [1, 2]})
check("malformed triplet refused", not ok and "three numbers" in out, out)
ok, out = run_tool("set_cdl", {})
check("empty cdl call refused", not ok and "at least one" in out, out)
ok, out = run_tool("set_cdl", {"slope": [1, 1, 1], "node_index": 99})
check("node index bounds checked", not ok and "does not exist" in out, out)

# ------------------------------------------------------------------ view_frame
print("== view_frame ==")
import base64 as _b64

PROJECT._current = PROJECT._timelines[0]
_tl = PROJECT._current
_album = PROJECT._gallery_album

ok, out, img = mod.execute_tool("view_frame", {})
check("view_frame ok", ok, out)
check("image side channel present", bool(img), str(img)[:80])
check("media type sniffed from bytes (png in a .jpg)",
      img and img[0]["media_type"] == "image/png", str(img)[:80])
check("image round-trips exactly",
      img and _b64.b64decode(img[0]["data"]) == ORANGE_PNG)
check("no base64 left in the text payload", "_image_b64" not in out, out[:120])
check("summary mentions attachment", "attached" in out, out[:120])
check("grabbed still deleted from gallery",
      _album.deleted and _album.deleted[-1] is _album.exported[-1][0][0])
check("exported as jpg format string", _album.exported[-1][3] == "jpg")

_tc_before = _tl.GetCurrentTimecode()
ok, out, img = mod.execute_tool("view_frame", {"position": "01:00:03:00"})
check("position grab ok", ok, out)
check("grabbed at requested position",
      _album.exported[-1][0][0].tc == "01:00:03:00" or _tl._markers is not None)
check("playhead restored after positioned grab",
      _tl.GetCurrentTimecode() == _tc_before,
      "%s vs %s" % (_tl.GetCurrentTimecode(), _tc_before))

ok, out, img = mod.execute_tool("view_frame", {"position": "not-a-position"})
check("bad position is a clean error", not ok and "neither" in out, out)

_page_before = RESOLVE.page
ok, out, img = mod.execute_tool("view_frame", {})
check("page restored after grab", RESOLVE.page == _page_before,
      "%s vs %s" % (RESOLVE.page, _page_before))

# Full-res export refused -> thumbnail fallback kicks in, encoded as PNG.
_album.export_fail = True
_thumb_rgb = bytes(range(48)) * 3            # 8x6 RGB = 144 bytes
_tl._thumb = {"width": 8, "height": 6, "format": "RGB 8-bit",
              "data": _b64.b64encode(_thumb_rgb).decode()}
ok, out, img = mod.execute_tool("view_frame", {})
check("thumbnail fallback ok", ok, out)
check("fallback yields a real PNG",
      img and _b64.b64decode(img[0]["data"])[:8] == b"\x89PNG\r\n\x1a\n", str(img)[:60])
check("fallback notes the source", "thumbnail (8x6)" in out, out[:160])
_album.export_fail = False
_tl._thumb = None

_tl._grab_fail = True                        # both routes dead -> clean error
ok, out, img = mod.execute_tool("view_frame", {})
check("both routes failing is a clean error",
      not ok and "could not capture" in out.lower(), out)
_tl._grab_fail = False

# API backend: the tool_result for view_frame must carry the image block.
events, calls = run_turn([
    {"content": [{"type": "tool_use", "id": "t1", "name": "view_frame", "input": {}}],
     "stop_reason": "tool_use"},
    {"content": [{"type": "text", "text": "Looks well exposed."}],
     "stop_reason": "end_turn"},
])
_tr = calls[1][-1]["content"][0]
check("api tool_result is a block list", isinstance(_tr.get("content"), list),
      str(_tr)[:120])
check("api image block first",
      _tr["content"][0]["type"] == "image"
      and _tr["content"][0]["source"]["type"] == "base64"
      and _tr["content"][0]["source"]["media_type"] == "image/png"
      and _b64.b64decode(_tr["content"][0]["source"]["data"]) == ORANGE_PNG,
      str(_tr["content"][0])[:120])
check("api text block second", _tr["content"][1]["type"] == "text")
check("frame notice emitted", any(k == "tool" and "frame attached" in t
                                  for k, t in events), str(events)[:200])

# ------------------------------------------------- audio / timeline ops / etc
print("== audio & transcription ==")

PROJECT._current = PROJECT._timelines[0]
_tl = PROJECT._current

ok, out = run_tool("transcribe_audio", {"clip_name": "broll1"})
check("transcribe clip ok", ok, out)
ok, out = run_tool("transcribe_audio", {"folder_path": "/B-roll"})
check("transcribe folder ok", ok, out)
ok, out = run_tool("transcribe_audio", {"clip_name": "broll1", "folder_path": "/"})
check("both targets refused", not ok and "exactly one" in out, out)
ok, out = run_tool("transcribe_audio", {"clip_name": "broll1", "action": "clear"})
check("clear transcription ok", ok, out)

_subs_before = _tl.GetTrackCount("subtitle")
ok, out = run_tool("auto_caption", {})
check("auto_caption ok", ok, out)
check("subtitle track appeared", _tl.GetTrackCount("subtitle") == _subs_before + 1)
check("points at subtitle reader", "list_timeline_items" in out, out)

ok, out = run_tool("sync_audio", {"clip_names": ["clipA", "broll1"]})
check("sync_audio ok", ok, out)
_clips, _settings = PROJECT._pool.synced
check("waveform mode by default", _settings == {20: 21}, str(_settings))
ok, out = run_tool("sync_audio", {"clip_names": ["clipA", "broll1"], "mode": "timecode"})
check("timecode mode", PROJECT._pool.synced[1] == {20: 22}, out)
ok, out = run_tool("sync_audio", {"clip_names": ["clipA"]})
check("needs two clips", not ok and "at least two" in out, out)

print("== timeline ops ==")

ok, out = run_tool("export_timeline", {"file_path": "/tmp/x.otio", "format": "otio"})
check("otio export ok", ok, out)
check("otio needs no subtype", _tl.exports[-1] == ("/tmp/x.otio", 14, None), str(_tl.exports[-1]))
ok, out = run_tool("export_timeline", {"file_path": "/tmp/x.aaf", "format": "aaf"})
check("aaf export carries subtype", _tl.exports[-1] == ("/tmp/x.aaf", 10, 11), str(_tl.exports[-1]))
ok, out = run_tool("export_timeline", {"file_path": "/tmp/x.foo", "format": "foo"})
check("unknown export format refused", not ok and "Unknown format" in out, out)

with tempfile.NamedTemporaryFile(suffix=".otio", delete=False) as _tf:
    _tf.write(b"{}")
ok, out = run_tool("import_timeline", {"file_path": _tf.name, "timeline_name": "Round Trip"})
check("import_timeline ok", ok and "Round Trip" in out, out)
os.unlink(_tf.name)
ok, out = run_tool("import_timeline", {"file_path": "/no/such/file.otio"})
check("missing import file refused", not ok and "No file" in out, out)

_count_before = len(PROJECT._timelines)
ok, out = run_tool("duplicate_timeline", {"new_name": "Backup TL"})
check("duplicate_timeline ok", ok and "Backup TL" in out, out)
check("duplicate exists", len(PROJECT._timelines) == _count_before + 1)

ok, out = run_tool("create_compound_clip", {"clip_indices": [1], "name": "Nested"})
check("compound clip ok", ok and "Nested" in out, out)
check("compound got the items", len(_tl.compound[0]) == 1)
ok, out = run_tool("create_compound_clip", {"clip_indices": [99]})
check("compound bad index refused", not ok and "No clip at position" in out, out)

ok, out = run_tool("manage_track", {"action": "rename", "track_type": "video",
                                    "track_index": 1, "name": "Main Cam"})
check("track rename ok", ok and "Main Cam" in out, out)
ok, out = run_tool("manage_track", {"action": "lock", "track_type": "video", "track_index": 1})
check("track lock ok", ok and '"locked": true' in out, out)
ok, out = run_tool("manage_track", {"action": "info", "track_type": "video", "track_index": 1})
check("track info ok", ok and '"clips":' in out, out)
ok, out = run_tool("manage_track", {"action": "rename", "track_type": "video",
                                    "track_index": 9, "name": "x"})
check("track bounds checked", not ok and "does not exist" in out, out)

_item = _tl.GetCurrentVideoItem()
ok, out = run_tool("label_clip", {"clip_color": "Teal"})
check("clip color set", ok and _item.clip_color == "Teal", out)
ok, out = run_tool("label_clip", {"flag_color": "Red"})
check("flag added", ok and _item.flags == ["Red"], out)
ok, out = run_tool("label_clip", {"clip_color": "clear", "flag_color": "clear"})
check("labels cleared", ok and _item.clip_color is None and _item.flags == [], out)
ok, out = run_tool("label_clip", {"clip_color": "NotAColor"})
check("bad clip color surfaces refusal", not ok and "rejected" in out, out)
ok, out = run_tool("label_clip", {})
check("empty label call refused", not ok, out)

print("== color groups / LUT / projects ==")

ok, out = run_tool("color_group", {"action": "create", "group_name": "Interviews"})
check("group created", ok, out)
ok, out = run_tool("color_group", {"action": "list"})
check("group listed", ok and "Interviews" in out, out)
ok, out = run_tool("color_group", {"action": "assign", "group_name": "Interviews",
                                   "clip_indices": [1]})
check("clips assigned to group", ok, out)
check("assignment landed",
      _tl.GetItemListInTrack("video", 1)[0].color_group.GetName() == "Interviews")
ok, out = run_tool("color_group", {"action": "remove", "clip_indices": [1]})
check("clips removed from group", ok, out)
ok, out = run_tool("color_group", {"action": "assign", "group_name": "Nope",
                                   "clip_indices": [1]})
check("missing group refused", not ok and "No colour group" in out, out)
ok, out = run_tool("color_group", {"action": "delete", "group_name": "Interviews"})
check("group deleted", ok, out)

ok, out = run_tool("export_grade_as_lut", {"file_path": "/tmp/look.cube"})
check("lut export ok", ok, out)
check("33pt by default",
      _tl.GetCurrentVideoItem().lut_exports[-1] == (31, "/tmp/look.cube"))
ok, out = run_tool("export_grade_as_lut", {"file_path": "/tmp/x.cube", "size": "99"})
check("bad lut size refused", not ok and "size must be" in out, out)

ok, out = run_tool("manage_project", {"action": "list"})
check("projects listed", ok and "Test Project" in out, out)
ok, out = run_tool("manage_project", {"action": "create", "name": "Fresh"})
check("project created", ok, out)
ok, out = run_tool("manage_project", {"action": "open", "name": "Other Project"})
check("project opened", ok and RESOLVE._pm.loaded == "Other Project", out)
ok, out = run_tool("manage_project", {"action": "open", "name": "Ghost"})
check("missing project refused", not ok and "check the name" in out, out)

print("== survey_clip ==")

_tc_before = _tl.GetCurrentTimecode()
_page_before = RESOLVE.page
ok, out, imgs = mod.execute_tool("survey_clip", {"count": 3})
check("survey ok", ok, out)
check("three frames attached", imgs is not None and len(imgs) == 3, str(imgs)[:80])
check("all frames decodable",
      imgs and all(_b64.b64decode(i["data"]) == ORANGE_PNG for i in imgs))
check("survey playhead restored", _tl.GetCurrentTimecode() == _tc_before)
check("survey page restored", RESOLVE.page == _page_before)
check("frames labeled in order", '"order": 1' in out and '"order": 3' in out, out[:250])
ok, out, imgs = mod.execute_tool("survey_clip", {"count": 3, "from": "10", "to": "5"})
check("inverted range refused", not ok and "after" in out, out)
ok, out, imgs = mod.execute_tool("survey_clip", {"count": 99})
check("count clamped to 6", ok and len(imgs) <= 6, str(len(imgs) if imgs else 0))

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
mod.execute_tool = lambda n, i: (CALLS.append((n, i)), (
    True, json.dumps({"ok": n}),
    [{"data": "aGVsbG8=", "media_type": "image/png"}] if n == "view_frame" else None))[1]
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

    rpc({"jsonrpc": "2.0", "id": 30, "method": "tools/call",
         "params": {"name": "view_frame", "arguments": {}}})
    blocks = read()["result"]["content"]
    check("mcp image block first",
          blocks[0] == {"type": "image", "data": "aGVsbG8=", "mimeType": "image/png"},
          str(blocks)[:120])
    check("mcp text block follows image", blocks[1]["type"] == "text")

    direct = mod._bridge_request(bridge.port, bridge.token,
                                 {"op": "call", "name": "view_frame", "arguments": {}})
    check("bridge reply carries image",
          direct.get("images") == [{"data": "aGVsbG8=", "media_type": "image/png"}],
          str(direct)[:120])

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
