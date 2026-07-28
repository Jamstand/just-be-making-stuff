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
import base64
import binascii
import io
import json
import os
import re
import shutil
import socket
import ssl
import subprocess
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

# Two ways to reach a model. "claude-code" shells out to the Claude Code CLI and
# rides the user's Pro/Max subscription (no API key, no per-token billing);
# "api" talks to the Messages API directly with a key.
BACKEND_API = "api"
BACKEND_CLAUDE_CODE = "claude-code"

# The MCP server name we expose the Resolve tools under. Claude Code namespaces
# MCP tools as mcp__<server>__<tool>, so this is also the allowlist prefix.
MCP_SERVER_NAME = "resolve"
# Protocol versions we can speak, newest first, plus what to answer with when
# the client asks for something we don't recognise.
MCP_PROTOCOL_VERSIONS = ("2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05")
MCP_FALLBACK_VERSION = "2025-06-18"
BRIDGE_ENV_PORT = "CLAUDE_RESOLVE_BRIDGE_PORT"
BRIDGE_ENV_TOKEN = "CLAUDE_RESOLVE_BRIDGE_TOKEN"
MCP_BRIDGE_FLAG = "--mcp-bridge"

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
- view_frame shows you the actual frame as an image; survey_clip shows several frames across a range at once. Whenever the question is about how footage looks — exposure, color, framing, what's in the shot, whether two shots match — look instead of guessing from names and metadata.
- To get spoken words as text: transcribe_audio on the clips, then auto_caption, then read the subtitle track with list_timeline_items(track_type='subtitle'). The transcript text is not directly retrievable any other way.

What Resolve's scripting API cannot do. Say so plainly rather than pretending or quietly failing:
- No trimming, slipping, rolling, razoring/splitting, moving a clip, or speed changes IN PLACE. Clips can only be ADDED (place_clips) and DELETED (delete_clips). Two workarounds, both with trade-offs to state before using them: (a) delete + re-add at new position/length, which destroys that clip's grade, Fusion comp, transforms and markers; (b) the interchange round-trip — get_timeline_interchange, transform the EDL/XML text yourself, apply_timeline_interchange — which supports arbitrary re-editing but builds a NEW timeline instead of changing the current one.
- No colour wheels: no lift, gamma, gain, contrast, temperature or tint control exists. set_cdl is the only numeric colour tool; it is write-only and overwrites that node's CDL absolutely, so you can never read the current grade or "nudge" it. Prefer copy_grade, LUTs and colour versions where they fit.
- No node creation, power windows, qualifiers, or grade keyframes.
- No audio mixing whatsoever: no clip volume, fades, EQ, dynamics, or level/loudness readings. Audio tracks can be added and managed; nothing inside them can be adjusted.
- Titles land on the lowest video track and their duration cannot be set at insert.
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


def get_backend(cfg):
    """Which brain the panel talks to: BACKEND_CLAUDE_CODE or BACKEND_API."""
    choice = (os.environ.get("CLAUDE_RESOLVE_BACKEND") or cfg.get("backend") or "").strip().lower()
    if choice in (BACKEND_CLAUDE_CODE, BACKEND_API):
        return choice
    # Unconfigured: prefer the subscription route when the CLI is present, so a
    # fresh install with Claude Code already set up needs no API key at all.
    return BACKEND_CLAUDE_CODE if find_claude_binary(cfg) else BACKEND_API


_ready_cache = {}


def backend_ready(cfg, recheck=False):
    """(ok, message) — can we actually talk to a model right now?

    The sign-in probe spawns a process, so a success is cached; it only needs to
    be true once per session.
    """
    backend = get_backend(cfg)
    if backend == BACKEND_CLAUDE_CODE:
        if _ready_cache.get(backend) and not recheck:
            return True, ""
        binary = find_claude_binary(cfg)
        if not binary:
            return False, ("Claude Code CLI not found. Install it with "
                           "`npm install -g @anthropic-ai/claude-code`, or switch this "
                           "panel to the API-key backend.")
        ok, detail = claude_code_auth_status(binary)
        if not ok:
            return False, detail
        _ready_cache[backend] = True
        return True, ""
    if not get_api_key(cfg):
        return False, "No API key configured — restart the script to enter one."
    return True, ""


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


_FUSIONSCRIPT_LIBS = [
    os.environ.get("RESOLVE_SCRIPT_LIB") or "",
    "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fusionscript.so",
    r"C:\Program Files\Blackmagic Design\DaVinci Resolve\fusionscript.dll",
    "/opt/resolve/libs/Fusion/fusionscript.so",
]


def _load_fusionscript():
    """Import the fusionscript module (provides scriptapp + UIDispatcher),
    falling back to loading the native library directly (external runs)."""
    try:
        import fusionscript
        return fusionscript
    except ImportError:
        pass
    import importlib.machinery
    import importlib.util
    for lib in _FUSIONSCRIPT_LIBS:
        if lib and os.path.isfile(lib):
            try:
                loader = importlib.machinery.ExtensionFileLoader("fusionscript", lib)
                spec = importlib.util.spec_from_loader("fusionscript", loader)
                module = importlib.util.module_from_spec(spec)
                loader.exec_module(module)
                return module
            except Exception:
                continue
    return None


def get_resolve_bmd_fusion():
    """Return (resolve, bmd_module, fusion) whether we run inside Resolve's
    Scripts menu (globals provided) or externally (Studio only)."""
    g = globals()
    res = g.get("resolve")
    bmd_mod = g.get("bmd")
    fu = g.get("fusion")
    if res is None:
        _add_module_paths()
        try:
            import DaVinciResolveScript as dvr  # noqa: N813
            res = dvr.scriptapp("Resolve")
        except ImportError:
            fs = _load_fusionscript()
            res = fs.scriptapp("Resolve") if fs else None
    if res is None:
        raise RuntimeError(
            "Could not connect to DaVinci Resolve. Run this script from "
            "Workspace > Scripts inside Resolve, or enable external scripting "
            "(Preferences > System > General > External scripting using: Local; "
            "Studio only).")
    if fu is None:
        fu = res.Fusion()
    if bmd_mod is None:
        bmd_mod = _load_fusionscript()
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

    def start_timecode(self, tl):
        """Timeline start as timecode; Resolve's own value when available."""
        try:
            tc = tl.GetStartTimecode()
            if tc:
                return tc
        except Exception:
            pass
        return self.abs_frame_to_tc(int(tl.GetStartFrame()), self.timeline_fps(tl))

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
            "start_timecode": app.start_timecode(current_tl),
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
    settings = None
    for arg in ("", None):
        try:
            settings = app.project.GetSetting(arg) if arg == "" else app.project.GetSetting()
        except Exception:
            settings = None
        if isinstance(settings, dict):
            return settings
    raise ResolveError("Could not read the full settings dict; ask for a specific setting name.")


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

def _playhead_if_current(app, tl):
    try:
        if tl.GetName() == app.timeline.GetName():
            return tl.GetCurrentTimecode()
    except ResolveError:
        pass
    return None


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
        "start_timecode": app.start_timecode(tl),
        "end_timecode": app.abs_frame_to_tc(tl.GetEndFrame(), fps),
        "duration_frames": int(tl.GetEndFrame()) - int(tl.GetStartFrame()),
        "playhead": _playhead_if_current(app, tl),
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
    # Resolve's API is positional-only and wants all six arguments.
    ok = tl.AddMarker(frame, color, name or "Marker", note or "",
                      int(duration_frames) or 1, "")
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
            "duration_tc": clip.GetClipProperty("Duration"),   # timecode string
            "frames": clip.GetClipProperty("Frames"),
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


# -- editing -----------------------------------------------------------------

# Verbatim from Resolve's "Looking up Timeline item properties". Values are
# floats unless noted; ranges that depend on frame size are checked by Resolve.
TRANSFORM_KEYS = {
    "Pan": "pixels, -4x..4x width", "Tilt": "pixels, -4x..4x height",
    "ZoomX": "0.0-100.0 (1.0 = original size)", "ZoomY": "0.0-100.0",
    "ZoomGang": "bool - link ZoomX/ZoomY",
    "RotationAngle": "-360.0..360.0 degrees",
    "AnchorPointX": "pixels", "AnchorPointY": "pixels",
    "Pitch": "-1.5..1.5", "Yaw": "-1.5..1.5",
    "FlipX": "bool - flip horizontally", "FlipY": "bool - flip vertically",
    "CropLeft": "pixels", "CropRight": "pixels",
    "CropTop": "pixels", "CropBottom": "pixels",
    "CropSoftness": "-100.0..100.0", "CropRetain": "bool",
    "Opacity": "0.0-100.0", "Distortion": "-1.0..1.0",
}


def _supports(obj, method):
    """Feature-detect a Resolve API method.

    NOT hasattr(): Resolve's Python bridge fabricates a callable for ANY
    attribute name, so hasattr is always True and getattr never raises. Only
    dir() lists the real methods.
    """
    try:
        return method in dir(obj)
    except Exception:
        return False


def _track_items(app, track_type, track_index):
    tl = app.timeline
    count = int(tl.GetTrackCount(track_type) or 0)
    if not 1 <= int(track_index) <= count:
        raise ResolveError("%s track %s does not exist (timeline has %d)."
                           % (track_type, track_index, count))
    return list(tl.GetItemListInTrack(track_type, int(track_index)) or [])


def _describe_item(app, item, fps, index=None):
    out = {
        "index": index,
        "name": item.GetName(),
        "start_timecode": app.abs_frame_to_tc(int(item.GetStart()), fps),
        "duration_frames": int(item.GetDuration()),
    }
    return out


@tool(
    "place_clips",
    "Place media pool clips onto the current timeline at exact positions — the "
    "way to build an assembly or drop a clip at a specific spot. Each entry needs "
    "`clip_name`; optionally `start_frame`/`end_frame` (in/out within the SOURCE "
    "clip), `track_index` (default 1), and `at` (timeline position as timecode or "
    "frames from timeline start; default: butt-joined after the previous entry). "
    "Note Resolve can only ADD clips — it cannot move or trim them afterwards.",
    params={
        "clips": {"type": "array", "description":
                  "List of {clip_name, start_frame?, end_frame?, track_index?, at?}.",
                  "items": {"type": "object"}},
        "audio_only": {"type": "boolean", "description": "Place audio only (default false)."},
        "video_only": {"type": "boolean", "description": "Place video only (default false)."},
    },
    required=["clips"],
)
def t_place_clips(app, clips, audio_only=False, video_only=False):
    if not isinstance(clips, list) or not clips:
        raise ResolveError("`clips` must be a non-empty list.")
    tl = app.timeline
    fps = app.timeline_fps(tl)
    timeline_start = int(tl.GetStartFrame())

    names = [c.get("clip_name") for c in clips if isinstance(c, dict)]
    if len(names) != len(clips) or not all(names):
        raise ResolveError("Every entry needs a `clip_name`.")
    found = dict(zip(names, app.find_clips_by_name(names)))

    infos = []
    cursor = timeline_start
    for entry in clips:
        mpi = found[entry["clip_name"]]
        info = {"mediaPoolItem": mpi}

        src_in = entry.get("start_frame")
        src_out = entry.get("end_frame")
        if src_in is not None:
            info["startFrame"] = int(src_in)
        if src_out is not None:
            info["endFrame"] = int(src_out)

        track_index = int(entry.get("track_index") or 1)
        info["trackIndex"] = track_index
        if audio_only:
            info["mediaType"] = 2
        elif video_only:
            info["mediaType"] = 1

        at = entry.get("at")
        if at is None:
            record = cursor
        elif isinstance(at, str) and (":" in at or ";" in at):
            record = app.tc_to_abs_frame(at, fps)
        else:
            # recordFrame is ABSOLUTE, and timelines usually start at 01:00:00:00 —
            # a bare frame number means "frames from timeline start".
            record = timeline_start + int(at)
        if record < timeline_start:
            raise ResolveError("Position %r is before the timeline start." % (at,))
        info["recordFrame"] = record

        if src_in is not None and src_out is not None:
            cursor = record + (int(src_out) - int(src_in) + 1)
        else:
            cursor = record + int(mpi.GetClipProperty("Frames") or 0)
        infos.append(info)

    placed = app.media_pool.AppendToTimeline(infos)
    if not placed:
        raise ResolveError(
            "Resolve refused to place the clips. Common causes: the target track "
            "doesn't exist (add it first), the source in/out range is outside the "
            "clip, or another clip already occupies that spot.")
    return {"placed": len(placed), "timeline": tl.GetName(),
            "clips": [c["clip_name"] for c in clips]}


@tool(
    "delete_clips",
    "Delete clips from a track of the current timeline, by their position in the "
    "track (1 = first clip). Set `ripple` to close the gap and pull later clips "
    "back. Destructive — confirm with the user first unless they asked for exactly "
    "this. Use list_timeline_items first to see what's on the track.",
    params={
        "clip_indices": {"type": "array", "description":
                         "1-based positions of clips within the track, e.g. [3] or [2,4].",
                         "items": {"type": "integer"}},
        "track_type": {"type": "string", "description": "video, audio or subtitle (default video)."},
        "track_index": {"type": "integer", "description": "1-based track number (default 1)."},
        "ripple": {"type": "boolean", "description":
                   "Close the gap and shift later clips earlier (default false)."},
    },
    required=["clip_indices"],
)
def t_delete_clips(app, clip_indices, track_type="video", track_index=1, ripple=False):
    tl = app.timeline
    if not _supports(tl, "DeleteClips"):
        raise ResolveError("This version of Resolve has no DeleteClips API (needs 18.5+).")
    items = _track_items(app, track_type, track_index)
    if not items:
        raise ResolveError("%s track %s is empty." % (track_type, track_index))

    picked, bad = [], []
    for n in clip_indices:
        n = int(n)
        if 1 <= n <= len(items):
            picked.append(items[n - 1])
        else:
            bad.append(n)
    if bad:
        raise ResolveError("No clip at position %s on %s track %s (track has %d)."
                           % (", ".join(map(str, bad)), track_type, track_index, len(items)))

    names = [i.GetName() for i in picked]
    if not tl.DeleteClips(picked, bool(ripple)):
        raise ResolveError("Resolve refused to delete those clips (is the track locked?).")
    return {"deleted": names, "ripple": bool(ripple),
            "remaining_on_track": len(_track_items(app, track_type, track_index))}


@tool(
    "set_clip_transform",
    "Change size/position/crop/opacity of a clip — punch in, reframe, crop, fade a "
    "clip's opacity, flip it. Applies to the clip under the playhead unless you give "
    "`track_type`/`track_index`/`clip_index`. Keys: " + ", ".join(sorted(TRANSFORM_KEYS)) +
    ". ZoomX/ZoomY are multipliers where 1.0 is original size (1.2 = 20% punch in).",
    params={
        "properties": {"type": "object", "description":
                       "Map of property name to value, e.g. {\"ZoomX\": 1.2, \"ZoomY\": 1.2}."},
        "track_type": {"type": "string", "description": "video/audio (default: clip under playhead)."},
        "track_index": {"type": "integer", "description": "1-based track number."},
        "clip_index": {"type": "integer", "description": "1-based clip position within the track."},
    },
    required=["properties"],
)
def t_set_clip_transform(app, properties, track_type=None, track_index=None, clip_index=None):
    if not isinstance(properties, dict) or not properties:
        raise ResolveError("`properties` must be a non-empty object.")
    unknown = [k for k in properties if k not in TRANSFORM_KEYS]
    if unknown:
        raise ResolveError("Unknown transform %s. Valid keys: %s"
                           % (", ".join(unknown), ", ".join(sorted(TRANSFORM_KEYS))))

    if clip_index is not None:
        items = _track_items(app, track_type or "video", track_index or 1)
        if not 1 <= int(clip_index) <= len(items):
            raise ResolveError("No clip at position %s (track has %d)." % (clip_index, len(items)))
        item = items[int(clip_index) - 1]
    else:
        item = app.timeline.GetCurrentVideoItem()
        if not item:
            raise ResolveError("No clip under the playhead — move the playhead over one, "
                               "or pass track_index/clip_index.")

    applied, refused = {}, []
    for key, value in properties.items():
        if isinstance(value, bool):
            send = value
        elif isinstance(value, (int, float)):
            send = float(value)
        else:
            try:
                send = float(value)
            except (TypeError, ValueError):
                send = value
        if item.SetProperty(key, send):
            applied[key] = send
        else:
            refused.append(key)
    if refused and not applied:
        raise ResolveError("Resolve refused to set %s on %r (value out of range?)."
                           % (", ".join(refused), item.GetName()))
    out = {"clip": item.GetName(), "applied": applied}
    if refused:
        out["refused"] = refused
    return out


@tool(
    "add_track",
    "Add a track to the current timeline. Needed before placing clips on a track "
    "that doesn't exist yet. Audio tracks take a sub-type (mono, stereo, 5.1, 7.1).",
    params={
        "track_type": {"type": "string", "description": "video, audio or subtitle."},
        "sub_type": {"type": "string", "description":
                     "Audio only: mono, stereo, 5.1, 7.1, adaptive1..adaptive24 (default stereo)."},
    },
    required=["track_type"],
)
def t_add_track(app, track_type, sub_type=None):
    tl = app.timeline
    ttype = str(track_type).strip().lower()
    if ttype not in ("video", "audio", "subtitle"):
        raise ResolveError("track_type must be video, audio or subtitle.")
    if ttype == "audio":
        ok = tl.AddTrack("audio", str(sub_type or "stereo"))
    else:
        ok = tl.AddTrack(ttype)
    if not ok:
        raise ResolveError("Resolve refused to add the %s track." % ttype)
    return {"track_type": ttype, "total_%s_tracks" % ttype: int(tl.GetTrackCount(ttype))}


# -- titles / fusion ---------------------------------------------------------

@tool(
    "add_title",
    "Insert a title at the playhead and set its text. `title_name` is the effect's "
    "name in Resolve's Effects Library — 'Text+' is the standard Fusion title. "
    "Note: Resolve always inserts on the lowest available video track and the API "
    "cannot choose a track or set the duration.",
    params={
        "text": {"type": "string", "description": "The words the title should show."},
        "title_name": {"type": "string", "description": "Effects Library name (default 'Text+')."},
        "at": {"type": "string", "description":
               "Optional timecode or frames from timeline start to insert at (default: playhead)."},
    },
    required=["text"],
)
def t_add_title(app, text, title_name="Text+", at=None):
    tl = app.timeline
    fps = app.timeline_fps(tl)
    if at is not None:
        target = at if (":" in str(at) or ";" in str(at)) else \
            app.abs_frame_to_tc(int(tl.GetStartFrame()) + int(at), fps)
        if not tl.SetCurrentTimecode(str(target)):
            raise ResolveError("Could not move the playhead to %r." % (at,))
        time.sleep(0.2)                     # Resolve needs a moment to settle

    item = tl.InsertFusionTitleIntoTimeline(str(title_name))
    if not item:
        item = tl.InsertTitleIntoTimeline(str(title_name))
    if not item:
        raise ResolveError(
            "Resolve would not insert a title named %r. The name must match the "
            "Effects Library exactly (e.g. 'Text+')." % title_name)

    detail = "inserted"
    try:
        comp = item.GetFusionCompByIndex(1)
        tools = comp.GetToolList(False, "TextPlus") if comp else None
        node = tools[1] if tools else None
        if node is not None:
            node.StyledText = str(text)
            detail = "text set"
        else:
            detail = ("inserted, but this title has no Text+ node to write into — "
                      "set the text by hand")
    except Exception as exc:
        detail = "inserted, but setting the text failed: %s" % exc

    return {"title": title_name, "text": text, "timecode": tl.GetCurrentTimecode(),
            "status": detail}


@tool(
    "add_fusion_effect",
    "Add a Fusion effect node (e.g. Blur, Glow, TransformCanvas) to the clip under "
    "the playhead, wired between the clip and the output. `settings` sets the node's "
    "inputs, e.g. {\"XBlurSize\": 5.0}. Use for effects the Color page can't do.",
    params={
        "effect": {"type": "string", "description":
                   "Fusion tool ID, e.g. Blur, Glow, DirectionalBlur, ColorCorrector."},
        "settings": {"type": "object", "description": "Optional input name -> value map."},
    },
    required=["effect"],
)
def t_add_fusion_effect(app, effect, settings=None):
    item = app.timeline.GetCurrentVideoItem()
    if not item:
        raise ResolveError("No clip under the playhead — move the playhead over one first.")

    comp = None
    try:
        if int(item.GetFusionCompCount() or 0) == 0:
            item.AddFusionComp()
        comp = item.GetFusionCompByIndex(1)
    except Exception as exc:
        raise ResolveError("Could not open a Fusion composition on this clip: %s" % exc)
    if not comp:
        raise ResolveError("Could not open a Fusion composition on this clip.")

    try:
        comp.Lock()
        comp.StartUndo("Claude: add %s" % effect)
        try:
            node = comp.AddTool(str(effect), -32768, -32768)
            if not node:
                raise ResolveError(
                    "Fusion has no tool called %r. Use the tool's ID, e.g. Blur, "
                    "Glow, DirectionalBlur." % effect)

            media_out = (comp.GetToolList(False, "MediaOut") or {}).get(1)
            media_in = (comp.GetToolList(False, "MediaIn") or {}).get(1)
            wired = False
            if media_out is not None and media_in is not None:
                try:
                    node.FindMainInput(1).ConnectTo(media_in.FindMainOutput(1))
                    media_out.FindMainInput(1).ConnectTo(node.FindMainOutput(1))
                    wired = True
                except Exception:
                    wired = False

            applied = {}
            for key, value in (settings or {}).items():
                try:
                    node.SetInput(str(key), value)
                    applied[key] = value
                except Exception:
                    pass
        finally:
            comp.EndUndo(True)
            comp.Unlock()
    except ResolveError:
        raise
    except Exception as exc:
        raise ResolveError("Fusion refused the edit: %s" % exc)

    return {"clip": item.GetName(), "effect": effect, "applied": applied,
            "wired_into_chain": wired,
            "note": ("" if wired else
                     "Node added but not auto-connected — connect it in the Fusion page.")}


# -- color ------------------------------------------------------------------------

MAX_FRAME_BYTES = 4 * 1024 * 1024   # Messages API caps one image at ~5MB; stay clear


def _sniff_image_media_type(data):
    """Trust the bytes, not the file extension Resolve happened to write."""
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if data[:2] == b"\xff\xd8":
        return "image/jpeg"
    return None


def _encode_png_rgb(width, height, rgb):
    """Raw packed RGB888 -> PNG, pure stdlib (for the thumbnail fallback)."""
    import struct
    import zlib

    def chunk(tag, payload):
        c = struct.pack(">I", len(payload)) + tag + payload
        return c + struct.pack(">I", zlib.crc32(tag + payload) & 0xffffffff)

    stride = width * 3
    raw = b"".join(b"\x00" + rgb[y * stride:(y + 1) * stride] for y in range(height))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6))
            + chunk(b"IEND", b""))


def _frame_export_dir():
    """A scratch dir Resolve can definitely write stills into.

    Not tempfile.mkdtemp(): on macOS that lands in /var/folders, which Resolve's
    process cannot write to — ExportStills just returns False. The user config
    dir is home-based on every OS.
    """
    path = os.path.join(os.path.dirname(config_path()), "frame-%d" % os.getpid())
    os.makedirs(path, exist_ok=True)
    return path


def _grab_still_frame(app, tl, project):
    """Full-resolution route: GrabStill -> ExportStills(jpg) -> read -> DeleteStills.

    Returns (data, detail) or (None, why_it_failed).
    """
    still = None
    for _ in range(3):                     # GrabStill is intermittently falsy
        still = tl.GrabStill()
        if still:
            break
        time.sleep(0.25)
    if not still:
        return None, "GrabStill returned nothing (no clip under the playhead?)"

    gallery = project.GetGallery()
    album = gallery.GetCurrentStillAlbum() if gallery else None
    if not album:
        return None, "could not access the Gallery's current still album"

    export_dir = _frame_export_dir()
    try:
        if not album.ExportStills([still], export_dir, "claude_frame", "jpg"):
            return None, ("ExportStills failed — if this keeps happening, make sure "
                          "the Gallery panel is open (Workspace > Gallery)")
        names = sorted(n for n in os.listdir(export_dir)
                       if n.lower().endswith((".jpg", ".jpeg", ".png")))
        if not names:                      # a .drx grade sidecar is always written; ignore it
            return None, "the still export produced no image file"
        with open(os.path.join(export_dir, names[0]), "rb") as f:
            return f.read(), "full-resolution still"
    finally:
        try:
            album.DeleteStills([still])    # leave the user's Gallery untouched
        except Exception:
            pass
        shutil.rmtree(export_dir, ignore_errors=True)


def _thumbnail_frame(app, tl):
    """Fallback route: the Color page thumbnail, in memory, no disk or Gallery.

    Returns (png_bytes, detail) or (None, why_it_failed).
    """
    thumb = None
    try:
        thumb = tl.GetCurrentClipThumbnailImage()
        if not thumb:
            tl.GrabStill()                 # known priming quirk on Resolve 17.3+
            thumb = tl.GetCurrentClipThumbnailImage()
    except Exception as exc:
        return None, "thumbnail call failed: %s" % exc
    if not isinstance(thumb, dict) or not thumb.get("data"):
        return None, "no thumbnail available"
    try:
        width, height = int(thumb["width"]), int(thumb["height"])
        rgb = base64.b64decode(thumb["data"])
        if len(rgb) != width * height * 3:
            return None, ("thumbnail is not raw RGB888 (%d bytes for %dx%d)"
                          % (len(rgb), width, height))
        return _encode_png_rgb(width, height, rgb), "thumbnail (%dx%d)" % (width, height)
    except Exception as exc:
        return None, "could not decode thumbnail: %s" % exc


@tool(
    "view_frame",
    "SEE a frame of the current timeline with your own eyes, as an actual image. "
    "Grabs a still at the playhead (or at `position`) and returns the picture, so "
    "use this whenever the question is about how footage LOOKS: exposure, color "
    "balance, framing, shot content, comparing shots. Grabbed stills are cleaned "
    "out of the Gallery automatically.",
    params={
        "position": {"type": "string",
                     "description": "Optional: 'HH:MM:SS:FF' timecode or integer frames from "
                                    "timeline start. Default: current playhead. The playhead "
                                    "is restored afterwards if moved."},
    },
)
def t_view_frame(app, position=None):
    tl = app.timeline
    project = app.pm.GetCurrentProject()
    fps = app.timeline_fps(tl)

    original_tc = None
    text = str(position).strip() if position is not None else ""
    if text and text.lower() != "playhead":
        original_tc = tl.GetCurrentTimecode()
        if ":" in text or ";" in text:
            target = text
        else:
            try:
                offset = int(text)
            except ValueError:
                raise ResolveError("Position %r is neither a timecode nor a frame number." % position)
            target = app.abs_frame_to_tc(int(tl.GetStartFrame()) + offset, fps)
        if not tl.SetCurrentTimecode(target):
            raise ResolveError("Could not move playhead to %r to grab the frame." % position)

    # Both grab routes only work reliably on the Color page. The playhead
    # survives the page round-trip, so this is a flicker, not a navigation loss.
    page_before = None
    try:
        page_before = app.resolve.GetCurrentPage()
        if page_before != "color":
            app.resolve.OpenPage("color")
    except Exception:
        page_before = None

    try:
        grab_tc = tl.GetCurrentTimecode()
        data, detail = _grab_still_frame(app, tl, project)
        if data is None:
            first_error = detail
            data, detail = _thumbnail_frame(app, tl)
            if data is None:
                raise ResolveError(
                    "Could not capture the frame. Full-res grab: %s. "
                    "Thumbnail fallback: %s." % (first_error, detail))

        media_type = _sniff_image_media_type(data)
        if media_type is None:
            raise ResolveError("The captured frame is not a readable JPEG/PNG.")
        if len(data) > MAX_FRAME_BYTES:
            raise ResolveError(
                "The captured frame is %.1f MB — too large to attach. This can happen "
                "on very high resolution timelines." % (len(data) / 1048576.0))

        return {
            "frame": {
                "timeline": tl.GetName(),
                "timecode": grab_tc,
                "source": detail,
                "file_size_bytes": len(data),
                "note": "The image of this frame is attached to this tool result.",
            },
            "_image_b64": base64.b64encode(data).decode("ascii"),
            "_image_media_type": media_type,
        }
    finally:
        # Leave the user's session exactly as we found it, whatever happened.
        if original_tc:
            try:
                tl.SetCurrentTimecode(original_tc)
            except Exception:
                pass
        if page_before and page_before != "color":
            try:
                app.resolve.OpenPage(page_before)
            except Exception:
                pass


@tool(
    "survey_clip",
    "SEE several frames spread across a range in one go — to scan a clip for "
    "exposure shifts, check continuity across a scene, or find where something "
    "changes. Defaults to sampling the clip under the playhead from start to end; "
    "give `from`/`to` (timecode or frames from timeline start) to survey any range. "
    "Returns each frame as an image, labeled by timecode.",
    params={
        "count": {"type": "integer", "description": "How many frames, 2-6 (default 4)."},
        "from": {"type": "string", "description": "Range start (default: current clip's start)."},
        "to": {"type": "string", "description": "Range end (default: current clip's end)."},
    },
)
def t_survey_clip(app, count=4, **kwargs):
    tl = app.timeline
    project = app.pm.GetCurrentProject()
    fps = app.timeline_fps(tl)
    count = max(2, min(6, int(count)))

    def to_abs(pos, label):
        text = str(pos).strip()
        if ":" in text or ";" in text:
            return app.tc_to_abs_frame(text, fps)
        try:
            return int(tl.GetStartFrame()) + int(text)
        except ValueError:
            raise ResolveError("%s %r is neither a timecode nor a frame number." % (label, pos))

    start = kwargs.get("from")
    end = kwargs.get("to")
    if start is None or end is None:
        item = tl.GetCurrentVideoItem()
        if not item:
            raise ResolveError("No clip under the playhead — move onto a clip, or give "
                               "`from` and `to`.")
        first = start if start is not None else int(item.GetStart())
        last = end if end is not None else int(item.GetEnd()) - 1
    else:
        first, last = start, end
    first = to_abs(first, "from") if not isinstance(first, int) else first
    last = to_abs(last, "to") if not isinstance(last, int) else last
    if last <= first:
        raise ResolveError("`to` must be after `from`.")

    original_tc = tl.GetCurrentTimecode()
    page_before = None
    try:
        page_before = app.resolve.GetCurrentPage()
        if page_before != "color":
            app.resolve.OpenPage("color")
    except Exception:
        page_before = None

    frames, failures = [], []
    total_bytes = 0
    try:
        for i in range(count):
            frame = first + (last - first) * i // (count - 1)
            tc = app.abs_frame_to_tc(frame, fps)
            if not tl.SetCurrentTimecode(tc):
                failures.append({"timecode": tc, "why": "could not move playhead"})
                continue
            time.sleep(0.2)                    # let Resolve settle before grabbing
            data, detail = _grab_still_frame(app, tl, project)
            if data is None:
                data, detail = _thumbnail_frame(app, tl)
            if data is None:
                failures.append({"timecode": tc, "why": detail})
                continue
            media_type = _sniff_image_media_type(data)
            if media_type is None or len(data) > MAX_FRAME_BYTES:
                failures.append({"timecode": tc, "why": "frame unreadable or too large"})
                continue
            if total_bytes + len(data) > 12 * 1024 * 1024:
                failures.append({"timecode": tc,
                                 "why": "skipped — total image payload would exceed 12MB"})
                continue
            total_bytes += len(data)
            frames.append({"tc": tc, "b64": base64.b64encode(data).decode("ascii"),
                           "media_type": media_type, "source": detail})
    finally:
        try:
            tl.SetCurrentTimecode(original_tc)
        except Exception:
            pass
        if page_before and page_before != "color":
            try:
                app.resolve.OpenPage(page_before)
            except Exception:
                pass

    if not frames:
        raise ResolveError("Could not capture any frames: %s"
                           % (failures or "no positions sampled"))
    out = {
        "frames": [{"order": i + 1, "timecode": f["tc"], "source": f["source"]}
                   for i, f in enumerate(frames)],
        "note": "The images are attached in the same order as this list.",
        "_images": [{"b64": f["b64"], "media_type": f["media_type"]} for f in frames],
    }
    if failures:
        out["failed_positions"] = failures
    return out


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


def _current_item(app, what="grade"):
    item = app.timeline.GetCurrentVideoItem()
    if not item:
        raise ResolveError("No clip under the playhead — move the playhead over the "
                           "clip you want to %s (Color or Edit page)." % what)
    return item


def _node_graph(app, item):
    """The Graph object for a clip, or None on Resolve < 19."""
    if not _supports(item, "GetNodeGraph"):
        return None
    try:
        return item.GetNodeGraph()
    except Exception:
        return None


@tool(
    "copy_grade",
    "Copy the grade from one clip to others — the reliable way to match a look "
    "across shots. Source is the clip under the playhead unless `from_clip_index` "
    "is given. Targets are 1-based clip positions on the track.",
    params={
        "to_clip_indices": {"type": "array", "description":
                            "1-based clip positions to copy the grade ONTO, e.g. [4,5,6].",
                            "items": {"type": "integer"}},
        "from_clip_index": {"type": "integer", "description":
                            "1-based source clip position (default: clip under playhead)."},
        "track_index": {"type": "integer", "description": "1-based video track (default 1)."},
    },
    required=["to_clip_indices"],
)
def t_copy_grade(app, to_clip_indices, from_clip_index=None, track_index=1):
    items = _track_items(app, "video", track_index)
    if not items:
        raise ResolveError("Video track %s is empty." % track_index)

    if from_clip_index is not None:
        if not 1 <= int(from_clip_index) <= len(items):
            raise ResolveError("No clip at position %s (track has %d)."
                               % (from_clip_index, len(items)))
        source = items[int(from_clip_index) - 1]
    else:
        source = _current_item(app, "copy from")

    targets, bad = [], []
    for n in to_clip_indices:
        n = int(n)
        if 1 <= n <= len(items):
            targets.append(items[n - 1])
        else:
            bad.append(n)
    if bad:
        raise ResolveError("No clip at position %s (track has %d)."
                           % (", ".join(map(str, bad)), len(items)))
    if not targets:
        raise ResolveError("No target clips given.")

    if not source.CopyGrades(targets):
        raise ResolveError("Resolve refused to copy the grade.")
    return {"from": source.GetName(), "to": [t.GetName() for t in targets],
            "count": len(targets)}


@tool(
    "color_version",
    "Manage colour versions on the clip under the playhead — snapshots of a grade "
    "you can return to. Actions: 'list', 'add' (save current grade under `name`), "
    "'load' (switch to a saved version), 'delete'. Adding a version before "
    "experimenting gives the user a way back.",
    params={
        "action": {"type": "string", "description": "list, add, load or delete."},
        "name": {"type": "string", "description": "Version name (required except for 'list')."},
    },
    required=["action"],
)
def t_color_version(app, action, name=None):
    item = _current_item(app, "version")
    act = str(action).strip().lower()
    if act == "list":
        return {"clip": item.GetName(),
                "versions": list(item.GetVersionNameList(0) or []),
                "current": item.GetCurrentVersion() or {}}
    if not name:
        raise ResolveError("`name` is required for action %r." % act)
    if act == "add":
        if not item.AddVersion(str(name), 0):
            raise ResolveError("Could not add version %r (does it already exist?)." % name)
    elif act == "load":
        if not item.LoadVersionByName(str(name), 0):
            raise ResolveError("No colour version named %r on this clip." % name)
    elif act == "delete":
        if not item.DeleteVersionByName(str(name), 0):
            raise ResolveError("Could not delete version %r." % name)
    else:
        raise ResolveError("action must be list, add, load or delete.")
    return {"clip": item.GetName(), "action": act, "version": name,
            "versions": list(item.GetVersionNameList(0) or [])}


@tool(
    "reset_grade",
    "Reset ALL grades on the clip under the playhead back to neutral. Destructive "
    "and not undoable through this tool — confirm with the user, and consider "
    "saving a colour version first.",
)
def t_reset_grade(app):
    item = _current_item(app, "reset")
    graph = _node_graph(app, item)
    if graph is None:
        raise ResolveError("This version of Resolve has no node graph API (needs 19.0+).")
    if not graph.ResetAllGrades():
        raise ResolveError("Resolve refused to reset the grade.")
    return {"clip": item.GetName(), "reset": True}


@tool(
    "set_cdl",
    "Set colour on the clip under the playhead using ASC CDL — the ONLY way to "
    "change colour numerically. Slope multiplies (gain), offset adds (lift), power "
    "is gamma; each takes three numbers for R G B, neutral is slope 1/offset 0/"
    "power 1. Warmer = more red slope, less blue. IMPORTANT: this is write-only — "
    "you cannot read the clip's current values, so every call OVERWRITES that "
    "node's CDL absolutely rather than nudging it. A colour version is saved first "
    "so the user can get back. Tell the user what you're applying and why.",
    params={
        "slope": {"type": "array", "description": "R G B gain, neutral [1,1,1].",
                  "items": {"type": "number"}},
        "offset": {"type": "array", "description": "R G B lift, neutral [0,0,0].",
                   "items": {"type": "number"}},
        "power": {"type": "array", "description": "R G B gamma, neutral [1,1,1].",
                  "items": {"type": "number"}},
        "saturation": {"type": "number", "description": "Saturation, neutral 1.0."},
        "node_index": {"type": "integer", "description": "1-based node to write to (default 1)."},
    },
)
def t_set_cdl(app, slope=None, offset=None, power=None, saturation=None, node_index=1):
    item = _current_item(app, "grade")
    if slope is None and offset is None and power is None and saturation is None:
        raise ResolveError("Give at least one of slope, offset, power or saturation.")

    def triplet(values, default, label):
        if values is None:
            return default
        if not isinstance(values, (list, tuple)) or len(values) != 3:
            raise ResolveError("%s must be three numbers, e.g. [1.05, 1.0, 0.95]." % label)
        try:
            return " ".join("%.6g" % float(v) for v in values)
        except (TypeError, ValueError):
            raise ResolveError("%s must be three numbers." % label)

    graph = _node_graph(app, item)
    total = None
    if graph is not None:
        try:
            total = int(graph.GetNumNodes() or 0)
        except Exception:
            total = None
    if total and not 1 <= int(node_index) <= total:
        raise ResolveError("Node %s does not exist — this clip has %d node(s)."
                           % (node_index, total))

    # Blind absolute write, so leave the user a way back before touching anything.
    undo_version = "before_claude_cdl"
    saved = False
    try:
        saved = bool(item.AddVersion(undo_version, 0))
    except Exception:
        saved = False

    cdl = {
        "NodeIndex": str(int(node_index)),
        "Slope": triplet(slope, "1 1 1", "slope"),
        "Offset": triplet(offset, "0 0 0", "offset"),
        "Power": triplet(power, "1 1 1", "power"),
        "Saturation": "%.6g" % float(saturation if saturation is not None else 1.0),
    }
    if not item.SetCDL(cdl):
        raise ResolveError("Resolve refused the CDL values (check the node index and ranges).")

    return {
        "clip": item.GetName(),
        "applied": cdl,
        "undo_version": undo_version if saved else None,
        "note": ("Saved colour version %r first — load it with color_version to undo."
                 % undo_version if saved else
                 "Could not save an undo version first (one may already exist)."),
    }


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
    ok = False
    # Current API: LUTs live on the node graph. item.SetLUT is the legacy path.
    try:
        graph = item.GetNodeGraph()
        if graph:
            ok = graph.SetLUT(int(node_index), lut_path)
    except Exception:
        ok = False
    if not ok:
        try:
            ok = item.SetLUT(int(node_index), lut_path)
        except Exception:
            ok = False
    if not ok:
        raise ResolveError("SetLUT failed — check the LUT path and node index "
                           "(the LUT may need to be in Resolve's LUT folder; "
                           "try project.RefreshLUTList via run_python).")
    return {"applied_lut": lut_path, "node": int(node_index), "clip": item.GetName()}


# -- audio / transcription ----------------------------------------------------

def _resolve_const(app, name):
    """A resolve.* constant, validated as a real int.

    Resolve's bridge fabricates a callable for ANY attribute, so a missing
    constant comes back as a function, not a number — never pass that through.
    """
    value = getattr(app.resolve, name, None)
    if not isinstance(value, int):
        raise ResolveError("This version of Resolve does not define %s." % name)
    return value


@tool(
    "transcribe_audio",
    "Transcribe a clip's (or a whole bin's) audio with Resolve's built-in speech "
    "recognition. The text powers Resolve's text-based search and auto captions — "
    "to read the words, run auto_caption afterwards and list the subtitle track. "
    "Actions: 'transcribe' or 'clear'.",
    params={
        "clip_name": {"type": "string", "description": "One clip by exact name."},
        "folder_path": {"type": "string", "description":
                        "Or a media pool folder like '/Interviews' (whole bin, recursive)."},
        "action": {"type": "string", "description": "transcribe (default) or clear."},
    },
)
def t_transcribe_audio(app, clip_name=None, folder_path=None, action="transcribe"):
    act = str(action).strip().lower()
    if act not in ("transcribe", "clear"):
        raise ResolveError("action must be transcribe or clear.")
    if bool(clip_name) == bool(folder_path):
        raise ResolveError("Give exactly one of clip_name or folder_path.")

    target = (app.find_clips_by_name([clip_name])[0] if clip_name
              else app.folder_by_path(folder_path))
    label = clip_name or folder_path
    method = "TranscribeAudio" if act == "transcribe" else "ClearTranscription"
    if not _supports(target, method):
        raise ResolveError("This version of Resolve cannot %s %s from a script."
                           % (act, "folders" if folder_path else "clips"))
    if not getattr(target, method)():
        raise ResolveError("Resolve reported failure %sing %r — transcription needs "
                           "audio in the clip and may need the language pack installed."
                           % (act.rstrip('e'), label))
    return {"action": act, "target": label,
            "note": ("Transcription runs in the background; captions and text search "
                     "use it once it finishes." if act == "transcribe" else "cleared")}


@tool(
    "auto_caption",
    "Generate a subtitle track for the current timeline from its audio (Resolve's "
    "auto-captions). Read the resulting text with list_timeline_items on "
    "track_type='subtitle'. Takes a while on long timelines.",
)
def t_auto_caption(app):
    tl = app.timeline
    if not _supports(tl, "CreateSubtitlesFromAudio"):
        raise ResolveError("This version of Resolve cannot create captions from a script.")
    try:
        ok = tl.CreateSubtitlesFromAudio()
    except TypeError:
        ok = tl.CreateSubtitlesFromAudio({})
    if not ok:
        raise ResolveError("Resolve could not generate captions (is there audible "
                           "speech on an enabled audio track?).")
    return {"timeline": tl.GetName(),
            "subtitle_tracks": int(tl.GetTrackCount("subtitle") or 0),
            "note": "Read the text with list_timeline_items(track_type='subtitle')."}


@tool(
    "sync_audio",
    "Auto-sync separately recorded audio to camera clips (waveform or timecode "
    "match), like right-click > Auto Sync Audio. Give at least one video clip and "
    "one audio clip by name. Requires Resolve 19.1+.",
    params={
        "clip_names": {"type": "array", "description":
                       "Media pool clip names — at least one video and one audio.",
                       "items": {"type": "string"}},
        "mode": {"type": "string", "description": "waveform (default) or timecode."},
    },
    required=["clip_names"],
)
def t_sync_audio(app, clip_names, mode="waveform"):
    if not isinstance(clip_names, list) or len(clip_names) < 2:
        raise ResolveError("Need at least two clips (one video + one audio).")
    mp = app.media_pool
    if not _supports(mp, "AutoSyncAudio"):
        raise ResolveError("AutoSyncAudio needs Resolve 19.1 or newer.")
    clips = app.find_clips_by_name(clip_names)
    mode_const = _resolve_const(app, "AUDIO_SYNC_WAVEFORM"
                                if str(mode).lower() != "timecode" else "AUDIO_SYNC_TIMECODE")
    settings = {_resolve_const(app, "AUDIO_SYNC_MODE"): mode_const}
    if not mp.AutoSyncAudio(clips, settings):
        raise ResolveError("Resolve could not sync these clips — check there's at "
                           "least one video and one audio clip, with overlapping "
                           "%s." % ("waveforms" if mode != "timecode" else "timecode"))
    return {"synced": clip_names, "mode": mode}


# -- timeline operations -------------------------------------------------------

EXPORT_FORMATS = {
    # format -> (exportType const, exportSubtype const or None)
    "aaf": ("EXPORT_AAF", "EXPORT_AAF_NEW"),
    "drt": ("EXPORT_DRT", None),
    "edl": ("EXPORT_EDL", "EXPORT_NONE"),
    "fcp7xml": ("EXPORT_FCP_7_XML", None),
    "fcpxml": ("EXPORT_FCPXML_1_10", None),
    "otio": ("EXPORT_OTIO", None),
    "csv": ("EXPORT_TEXT_CSV", None),
    "ale": ("EXPORT_ALE", None),
    "hdr10a": ("EXPORT_HDR_10_PROFILE_A", None),
    "hdr10b": ("EXPORT_HDR_10_PROFILE_B", None),
    "dolbyvision2.9": ("EXPORT_DOLBY_VISION_VER_2_9", None),
    "dolbyvision4.0": ("EXPORT_DOLBY_VISION_VER_4_0", None),
    "dolbyvision5.1": ("EXPORT_DOLBY_VISION_VER_5_1", None),
}


@tool(
    "export_timeline",
    "Export the current timeline to an interchange file for other apps: formats "
    + ", ".join(sorted(EXPORT_FORMATS)) +
    ". `file_path` is the absolute output path including filename.",
    params={
        "file_path": {"type": "string", "description": "Absolute path to write."},
        "format": {"type": "string", "description": "One of: " + ", ".join(sorted(EXPORT_FORMATS))},
    },
    required=["file_path", "format"],
)
def t_export_timeline(app, file_path, format):
    fmt = str(format).strip().lower()
    if fmt not in EXPORT_FORMATS:
        raise ResolveError("Unknown format %r. Choose from: %s"
                           % (format, ", ".join(sorted(EXPORT_FORMATS))))
    type_name, sub_name = EXPORT_FORMATS[fmt]
    tl = app.timeline
    export_type = _resolve_const(app, type_name)
    if sub_name is not None:
        ok = tl.Export(str(file_path), export_type, _resolve_const(app, sub_name))
    else:
        ok = tl.Export(str(file_path), export_type)
    if not ok:
        raise ResolveError("Resolve refused the export — check the directory exists "
                           "and is writable.")
    return {"exported": tl.GetName(), "format": fmt, "file": file_path}


@tool(
    "import_timeline",
    "Create a NEW timeline from an interchange file (AAF/EDL/XML/FCPXML/DRT/OTIO). "
    "This is also the escape hatch for edits the API can't do directly: export, "
    "modify the file, re-import as a new timeline.",
    params={
        "file_path": {"type": "string", "description": "Absolute path of the file."},
        "timeline_name": {"type": "string", "description": "Name for the new timeline."},
    },
    required=["file_path"],
)
def t_import_timeline(app, file_path, timeline_name=None):
    if not os.path.exists(str(file_path)):
        raise ResolveError("No file at %r." % file_path)
    mp = app.media_pool
    options = {"timelineName": str(timeline_name)} if timeline_name else {}
    tl = mp.ImportTimelineFromFile(str(file_path), options)
    if not tl:
        raise ResolveError("Resolve could not import %r — unsupported contents, or "
                           "source media unavailable." % file_path)
    return {"imported": tl.GetName(), "from": file_path}


@tool(
    "duplicate_timeline",
    "Duplicate the current timeline — a safe snapshot before big changes.",
    params={"new_name": {"type": "string", "description": "Name for the copy."}},
)
def t_duplicate_timeline(app, new_name=None):
    tl = app.timeline
    if not _supports(tl, "DuplicateTimeline"):
        raise ResolveError("This version of Resolve cannot duplicate timelines from a script.")
    copy = tl.DuplicateTimeline(str(new_name)) if new_name else tl.DuplicateTimeline()
    if not copy:
        raise ResolveError("Resolve refused to duplicate the timeline.")
    return {"duplicated": tl.GetName(), "copy": copy.GetName()}


@tool(
    "create_compound_clip",
    "Collapse clips on the current timeline into one compound clip. Pick the clips "
    "by their 1-based positions on a track (see list_timeline_items).",
    params={
        "clip_indices": {"type": "array", "description": "1-based positions, e.g. [2,3,4].",
                         "items": {"type": "integer"}},
        "track_type": {"type": "string", "description": "video or audio (default video)."},
        "track_index": {"type": "integer", "description": "1-based track (default 1)."},
        "name": {"type": "string", "description": "Name for the compound clip."},
    },
    required=["clip_indices"],
)
def t_create_compound_clip(app, clip_indices, track_type="video", track_index=1, name=None):
    tl = app.timeline
    if not _supports(tl, "CreateCompoundClip"):
        raise ResolveError("This version of Resolve cannot create compound clips from a script.")
    items = _track_items(app, track_type, track_index)
    picked = []
    for n in clip_indices:
        n = int(n)
        if not 1 <= n <= len(items):
            raise ResolveError("No clip at position %d (track has %d)." % (n, len(items)))
        picked.append(items[n - 1])
    info = {"name": str(name)} if name else {}
    made = tl.CreateCompoundClip(picked, info)
    if not made:
        raise ResolveError("Resolve refused to create the compound clip.")
    return {"compound_clip": made.GetName(), "from_clips": [i.GetName() for i in picked]}


@tool(
    "manage_track",
    "Rename, lock/unlock, or enable/disable a track of the current timeline. "
    "Actions: rename, lock, unlock, enable, disable, info.",
    params={
        "action": {"type": "string", "description": "rename, lock, unlock, enable, disable or info."},
        "track_type": {"type": "string", "description": "video, audio or subtitle."},
        "track_index": {"type": "integer", "description": "1-based track number."},
        "name": {"type": "string", "description": "New name (rename only)."},
    },
    required=["action", "track_type", "track_index"],
)
def t_manage_track(app, action, track_type, track_index, name=None):
    tl = app.timeline
    ttype = str(track_type).strip().lower()
    idx = int(track_index)
    count = int(tl.GetTrackCount(ttype) or 0)
    if not 1 <= idx <= count:
        raise ResolveError("%s track %d does not exist (timeline has %d)." % (ttype, idx, count))
    act = str(action).strip().lower()

    if act == "rename":
        if not name:
            raise ResolveError("`name` is required for rename.")
        if not tl.SetTrackName(ttype, idx, str(name)):
            raise ResolveError("Resolve refused to rename the track.")
    elif act in ("lock", "unlock"):
        if not tl.SetTrackLock(ttype, idx, act == "lock"):
            raise ResolveError("Resolve refused to change the track lock.")
    elif act in ("enable", "disable"):
        if not tl.SetTrackEnable(ttype, idx, act == "enable"):
            raise ResolveError("Resolve refused to change the track enable state.")
    elif act != "info":
        raise ResolveError("action must be rename, lock, unlock, enable, disable or info.")

    return {"track": "%s %d" % (ttype, idx),
            "name": tl.GetTrackName(ttype, idx),
            "enabled": bool(tl.GetIsTrackEnabled(ttype, idx)),
            "locked": bool(tl.GetIsTrackLocked(ttype, idx)),
            "clips": len(tl.GetItemListInTrack(ttype, idx) or [])}


@tool(
    "label_clip",
    "Color-code clips for organisation: set or clear a clip's color, or add/clear "
    "flags. Targets clips by 1-based position on a track, or the clip under the "
    "playhead if no position given.",
    params={
        "clip_color": {"type": "string", "description":
                       "Clip color name (e.g. Orange, Teal, Purple), or 'clear'."},
        "flag_color": {"type": "string", "description":
                       "Flag color to add (e.g. Red, Blue), or 'clear' to remove all flags."},
        "clip_indices": {"type": "array", "description":
                         "1-based clip positions (default: clip under playhead).",
                         "items": {"type": "integer"}},
        "track_type": {"type": "string", "description": "Track type (default video)."},
        "track_index": {"type": "integer", "description": "1-based track (default 1)."},
    },
)
def t_label_clip(app, clip_color=None, flag_color=None, clip_indices=None,
                 track_type="video", track_index=1):
    if clip_color is None and flag_color is None:
        raise ResolveError("Give clip_color and/or flag_color.")

    if clip_indices:
        items = _track_items(app, track_type, track_index)
        targets = []
        for n in clip_indices:
            n = int(n)
            if not 1 <= n <= len(items):
                raise ResolveError("No clip at position %d (track has %d)." % (n, len(items)))
            targets.append(items[n - 1])
    else:
        targets = [_current_item(app, "label")]

    done = []
    for item in targets:
        result = {"clip": item.GetName()}
        if clip_color is not None:
            if str(clip_color).lower() == "clear":
                if not (_supports(item, "ClearClipColor") and item.ClearClipColor()):
                    raise ResolveError("Could not clear the clip color on %r." % item.GetName())
                result["clip_color"] = "cleared"
            else:
                if not item.SetClipColor(str(clip_color)):
                    raise ResolveError("Resolve rejected clip color %r — use a name from "
                                       "the clip-color menu (Orange, Teal, ...)." % clip_color)
                result["clip_color"] = clip_color
        if flag_color is not None:
            if str(flag_color).lower() == "clear":
                if not (_supports(item, "ClearFlags") and item.ClearFlags("All")):
                    raise ResolveError("Could not clear flags on %r." % item.GetName())
                result["flags"] = "cleared"
            else:
                if not (_supports(item, "AddFlag") and item.AddFlag(str(flag_color))):
                    raise ResolveError("Resolve rejected flag color %r." % flag_color)
                result["flag_added"] = flag_color
        done.append(result)
    return {"labeled": done}


# -- grading extras ------------------------------------------------------------

@tool(
    "color_group",
    "Manage colour groups (grade many shots as one unit, Resolve 19+). Actions: "
    "'create' a group, 'list' groups, 'assign' clips to a group by track position, "
    "'remove' clips from their group, 'delete' a group.",
    params={
        "action": {"type": "string", "description": "create, list, assign, remove or delete."},
        "group_name": {"type": "string", "description": "Group name (create/assign/delete)."},
        "clip_indices": {"type": "array", "description":
                         "1-based clip positions on video track (assign/remove).",
                         "items": {"type": "integer"}},
        "track_index": {"type": "integer", "description": "1-based video track (default 1)."},
    },
    required=["action"],
)
def t_color_group(app, action, group_name=None, clip_indices=None, track_index=1):
    project = app.project
    if not _supports(project, "AddColorGroup"):
        raise ResolveError("Colour groups need Resolve 19 or newer.")
    act = str(action).strip().lower()

    def find_group(name):
        for g in project.GetColorGroupsList() or []:
            if g.GetName() == name:
                return g
        raise ResolveError("No colour group named %r." % name)

    if act == "list":
        return {"groups": [g.GetName() for g in project.GetColorGroupsList() or []]}
    if act == "create":
        if not group_name:
            raise ResolveError("`group_name` is required.")
        if not project.AddColorGroup(str(group_name)):
            raise ResolveError("Could not create group %r (name must be unique)." % group_name)
        return {"created": group_name}
    if act == "delete":
        if not group_name:
            raise ResolveError("`group_name` is required.")
        if not project.DeleteColorGroup(find_group(group_name)):
            raise ResolveError("Could not delete group %r." % group_name)
        return {"deleted": group_name}

    if act in ("assign", "remove"):
        if not clip_indices:
            raise ResolveError("`clip_indices` is required for %s." % act)
        items = _track_items(app, "video", track_index)
        picked = []
        for n in clip_indices:
            n = int(n)
            if not 1 <= n <= len(items):
                raise ResolveError("No clip at position %d (track has %d)." % (n, len(items)))
            picked.append(items[n - 1])
        if act == "assign":
            if not group_name:
                raise ResolveError("`group_name` is required for assign.")
            group = find_group(group_name)
            failed = [i.GetName() for i in picked if not i.AssignToColorGroup(group)]
        else:
            failed = [i.GetName() for i in picked if not i.RemoveFromColorGroup()]
        if failed:
            raise ResolveError("Failed for: %s" % ", ".join(failed))
        return {act + "ed": [i.GetName() for i in picked],
                "group": group_name if act == "assign" else None}

    raise ResolveError("action must be create, list, assign, remove or delete.")


LUT_SIZES = {"17": "EXPORT_LUT_17PTCUBE", "33": "EXPORT_LUT_33PTCUBE",
             "65": "EXPORT_LUT_65PTCUBE", "vlut": "EXPORT_LUT_PANASONICVLUT"}


@tool(
    "export_grade_as_lut",
    "Bake the grade of the clip under the playhead into a .cube LUT file — reuse "
    "the look on other clips, projects, or cameras. Resolve 19+. Note windows and "
    "keyframes can't be carried by a LUT.",
    params={
        "file_path": {"type": "string", "description":
                      "Absolute output path incl. filename (.cube appended if missing)."},
        "size": {"type": "string", "description": "17, 33 (default), 65, or vlut."},
    },
    required=["file_path"],
)
def t_export_grade_as_lut(app, file_path, size="33"):
    item = _current_item(app, "export")
    if not _supports(item, "ExportLUT"):
        raise ResolveError("ExportLUT needs Resolve 19 or newer.")
    key = str(size).strip().lower()
    if key not in LUT_SIZES:
        raise ResolveError("size must be one of: %s" % ", ".join(sorted(LUT_SIZES)))
    if not item.ExportLUT(_resolve_const(app, LUT_SIZES[key]), str(file_path)):
        raise ResolveError("Resolve refused the LUT export — check the directory exists.")
    return {"clip": item.GetName(), "lut": file_path, "size": key}


# -- project management ---------------------------------------------------------

@tool(
    "manage_project",
    "List, create, or open projects in the current project-manager folder. "
    "Actions: 'list', 'create' (and switch to it), 'open'. Opening another project "
    "closes the current one — save first and confirm with the user.",
    params={
        "action": {"type": "string", "description": "list, create or open."},
        "name": {"type": "string", "description": "Project name (create/open)."},
    },
    required=["action"],
)
def t_manage_project(app, action, name=None):
    pm = app.pm
    act = str(action).strip().lower()
    if act == "list":
        if not _supports(pm, "GetProjectListInCurrentFolder"):
            raise ResolveError("Cannot list projects on this version of Resolve.")
        return {"projects": list(pm.GetProjectListInCurrentFolder() or []),
                "current": app.project.GetName()}
    if not name:
        raise ResolveError("`name` is required for %s." % act)
    if act == "create":
        if not (_supports(pm, "CreateProject") and pm.CreateProject(str(name))):
            raise ResolveError("Could not create project %r (name may already exist)." % name)
        return {"created": name, "current": app.project.GetName()}
    if act == "open":
        if not (_supports(pm, "LoadProject") and pm.LoadProject(str(name))):
            raise ResolveError("Could not open project %r — check the name with 'list'." % name)
        return {"opened": name}
    raise ResolveError("action must be list, create or open.")


# -- more editing / media -------------------------------------------------------

@tool(
    "detect_scene_cuts",
    "Run Resolve's automatic scene-cut detection on the current timeline — razors "
    "long recordings into shots at detected cuts. Changes the timeline (adds edits); "
    "confirm with the user first. Can take a while on long timelines.",
)
def t_detect_scene_cuts(app):
    tl = app.timeline
    if not _supports(tl, "DetectSceneCuts"):
        raise ResolveError("This version of Resolve cannot detect scene cuts from a script.")
    before = sum(len(tl.GetItemListInTrack("video", i) or [])
                 for i in range(1, int(tl.GetTrackCount("video") or 0) + 1))
    if not tl.DetectSceneCuts():
        raise ResolveError("Scene cut detection failed or found nothing to cut.")
    after = sum(len(tl.GetItemListInTrack("video", i) or [])
                for i in range(1, int(tl.GetTrackCount("video") or 0) + 1))
    return {"timeline": tl.GetName(), "clips_before": before, "clips_after": after}


@tool(
    "set_voice_isolation",
    "Turn Resolve's AI Voice Isolation on/off for clips (cleans dialogue by "
    "suppressing background noise). Resolve 20.1+, Studio. Applies to the clip "
    "under the playhead, or to `clip_indices` on an audio/video track.",
    params={
        "enabled": {"type": "boolean", "description": "Turn isolation on or off."},
        "amount": {"type": "integer", "description": "Strength 0-100 (default 50)."},
        "clip_indices": {"type": "array", "description": "1-based clip positions (optional).",
                         "items": {"type": "integer"}},
        "track_type": {"type": "string", "description": "audio or video (default audio)."},
        "track_index": {"type": "integer", "description": "1-based track (default 1)."},
    },
    required=["enabled"],
)
def t_set_voice_isolation(app, enabled, amount=50, clip_indices=None,
                          track_type="audio", track_index=1):
    amount = max(0, min(100, int(amount)))
    if clip_indices:
        items = _track_items(app, track_type, track_index)
        targets = []
        for n in clip_indices:
            n = int(n)
            if not 1 <= n <= len(items):
                raise ResolveError("No clip at position %d (track has %d)." % (n, len(items)))
            targets.append(items[n - 1])
    else:
        targets = [_current_item(app, "isolate")]

    state = {"isEnabled": bool(enabled), "amount": amount}
    done, failed = [], []
    for item in targets:
        if _supports(item, "SetVoiceIsolationState") and item.SetVoiceIsolationState(dict(state)):
            done.append(item.GetName())
        else:
            failed.append(item.GetName())
    if failed and not done:
        raise ResolveError("Voice Isolation was refused (needs Resolve 20.1+ Studio, "
                           "and clips with audio). Failed: %s" % ", ".join(failed))
    out = {"voice_isolation": state, "applied_to": done}
    if failed:
        out["failed"] = failed
    return out


@tool(
    "manage_proxy",
    "Link or unlink proxy media for a clip. `link` attaches a proxy file to a "
    "media pool clip; `unlink` detaches it. Refuses cleanly if this Resolve "
    "version has no proxy API.",
    params={
        "action": {"type": "string", "description": "link or unlink."},
        "clip_name": {"type": "string", "description": "Media pool clip by exact name."},
        "proxy_path": {"type": "string", "description": "Absolute path to the proxy file (link only)."},
    },
    required=["action", "clip_name"],
)
def t_manage_proxy(app, action, clip_name, proxy_path=None):
    clip = app.find_clips_by_name([clip_name])[0]
    act = str(action).strip().lower()
    if act == "link":
        if not proxy_path:
            raise ResolveError("`proxy_path` is required to link.")
        if not _supports(clip, "LinkProxyMedia"):
            raise ResolveError("This version of Resolve has no proxy-linking API.")
        if not clip.LinkProxyMedia(str(proxy_path)):
            raise ResolveError("Resolve refused to link that proxy (resolution/codec "
                               "must be compatible with the original).")
        return {"linked": clip_name, "proxy": proxy_path}
    if act == "unlink":
        if not _supports(clip, "UnlinkProxyMedia"):
            raise ResolveError("This version of Resolve has no proxy-linking API.")
        if not clip.UnlinkProxyMedia():
            raise ResolveError("Resolve refused to unlink the proxy.")
        return {"unlinked": clip_name}
    raise ResolveError("action must be link or unlink.")


@tool(
    "manage_takes",
    "Take selector on the clip under the playhead — audition alternate takes in "
    "place, the closest thing Resolve's API has to swapping a clip. Actions: 'add' "
    "(a media pool clip as a take), 'list', 'select' (by 1-based index), "
    "'finalize' (keep selected take), 'delete' (by index).",
    params={
        "action": {"type": "string", "description": "add, list, select, finalize or delete."},
        "clip_name": {"type": "string", "description": "Media pool clip to add as a take."},
        "take_index": {"type": "integer", "description": "1-based take (select/delete)."},
        "start_frame": {"type": "integer", "description": "Source in-point for add."},
        "end_frame": {"type": "integer", "description": "Source out-point for add."},
    },
    required=["action"],
)
def t_manage_takes(app, action, clip_name=None, take_index=None,
                   start_frame=None, end_frame=None):
    item = _current_item(app, "use takes on")
    act = str(action).strip().lower()
    if not _supports(item, "GetTakesCount"):
        raise ResolveError("This version of Resolve has no take-selector API.")

    if act == "add":
        if not clip_name:
            raise ResolveError("`clip_name` is required for add.")
        mpi = app.find_clips_by_name([clip_name])[0]
        if start_frame is not None and end_frame is not None:
            ok = item.AddTake(mpi, int(start_frame), int(end_frame))
        else:
            ok = item.AddTake(mpi)
        if not ok:
            raise ResolveError("Resolve refused to add %r as a take." % clip_name)
    elif act == "select":
        if take_index is None:
            raise ResolveError("`take_index` is required for select.")
        if not item.SelectTakeByIndex(int(take_index)):
            raise ResolveError("No take %s on this clip." % take_index)
    elif act == "delete":
        if take_index is None:
            raise ResolveError("`take_index` is required for delete.")
        if not item.DeleteTakeByIndex(int(take_index)):
            raise ResolveError("Could not delete take %s." % take_index)
    elif act == "finalize":
        if not item.FinalizeTake():
            raise ResolveError("Could not finalize the take.")
    elif act != "list":
        raise ResolveError("action must be add, list, select, finalize or delete.")

    return {"clip": item.GetName(),
            "takes": int(item.GetTakesCount() or 0),
            "selected": int(item.GetSelectedTakeIndex() or 0)}


# -- looks library ---------------------------------------------------------------

def _looks_dir():
    path = os.path.join(os.path.dirname(config_path()), "looks")
    os.makedirs(path, exist_ok=True)
    return path


@tool(
    "save_look",
    "Save the grade of the clip under the playhead into the plugin's looks library "
    "as a named .drx file — building a reusable palette of looks that apply_look "
    "can put on any clip later.",
    params={"name": {"type": "string", "description": "Name for the look, e.g. 'warm sunset'."}},
    required=["name"],
)
def t_save_look(app, name):
    safe = re.sub(r"[^\w\- ]", "", str(name)).strip()
    if not safe:
        raise ResolveError("Give the look a usable name.")
    tl = app.timeline
    project = app.pm.GetCurrentProject()

    page_before = None
    try:
        page_before = app.resolve.GetCurrentPage()
        if page_before != "color":
            app.resolve.OpenPage("color")
    except Exception:
        page_before = None

    still, album = None, None
    try:
        for _ in range(3):
            still = tl.GrabStill()
            if still:
                break
            time.sleep(0.25)
        if not still:
            raise ResolveError("Could not grab the grade (no clip under the playhead?).")
        gallery = project.GetGallery()
        album = gallery.GetCurrentStillAlbum() if gallery else None
        if not album:
            raise ResolveError("Could not access the Gallery.")
        if not album.ExportStills([still], _looks_dir(), safe, "drx"):
            raise ResolveError("Resolve refused to export the grade (is the Gallery "
                               "panel open?).")
        made = [f for f in os.listdir(_looks_dir())
                if f.startswith(safe) and f.lower().endswith(".drx")]
        if not made:
            raise ResolveError("The export produced no .drx file.")
        return {"saved_look": safe, "file": os.path.join(_looks_dir(), sorted(made)[-1]),
                "library": _looks_dir()}
    finally:
        if still is not None and album is not None:
            try:
                album.DeleteStills([still])
            except Exception:
                pass
        if page_before and page_before != "color":
            try:
                app.resolve.OpenPage(page_before)
            except Exception:
                pass


@tool(
    "list_looks",
    "List the saved looks in the plugin's looks library (built with save_look; "
    "you can also drop .drx files into the folder by hand).",
)
def t_list_looks(app):
    looks = sorted(f for f in os.listdir(_looks_dir()) if f.lower().endswith(".drx"))
    return {"looks": looks, "library": _looks_dir()}


@tool(
    "apply_look",
    "Apply a saved look (.drx from the looks library) to the grade of the clip "
    "under the playhead. Resolve 19.1+. Overwrites the clip's current grade — a "
    "colour version is saved first as an undo net.",
    params={"name": {"type": "string", "description": "Look name or filename from list_looks."}},
    required=["name"],
)
def t_apply_look(app, name):
    item = _current_item(app, "apply a look to")
    graph = _node_graph(app, item)
    if graph is None or not _supports(graph, "ApplyGradeFromDRX"):
        raise ResolveError("Applying .drx grades needs Resolve 19.1 or newer.")

    wanted = str(name).lower()
    matches = [f for f in os.listdir(_looks_dir()) if f.lower().endswith(".drx")
               and (wanted in f.lower() or f.lower() == wanted)]
    if not matches:
        raise ResolveError("No look matching %r — see list_looks." % name)
    path = os.path.join(_looks_dir(), sorted(matches)[0])

    saved = False
    try:
        saved = bool(item.AddVersion("before_claude_look", 0))
    except Exception:
        pass
    if not graph.ApplyGradeFromDRX(path, 0):
        raise ResolveError("Resolve refused to apply the look.")
    return {"applied_look": os.path.basename(path), "clip": item.GetName(),
            "undo_version": "before_claude_look" if saved else None}


# -- timeline interchange (the round-trip editing escape hatch) -------------------

INTERCHANGE_MAX_BYTES = 192 * 1024


@tool(
    "get_timeline_interchange",
    "Read the current timeline as interchange TEXT (edl, fcp7xml, fcpxml or otio) "
    "so you can inspect or transform the edit itself. Combined with "
    "apply_timeline_interchange this is the ONLY route to trims/moves/splits: "
    "read, modify the text, apply as a new timeline. EDL is the most compact.",
    params={"format": {"type": "string", "description": "edl, fcp7xml, fcpxml or otio (default edl)."}},
)
def t_get_timeline_interchange(app, format="edl"):
    fmt = str(format).strip().lower()
    if fmt not in ("edl", "fcp7xml", "fcpxml", "otio"):
        raise ResolveError("format must be edl, fcp7xml, fcpxml or otio.")
    type_name, sub_name = EXPORT_FORMATS[fmt]
    tl = app.timeline
    out_dir = os.path.join(os.path.dirname(config_path()), "interchange-%d" % os.getpid())
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "timeline." + fmt)
    try:
        export_type = _resolve_const(app, type_name)
        if sub_name is not None:
            ok = tl.Export(path, export_type, _resolve_const(app, sub_name))
        else:
            ok = tl.Export(path, export_type)
        if not ok or not os.path.exists(path):
            raise ResolveError("Resolve refused the %s export." % fmt)
        size = os.path.getsize(path)
        if size > INTERCHANGE_MAX_BYTES:
            raise ResolveError("The %s is %.0fKB — too large to hand over. Try "
                               "format='edl', which is far more compact." % (fmt, size / 1024.0))
        with open(path, "r", errors="replace") as f:
            content = f.read()
    finally:
        shutil.rmtree(out_dir, ignore_errors=True)
    return {"timeline": tl.GetName(), "format": fmt, "content": content}


@tool(
    "apply_timeline_interchange",
    "Create a NEW timeline from interchange text you provide (the write half of "
    "the round-trip: get_timeline_interchange -> modify -> apply). The original "
    "timeline is untouched; the result appears as a separate timeline.",
    params={
        "content": {"type": "string", "description": "The interchange document text."},
        "format": {"type": "string", "description": "edl, fcp7xml, fcpxml or otio (default edl)."},
        "timeline_name": {"type": "string", "description": "Name for the new timeline."},
    },
    required=["content"],
)
def t_apply_timeline_interchange(app, content, format="edl", timeline_name=None):
    fmt = str(format).strip().lower()
    ext = {"edl": ".edl", "fcp7xml": ".xml", "fcpxml": ".fcpxml", "otio": ".otio"}.get(fmt)
    if ext is None:
        raise ResolveError("format must be edl, fcp7xml, fcpxml or otio.")
    if not str(content).strip():
        raise ResolveError("`content` is empty.")
    if len(content) > INTERCHANGE_MAX_BYTES:
        raise ResolveError("Content is too large (%.0fKB)." % (len(content) / 1024.0))

    out_dir = os.path.join(os.path.dirname(config_path()), "interchange-%d" % os.getpid())
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "incoming" + ext)
    try:
        with open(path, "w") as f:
            f.write(content)
        options = {"timelineName": str(timeline_name)} if timeline_name else {}
        tl = app.media_pool.ImportTimelineFromFile(path, options)
        if not tl:
            raise ResolveError("Resolve could not build a timeline from that %s — "
                               "check the document is valid and its media exists "
                               "in the project." % fmt)
        return {"created_timeline": tl.GetName(), "format": fmt}
    finally:
        shutil.rmtree(out_dir, ignore_errors=True)


# -- speech generation (Resolve 21+) ----------------------------------------------

@tool(
    "generate_speech",
    "Generate AI speech into the media pool (Resolve 21+ with the AI Speech "
    "Generator extra installed). `settings` is passed straight to Resolve's "
    "speechGenerationSettings — its keys follow Resolve 21's documentation, e.g. "
    "the text and voice selection. Refuses cleanly on older Resolves.",
    params={
        "settings": {"type": "object", "description":
                     "Resolve speechGenerationSettings dict, passed through as-is."},
        "timecode": {"type": "string", "description":
                     "Timeline timecode for the generated clip (default: playhead)."},
    },
    required=["settings"],
)
def t_generate_speech(app, settings, timecode=None):
    project = app.project
    if not _supports(project, "GenerateSpeech"):
        raise ResolveError("Speech generation needs Resolve 21+ with the AI Speech "
                           "Generator extra installed.")
    if not isinstance(settings, dict) or not settings:
        raise ResolveError("`settings` must be a non-empty object.")
    tc = str(timecode) if timecode else app.timeline.GetCurrentTimecode()
    made = project.GenerateSpeech(dict(settings), tc)
    if not made:
        raise ResolveError("Resolve did not generate speech — check the settings "
                           "keys against Resolve 21's speechGenerationSettings.")
    return {"generated_clip": made.GetName(), "at": tc}


# -- deliver / render ---------------------------------------------------------------

@tool(
    "render_settings",
    "Inspect or change the Deliver page's render format/codec and settings. "
    "Actions: 'formats' (list), 'codecs' (for a format), 'set' (format/codec "
    "and/or a settings dict: FormatWidth, FormatHeight, FrameRate, ExportVideo, "
    "ExportAudio, AudioCodec, AudioBitDepth, AudioSampleRate, MarkIn, MarkOut, "
    "TargetDir, CustomName...), 'save_preset' (store current setup under a name).",
    params={
        "action": {"type": "string", "description": "formats, codecs, set or save_preset."},
        "format": {"type": "string", "description": "Render format key (codecs/set)."},
        "codec": {"type": "string", "description": "Codec name (set)."},
        "settings": {"type": "object", "description": "SetRenderSettings dict (set)."},
        "preset_name": {"type": "string", "description": "Name (save_preset)."},
    },
    required=["action"],
)
def t_render_settings(app, action, format=None, codec=None, settings=None, preset_name=None):
    project = app.project
    act = str(action).strip().lower()
    if act == "formats":
        return {"formats": project.GetRenderFormats() or {}}
    if act == "codecs":
        if not format:
            raise ResolveError("`format` is required for codecs.")
        return {"format": format, "codecs": project.GetRenderCodecs(str(format)) or {}}
    if act == "set":
        out = {}
        if format or codec:
            if not (format and codec):
                raise ResolveError("Setting format/codec needs both `format` and `codec`.")
            if not project.SetCurrentRenderFormatAndCodec(str(format), str(codec)):
                raise ResolveError("Resolve rejected format %r / codec %r — check "
                                   "them against the 'formats' and 'codecs' actions."
                                   % (format, codec))
            out["format"] = format
            out["codec"] = codec
        if settings:
            if not isinstance(settings, dict):
                raise ResolveError("`settings` must be an object.")
            if not project.SetRenderSettings(dict(settings)):
                raise ResolveError("Resolve rejected those render settings.")
            out["settings"] = settings
        if not out:
            raise ResolveError("Give format+codec and/or settings.")
        return out
    if act == "save_preset":
        if not preset_name:
            raise ResolveError("`preset_name` is required.")
        if not (_supports(project, "SaveAsNewRenderPreset")
                and project.SaveAsNewRenderPreset(str(preset_name))):
            raise ResolveError("Could not save render preset %r." % preset_name)
        return {"saved_preset": preset_name}
    raise ResolveError("action must be formats, codecs, set or save_preset.")


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
    if not hasattr(_anthropic_sdk, "Anthropic"):
        _anthropic_sdk = None  # ancient/broken install — use the stdlib client
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
# Claude Code backend — locating the CLI and a usable Python
# ----------------------------------------------------------------------------

_binary_cache = {}


def _spawn_kwargs():
    """Keep Windows from flashing a console window for every child process."""
    kwargs = {}
    if sys.platform == "win32":
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        if flags:
            kwargs["creationflags"] = flags
        else:                                     # Python < 3.7
            info = subprocess.STARTUPINFO()
            info.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            kwargs["startupinfo"] = info
    return kwargs


def _first_existing(candidates):
    for path in candidates:
        if path and os.path.isfile(path):
            return path
    return ""


def find_claude_binary(cfg=None):
    """Absolute path to the Claude Code CLI, or "" if we can't find it.

    Resolve launches scripts with a trimmed PATH, so `shutil.which` alone misses
    npm-global and native installs often enough to be worth probing for.
    """
    explicit = ((cfg or {}).get("claude_code_bin")
                or os.environ.get("CLAUDE_CODE_BIN") or "").strip()
    if explicit:
        return explicit if os.path.isfile(explicit) else (shutil.which(explicit) or "")

    if "claude" in _binary_cache:
        return _binary_cache["claude"]

    found = shutil.which("claude") or ""
    if not found:
        home = os.path.expanduser("~")
        if sys.platform == "win32":
            appdata = os.environ.get("APPDATA", "")
            localapp = os.environ.get("LOCALAPPDATA", "")
            found = _first_existing([
                os.path.join(appdata, "npm", "claude.cmd") if appdata else "",
                os.path.join(appdata, "npm", "claude.exe") if appdata else "",
                os.path.join(localapp, "Programs", "claude", "claude.exe") if localapp else "",
                os.path.join(home, ".local", "bin", "claude.exe"),
                os.path.join(home, ".local", "bin", "claude"),
            ])
        else:
            found = _first_existing([
                os.path.join(home, ".local", "bin", "claude"),
                os.path.join(home, ".claude", "local", "claude"),
                "/usr/local/bin/claude",
                "/opt/homebrew/bin/claude",
            ])
    _binary_cache["claude"] = found
    return found


def find_python_binary():
    """A real python interpreter we can spawn the MCP bridge with.

    Inside Resolve, `sys.executable` is often Resolve itself rather than a
    python binary, so it can only be trusted when it actually looks like one.
    """
    if "python" in _binary_cache:
        return _binary_cache["python"]

    exe = sys.executable or ""
    if exe and "python" in os.path.basename(exe).lower():
        _binary_cache["python"] = exe
        return exe

    found = shutil.which("python3") or shutil.which("python") or ""
    if not found and sys.platform == "win32":
        localapp = os.environ.get("LOCALAPPDATA", "")
        globs = []
        if localapp:
            base = os.path.join(localapp, "Programs", "Python")
            try:
                globs = [os.path.join(base, d, "python.exe") for d in sorted(os.listdir(base), reverse=True)]
            except Exception:
                globs = []
        found = _first_existing(globs)
    _binary_cache["python"] = found
    return found


def claude_code_auth_status(binary):
    """(ok, detail) — `claude auth status` exits 0 only when signed in."""
    try:
        proc = subprocess.Popen([binary, "auth", "status"],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                **_spawn_kwargs())
        try:
            out, _ = proc.communicate(timeout=30)
        except Exception:
            proc.kill()
            return False, "Timed out asking Claude Code for its sign-in status."
    except Exception as exc:
        return False, "Could not run Claude Code (%s): %s" % (binary, exc)

    if proc.returncode == 0:
        return True, ""
    detail = (out or b"").decode("utf-8", "replace").strip()
    return False, ("Claude Code is installed but not signed in.\n"
                   "Open a terminal, run `claude`, sign in with your Claude "
                   "account, then reopen this panel."
                   + ("\n\n%s" % detail if detail else ""))


# ----------------------------------------------------------------------------
# Tool bridge — lets the out-of-process MCP server reach this Resolve session
# ----------------------------------------------------------------------------

class ToolBridge(object):
    """Loopback JSON-line server that executes Resolve tools on request.

    Claude Code spawns MCP servers as separate processes, and a separate process
    has no handle on this Resolve session. So the MCP server we hand it is a thin
    client that forwards every tools/list and tools/call back here, to the
    process that actually owns the `resolve` object.

    Bound to 127.0.0.1 on an ephemeral port and gated by a random token, so only
    a child we handed the token to can drive Resolve.
    """

    def __init__(self):
        self.token = binascii.hexlify(os.urandom(24)).decode("ascii")
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind(("127.0.0.1", 0))
        self._sock.listen(8)
        self.port = self._sock.getsockname()[1]
        self._call_lock = threading.Lock()   # Resolve's API is not thread-safe
        self._closed = False
        self._thread = threading.Thread(target=self._serve, name="claude-tool-bridge")
        self._thread.daemon = True
        self._thread.start()

    def _serve(self):
        while not self._closed:
            try:
                conn, _ = self._sock.accept()
            except Exception:
                return                       # socket closed, or shutting down
            worker = threading.Thread(target=self._handle, args=(conn,))
            worker.daemon = True
            worker.start()

    def _handle(self, conn):
        try:
            stream = conn.makefile("rwb")
            for raw in stream:
                line = raw.decode("utf-8", "replace").strip()
                if not line:
                    continue
                try:
                    reply = self._dispatch(json.loads(line))
                except ValueError:
                    reply = {"ok": False, "content": "bridge: malformed request"}
                stream.write((json.dumps(reply, default=str) + "\n").encode("utf-8"))
                stream.flush()
        except Exception:
            pass
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def _dispatch(self, req):
        if not isinstance(req, dict) or req.get("token") != self.token:
            return {"ok": False, "content": "bridge: unauthorized"}

        op = req.get("op")
        if op == "list":
            return {"ok": True, "tools": mcp_tool_schemas()}
        if op == "call":
            name = req.get("name")
            args = req.get("arguments")
            if not isinstance(args, dict):
                args = {}
            with self._call_lock:
                ok, text, images = execute_tool(name, args)
            reply = {"ok": ok, "content": text}
            if images:
                reply["images"] = images
            return reply
        return {"ok": False, "content": "bridge: unknown op %r" % (op,)}

    def close(self):
        self._closed = True
        # Closing the socket from another thread does not wake a blocked
        # accept(), so nudge it with a throwaway connection and let the loop
        # notice the flag and fall out.
        try:
            socket.create_connection(("127.0.0.1", self.port), timeout=1.0).close()
        except Exception:
            pass
        self._thread.join(timeout=2.0)
        try:
            self._sock.close()
        except Exception:
            pass


def mcp_tool_schemas():
    """The tool catalogue in MCP shape (`inputSchema`, not `input_schema`)."""
    tools = []
    for schema in tool_schemas():
        tools.append({
            "name": schema["name"],
            "description": schema["description"],
            "inputSchema": schema["input_schema"],
        })
    return tools


# ----------------------------------------------------------------------------
# MCP server — runs as a subprocess of Claude Code, talks JSON-RPC over stdio
# ----------------------------------------------------------------------------

def _bridge_request(port, token, payload):
    """One request/response round-trip against the in-Resolve ToolBridge."""
    conn = socket.create_connection(("127.0.0.1", port), timeout=600)
    try:
        stream = conn.makefile("rwb")
        payload = dict(payload)
        payload["token"] = token
        stream.write((json.dumps(payload) + "\n").encode("utf-8"))
        stream.flush()
        line = stream.readline()
        if not line:
            raise IOError("bridge closed the connection")
        return json.loads(line.decode("utf-8", "replace"))
    finally:
        try:
            conn.close()
        except Exception:
            pass


def run_mcp_bridge():
    """Entry point for `Claude Assistant.py --mcp-bridge`.

    Speaks newline-delimited JSON-RPC on stdin/stdout — nothing else may ever be
    written to stdout, or the transport is corrupted.
    """
    stdin = io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", newline="")
    stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", newline="\n")

    port = int(os.environ.get(BRIDGE_ENV_PORT) or 0)
    token = os.environ.get(BRIDGE_ENV_TOKEN) or ""

    def log(msg):
        sys.stderr.write("[claude-resolve-mcp] %s\n" % msg)
        sys.stderr.flush()

    def send(obj):
        stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
        stdout.flush()

    def ok(rid, payload):
        send({"jsonrpc": "2.0", "id": rid, "result": payload})

    def fail(rid, code, message):
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}})

    def handle(msg):
        if not isinstance(msg, dict) or msg.get("jsonrpc") != "2.0":
            return fail(None, -32600, "Invalid Request")

        method = msg.get("method")
        params = msg.get("params") or {}          # may be absent entirely
        rid = msg.get("id")
        # id 0 is a legitimate request id, so test for presence, not truthiness.
        is_request = "id" in msg and msg["id"] is not None

        if method is None:
            return                                 # a response; we send no requests
        if not is_request:
            return                                 # notifications never get a reply

        if method == "initialize":
            requested = params.get("protocolVersion")
            version = requested if requested in MCP_PROTOCOL_VERSIONS else MCP_FALLBACK_VERSION
            return ok(rid, {
                "protocolVersion": version,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": MCP_SERVER_NAME, "version": "1.0.0"},
            })

        if method == "ping":
            return ok(rid, {})

        if method == "tools/list":
            try:
                reply = _bridge_request(port, token, {"op": "list"})
            except Exception as exc:
                return fail(rid, -32603, "Resolve bridge unreachable: %s" % exc)
            if not reply.get("ok"):
                return fail(rid, -32603, reply.get("content") or "bridge error")
            return ok(rid, {"tools": reply.get("tools") or []})

        if method == "tools/call":
            name = params.get("name")
            args = params.get("arguments") or {}
            if not isinstance(name, str):
                return fail(rid, -32602, "Invalid params: 'name' must be a string")
            if not isinstance(args, dict):
                return fail(rid, -32602, "Invalid params: 'arguments' must be an object")
            try:
                reply = _bridge_request(port, token, {"op": "call", "name": name,
                                                      "arguments": args})
            except Exception as exc:
                # Transport failure is a tool error, not a protocol error, so the
                # model can report it instead of the whole session dying.
                return ok(rid, {"content": [{"type": "text",
                                             "text": "Resolve bridge unreachable: %s" % exc}],
                                "isError": True})
            text = reply.get("content")
            if not isinstance(text, str):
                text = json.dumps(text, default=str)
            content = []
            for image in (reply.get("images") or []):
                if isinstance(image, dict) and image.get("data"):
                    # MCP ImageContent — verified end-to-end that Claude Code
                    # forwards this to the model as real vision input.
                    content.append({"type": "image", "data": image["data"],
                                    "mimeType": image.get("media_type", "image/jpeg")})
            content.append({"type": "text", "text": text})
            return ok(rid, {"content": content, "isError": not reply.get("ok")})

        return fail(rid, -32601, "Method not found: %s" % method)

    log("started (bridge port %s)" % port)
    for raw in stdin:
        line = raw.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            fail(None, -32700, "Parse error")
            continue
        try:
            handle(msg)
        except Exception as exc:
            log("internal error: %r" % exc)
            rid = msg.get("id") if isinstance(msg, dict) else None
            if rid is not None:
                fail(rid, -32603, "Internal error")
    log("stdin closed, exiting")


# ----------------------------------------------------------------------------
# Agent loop
# ----------------------------------------------------------------------------

STATE = {
    "messages": [],          # Anthropic wire-format history
    "allow_python": True,
    "fusion": None,
    "app": None,             # ResolveApp
    "bridge": None,          # ToolBridge, lazily started for the CLI backend
    "cc_session_id": None,   # Claude Code session to --resume, for continuity
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
    """Run one tool. Returns (ok, text, images).

    `images` is None, or a list of {"data": <base64 str>, "media_type": ...}
    when the tool produced pictures (view_frame, survey_clip): tools smuggle
    them out via _image_b64/_image_media_type (one image) or _images (several),
    all stripped from the JSON text.
    """
    entry = TOOL_INDEX.get(name)
    if entry is None:
        return False, "Unknown tool: %s" % name, None
    try:
        result = entry["fn"](STATE["app"], **(tool_input or {}))
        images = None
        if isinstance(result, dict):
            if "_image_b64" in result:
                images = [{"data": result.pop("_image_b64"),
                           "media_type": result.pop("_image_media_type", "image/jpeg")}]
            elif "_images" in result:
                images = [{"data": i["b64"], "media_type": i.get("media_type", "image/jpeg")}
                          for i in result.pop("_images")]
        return True, json.dumps(result, default=str), images or None
    except ResolveError as exc:
        return False, str(exc), None
    except TypeError as exc:
        return False, "Bad arguments for %s: %s" % (name, exc), None
    except Exception:
        return False, "Tool %s crashed:\n%s" % (name, traceback.format_exc(limit=4)), None


def run_agent_turn(cfg, model, user_text, emit):
    """Run one user turn against whichever backend is configured.

    `emit(kind, text)` is called with transcript events:
      kind in {assistant, tool, error, notice}.
    """
    if get_backend(cfg) == BACKEND_CLAUDE_CODE:
        return run_agent_turn_claude_code(cfg, model, user_text, emit)
    return run_agent_turn_api(get_api_key(cfg), model, user_text, emit)


def get_tool_bridge():
    bridge = STATE.get("bridge")
    if bridge is None:
        bridge = ToolBridge()
        STATE["bridge"] = bridge
    return bridge


def build_claude_code_argv(cfg, model, prompt, bridge, resume_session=None):
    """The full `claude` command line for one turn. Split out so it's testable."""
    python_bin = find_python_binary()
    if not python_bin:
        raise ApiError("Could not find a Python interpreter to run the Resolve "
                       "tool bridge. Install Python 3 and make sure it's on PATH.")

    mcp_config = json.dumps({
        "mcpServers": {
            MCP_SERVER_NAME: {
                "type": "stdio",
                "command": python_bin,
                "args": [os.path.abspath(__file__), MCP_BRIDGE_FLAG],
                # MCP subprocesses are spawned with a whitelisted environment,
                # so the bridge coordinates have to be passed explicitly here.
                "env": {
                    BRIDGE_ENV_PORT: str(bridge.port),
                    BRIDGE_ENV_TOKEN: bridge.token,
                },
            },
        },
    }, separators=(",", ":"))

    argv = [
        find_claude_binary(cfg),
        "-p", prompt,
        "--output-format", "stream-json",
        "--verbose",
        # Ignore whatever MCP servers the user has configured globally; this
        # panel's tool surface should be exactly the Resolve tools.
        "--strict-mcp-config",
        "--mcp-config", mcp_config,
        "--allowedTools", "mcp__%s__*" % MCP_SERVER_NAME,
        # No filesystem, no shell — Claude gets the Resolve tools and nothing else.
        "--tools", "",
        "--append-system-prompt", SYSTEM_PROMPT,
        "--model", model,
    ]
    if resume_session:
        argv += ["--resume", resume_session]
    return argv


def claude_code_env():
    """Child environment for the CLI, scrubbed of anything that would bypass
    the user's subscription.

    In `-p` mode an ANTHROPIC_API_KEY is used silently, with no approval prompt
    — inheriting one would quietly bill API credits to someone who chose this
    backend precisely to avoid that.
    """
    env = dict(os.environ)
    env.pop("ANTHROPIC_API_KEY", None)
    env.pop("ANTHROPIC_AUTH_TOKEN", None)
    return env


def run_agent_turn_claude_code(cfg, model, user_text, emit):
    """Drive one turn through the Claude Code CLI (uses the user's subscription).

    Conversation state lives in Claude Code's own session store rather than in
    STATE["messages"]; we just carry the session id forward with --resume.
    """
    binary = find_claude_binary(cfg)
    if not binary:
        emit("error", "Claude Code CLI not found. Install it with "
                      "`npm install -g @anthropic-ai/claude-code`.")
        return

    prompt = "%s\n\n%s" % (user_text, resolve_context_block())
    try:
        argv = build_claude_code_argv(cfg, model, prompt, get_tool_bridge(),
                                      STATE.get("cc_session_id"))
    except ApiError as exc:
        emit("error", str(exc))
        return

    try:
        proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=claude_code_env(), **_spawn_kwargs())
    except Exception as exc:
        emit("error", "Could not start Claude Code: %s" % exc)
        return

    saw_output = False
    try:
        for raw in proc.stdout:
            line = raw.decode("utf-8", "replace").strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except ValueError:
                continue                       # non-JSON noise on stdout
            if _handle_claude_code_event(event, emit):
                saw_output = True
    finally:
        try:
            proc.stdout.close()
        except Exception:
            pass
        stderr = b""
        try:
            stderr = proc.stderr.read() or b""
            proc.stderr.close()
        except Exception:
            pass
        proc.wait()

    if proc.returncode != 0 and not saw_output:
        detail = stderr.decode("utf-8", "replace").strip()
        emit("error", "Claude Code exited with status %d.%s"
             % (proc.returncode, "\n\n%s" % detail if detail else ""))


def _handle_claude_code_event(event, emit):
    """Translate one stream-json line into panel events. True if it showed something."""
    if not isinstance(event, dict):
        return False
    kind = event.get("type")

    if kind == "system" and event.get("subtype") == "init":
        if event.get("session_id"):
            STATE["cc_session_id"] = event["session_id"]
        # A server that failed to connect means no Resolve tools this turn.
        for server in event.get("mcp_servers") or []:
            if server.get("name") == MCP_SERVER_NAME and server.get("status") in ("failed", "needs-auth"):
                emit("notice", "The Resolve tool bridge did not connect (%s) — "
                               "Claude can still talk, but can't drive Resolve this turn."
                     % server.get("status"))
        return False

    if kind == "assistant":
        shown = False
        for block in ((event.get("message") or {}).get("content") or []):
            btype = block.get("type")
            if btype == "text" and block.get("text", "").strip():
                emit("assistant", block["text"])
                shown = True
            elif btype == "tool_use":
                name = block.get("name") or ""
                short = name.split("__")[-1] or name
                emit("tool", "%s(%s)" % (short, _short_json(block.get("input"))))
                if short == "run_python" and isinstance(block.get("input"), dict):
                    emit("tool", "```python\n%s\n```" % block["input"].get("code", ""))
                shown = True
        return shown

    if kind == "result":
        if event.get("session_id"):
            STATE["cc_session_id"] = event["session_id"]
        if event.get("is_error") or event.get("subtype") == "error":
            emit("error", str(event.get("result") or "Claude Code reported an error."))
            return True
        if event.get("subtype") == "error_max_turns":
            emit("notice", "Stopped after the maximum number of tool rounds — "
                           "ask me to continue if needed.")
            return True
    return False


def run_agent_turn_api(api_key, model, user_text, emit):
    """Run one full user turn against the Messages API (many tool round-trips)."""
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

        # Never store an empty assistant message (e.g. a pre-output refusal) —
        # the API rejects empty content on subsequent requests.
        if content:
            messages.append({"role": "assistant",
                             "content": _sanitize_assistant_content(content)})

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
                ok, text, images = execute_tool(name, block.get("input") or {})
                if not ok:
                    emit("tool", "error: %s" % text)
                entry = {"type": "tool_result", "tool_use_id": block.get("id")}
                if images:
                    # Images first, then the JSON summary — Claude sees the frames.
                    entry["content"] = [
                        {"type": "image",
                         "source": {"type": "base64",
                                    "media_type": img["media_type"],
                                    "data": img["data"]}}
                        for img in images
                    ] + [{"type": "text", "text": text}]
                    emit("tool", "(%d frame%s attached)" %
                         (len(images), "" if len(images) == 1 else "s"))
                else:
                    entry["content"] = text
                if not ok:
                    entry["is_error"] = True
                results.append(entry)
            messages.append({"role": "user", "content": results})
            continue

        if stop_reason == "pause_turn":
            if not content:
                emit("notice", "The API paused without output — please try again.")
                return
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


def _sanitize_assistant_content(content):
    """Prepare assistant content for echoing back to the API.

    After a mid-output refusal fallback, the response contains a 'fallback'
    boundary block; thinking/tool_use blocks BEFORE the last boundary must be
    omitted when replaying history (per the fallbacks API contract). Content
    without fallback blocks is returned unchanged.
    """
    last_fb = -1
    for i, block in enumerate(content):
        if block.get("type") == "fallback":
            last_fb = i
    if last_fb < 0:
        return content
    kept = []
    for i, block in enumerate(content):
        if i < last_fb and block.get("type") in ("thinking", "redacted_thinking",
                                                 "tool_use", "server_tool_use"):
            continue
        kept.append(block)
    return kept


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
                                     "Weight": 1,
                                     # ReturnPressed is not a default-enabled event
                                     "Events": {"ReturnPressed": True}}),
                        ui.Button({"ID": "SendBtn", "Text": "Send", "Weight": 0}),
                    ]),
                    ui.Label({"ID": "Status", "Text": "", "Weight": 0}),
                ]),
            ])
        self.items = self.win.GetItems()

        combo = self.items["ModelCombo"]
        try:
            combo.AddItems(MODEL_CHOICES)
        except Exception:
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
            self.timer = self.ui.Timer({"ID": "PollTimer", "Interval": 120})
            handler = lambda ev: self.drain_events()  # noqa: E731
            wired = False
            # Global timeout handler on the dispatcher (verified pattern);
            # only our timer exists, so any Timeout event is ours.
            try:
                self.disp["On"]["Timeout"] = handler
                wired = True
            except Exception:
                pass
            try:
                self.win.On.PollTimer.Timeout = handler
                wired = True
            except Exception:
                pass
            if not wired:
                raise RuntimeError("no Timeout wiring available")
            self.timer.Start()
        except Exception:
            self.timer = None

    def drain_events(self):
        while True:
            try:
                kind, text = self.events.get_nowait()
            except _queue.Empty:
                return
            try:
                if kind == "__done__":
                    self.set_busy(False)
                else:
                    self.append_chat(kind, text)
            except Exception:
                pass  # window may be tearing down; never lose the queue loop

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
        try:
            chat.EnsureCursorVisible()
        except Exception:
            pass

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

        ready, why = backend_ready(self.cfg)
        if not ready:
            self.append_chat("error", why)
            return

        self.append_chat("you", text)

        if self.timer is not None:
            self.set_busy(True)
            worker = threading.Thread(
                target=self._worker, args=(self.cfg, model, text), daemon=True)
            worker.start()
        else:
            # Synchronous fallback: UI freezes during the call but stays correct.
            self.set_busy(True)
            try:
                run_agent_turn(self.cfg, model, text,
                               lambda kind, t: self.append_chat(kind, t))
            finally:
                self.set_busy(False)

    def _worker(self, cfg, model, text):
        try:
            run_agent_turn(cfg, model, text,
                           lambda kind, t: self.events.put((kind, t)))
        except Exception:
            self.events.put(("error", "Unexpected failure:\n" + traceback.format_exc(limit=6)))
        finally:
            self.events.put(("__done__", ""))
            # Safety net: if the timer's Timeout never fires on this Resolve
            # build, drain from here so the window can't get stuck "busy".
            time.sleep(2.0)
            if not self.events.empty():
                try:
                    self.drain_events()
                except Exception:
                    pass

    def on_new_chat(self, ev):
        if self.busy:
            return
        STATE["messages"] = []
        STATE["cc_session_id"] = None   # start a fresh Claude Code session too
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
                         "\"look at this frame — is it overexposed?\", "
                         "\"what's in my media pool?\", "
                         "\"queue a YouTube 1080p render to ~/Renders\".")


SETUP_CHOICES = [BACKEND_CLAUDE_CODE, BACKEND_API]
SETUP_LABELS = [
    "Claude Code — use my Claude subscription (no API key)",
    "Anthropic API key — pay per use",
]


def prompt_for_setup(ui, disp, cfg):
    """One-shot window to pick a backend the first time the panel runs."""
    result = {"saved": False}
    binary = find_claude_binary(cfg)
    if binary:
        signed_in, _ = claude_code_auth_status(binary)
        cli_status = ("Claude Code detected and signed in — you're ready to go."
                      if signed_in else
                      "Claude Code detected, but not signed in yet. Open a terminal, "
                      "run `claude`, and sign in with your Claude account.")
    else:
        cli_status = ("Claude Code not found. To use your subscription instead of an "
                      "API key, install it with:  npm install -g @anthropic-ai/claude-code")

    win = disp.AddWindow(
        {"ID": "SetupWin", "WindowTitle": "Claude Assistant — setup",
         "Geometry": [300, 300, 640, 260]},
        [
            ui.VGroup({"Spacing": 8}, [
                ui.Label({"ID": "SetupInfo", "WordWrap": True, "Text":
                          "How should this panel reach Claude?"}),
                ui.ComboBox({"ID": "BackendCombo"}),
                ui.Label({"ID": "CliStatus", "WordWrap": True, "Text": cli_status}),
                ui.Label({"ID": "KeyLabel", "WordWrap": True, "Text":
                          "API key (only needed for the second option). Stored on this "
                          "machine only, in your user config folder."}),
                ui.LineEdit({"ID": "KeyInput", "PlaceholderText": "sk-ant-…",
                             "EchoMode": "Password",
                             "Events": {"ReturnPressed": True}}),
                ui.HGroup({}, [
                    ui.Button({"ID": "SetupSave", "Text": "Save & start"}),
                    ui.Button({"ID": "SetupCancel", "Text": "Cancel"}),
                ]),
            ]),
        ])
    items = win.GetItems()

    combo = items["BackendCombo"]
    try:
        combo.AddItems(SETUP_LABELS)
    except Exception:
        for label in SETUP_LABELS:
            combo.AddItem(label)
    # Default to whichever option can actually work right now.
    combo.CurrentIndex = 0 if binary else 1

    def on_save(ev):
        backend = SETUP_CHOICES[int(combo.CurrentIndex)]
        key = (items["KeyInput"].Text or "").strip()
        if backend == BACKEND_API and not key and not get_api_key(cfg):
            items["CliStatus"].Text = "Enter an API key, or pick the Claude Code option."
            return
        if backend == BACKEND_CLAUDE_CODE and not find_claude_binary(cfg):
            items["CliStatus"].Text = ("Claude Code isn't installed yet — install it, or "
                                       "pick the API key option.")
            return
        cfg["backend"] = backend
        if key:
            cfg["api_key"] = key
        save_config(cfg)
        result["saved"] = True
        disp.ExitLoop()

    def on_cancel(ev):
        disp.ExitLoop()

    win.On.SetupSave.Clicked = on_save
    win.On.KeyInput.ReturnPressed = on_save
    win.On.SetupCancel.Clicked = on_cancel
    win.On.SetupWin.Close = on_cancel
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

    # Only interrupt when neither backend could work; otherwise get_backend()
    # picks the CLI if it's installed and falls back to the API key.
    if not get_api_key(cfg) and not find_claude_binary(cfg):
        if not prompt_for_setup(ui, disp, cfg):
            print("[%s] Setup cancelled — exiting." % APP_NAME)
            return

    try:
        window = ChatWindow(ui, disp, cfg)
        window.greet()
        window.win.Show()
        disp.RunLoop()
        window.win.Hide()
    finally:
        bridge = STATE.get("bridge")
        if bridge is not None:
            bridge.close()


if __name__ == "__main__":
    # Claude Code spawns this same file as its MCP server; that mode must not
    # touch Resolve or open a window.
    if MCP_BRIDGE_FLAG in sys.argv[1:]:
        run_mcp_bridge()
    else:
        main()
