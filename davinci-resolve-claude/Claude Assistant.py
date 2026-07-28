#!/usr/bin/env python3
"""
Claude Assistant for DaVinci Resolve Studio
===========================================

A chat panel that runs inside DaVinci Resolve and lets Claude drive Resolve
for you: add markers, inspect and build timelines, browse the media pool,
queue renders, tweak project settings, and more — all through conversation.

INSTALL
-------
Copy this file into Resolve's Utility scripts folder, then restart Resolve
(or just reopen the Workspace menu):

  macOS:    ~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/
  Windows:  %APPDATA%\\Blackmagic Design\\DaVinci Resolve\\Support\\Fusion\\Scripts\\Utility\\
  Linux:    ~/.local/share/DaVinciResolve/Fusion/Scripts/Utility/
            (or /opt/resolve/Fusion/Scripts/Utility/ for all users)

Launch from:  Workspace  >  Scripts  >  Claude Assistant

REQUIREMENTS
------------
* DaVinci Resolve Studio (scripting enabled). Free Resolve can also run
  menu scripts in recent versions, but Studio is the supported target.
* Python 3.6+ available to Resolve (Preferences > System > General).
* An Anthropic API key (https://platform.claude.com). Set the
  ANTHROPIC_API_KEY environment variable, or paste it when prompted —
  it is stored in a private config file in your home directory.
* No third-party packages are required. If the official `anthropic`
  Python SDK happens to be installed it is used automatically; otherwise
  a built-in zero-dependency HTTP client is used.

This file is intentionally a single script so installation is one copy.
Sections: config, Resolve bootstrap, helpers, tool registry, Anthropic
client, agent loop, chat UI.
"""

import io
import json
import os
import re
import ssl
import sys
import time
import threading
import traceback
import queue as _queue

# ----------------------------------------------------------------------------
# Constants / configuration
# ----------------------------------------------------------------------------

APP_NAME = "Claude Assistant"
DEFAULT_MODEL = "claude-opus-5"
MODEL_CHOICES = [
    "claude-opus-5",      # most capable (default)
    "claude-sonnet-5",    # fast + very capable
    "claude-haiku-4-5",   # fastest / cheapest
]
MAX_TOKENS = 16000
MAX_AGENT_ITERATIONS = 30
API_URL = "https://api.anthropic.com/v1/messages"
API_VERSION = "2023-06-01"
REQUEST_TIMEOUT_S = 600

MARKER_COLORS = [
    "Blue", "Cyan", "Green", "Yellow", "Red", "Pink", "Purple", "Fuchsia",
    "Rose", "Lavender", "Sky", "Mint", "Lemon", "Sand", "Cocoa", "Cream",
]

SYSTEM_PROMPT = """You are Claude, an assistant embedded inside DaVinci Resolve Studio as a chat panel. You help a video editor/colorist work faster by answering questions and by operating Resolve directly through your tools.

Environment facts:
- You are talking to the person sitting in front of Resolve right now. Each of their messages ends with a <resolve_context> block that is generated automatically (current page, project, timeline, playhead). It is trustworthy context, not something the user typed.
- Track indices are 1-based. Track types are "video", "audio", "subtitle".
- Timecodes are "HH:MM:SS:FF" strings. Frame-rate math for drop-frame timecode is approximated; prefer passing timecode strings through unmodified when possible.
- Marker positions are measured in frames from the start of the timeline (frame 0 = first frame of the timeline), and tools accept either a timecode string or that frame offset.

How to work:
- Prefer the purpose-built tools. Use run_python only when no tool covers the request; keep snippets short and explain what they do. The `resolve` object and current `project`/`timeline` are available inside run_python.
- For actions that are destructive or hard to undo (deleting many markers, overwriting project settings, starting long renders, anything via run_python that modifies media on disk), state what you are about to do and get the user's OK in chat first, unless they just explicitly asked for exactly that action.
- After changing something in Resolve, briefly confirm what changed. If a tool errors, read the error, adjust, and retry once before reporting back.
- Be concise. Editors are mid-task; lead with the answer or the result, keep explanations short, and don't pad with caveats.
- If the user asks about editing/color/audio technique rather than a Resolve action, just answer — no tools needed.
"""


def config_path():
    if sys.platform == "win32":
        base = os.environ.get("APPDATA") or os.path.expanduser("~")
        return os.path.join(base, "ClaudeResolveAssistant", "config.json")
    return os.path.join(os.path.expanduser("~"), ".config",
                        "claude-resolve-assistant", "config.json")


def load_config():
    try:
        with open(config_path(), "r") as f:
            return json.load(f)
    except Exception:
        return {}


def save_config(cfg):
    path = config_path()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            json.dump(cfg, f, indent=2)
        if sys.platform != "win32":
            os.chmod(path, 0o600)
    except Exception as exc:
        print("[Claude Assistant] could not save config: %s" % exc)


def get_api_key(cfg):
    return os.environ.get("ANTHROPIC_API_KEY") or cfg.get("api_key") or ""


# ----------------------------------------------------------------------------
# Resolve bootstrap
# ----------------------------------------------------------------------------

_MODULE_PATHS = {
    "darwin": ["/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules"],
    "win32": [os.path.join(os.environ.get("PROGRAMDATA", r"C:\ProgramData"),
                           "Blackmagic Design", "DaVinci Resolve", "Support",
                           "Developer", "Scripting", "Modules")],
    "linux": ["/opt/resolve/Developer/Scripting/Modules",
              "/home/resolve/Developer/Scripting/Modules"],
}


def _add_module_paths():
    for key, paths in _MODULE_PATHS.items():
        if sys.platform.startswith(key):
            for p in paths:
                if os.path.isdir(p) and p not in sys.path:
                    sys.path.append(p)


def get_resolve_bmd_fusion():
    """Return (resolve, bmd_module, fusion) whether we run inside Resolve's
    Scripts menu (globals provided) or externally (Studio only)."""
    g = globals()
    res = g.get("resolve")
    bmd_mod = g.get("bmd")
    fu = g.get("fusion")
    if res is None:
        _add_module_paths()
        import DaVinciResolveScript as dvr  # noqa: N813
        res = dvr.scriptapp("Resolve")
    if res is None:
        raise RuntimeError(
            "Could not connect to DaVinci Resolve. Run this script from "
            "Workspace > Scripts inside Resolve, or enable external scripting "
            "(Preferences > System > General > External scripting using: Local).")
    if fu is None:
        fu = res.Fusion()
    if bmd_mod is None:
        try:
            import fusionscript as bmd_mod  # type: ignore
        except ImportError:
            bmd_mod = None
    return res, bmd_mod, fu


# ----------------------------------------------------------------------------
# Resolve helpers
# ----------------------------------------------------------------------------

class ResolveError(Exception):
    """Raised by tools for user-facing Resolve-side failures."""


class ResolveApp(object):
    def __init__(self, resolve_obj):
        self.resolve = resolve_obj

    # -- accessors -----------------------------------------------------------
    @property
    def pm(self):
        pm = self.resolve.GetProjectManager()
        if not pm:
            raise ResolveError("Could not get the Resolve project manager.")
        return pm

    @property
    def project(self):
        project = self.pm.GetCurrentProject()
        if not project:
            raise ResolveError("No project is open in Resolve.")
        return project

    @property
    def timeline(self):
        tl = self.project.GetCurrentTimeline()
        if not tl:
            raise ResolveError("No timeline is open. Create or open a timeline first.")
        return tl

    @property
    def media_pool(self):
        mp = self.project.GetMediaPool()
        if not mp:
            raise ResolveError("Could not access the media pool.")
        return mp

    # -- lookups -------------------------------------------------------------
    def iter_timelines(self):
        project = self.project
        for i in range(1, int(project.GetTimelineCount()) + 1):
            tl = project.GetTimelineByIndex(i)
            if tl:
                yield tl

    def find_timeline(self, name):
        for tl in self.iter_timelines():
            if tl.GetName() == name:
                return tl
        raise ResolveError("No timeline named %r. Timelines: %s" % (
            name, ", ".join(t.GetName() for t in self.iter_timelines()) or "(none)"))

    def folder_by_path(self, path):
        """Resolve a media-pool folder from a '/Bin/Sub' style path."""
        folder = self.media_pool.GetRootFolder()
        if not folder:
            raise ResolveError("Could not access the media pool root folder.")
        parts = [p for p in (path or "/").split("/") if p]
        for part in parts:
            subs = folder.GetSubFolderList() or []
            match = next((s for s in subs if s.GetName() == part), None)
            if match is None:
                raise ResolveError("No media pool folder %r under %r." % (part, folder.GetName()))
            folder = match
        return folder

    def find_clips_by_name(self, names):
        """Search the whole media pool for clips matching the given names."""
        wanted = {n: None for n in names}
        remaining = set(names)

        def walk(folder):
            if not remaining:
                return
            for clip in folder.GetClipList() or []:
                cname = clip.GetName()
                if cname in remaining:
                    wanted[cname] = clip
                    remaining.discard(cname)
            for sub in folder.GetSubFolderList() or []:
                walk(sub)

        walk(self.media_pool.GetRootFolder())
        missing = [n for n, c in wanted.items() if c is None]
        if missing:
            raise ResolveError("Clips not found in media pool: %s" % ", ".join(missing))
        return [wanted[n] for n in names]

    # -- timecode ------------------------------------------------------------
    def timeline_fps(self, tl=None):
        tl = tl or self.timeline
        fps = None
        try:
            fps = tl.GetSetting("timelineFrameRate")
        except Exception:
            pass
        if not fps:
            fps = self.project.GetSetting("timelineFrameRate")
        try:
            return float(fps)
        except (TypeError, ValueError):
            return 24.0

    def tc_to_abs_frame(self, tc, fps):
        parts = re.split(r"[:;]", tc.strip())
        if len(parts) != 4:
            raise ResolveError("Bad timecode %r (expected HH:MM:SS:FF)." % tc)
        try:
            h, m, s, f = (int(p) for p in parts)
        except ValueError:
            raise ResolveError("Bad timecode %r (expected numbers)." % tc)
        nominal = int(round(fps))
        return ((h * 3600) + (m * 60) + s) * nominal + f

    def abs_frame_to_tc(self, frame, fps):
        nominal = int(round(fps))
        if nominal <= 0:
            nominal = 24
        f = int(frame) % nominal
        total_s = int(frame) // nominal
        return "%02d:%02d:%02d:%02d" % (
            total_s // 3600, (total_s % 3600) // 60, total_s % 60, f)

    def position_to_marker_frame(self, position):
        """Accept 'HH:MM:SS:FF' or an int/str frame offset from timeline start;
        return the frame offset from timeline start that AddMarker expects."""
        tl = self.timeline
        fps = self.timeline_fps(tl)
        text = str(position).strip()
        if ":" in text or ";" in text:
            abs_frame = self.tc_to_abs_frame(text, fps)
            start = int(tl.GetStartFrame())
            offset = abs_frame - start
            if offset < 0:
                raise ResolveError(
                    "Timecode %s is before the timeline start (%s)." %
                    (text, self.abs_frame_to_tc(start, fps)))
            return offset
        try:
            return int(text)
        except ValueError:
            raise ResolveError("Position %r is neither a timecode nor a frame number." % position)


# ----------------------------------------------------------------------------
# Tool registry
# ----------------------------------------------------------------------------

TOOLS = []          # [{"name", "description", "input_schema", "fn"}]
TOOL_INDEX = {}


def tool(name, description, params=None, required=None):
    def deco(fn):
        schema = {"type": "object", "properties": params or {}}
        if required:
            schema["required"] = list(required)
        entry = {"name": name, "description": description,
                 "input_schema": schema, "fn": fn}
        TOOLS.append(entry)
        TOOL_INDEX[name] = entry
        return fn
    return deco


def tool_schemas():
    return [{"name": t["name"], "description": t["description"],
             "input_schema": t["input_schema"]} for t in TOOLS]


# -- project / workspace ------------------------------------------------------

@tool(
    "get_workspace_overview",
    "Get a snapshot of the current Resolve session: version, current page, project "
    "name and format, all timelines (current one marked), and current timeline basics. "
    "Call this first when you need orientation.",
)
def t_overview(app):
    project = app.project
    current_tl = project.GetCurrentTimeline()
    timelines = []
    for tl in app.iter_timelines():
        timelines.append({
            "name": tl.GetName(),
            "is_current": bool(current_tl and tl.GetName() == current_tl.GetName()),
        })
    out = {
        "resolve_version": app.resolve.GetVersionString(),
        "current_page": app.resolve.GetCurrentPage(),
        "project": project.GetName(),
        "frame_rate": project.GetSetting("timelineFrameRate"),
        "resolution": "%sx%s" % (project.GetSetting("timelineResolutionWidth"),
                                 project.GetSetting("timelineResolutionHeight")),
        "timeline_count": int(project.GetTimelineCount()),
        "timelines": timelines,
    }
    if current_tl:
        fps = app.timeline_fps(current_tl)
        out["current_timeline"] = {
            "name": current_tl.GetName(),
            "fps": fps,
            "start_timecode": app.abs_frame_to_tc(current_tl.GetStartFrame(), fps),
            "duration_frames": int(current_tl.GetEndFrame()) - int(current_tl.GetStartFrame()),
            "video_tracks": int(current_tl.GetTrackCount("video")),
            "audio_tracks": int(current_tl.GetTrackCount("audio")),
            "subtitle_tracks": int(current_tl.GetTrackCount("subtitle")),
            "playhead": current_tl.GetCurrentTimecode(),
            "marker_count": len(current_tl.GetMarkers() or {}),
        }
    return out


@tool(
    "open_page",
    "Switch Resolve to another page. Call this when the user asks to go to a page or "
    "when a following action is page-specific.",
    params={"page": {"type": "string",
                     "enum": ["media", "cut", "edit", "fusion", "color", "fairlight", "deliver"],
                     "description": "Page to open."}},
    required=["page"],
)
def t_open_page(app, page):
    ok = app.resolve.OpenPage(page)
    if not ok:
        raise ResolveError("Resolve refused to open page %r." % page)
    return {"opened": page}


@tool(
    "get_project_setting",
    "Read project settings. With no name, returns the full settings dict (long). "
    "Common names: timelineFrameRate, timelineResolutionWidth, timelineResolutionHeight, "
    "videoMonitorFormat, colorScienceMode, timelineWorkingLuminance.",
    params={"name": {"type": "string", "description": "Optional setting name; omit for all."}},
)
def t_get_setting(app, name=None):
    if name:
        return {name: app.project.GetSetting(name)}
    return app.project.GetSetting("") or app.project.GetSetting()


@tool(
    "set_project_setting",
    "Change one project setting (Project Settings dialog values). Values are strings, "
    "e.g. timelineFrameRate='24'. Confirm with the user before changing timeline "
    "resolution or frame rate on an in-progress project.",
    params={"name": {"type": "string"}, "value": {"type": "string"}},
    required=["name", "value"],
)
def t_set_setting(app, name, value):
    ok = app.project.SetSetting(name, value)
    if not ok:
        raise ResolveError("Resolve rejected setting %s=%r (check name/value)." % (name, value))
    return {"set": {name: value}}


@tool(
    "save_project",
    "Save the current project. Use after a batch of changes or when the user asks.",
)
def t_save(app):
    ok = app.pm.SaveProject()
    return {"saved": bool(ok)}


# -- timelines -----------------------------------------------------------------

@tool(
    "get_timeline",
    "Get details for one timeline (default: the current one): tracks, duration, "
    "start timecode, playhead, and item counts per video/audio track.",
    params={"name": {"type": "string", "description": "Timeline name; omit for current."}},
)
def t_get_timeline(app, name=None):
    tl = app.find_timeline(name) if name else app.timeline
    fps = app.timeline_fps(tl)
    tracks = {}
    for ttype in ("video", "audio", "subtitle"):
        count = int(tl.GetTrackCount(ttype))
        infos = []
        for idx in range(1, count + 1):
            items = tl.GetItemListInTrack(ttype, idx) or []
            infos.append({"index": idx, "item_count": len(items)})
        tracks[ttype] = infos
    return {
        "name": tl.GetName(),
        "fps": fps,
        "start_timecode": app.abs_frame_to_tc(tl.GetStartFrame(), fps),
        "end_timecode": app.abs_frame_to_tc(tl.GetEndFrame(), fps),
        "duration_frames": int(tl.GetEndFrame()) - int(tl.GetStartFrame()),
        "playhead": tl.GetCurrentTimecode() if tl.GetName() == app.timeline.GetName() else None,
        "tracks": tracks,
        "marker_count": len(tl.GetMarkers() or {}),
    }


@tool(
    "list_timeline_items",
    "List the clips on one track of the current timeline, with start/end timecode and "
    "duration. Use to inspect edits, find a clip, or pick marker positions.",
    params={
        "track_type": {"type": "string", "enum": ["video", "audio", "subtitle"],
                       "description": "Track type (default video)."},
        "track_index": {"type": "integer", "description": "1-based track number (default 1)."},
    },
)
def t_list_items(app, track_type="video", track_index=1):
    tl = app.timeline
    fps = app.timeline_fps(tl)
    count = int(tl.GetTrackCount(track_type))
    if not (1 <= int(track_index) <= max(count, 0)):
        raise ResolveError("Track %s %s does not exist (timeline has %d)." %
                           (track_type, track_index, count))
    items = tl.GetItemListInTrack(track_type, int(track_index)) or []
    out = []
    for i, item in enumerate(items, 1):
        start, end = int(item.GetStart()), int(item.GetEnd())
        out.append({
            "index": i,
            "name": item.GetName(),
            "start_timecode": app.abs_frame_to_tc(start, fps),
            "end_timecode": app.abs_frame_to_tc(end, fps),
            "duration_frames": int(item.GetDuration()),
        })
    return {"track": "%s %s" % (track_type, track_index), "items": out}


@tool(
    "create_timeline",
    "Create a new empty timeline in the media pool and make it current.",
    params={"name": {"type": "string"}},
    required=["name"],
)
def t_create_timeline(app, name):
    tl = app.media_pool.CreateEmptyTimeline(name)
    if not tl:
        raise ResolveError("Could not create timeline %r (name already in use?)." % name)
    return {"created": tl.GetName()}


@tool(
    "set_current_timeline",
    "Switch to another timeline by name.",
    params={"name": {"type": "string"}},
    required=["name"],
)
def t_set_current_timeline(app, name):
    tl = app.find_timeline(name)
    ok = app.project.SetCurrentTimeline(tl)
    if not ok:
        raise ResolveError("Resolve refused to switch to timeline %r." % name)
    return {"current_timeline": name}


@tool(
    "move_playhead",
    "Move the playhead of the current timeline to a timecode (HH:MM:SS:FF).",
    params={"timecode": {"type": "string"}},
    required=["timecode"],
)
def t_move_playhead(app, timecode):
    ok = app.timeline.SetCurrentTimecode(str(timecode).strip())
    if not ok:
        raise ResolveError("Could not move playhead to %r (bad timecode or out of range)." % timecode)
    return {"playhead": app.timeline.GetCurrentTimecode()}


# -- markers -------------------------------------------------------------------

@tool(
    "add_marker",
    "Add a marker to the current timeline. Position is a timecode string "
    "('HH:MM:SS:FF') or a frame offset from the timeline start. Valid colors: "
    + ", ".join(MARKER_COLORS) + ".",
    params={
        "position": {"type": "string",
                     "description": "Timecode 'HH:MM:SS:FF', or integer frames from timeline start, or 'playhead'."},
        "color": {"type": "string", "description": "Marker color (default Blue)."},
        "name": {"type": "string", "description": "Marker name (default 'Marker')."},
        "note": {"type": "string", "description": "Marker note text."},
        "duration_frames": {"type": "integer", "description": "Marker duration in frames (default 1)."},
    },
    required=["position"],
)
def t_add_marker(app, position, color="Blue", name="Marker", note="", duration_frames=1):
    tl = app.timeline
    if str(position).strip().lower() == "playhead":
        position = tl.GetCurrentTimecode()
    frame = app.position_to_marker_frame(position)
    color = color.capitalize() if color else "Blue"
    if color not in MARKER_COLORS:
        raise ResolveError("Unknown marker color %r. Valid: %s" % (color, ", ".join(MARKER_COLORS)))
    ok = tl.AddMarker(frame, color, name or "Marker", note or "", int(duration_frames) or 1)
    if not ok:
        raise ResolveError(
            "Resolve refused the marker at frame %s (already a marker there, or out of range)." % frame)
    fps = app.timeline_fps(tl)
    return {"added_marker": {
        "frame_offset": frame,
        "timecode": app.abs_frame_to_tc(int(tl.GetStartFrame()) + frame, fps),
        "color": color, "name": name, "note": note,
    }}


@tool(
    "list_markers",
    "List all markers on the current timeline with their timecode, color, name and note.",
)
def t_list_markers(app):
    tl = app.timeline
    fps = app.timeline_fps(tl)
    start = int(tl.GetStartFrame())
    markers = tl.GetMarkers() or {}
    out = []
    for frame, info in sorted(markers.items(), key=lambda kv: int(kv[0])):
        out.append({
            "frame_offset": int(frame),
            "timecode": app.abs_frame_to_tc(start + int(frame), fps),
            "color": info.get("color"),
            "name": info.get("name"),
            "note": info.get("note"),
            "duration_frames": info.get("duration"),
        })
    return {"timeline": tl.GetName(), "markers": out}


@tool(
    "delete_markers",
    "Delete markers on the current timeline. Provide `position` to delete one marker, "
    "or `color` to delete all markers of one color ('All' deletes every marker). "
    "Deleting many markers is destructive — confirm with the user first.",
    params={
        "position": {"type": "string",
                     "description": "Timecode or frame offset of a single marker to delete."},
        "color": {"type": "string",
                  "description": "Marker color to delete, or 'All' for every marker."},
    },
)
def t_delete_markers(app, position=None, color=None):
    tl = app.timeline
    if position is not None:
        frame = app.position_to_marker_frame(position)
        ok = tl.DeleteMarkerAtFrame(frame)
        if not ok:
            raise ResolveError("No marker found at %r." % position)
        return {"deleted_marker_at_frame": frame}
    if color:
        before = len(tl.GetMarkers() or {})
        ok = tl.DeleteMarkersByColor(color.capitalize() if color != "All" else "All")
        after = len(tl.GetMarkers() or {})
        if not ok and before == after:
            raise ResolveError("No markers deleted (color %r not present?)." % color)
        return {"deleted_count": before - after}
    raise ResolveError("Provide either `position` or `color`.")


# -- media pool ------------------------------------------------------------------

@tool(
    "list_media_pool",
    "List clips and sub-folders in a media pool folder. `folder_path` like '/B-roll/Day 1' "
    "(default '/'). Set include_subfolders=true to walk the whole subtree (capped at 200 clips).",
    params={
        "folder_path": {"type": "string", "description": "Folder path, '/' = root."},
        "include_subfolders": {"type": "boolean"},
    },
)
def t_list_media_pool(app, folder_path="/", include_subfolders=False):
    root = app.folder_by_path(folder_path)
    clips, truncated = [], False
    CAP = 200

    def describe(clip, where):
        return {
            "name": clip.GetName(),
            "folder": where,
            "duration": clip.GetClipProperty("Duration"),
            "fps": clip.GetClipProperty("FPS"),
            "resolution": clip.GetClipProperty("Resolution"),
            "type": clip.GetClipProperty("Type"),
        }

    def walk(folder, where):
        nonlocal truncated
        for clip in folder.GetClipList() or []:
            if len(clips) >= CAP:
                truncated = True
                return
            clips.append(describe(clip, where))
        if include_subfolders:
            for sub in folder.GetSubFolderList() or []:
                walk(sub, where.rstrip("/") + "/" + sub.GetName())

    walk(root, folder_path or "/")
    subfolders = [s.GetName() for s in root.GetSubFolderList() or []]
    out = {"folder": folder_path or "/", "subfolders": subfolders, "clips": clips}
    if truncated:
        out["note"] = "Truncated at %d clips." % CAP
    return out


@tool(
    "get_clip_properties",
    "Get all media pool properties for one clip (file path, codec, timecode, audio "
    "channels, etc.). The clip is found by exact name anywhere in the media pool.",
    params={"clip_name": {"type": "string"}},
    required=["clip_name"],
)
def t_clip_props(app, clip_name):
    clip = app.find_clips_by_name([clip_name])[0]
    props = clip.GetClipProperty()
    if not isinstance(props, dict):
        props = {"value": props}
    return {"clip": clip_name, "properties": props}


@tool(
    "create_media_pool_folder",
    "Create a new bin/folder in the media pool under `parent_path` (default root).",
    params={
        "name": {"type": "string"},
        "parent_path": {"type": "string", "description": "Parent folder path, default '/'."},
    },
    required=["name"],
)
def t_create_bin(app, name, parent_path="/"):
    parent = app.folder_by_path(parent_path)
    folder = app.media_pool.AddSubFolder(parent, name)
    if not folder:
        raise ResolveError("Could not create folder %r under %r." % (name, parent_path))
    return {"created_folder": folder.GetName(), "under": parent_path}


@tool(
    "import_media",
    "Import media files/folders from disk into the CURRENT media pool folder. "
    "Paths must be absolute paths on this machine.",
    params={"paths": {"type": "array", "items": {"type": "string"},
                      "description": "Absolute file or folder paths."}},
    required=["paths"],
)
def t_import_media(app, paths):
    missing = [p for p in paths if not os.path.exists(p)]
    if missing:
        raise ResolveError("These paths do not exist: %s" % ", ".join(missing))
    items = app.media_pool.ImportMedia(list(paths))
    if not items:
        raise ResolveError("Resolve imported nothing (unsupported format or duplicate?).")
    return {"imported": [it.GetName() for it in items]}


@tool(
    "append_to_timeline",
    "Append media pool clips (found by exact name) to the end of the current timeline, "
    "in the order given.",
    params={"clip_names": {"type": "array", "items": {"type": "string"}}},
    required=["clip_names"],
)
def t_append(app, clip_names):
    app.timeline  # ensure a timeline exists first
    clips = app.find_clips_by_name(clip_names)
    result = app.media_pool.AppendToTimeline(clips)
    if not result:
        raise ResolveError("AppendToTimeline failed (are these clips usable on this timeline?).")
    return {"appended": clip_names, "timeline": app.timeline.GetName()}


# -- color ------------------------------------------------------------------------

@tool(
    "get_current_video_item",
    "Get info about the clip under the playhead on the current timeline (the clip a "
    "colorist is working on): name, range, grade versions. Works best on the Color page.",
)
def t_current_item(app):
    item = app.timeline.GetCurrentVideoItem()
    if not item:
        raise ResolveError("No current video item (move the playhead over a clip, "
                           "ideally on the Edit or Color page).")
    fps = app.timeline_fps()
    out = {
        "name": item.GetName(),
        "start_timecode": app.abs_frame_to_tc(int(item.GetStart()), fps),
        "end_timecode": app.abs_frame_to_tc(int(item.GetEnd()), fps),
        "duration_frames": int(item.GetDuration()),
    }
    try:
        out["color_versions"] = item.GetVersionNameList(0)
    except Exception:
        pass
    return out


@tool(
    "apply_lut_to_current_clip",
    "Apply a LUT file to a node of the clip under the playhead (Color page grade). "
    "`lut_path` is an absolute path to a .cube/.3dl file, `node_index` is 1-based.",
    params={
        "lut_path": {"type": "string"},
        "node_index": {"type": "integer", "description": "1-based node index (default 1)."},
    },
    required=["lut_path"],
)
def t_apply_lut(app, lut_path, node_index=1):
    item = app.timeline.GetCurrentVideoItem()
    if not item:
        raise ResolveError("No current video item — move the playhead over the clip first.")
    ok = item.SetLUT(int(node_index), lut_path)
    if not ok:
        raise ResolveError("SetLUT failed — check the LUT path and node index "
                           "(LUT may need to be in Resolve's LUT folder).")
    return {"applied_lut": lut_path, "node": int(node_index), "clip": item.GetName()}


# -- deliver / render ---------------------------------------------------------------

@tool(
    "list_render_presets",
    "List available render presets on the Deliver page (built-in + user presets).",
)
def t_render_presets(app):
    return {"presets": app.project.GetRenderPresetList() or []}


@tool(
    "add_render_job",
    "Queue a render job for the current timeline on the Deliver page. Optionally load a "
    "render preset first, and set the output directory and file name. Does NOT start "
    "rendering — use start_render for that.",
    params={
        "preset_name": {"type": "string", "description": "Render preset to load (optional)."},
        "target_dir": {"type": "string", "description": "Output directory (absolute path)."},
        "custom_name": {"type": "string", "description": "Output file name (without extension)."},
    },
)
def t_add_render_job(app, preset_name=None, target_dir=None, custom_name=None):
    project = app.project
    if preset_name:
        if not project.LoadRenderPreset(preset_name):
            raise ResolveError("Unknown render preset %r. Use list_render_presets." % preset_name)
    settings = {}
    if target_dir:
        settings["TargetDir"] = target_dir
    if custom_name:
        settings["CustomName"] = custom_name
    if settings and not project.SetRenderSettings(settings):
        raise ResolveError("Resolve rejected render settings %r." % settings)
    job_id = project.AddRenderJob()
    if not job_id:
        raise ResolveError("Could not add render job (is a timeline open?).")
    return {"job_id": job_id, "preset": preset_name, "settings": settings}


@tool(
    "start_render",
    "Start rendering all queued jobs on the Deliver page. Long-running and hard to "
    "miss — only do this when the user asked to render.",
)
def t_start_render(app):
    ok = app.project.StartRendering()
    if not ok:
        raise ResolveError("StartRendering failed (empty render queue?).")
    return {"rendering": True}


@tool(
    "get_render_status",
    "Check the render queue: whether rendering is in progress and each job's status "
    "and completion percentage.",
)
def t_render_status(app):
    project = app.project
    jobs = []
    for job in project.GetRenderJobList() or []:
        jid = job.get("JobId")
        status = {}
        if jid:
            try:
                status = project.GetRenderJobStatus(jid) or {}
            except Exception:
                status = {}
        jobs.append({
            "job_id": jid,
            "name": job.get("RenderJobName") or job.get("TimelineName"),
            "target": os.path.join(job.get("TargetDir", "") or "", job.get("OutputFilename", "") or ""),
            "status": status.get("JobStatus"),
            "completion_pct": status.get("CompletionPercentage"),
        })
    return {"rendering_in_progress": bool(project.IsRenderingInProgress()),
            "jobs": jobs}


# -- escape hatch -------------------------------------------------------------------

@tool(
    "run_python",
    "Run a short Python snippet inside Resolve's scripting environment. Use ONLY when no "
    "other tool covers the request. Available names: resolve, project_manager, project, "
    "timeline (may be None), media_pool, fusion. stdout is captured; set a variable "
    "named `result` for a structured return value. The code is shown to the user. "
    "Never write code that deletes media files or project data without the user's "
    "explicit confirmation in chat.",
    params={"code": {"type": "string", "description": "Python source to execute."}},
    required=["code"],
)
def t_run_python(app, code):
    if not STATE.get("allow_python", True):
        raise ResolveError("Python execution is disabled (checkbox in the assistant window).")
    env = {
        "resolve": app.resolve,
        "project_manager": app.pm,
        "project": app.pm.GetCurrentProject(),
        "timeline": None,
        "media_pool": None,
        "fusion": STATE.get("fusion"),
    }
    try:
        env["timeline"] = env["project"].GetCurrentTimeline() if env["project"] else None
        env["media_pool"] = env["project"].GetMediaPool() if env["project"] else None
    except Exception:
        pass
    buf = io.StringIO()
    old_stdout = sys.stdout
    sys.stdout = buf
    try:
        exec(compile(code, "<claude-snippet>", "exec"), env)
    finally:
        sys.stdout = old_stdout
    out = {"stdout": buf.getvalue()[-8000:]}
    if "result" in env:
        try:
            json.dumps(env["result"])
            out["result"] = env["result"]
        except (TypeError, ValueError):
            out["result"] = repr(env["result"])[:4000]
    return out


# ----------------------------------------------------------------------------
# Anthropic API client (SDK if installed, stdlib fallback otherwise)
# ----------------------------------------------------------------------------

try:
    import anthropic as _anthropic_sdk  # optional
except ImportError:
    _anthropic_sdk = None


class ApiError(Exception):
    pass


def _strip_none(obj):
    if isinstance(obj, dict):
        return {k: _strip_none(v) for k, v in obj.items() if v is not None}
    if isinstance(obj, list):
        return [_strip_none(v) for v in obj]
    return obj


def _build_payload(model, messages):
    payload = {
        "model": model,
        "max_tokens": MAX_TOKENS,
        "system": [{"type": "text", "text": SYSTEM_PROMPT,
                    "cache_control": {"type": "ephemeral"}}],
        "tools": tool_schemas(),
        "messages": messages,
    }
    betas = []
    if "haiku" not in model:
        payload["thinking"] = {"type": "adaptive"}
    if model.startswith(("claude-opus-5", "claude-fable-5")):
        # Server-side refusal fallbacks: if safety classifiers decline a
        # request, the API transparently retries it on a recommended model.
        payload["fallbacks"] = "default"
        betas.append("server-side-fallback-2026-07-01")
    return payload, betas


def _call_api_sdk(api_key, payload, betas):
    client = _anthropic_sdk.Anthropic(api_key=api_key, max_retries=3,
                                      timeout=REQUEST_TIMEOUT_S)
    kwargs = dict(payload)
    fallbacks = kwargs.pop("fallbacks", None)
    extra_headers = {"anthropic-beta": ",".join(betas)} if betas else None
    extra_body = {"fallbacks": fallbacks} if fallbacks else None
    try:
        resp = client.messages.create(
            extra_headers=extra_headers, extra_body=extra_body, **kwargs)
    except _anthropic_sdk.APIStatusError as exc:
        raise ApiError("Anthropic API error %s: %s" % (exc.status_code, exc.message))
    except _anthropic_sdk.APIConnectionError as exc:
        raise ApiError("Could not reach the Anthropic API: %s" % exc)
    try:
        data = json.loads(resp.model_dump_json())
    except AttributeError:  # very old SDK
        data = json.loads(resp.json())
    data["content"] = _strip_none(data.get("content") or [])
    return data


def _call_api_stdlib(api_key, payload, betas):
    import urllib.request
    import urllib.error

    body = json.dumps(payload).encode("utf-8")
    headers = {
        "x-api-key": api_key,
        "anthropic-version": API_VERSION,
        "content-type": "application/json",
    }
    if betas:
        headers["anthropic-beta"] = ",".join(betas)

    ctx = None
    try:
        import certifi
        ctx = ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        ctx = ssl.create_default_context()

    delays = [0, 2, 4, 8, 16]
    last_err = None
    for attempt, delay in enumerate(delays):
        if delay:
            time.sleep(delay)
        req = urllib.request.Request(API_URL, data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT_S, context=ctx) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            raw = b""
            try:
                raw = exc.read()
            except Exception:
                pass
            message = ""
            try:
                message = json.loads(raw.decode("utf-8"))["error"]["message"]
            except Exception:
                message = raw.decode("utf-8", "replace")[:400]
            if exc.code in (429, 500, 529) and attempt < len(delays) - 1:
                retry_after = exc.headers.get("retry-after") if exc.headers else None
                if retry_after:
                    try:
                        time.sleep(min(float(retry_after), 60))
                    except ValueError:
                        pass
                last_err = "HTTP %s: %s" % (exc.code, message)
                continue
            if exc.code == 401:
                raise ApiError("Invalid API key (HTTP 401). Update it and try again.")
            raise ApiError("Anthropic API error %s: %s" % (exc.code, message))
        except urllib.error.URLError as exc:
            reason = getattr(exc, "reason", exc)
            if isinstance(reason, ssl.SSLCertVerificationError):
                raise ApiError(
                    "TLS certificate verification failed. On macOS run "
                    "'Install Certificates.command' inside your Python folder, "
                    "or `pip install certifi`, then relaunch Resolve.")
            if attempt < len(delays) - 1:
                last_err = str(reason)
                continue
            raise ApiError("Could not reach the Anthropic API: %s" % reason)
    raise ApiError("Anthropic API kept failing after retries: %s" % last_err)


def call_claude(api_key, model, messages):
    payload, betas = _build_payload(model, messages)
    if _anthropic_sdk is not None:
        return _call_api_sdk(api_key, payload, betas)
    return _call_api_stdlib(api_key, payload, betas)


# ----------------------------------------------------------------------------
# Agent loop
# ----------------------------------------------------------------------------

STATE = {
    "messages": [],          # Anthropic wire-format history
    "allow_python": True,
    "fusion": None,
    "app": None,             # ResolveApp
}


def resolve_context_block():
    """A small trusted snapshot appended to each user message."""
    lines = []
    try:
        app = STATE["app"]
        lines.append("page: %s" % app.resolve.GetCurrentPage())
        project = app.pm.GetCurrentProject()
        if project:
            lines.append("project: %s" % project.GetName())
            tl = project.GetCurrentTimeline()
            if tl:
                lines.append("timeline: %s" % tl.GetName())
                lines.append("playhead: %s" % tl.GetCurrentTimecode())
            else:
                lines.append("timeline: (none open)")
        else:
            lines.append("project: (none open)")
    except Exception as exc:
        lines.append("unavailable: %s" % exc)
    return "<resolve_context>\n%s\n</resolve_context>" % "\n".join(lines)


def execute_tool(name, tool_input):
    entry = TOOL_INDEX.get(name)
    if entry is None:
        return False, "Unknown tool: %s" % name
    try:
        result = entry["fn"](STATE["app"], **(tool_input or {}))
        return True, json.dumps(result, default=str)
    except ResolveError as exc:
        return False, str(exc)
    except TypeError as exc:
        return False, "Bad arguments for %s: %s" % (name, exc)
    except Exception:
        return False, "Tool %s crashed:\n%s" % (name, traceback.format_exc(limit=4))


def run_agent_turn(api_key, model, user_text, emit):
    """Run one full user turn (which may involve many tool round-trips).

    `emit(kind, text)` is called with transcript events:
      kind in {assistant, tool, error, notice}.
    """
    messages = STATE["messages"]
    messages.append({
        "role": "user",
        "content": [
            {"type": "text", "text": user_text},
            {"type": "text", "text": resolve_context_block()},
        ],
    })

    for _ in range(MAX_AGENT_ITERATIONS):
        try:
            response = call_claude(api_key, model, messages)
        except ApiError as exc:
            # Do not leave a dangling user message pair-less: keep history as-is;
            # the next attempt simply retries the same conversation.
            emit("error", str(exc))
            return

        content = response.get("content") or []
        stop_reason = response.get("stop_reason")

        for block in content:
            if block.get("type") == "text" and block.get("text", "").strip():
                emit("assistant", block["text"])

        messages.append({"role": "assistant", "content": content})

        if stop_reason == "tool_use":
            results = []
            for block in content:
                if block.get("type") != "tool_use":
                    continue
                name = block.get("name")
                emit("tool", "%s(%s)" % (name, _short_json(block.get("input"))))
                if name == "run_python" and isinstance(block.get("input"), dict):
                    code = block["input"].get("code", "")
                    emit("tool", "```python\n%s\n```" % code)
                ok, text = execute_tool(name, block.get("input") or {})
                if not ok:
                    emit("tool", "error: %s" % text)
                entry = {"type": "tool_result", "tool_use_id": block.get("id"),
                         "content": text}
                if not ok:
                    entry["is_error"] = True
                results.append(entry)
            messages.append({"role": "user", "content": results})
            continue

        if stop_reason == "pause_turn":
            continue  # assistant turn already appended; just call again

        if stop_reason == "refusal":
            details = response.get("stop_details") or {}
            emit("notice", "Claude declined this request (safety classifiers%s)." %
                 (", category: %s" % details.get("category") if details.get("category") else ""))
        elif stop_reason == "max_tokens":
            emit("notice", "Response hit the length limit and may be truncated — "
                           "say 'continue' to keep going.")
        return

    emit("notice", "Stopped after %d tool rounds — ask me to continue if needed."
         % MAX_AGENT_ITERATIONS)


def _short_json(obj, limit=160):
    try:
        text = json.dumps(obj, default=str)
    except (TypeError, ValueError):
        text = repr(obj)
    return text if len(text) <= limit else text[:limit] + "…"


# ----------------------------------------------------------------------------
# Chat UI (Fusion UIManager)
# ----------------------------------------------------------------------------

def _escape(text):
    return (text.replace("&", "&amp;").replace("<", "&lt;")
                .replace(">", "&gt;"))


def _render_markdownish(text):
    """Minimal, safe rendering: escape HTML, keep ``` blocks as <pre>."""
    parts = re.split(r"```(?:[\w+-]*)\n?", text)
    html = []
    for i, part in enumerate(parts):
        if i % 2 == 1:  # inside a fence
            html.append("<pre style='background:#161616;color:#d8d8d8;"
                        "padding:6px;border-radius:4px;white-space:pre-wrap;'>"
                        + _escape(part) + "</pre>")
        else:
            chunk = _escape(part)
            chunk = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", chunk)
            chunk = re.sub(r"`([^`\n]+)`",
                           r"<code style='background:#242424;'>\1</code>", chunk)
            html.append(chunk.replace("\n", "<br>"))
    return "".join(html)


class ChatWindow(object):
    SPEAKER_STYLES = {
        "you": ("You", "#7fd07f"),
        "assistant": ("Claude", "#e8a87c"),
        "tool": ("Tool", "#8fa8c8"),
        "error": ("Error", "#e07a7a"),
        "notice": ("Note", "#c8b45a"),
    }

    def __init__(self, ui, disp, cfg):
        self.ui = ui
        self.disp = disp
        self.cfg = cfg
        self.events = _queue.Queue()
        self.busy = False
        self.timer = None
        self.html_log = []

        self.win = disp.AddWindow(
            {
                "ID": "ClaudeWin",
                "WindowTitle": "Claude Assistant — DaVinci Resolve",
                "Geometry": [240, 160, 760, 680],
            },
            [
                ui.VGroup({"Spacing": 6}, [
                    ui.HGroup({"Weight": 0}, [
                        ui.Label({"ID": "ModelLbl", "Text": "Model:", "Weight": 0}),
                        ui.ComboBox({"ID": "ModelCombo", "Weight": 0.35}),
                        ui.CheckBox({"ID": "AllowPy",
                                     "Text": "Allow Python execution",
                                     "Checked": bool(cfg.get("allow_python", True)),
                                     "Weight": 0.4}),
                        ui.Button({"ID": "NewChatBtn", "Text": "New chat", "Weight": 0.15}),
                    ]),
                    ui.TextEdit({"ID": "Chat", "ReadOnly": True, "Weight": 1}),
                    ui.HGroup({"Weight": 0}, [
                        ui.LineEdit({"ID": "Input",
                                     "PlaceholderText": "Ask Claude…  (Enter to send)",
                                     "Weight": 1}),
                        ui.Button({"ID": "SendBtn", "Text": "Send", "Weight": 0}),
                    ]),
                    ui.Label({"ID": "Status", "Text": "", "Weight": 0}),
                ]),
            ])
        self.items = self.win.GetItems()

        combo = self.items["ModelCombo"]
        for m in MODEL_CHOICES:
            combo.AddItem(m)
        saved = cfg.get("model", DEFAULT_MODEL)
        if saved in MODEL_CHOICES:
            combo.CurrentIndex = MODEL_CHOICES.index(saved)

        self.win.On.SendBtn.Clicked = self.on_send
        self.win.On.Input.ReturnPressed = self.on_send
        self.win.On.NewChatBtn.Clicked = self.on_new_chat
        self.win.On.ClaudeWin.Close = self.on_close

        self._setup_timer()

    # -- timer / threading ----------------------------------------------------
    def _setup_timer(self):
        """Poll the event queue so a worker thread can update the transcript.
        If UIManager has no Timer, we fall back to synchronous calls."""
        try:
            self.timer = self.ui.Timer({"ID": "PollTimer", "Interval": 100})
            self.win.On.PollTimer.Timeout = lambda ev: self.drain_events()
            self.timer.Start()
        except Exception:
            self.timer = None

    def drain_events(self):
        try:
            while True:
                kind, text = self.events.get_nowait()
                if kind == "__done__":
                    self.set_busy(False)
                else:
                    self.append_chat(kind, text)
        except _queue.Empty:
            pass

    # -- transcript -----------------------------------------------------------
    def append_chat(self, kind, text):
        speaker, color = self.SPEAKER_STYLES.get(kind, ("?", "#cccccc"))
        body = _render_markdownish(text)
        html = ("<div style='margin:6px 0;'><b><span style='color:%s;'>%s"
                "</span></b>&nbsp; %s</div>" % (color, speaker, body))
        self.html_log.append(html)
        chat = self.items["Chat"]
        try:
            chat.Append(html)
        except Exception:
            chat.HTML = "".join(self.html_log)

    def set_status(self, text):
        try:
            self.items["Status"].Text = text
        except Exception:
            pass

    def set_busy(self, busy):
        self.busy = busy
        self.items["SendBtn"].Enabled = not busy
        self.items["Input"].Enabled = not busy
        self.set_status("Claude is working…" if busy else "")

    # -- events -----------------------------------------------------------------
    def current_model(self):
        idx = int(self.items["ModelCombo"].CurrentIndex)
        return MODEL_CHOICES[idx] if 0 <= idx < len(MODEL_CHOICES) else DEFAULT_MODEL

    def on_send(self, ev):
        if self.busy:
            return
        text = (self.items["Input"].Text or "").strip()
        if not text:
            return
        self.items["Input"].Text = ""
        STATE["allow_python"] = bool(self.items["AllowPy"].Checked)
        model = self.current_model()

        self.cfg["model"] = model
        self.cfg["allow_python"] = STATE["allow_python"]
        save_config(self.cfg)

        api_key = get_api_key(self.cfg)
        if not api_key:
            self.append_chat("error", "No API key configured — restart the script to enter one.")
            return

        self.append_chat("you", text)

        if self.timer is not None:
            self.set_busy(True)
            worker = threading.Thread(
                target=self._worker, args=(api_key, model, text), daemon=True)
            worker.start()
        else:
            # Synchronous fallback: UI freezes during the call but stays correct.
            self.set_busy(True)
            try:
                run_agent_turn(api_key, model, text,
                               lambda kind, t: self.append_chat(kind, t))
            finally:
                self.set_busy(False)

    def _worker(self, api_key, model, text):
        try:
            run_agent_turn(api_key, model, text,
                           lambda kind, t: self.events.put((kind, t)))
        except Exception:
            self.events.put(("error", "Unexpected failure:\n" + traceback.format_exc(limit=6)))
        finally:
            self.events.put(("__done__", ""))

    def on_new_chat(self, ev):
        if self.busy:
            return
        STATE["messages"] = []
        self.html_log = []
        try:
            self.items["Chat"].Clear()
        except Exception:
            self.items["Chat"].HTML = ""
        self.greet()

    def on_close(self, ev):
        self.disp.ExitLoop()

    def greet(self):
        self.append_chat("notice",
                         "Connected to Resolve. Ask me anything — e.g. "
                         "\"add a red marker at every cut on V1\", "
                         "\"what's in my media pool?\", "
                         "\"queue a YouTube 1080p render to ~/Renders\".")


def prompt_for_api_key(ui, disp, cfg):
    """Small one-shot window shown when no API key is configured."""
    result = {"saved": False}
    win = disp.AddWindow(
        {"ID": "KeyWin", "WindowTitle": "Claude Assistant — API key",
         "Geometry": [300, 300, 560, 150]},
        [
            ui.VGroup({"Spacing": 8}, [
                ui.Label({"ID": "KeyInfo", "WordWrap": True, "Text":
                          "Enter your Anthropic API key (from platform.claude.com).\n"
                          "It is stored only on this machine, in your user config folder."}),
                ui.LineEdit({"ID": "KeyInput", "PlaceholderText": "sk-ant-…",
                             "EchoMode": "Password"}),
                ui.HGroup({}, [
                    ui.Button({"ID": "KeySave", "Text": "Save & start"}),
                    ui.Button({"ID": "KeyCancel", "Text": "Cancel"}),
                ]),
            ]),
        ])
    items = win.GetItems()

    def on_save(ev):
        key = (items["KeyInput"].Text or "").strip()
        if key:
            cfg["api_key"] = key
            save_config(cfg)
            result["saved"] = True
        disp.ExitLoop()

    def on_cancel(ev):
        disp.ExitLoop()

    win.On.KeySave.Clicked = on_save
    win.On.KeyInput.ReturnPressed = on_save
    win.On.KeyCancel.Clicked = on_cancel
    win.On.KeyWin.Close = on_cancel
    win.Show()
    disp.RunLoop()
    win.Hide()
    return result["saved"]


# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

def main():
    resolve_obj, bmd_mod, fusion_obj = get_resolve_bmd_fusion()
    STATE["app"] = ResolveApp(resolve_obj)
    STATE["fusion"] = fusion_obj

    if bmd_mod is None or fusion_obj is None:
        print("[%s] UI toolkit unavailable — cannot open the chat window." % APP_NAME)
        return

    cfg = load_config()
    STATE["allow_python"] = bool(cfg.get("allow_python", True))

    ui = fusion_obj.UIManager
    disp = bmd_mod.UIDispatcher(ui)

    if not get_api_key(cfg):
        if not prompt_for_api_key(ui, disp, cfg):
            print("[%s] No API key entered — exiting." % APP_NAME)
            return

    window = ChatWindow(ui, disp, cfg)
    window.greet()
    window.win.Show()
    disp.RunLoop()
    window.win.Hide()


if __name__ == "__main__":
    main()
