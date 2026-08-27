// Tool layer for the Claude Assistant workflow-integration plugin.
//
// Everything here runs in Electron's MAIN process but is plain Node — no
// Electron imports — so `node test_plugin.js` can exercise it against a fake
// Resolve object. The Resolve JS API is the same object tree as the Python
// scripting API (GetProjectManager, GetCurrentTimeline, AddMarker, ...), so
// these bodies mirror the proven Python plugin's tools.
//
// The approval flow matches the panel design: read-only tools run freely in
// "Ask before edits"; anything mutating pauses until the renderer's buttons
// (or a timeout) resolve it.

"use strict";
const net = require("net");
const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");

const PERMISSION_MODES = ["Ask before edits", "Always ask", "Never ask"];
const APPROVAL_TIMEOUT_MS = 120000;

const READONLY_TOOLS = new Set([
  "get_workspace_overview", "list_media_pool", "get_clip_properties",
  "list_timelines", "list_markers", "list_render_presets",
  "get_render_status", "move_playhead", "open_page",
  // grab_still LOOKS at a frame: the gallery still it makes is deleted
  // again after export, so treating it as a read keeps vision friction-free.
  "grab_still",
]);

function jsonSafe(value, depth) {
  depth = depth || 0;
  if (depth > 5) return String(value);
  if (value === null || value === undefined) return null;
  const t = typeof value;
  if (t === "number" || t === "string" || t === "boolean") return value;
  if (Array.isArray(value)) return value.map((v) => jsonSafe(v, depth + 1));
  if (t === "object") {
    const out = {};
    for (const k of Object.keys(value)) out[k] = jsonSafe(value[k], depth + 1);
    return out;
  }
  return String(value);
}

class ResolveError extends Error {}

// ---------------------------------------------------------------- state
function makeState(resolve) {
  return {
    resolve,
    permissionMode: "Ask before edits",
    approveAllEdits: false,
    pendingApproval: null,      // {name, input, resolveFn} while waiting
    onApprovalNeeded: null,     // main.js wires this to the renderer
  };
}

function project(state) {
  const p = state.resolve.GetProjectManager().GetCurrentProject();
  if (!p) throw new ResolveError("No project is open in Resolve.");
  return p;
}

function timeline(state) {
  const t = project(state).GetCurrentTimeline();
  if (!t) throw new ResolveError("The project has no current timeline.");
  return t;
}

// ---------------------------------------------------------------- approvals
function needsApproval(state, name) {
  const mode = state.permissionMode;
  if (mode === "Always ask") return true;
  if (mode !== "Ask before edits") return false;
  if (state.approveAllEdits) return false;
  return !READONLY_TOOLS.has(name);
}

function requestApproval(state, name, input) {
  // Resolves to null (approved) or a decline message for the model.
  return new Promise((resolveP) => {
    const pending = { name, input };
    let done = false;
    const finish = (msg) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      state.pendingApproval = null;
      resolveP(msg);
    };
    const timer = setTimeout(() => finish(
      "The approval request timed out after " + APPROVAL_TIMEOUT_MS / 1000 +
      "s with no answer — the action was NOT performed. Ask the user how " +
      "to proceed."), APPROVAL_TIMEOUT_MS);
    pending.answer = (decision, guidance) => {
      if (decision === "always") { state.approveAllEdits = true; finish(null); }
      else if (decision === "run") finish(null);
      else finish("The user declined this action" +
                  (guidance ? " and said: " + guidance : "") +
                  ". Do not retry it as-is.");
    };
    state.pendingApproval = pending;
    if (state.onApprovalNeeded) state.onApprovalNeeded(pending);
  });
}

// ---------------------------------------------------------------- tools
const TOOLS = [];
function tool(name, description, params, required, fn) {
  TOOLS.push({ name, description, params: params || {}, required: required || [], fn });
}

tool("get_workspace_overview",
  "Current project, timeline, fps, page and playhead — orient yourself first.",
  {}, [], (state) => {
    const r = state.resolve;
    const p = project(state);
    const t = p.GetCurrentTimeline();
    const out = { project: p.GetName(), page: r.GetCurrentPage() };
    if (t) {
      out.timeline = t.GetName();
      out.fps = t.GetSetting("timelineFrameRate");
      out.timecode = t.GetCurrentTimecode();
      out.video_tracks = t.GetTrackCount("video");
    }
    return out;
  });

tool("open_page",
  "Switch Resolve to a page: media, cut, edit, fusion, color, fairlight, deliver.",
  { page: { type: "string" } }, ["page"], (state, a) => {
    if (!state.resolve.OpenPage(String(a.page)))
      throw new ResolveError("Resolve refused to open page " + a.page);
    return { page: state.resolve.GetCurrentPage() };
  });

tool("list_media_pool",
  "Clips and sub-bins in a media pool folder ('/' is the root).",
  { folder_path: { type: "string" } }, [], (state, a) => {
    const mp = project(state).GetMediaPool();
    let folder = mp.GetRootFolder();
    const parts = String(a.folder_path || "/").split("/").filter(Boolean);
    for (const part of parts) {
      const subs = folder.GetSubFolderList() || [];
      const next = subs.find((s) => s.GetName() === part);
      if (!next) throw new ResolveError("No bin called " + part);
      folder = next;
    }
    return {
      folders: (folder.GetSubFolderList() || []).map((s) => s.GetName()),
      clips: (folder.GetClipList() || []).map((c) => c.GetName()),
    };
  });

tool("get_clip_properties",
  "Properties of a media pool clip found by exact name.",
  { clip_name: { type: "string" } }, ["clip_name"], (state, a) => {
    const mp = project(state).GetMediaPool();
    const stack = [mp.GetRootFolder()];
    while (stack.length) {
      const folder = stack.pop();
      for (const clip of folder.GetClipList() || [])
        if (clip.GetName() === a.clip_name)
          return jsonSafe(clip.GetClipProperty());
      for (const sub of folder.GetSubFolderList() || []) stack.push(sub);
    }
    throw new ResolveError("No clip named " + a.clip_name + " in the media pool.");
  });

tool("list_timelines", "Every timeline in the project; marks the current one.",
  {}, [], (state) => {
    const p = project(state);
    const current = p.GetCurrentTimeline();
    const out = [];
    for (let i = 1; i <= p.GetTimelineCount(); i++) {
      const t = p.GetTimelineByIndex(i);
      out.push({ name: t.GetName(),
                 current: !!current && t.GetName() === current.GetName() });
    }
    return { timelines: out };
  });

tool("set_current_timeline", "Switch to a timeline by exact name.",
  { name: { type: "string" } }, ["name"], (state, a) => {
    const p = project(state);
    for (let i = 1; i <= p.GetTimelineCount(); i++) {
      const t = p.GetTimelineByIndex(i);
      if (t.GetName() === a.name) {
        if (!p.SetCurrentTimeline(t))
          throw new ResolveError("Resolve refused to switch timeline.");
        return { current: a.name };
      }
    }
    throw new ResolveError("No timeline named " + a.name);
  });

tool("move_playhead", "Jump the playhead to a timecode like 01:00:12:03.",
  { timecode: { type: "string" } }, ["timecode"], (state, a) => {
    if (!timeline(state).SetCurrentTimecode(String(a.timecode)))
      throw new ResolveError("Resolve rejected timecode " + a.timecode);
    return { timecode: timeline(state).GetCurrentTimecode() };
  });

tool("add_marker",
  "Add a marker to the current timeline at a frame (timeline-relative).",
  { frame: { type: "number" }, color: { type: "string" },
    name: { type: "string" }, note: { type: "string" },
    duration: { type: "number" } }, ["frame", "color"], (state, a) => {
    const ok = timeline(state).AddMarker(Number(a.frame), String(a.color),
      String(a.name || ""), String(a.note || ""), Number(a.duration || 1), "");
    if (!ok) throw new ResolveError(
      "Resolve refused the marker — often a duplicate frame position.");
    return { added: { frame: a.frame, color: a.color } };
  });

tool("list_markers", "All markers on the current timeline.", {}, [],
  (state) => ({ markers: jsonSafe(timeline(state).GetMarkers()) }));

tool("delete_markers", "Delete timeline markers by color, or 'All'.",
  { color: { type: "string" } }, ["color"], (state, a) => {
    if (!timeline(state).DeleteMarkersByColor(String(a.color)))
      throw new ResolveError("No markers of that color to delete.");
    return { deleted: a.color };
  });

tool("append_to_timeline",
  "Append media pool clips (exact names, in order) to the current timeline.",
  { clip_names: { type: "array", items: { type: "string" } } }, ["clip_names"],
  (state, a) => {
    const mp = project(state).GetMediaPool();
    const wanted = new Map((a.clip_names || []).map((n) => [n, null]));
    const stack = [mp.GetRootFolder()];
    while (stack.length) {
      const folder = stack.pop();
      for (const clip of folder.GetClipList() || [])
        if (wanted.has(clip.GetName()) && !wanted.get(clip.GetName()))
          wanted.set(clip.GetName(), clip);
      for (const sub of folder.GetSubFolderList() || []) stack.push(sub);
    }
    const missing = [...wanted].filter(([, c]) => !c).map(([n]) => n);
    if (missing.length)
      throw new ResolveError("Not in the media pool: " + missing.join(", "));
    const added = mp.AppendToTimeline([...wanted.values()]);
    if (!added || !added.length)
      throw new ResolveError("Resolve appended nothing.");
    return { appended: a.clip_names };
  });

tool("import_media", "Import absolute file paths into the current media pool bin.",
  { paths: { type: "array", items: { type: "string" } } }, ["paths"],
  (state, a) => {
    const items = project(state).GetMediaPool().ImportMedia(a.paths || []);
    if (!items || !items.length)
      throw new ResolveError("Resolve imported nothing (bad paths or formats?).");
    return { imported: items.map((c) => c.GetName()) };
  });

tool("create_media_pool_folder", "Create a bin under the media pool root.",
  { name: { type: "string" } }, ["name"], (state, a) => {
    const mp = project(state).GetMediaPool();
    const folder = mp.AddSubFolder(mp.GetRootFolder(), String(a.name));
    if (!folder) throw new ResolveError("Could not create the bin.");
    return { created: a.name };
  });

tool("list_render_presets", "Render presets available in this project.", {}, [],
  (state) => ({ presets: jsonSafe(project(state).GetRenderPresetList()) }));

tool("add_render_job",
  "Queue a render of the current timeline with a preset to a target directory.",
  { preset: { type: "string" }, target_dir: { type: "string" },
    custom_name: { type: "string" } }, ["preset", "target_dir"], (state, a) => {
    const p = project(state);
    if (!p.LoadRenderPreset(String(a.preset)))
      throw new ResolveError("No render preset named " + a.preset);
    const settings = { TargetDir: String(a.target_dir) };
    if (a.custom_name) settings.CustomName = String(a.custom_name);
    if (!p.SetRenderSettings(settings))
      throw new ResolveError("Resolve rejected those render settings.");
    const job = p.AddRenderJob();
    if (!job) throw new ResolveError("Could not queue the render job.");
    return { job_id: job };
  });

tool("start_render", "Start rendering the queued jobs.", {}, [], (state) => {
  if (!project(state).StartRendering())
    throw new ResolveError("Rendering did not start (empty queue?).");
  return { rendering: true };
});

tool("get_render_status", "Progress of render jobs.", {}, [], (state) => ({
  rendering: project(state).IsRenderingInProgress(),
  jobs: jsonSafe(project(state).GetRenderJobList()),
}));

function frameToTimecode(frame, fps) {
  // Nominal-rate, non-drop conversion (59.94 -> 60): fine for parking on a
  // frame to grab it; not an editorial-accuracy TC calculator.
  const nominal = Math.max(1, Math.round(Number(fps) || 24));
  const f = Math.max(0, Math.floor(Number(frame)));
  const pad = (n) => String(n).padStart(2, "0");
  return pad(Math.floor(f / (3600 * nominal))) + ":" +
         pad(Math.floor(f / (60 * nominal)) % 60) + ":" +
         pad(Math.floor(f / nominal) % 60) + ":" + pad(f % nominal);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

tool("grab_still",
  "Grab a still of the current timeline frame and SEE it: parks the " +
  "playhead (optional frame/timecode), grabs on the Color page, exports a " +
  "PNG (to /tmp by default; falls back to a home folder if Resolve cannot " +
  "write there), and returns the image to your vision. The temporary " +
  "gallery still is cleaned up afterwards.",
  { frame: { type: "number",
             description: "Absolute timeline frame to park on (optional)." },
    timecode: { type: "string",
                description: "Or a timecode like 01:00:12:03 (optional)." },
    out_dir: { type: "string",
               description: "Export directory; default /tmp." } },
  [], async (state, a) => {
    const resolve = state.resolve;
    const proj = project(state);
    const tl = timeline(state);
    let tc = a.timecode ? String(a.timecode) : null;
    if (!tc && a.frame !== undefined && a.frame !== null)
      tc = frameToTimecode(a.frame, tl.GetSetting("timelineFrameRate"));
    if (tc && !tl.SetCurrentTimecode(tc))
      throw new ResolveError("Resolve rejected timecode " + tc);

    const previousPage = resolve.GetCurrentPage();
    resolve.OpenPage("color");            // GrabStill only works from Color
    try {
      const gallery = proj.GetGallery();
      const album = gallery && gallery.GetCurrentStillAlbum();
      if (!album)
        throw new ResolveError("No gallery album available — open the Color "
                               + "page gallery once so Resolve creates one.");
      let still = null;
      for (let attempt = 0; attempt < 3 && !still; attempt++) {
        still = tl.GrabStill();           // intermittently falsy: retry
        if (!still) await sleep(400);
      }
      if (!still)
        throw new ResolveError("GrabStill kept returning nothing — is a "
                               + "timeline open with a clip at the playhead?");

      const prefix = "claude_" + Date.now().toString(36);
      const dirs = [String(a.out_dir || (process.platform === "win32"
                                         ? os.tmpdir() : "/tmp")),
                    path.join(os.homedir(), "ClaudeAssistantStills")];
      let exported = null, usedDir = null;
      for (const dir of dirs) {
        try { fs.mkdirSync(dir, { recursive: true }); } catch (e) { continue; }
        const before = new Set(fs.readdirSync(dir));
        album.ExportStills([still], dir, prefix, "png");
        await sleep(200);                 // export is not always synchronous
        // Filenames are unpredictable — diff the directory instead.
        const fresh = fs.readdirSync(dir).filter((n) => !before.has(n));
        const png = fresh.find((n) => n.toLowerCase().endsWith(".png"));
        for (const sidecar of fresh)      // a .drx sidecar always appears
          if (sidecar.toLowerCase().endsWith(".drx")) {
            try { fs.unlinkSync(path.join(dir, sidecar)); } catch (e) {}
          }
        if (png) { exported = path.join(dir, png); usedDir = dir; break; }
      }
      try { album.DeleteStills([still]); } catch (e) {}
      if (!exported)
        throw new ResolveError("Resolve exported no PNG into " +
          dirs.join(" or ") + " — macOS Resolve sometimes cannot write to "
          + "system temp dirs; both attempts failed.");

      const bytes = fs.readFileSync(exported);
      if (bytes.length > 4500000)
        throw new ResolveError("The still is " + bytes.length + " bytes — too "
          + "large to attach. It is saved at " + exported + ".");
      return { _images: [{ data: bytes.toString("base64"),
                           media_type: "image/png" }],
               path: exported, dir: usedDir, bytes: bytes.length,
               timecode: tl.GetCurrentTimecode() };
    } finally {
      if (previousPage && previousPage !== "color") {
        try { resolve.OpenPage(previousPage); } catch (e) {}
      }
    }
  });

tool("run_javascript",
  "Escape hatch when no tool fits: run a short JavaScript snippet against " +
  "the live Resolve scripting objects. In scope: resolve, projectManager, " +
  "project, timeline (may be null), mediaPool. Return a value with " +
  "`return`. The API is identical to Resolve's documented scripting API. " +
  "The code is shown to the user, and destructive work needs their approval.",
  { code: { type: "string" } }, ["code"], (state, a) => {
    const r = state.resolve;
    const pm = r.GetProjectManager();
    const p = pm.GetCurrentProject();
    const fn = new Function("resolve", "projectManager", "project", "timeline",
                           "mediaPool", '"use strict";' + String(a.code));
    const result = fn(r, pm, p, p ? p.GetCurrentTimeline() : null,
                      p ? p.GetMediaPool() : null);
    return jsonSafe(result === undefined ? { done: true } : result);
  });

// ---------------------------------------------------------------- execution
async function executeTool(state, name, input) {
  const entry = TOOLS.find((t) => t.name === name);
  if (!entry) return { ok: false, text: "Unknown tool: " + name };
  if (needsApproval(state, name)) {
    const declined = await requestApproval(state, name, input || {});
    if (declined) return { ok: false, text: declined };
  }
  try {
    const result = await entry.fn(state, input || {});
    let images = null;
    if (result && typeof result === "object" && result._images) {
      images = result._images;            // picture side channel, kept out of
      delete result._images;              // the JSON text (25k-token cap)
    }
    return { ok: true, text: JSON.stringify(result), images };
  } catch (err) {
    if (err instanceof ResolveError) return { ok: false, text: err.message };
    return { ok: false, text: "Tool " + name + " crashed: " + (err && err.stack || err) };
  }
}

function toolSchemas() {
  return TOOLS.map((t) => ({
    name: t.name, description: t.description,
    inputSchema: { type: "object", properties: t.params, required: t.required },
  }));
}

// ------------------------------------------------------------- tool bridge
// Loopback TCP server the MCP child (bridge.js, spawned by the claude CLI)
// forwards tools/list and tools/call to. Same wire format as the proven
// Python ToolBridge: one JSON object per line, token-gated, localhost only.
function startBridge(state, onEvent) {
  const token = crypto.randomBytes(16).toString("hex");
  const server = net.createServer((socket) => {
    let buffer = "";
    socket.on("data", async (chunk) => {
      buffer += chunk.toString("utf8");
      let idx;
      while ((idx = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, idx); buffer = buffer.slice(idx + 1);
        if (!line.trim()) continue;
        let msg;
        try { msg = JSON.parse(line); } catch (e) { continue; }
        if (msg.token !== token) {
          socket.write(JSON.stringify({ ok: false, error: "bad token" }) + "\n");
          continue;
        }
        let reply;
        if (msg.op === "list") {
          reply = { ok: true, tools: toolSchemas() };
        } else if (msg.op === "call") {
          const args = msg.arguments || msg.input || {};
          if (onEvent) onEvent("call", msg.name, args);
          const started = Date.now();
          const r = await executeTool(state, msg.name, args);
          if (onEvent) onEvent("result", msg.name,
                               { ok: r.ok, ms: Date.now() - started });
          reply = { ok: r.ok, content: r.text };   // wire format of bridge.js
          if (r.images) reply.images = r.images;   // -> MCP image blocks
        } else {
          reply = { ok: false, error: "unknown op" };
        }
        socket.write(JSON.stringify(reply) + "\n");
      }
    });
    socket.on("error", () => {});
  });
  return new Promise((resolveP) => {
    server.listen(0, "127.0.0.1", () => {
      resolveP({ server, port: server.address().port, token });
    });
  });
}

module.exports = {
  PERMISSION_MODES, READONLY_TOOLS, APPROVAL_TIMEOUT_MS, ResolveError,
  makeState, needsApproval, requestApproval, executeTool, toolSchemas,
  startBridge, TOOLS,
};
