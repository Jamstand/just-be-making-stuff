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
const { spawn } = require("child_process");

const PERMISSION_MODES = ["Ask before edits", "Always ask", "Never ask"];
const APPROVAL_TIMEOUT_MS = 120000;

const READONLY_TOOLS = new Set([
  "get_workspace_overview", "list_media_pool", "get_clip_properties",
  "pipeline_doctor", "study_edit", "watch_video", "set_gemini_key",
  "gemini_status",
  "list_timelines", "list_markers", "list_render_presets",
  "get_render_status", "move_playhead", "open_page",
  // grab_still LOOKS at a frame: the gallery still it makes is deleted
  // again after export, so treating it as a read keeps vision friction-free.
  "grab_still", "compare_stills",
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
function needsApproval(state, name, input) {
  const mode = state.permissionMode;
  if (mode === "Always ask") return true;
  if (mode !== "Ask before edits") return false;
  if (state.approveAllEdits) return false;
  // pre_grade grabs briefly create/delete a temp timeline in the project:
  // that is a write, even though a plain grab_still is a read.
  if (name === "grab_still" && input && input.pre_grade) return true;
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

// --------------------------------------------------- still-file inspection
// Phase 1 of the colour suite: never trust the intended bit depth, read it.
// parseTiff reads the header; tiffCensus counts DISTINCT values per channel
// on uncompressed data — 8-bit data smuggled in a 16-bit container shows
// <=256 levels, real 10-bit <=1024. That census, not the file extension,
// answers "is this the data I think it is".

function parseTiff(buffer) {
  if (buffer.length < 8) return null;
  const le = buffer[0] === 0x49 && buffer[1] === 0x49;      // 'II' vs 'MM'
  if (!le && !(buffer[0] === 0x4d && buffer[1] === 0x4d)) return null;
  const u16 = (o) => (le ? buffer.readUInt16LE(o) : buffer.readUInt16BE(o));
  const u32 = (o) => (le ? buffer.readUInt32LE(o) : buffer.readUInt32BE(o));
  if (u16(2) !== 42) return null;
  const info = { littleEndian: le, bitsPerSample: null, compression: null,
                 width: null, height: null, samplesPerPixel: 3,
                 stripOffsets: null, stripByteCounts: null };
  let ifd = u32(4);
  if (ifd + 2 > buffer.length) return info;
  const count = u16(ifd);
  for (let i = 0; i < count; i++) {
    const entry = ifd + 2 + i * 12;
    if (entry + 12 > buffer.length) break;
    const tag = u16(entry), type = u16(entry + 2), n = u32(entry + 4);
    const short = (o) => u16(o);
    const inline = entry + 8;
    const valueAt = (idx) => {
      const size = type === 3 ? 2 : 4;
      const base = (n * size <= 4) ? inline : u32(inline);
      const off = base + idx * size;
      if (off + size > buffer.length) return null;
      return type === 3 ? short(off) : u32(off);
    };
    if (tag === 256) info.width = valueAt(0);
    else if (tag === 257) info.height = valueAt(0);
    else if (tag === 258) info.bitsPerSample = valueAt(0);
    else if (tag === 259) info.compression = valueAt(0);
    else if (tag === 277) info.samplesPerPixel = valueAt(0);
    else if (tag === 273)
      info.stripOffsets = Array.from({ length: n }, (_, k) => valueAt(k));
    else if (tag === 279)
      info.stripByteCounts = Array.from({ length: n }, (_, k) => valueAt(k));
  }
  return info;
}

function tiffCensus(buffer, info) {
  if (!info || info.compression !== 1 || !info.stripOffsets ||
      !info.stripByteCounts)
    return { skipped: "census needs uncompressed strip TIFF (compression=" +
                      (info && info.compression) + ")" };
  const bits = info.bitsPerSample;
  if (bits !== 8 && bits !== 16)
    return { skipped: "census handles 8/16 bits, file says " + bits };
  const channels = Math.max(1, Math.min(4, info.samplesPerPixel || 3));
  const seen = Array.from({ length: channels },
                          () => new Uint8Array(65536 >> 3));
  const unique = new Array(channels).fill(0);
  const le = info.littleEndian;
  let index = 0;
  for (let s = 0; s < info.stripOffsets.length; s++) {
    const start = info.stripOffsets[s];
    const end = Math.min(buffer.length, start + info.stripByteCounts[s]);
    const step = bits >> 3;
    for (let o = start; o + step <= end; o += step) {
      const v = bits === 8 ? buffer[o]
                : (le ? buffer.readUInt16LE(o) : buffer.readUInt16BE(o));
      const c = index % channels;
      index += 1;
      if (!((seen[c][v >> 3] >> (v & 7)) & 1)) {
        seen[c][v >> 3] |= 1 << (v & 7);
        unique[c] += 1;
      }
    }
  }
  return { unique_per_channel: unique.slice(0, 3),
           samples_counted: index };
}

function effectiveDepthLabel(unique) {
  const top = Math.max.apply(null, unique || [0]);
  if (top > 4096) return "~14-16 bit (" + top + " distinct levels)";
  if (top > 1024) return "~12 bit (" + top + " distinct levels)";
  if (top > 256) return "~10 bit (" + top + " distinct levels)";
  if (top > 64) return "8 bit (" + top + " distinct levels)";
  return "suspiciously flat (" + top + " distinct levels)";
}

function parseExr(buffer) {
  if (buffer.length < 8 || buffer.readUInt32LE(0) !== 0x01312f76) return null;
  const out = { pixelType: null, compression: null };
  let o = 8;
  const readStr = () => {
    const start = o;
    while (o < buffer.length && buffer[o] !== 0) o++;
    const s = buffer.toString("latin1", start, o); o++; return s;
  };
  const COMP = ["none", "rle", "zips", "zip", "piz", "pxr24", "b44", "b44a"];
  while (o < buffer.length) {
    const name = readStr();
    if (!name) break;                     // end of header
    readStr();                            // attribute type
    const size = buffer.readInt32LE(o); o += 4;
    const data = o; o += size;
    if (name === "compression") out.compression = COMP[buffer[data]] || buffer[data];
    if (name === "channels") {
      let c = data;
      while (c < data + size && buffer[c] !== 0) {
        while (buffer[c] !== 0) c++;
        c++;
        const pt = buffer.readInt32LE(c);
        out.pixelType = ["uint32", "half-float 16", "float 32"][pt] || pt;
        break;                            // first channel is representative
      }
    }
  }
  return out;
}

function timecodeToFrame(tc, fps) {
  const nominal = Math.max(1, Math.round(Number(fps) || 24));
  const p = String(tc || "").replace(/;/g, ":").split(":")
    .map((n) => parseInt(n, 10) || 0);
  while (p.length < 4) p.unshift(0);
  return ((p[0] * 60 + p[1]) * 60 + p[2]) * nominal + p[3];
}

// Drop-frame conversion (29.97/59.94 families): true frame count ->
// "hh:mm:ss;ff". Heidelberger algorithm; unit-tested against the standard
// vectors (29.97 frame 1800 -> 00:01:00;02, 59.94 frame 3600 -> 00:01:00;04).
function dropFrameTimecode(frame, fps) {
  const fpsInt = Math.round(fps);
  const drop = Math.round(fpsInt / 15);           // 2 for 29.97, 4 for 59.94
  const perMin = fpsInt * 60 - drop;
  const per10 = fpsInt * 600 - drop * 9;
  const tens = Math.floor(frame / per10);
  const rem = frame % per10;
  let fn = frame + drop * 9 * tens;
  if (rem > drop) fn += drop * Math.floor((rem - drop) / perMin);
  const pad = (n) => String(n).padStart(2, "0");
  return pad(Math.floor(fn / (fpsInt * 3600))) + ":" +
         pad(Math.floor(fn / (fpsInt * 60)) % 60) + ":" +
         pad(Math.floor(fn / fpsInt) % 60) + ";" + pad(fn % fpsInt);
}

// The label a given TIMELINE actually uses for a frame: drop-frame when the
// timeline says so (a nominal non-drop label on a DF timeline lands on
// dropped numbers and never matches the readback — review-confirmed).
function timelineLabel(tl, frame) {
  const fps = Number(tl.GetSetting("timelineFrameRate")) || 24;
  let drop = false;
  try { drop = String(tl.GetSetting("timelineDropFrameTimecode")) === "1"; }
  catch (e) {}
  const dfFamily = Math.abs(fps - 29.97) < 0.05
                   || Math.abs(fps - 59.94) < 0.1;
  return drop && dfFamily ? dropFrameTimecode(frame, fps)
                          : frameToTimecode(frame, fps);
}

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

async function exportOneStill(album, still, dir, prefix, format) {
  const before = new Set(fs.readdirSync(dir));
  album.ExportStills([still], dir, prefix, format);
  await sleep(200);                       // export is not always synchronous
  // Filenames are unpredictable — diff the directory instead.
  const fresh = fs.readdirSync(dir).filter((n) => !before.has(n));
  for (const sidecar of fresh)            // a .drx sidecar always appears
    if (sidecar.toLowerCase().endsWith(".drx")) {
      try { fs.unlinkSync(path.join(dir, sidecar)); } catch (e) {}
    }
  const wanted = fresh.find((n) => {
    const low = n.toLowerCase();
    return format === "tif" ? (low.endsWith(".tif") || low.endsWith(".tiff"))
                            : low.endsWith("." + format);
  });
  return wanted ? path.join(dir, wanted) : null;
}

// A 1080p photographic PNG routinely blows past the MCP image budget, and a
// proxy nobody can see defeats grab_still's purpose. Inside Resolve's
// Electron, downscale + JPEG the proxy (measurement never touches it — the
// TIFF/EXR is the data path); under plain node (tests) electron does not
// exist and the caller falls back to the raw PNG when it is small enough.
function shrinkProxy(proxyPath) {
  let nativeImage;
  try { nativeImage = require("electron").nativeImage; }
  catch (e) { return null; }
  try {
    let img = nativeImage.createFromPath(proxyPath);
    if (!img || img.isEmpty()) return null;
    if (img.getSize().width > 1280) img = img.resize({ width: 1280 });
    const jpeg = img.toJPEG(80);
    if (jpeg && jpeg.length && jpeg.length <= 4500000)
      return { data: jpeg.toString("base64"), media_type: "image/jpeg" };
  } catch (e) {}
  return null;
}

tool("grab_still",
  "Grab a still of the current timeline frame for ANALYSIS and viewing. " +
  "Exports a measurement file (format 'tif' default — 16-bit intent — " +
  "or 'png'; Resolve's gallery export cannot write EXR, live-verified) " +
  "plus an 8-bit PNG proxy that is returned to your " +
  "vision; measurements must use the measurement file, never the proxy. " +
  "The result reports the file's ACTUAL bit depth (parsed from its header) " +
  "and a distinct-value census per channel, so quantised or clipped data " +
  "is caught instead of assumed away. pre_grade=true grabs the SOURCE " +
  "image by placing the same clip on a temporary timeline (fresh " +
  "placements carry no grade; AddVersion copies grades, live-verified) " +
  "parked on the matching source frame, then deleting that timeline — " +
  "non-destructive, but it is a write and asks for approval. " +
  "Optional frame/timecode parks the playhead first.",
  { frame: { type: "number",
             description: "Absolute timeline frame to park on (optional)." },
    timecode: { type: "string",
                description: "Or a timecode like 01:00:12:03 (optional)." },
    format: { type: "string", enum: ["tif", "png"],
              description: "Measurement export format; default tif." },
    pre_grade: { type: "boolean",
                 description: "Grab the ungraded source via a temporary "
                              + "timeline (created and deleted again)." },
    out_dir: { type: "string",
               description: "Export directory; default /tmp." },
    no_proxy: { type: "boolean",
                description: "Skip the vision proxy entirely — for "
                             + "measurement sweeps that only read numbers "
                             + "(halves the per-grab cost)." } },
  [], async (state, a) => {
    const resolve = state.resolve;
    const proj = project(state);
    const tl = timeline(state);
    const format = ["tif", "png"].includes(a.format) ? a.format : "tif";
    let tc = a.timecode ? String(a.timecode) : null;
    if (!tc && a.frame !== undefined && a.frame !== null)
      tc = timelineLabel(tl, Math.floor(Number(a.frame)));

    const previousPage = resolve.GetCurrentPage();
    resolve.OpenPage("color");            // GrabStill only works from Color
    // Park AFTER the page switch: SetCurrentTimecode is rejected from the
    // Edit page (live-verified).
    if (tc) {
      if (!tl.SetCurrentTimecode(tc))
        throw new ResolveError("Resolve rejected timecode " + tc);
      // This seek is ALSO asynchronous (live-verified by the 9-clip QC
      // scan: reading the playhead straight back returned the previous
      // position, clamping clips 3-9 to their first source frame). Wait
      // for the park to land before grabbing or computing from it.
      const normTc = (t) => String(t || "").replace(/;/g, ":");
      for (let i = 0; i < 10 && normTc(tl.GetCurrentTimecode())
                                !== normTc(tc); i++)
        await sleep(200);
      await sleep(300);
    }
    let tempTimeline = null, grabTl = tl, item = null, preMap = null;
    try {
      item = tl.GetCurrentVideoItem && tl.GetCurrentVideoItem();
      if (a.pre_grade) {
        if (!item)
          throw new ResolveError("pre_grade needs a clip under the playhead.");
        const mpItem = item.GetMediaPoolItem && item.GetMediaPoolItem();
        if (!mpItem)
          throw new ResolveError("pre_grade: this timeline item has no media "
            + "pool clip to re-place (title or generator?).");
        // AddVersion COPIES the current grade (live-verified: a CDL slammed
        // on node 1 survived into the "fresh" version byte-for-byte), so the
        // only honest pre-grade source is a NEW timeline item — fresh
        // placements carry no grade. Same clip, same SOURCE frame, its own
        // throwaway timeline.
        const tlFps = Number(tl.GetSetting("timelineFrameRate")) || 24;
        // Trust the REQUESTED timecode over a playhead readback that can
        // still be in flight; fall back to the readback only when the
        // caller didn't park.
        const here = timecodeToFrame(tc || tl.GetCurrentTimecode(), tlFps);
        // Timeline frames and SOURCE frames are different clocks when the
        // clip rate differs from the timeline rate (59.94 media in a 24
        // timeline advances ~2.5 source frames per timeline frame) —
        // convert through seconds, never mix the two.
        const srcFps = Number(mpItem.GetClipProperty
                              && mpItem.GetClipProperty("FPS")) || tlFps;
        const srcFrame = Math.round(
          (item.GetLeftOffset ? item.GetLeftOffset() : 0)
          + Math.max(0, here - item.GetStart()) * (srcFps / tlFps));
        const mediaPool = proj.GetMediaPool();
        tempTimeline = mediaPool.CreateTimelineFromClips(
          "claude_pregrade_" + Date.now().toString(36), [mpItem]);
        if (!tempTimeline)
          throw new ResolveError("pre_grade: CreateTimelineFromClips "
            + "returned nothing — cannot build the temporary timeline.");
        if (!proj.SetCurrentTimeline(tempTimeline))
          throw new ResolveError("pre_grade: could not switch to the "
            + "temporary timeline.");
        grabTl = tempTimeline;
        // No silent fallback here: live round 5 proved that guessing the
        // temp timeline's rate parks on the wrong source frame while
        // reporting success. If it won't tell us, we stop.
        const tempFpsRaw = grabTl.GetSetting("timelineFrameRate");
        const tempFps = Number(tempFpsRaw);
        if (!tempFps)
          throw new ResolveError("pre_grade: the temporary timeline did not "
            + "report a usable frame rate (got " + JSON.stringify(tempFpsRaw)
            + ") — refusing to guess where to park.");
        const track = grabTl.GetItemListInTrack
                      && grabTl.GetItemListInTrack("video", 1);
        const tempItem = track && track[0];
        if (!tempItem)
          throw new ResolveError("pre_grade: no clip on the temporary "
            + "timeline's video track 1.");
        // Park via the temp item's own geometry, not assumptions about
        // where CreateTimelineFromClips placed it.
        const tempLeft = tempItem.GetLeftOffset
                         ? tempItem.GetLeftOffset() : 0;
        const destFrame = tempItem.GetStart()
          + Math.round((srcFrame - tempLeft) * (tempFps / srcFps));
        const dest = frameToTimecode(destFrame, tempFps);
        if (!grabTl.SetCurrentTimecode(dest))
          throw new ResolveError("pre_grade: Resolve rejected timecode "
            + dest + " on the temporary timeline.");
        // The seek after a timeline switch is asynchronous: the call
        // returns true while the viewer is still travelling, and GrabStill
        // captures whatever frame is on screen (live-verified — three runs,
        // three different frames). Wait for the readback, then settle.
        let readback = null;
        const normDest = String(dest).replace(/;/g, ":");
        for (let i = 0; i < 10; i++) {
          readback = grabTl.GetCurrentTimecode();
          if (String(readback || "").replace(/;/g, ":") === normDest) break;
          await sleep(200);
        }
        await sleep(400);
        preMap = { main_timecode: tl.GetCurrentTimecode(),
                   item_start: item.GetStart(),
                   left_offset: item.GetLeftOffset ? item.GetLeftOffset() : 0,
                   timeline_fps: tlFps, source_fps: srcFps,
                   source_frame: srcFrame,
                   temp_fps: tempFps, temp_item_start: tempItem.GetStart(),
                   temp_left_offset: tempLeft, dest_frame: destFrame,
                   temp_timecode: dest, temp_readback: readback,
                   parked: String(readback || "").replace(/;/g, ":")
                           === normDest };
      }

      const gallery = proj.GetGallery();
      const album = gallery && gallery.GetCurrentStillAlbum();
      if (!album)
        throw new ResolveError("No gallery album available — open the Color "
                               + "page gallery once so Resolve creates one.");
      let still = null;
      for (let attempt = 0; attempt < 3 && !still; attempt++) {
        still = grabTl.GrabStill();       // intermittently falsy: retry
        if (!still) await sleep(400);
      }
      if (!still)
        throw new ResolveError("GrabStill kept returning nothing — is a "
                               + "timeline open with a clip at the playhead?");

      const stamp = Date.now().toString(36);
      // macOS Resolve cannot write /tmp (trap 9, re-confirmed live in the
      // Lambo session — every grab burned a failed first attempt), so the
      // home stills dir is the darwin default.
      const preferred = a.out_dir ? String(a.out_dir)
        : process.platform === "darwin"
          ? path.join(os.homedir(), "ClaudeAssistantStills")
          : process.platform === "win32" ? os.tmpdir() : "/tmp";
      const dirs = [preferred,
                    path.join(os.homedir(), "ClaudeAssistantStills")];
      let measurePath = null, proxyPath = null, usedDir = null;
      for (const dir of dirs) {
        try { fs.mkdirSync(dir, { recursive: true }); } catch (e) { continue; }
        measurePath = await exportOneStill(album, still, dir,
                                           "claude_m" + stamp, format);
        if (!measurePath) continue;
        usedDir = dir;
        proxyPath = a.no_proxy ? null
          : format === "png" ? measurePath
          : await exportOneStill(album, still, dir, "claude_p" + stamp,
                                 "png");
        break;
      }
      try { album.DeleteStills([still]); } catch (e) {}
      if (!measurePath)
        throw new ResolveError("Resolve exported no " + format + " into " +
          dirs.join(" or ") + " — macOS Resolve sometimes cannot write to "
          + "system temp dirs; both attempts failed.");

      // Never trust the intended depth — read the file's own header.
      const bytes = fs.readFileSync(measurePath);
      const analysis = { format, bytes: bytes.length };
      if (format === "tif") {
        const info = parseTiff(bytes);
        analysis.bits_per_sample = info ? info.bitsPerSample : "unparsed";
        analysis.compression = info ? info.compression : null;
        const census = info ? tiffCensus(bytes, info) : { skipped: "unparsed" };
        if (census.unique_per_channel) {
          analysis.unique_values_rgb = census.unique_per_channel;
          analysis.effective_depth =
            effectiveDepthLabel(census.unique_per_channel);
        } else {
          analysis.census_skipped = census.skipped;
        }
      } else {
        analysis.bits_per_sample = 8;
        analysis.note = "PNG is 8-bit — fine for looking, wrong for "
                        + "measuring log footage.";
      }

      const out = { measurement_file: measurePath, dir: usedDir,
                    analysis, pre_grade: !!a.pre_grade,
                    timecode: grabTl.GetCurrentTimecode() };
      if (preMap) out.pre_grade_map = preMap;
      try {
        const mpItem = item && item.GetMediaPoolItem && item.GetMediaPoolItem();
        if (mpItem)
          out.clip = { name: item.GetName(),
                       input_color_space:
                         mpItem.GetClipProperty("Input Color Space") };
      } catch (e) {}
      if (proxyPath) {
        out.proxy_png = proxyPath;
        const shrunk = shrinkProxy(proxyPath);
        if (shrunk) { out._images = [shrunk]; out.proxy_attach = "jpeg-shrunk"; }
        else {
          const proxyBytes = fs.readFileSync(proxyPath);
          if (proxyBytes.length <= 4500000) {
            out._images = [{ data: proxyBytes.toString("base64"),
                             media_type: "image/png" }];
            out.proxy_attach = "png-raw";
          }
          else out.proxy_note = "proxy too large to attach and no Electron "
            + "image codec available to shrink it; view it on disk";
        }
      }
      return out;
    } finally {
      if (tempTimeline) {
        try { proj.SetCurrentTimeline(tl); } catch (e) {}
        try { proj.GetMediaPool().DeleteTimelines([tempTimeline]); }
        catch (e) {}
      }
      if (previousPage && previousPage !== "color") {
        try { resolve.OpenPage(previousPage); } catch (e) {}
      }
    }
  });

// --------------------------------------------------- Phase 2: pipeline doctor
// The camera's Sony XML sidecar (C0797.MP4 -> C0797M01.XML) is ground truth
// for what a clip IS: live-verified that Resolve leaves Gamma Notes empty
// for a6700 AVC while the sidecar plainly says s-log3-cine/s-gamut3-cine
// (the H.264 stream itself claims rec709 coding, which is only the encode
// matrix — the classic Sony misread).
const SONY_GAMMA = { "s-log3-cine": "S-Log3", "s-log3": "S-Log3",
                     "s-log2": "S-Log2" };
const SONY_GAMUT = { "s-gamut3-cine": "S-Gamut3.Cine",
                     "s-gamut3": "S-Gamut3" };

function parseSonySidecar(xml) {
  const grab = (re) => { const m = re.exec(xml); return m ? m[1] : null; };
  const gamma = grab(/name="CaptureGammaEquation"\s+value="([^"]*)"/);
  const gamut = grab(/name="CaptureColorPrimaries"\s+value="([^"]*)"/);
  const out = {
    capture_gamma: gamma, capture_gamut: gamut,
    capture_fps: grab(/captureFps="([^"]*)"/),
    camera: grab(/<Device[^>]*modelName="([^"]*)"/),
    camera_lut: grab(/RelatedTo\s+file="([^"]*)"\s+rel="LUT"/),
  };
  const g = gamma && SONY_GAMMA[gamma.toLowerCase()];
  const p = gamut && SONY_GAMUT[gamut.toLowerCase()];
  if (g && p) out.expected_input_color_space = p + "/" + g;
  return out;
}

function findSidecar(clipPath) {
  const dir = path.dirname(clipPath);
  const base = path.basename(clipPath).replace(/\.[^.]+$/, "");
  for (const name of [base + "M01.XML", base + "M01.xml",
                      base + ".XML", base + ".xml"]) {
    const full = path.join(dir, name);
    try { if (fs.statSync(full).isFile()) return full; } catch (e) {}
  }
  try {
    const hit = fs.readdirSync(dir).find((n) =>
      n.startsWith(base) && /\.xml$/i.test(n));
    if (hit) return path.join(dir, hit);
  } catch (e) {}
  return null;
}

function clipProp(clip, key) {
  let v = null;
  try { v = clip.GetClipProperty(key); } catch (e) { return ""; }
  if (v && typeof v === "object") v = v[key];   // some builds return the map
  return v === null || v === undefined ? "" : v;
}

function itemLuts(item) {
  try {
    if (typeof item.GetNodeGraph === "function") {
      const g = item.GetNodeGraph();
      if (g && typeof g.GetNumNodes === "function") {
        const n = Number(g.GetNumNodes()) || 0;
        const luts = [];
        for (let i = 1; i <= n; i++) {
          let l = null;
          try { l = g.GetLUT(i); } catch (e) {}
          if (typeof l === "string" && l) luts.push({ node: i, lut: l });
        }
        return { method: "node graph", nodes: n, luts };
      }
    }
  } catch (e) {}
  if (typeof item.GetLUT === "function") {
    const luts = [];
    for (let i = 1; i <= 8; i++) {
      let l = null;
      try { l = item.GetLUT(i); } catch (e) {}
      if (typeof l === "string" && l) luts.push({ node: i, lut: l });
    }
    return { method: "GetLUT probe of nodes 1-8", nodes: null, luts };
  }
  return { method: "unavailable", nodes: null, luts: [] };
}

tool("pipeline_doctor",
  "Audit the project for colour-management mistakes. READ-ONLY: changes "
  + "nothing. Reads project/timeline colour settings, every media pool "
  + "clip's Input Color Space and Gamma Notes, the Sony XML sidecar next "
  + "to each media file (camera ground truth for capture gamma/gamut), "
  + "node LUTs where this Resolve exposes them, and clip-vs-timeline "
  + "frame-rate mixes. Findings come with plain-English 'why it matters'. "
  + "Honest limits are listed in api_walls — the API cannot see OFX nodes, "
  + "so CST double-conversion checks are heuristic at best.",
  {}, [], (state) => {
    const proj = project(state);
    const setting = (k) => { try { return proj.GetSetting(k) || ""; }
                             catch (e) { return ""; } };
    const cm = {
      color_science: setting("colorScienceMode"),
      project_input_color_space: setting("colorSpaceInput"),
      timeline_color_space: setting("colorSpaceTimeline"),
      output_color_space: setting("colorSpaceOutput"),
    };
    const managed = /colormanaged/i.test(String(cm.color_science));
    const findings = [];
    const norm = (v) => String(v || "").toLowerCase().replace(/[\s._-]/g, "");

    if (!managed)
      findings.push({ severity: "warning", where: "project",
        what: "Colour science is " + (cm.color_science || "unknown")
              + " — not colour managed.",
        why: "Input Color Space tags (clip and project) are inert in this "
             + "mode. Log clips display untransformed unless a node "
             + "LUT/CST converts them, and every input-space check below "
             + "reports what WOULD happen if RCM were enabled." });

    // ---- media pool walk
    const clips = [];
    const walk = (folder, prefix) => {
      for (const c of folder.GetClipList() || []) {
        const type = String(clipProp(c, "Type"));
        const row = { bin: prefix, name: c.GetName(), type,
                      input_color_space: clipProp(c, "Input Color Space"),
                      gamma_notes: clipProp(c, "Gamma Notes"),
                      fps: clipProp(c, "FPS") };
        if (/video/i.test(type)) {
          const file = String(clipProp(c, "File Path"));
          const side = file && findSidecar(file);
          if (side) {
            try {
              row.sidecar = parseSonySidecar(fs.readFileSync(side, "utf8"));
              row.sidecar.file = side;
            } catch (e) { row.sidecar_error = e.message; }
          } else if (file) {
            row.sidecar = null;
            findings.push({ severity: "info", where: row.name,
              what: "No Sony XML sidecar found next to the media file.",
              why: "Without it the only gamma evidence is Resolve's own "
                   + "metadata, which is blank for these files — the clip "
                   + "cannot be verified against camera ground truth." });
          }
          const expected = row.sidecar
                           && row.sidecar.expected_input_color_space;
          if (expected) {
            if (!row.gamma_notes)
              findings.push({ severity: "info", where: row.name,
                what: "Resolve's Gamma Notes is empty; the camera sidecar "
                      + "says " + row.sidecar.capture_gamma + "/"
                      + row.sidecar.capture_gamut + ".",
                why: "Resolve did not read the Sony sidecar. Anything "
                     + "keying off clip metadata will treat this log clip "
                     + "as ordinary Rec.709 video." });
            const effective = row.input_color_space
                              && row.input_color_space !== "Project"
                              ? row.input_color_space
                              : (cm.project_input_color_space
                                 || "(project default)");
            row.effective_input_color_space = effective;
            if (norm(effective) !== norm(expected))
              findings.push({
                severity: managed ? "problem" : "warning", where: row.name,
                what: "Camera recorded " + expected + " but the effective "
                      + "input colour space is " + effective
                      + (row.input_color_space === "Project"
                         ? " (inherited from the project default)" : "") + ".",
                why: managed
                  ? "RCM is decoding this log clip with the wrong input "
                    + "transform: shadows lift, highlights clamp, colours "
                    + "skew before any grade is applied. Fix: set the "
                    + "clip's Input Color Space to " + expected + "."
                  : "Inert today (project not colour managed), but the "
                    + "moment RCM is enabled this clip decodes wrongly. "
                    + "Set the clip tag to " + expected
                    + " so the project is safe to migrate." });
          }
        }
        clips.push(row);
      }
      for (const sub of folder.GetSubFolderList() || [])
        walk(sub, prefix + sub.GetName() + "/");
    };
    walk(proj.GetMediaPool().GetRootFolder(), "/");

    // ---- current timeline: rates and node LUTs
    const tl = proj.GetCurrentTimeline();
    let timeline = null;
    if (tl) {
      const tlFps = Number(tl.GetSetting("timelineFrameRate")) || null;
      timeline = { name: tl.GetName(), fps: tlFps, items: [] };
      const tracks = Number(tl.GetTrackCount("video")) || 0;
      for (let t = 1; t <= tracks; t++) {
        for (const item of tl.GetItemListInTrack("video", t) || []) {
          const row = { track: t, name: item.GetName() };
          const mp = item.GetMediaPoolItem && item.GetMediaPoolItem();
          const clipFps = mp ? Number(clipProp(mp, "FPS")) : null;
          if (clipFps && tlFps && Math.abs(clipFps - tlFps) > 0.01) {
            row.fps_mismatch = clipFps + " media in a " + tlFps
                               + " timeline";
            findings.push({ severity: "warning", where: row.name,
              what: "Frame-rate mix: " + row.fps_mismatch + ".",
              why: "Every timeline frame lands between source frames, so "
                   + "Retime Process (nearest/frame-blend/optical flow) "
                   + "decides what you see — blends and optical-flow "
                   + "artifacts masquerade as motion blur, and QC "
                   + "measurements sample synthesised frames "
                   + "(live-verified on this very setup)." });
          }
          const lutInfo = itemLuts(item);
          row.node_luts = lutInfo;
          for (const l of lutInfo.luts) {
            const lutName = path.basename(l.lut);
            const toRec709 = /to.?s?709|s?log.?to|709\.cube$/i
                             .test(lutName);
            if (managed)
              findings.push({ severity: "warning",
                where: row.name + " node " + l.node,
                what: "Node LUT " + lutName + " while RCM is active.",
                why: "RCM already handles the log-to-working conversion; "
                     + (toRec709
                        ? "this looks like a log-to-709 conversion LUT, "
                          + "which would convert a second time — double "
                          + "transform."
                        : "if this LUT also converts colour space the "
                          + "image is transformed twice. Creative LUTs "
                          + "expecting log input will also misbehave "
                          + "after RCM's conversion.") });
            else if (toRec709)
              findings.push({ severity: "info",
                where: row.name + " node " + l.node,
                what: "Conversion LUT " + lutName
                      + " is doing the log-to-709 work.",
                why: "Consistent with an unmanaged project — but if you "
                     + "enable RCM later, remove this LUT or it will "
                     + "double-convert." });
          }
          if (lutInfo.method === "unavailable")
            timeline.node_lut_note = "This Resolve exposes no node LUT "
              + "readback API; LUT checks skipped.";
          timeline.items.push(row);
        }
      }
    }

    return {
      color_management: cm,
      managed,
      clips, timeline, findings,
      api_walls: [
        "OFX nodes (incl. Color Space Transform) are invisible to the "
        + "scripting API: 'manual CST while RCM active' and 'LUT after "
        + "CST-out' cannot be checked directly — LUT findings above are "
        + "the honest subset.",
        "Grades are write-only (SetCDL has no readback), so node "
        + "contents beyond LUT paths cannot be inspected.",
      ],
    };
  });

// ------------------------------------------------------- Phase 3: QC scanner
// Full-depth pixel statistics from a single histogram pass. Interpretation
// thresholds are heuristics and say so in the report; the numbers are exact.
function tiffStats(buffer, info) {
  if (!info || info.compression !== 1 || !info.stripOffsets ||
      !info.stripByteCounts)
    return { skipped: "stats need an uncompressed strip TIFF" };
  const bits = info.bitsPerSample;
  if (bits !== 8 && bits !== 16)
    return { skipped: "stats handle 8/16 bits, file says " + bits };
  const channels = Math.max(1, Math.min(4, info.samplesPerPixel || 3));
  const hist = Array.from({ length: channels },
                          () => new Uint32Array(65536));
  const step = bits >> 3;
  let index = 0;
  for (let st = 0; st < info.stripOffsets.length; st++) {
    const start = info.stripOffsets[st];
    const end = Math.min(buffer.length, start + info.stripByteCounts[st]);
    for (let o = start; o + step <= end; o += step) {
      const v = bits === 8 ? buffer[o]
        : (info.littleEndian ? buffer.readUInt16LE(o)
                             : buffer.readUInt16BE(o));
      hist[index % channels][v] += 1;
      index += 1;
    }
  }
  const full = bits === 8 ? 255 : 65535;
  const out = { channels: [],
                samples_per_channel: Math.floor(index / channels) };
  for (let c = 0; c < Math.min(channels, 3); c++) {
    const h = hist[c];
    let min = -1, max = -1, sum = 0, sq = 0, n = 0;
    for (let v = 0; v <= full; v++) {
      const k = h[v];
      if (!k) continue;
      if (min < 0) min = v;
      max = v; sum += v * k; sq += v * v * k; n += k;
    }
    const meanV = sum / (n || 1);
    const stdV = Math.sqrt(Math.max(0, sq / (n || 1) - meanV * meanV));
    let lo = 0, hi = 0;
    const loEnd = Math.round(full * 0.01), hiStart = Math.round(full * 0.99);
    for (let v = 0; v <= loEnd; v++) lo += h[v];
    for (let v = hiStart; v <= full; v++) hi += h[v];
    const pct = (x) => +(100 * x / (n || 1)).toFixed(3);
    out.channels.push({
      min, max,
      mean_pct: +((100 * meanV) / full).toFixed(2),
      std_pct: +((100 * stdV) / full).toFixed(2),
      // A hard clip is a PLATEAU: many samples at one exact code value.
      at_exact_min_pct: pct(min < 0 ? 0 : h[min]),
      at_exact_max_pct: pct(max < 0 ? 0 : h[max]),
      bottom_1pct_of_scale_pct: pct(lo),
      top_1pct_of_scale_pct: pct(hi),
      // Percentile levels (P_LEVELS) as % of full scale: the matcher fits
      // its CDL to these curves, not just to mean/std.
      pctl: (() => {
        const res = [];
        let cum = 0, li = 0;
        for (let v = 0; v <= full && li < P_LEVELS.length; v++) {
          cum += h[v];
          while (li < P_LEVELS.length && cum >= P_LEVELS[li] * (n || 1)) {
            res.push(+((100 * v) / full).toFixed(3)); li += 1;
          }
        }
        while (res.length < P_LEVELS.length) res.push(+((100 * (max < 0 ? 0 : max)) / full).toFixed(3));
        return res;
      })(),
    });
  }
  out.joint = jointStats(buffer, info, channels, bits, full);
  return out;
}

const P_LEVELS = [0.01, 0.05, 0.1, 0.25, 0.5, 0.75, 0.9, 0.95, 0.99];
const HUE_SECTORS = 12;                          // 30° each, centred on 0,30,…
const HUE_BINS = 72;                             // 5° hue histogram bins
// ±1-bin smoothing of a hue histogram, so spiky content (charts, graphics)
// does not turn a 5° shift into a lost overlap or a staircase CDF.
const smoothHue = (H) => H.map((v, k) => 0.25 * (H[(k + HUE_BINS - 1) % HUE_BINS] || 0) + 0.5 * (v || 0) + 0.25 * (H[(k + 1) % HUE_BINS] || 0));
// The one definition of "a pixel with a hue worth counting" — jointStats
// (the measurement) and simHueStats (the simulation) must agree on it.
const isColoured = (sat, mx, d) => sat >= 0.1 && mx >= 0.08 && d >= 0.02;
const SKIN_LINE_DEG = 123;                       // vectorscope skin-tone line

// One pass over (a stride of) the pixels for everything a per-channel
// histogram cannot give: saturation, a luma median, greyness-weighted
// neutral means (auto balance), per-hue-sector means (hue-selective match)
// and a skin-tone cluster (YCbCr rule, Chai & Ngan) with its vectorscope
// angle. Display-referred RGB in, everything in % of full scale.
function jointStats(buffer, info, channels, bits, full) {
  const step = bits >> 3, pxBytes = step * channels;
  let total = 0;
  for (let st = 0; st < info.stripOffsets.length; st++)
    total += Math.floor(info.stripByteCounts[st] / pxBytes);
  const stride = Math.max(1, Math.floor(total / 400000));
  const rd = (o) => (bits === 8 ? buffer[o] : (info.littleEndian
    ? buffer.readUInt16LE(o) : buffer.readUInt16BE(o))) / full;
  const lumaHist = new Uint32Array(1024), chromaHist = new Uint32Array(1001);
  const sec = Array.from({ length: HUE_SECTORS }, () =>
    ({ n: 0, r: 0, g: 0, b: 0, cos: 0, sin: 0, sat: 0, val: 0 }));
  const skin = { n: 0, cb: 0, cr: 0, y: 0, cos: 0, sin: 0 };
  const hueHist = new Float64Array(HUE_BINS);
  const binRgb = [new Float64Array(HUE_BINS), new Float64Array(HUE_BINS), new Float64Array(HUE_BINS)];
  let n = 0, sumSat = 0, sumChroma = 0, sumLuma = 0, wSum = 0, wr = 0, wg = 0, wb = 0;
  const p95 = [0, 0, 0];
  let k = 0;
  for (let st = 0; st < info.stripOffsets.length; st++) {
    const start = info.stripOffsets[st];
    const end = Math.min(buffer.length, start + info.stripByteCounts[st]);
    for (let o = start; o + pxBytes <= end; o += pxBytes, k++) {
      if (k % stride) continue;
      const r = rd(o), g = channels > 1 ? rd(o + step) : r, b = channels > 2 ? rd(o + 2 * step) : r;
      const mx = Math.max(r, g, b), mn = Math.min(r, g, b), d = mx - mn;
      const sat = mx > 1e-6 ? d / mx : 0;
      const luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;
      n += 1; sumSat += sat; sumChroma += d; sumLuma += luma;
      lumaHist[Math.min(1023, Math.round(luma * 1023))] += 1;
      chromaHist[Math.min(1000, Math.round(d * 1000))] += 1;
      // Near-neutral vote: only barely-tinted mid-tones count, and the
      // less tinted the louder (pastel skin must not pull a white balance).
      const wn = Math.max(0, 1 - sat / 0.25);
      const w = wn * wn * (luma > 0.03 && luma < 0.97 ? 1 : 0);
      wSum += w; wr += w * r; wg += w * g; wb += w * b;
      if (isColoured(sat, mx, d)) {
        const h = rgbToHsv(r, g, b)[0];
        // Soft membership: the two nearest sector centres share the pixel,
        // so a patch sitting on a boundary cannot flip sectors between frames.
        const hb = Math.floor(h / (360 / HUE_BINS)) % HUE_BINS;
        hueHist[hb] += 1; binRgb[0][hb] += r; binRgb[1][hb] += g; binRgb[2][hb] += b;
        const span = 360 / HUE_SECTORS, lo = Math.floor(h / span), frac = h / span - lo;
        const cs = Math.cos(h * Math.PI / 180), sn = Math.sin(h * Math.PI / 180);
        // Weighted by chroma: a vivid pixel says more about its hue than a
        // barely-tinted one, and sensor noise in the darks says nothing.
        for (const [si, w0] of [[lo % HUE_SECTORS, 1 - frac], [(lo + 1) % HUE_SECTORS, frac]]) {
          const w = w0 * d;
          if (w <= 0) continue;
          const S = sec[si];
          S.n += w; S.r += w * r; S.g += w * g; S.b += w * b; S.sat += w * sat; S.val += w * mx;
          S.cos += w * cs; S.sin += w * sn;
        }
      }
      const cb = 128 + 255 * (-0.168736 * r - 0.331264 * g + 0.5 * b);
      const cr = 128 + 255 * (0.5 * r - 0.418688 * g - 0.081312 * b);
      if (cb >= 77 && cb <= 127 && cr >= 133 && cr <= 173 && luma > 0.1 && luma < 0.9) {
        skin.n += 1; skin.cb += cb - 128; skin.cr += cr - 128; skin.y += luma;
      }
    }
  }
  const N = n || 1;
  const pctOf = (hist, p) => { let cum = 0; for (let v = 0; v < hist.length; v++) { cum += hist[v]; if (cum >= p * N) return +((100 * v) / (hist.length - 1)).toFixed(2); } return 100; };
  const chromaTotal = sec.reduce((t, S) => t + S.n, 0) || 1;
  const sectors = sec.map((S, i) => ({
    hue_centre: i * (360 / HUE_SECTORS),
    pct: +((100 * S.n) / chromaTotal).toFixed(2),        // share of the frame's chroma
    mean_rgb_pct: S.n ? [S.r, S.g, S.b].map((v) => +((100 * v) / S.n).toFixed(2)) : null,
    mean_hue: S.n ? +((((Math.atan2(S.sin, S.cos) * 180 / Math.PI) % 360) + 360) % 360).toFixed(1) : null,
    mean_sat: S.n ? +(S.sat / S.n).toFixed(3) : null,
    mean_val: S.n ? +(S.val / S.n).toFixed(3) : null }));
  const skinAngle = skin.n ? ((Math.atan2(skin.cr / skin.n, skin.cb / skin.n) * 180 / Math.PI) + 360) % 360 : null;
  return {
    sampled_pixels: n, stride,
    mean_sat: +(sumSat / N).toFixed(4),
    mean_chroma_pct: +((100 * sumChroma) / N).toFixed(2),
    chroma_p90_pct: pctOf(chromaHist, 0.9),
    luma: { mean_pct: +((100 * sumLuma) / N).toFixed(2), median_pct: pctOf(lumaHist, 0.5),
            p05_pct: pctOf(lumaHist, 0.05), p95_pct: pctOf(lumaHist, 0.95) },
    neutral_mean_pct: wSum > 0 ? [wr, wg, wb].map((v) => +((100 * v) / wSum).toFixed(2)) : null,
    neutral_weight_pct: +((100 * wSum) / N).toFixed(1),
    hue_sectors: sectors,
    hue_hist: (() => { const t = hueHist.reduce((a, b) => a + b, 0) || 1; return Array.from(hueHist, (v) => +(v / t).toFixed(5)); })(),   // 5° bins, share of coloured pixels
    hue_bins_rgb_pct: Array.from(hueHist, (cnt, k) => (cnt ? [0, 1, 2].map((c) => +((100 * binRgb[c][k]) / cnt).toFixed(2)) : null)),
    skin: { pct: +((100 * skin.n) / N).toFixed(2),
            angle_deg: skinAngle === null ? null : +skinAngle.toFixed(1),
            line_deviation_deg: skinAngle === null ? null : +(((skinAngle - SKIN_LINE_DEG + 540) % 360) - 180).toFixed(1),
            mean_chroma: skin.n ? +Math.hypot(skin.cb / skin.n, skin.cr / skin.n).toFixed(1) : null,
            mean_luma_pct: skin.n ? +((100 * skin.y) / skin.n).toFixed(1) : null },
  };
}

// A stride of the grab's pixels taken into the node's working space (DI-log
// via the display->DI model). The matcher simulates candidate CDLs on these
// instead of guessing how saturation and per-channel terms interact.
function sampleDi(buffer, info, maxN) {
  const bits = info.bitsPerSample, channels = Math.max(1, Math.min(4, info.samplesPerPixel || 3));
  const step = bits >> 3, pxBytes = step * channels, full = bits === 8 ? 255 : 65535;
  let total = 0;
  for (let st = 0; st < info.stripOffsets.length; st++) total += Math.floor(info.stripByteCounts[st] / pxBytes);
  const stride = Math.max(1, Math.ceil(total / (maxN || 40000)));
  const out = new Float32Array(3 * Math.ceil(total / stride));
  const rd = (o) => (bits === 8 ? buffer[o] : (info.littleEndian ? buffer.readUInt16LE(o) : buffer.readUInt16BE(o)));
  let k = 0, n = 0;
  for (let st = 0; st < info.stripOffsets.length; st++) {
    const start = info.stripOffsets[st], end = Math.min(buffer.length, start + info.stripByteCounts[st]);
    for (let o = start; o + pxBytes <= end; o += pxBytes, k++) {
      if (k % stride) continue;
      for (let c = 0; c < 3; c++) out[3 * n + c] = displayPctToDi(100 * rd(o + Math.min(c, channels - 1) * step) / full);
      n += 1;
    }
  }
  return out.subarray(0, 3 * n);
}

// What the grab would measure if this CDL sat on the node (DI-log model):
// per-channel percentile curves + means in display %, and HSV saturation.
function simStats(samples, cdl, sat) {
  const n = samples.length / 3, hist = [new Uint32Array(1001), new Uint32Array(1001), new Uint32Array(1001)];
  const chromaHist = new Uint32Array(1001);
  const sum = [0, 0, 0]; let satSum = 0;
  const px = [0, 0, 0];
  for (let i = 0; i < n; i++) {
    for (let c = 0; c < 3; c++) px[c] = Math.pow(Math.max(0, samples[3 * i + c] * cdl.slope[c] + cdl.offset[c]), cdl.power[c]);
    if (sat !== 1) { const l = 0.2126 * px[0] + 0.7152 * px[1] + 0.0722 * px[2]; for (let c = 0; c < 3; c++) px[c] = l + (px[c] - l) * sat; }
    let mx = 0, mn = 100;
    for (let c = 0; c < 3; c++) {
      const v = Math.min(100, Math.max(0, 100 * Math.pow(diDecode(Math.max(0, px[c])), 1 / 2.4)));
      px[c] = v; sum[c] += v; hist[c][Math.round(v * 10)] += 1;
      if (v > mx) mx = v; if (v < mn) mn = v;
    }
    satSum += mx > 1e-3 ? (mx - mn) / mx : 0;
    chromaHist[Math.min(1000, Math.round((mx - mn) * 10))] += 1;
  }
  let chromaP90 = 100;
  for (let v = 0, cum = 0; v <= 1000; v++) { cum += chromaHist[v]; if (cum >= 0.9 * n) { chromaP90 = v / 10; break; } }
  const pctl = hist.map((h) => { const res = []; let cum = 0, li = 0;
    for (let v = 0; v <= 1000 && li < P_LEVELS.length; v++) { cum += h[v]; while (li < P_LEVELS.length && cum >= P_LEVELS[li] * n) { res.push(v / 10); li += 1; } }
    while (res.length < P_LEVELS.length) res.push(100); return res; });
  return { pctl, mean: sum.map((v) => v / (n || 1)), mean_sat: satSum / (n || 1), chroma_p90: chromaP90 };
}

// Coordinate descent on (slope, offset, power) x3 + saturation against the
// goal percentile curves and the reference saturation, evaluated through
// simStats. fitCdl gives the starting point; this fixes what a per-channel
// fit cannot see (saturation mixes the channels).
function refineCdl(goalPctl, refSat, samples, init, opts) {
  opts = opts || {};
  const P = [init.slope[0], init.slope[1], init.slope[2], init.offset[0], init.offset[1], init.offset[2],
             init.power[0], init.power[1], init.power[2], init.sat === undefined ? 1 : init.sat];
  const lo = [0.25, 0.25, 0.25, -0.5, -0.5, -0.5, 0.5, 0.5, 0.5, 0.5], hi = [4, 4, 4, 0.5, 0.5, 0.5, 2, 2, 2, 2];
  let steps = [0.04, 0.04, 0.04, 0.01, 0.01, 0.01, 0.05, 0.05, 0.05, 0.08];
  const active = [0, 1, 2, 3, 4, 5].concat(opts.power === false ? [] : [6, 7, 8]).concat(opts.saturation === false || refSat === null ? [] : [9]);
  const cost = (v) => {
    const st = simStats(samples, { slope: v.slice(0, 3), offset: v.slice(3, 6), power: v.slice(6, 9) }, v[9]);
    let j = 0;
    for (let c = 0; c < 3; c++) for (let k = 1; k <= 7; k++) j += (st.pctl[c][k] - goalPctl[c][k]) ** 2;
    if (refSat !== null && active.includes(9)) j += 4 * (st.chroma_p90 - refSat) ** 2;
    return j;
  };
  let best = cost(P), evals = 1;
  for (let pass = 0; pass < (opts.passes || 4); pass++) {
    for (const i of active) {
      for (const dir of [1, -1]) {
        for (let rep = 0; rep < 3; rep++) {
          const trial = P.slice(); trial[i] = clampN(trial[i] + dir * steps[i], lo[i], hi[i]);
          if (trial[i] === P[i]) break;
          const j = cost(trial); evals += 1;
          if (j < best - 1e-9) { best = j; P[i] = trial[i]; } else break;
        }
      }
    }
    steps = steps.map((v) => v / 2);
  }
  return { slope: P.slice(0, 3), offset: P.slice(3, 6), power: P.slice(6, 9), sat: P[9], cost: best, evals };
}

// Hue statistics the recipe would produce, simulated on the target's own DI
// samples: run each pixel through the look, back to display, then the same
// thresholds and 5° bins jointStats uses.
function simHueStats(samples, look) {
  const n = samples.length / 3, hist = new Float64Array(HUE_BINS), rgb = [new Float64Array(HUE_BINS), new Float64Array(HUE_BINS), new Float64Array(HUE_BINS)];
  const adjustments = (look && look.hue_adjustments) || [];
  let total = 0;
  for (let i = 0; i < n; i++) {
    let p = [samples[3 * i], samples[3 * i + 1], samples[3 * i + 2]];
    if (adjustments.length) p = applyLook(p, look);
    const d3 = p.map((y) => Math.min(1, Math.max(0, Math.pow(diDecode(Math.max(0, y)), 1 / 2.4))));
    const [r, g, b] = d3, mx = Math.max(r, g, b), mn = Math.min(r, g, b), d = mx - mn, sat = mx > 1e-6 ? d / mx : 0;
    if (!isColoured(sat, mx, d)) continue;
    const h = rgbToHsv(r, g, b)[0];
    const k = Math.floor(h / (360 / HUE_BINS)) % HUE_BINS;
    hist[k] += 1; rgb[0][k] += r; rgb[1][k] += g; rgb[2][k] += b; total += 1;
  }
  return { hue_hist: Array.from(hist, (v) => v / (total || 1)),
           hue_bins_rgb_pct: Array.from(hist, (cnt, k) => (cnt ? [0, 1, 2].map((c) => (100 * rgb[c][k]) / cnt) : null)) };
}

// How far a frame's hue content sits from the reference: histogram L1 (are
// the hues in the same places) plus, per bin both frames occupy, the DI-space
// saturation and value gap of the bin's mean colour, weighted by shared mass.
function hueCost(refJoint, sim) {
  const diHsv = diHsvPct;
  let l1 = 0, colour = 0;
  for (let k = 0; k < HUE_BINS; k++) {
    const a = refJoint.hue_hist[k] || 0, b = sim.hue_hist[k] || 0;
    l1 += Math.abs(a - b);
    const ra = refJoint.hue_bins_rgb_pct && refJoint.hue_bins_rgb_pct[k], rb = sim.hue_bins_rgb_pct && sim.hue_bins_rgb_pct[k];
    if (ra && rb) { const ha = diHsv(ra), hb = diHsv(rb); colour += Math.min(a, b) * (Math.abs(ha[1] - hb[1]) + Math.abs(ha[2] - hb[2])); }
  }
  return l1 + 10 * colour;
}

// Keep only the adjustments that measurably move the target's hue content
// toward the reference (greedy add, then a short coordinate descent), so a
// recipe can never make a frame worse by its own yardstick.
function refineHueRecipe(refJoint, samples, adjustments, opts) {
  opts = opts || {};
  const cost = (adj) => hueCost(refJoint, simHueStats(samples, { hue_adjustments: adj }));
  const before = cost([]);
  let kept = [], best = before, evals = 1;
  const order = adjustments.slice().sort((a, b) => Math.abs(b.shift) - Math.abs(a.shift));
  for (const adj of order) {
    let winner = null;
    for (const scale of [1, 0.5]) {
      const trial = Object.assign({}, adj, { shift: +(adj.shift * scale).toFixed(1), sat: +Math.pow(adj.sat, scale).toFixed(3), gain: +(adj.gain * scale).toFixed(3) });
      const c = cost(kept.concat([trial])); evals += 1;
      if (c < best - 0.005 * before) { best = c; winner = trial; break; }  // must earn its keep
    }
    if (winner) kept.push(winner);
  }
  const steps = { shift: 2, sat: 0.05, gain: 0.02 }, lo = { shift: -25, sat: 0.7, gain: -0.1 }, hi = { shift: 25, sat: 1.4, gain: 0.1 };
  for (let pass = 0; pass < (opts.passes === undefined ? 2 : opts.passes); pass++)
    for (let i = 0; i < kept.length; i++)
      for (const key of ["shift", "sat", "gain"])
        for (const dir of [1, -1]) {
          const trial = kept.slice(); trial[i] = Object.assign({}, kept[i]);
          trial[i][key] = +clampN(kept[i][key] + dir * steps[key] / (pass + 1), lo[key], hi[key]).toFixed(3);
          if (trial[i][key] === kept[i][key]) continue;
          const c = cost(trial); evals += 1;
          if (c < best - 1e-6) { best = c; kept = trial; }
        }
  kept = kept.filter((a) => Math.abs(a.shift) >= 1 || Math.abs(a.sat - 1) >= 0.02 || Math.abs(a.gain) >= 0.02);
  const after = cost(kept);
  // Noise-level differences produce noise-level recipes: below a 25% gain
  // in the frame's own yardstick, nothing is worth a LUT.
  const minGain = opts.min_gain === undefined ? 0.25 : Number(opts.min_gain);
  if (after > before * (1 - minGain)) kept = [];
  return { hue_adjustments: kept, cost_before: +before.toFixed(4), cost_after: +(kept.length ? after : before).toFixed(4), evals,
           rejected: kept.length ? null : "improvement under " + Math.round(minGain * 100) + "% — not worth a LUT" };
}

// Grab a clip's mid frame as a measurement TIFF and reduce it — the one
// measure step every colour tool shares. `a.out_dir` is the grab dir;
// grabOpts overrides (no_proxy, pre_grade...).
async function measureItem(state, item, a, grabOpts) {
  const grabEntry = TOOLS.find((t) => t.name === "grab_still");
  const frame = item.GetStart() + Math.floor((Number(item.GetDuration()) || 2) / 2);
  const g = await grabEntry.fn(state, Object.assign({ frame, format: "tif", out_dir: (a || {}).out_dir }, grabOpts || {}));
  const m = measureBuffer(fs.readFileSync(g.measurement_file));
  if (m.error) throw new ResolveError("Could not measure " + item.GetName() + ": " + m.error);
  return Object.assign(m, { proxy: (g._images || [])[0], file: g.measurement_file, timecode: g.timecode });
}

// Everything the matcher needs from one grab, from its bytes.
function measureBuffer(buffer) {
  const info = parseTiff(buffer);
  const st = tiffStats(buffer, info);
  if (!st.channels) return { error: st.skipped || "no stats" };
  return { stats: st.channels, joint: st.joint, samples: sampleDi(buffer, info, 40000) };
}

// Minimal little-endian uncompressed RGB16 TIFF from [r,g,b] 0..1 pixels —
// what the tests and the benchmark feed tiffStats (Resolve's own TIFF
// grabs are exactly this shape).
function writeTiff16(pixels, width, height) {
  const entries = 9, ifd = 8, dataOff = ifd + 2 + entries * 12 + 4;
  const bpsOff = dataOff, stripOff = dataOff + 6, bytes = pixels.length * 6;
  const buf = Buffer.alloc(stripOff + bytes);
  buf.write("II", 0); buf.writeUInt16LE(42, 2); buf.writeUInt32LE(ifd, 4);
  buf.writeUInt16LE(entries, ifd);
  const tag = (i, id, type, count, value) => {
    const o = ifd + 2 + i * 12;
    buf.writeUInt16LE(id, o); buf.writeUInt16LE(type, o + 2);
    buf.writeUInt32LE(count, o + 4); buf.writeUInt32LE(value, o + 8);
  };
  tag(0, 256, 4, 1, width); tag(1, 257, 4, 1, height); tag(2, 258, 3, 3, bpsOff);
  tag(3, 259, 3, 1, 1); tag(4, 262, 3, 1, 2); tag(5, 273, 4, 1, stripOff);
  tag(6, 277, 3, 1, 3); tag(7, 278, 4, 1, height); tag(8, 279, 4, 1, bytes);
  for (let i = 0; i < 3; i++) buf.writeUInt16LE(16, bpsOff + i * 2);
  for (let i = 0; i < pixels.length; i++)
    for (let c = 0; c < 3; c++)
      buf.writeUInt16LE(Math.round(Math.max(0, Math.min(1, pixels[i][c])) * 65535), stripOff + (i * 3 + c) * 2);
  return buf;
}

// ~7.7% of full scale per stop: S-Log3's log segment slope (261.5/1023 code
// per decade => 261.5*log10(2)/1023 of scale per doubling). Only quoted for
// S-Log3 material; other spaces get raw percentages, no fake stop numbers.
const SLOG3_PCT_PER_STOP = 7.7;

tool("qc_scan",
  "Phase 3 QC: walk the current timeline's clips, grab a measurement TIFF "
  + "from each (pre_grade source pixels by default — real camera data on "
  + "true source frames, immune to retime synthesis), and report per clip: "
  + "clipped-highlight / crushed-shadow plateaus (% of samples at one exact "
  + "rail value), exposure (mean level, flagged against the timeline "
  + "median, in stops for S-Log3), and colour cast (R-G / B-G balance). "
  + "Numbers are exact full-depth statistics; the clip/crush/cast FLAGS use "
  + "stated heuristic thresholds. Creates and deletes a temporary timeline "
  + "per clip in pre_grade mode, so it asks for approval once. Slow: "
  + "roughly 2-4s per clip — use max_clips/start_index to batch.",
  { track: { type: "number", description: "Video track (default 1)." },
    pre_grade: { type: "boolean",
                 description: "Measure ungraded source pixels (default "
                              + "true). false = measure the graded render." },
    max_clips: { type: "number",
                 description: "Scan at most this many clips (default 25)." },
    start_index: { type: "number",
                   description: "1-based first clip (default 1) for "
                                + "batching long timelines." },
    out_dir: { type: "string",
               description: "Export directory; default /tmp." } },
  [], async (state, a) => {
    const proj = project(state);
    const tl = timeline(state);
    const track = Number(a.track) || 1;
    const preGrade = a.pre_grade !== false;
    const first = Math.max(1, Number(a.start_index) || 1);
    const cap = Math.max(1, Number(a.max_clips) || 25);
    const items = tl.GetItemListInTrack("video", track) || [];
    if (!items.length)
      throw new ResolveError("No clips on video track " + track + ".");
    const tlFps = Number(tl.GetSetting("timelineFrameRate")) || 24;
    // The measurement SPACE depends on the project: under RCM every grab is
    // display-referred (input transform + working space + output transform),
    // so S-Log3 arithmetic on the tagged clips would be exactly wrong.
    // Unmanaged projects hand us raw source code values (live-verified:
    // rails at the S-Log3 legal-range footprint pre-migration, and a 99%
    // pixel shift the moment RCM was enabled).
    const sci = (() => { try { return String(proj.GetSetting(
      "colorScienceMode") || ""); } catch (e) { return ""; } })();
    const rcm = /colormanaged/i.test(sci);
    const outSpace = (() => { try { return String(proj.GetSetting(
      "colorSpaceOutput") || ""); } catch (e) { return ""; } })();
    const drt = (() => { try { return String(proj.GetSetting(
      "outputDRT") || ""); } catch (e) { return ""; } })();
    const grabEntry = TOOLS.find((t) => t.name === "grab_still");
    const clips = [];
    const batch = items.slice(first - 1, first - 1 + cap);
    for (let i = 0; i < batch.length; i++) {
      const item = batch[i];
      const row = { index: first + i, name: item.GetName() };
      try {
        const mid = item.GetStart()
                    + Math.floor((Number(item.GetDuration()) || 2) / 2);
        // Direct fn call: qc_scan itself carried the approval; per-grab
        // prompts would turn one consented scan into N nag cards.
        const grab = await grabEntry.fn(state, {
          frame: mid, format: "tif", pre_grade: preGrade,
          out_dir: a.out_dir, no_proxy: true,
        });
        row.measurement_file = grab.measurement_file;
        row.timecode = grab.timecode;
        const stats = tiffStats(fs.readFileSync(grab.measurement_file),
                                parseTiff(fs.readFileSync(
                                  grab.measurement_file)));
        row.stats = stats;
        if (stats.channels) {
          row.mean_level_pct = +(stats.channels
            .reduce((t, c) => t + c.mean_pct, 0) / 3).toFixed(2);
          row.cast = {
            r_minus_g_pct: +(stats.channels[0].mean_pct
                             - stats.channels[1].mean_pct).toFixed(2),
            b_minus_g_pct: +(stats.channels[2].mean_pct
                             - stats.channels[1].mean_pct).toFixed(2),
          };
          if (stats.joint) {
            row.saturation = stats.joint.mean_sat;
            row.skin = stats.joint.skin;
            row.neutral_cast = stats.joint.neutral_mean_pct ? {
              r_minus_g_pct: +(stats.joint.neutral_mean_pct[0] - stats.joint.neutral_mean_pct[1]).toFixed(2),
              b_minus_g_pct: +(stats.joint.neutral_mean_pct[2] - stats.joint.neutral_mean_pct[1]).toFixed(2) } : null;
          }
          delete row.stats.joint;          // the summary above is the readable form
        }
        const mp = item.GetMediaPoolItem && item.GetMediaPoolItem();
        const ics = mp ? String(clipProp(mp, "Input Color Space")) : "";
        row.slog3 = /s-?log3/i.test(ics)
          || (grab.clip && /s-?log3/i.test(
                String(grab.clip.input_color_space || "")));
      } catch (e) {
        row.error = e.message;             // one bad clip must not kill a scan
      }
      clips.push(row);
    }

    // Timeline-level flags, thresholds stated inline.
    const flags = [];
    const levels = clips.filter((c) => c.mean_level_pct !== undefined)
                        .map((c) => c.mean_level_pct).sort((x, y) => x - y);
    const median = levels.length
      ? levels[Math.floor(levels.length / 2)] : null;
    // Exposure model: gamma24 = grabs are Rec.709 Gamma 2.4 (RCM output,
    // invertible while outputDRT is None): stops = 2.4*log2(level ratio).
    // slog3 = unmanaged project handing over raw S-Log3: stops = delta/7.7.
    // percent = no defensible stop conversion; raw percentages only.
    // A tone-mapping DRT bends the curve: 2.4*log2 stays midtone-usable
    // but is no longer exact, and the model name must say so.
    const exposureModel = rcm
      ? (/gamma 2\.4/i.test(outSpace)
         ? (!drt || /none/i.test(drt) ? "gamma24" : "gamma24-approx")
         : "percent")
      : (clips.some((c) => c.slog3) ? "slog3" : "percent");
    const stopsFrom = (level) => {
      if (median === null || !level) return null;
      if (exposureModel === "gamma24" || exposureModel === "gamma24-approx")
        return +(2.4 * Math.log2(level / median)).toFixed(2);
      if (exposureModel === "slog3")
        return +((level - median) / SLOG3_PCT_PER_STOP).toFixed(2);
      return null;
    };
    for (const c of clips) {
      if (!c.stats || !c.stats.channels) continue;
      if (c.skin && c.skin.pct >= 2 && Math.abs(c.skin.line_deviation_deg) > 8)
        flags.push({ clip: c.name, kind: "skin-cast",
          detail: c.skin.pct + "% skin pixels sit " + c.skin.line_deviation_deg
            + "° off the skin-tone line (threshold 8°, " + (c.skin.line_deviation_deg > 0 ? "toward red/magenta" : "toward yellow/green")
            + "): match_hues against a good clip, or design_look hue_adjustments {hue: 25, width: 30, shift: "
            + (-c.skin.line_deviation_deg / 2).toFixed(0) + "} (skin sits near HSV hue 25°)." });
      for (let ch = 0; ch < 3; ch++) {
        const cs = c.stats.channels[ch], name = "RGB"[ch];
        if (cs.at_exact_max_pct > 0.5)
          flags.push({ clip: c.name, kind: "clipped-highlights",
            detail: name + ": " + cs.at_exact_max_pct + "% of samples sit "
              + "on one plateau at code " + cs.max
              + " (threshold 0.5%) — flat sensor/encode ceiling." });
        if (cs.at_exact_min_pct > 0.5)
          flags.push({ clip: c.name, kind: "crushed-shadows",
            detail: name + ": " + cs.at_exact_min_pct + "% of samples on "
              + "the floor at code " + cs.min + " (threshold 0.5%)." });
      }
      if (median !== null && c.mean_level_pct !== undefined) {
        const d = +(c.mean_level_pct - median).toFixed(2);
        const st = stopsFrom(c.mean_level_pct);
        const over = st !== null ? Math.abs(st) > 1
                                 : Math.abs(d) > 10;
        if (st !== null) c.exposure_stops_vs_median = st;
        if (over)
          flags.push({ clip: c.name, kind: "exposure-outlier",
            detail: (d > 0 ? "+" : "") + d + "% of scale vs timeline "
              + "median " + median + "%"
              + (st !== null
                 ? " ≈ " + (st > 0 ? "+" : "") + st + " stops ("
                   + (exposureModel === "gamma24" ? "via output gamma 2.4"
                      : exposureModel === "gamma24-approx"
                      ? "midtone approximation — tone mapping bends the "
                        + "curve, highlights read compressed"
                      : "S-Log3 slope") + ")"
                 : " (no stop conversion for this pipeline)") });
      }
      if (c.cast && (Math.abs(c.cast.r_minus_g_pct) > 3
                     || Math.abs(c.cast.b_minus_g_pct) > 3))
        flags.push({ clip: c.name, kind: "colour-cast",
          detail: "R-G " + c.cast.r_minus_g_pct + "%, B-G "
            + c.cast.b_minus_g_pct + "% (threshold 3%): "
            + (c.cast.r_minus_g_pct > 3 ? "warm/red lean"
               : c.cast.b_minus_g_pct > 3 ? "cool/blue lean"
               : "green/magenta imbalance") + "." });
    }
    return {
      timeline: tl.GetName(), track,
      measured: preGrade ? "pre-grade source pixels (true source frames)"
                         : "graded timeline render",
      measurement_space: rcm
        ? "RCM output-referred (" + (outSpace || "unknown output space")
          + "; outputDRT " + (drt || "None")
          + ") — the display transform is baked into every number"
        : "raw source code values (unmanaged project)",
      exposure_model: exposureModel,
      clips_scanned: clips.length,
      clips_total: items.length,
      remaining_hint: first - 1 + clips.length < items.length
        ? "continue with start_index: " + (first + clips.length) : null,
      timeline_median_level_pct: median,
      clips, flags,
      thresholds: { plateau_pct: 0.5, cast_pct: 3,
                    exposure_outlier: exposureModel === "percent"
                      ? "10% of scale (no stop conversion available)"
                      : "1 stop (" + exposureModel + " model)" },
    };
  });

// ------------------------------------------------------ Phase 4: shot matcher
// Closed-loop Reinhard matching. The grabs are display-referred (Rec.709
// Gamma 2.4 through the DaVinci DRT — not invertible in closed form), but
// the CDL node operates in the timeline working space (DaVinci
// WG/Intermediate log). So: estimate DI-log statistics by pushing display
// stats through gamma-2.4 decode + the published DI encode, derive
// slope/offset there, apply, RE-GRAB, and let the measured residual correct
// the approximation. Iteration is what makes the unknown DRT harmless.
const DI = {          // DaVinci Intermediate log constants (Blackmagic doc)
  A: 0.0075, B: 7.0, C: 0.07329248, M: 10.44426855, CUT: 0.00262409,
};
function diEncode(lin) {
  return lin <= DI.CUT ? lin * DI.M
                       : (Math.log2(lin + DI.A) + DI.B) * DI.C;
}
function displayPctToDi(pct) {
  // Display level (0-100% of Rec.709 Gamma 2.4) -> approximate DI-log value.
  // The DRT bends this — the closed loop absorbs that error.
  return diEncode(Math.pow(Math.max(0, pct) / 100, 2.4));
}

// Should these two shots be matched at all? Refuses the night-vs-day case
// instead of inventing a grade that fakes it.
function matchGate(refCh, tgtCh) {
  const mean = (chs) => chs.reduce((t, c) => t + c.mean_pct, 0) / chs.length;
  const rM = mean(refCh), tM = mean(tgtCh);
  if (rM <= 0.5 || tM <= 0.5)
    return { refuse: true, reason: "One of the frames is essentially "
             + "black — nothing statistical to match." };
  const stops = 2.4 * Math.log2(rM / tM);
  if (Math.abs(stops) > 2.5)
    return { refuse: true, stops_apart: +stops.toFixed(2),
      reason: "Exposure regimes are " + Math.abs(stops).toFixed(1)
        + " stops apart (limit 2.5). Forcing a match would fake a "
        + "different scene, not correct this one — expose or grade it "
        + "deliberately instead." };
  const sd = (chs) => chs.reduce((t, c) => t + c.std_pct, 0) / chs.length;
  const ratio = sd(refCh) / Math.max(0.01, sd(tgtCh));
  if (ratio > 4 || ratio < 0.25)
    return { refuse: true, contrast_ratio: +ratio.toFixed(2),
      reason: "Contrast regimes differ by " + ratio.toFixed(1)
        + "x (limits 0.25-4): these are different kinds of images "
        + "(e.g. flat overcast vs hard night contrast)." };
  return { refuse: false, stops_apart: +stops.toFixed(2) };
}

// Per-channel Reinhard in estimated DI space:
//   out = (in - mu_t) * (sigma_r / sigma_t) + mu_r  ==  slope*in + offset
function deriveCdl(refCh, tgtCh) {
  const slope = [], offset = [];
  for (let c = 0; c < 3; c++) {
    const rMu = displayPctToDi(refCh[c].mean_pct);
    const tMu = displayPctToDi(tgtCh[c].mean_pct);
    const rSg = displayPctToDi(refCh[c].mean_pct + refCh[c].std_pct) - rMu;
    const tSg = displayPctToDi(tgtCh[c].mean_pct + tgtCh[c].std_pct) - tMu;
    const sl = Math.min(4, Math.max(0.25,
      tSg > 1e-6 ? rSg / tSg : 1));
    slope.push(sl);
    offset.push(rMu - tMu * sl);
  }
  return { slope, offset };
}
const cdlStr = (v) => v.map((x) => x.toFixed(4)).join(" ");
const clampN = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

// Full CDL fit per channel from percentile curves: out = (slope*x +
// offset)^power in DI-log, least squares over p05..p95 (p01/p99 left out
// so clipped rails cannot steer it), power on a grid with a small pull
// toward 1 so identical curves fit the identity exactly.
function fitCdl(refPctl, tgtPctl, opts) {
  opts = opts || {};
  const idx = [1, 2, 3, 4, 5, 6, 7];
  const grid = opts.power === false ? [1]
    : Array.from({ length: 31 }, (_, i) => +(0.5 + i * 0.05).toFixed(2));
  const slope = [], offset = [], power = [], rms = [];
  for (let c = 0; c < 3; c++) {
    const xs = idx.map((i) => displayPctToDi(tgtPctl[c][i]));
    const ys = idx.map((i) => displayPctToDi(refPctl[c][i]));
    let best = null;
    for (const p of grid) {
      const yt = ys.map((y) => Math.pow(Math.max(0, y), 1 / p));
      const mx = xs.reduce((t, v) => t + v, 0) / xs.length;
      const my = yt.reduce((t, v) => t + v, 0) / yt.length;
      let sxx = 0, sxy = 0;
      for (let i = 0; i < xs.length; i++) { sxx += (xs[i] - mx) ** 2; sxy += (xs[i] - mx) * (yt[i] - my); }
      const sl = clampN(sxx > 1e-12 ? sxy / sxx : 1, 0.25, 4);
      const of = clampN(my - sl * mx, -0.5, 0.5);
      let err = 0;
      for (let i = 0; i < xs.length; i++) err += (Math.pow(Math.max(0, sl * xs[i] + of), p) - ys[i]) ** 2;
      err = err / xs.length + 0.0004 * (p - 1) ** 2;
      if (!best || err < best.err) best = { sl, of, p, err };
    }
    slope.push(best.sl); offset.push(best.of); power.push(best.p);
    rms.push(+Math.sqrt(Math.max(0, best.err)).toFixed(4));
  }
  return { slope, offset, power, rms_di: rms };
}

// Auto balance with no reference: greyness-weighted grey-world gains
// blended with a white-patch estimate, then exposure from the luma median.
// A linear gain is an OFFSET in DI-log (C*log2(gain)), so the whole thing
// is a slope-1 CDL: honest to the node's working space.
function balanceEstimate(stats, opts) {
  opts = opts || {};
  const channels = stats.channels || stats.stats;              // tiffStats or measureBuffer shape
  const J = stats.joint;
  if (!J || !J.neutral_mean_pct || J.neutral_weight_pct < 1)
    return { refuse: true, reason: "Too few near-neutral pixels to judge a "
      + "white balance from (" + (J ? J.neutral_weight_pct : 0) + "% weight)." };
  const lin = (pct) => Math.pow(Math.max(0, pct) / 100, 2.4);
  const nl = J.neutral_mean_pct.map(lin);
  const grey = (nl[0] + nl[1] + nl[2]) / 3;
  const gw = nl.map((v) => grey / Math.max(1e-6, v));
  const wpl = channels.map((ch) => lin(ch.pctl[7]));             // p95
  const wmax = Math.max(...wpl);
  const wp = wpl.map((v) => wmax / Math.max(1e-6, v));
  const blend = opts.white_patch_weight === undefined ? 0.3 : clampN(Number(opts.white_patch_weight), 0, 1);
  let gains = gw.map((g, c) => Math.exp((1 - blend) * Math.log(g) + blend * Math.log(wp[c])));
  gains = gains.map((g) => clampN(g / gains[1], 0.5, 2));         // green = 1
  const strength = opts.strength === undefined ? 1 : clampN(Number(opts.strength), 0, 1);
  gains = gains.map((g) => Math.pow(g, strength));               // what is actually applied
  const wbOffset = gains.map((g) => DI.C * Math.log2(g));
  let stops = 0;
  if (opts.exposure !== false) {
    // A luma median anywhere in the band is "exposed"; outside it, move to
    // the nearest edge (or to target_median_pct when one is given).
    const maxStops = Number(opts.max_stops) || 1.5;
    const med = J.luma.median_pct;
    let target = Number(opts.target_median_pct) || 0;
    if (!target) { const band = [Number(opts.band_low_pct) || 30, Number(opts.band_high_pct) || 55]; target = med < band[0] ? band[0] : med > band[1] ? band[1] : med; }
    stops = clampN(Math.log2(lin(target) / Math.max(1e-6, lin(med))), -maxStops, maxStops) * strength;
    if (Math.abs(stops) < 0.1) stops = 0;                          // dead band
  }
  const offset = wbOffset.map((o) => o + DI.C * stops);
  return { refuse: false, gains: gains.map((g) => +g.toFixed(4)), strength, exposure_stops: +stops.toFixed(2),
    slope: [1, 1, 1], offset, power: [1, 1, 1], saturation: 1,
    cast_before: { r_minus_g_pct: +(J.neutral_mean_pct[0] - J.neutral_mean_pct[1]).toFixed(2),
                   b_minus_g_pct: +(J.neutral_mean_pct[2] - J.neutral_mean_pct[1]).toFixed(2) },
    luma_median_pct: J.luma.median_pct, neutral_weight_pct: J.neutral_weight_pct };
}

// Hue-selective correction from two frames' hue-sector means: per sector a
// hue shift, a saturation ratio and a value gain, in the look designer's
// hue_adjustments form (so it becomes a .cube). Sectors too thin in either
// frame are skipped and named.
function hueMatchRecipe(refJoint, tgtJoint, opts) {
  opts = opts || {};
  const minPct = opts.min_sector_pct === undefined ? 1 : Number(opts.min_sector_pct);
  const strength = opts.strength === undefined ? 1 : clampN(Number(opts.strength), 0, 1);
  const adjustments = [], skipped = [], sectors = [];
  // Adjustment sectors are finer than the 30° stats sectors: 15° keeps a
  // yellow-green fix off the yellows next door. Mass guards use the 5° bins.
  const span = clampN(Number(opts.sector_deg) || 15, 10, 60), binDeg = 360 / HUE_BINS;
  const nSec = Math.round(360 / span);
  const width = span;
  if (!refJoint.hue_hist || !tgtJoint.hue_hist) return { hue_adjustments: [], sectors, skipped, error: "no hue histograms" };
  const RH = smoothHue(refJoint.hue_hist), TH = smoothHue(tgtJoint.hue_hist);
  const minBin = opts.min_bin_pct === undefined ? 0.2 : Number(opts.min_bin_pct);   // % of coloured pixels per 5° bin
  const satGain = opts.sat_gain !== false;
  // Same scene? Bhattacharyya overlap of the two hue histograms; different
  // subjects make a hue-to-hue mapping meaningless.
  let overlap = 0;
  for (let i = 0; i < HUE_BINS; i++) overlap += Math.sqrt(RH[i] * TH[i]);
  const minSim = opts.min_similarity === undefined ? 0.6 : Number(opts.min_similarity);
  if (overlap < minSim)
    return { hue_adjustments: [], sectors, skipped, similarity: +overlap.toFixed(3),
      refused: "Hue content differs too much between the frames (overlap " + overlap.toFixed(2)
        + " < " + minSim + "): these are different subjects, a hue-to-hue map would be fiction." };
  // Where did each hue go? Match the two chroma-weighted hue CDFs, cutting
  // the circle at the emptiest bin, so a patch that crossed a sector
  // boundary is still paired with itself instead of with its neighbour.
  let cut = 0, least = Infinity;
  for (let i = 0; i < HUE_BINS; i++) { const m = RH[i] + TH[i]; if (m < least) { least = m; cut = i; } }
  // start[k] = mass before the k-th bin counted from the cut; mass[k] = that bin's.
  const cum = (H) => { const start = [], mass = []; let c = 0; for (let k = 0; k < HUE_BINS; k++) { const m = H[(cut + k) % HUE_BINS]; start.push(c); mass.push(m); c += m; } return { start: start.map((v) => v / (c || 1)), mass: mass.map((v) => v / (c || 1)) }; };
  const FR = cum(RH), FT = cum(TH);
  const mapHue = (h) => {                        // target hue -> reference hue
    const pos = ((h / binDeg - cut) % HUE_BINS + HUE_BINS) % HUE_BINS;
    const k = Math.floor(pos), fr = pos - k;
    const c = FT.start[k] + fr * FT.mass[k];
    let j = 0;
    while (j < HUE_BINS - 1 && FR.start[j] + FR.mass[j] < c) j++;
    while (j < HUE_BINS - 1 && FR.mass[j] <= 0) j++;
    const within = FR.mass[j] > 1e-12 ? clampN((c - FR.start[j]) / FR.mass[j], 0, 1) : 0.5;
    return (((cut + j + within) * binDeg) % 360 + 360) % 360;
  };
  // The LUT works in DI-log, where saturation and value are not what the
  // display-referred grab shows: judge sector colours in that space.
  const diHsv = diHsvPct;
  // Reference colour (DI-space HSV) at a hue, from the 5° bin means.
  const refBinHsv = (h) => {
    const k0 = Math.floor((((h / binDeg) % HUE_BINS) + HUE_BINS) % HUE_BINS);
    for (const k of [k0, (k0 + 1) % HUE_BINS, (k0 + HUE_BINS - 1) % HUE_BINS]) {
      const rgb = refJoint.hue_bins_rgb_pct && refJoint.hue_bins_rgb_pct[k];
      if (rgb && refJoint.hue_hist[k] * 100 >= minBin) return diHsv(rgb);
    }
    return null;
  };
  // Mass of a frame's coloured pixels within ±span/2 of a hue (% of coloured).
  const massNear = (H, centre) => { let m = 0; for (let k = 0; k < HUE_BINS; k++) { const h = (k + 0.5) * binDeg, dist = Math.min(Math.abs(h - centre), 360 - Math.abs(h - centre)); if (dist <= span / 2) m += H[k]; } return 100 * m; };
  for (let i = 0; i < nSec; i++) {
    const centre = i * span;
    const tgtPct = +massNear(tgtJoint.hue_hist, centre).toFixed(2);
    // The reference is checked where these pixels are GOING (their mapped
    // hue), so a patch that left its sector still finds its twin.
    const refPct = +massNear(refJoint.hue_hist, tgtPct >= minPct ? mapHue(centre) : centre).toFixed(2);
    if (refPct < minPct || tgtPct < minPct) {
      if (refPct >= minPct || tgtPct >= minPct) skipped.push({ hue: centre, ref_pct_at_mapped_hue: refPct, target_pct: tgtPct });
      continue;
    }
    // Per 5° bin inside the sector: where its pixels went (CDF map), and the
    // reference colour there vs the target colour here. Mass-weighted; a
    // sector whose bins disagree on the shift gets a smaller one.
    let wsum = 0, ssum = 0, s2 = 0, satSum = 0, gainSum = 0, wsg = 0;
    for (let k = 0; k < HUE_BINS; k++) {
      const h = (k + 0.5) * binDeg, dist = Math.min(Math.abs(h - centre), 360 - Math.abs(h - centre));
      if (dist > span / 2 || tgtJoint.hue_hist[k] * 100 < minBin) continue;
      const w = TH[k] * (1 - dist / (span / 2 + 1e-9));
      const mapped = mapHue(h), dh = (((mapped - h) + 540) % 360) - 180;
      ssum += w * dh; s2 += w * dh * dh; wsum += w;
      const trgb = tgtJoint.hue_bins_rgb_pct && tgtJoint.hue_bins_rgb_pct[k];
      const rh = refBinHsv(mapped);
      if (satGain && trgb && rh) {
        const th = diHsv(trgb);
        satSum += w * Math.log(rh[1] / Math.max(0.005, th[1]));
        gainSum += w * (rh[2] / Math.max(0.01, th[2]) - 1); wsg += w;
      }
    }
    if (wsum <= 0) continue;
    const meanShift = ssum / wsum, sd = Math.sqrt(Math.max(0, s2 / wsum - meanShift * meanShift));
    const confidence = clampN(1 - sd / 10, 0, 1);
    let shift = clampN(meanShift, -25, 25) * strength * confidence;
    const sat = wsg > 0 ? clampN(Math.exp(satSum / wsg * strength), 0.7, 1.4) : 1;
    const gain = wsg > 0 ? clampN(gainSum / wsg * strength, -0.1, 0.1) : 0;
    const row = { hue: centre, ref_pct: refPct, target_pct: tgtPct, shift_spread_deg: +sd.toFixed(1),
      shift: +shift.toFixed(1), sat: +sat.toFixed(3), gain: +gain.toFixed(3) };
    sectors.push(row);
    if (Math.abs(shift) < 1.5 && Math.abs(sat - 1) < 0.03 && Math.abs(gain) < 0.02) continue;
    adjustments.push({ hue: centre, width, shift: row.shift, sat: row.sat, gain: row.gain });
  }
  return { hue_adjustments: adjustments, sectors, skipped, similarity: +overlap.toFixed(3) };
}

// The measure -> apply -> regrab loop shared by match_shot and
// match_timeline. Each round refits the ORIGINAL target to a goal shifted by
// the measured residual, so pipeline errors the DI-log model does not know
// about (the DRT) are absorbed. Converged = every channel's mean and median
// within TOLERANCE_PCT of the reference.
const TOLERANCE_PCT = 0.75;
async function runCdlLoop(ref, tgtItem, measure, opts) {
  const nodeIndex = opts.nodeIndex || 1;
  const maxIter = Math.min(5, Math.max(1, Number(opts.maxIterations) || 3));
  let tgt = opts.tgt0;
  const samples0 = tgt.samples;
  const base = tgt.stats.map((ch) => ch.pctl.slice());
  let goal = ref.stats.map((ch) => ch.pctl.slice());
  let sat = 1;
  const satOn = opts.saturation !== false && ref.joint && tgt.joint
    && tgt.joint.chroma_p90_pct > 1 && ref.joint.chroma_p90_pct > 1;
  const satErrOf = (t) => (satOn ? Math.abs(ref.joint.chroma_p90_pct - t.joint.chroma_p90_pct) / Math.max(1, ref.joint.chroma_p90_pct) : 0);
  let cdl = fitCdl(goal, base, { power: opts.power });
  // Refine on the grab's own pixels: the per-channel fit cannot see how
  // saturation mixes channels, the simulated node can.
  const refine = (init) => {
    if (!samples0 || !samples0.length) return init;
    const r = refineCdl(goal, satOn ? ref.joint.chroma_p90_pct : null, samples0,
      { slope: init.slope, offset: init.offset, power: init.power, sat }, { power: opts.power, saturation: satOn });
    sat = satOn ? r.sat : 1;
    return { slope: r.slope, offset: r.offset, power: r.power, refined: true, evals: r.evals };
  };
  cdl = refine(cdl);
  const iterations = [];
  let bestScore = Infinity, bestCdl = null, bestSat = 1, bestTgt = null;
  const write = () => tgtItem.SetCDL({
    NodeIndex: String(nodeIndex), Slope: cdlStr(cdl.slope),
    Offset: cdlStr(cdl.offset), Power: cdlStr(cdl.power || [1, 1, 1]),
    Saturation: (satOn ? sat : 1).toFixed(4) });
  for (let i = 1; i <= maxIter; i++) {
    if (!write())
      throw new ResolveError("SetCDL returned false on node " + nodeIndex
        + " of " + tgtItem.GetName() + " (iteration " + i + ").");
    tgt = await measure(tgtItem);
    const resid = ref.stats.map((rc, c) => +(rc.mean_pct - tgt.stats[c].mean_pct).toFixed(2));
    const p50 = ref.stats.map((rc, c) => +(rc.pctl[4] - tgt.stats[c].pctl[4]).toFixed(2));
    iterations.push({ iteration: i,
      cdl: { slope: cdlStr(cdl.slope), offset: cdlStr(cdl.offset),
             power: cdlStr(cdl.power || [1, 1, 1]), saturation: (satOn ? sat : 1).toFixed(4) },
      residual_mean_pct_rgb: resid, residual_median_pct_rgb: p50,
      residual_chroma_p90_pct: satOn ? +(ref.joint.chroma_p90_pct - tgt.joint.chroma_p90_pct).toFixed(2) : null });
    const worst = Math.max(...resid.map(Math.abs), ...p50.map(Math.abs));
    const score = worst + 25 * satErrOf(tgt);
    if (score < bestScore) { bestScore = score; bestCdl = cdl; bestSat = sat; bestTgt = tgt; }
    else {                                                         // regressed: restore the best round
      cdl = bestCdl; sat = bestSat; tgt = bestTgt;
      if (!write())
        throw new ResolveError("SetCDL returned false while restoring round " + (iterations.length - 1)
          + " on node " + nodeIndex + " of " + tgtItem.GetName() + " — the node may hold the worse round " + i + ".");
      iterations[iterations.length - 1].regressed = "worse than round " + (iterations.length - 1) + " — restored it";
      break;
    }
    if (worst < TOLERANCE_PCT && satErrOf(tgt) < 0.03) break;
    if (i === maxIter) break;
    goal = goal.map((row, c) => row.map((v, k) => v + (ref.stats[c].pctl[k] - tgt.stats[c].pctl[k])));
    cdl = refine(fitCdl(goal, base, { power: opts.power }));
  }
  const last = iterations[iterations.length - 1].regressed ? iterations[iterations.length - 2] : iterations[iterations.length - 1];
  return { iterations, final_cdl: last.cdl, final_residual_mean_pct_rgb: last.residual_mean_pct_rgb,
    converged: Math.max(...last.residual_mean_pct_rgb.map(Math.abs)) < TOLERANCE_PCT,
    final: tgt };
}

tool("match_shot",
  "Phase 4: match one clip's colour to a reference clip. Fits a FULL CDL "
  + "(slope, offset, power per channel + saturation) to the two frames' "
  + "percentile curves in the node's own working space (DaVinci "
  + "Intermediate log, estimated from display-referred grabs) and refines "
  + "it with a measure-apply-regrab loop. Global only: exposure, white "
  + "balance, contrast, saturation — a single hue or region that differs "
  + "needs match_hues on top. Writes ONE node of the target — "
  + "non-destructive, revert values included, every write logged to a "
  + "JSON sidecar. REFUSES to match shots in different exposure or "
  + "contrast regimes (night vs day) instead of faking it. WARNING: any "
  + "CDL already on that node is overwritten and cannot be read back "
  + "first (API has no grade readback) — point node_index at a spare "
  + "node. Clips are addressed by their 1-based position on the track.",
  { reference: { type: "number",
                 description: "1-based track position of the reference "
                              + "clip." },
    target: { type: "number",
              description: "1-based track position of the clip to match." },
    track: { type: "number", description: "Video track (default 1)." },
    node_index: { type: "number",
                  description: "Target node for the CDL (default 1). Use "
                               + "a spare node — existing CDL there is "
                               + "overwritten." },
    max_iterations: { type: "number",
                      description: "Measure-apply-regrab rounds (default "
                                   + "3)." },
    dry_run: { type: "boolean",
               description: "true = measure, gate, and propose the CDL "
                            + "without writing anything." },
    power: { type: "boolean",
             description: "Fit the power (contrast) term too (default "
                          + "true). false = slope/offset only." },
    saturation: { type: "boolean",
                  description: "Match saturation too (default true)." },
    out_dir: { type: "string",
               description: "Grab/log directory; default /tmp." } },
  ["reference", "target"], async (state, a) => {
    const tl = timeline(state);
    const track = Number(a.track) || 1;
    const items = tl.GetItemListInTrack("video", track) || [];
    const refItem = items[Number(a.reference) - 1];
    const tgtItem = items[Number(a.target) - 1];
    if (!refItem || !tgtItem)
      throw new ResolveError("Track " + track + " has " + items.length
        + " clips; reference/target must be 1-based positions on it.");
    if (refItem === tgtItem)
      throw new ResolveError("Reference and target are the same clip.");
    const tlFps = Number(tl.GetSetting("timelineFrameRate")) || 24;
    const nodeIndex = Number(a.node_index) || 1;
    const measure = (item) => measureItem(state, item, a);

    const ref = await measure(refItem);
    const tgt0 = await measure(tgtItem);
    const gate = matchGate(ref.stats, tgt0.stats);
    const out = { reference: refItem.GetName(), target: tgtItem.GetName(),
                  gate };
    if (ref.joint && tgt0.joint)
      out.skin = { reference: ref.joint.skin, target: tgt0.joint.skin };
    if (gate.refuse) {
      out.refused = true;
      out._images = [ref.proxy, tgt0.proxy].filter(Boolean);
      return out;                       // nothing written, and we say why
    }

    const first = fitCdl(ref.stats.map((c) => c.pctl), tgt0.stats.map((c) => c.pctl), { power: a.power });
    const satOn = a.saturation !== false && ref.joint && tgt0.joint && tgt0.joint.chroma_p90_pct > 1;
    out.proposed_cdl = { node: nodeIndex, slope: cdlStr(first.slope),
                         offset: cdlStr(first.offset), power: cdlStr(first.power),
                         saturation: (satOn ? clampN(ref.joint.chroma_p90_pct / Math.max(1, tgt0.joint.chroma_p90_pct), 0.5, 2) : 1).toFixed(4),
                         fit_rms_log: first.rms_di };
    if (a.dry_run) {
      out.dry_run = true;
      out._images = [ref.proxy, tgt0.proxy].filter(Boolean);
      return out;
    }

    const loop = await runCdlLoop(ref, tgtItem, measure, { tgt0, nodeIndex,
      maxIterations: a.max_iterations, power: a.power, saturation: a.saturation });
    const tgt = loop.final;
    out.iterations = loop.iterations;
    out.final_cdl = loop.final_cdl;
    out.final_residual_mean_pct_rgb = loop.final_residual_mean_pct_rgb;
    out.converged = loop.converged;
    if (!loop.converged)
      out.note = "Residual above " + TOLERANCE_PCT + "% after " + loop.iterations.length
        + " rounds — the shots differ in a way a global CDL cannot express "
        + "(a hue or region): try match_hues on top, or more max_iterations.";
    out.revert = { NodeIndex: String(nodeIndex), Slope: "1 1 1",
                   Offset: "0 0 0", Power: "1 1 1", Saturation: "1" };
    const logDir = String(a.out_dir || (process.platform === "win32"
                                        ? os.tmpdir() : "/tmp"));
    try {
      const logFile = path.join(logDir, "cdl_match_"
        + Date.now().toString(36) + ".json");
      fs.writeFileSync(logFile, JSON.stringify(out, null, 2));
      out.log_file = logFile;           // grades are write-only: this JSON
    } catch (e) {}                      // is the only readable record
    out._images = [ref.proxy, tgt.proxy].filter(Boolean);
    return out;
  });

tool("auto_balance",
  "Balance a clip with NO reference (Colourlab-style 'Balance'): white "
  + "balance from greyness-weighted grey-world + white-patch estimates and "
  + "exposure from the luma median, written as a slope-1 CDL (offsets in "
  + "DI-log = linear gains) on one node, refined by a measure-apply-regrab "
  + "loop. Refuses frames with too few near-neutral pixels. Says what it "
  + "changed in stops and gains. Overwrites any CDL on that node.",
  { clip: { type: "number", description: "1-based track position; default: clip under the playhead." },
    track: { type: "number", description: "Video track (default 1)." },
    node_index: { type: "number", description: "Node for the CDL (default 1; use a spare node)." },
    strength: { type: "number", description: "0-1, default 1 (full correction)." },
    exposure: { type: "boolean", description: "Also normalise exposure (default true)." },
    target_median_pct: { type: "number", description: "Force the luma median to this % of display. Default: leave exposure alone while the median is within 30-55%, else move it to the nearest edge of that band." },
    max_stops: { type: "number", description: "Exposure change cap in stops (default 1.5)." },
    max_iterations: { type: "number", description: "Measure-apply-regrab rounds (default 2)." },
    dry_run: { type: "boolean", description: "true = measure and propose only." },
    out_dir: { type: "string", description: "Grab/log directory; default /tmp." } },
  [], async (state, a) => {
    const tl = timeline(state);
    let item;
    if (a.clip !== undefined) {
      const items = tl.GetItemListInTrack("video", Number(a.track) || 1) || [];
      item = items[Number(a.clip) - 1];
      if (!item) throw new ResolveError("No clip at position " + a.clip + ".");
    } else {
      item = tl.GetCurrentVideoItem && tl.GetCurrentVideoItem();
      if (!item) throw new ResolveError("No clip under the playhead — park on one or pass clip/track.");
    }
    const nodeIndex = Number(a.node_index) || 1;
    const measure = (it) => measureItem(state, it, a);
    const before = await measure(item);
    const est = balanceEstimate({ channels: before.stats, joint: before.joint }, a);
    const out = { clip: item.GetName(), node: nodeIndex, estimate: est };
    if (est.refuse) { out.refused = true; out._images = [before.proxy].filter(Boolean); return out; }
    out.proposed_cdl = { slope: "1 1 1", offset: cdlStr(est.offset), power: "1 1 1", saturation: "1" };
    if (a.dry_run) { out.dry_run = true; out._images = [before.proxy].filter(Boolean); return out; }
    const maxIter = Math.min(4, Math.max(1, Number(a.max_iterations) || 2));
    let offset = est.offset.slice();
    const rounds = [];
    for (let i = 1; i <= maxIter; i++) {
      if (!item.SetCDL({ NodeIndex: String(nodeIndex), Slope: "1 1 1", Offset: cdlStr(offset), Power: "1 1 1", Saturation: "1" }))
        throw new ResolveError("SetCDL returned false on node " + nodeIndex + " of " + item.GetName() + ".");
      const now = await measure(item);
      const nm = now.joint.neutral_mean_pct || [0, 0, 0];
      const cast = { r_minus_g_pct: +(nm[0] - nm[1]).toFixed(2), b_minus_g_pct: +(nm[2] - nm[1]).toFixed(2) };
      rounds.push({ iteration: i, offset: cdlStr(offset), cast_after: cast, luma_median_pct: now.joint.luma.median_pct });
      if (Math.abs(cast.r_minus_g_pct) < 0.5 && Math.abs(cast.b_minus_g_pct) < 0.5) break;
      if (i === maxIter) break;
      const corr = balanceEstimate({ channels: now.stats, joint: now.joint }, Object.assign({}, a, { exposure: false }));
      if (corr.refuse) break;
      offset = offset.map((o, c) => o + corr.offset[c]);
    }
    out.iterations = rounds;
    out.final_cdl = { slope: "1 1 1", offset: cdlStr(offset), power: "1 1 1", saturation: "1" };
    out.cast_before = est.cast_before;
    out.cast_after = rounds[rounds.length - 1].cast_after;
    out.exposure_change_stops = est.exposure_stops;
    out.revert = { NodeIndex: String(nodeIndex), Slope: "1 1 1", Offset: "0 0 0", Power: "1 1 1", Saturation: "1" };
    out._images = [before.proxy].filter(Boolean);
    return out;
  });

tool("match_timeline",
  "Match every clip on a track to one hero shot (Colourlab-style timeline "
  + "match): measures all clips, picks the hero (given, or 'auto' = the "
  + "most central clip so the total change is smallest), gates each pair "
  + "(night-vs-day refused, named), then runs the match_shot loop on each. "
  + "One approval, one log. Slow: (1 + rounds) grabs per clip, ~3 s each — "
  + "use clips/max_clips to batch. Overwrites the CDL on node_index of "
  + "every matched clip; revert values are returned per clip.",
  { track: { type: "number", description: "Video track (default 1)." },
    hero: { type: "number", description: "1-based position of the reference clip; omit = auto." },
    clips: { type: "array", items: { type: "number" }, description: "Positions to match (default: all others)." },
    max_clips: { type: "number", description: "Cap when clips is omitted (default 12)." },
    node_index: { type: "number", description: "Node for each CDL (default 1; use a spare node)." },
    max_iterations: { type: "number", description: "Rounds per clip (default 2)." },
    power: { type: "boolean" }, saturation: { type: "boolean" },
    dry_run: { type: "boolean", description: "true = measure, pick hero, gate and propose only." },
    out_dir: { type: "string", description: "Grab/log directory; default /tmp." } },
  [], async (state, a) => {
    const tl = timeline(state);
    const track = Number(a.track) || 1;
    const items = tl.GetItemListInTrack("video", track) || [];
    if (items.length < 2) throw new ResolveError("Track " + track + " has " + items.length + " clip(s); nothing to match.");
    const nodeIndex = Number(a.node_index) || 1;
    const measure = (it) => measureItem(state, it, a, { no_proxy: true });
    let wanted = Array.isArray(a.clips) && a.clips.length ? a.clips.map(Number) : null;
    const heroPos = a.hero !== undefined ? Number(a.hero) : null;
    if (heroPos !== null && !items[heroPos - 1]) throw new ResolveError("No clip at hero position " + heroPos + ".");
    const cap = Math.max(1, Number(a.max_clips) || 12);
    const positions = wanted ? wanted.filter((p) => items[p - 1]) : items.map((_, i) => i + 1).slice(0, cap + (heroPos ? 1 : 0));
    const pool = Array.from(new Set(positions.concat(heroPos ? [heroPos] : [])));
    const measured = {};
    const errors = [];
    for (const p of pool) {
      try { measured[p] = await measure(items[p - 1]); }
      catch (e) { errors.push({ clip: p, name: items[p - 1].GetName(), error: e.message }); }
    }
    const ok = pool.filter((p) => measured[p]);
    if (heroPos !== null && !measured[heroPos])
      throw new ResolveError("The hero clip (" + items[heroPos - 1].GetName() + ", position " + heroPos + ") could not be measured: "
        + ((errors.find((e) => e.clip === heroPos) || {}).error || "no grab") + " — pick another hero.");
    if (ok.length < 2) throw new ResolveError("Could not measure enough clips: " + JSON.stringify(errors));
    // Hero = medoid over (mean, std) per channel: the clip closest to all others.
    const dist = (x, y) => x.stats.reduce((t, ch, c) => t + Math.abs(ch.mean_pct - y.stats[c].mean_pct) + 0.5 * Math.abs(ch.std_pct - y.stats[c].std_pct), 0);
    let hero = heroPos;
    if (hero === null) {
      let best = null;
      for (const p of ok) {
        const d = ok.reduce((t, q) => t + (q === p ? 0 : dist(measured[p], measured[q])), 0);
        if (!best || d < best.d) best = { p, d };
      }
      hero = best.p;
    }
    const ref = measured[hero];
    const out = { track, hero: { position: hero, name: items[hero - 1].GetName(), chosen: heroPos ? "given" : "auto (medoid)" },
                  results: [], errors, node: nodeIndex };
    for (const p of ok) {
      if (p === hero) continue;
      const item = items[p - 1];
      const row = { position: p, name: item.GetName() };
      try {
        const tgt0 = measured[p];
        row.gate = matchGate(ref.stats, tgt0.stats);
        if (row.gate.refuse) { row.refused = true; out.results.push(row); continue; }
        const first = fitCdl(ref.stats.map((c) => c.pctl), tgt0.stats.map((c) => c.pctl), { power: a.power });
        row.proposed_cdl = { slope: cdlStr(first.slope), offset: cdlStr(first.offset), power: cdlStr(first.power) };
        if (a.dry_run) { out.results.push(row); continue; }
        const loop = await runCdlLoop(ref, item, measure, { tgt0, nodeIndex, maxIterations: Number(a.max_iterations) || 2,
          power: a.power, saturation: a.saturation });
        row.final_cdl = loop.final_cdl;
        row.final_residual_mean_pct_rgb = loop.final_residual_mean_pct_rgb;
        row.converged = loop.converged;
        row.rounds = loop.iterations.length;
      } catch (e) { row.error = e.message; }
      out.results.push(row);
    }
    out.matched = out.results.filter((r) => r.final_cdl).length;
    out.refused = out.results.filter((r) => r.refused).map((r) => ({ position: r.position, name: r.name, reason: r.gate.reason }));
    if (!a.dry_run) out.revert_each = { NodeIndex: String(nodeIndex), Slope: "1 1 1", Offset: "0 0 0", Power: "1 1 1", Saturation: "1" };
    if (a.dry_run) out.dry_run = true;
    const logDir = String(a.out_dir || (process.platform === "win32" ? os.tmpdir() : "/tmp"));
    try {
      const logFile = path.join(logDir, "timeline_match_" + Date.now().toString(36) + ".json");
      fs.writeFileSync(logFile, JSON.stringify(out, null, 2));
      out.log_file = logFile;
    } catch (e) {}
    return out;
  });

// ------------------------------------------------------ Phase 5: look designer
// A 3D LUT is a colour->colour map, which buys back part of two API walls:
// hue-selective "secondaries" (a qualifier's colour selection, without the
// UI) and full creative tone shaping. It has NO spatial awareness — windows
// and tracking stay walls (the vignette tool below handles the static
// spatial case via Fusion). The LUT applies on a Color-page node, so its
// input domain is the timeline working space (DaVinci Intermediate log
// under this project's RCM); all look math is done in that log domain.
function diDecode(y) {
  return y <= DI.CUT * DI.M ? y / DI.M
                            : Math.pow(2, y / DI.C - DI.B) - DI.A;
}
function rgbToHsv(r, g, b) {
  const mx = Math.max(r, g, b), mn = Math.min(r, g, b), d = mx - mn;
  let h = 0;
  if (d > 1e-9) {
    if (mx === r) h = ((g - b) / d) % 6;
    else if (mx === g) h = (b - r) / d + 2;
    else h = (r - g) / d + 4;
    h *= 60; if (h < 0) h += 360;
  }
  return [h, mx > 1e-9 ? d / mx : 0, mx];
}
function hsvToRgb(h, sv, v) {
  const c = v * sv, x = c * (1 - Math.abs(((h / 60) % 2) - 1)), m = v - c;
  const k = h < 60 ? [c, x, 0] : h < 120 ? [x, c, 0] : h < 180 ? [0, c, x]
          : h < 240 ? [0, x, c] : h < 300 ? [x, 0, c] : [c, 0, x];
  return [k[0] + m, k[1] + m, k[2] + m];
}
// Display-referred % RGB -> HSV of the same colour in DI-log (the LUT's space).
const diHsvPct = (rgbPct) => rgbToHsv(...rgbPct.map((v) => diEncode(Math.pow(Math.max(0, v) / 100, 2.4))));
const DI_STOP = 0.0733;                  // 1 stop in DI-log units (= DI.C)
const DI_MID = 0.336;                    // 18% grey, DI-encoded

// applyLook: one lattice point through the recipe. Every field optional;
// all defaults are the identity, so an empty look is a no-op LUT.
function applyLook(rgb, L) {
  let [r, g, b] = rgb;
  const off = (Number(L.exposure) || 0) * DI_STOP;
  r += off; g += off; b += off;
  const warm = (Number(L.warmth) || 0) * 0.02;
  const tint = (Number(L.tint) || 0) * 0.02;
  r += warm; b -= warm; g += tint;
  const pivot = Number(L.pivot) || DI_MID;
  const con = L.contrast === undefined ? 1 : Number(L.contrast);
  r = pivot + (r - pivot) * con;
  g = pivot + (g - pivot) * con;
  b = pivot + (b - pivot) * con;
  let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  const sat = L.saturation === undefined ? 1 : Number(L.saturation);
  r = luma + (r - luma) * sat;
  g = luma + (g - luma) * sat;
  b = luma + (b - luma) * sat;
  const splits = [
    { hue: L.split_shadow_hue, str: L.split_shadow_strength,
      w: Math.max(0, Math.min(1, (0.35 - luma) / 0.35)) },
    { hue: L.split_highlight_hue, str: L.split_highlight_strength,
      w: Math.max(0, Math.min(1, (luma - 0.5) / 0.4)) },
  ];
  for (const sp of splits) {
    const strength = Number(sp.str) || 0;
    if (!strength || sp.hue === undefined) continue;
    const tone = hsvToRgb(((Number(sp.hue) % 360) + 360) % 360, 1, 1);
    const k = strength * 0.05 * sp.w;
    r += (tone[0] - 0.5) * k; g += (tone[1] - 0.5) * k;
    b += (tone[2] - 0.5) * k;
  }
  for (const adj of L.hue_adjustments || []) {
    const centre = ((Number(adj.hue) % 360) + 360) % 360;
    const width = Number(adj.width) || 30;
    const hsv = rgbToHsv(Math.max(0, r), Math.max(0, g), Math.max(0, b));
    let dist = Math.abs(hsv[0] - centre);
    if (dist > 180) dist = 360 - dist;
    const w = Math.max(0, 1 - dist / width) * Math.min(1, hsv[1] * 4);
    if (w <= 0) continue;
    const h2 = hsv[0] + (Number(adj.shift) || 0) * w;
    const s2 = hsv[1] * (1 + ((adj.sat === undefined ? 1 : Number(adj.sat))
                              - 1) * w);
    const v2 = hsv[2] * (1 + (Number(adj.gain) || 0) * w);
    const outc = hsvToRgb(((h2 % 360) + 360) % 360,
                          Math.max(0, Math.min(1, s2)), Math.max(0, v2));
    r = outc[0]; g = outc[1]; b = outc[2];
  }
  const matte = (Number(L.matte_blacks) || 0) * 0.1;
  if (matte) { r = matte + r * (1 - matte); g = matte + g * (1 - matte);
               b = matte + b * (1 - matte); }
  const roll = Number(L.highlight_rolloff) || 0;
  if (roll) {
    const knee = 0.75, soft = (v) => v <= knee ? v
      : knee + (v - knee) / (1 + roll * 2 * (v - knee));
    r = soft(r); g = soft(g); b = soft(b);
  }
  const clamp = (v) => Math.max(0, Math.min(1, v));
  return [clamp(r), clamp(g), clamp(b)];
}

function generateCube(look, size) {
  const n = Math.max(9, Math.min(65, Number(size) || 33));
  const lines = ["# Generated by Claude Assistant look designer",
                 "LUT_3D_SIZE " + n];
  for (let bi = 0; bi < n; bi++)
    for (let gi = 0; gi < n; gi++)
      for (let ri = 0; ri < n; ri++) {
        const outv = applyLook([ri / (n - 1), gi / (n - 1), bi / (n - 1)],
                               look || {});
        lines.push(outv.map((v) => v.toFixed(6)).join(" "));
      }
  return lines.join("\n") + "\n";
}

tool("design_look",
  "Generate a creative 3D LUT (.cube) from a parametric recipe and apply "
  + "it to a clip's node — the scriptable route to cinematic looks, incl. "
  + "hue-selective secondaries (colour-based qualification; a LUT has no "
  + "spatial awareness, so windows/tracking remain manual). Recipe fields "
  + "(all optional, defaults = identity): exposure (stops), contrast + "
  + "pivot, warmth/tint (+-1 subtle), saturation, split_shadow_hue/"
  + "strength, split_highlight_hue/strength (hue 0-360), matte_blacks "
  + "(0-1), highlight_rolloff (0-1), hue_adjustments: [{hue, width, sat, "
  + "shift, gain}]. The LUT lives in the node's working space (DaVinci "
  + "Intermediate log here). Iterate by LOOKING: apply, grab_still, "
  + "judge, re-apply with tweaked numbers. Revert: set_lut with an empty "
  + "path (also returned). Overwrites any LUT already on that node.",
  { look: { type: "object", description: "The recipe (see description)." },
    name: { type: "string",
            description: "Look name for the .cube file (default "
                         + "'claude-look')." },
    clip: { type: "number",
            description: "1-based track position; default: clip under the "
                         + "playhead." },
    track: { type: "number", description: "Video track (default 1)." },
    node_index: { type: "number",
                  description: "Node for the LUT (default 1)." },
    size: { type: "number", description: "LUT lattice size (default 33)." },
    out_dir: { type: "string",
               description: "Where to write the .cube (default "
                            + "~/ClaudeAssistantLooks)." } },
  [], async (state, a) => {
    const tl = timeline(state);
    let item;
    if (a.clip !== undefined) {
      const items = tl.GetItemListInTrack("video", Number(a.track) || 1)
                    || [];
      item = items[Number(a.clip) - 1];
      if (!item)
        throw new ResolveError("No clip at position " + a.clip + ".");
    } else {
      item = tl.GetCurrentVideoItem && tl.GetCurrentVideoItem();
      if (!item)
        throw new ResolveError("No clip under the playhead — park on one "
                               + "or pass clip/track.");
    }
    const dir = String(a.out_dir
      || path.join(os.homedir(), "ClaudeAssistantLooks"));
    fs.mkdirSync(dir, { recursive: true });
    const base = String(a.name || "claude-look")
      .replace(/[^\w.-]+/g, "_").slice(0, 60);
    const file = path.join(dir, base + "_" + Date.now().toString(36)
                           + ".cube");
    fs.writeFileSync(file, generateCube(a.look, a.size));
    const nodeIndex = Number(a.node_index) || 1;
    if (typeof item.SetLUT !== "function")
      throw new ResolveError("This Resolve exposes no SetLUT on timeline "
        + "items — the .cube was written to " + file
        + " for manual use, but scripted application is unavailable.");
    const applied = item.SetLUT(nodeIndex, file);
    const readback = typeof item.GetLUT === "function"
      ? item.GetLUT(nodeIndex) : null;
    const out = { clip: item.GetName(), node: nodeIndex, lut_file: file,
                  applied: !!applied, look: a.look || {} };
    if (applied) {
      out.verified = readback
        ? path.basename(String(readback)) === path.basename(file)
        : "no GetLUT readback in this Resolve";
      out.revert = "set_lut node " + nodeIndex + " with empty path, or "
                   + "clear the node LUT in the UI";
    } else {
      // Live-verified on the Mac install: SetLUT resolves NO path at all
      // (not even Blackmagic-shipped LUTs), so the .cube file itself is
      // the deliverable. Never fail the call over a broken applicator.
      out.manual_load = "SetLUT cannot resolve paths on this install "
        + "(live-verified, all path forms). Load it by hand: copy "
        + file + " into /Library/Application Support/Blackmagic Design/"
        + "DaVinci Resolve/LUT/, update the LUT list in Project Settings, "
        + "then right-click the node > LUT. The file is valid and ready.";
    }
    return out;
  });

tool("match_hues",
  "Hue-selective match (the part of Colourlab's Region Match a LUT can do): "
  + "compares the two frames per 30° hue sector — mean hue, saturation, "
  + "brightness — and writes the per-sector corrections as a .cube through "
  + "the look designer (hue_adjustments), then tries SetLUT on the target "
  + "node. Run match_shot FIRST so only the hue-specific residue is left. "
  + "Colour-based only: no spatial windows, no tracking. On installs where "
  + "SetLUT is dead the .cube is the deliverable with manual-load steps, "
  + "and the recipe is returned so design_look can tweak it.",
  { reference: { type: "number", description: "1-based track position of the reference clip." },
    target: { type: "number", description: "1-based track position of the clip to fix." },
    track: { type: "number", description: "Video track (default 1)." },
    node_index: { type: "number", description: "Node for the LUT (default 2, after the match CDL)." },
    strength: { type: "number", description: "0-1, default 1." },
    min_sector_pct: { type: "number", description: "Skip hue sectors thinner than this % of coloured pixels in either frame (default 1)." },
    max_global_gap_pct: { type: "number", description: "Refuse when the clips' overall level/balance still differ by more than this % (default 3) — match_shot first." },
    name: { type: "string" }, size: { type: "number" },
    dry_run: { type: "boolean", description: "true = measure and return the recipe only." },
    out_dir: { type: "string", description: "Where to write the .cube (default ~/ClaudeAssistantLooks)." } },
  ["reference", "target"], async (state, a) => {
    const tl = timeline(state);
    const items = tl.GetItemListInTrack("video", Number(a.track) || 1) || [];
    const refItem = items[Number(a.reference) - 1], tgtItem = items[Number(a.target) - 1];
    if (!refItem || !tgtItem) throw new ResolveError("Track has " + items.length + " clips; reference/target must be 1-based positions on it.");
    if (refItem === tgtItem) throw new ResolveError("Reference and target are the same clip.");
    // a.out_dir is where the .cube goes; grabs take the default still dir.
    const measure = (it) => measureItem(state, it, {});
    const ref = await measure(refItem), tgt = await measure(tgtItem);
    const out = { reference: refItem.GetName(), target: tgtItem.GetName(),
      skin: { reference: ref.joint.skin, target: tgt.joint.skin } };
    // A hue pass sits on top of a global match: with the overall levels still
    // apart, a hue-to-hue map corrects the wrong thing.
    const globalGap = Math.max(...ref.stats.map((c, i) => Math.max(Math.abs(c.mean_pct - tgt.stats[i].mean_pct), Math.abs(c.pctl[4] - tgt.stats[i].pctl[4]))));
    out.global_gap_pct = +globalGap.toFixed(2);
    const gapLimit = Number(a.max_global_gap_pct) || 3;
    if (globalGap > gapLimit) {
      out.refused = "The clips are still " + globalGap.toFixed(1) + "% apart in overall level/balance (limit " + gapLimit + "%): run match_shot first, then match_hues for what is left.";
      out._images = [ref.proxy, tgt.proxy].filter(Boolean);
      return out;
    }
    const recipe = hueMatchRecipe(ref.joint, tgt.joint, a);
    out.similarity = recipe.similarity; out.sectors = recipe.sectors; out.skipped_sectors = recipe.skipped;
    if (recipe.refused) { out.refused = recipe.refused; out._images = [ref.proxy, tgt.proxy].filter(Boolean); return out; }
    // Never trust the recipe blind: keep only what moves the target's hue
    // content toward the reference when simulated on its own pixels.
    const verified = refineHueRecipe(ref.joint, tgt.samples, recipe.hue_adjustments, {});
    out.verified_by_simulation = { cost_before: verified.cost_before, cost_after: verified.cost_after,
      proposed: recipe.hue_adjustments.length, kept: verified.hue_adjustments.length, rejected: verified.rejected };
    out.look = { hue_adjustments: verified.hue_adjustments };
    if (!verified.hue_adjustments.length) {
      out.nothing_to_do = recipe.hue_adjustments.length
        ? "The measured hue differences do not survive simulation on this frame — nothing a hue LUT would improve; a global match_shot covers this pair."
        : "No hue sector differs beyond 1.5° / 3% between the frames — a global match_shot covers this pair.";
      out._images = [ref.proxy, tgt.proxy].filter(Boolean);
      return out;
    }
    if (a.dry_run) { out.dry_run = true; out._images = [ref.proxy, tgt.proxy].filter(Boolean); return out; }
    const dir = String(a.out_dir || path.join(os.homedir(), "ClaudeAssistantLooks"));
    fs.mkdirSync(dir, { recursive: true });
    const base = String(a.name || ("hue-match-" + tgtItem.GetName())).replace(/[^\w.-]+/g, "_").slice(0, 60);
    const file = path.join(dir, base + "_" + Date.now().toString(36) + ".cube");
    fs.writeFileSync(file, generateCube(out.look, a.size));
    out.lut_file = file;
    const nodeIndex = Number(a.node_index) || 2;
    out.node = nodeIndex;
    const applied = typeof tgtItem.SetLUT === "function" ? !!tgtItem.SetLUT(nodeIndex, file) : false;
    out.applied = applied;
    if (applied) out.verify = "grab_still the target and compare with the reference; iterate with design_look on the returned recipe.";
    else out.manual_load = "SetLUT cannot resolve paths on this install (live-verified) — manual load: copy " + file
      + " into /Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT/, update the LUT list in Project Settings, "
      + "then right-click node " + nodeIndex + " of " + tgtItem.GetName() + " > LUT. Then grab_still to verify.";
    out._images = [ref.proxy, tgt.proxy].filter(Boolean);
    return out;
  });

tool("apply_vignette",
  "LIVE-VERIFIED: a static power-window-style vignette via the clip's "
  + "Fusion comp, driven as Lua through comp.Execute() (the JS proxy's "
  + "tool handles are hollow; Execute inside Fusion works — confirmed by "
  + "a 57%-of-samples corner-darkening pixel diff). Execute's RETURN "
  + "value cannot marshal back across the bridge, so success is judged "
  + "by FindTool + pixels, never the return. No tracking — the mask is "
  + "static. action 'remove' deletes the named tools the same way.",
  { amount: { type: "number",
              description: "Darkening outside the ellipse, 0-1 (default "
                           + "0.35)." },
    softness: { type: "number", description: "Edge softness 0-1 (default "
                                             + "0.4)." },
    size: { type: "number",
            description: "Ellipse size vs frame, 0-1 (default 0.85)." },
    action: { type: "string", enum: ["add", "remove"],
              description: "Default add." },
    clip: { type: "number",
            description: "1-based track position; default: clip under "
                         + "the playhead." },
    track: { type: "number", description: "Video track (default 1)." } },
  [], async (state, a) => {
    const tl = timeline(state);
    let item;
    if (a.clip !== undefined) {
      const items = tl.GetItemListInTrack("video", Number(a.track) || 1)
                    || [];
      item = items[Number(a.clip) - 1];
    } else item = tl.GetCurrentVideoItem && tl.GetCurrentVideoItem();
    if (!item) throw new ResolveError("No clip found for the vignette.");
    if (typeof item.GetFusionCompByIndex !== "function")
      throw new ResolveError("This timeline item exposes no Fusion comp "
                             + "API — vignette unavailable here.");
    let comp = item.GetFusionCompByIndex(1);
    let createdComp = false;
    if (!comp && a.action !== "remove"
        && typeof item.AddFusionComp === "function") {
      comp = item.AddFusionComp();
      createdComp = true;               // NOTE: script deletion of comps
    }                                   // returns false (live-verified)
    if (!comp)
      throw new ResolveError("No Fusion comp on " + item.GetName()
                             + (a.action === "remove"
                                ? " — nothing to remove." : "."));
    if (typeof comp.Execute !== "function")
      throw new ResolveError("comp.Execute is not exposed here — with "
        + "hollow tool handles (live-verified) there is no scriptable "
        + "route left to configure Fusion tools. The vignette must be "
        + "built by hand (Fusion EllipseMask, or a Color page power "
        + "window).");
    // Execute's return value fails to marshal ("Unknown object type for
    // key:result") even when the Lua ran fine — live-verified. Swallow
    // that; the FindTool check below is the real verdict.
    const runLua = (lua) => { try { comp.Execute(lua); } catch (e) {} };
    if (a.action === "remove") {
      runLua(
        'for _, nm in ipairs({"ClaudeVignetteMask", "ClaudeVignetteBC"}) '
        + 'do local t = comp:FindTool(nm); if t then t:Delete() end end');
      const still = comp.FindTool && (comp.FindTool("ClaudeVignetteBC")
                                      || comp.FindTool("ClaudeVignetteMask"));
      return { clip: item.GetName(),
               removed: !still,
               note: still ? "Execute ran but the tools are still "
                             + "present — remove them by hand in Fusion."
                           : "Vignette tools deleted (or none existed)." };
    }
    const amount = Math.max(0, Math.min(1, Number(a.amount) || 0.35));
    const soft = Math.max(0, Math.min(1, Number(a.softness) || 0.4));
    const sizeV = Math.max(0.1, Math.min(1.5, Number(a.size) || 0.85));
    const lua = [
      "comp:Lock()",
      'local m = comp:AddTool("EllipseMask", -32768, -32768)',
      'local b = comp:AddTool("BrightnessContrast", -32768, -32768)',
      'm:SetAttrs({TOOLS_Name = "ClaudeVignetteMask"})',
      'b:SetAttrs({TOOLS_Name = "ClaudeVignetteBC"})',
      "m.Width = " + sizeV.toFixed(4),
      "m.Height = " + (sizeV * 0.75).toFixed(4),
      "m.SoftEdge = " + (soft * 0.25).toFixed(4),
      "m.Invert = 1",
      "b.Gain = " + (1 - amount).toFixed(4),
      'local mi = comp:FindTool("MediaIn1")',
      'local mo = comp:FindTool("MediaOut1")',
      "if mi and mo then",
      "  b.Input = mi.Output",
      "  b.EffectMask = m.Mask",
      "  mo.Input = b.Output",
      "end",
      "comp:Unlock()",
    ].join("\n");
    runLua(lua);
    const present = comp.FindTool
      && !!comp.FindTool("ClaudeVignetteBC");
    return { clip: item.GetName(), amount, softness: soft, size: sizeV,
             created_comp: createdComp || undefined,
             tools_present_after_execute: present,
             verification: "FindTool existence only — grab a still and "
               + "LOOK to confirm the darkening actually renders; if the "
               + "frame is unchanged, the wiring silently failed and "
               + "this wall stands.",
             revert: "apply_vignette with action 'remove'" };
  });

// --------------------------------------------------- node graph templates
// The API cannot create/delete/rearrange Color-page nodes directly — but a
// .drx (which every gallery still export writes) carries the ENTIRE node
// graph, and Timeline.ApplyGradeFromDRX stamps it onto clips. So node
// structure becomes scriptable the honest way: build a layout by hand
// ONCE, save it as a named template, stamp any clip ever after. Stamping
// REPLACES the target's whole grade — structure setup, not in-place edits.
const TEMPLATE_DIR = path.join(os.homedir(), "ClaudeNodeTemplates");

tool("grade_template",
  "Save, list, and apply Color-page NODE GRAPH templates via .drx — the "
  + "one scriptable route to node creation/rearrangement. 'save' captures "
  + "the CURRENT clip's full grade + node layout under a name (build the "
  + "layout by hand first, e.g. 4 empty serial nodes). 'apply' stamps a "
  + "saved template onto a clip — WARNING: this REPLACES that clip's "
  + "entire grade and node graph, which is the mechanism, not a bug. "
  + "'list' shows saved templates. Templates live in ~/ClaudeNodeTemplates.",
  { action: { type: "string", enum: ["save", "apply", "list", "inspect"],
              description: "What to do. 'inspect' reports a saved "
                + "template's file format (magic bytes, compression) and "
                + "searches it for given strings in utf8/utf16 — the "
                + "recon step toward programmatic label rewriting." },
    search: { type: "array", items: { type: "string" },
              description: "inspect: strings to hunt for (e.g. the "
                           + "hand-typed node labels)." },
    name: { type: "string",
            description: "Template name (save/apply)." },
    clip: { type: "number",
            description: "apply: 1-based track position; default: clip "
                         + "under the playhead." },
    track: { type: "number", description: "Video track (default 1)." } },
  ["action"], async (state, a) => {
    fs.mkdirSync(TEMPLATE_DIR, { recursive: true });
    const safe = (n) => String(n || "").replace(/[^\w.-]+/g, "_")
      .slice(0, 60);
    if (a.action === "list") {
      const rows = fs.readdirSync(TEMPLATE_DIR)
        .filter((n) => n.toLowerCase().endsWith(".drx"))
        .map((n) => ({ name: n.replace(/\.drx$/i, ""),
                       saved: fs.statSync(path.join(TEMPLATE_DIR, n))
                                .mtime.toISOString() }));
      return { templates: rows, dir: TEMPLATE_DIR,
               note: rows.length ? undefined
                 : "None yet — park on a clip whose node layout you want "
                   + "to reuse and run action 'save'." };
    }
    if (!a.name) throw new ResolveError("'" + a.action
                                        + "' needs a template name.");
    const file = path.join(TEMPLATE_DIR, safe(a.name) + ".drx");
    if (a.action === "inspect") {
      if (!fs.existsSync(file))
        throw new ResolveError("No template named '" + safe(a.name)
                               + "'.");
      const raw = fs.readFileSync(file);
      const zlib = require("zlib");
      const out = { file, bytes: raw.length,
                    magic: raw.slice(0, 4).toString("hex") };
      let bodies = [{ layer: "raw", buf: raw }];
      // .drx internals are undocumented — detect the common wrappers.
      try {
        if (raw[0] === 0x1f && raw[1] === 0x8b)
          bodies.push({ layer: "gunzipped",
                        buf: zlib.gunzipSync(raw) });
        else if (raw[0] === 0x78)
          bodies.push({ layer: "inflated", buf: zlib.inflateSync(raw) });
        else if (raw.slice(0, 2).toString() === "PK")
          out.container = "zip — needs an unzip step before patching";
      } catch (e) { out.decompress_error = e.message; }
      out.compressed = bodies.length > 1 ? bodies[1].layer : "none detected";
      // DaVinci XML often wraps its real payload as base64 (frequently
      // zlib-compressed) inside the envelope — live case: labels round-trip
      // through the file (+68 bytes) yet match nothing on the surface.
      // Hunt embedded blobs and search inside them too.
      const text = raw.toString("latin1");
      const b64re = /[A-Za-z0-9+\/]{200,}={0,2}/g;
      let run, blobs = 0;
      out.base64_blobs = [];
      while ((run = b64re.exec(text)) && blobs < 20) {
        blobs += 1;
        let decoded = null;
        try { decoded = Buffer.from(run[0], "base64"); } catch (e) {}
        if (!decoded || !decoded.length) continue;
        const tag = "base64@" + run.index;
        const blob = { at: run.index, b64_chars: run[0].length,
                       decoded_bytes: decoded.length,
                       decoded_magic: decoded.slice(0, 2).toString("hex") };
        bodies.push({ layer: tag, buf: decoded });
        try {
          const zlib2 = require("zlib");
          let inner = null;
          if (decoded[0] === 0x78) inner = zlib2.inflateSync(decoded);
          else if (decoded[0] === 0x1f && decoded[1] === 0x8b)
            inner = zlib2.gunzipSync(decoded);
          if (inner) {
            bodies.push({ layer: tag + ":decompressed", buf: inner });
            blob.decompressed_bytes = inner.length;
          }
        } catch (e) {}
        out.base64_blobs.push(blob);
      }
      out.matches = [];
      for (const term of a.search || []) {
        for (const body of bodies) {
          for (const enc of ["utf8", "utf16le"]) {
            const needle = Buffer.from(String(term), enc);
            let at = body.buf.indexOf(needle), hits = 0, first = -1;
            while (at !== -1 && hits < 50) {
              if (first < 0) first = at;
              hits += 1;
              at = body.buf.indexOf(needle, at + 1);
            }
            if (hits) out.matches.push({ term, layer: body.layer,
                                         encoding: enc, hits,
                                         first_offset: first });
          }
        }
      }
      if (!out.matches.length && (a.search || []).length)
        out.verdict = "No search string appears (utf8/utf16, raw or "
          + "decompressed). Two readings — the values are stored some "
          + "other way, OR the source clip simply never had them (an "
          + "unlabelled node has no label to store). Only a source that "
          + "verifiably contains the values can distinguish the two.";
      else if (out.matches.length)
        out.verdict = "Strings found — programmatic relabelling looks "
          + "feasible; report these findings back.";
      return out;
    }
    const tl = timeline(state);
    if (a.action === "save") {
      const resolve = state.resolve;
      const proj = project(state);
      const previousPage = resolve.GetCurrentPage();
      resolve.OpenPage("color");
      try {
        const gallery = proj.GetGallery();
        const album = gallery && gallery.GetCurrentStillAlbum();
        if (!album) throw new ResolveError("No gallery album available.");
        let still = null;
        for (let i = 0; i < 3 && !still; i++) {
          still = tl.GrabStill();
          if (!still) await sleep(400);
        }
        if (!still) throw new ResolveError("GrabStill returned nothing — "
          + "park on the clip whose layout you want to save.");
        const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ca-drx-"));
        const before = new Set(fs.readdirSync(tmp));
        album.ExportStills([still], tmp, "tmpl", "png");
        await sleep(300);
        const drx = fs.readdirSync(tmp).find((n) =>
          !before.has(n) && n.toLowerCase().endsWith(".drx"));
        try { album.DeleteStills([still]); } catch (e) {}
        if (!drx) throw new ResolveError("Export produced no .drx sidecar "
          + "— cannot capture the node graph.");
        fs.copyFileSync(path.join(tmp, drx), file);
        try { for (const n of fs.readdirSync(tmp))
                fs.unlinkSync(path.join(tmp, n));
              fs.rmdirSync(tmp); } catch (e) {}
        const item = tl.GetCurrentVideoItem && tl.GetCurrentVideoItem();
        return { saved: safe(a.name), file,
                 from_clip: item ? item.GetName() : "unknown",
                 note: "Template captures the FULL grade + node layout as "
                   + "it is right now. For a structure-only template, "
                   + "save from a clip whose nodes are empty." };
      } finally {
        if (previousPage && previousPage !== "color") {
          try { resolve.OpenPage(previousPage); } catch (e) {}
        }
      }
    }
    // apply
    if (!fs.existsSync(file))
      throw new ResolveError("No template named '" + safe(a.name)
        + "'. Run action 'list' to see what exists.");
    let item;
    if (a.clip !== undefined) {
      const items = tl.GetItemListInTrack("video", Number(a.track) || 1)
                    || [];
      item = items[Number(a.clip) - 1];
      if (!item) throw new ResolveError("No clip at position " + a.clip
                                        + ".");
    } else {
      item = tl.GetCurrentVideoItem && tl.GetCurrentVideoItem();
      if (!item) throw new ResolveError("No clip under the playhead.");
    }
    // Live-verified: on this install the method lives on the NODE GRAPH
    // object (item.GetNodeGraph().ApplyGradeFromDRX(path, 0)); the
    // timeline-level signature is the documented fallback for others.
    let ok = false, route = null;
    const ng = typeof item.GetNodeGraph === "function"
               ? item.GetNodeGraph() : null;
    if (ng && typeof ng.ApplyGradeFromDRX === "function") {
      ok = ng.ApplyGradeFromDRX(file, 0);
      route = "node graph";
    } else if (typeof tl.ApplyGradeFromDRX === "function") {
      ok = tl.ApplyGradeFromDRX(file, 0, item);
      route = "timeline";
    } else {
      throw new ResolveError("Neither the node graph nor the timeline "
        + "exposes ApplyGradeFromDRX here — template stamping "
        + "unavailable.");
    }
    if (!ok)
      throw new ResolveError("ApplyGradeFromDRX returned false for "
        + item.GetName() + " — the clip's previous grade is untouched.");
    return { applied: safe(a.name), to_clip: item.GetName(), route,
             replaced: "the clip's ENTIRE previous grade and node graph",
             note: "Node indexes from the template are now addressable by "
               + "set-CDL/LUT tools. No undo via API — use the Color "
               + "page's own undo if this was a mistake." };
  });

tool("label_nodes",
  "Label Color-page nodes (e.g. 1=EXP, 2=WB, 3=LOOK, 4=SPARE). Tries the "
  + "node graph's SetNodeLabel if this Resolve exposes one "
  + "(undocumented; feature-detected, never assumed) and reports label "
  + "readback per node. If the setter is missing, the reliable route is "
  + "returned instead: label the nodes BY HAND once, then grade_template "
  + "save — a .drx carries labels, so every stamped clip inherits them.",
  { labels: { type: "object",
              description: "Node index -> label, e.g. {\"1\": \"EXP\", "
                           + "\"2\": \"WB\"}." },
    clip: { type: "number",
            description: "1-based track position; default: clip under "
                         + "the playhead." },
    track: { type: "number", description: "Video track (default 1)." } },
  ["labels"], async (state, a) => {
    const tl = timeline(state);
    let item;
    if (a.clip !== undefined) {
      const items = tl.GetItemListInTrack("video", Number(a.track) || 1)
                    || [];
      item = items[Number(a.clip) - 1];
      if (!item) throw new ResolveError("No clip at position " + a.clip
                                        + ".");
    } else {
      item = tl.GetCurrentVideoItem && tl.GetCurrentVideoItem();
      if (!item) throw new ResolveError("No clip under the playhead.");
    }
    const ng = typeof item.GetNodeGraph === "function"
               ? item.GetNodeGraph() : null;
    if (!ng)
      throw new ResolveError("No node graph API on this item.");
    if (typeof ng.SetNodeLabel !== "function")
      return { clip: item.GetName(), settable: false,
               manual_route: "This Resolve exposes no SetNodeLabel "
                 + "(GetNodeLabel reads fine). Label the nodes by hand "
                 + "(double-click each node, type the name), then "
                 + "grade_template save — the .drx carries labels, so "
                 + "every clip you stamp inherits EXP/WB/etc. "
                 + "automatically." };
    const results = {};
    for (const [idx, label] of Object.entries(a.labels || {})) {
      const n = Number(idx);
      if (!n) continue;
      const ok = ng.SetNodeLabel(n, String(label));
      const back = typeof ng.GetNodeLabel === "function"
                   ? ng.GetNodeLabel(n) : null;
      results[n] = { requested: String(label), set: !!ok,
                     readback: back };
    }
    return { clip: item.GetName(), settable: true, nodes: results };
  });

// ------------------------------------------------------ Phase 6: study_edit
// "Training" done honestly: break a finished edit down into measurable
// style — cut rhythm, shot lengths, exposure and cast tendencies — and
// persist it as a profile future sessions read. No model weights change;
// the profile file IS the memory, and the user can open and correct it.
const STYLE_DIR = path.join(os.homedir(), "ClaudeAssistantStyle");

function percentile(sorted, p) {
  if (!sorted.length) return null;
  const at = Math.min(sorted.length - 1,
                      Math.max(0, Math.round(p * (sorted.length - 1))));
  return sorted[at];
}

// diffs[i] = mean abs pixel difference between samples i and i+1 (% of
// full scale, RGB-averaged). A run of over-threshold entries is ONE cut
// (a cut plus settling, or a whip pan) — collapse it.
function detectCuts(diffs, threshold) {
  const cuts = [];
  let inRun = false;
  for (let i = 0; i < diffs.length; i++) {
    if (diffs[i] >= threshold) { if (!inRun) cuts.push(i); inRun = true; }
    else inRun = false;
  }
  return cuts;
}

function styleAggregate(edits) {
  const lens = edits.flatMap((e) => e.shot_lengths_s || [])
                    .sort((x, y) => x - y);
  const levels = edits.flatMap((e) => (e.shots || [])
                       .map((sh) => sh.mean_level_pct))
                      .filter((v) => v !== null && v !== undefined)
                      .sort((x, y) => x - y);
  const casts = edits.flatMap((e) => (e.shots || []));
  const totalS = edits.reduce((t, e) => t + (e.duration_s || 0), 0);
  const totalCuts = edits.reduce((t, e) => t + (e.cuts || 0), 0);
  const warm = casts.filter((sh) => (sh.cast_rg || 0) > 1).length;
  const cool = casts.filter((sh) => (sh.cast_bg || 0) > 1).length;
  return {
    edits_studied: edits.length,
    total_duration_s: +totalS.toFixed(1),
    cuts_per_minute: totalS ? +(60 * totalCuts / totalS).toFixed(1) : null,
    shot_length_s: { median: percentile(lens, 0.5),
                     p25: percentile(lens, 0.25),
                     p75: percentile(lens, 0.75),
                     shortest: lens[0] || null,
                     longest: lens[lens.length - 1] || null },
    mean_level_pct_median: percentile(levels, 0.5),
    dark_shot_fraction: casts.length
      ? +(casts.filter((sh) => (sh.mean_level_pct || 0) < 25).length
          / casts.length).toFixed(2) : null,
    cast_tendency: casts.length
      ? (warm > cool * 1.5 ? "warm-leaning"
         : cool > warm * 1.5 ? "cool-leaning" : "mixed/neutral")
      : null,
  };
}

tool("study_edit",
  "Study a finished edit on the current timeline and distill its style "
  + "into a persistent profile (~/ClaudeAssistantStyle/<name>.json) that "
  + "future assemble/grade work reads. Samples frames at interval_frames "
  + "(default half a second), detects cuts as big neighbour-sample pixel "
  + "diffs (cut_threshold, default 8% mean — a heuristic: calibrate "
  + "against the returned diff_series on the first run), measures each "
  + "shot at full depth (exposure, cast), and merges the findings into "
  + "the profile. Grab files are deleted as it goes. SLOW (~2-3s per "
  + "sample) and batched: max_samples per call (default 40), resume via "
  + "start_frame from the previous result's next_start_frame until it "
  + "returns null, then the edit's entry is finalised.",
  { name: { type: "string",
            description: "Profile name (default 'car-edits')." },
    source: { type: "string",
              description: "Label for what's being studied (default the "
                           + "timeline name)." },
    interval_frames: { type: "number",
                       description: "Sampling stride in frames (default "
                                    + "fps/2 = 0.5s). Cuts faster than "
                                    + "one per stride merge together — "
                                    + "shrink this for machine-gun "
                                    + "editing." },
    cut_threshold: { type: "number",
                     description: "Mean pixel diff (%) that counts as a "
                                  + "cut; default 8." },
    max_samples: { type: "number",
                   description: "Samples this call (default 40, cap "
                                + "400; a ~90s wall-clock budget stops "
                                + "the batch early regardless)." },
    start_frame: { type: "number",
                   description: "Resume cursor from the previous call's "
                                + "next_start_frame." },
    out_dir: { type: "string",
               description: "Scratch dir for grabs; default /tmp." } },
  [], async (state, a) => {
    const tl = timeline(state);
    const fps = Number(tl.GetSetting("timelineFrameRate")) || 24;
    const interval = Math.max(1, Math.round(Number(a.interval_frames)
                                            || fps / 2));
    const tlStart = typeof tl.GetStartFrame === "function"
                    ? Number(tl.GetStartFrame()) : 0;
    // GetEndFrame is one PAST the last content frame (review-confirmed):
    // the walk stays strictly below it.
    const tlEnd = typeof tl.GetEndFrame === "function"
                  ? Number(tl.GetEndFrame()) : tlStart + 1;
    const maxSamples = Math.max(2, Math.min(400,
                                            Number(a.max_samples) || 40));
    const threshold = Number(a.cut_threshold) || 8;
    const grabEntry = TOOLS.find((t) => t.name === "grab_still");
    const t0 = Date.now();
    const TIME_BUDGET_MS = 90000;

    // ---- profile load, with corruption survival (never clobber silently)
    fs.mkdirSync(STYLE_DIR, { recursive: true });
    const profName = String(a.name || "car-edits")
      .replace(/[^\w.-]+/g, "_").slice(0, 60);
    const profFile = path.join(STYLE_DIR, profName + ".json");
    let profile = null, recoveredFrom = null;
    if (fs.existsSync(profFile)) {
      try {
        profile = JSON.parse(fs.readFileSync(profFile, "utf8"));
        if (!profile || !Array.isArray(profile.edits))
          throw new Error("profile has no edits array");
      } catch (e) {
        // Keep the damaged bytes — hours of study may be recoverable by
        // hand; never overwrite them wholesale.
        recoveredFrom = profFile + ".corrupt-" + Date.now().toString(36);
        try { fs.renameSync(profFile, recoveredFrom); } catch (e2) {}
        profile = null;
      }
    }
    if (!profile) profile = { name: profName, edits: [] };

    const source = String(a.source || tl.GetName());
    // A resume must name the exact cursor the previous batch handed back;
    // anything else is a FRESH study (Number(null) === 0 must not send us
    // to frame zero — review-confirmed footgun).
    const wantsResume = a.start_frame !== undefined
                        && a.start_frame !== null
                        && Number.isFinite(Number(a.start_frame));
    let entry = profile.edits.find((e) => e.source === source
                                          && !e.complete && e.pending);
    let resuming = false;
    if (wantsResume && entry
        && Number(a.start_frame) === entry.pending.next_frame) {
      resuming = true;
    } else {
      if (entry)                       // stale partial: replace, don't blend
        profile.edits = profile.edits.filter((e) => e !== entry);
      entry = { source, studied: new Date().toISOString(),
                samples_counted: 0, duration_s: 0, cuts: 0,
                shot_lengths_s: [], shots: [],
                interval_frames: interval };
      profile.edits.push(entry);
    }

    // ---- streaming shot/cut state, persisted across batches in pending
    let shot = null, inRun = false, prev = null;
    let frame = resuming ? entry.pending.next_frame : tlStart;
    if (resuming) {
      inRun = !!entry.pending.in_run;
      shot = entry.pending.shot || null;
      // Rejoin the seam: re-grab the previous batch's last sample so the
      // boundary diff exists (its absence silently ate seam cuts and split
      // every seam-spanning shot — review-confirmed with pixels).
      try {
        const g0 = await grabEntry.fn(state, {
          frame: entry.pending.prev_frame, format: "tif",
          out_dir: a.out_dir, no_proxy: true });
        const buf0 = fs.readFileSync(g0.measurement_file);
        try { fs.unlinkSync(g0.measurement_file); } catch (e) {}
        prev = { buf: buf0, info: parseTiff(buf0) };
      } catch (e) { prev = null; }      // seam diff lost, batch still runs
    }
    const closeShot = () => {
      if (!shot || !shot.n) { shot = null; return; }
      const m = shot.measured || 0;
      const done = {
        start_timecode: frameToTimecode(shot.start_frame, fps),
        length_s: +((shot.n * interval) / fps).toFixed(2),
        mean_level_pct: m ? +(shot.sum_level / m).toFixed(2) : null,
        cast_rg: m ? +(shot.sum_rg / m).toFixed(2) : null,
        cast_bg: m ? +(shot.sum_bg / m).toFixed(2) : null,
      };
      entry.shots.push(done);
      entry.shot_lengths_s.push(done.length_s);
      shot = null;
    };

    const diffs = [];
    let sampled = 0, cutsThisBatch = 0, unmeasured = 0, stopNote = null;
    while (sampled < maxSamples && frame < tlEnd
           && Date.now() - t0 < TIME_BUDGET_MS) {
      let buf = null, info = null, st = null;
      // One failed grab must not discard the whole batch's work
      // (review-confirmed): retry once, then stop here resumable.
      for (let attempt = 0; attempt < 2 && !buf; attempt++) {
        try {
          const g = await grabEntry.fn(state, {
            frame, format: "tif", out_dir: a.out_dir, no_proxy: true });
          buf = fs.readFileSync(g.measurement_file);
          try { fs.unlinkSync(g.measurement_file); } catch (e) {}
        } catch (e) {
          if (attempt === 1)
            stopNote = "sample at frame " + frame + " failed twice ("
              + e.message + ") — batch stopped there, resume to retry";
        }
      }
      if (!buf) break;
      info = parseTiff(buf);
      st = tiffStats(buf, info);
      const ch = st && st.channels;
      let diff = null;
      if (prev && prev.info && info) {
        const d = tiffDiffStats(prev.buf, prev.info, buf, info);
        if (d.mean_abs_diff_rgb_pct)
          diff = +(d.mean_abs_diff_rgb_pct.reduce((t, v) => t + v, 0) / 3)
            .toFixed(2);
      }
      // A failed measurement is UNKNOWN, not "no cut" (review-confirmed):
      // it leaves the run state alone and is counted separately.
      if (diff === null && prev) unmeasured += 1;
      diffs.push(diff);
      if (diff !== null && diff >= threshold) {
        if (!inRun) {
          closeShot();
          entry.cuts += 1;
          cutsThisBatch += 1;
        }
        inRun = true;
      } else if (diff !== null) inRun = false;
      if (!shot) shot = { start_frame: frame, n: 0, measured: 0,
                          sum_level: 0, sum_rg: 0, sum_bg: 0 };
      shot.n += 1;
      if (ch) {
        shot.measured += 1;
        shot.sum_level += ch.reduce((t, c) => t + c.mean_pct, 0) / 3;
        shot.sum_rg += ch[0].mean_pct - ch[1].mean_pct;
        shot.sum_bg += ch[2].mean_pct - ch[1].mean_pct;
      }
      entry.samples_counted += 1;
      prev = { buf, info };
      sampled += 1;
      frame += interval;
    }

    const done = frame >= tlEnd && !stopNote;
    entry.duration_s = +((entry.samples_counted * interval) / fps)
      .toFixed(1);
    if (done) {
      closeShot();
      entry.complete = true;
      delete entry.pending;
    } else {
      entry.pending = { next_frame: frame, prev_frame: frame - interval,
                        in_run: inRun, shot };
    }
    profile.aggregate = styleAggregate(profile.edits);
    profile.updated = new Date().toISOString();
    const tmpFile = profFile + ".tmp";
    fs.writeFileSync(tmpFile, JSON.stringify(profile, null, 2));
    fs.renameSync(tmpFile, profFile);    // atomic: no half-written profiles

    const hot = diffs.filter((d) => d !== null && d >= threshold).length;
    const out = {
      studied: source, samples: sampled,
      interval_frames: interval, cut_threshold: threshold,
      cuts_this_batch: cutsThisBatch,
      shots_so_far: entry.shots.length + (shot ? 1 : 0),
      diff_series: diffs.slice(0, 150),
      unmeasured_diffs: unmeasured || undefined,
      elapsed_ms: Date.now() - t0,
      next_start_frame: done ? null : frame,
      batch_note: done
        ? "Edit fully studied — profile entry finalised."
        : (stopNote || "More timeline remains: call again with "
           + "start_frame " + frame + "."),
      profile_file: profFile,
      aggregate: profile.aggregate,
    };
    if (recoveredFrom)
      out.profile_recovered = "Previous profile was unreadable; preserved "
        + "at " + recoveredFrom + " (nothing was overwritten silently).";
    if (diffs.length && hot > diffs.length * 0.3)
      out.stride_warning = "Over 30% of neighbour diffs exceed the cut "
        + "threshold — the edit may cut faster than this stride resolves; "
        + "consider re-studying with a smaller interval_frames.";
    return out;
  });

// ---------------------------------------------------- Gemini video eyes
// Verified against ai.google.dev 2026-08 docs (video-understanding, files,
// generate-content, api-errors). generateContent is used deliberately —
// Google's Interactions API is mid-breaking-change; generateContent
// "remains fully supported" and has the stable response shape.
const https = require("https");
const GEMINI_HOST = "generativelanguage.googleapis.com";
const GEMINI_MODEL_DEFAULT = "gemini-3.7-flash";
const VIDEO_MIME = { mp4: "video/mp4", mov: "video/mov", webm: "video/webm",
                     avi: "video/avi", mpg: "video/mpg", mpeg: "video/mpeg",
                     wmv: "video/wmv", flv: "video/x-flv",
                     "3gp": "video/3gpp" };

function httpsRequest(url, opts, body) {
  return new Promise((res, rej) => {
    const u = new URL(url);
    const req = https.request({
      hostname: u.hostname, path: u.pathname + u.search,
      method: (opts && opts.method) || "GET",
      headers: (opts && opts.headers) || {},
      timeout: (opts && opts.timeoutMs) || 120000,
    }, (r) => {
      const chunks = [];
      r.on("data", (d) => chunks.push(d));
      r.on("end", () => {
        const text = Buffer.concat(chunks).toString("utf8");
        let json = null;
        try { json = JSON.parse(text); } catch (e) {}
        res({ status: r.statusCode, headers: r.headers, text, json });
      });
    });
    req.on("timeout", () => { req.destroy(new Error("timed out")); });
    req.on("error", rej);
    if (body) req.write(body);
    req.end();
  });
}

// Retry wrapper per Google's own guidance: back off on 429/5xx/network,
// never retry 400/403. A transient 503 must not fail a whole study pass
// (live incident: Google overloaded, zero retries, five reels lost).
async function geminiCall(doReq, url, opts, body, tries) {
  let last = { status: 0 };
  for (let i = 0; i < (tries || 3); i++) {
    if (i) await sleep(1500 * Math.pow(2, i - 1));
    try { last = await doReq(url, opts, body); }
    catch (e) { last = { status: 0, headers: {}, json: null,
                         text: e.message }; continue; }
    if (last.status && last.status < 500 && last.status !== 429)
      return last;
  }
  return last;
}

// Branch on error.status first, then details[].reason — a bad key is 400
// INVALID_ARGUMENT + API_KEY_INVALID, NOT 403 (403 = valid key, no
// permission). Straight from the api-errors doc.
function geminiErrorText(status, json) {
  const e = (json && json.error) || {};
  const reason = (e.details || []).map((d) => d && d.reason)
    .filter(Boolean)[0];
  if (reason === "API_KEY_INVALID")
    return "Gemini rejected the API key as invalid — re-check it "
      + "(aistudio.google.com > Get API key) and store it again.";
  if (e.status === "RESOURCE_EXHAUSTED")
    return "Gemini rate limit hit (free tier). Wait a minute and retry; "
      + "daily quotas reset at midnight Pacific.";
  if (e.status === "PERMISSION_DENIED")
    return "The Gemini key is valid but lacks permission for this API.";
  if (e.status === "FAILED_PRECONDITION")
    return "Gemini free tier is not available for this project/region — "
      + "enable billing in Google AI Studio.";
  if (e.status === "NOT_FOUND")
    return "The uploaded video is gone on Google's side (files expire "
      + "after 48h) — re-run to upload again.";
  if (status === 503 || e.status === "UNAVAILABLE")
    return "Google's Gemini service is temporarily overloaded (503). "
      + "Already retried with backoff — wait a few minutes and try "
      + "again; nothing is wedged on our side.";
  if (status === 0)
    return "Could not reach Google at all (network error: "
      + ((json && json.text) || "unknown") + ").";
  return "Gemini error HTTP " + status + ": "
    + (e.message || "no detail").slice(0, 300);
}

async function geminiUploadVideo(doReq, key, file) {
  const bytes = fs.readFileSync(file);
  if (bytes.length > 2 * 1024 * 1024 * 1024)
    throw new ResolveError("Video exceeds Gemini's 2GB per-file cap.");
  const ext = path.extname(file).slice(1).toLowerCase();
  const mime = VIDEO_MIME[ext] || "video/mp4";
  const start = await geminiCall(doReq,
    "https://" + GEMINI_HOST + "/upload/v1beta/files",
    { method: "POST", timeoutMs: 30000, headers: {
        "x-goog-api-key": key,
        "X-Goog-Upload-Protocol": "resumable",
        "X-Goog-Upload-Command": "start",
        "X-Goog-Upload-Header-Content-Length": String(bytes.length),
        "X-Goog-Upload-Header-Content-Type": mime,
        "Content-Type": "application/json" } },
    JSON.stringify({ file: { display_name: path.basename(file) } }));
  if (start.status !== 200)
    throw new ResolveError(geminiErrorText(start.status, start.json));
  const uploadUrl = start.headers["x-goog-upload-url"];
  if (!uploadUrl)
    throw new ResolveError("Gemini upload start returned no "
      + "x-goog-upload-url header.");
  const up = await doReq(uploadUrl,
    { method: "POST", timeoutMs: 150000, headers: {
        "Content-Length": String(bytes.length),
        "X-Goog-Upload-Offset": "0",
        "X-Goog-Upload-Command": "upload, finalize" } }, bytes);
  const fileObj = up.json && up.json.file;   // upload response IS wrapped
  if (up.status !== 200 || !fileObj || !fileObj.uri)
    throw new ResolveError(geminiErrorText(up.status, up.json));
  // Poll until ACTIVE. Asymmetry (doc-verified): GET returns a BARE File,
  // not {file: ...} — read both defensively.
  let st = fileObj.state, name = fileObj.name;
  for (let i = 0; i < 15 && st === "PROCESSING"; i++) {
    await sleep(5000);
    const poll = await geminiCall(doReq,
      "https://" + GEMINI_HOST + "/v1beta/" + name,
      { timeoutMs: 15000, headers: { "x-goog-api-key": key } }, null, 2);
    const f = (poll.json && poll.json.file) || poll.json || {};
    st = f.state || st;
    if (f.error) throw new ResolveError("Gemini could not process the "
      + "video: " + (f.error.message || JSON.stringify(f.error)));
  }
  if (st !== "ACTIVE")
    throw new ResolveError("Gemini file never became ACTIVE (state "
      + st + ") — try again or use a shorter clip.");
  return { uri: fileObj.uri, name, mime };
}

const WATCH_PROMPT_DEFAULT =
  "You are analysing a finished short-form automotive edit for an "
  + "editor/colorist studying its style. Report concretely: "
  + "1) Shot list with timestamps: subject, shot size (wide/medium/"
  + "close/detail), camera movement (static/pan/orbit/gimbal/FPV), "
  + "day or night. 2) Structure: how it opens, builds, and pays off. "
  + "3) Pacing character in words. 4) The grade/look in plain colour "
  + "terms (contrast, cast, saturation, where it leans). 5) Anything "
  + "distinctive worth imitating. Be brief and specific.";

tool("watch_video",
  "Gemini video eyes: upload a LOCAL video file (e.g. the file "
  + "study_url downloaded) to Google's Gemini API and have it actually "
  + "WATCH the footage — shot types, subjects, structure, look — the "
  + "content half that pixel statistics cannot see. Needs a Gemini API "
  + "key stored via set_gemini_key (free at aistudio.google.com). "
  + "Optionally merges the answer into a style profile entry "
  + "(profile + source matching a study_edit entry). The file goes to "
  + "Google for analysis and auto-expires there in 48h (we also delete "
  + "it immediately after).",
  { file: { type: "string",
            description: "Absolute path to the local video file." },
    question: { type: "string",
                description: "What to ask about it (default: a "
                             + "style-study breakdown)." },
    model: { type: "string",
             description: "Gemini model id (default "
                          + GEMINI_MODEL_DEFAULT + ")." },
    low_res: { type: "boolean",
               description: "Low media resolution — for videos over "
                            + "~45 min, or to save quota." },
    profile: { type: "string",
               description: "Style profile name to merge the answer "
                            + "into (optional)." },
    source: { type: "string",
              description: "The profile entry's source label to attach "
                           + "the content notes to (with profile)." } },
  ["file"], async (state, a) => {
    const key = geminiKey();
    if (!key)
      throw new ResolveError("No Gemini API key stored. Get a free one "
        + "at aistudio.google.com (Get API key), then run set_gemini_key.");
    const file = String(a.file);
    if (!fs.existsSync(file))
      throw new ResolveError("No such file: " + file);
    const doReq = state._testHttp || httpsRequest;
    const up = await geminiUploadVideo(doReq, key, file);
    const model = String(a.model || GEMINI_MODEL_DEFAULT);
    const body = {
      contents: [{ parts: [
        { text: String(a.question || WATCH_PROMPT_DEFAULT) },
        { fileData: { mimeType: up.mime, fileUri: up.uri } },
      ] }],
    };
    if (a.low_res)
      body.generationConfig = { mediaResolution: "MEDIA_RESOLUTION_LOW" };
    const gen = await geminiCall(doReq,
      "https://" + GEMINI_HOST + "/v1beta/models/"
      + model + ":generateContent",
      { method: "POST", timeoutMs: 150000,
        headers: { "x-goog-api-key": key,
                   "Content-Type": "application/json" } },
      JSON.stringify(body));
    // Tidy up server-side regardless of the answer (48h auto-expiry is
    // the backstop).
    try { await doReq("https://" + GEMINI_HOST + "/v1beta/" + up.name,
      { method: "DELETE", headers: { "x-goog-api-key": key } }); }
    catch (e) {}
    if (gen.status !== 200)
      throw new ResolveError(geminiErrorText(gen.status, gen.json));
    const cands = (gen.json && gen.json.candidates) || [];
    if (!cands.length) {
      const block = gen.json && gen.json.promptFeedback
        && gen.json.promptFeedback.blockReason;
      throw new ResolveError("Gemini returned no answer"
        + (block ? " (blocked: " + block + ")" : "") + ".");
    }
    const answer = ((cands[0].content || {}).parts || [])
      .filter((pt) => typeof pt.text === "string" && !pt.thought)
      .map((pt) => pt.text).join("\n").trim();
    const out = { model, answer,
                  tokens: gen.json.usageMetadata
                          && gen.json.usageMetadata.totalTokenCount };
    if (a.profile && answer) {
      try {
        const pf = path.join(STYLE_DIR,
          String(a.profile).replace(/[^\w.-]+/g, "_").slice(0, 60)
          + ".json");
        const prof = JSON.parse(fs.readFileSync(pf, "utf8"));
        const src = String(a.source || "");
        const entry = prof.edits.find((e) => e.source === src)
          || prof.edits[prof.edits.length - 1];
        if (entry) {
          entry.content_notes = answer;
          const tmp = pf + ".tmp";
          fs.writeFileSync(tmp, JSON.stringify(prof, null, 2));
          fs.renameSync(tmp, pf);
          out.merged_into = { profile: path.basename(pf),
                             source: entry.source };
        } else out.merge_note = "profile has no entries yet";
      } catch (e) { out.merge_note = "could not merge: " + e.message; }
    }
    return out;
  });

tool("gemini_status",
  "Report whether a Gemini API key is configured (env or "
  + "~/.claude-assistant.json) WITHOUT any network call — shows only "
  + "the key's last 4 characters. Pass validate: true to additionally "
  + "confirm it against Google's models endpoint (one free call).",
  { validate: { type: "boolean",
                description: "Also check the key against Google." } },
  [], async (state, a) => {
    const key = geminiKey();
    if (!key) return { key_stored: false, config_file: CONFIG_FILE,
      how_to: "set_gemini_key with a key from aistudio.google.com "
              + "(Get API key)" };
    const out = { key_stored: true, key_ending: "..." + key.slice(-4),
                  source: process.env.GEMINI_API_KEY ? "environment"
                          : CONFIG_FILE };
    if (a.validate) {
      const doReq = state._testHttp || httpsRequest;
      const check = await geminiCall(doReq, "https://" + GEMINI_HOST
        + "/v1beta/models",
        { timeoutMs: 20000, headers: { "x-goog-api-key": key } });
      out.valid = check.status === 200;
      if (!out.valid)
        out.problem = geminiErrorText(check.status, check.json);
    }
    return out;
  });

tool("set_gemini_key",
  "Store the Gemini API key (from aistudio.google.com) in the local "
  + "config (~/.claude-assistant.json, owner-only permissions) and "
  + "validate it with a free models-list call. The key is never echoed "
  + "back.",
  { key: { type: "string", description: "The API key (AIza...)." } },
  ["key"], async (state, a) => {
    const key = String(a.key || "").trim();
    if (key.length < 20)
      throw new ResolveError("That doesn't look like an API key.");
    const doReq = state._testHttp || httpsRequest;
    const check = await geminiCall(doReq,
      "https://" + GEMINI_HOST + "/v1beta/models",
      { timeoutMs: 20000, headers: { "x-goog-api-key": key } });
    if (check.status !== 200)
      throw new ResolveError("Key stored NOWHERE — validation failed: "
        + geminiErrorText(check.status, check.json));
    writeConfig({ gemini_api_key: key });
    return { stored: true, config: CONFIG_FILE,
             key_ending: "..." + key.slice(-4),
             validated: "models list call succeeded" };
  });

// Slash commands: prompt macros the panel expands before the model sees
// them. The transcript shows what the user typed; the model receives the
// expanded marching orders. SLASH_COMMANDS is what the renderer's "/"
// menu lists (config IPC); local:true ones the renderer handles itself.
const SLASH_COMMANDS = [
  { name: "study", args: "<link> [<link> …]",
    description: "Study finished edits into your style profile (TikTok, Instagram, YouTube links)" },
  { name: "train", args: "<link> [<link> …]",
    description: "Same as /study — train the style profile on finished edits" },
  { name: "help", args: "", local: true,
    description: "What Claude can do here, and these commands" },
  { name: "new", args: "", local: true,
    description: "Start a new chat (Claude's memory of this session is cleared)" },
  { name: "history", args: "", local: true, description: "Open past chats" },
  { name: "copy", args: "", local: true, description: "Copy the whole conversation as text" },
];

function expandSlash(text) {
  const t = String(text || "").trim();
  const m = /^\/(stu+d+y|trai+n+)\b/i.exec(t);   // typo-tolerant: /stuudy, /trainn too
  if (!m) return null;
  const typed = /^t/i.test(m[1]) ? "/train" : "/study";
  const urls = t.match(/https?:\/\/\S+/g) || [];
  if (!urls.length)
    return "The user typed " + typed + " without links. Explain briefly: "
      + typed + " <link> [<link> ...] downloads each video (TikTok, "
      + "Instagram, YouTube), builds a study timeline, and analyses it "
      + "into the car-edits style profile"
      + (typed === "/train" ? " (/train and /study are the same command)" : "") + ".";
  return "Study these " + urls.length + " edit(s) into the car-edits "
    + "style profile, STRICTLY one at a time. For EACH link, all three "
    + "steps in order:\n"
    + urls.map((u, i) => (i + 1) + ". " + u).join("\n")
    + "\nSTEP A: study_url with the link (downloads + builds the study "
    + "timeline).\n"
    + "STEP B: study_edit, resuming with next_start_frame until that "
    + "edit reports complete (the measurements).\n"
    + "STEP C: watch_video on the downloaded file from step A, with "
    + "profile car-edits and the same source label — Gemini watches the "
    + "footage and its content read merges into the profile. This step "
    + "is NOT optional; if it fails over a missing or invalid Gemini "
    + "key, report that plainly once, skip further watch attempts, and "
    + "keep studying the remaining links.\n"
    + "If a link fails entirely, say why and continue with the rest. "
    + "Finish with the profile aggregate and a plain-English read of "
    + "the style — the numbers AND the content notes together.";
}

// What the panel does with a typed line: expand a known macro; answer an
// unknown "/word" itself (Claude Code reads a leading slash as one of ITS
// commands and answers "Unknown command: /train"); or pass text through,
// prefixed when it starts with "/" (a file path) for the same reason.
function slashRoute(text) {
  const t = String(text || "").trim();
  const expanded = expandSlash(t);
  if (expanded) return { kind: "expand", prompt: expanded };
  const m = /^\/([a-z][a-z-]*)$/i.exec(t.split(/\s+/)[0] || "");
  if (m) {
    const name = m[1].toLowerCase();
    const local = SLASH_COMMANDS.find((c) => c.name === name && c.local);
    return { kind: "unknown", name,
      note: local ? "/" + name + " works on its own — type it without anything after it."
        : "No command called /" + name + " — type / to see the list. Anything that doesn't start with / goes to Claude as written." };
  }
  return { kind: "text", prompt: t.startsWith("/") ? "Message from the panel (a path, not a command): " + t : t };
}

// ------------------------------------------------------------ plugin config
// Small JSON store for secrets/settings (the Gemini key today). Kept in the
// user's home, 0600, and never echoed back in tool results.
const CONFIG_FILE = path.join(os.homedir(), ".claude-assistant.json");

function readConfig() {
  try { return JSON.parse(fs.readFileSync(CONFIG_FILE, "utf8")) || {}; }
  catch (e) { return {}; }
}

function writeConfig(patch) {
  const cfg = Object.assign(readConfig(), patch || {});
  const tmp = CONFIG_FILE + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(cfg, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, CONFIG_FILE);
  try { fs.chmodSync(CONFIG_FILE, 0o600); } catch (e) {}
  return cfg;
}

function geminiKey() {
  return process.env.GEMINI_API_KEY || readConfig().gemini_api_key || null;
}

// ------------------------------------------------- study from a pasted link
// GUI apps get a bare PATH on macOS (the same trap the CLI hit), so probe
// the usual homes for yt-dlp instead of trusting PATH alone.
function findYtDlp() {
  const candidates = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp",
                      path.join(os.homedir(), ".local/bin/yt-dlp"),
                      "yt-dlp"];
  for (const c of candidates) {
    if (c.includes("/")) { try { fs.accessSync(c, fs.constants.X_OK);
                                 return c; } catch (e) {} }
    else return c;                       // last resort: hope PATH has it
  }
  return null;
}

function downloadVideo(url, dir) {
  return new Promise((resolveP, rejectP) => {
    const bin = findYtDlp();
    if (!bin)
      return rejectP(new ResolveError("yt-dlp is not installed — it does "
        + "the actual downloading. One-time setup in Terminal: "
        + "brew install yt-dlp ffmpeg   (then retry)."));
    const stamp = Date.now().toString(36);
    const template = path.join(dir, "study_" + stamp + ".%(ext)s");
    const child = spawn(bin, ["-f", "mp4/bv*+ba/b",
                              "--merge-output-format", "mp4",
                              "--no-playlist", "-o", template, url],
                        { stdio: ["ignore", "pipe", "pipe"] });
    let err = "";
    child.stderr.on("data", (d) => { err += d; });
    const timer = setTimeout(() => { try { child.kill(); } catch (e) {}
      rejectP(new ResolveError("Download timed out after 180s.")); },
      180000);
    child.on("error", (e) => { clearTimeout(timer);
      rejectP(new ResolveError("Could not run yt-dlp: " + e.message)); });
    child.on("close", (code) => {
      clearTimeout(timer);
      const hit = fs.readdirSync(dir).find((n) =>
        n.startsWith("study_" + stamp + "."));
      if (code === 0 && hit) resolveP(path.join(dir, hit));
      else rejectP(new ResolveError("yt-dlp failed (exit " + code + "): "
        + err.slice(-500)));
    });
  });
}

tool("study_url",
  "Paste-a-link studying: download a video from a URL (TikTok, "
  + "Instagram, YouTube — anything yt-dlp handles; requires 'brew "
  + "install yt-dlp ffmpeg' once), import it into a 'Studied Edits' "
  + "bin, build a timeline from it, and make that timeline current — "
  + "ready for study_edit to analyse into a style profile. Only study "
  + "content you're entitled to view; the download is for local "
  + "analysis. Writes to the project (import + one timeline), so it "
  + "asks approval.",
  { url: { type: "string", description: "The video link." },
    keep_file: { type: "boolean",
                 description: "Keep the downloaded file (default true; "
                              + "it lives in ~/ClaudeAssistantStudy)." } },
  ["url"], async (state, a) => {
    const proj = project(state);
    const dir = path.join(os.homedir(), "ClaudeAssistantStudy");
    fs.mkdirSync(dir, { recursive: true });
    const file = state._testDownload
      ? await state._testDownload(String(a.url), dir)
      : await downloadVideo(String(a.url), dir);
    const mediaPool = proj.GetMediaPool();
    const root = mediaPool.GetRootFolder();
    let bin = (root.GetSubFolderList() || [])
      .find((f) => f.GetName() === "Studied Edits");
    if (!bin) bin = mediaPool.AddSubFolder(root, "Studied Edits");
    if (bin && mediaPool.SetCurrentFolder) mediaPool.SetCurrentFolder(bin);
    const clips = mediaPool.ImportMedia([file]);
    if (!clips || !clips.length)
      throw new ResolveError("Downloaded fine but Resolve refused the "
        + "import: " + file + " — codec trouble? The file is on disk.");
    const tlName = "study_" + path.basename(file).replace(/\.\w+$/, "");
    const studyTl = mediaPool.CreateTimelineFromClips(tlName, [clips[0]]);
    if (!studyTl)
      throw new ResolveError("Import worked but CreateTimelineFromClips "
        + "returned nothing; create a timeline from the clip by hand.");
    proj.SetCurrentTimeline(studyTl);
    return { downloaded: file,
             imported_to_bin: "Studied Edits",
             timeline: tlName,
             now_current: true,
             next: "Run study_edit (it studies the CURRENT timeline) — "
               + "batch with the resume cursor until complete.",
             cleanup: a.keep_file === false
               ? (() => { try { fs.unlinkSync(file); return "file "
                    + "deleted after import"; } catch (e) {
                    return "delete failed: " + e.message; } })()
               : "file kept at " + file };
  });

// Settles "are these two grabs the same image?" with arithmetic instead of
// eyeballs — the model's JS sandbox has no fs, but this process does.
// CIE Lab (D65) of a display-referred RGB triple (0..1, Rec.709 gamma 2.4)
// and CIEDE2000 — the perceptual yardstick the benchmarks use.
function labOf(rgb) {
  const [r, g, b] = rgb.map((v) => Math.pow(Math.max(0, v), 2.4));
  const X = 0.4124 * r + 0.3576 * g + 0.1805 * b, Y = 0.2126 * r + 0.7152 * g + 0.0722 * b, Z = 0.0193 * r + 0.1192 * g + 0.9505 * b;
  const f = (t) => (t > 0.008856 ? Math.cbrt(t) : 7.787 * t + 16 / 116);
  const fx = f(X / 0.95047), fy = f(Y), fz = f(Z / 1.08883);
  return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
}
function deltaE2000([L1, a1, b1], [L2, a2, b2]) {
  const C1 = Math.hypot(a1, b1), C2 = Math.hypot(a2, b2), Cb = (C1 + C2) / 2;
  const G = 0.5 * (1 - Math.sqrt(Math.pow(Cb, 7) / (Math.pow(Cb, 7) + Math.pow(25, 7))));
  const ap1 = a1 * (1 + G), ap2 = a2 * (1 + G), Cp1 = Math.hypot(ap1, b1), Cp2 = Math.hypot(ap2, b2);
  const h = (a, b) => { let t = Math.atan2(b, a) * 180 / Math.PI; return t < 0 ? t + 360 : t; };
  const hp1 = h(ap1, b1), hp2 = h(ap2, b2), dL = L2 - L1, dC = Cp2 - Cp1;
  let dh = hp2 - hp1; if (Cp1 * Cp2 === 0) dh = 0; else if (dh > 180) dh -= 360; else if (dh < -180) dh += 360;
  const dH = 2 * Math.sqrt(Cp1 * Cp2) * Math.sin(dh / 2 * Math.PI / 180);
  const Lb = (L1 + L2) / 2, Cpb = (Cp1 + Cp2) / 2;
  let hb = hp1 + hp2; if (Cp1 * Cp2 !== 0) { if (Math.abs(hp1 - hp2) > 180) hb += hb < 360 ? 360 : -360; hb /= 2; }
  const T = 1 - 0.17 * Math.cos((hb - 30) * Math.PI / 180) + 0.24 * Math.cos(2 * hb * Math.PI / 180) + 0.32 * Math.cos((3 * hb + 6) * Math.PI / 180) - 0.20 * Math.cos((4 * hb - 63) * Math.PI / 180);
  const Sl = 1 + 0.015 * (Lb - 50) ** 2 / Math.sqrt(20 + (Lb - 50) ** 2), Sc = 1 + 0.045 * Cpb, Sh = 1 + 0.015 * Cpb * T;
  const Rt = -2 * Math.sqrt(Math.pow(Cpb, 7) / (Math.pow(Cpb, 7) + Math.pow(25, 7))) * Math.sin(60 * Math.exp(-(((hb - 275) / 25) ** 2)) * Math.PI / 180);
  return Math.sqrt((dL / Sl) ** 2 + (dC / Sc) ** 2 + (dH / Sh) ** 2 + Rt * (dC / Sc) * (dH / Sh));
}

// Per-pixel ΔE2000 between two grabs of the SAME content (same source
// frame): mean, p95, max and the share of pixels a viewer would notice.
function tiffDeltaE(bufA, infoA, bufB, infoB, maxPixels) {
  const okInfo = (info, buf) => info && info.compression === 1 && (info.bitsPerSample === 8 || info.bitsPerSample === 16)
    && info.stripOffsets && info.stripByteCounts && info.stripOffsets.length === info.stripByteCounts.length;
  const comparable = okInfo(infoA, bufA) && okInfo(infoB, bufB) && infoA.bitsPerSample === infoB.bitsPerSample
    && infoA.width === infoB.width && infoA.height === infoB.height;
  if (!comparable) return { skipped: "per-pixel ΔE needs two uncompressed 8/16-bit strip TIFFs of the same size and depth" };
  const bits = infoA.bitsPerSample, full = bits === 8 ? 255 : 65535, step = bits >> 3;
  const chA = Math.max(1, Math.min(4, infoA.samplesPerPixel || 3)), chB = Math.max(1, Math.min(4, infoB.samplesPerPixel || 3));
  const rd = (buf, info, o) => (bits === 8 ? buf[o] : (info.littleEndian ? buf.readUInt16LE(o) : buf.readUInt16BE(o))) / full;
  // Pixels actually present in the file (a truncated grab has fewer than the header says).
  const count = (buf, info, ch) => { let n = 0; for (let st = 0; st < info.stripOffsets.length; st++) { const start = info.stripOffsets[st], end = Math.min(buf.length, start + info.stripByteCounts[st]); n += Math.max(0, Math.floor((end - start) / (step * ch))); } return n; };
  const n = Math.min(count(bufA, infoA, chA), count(bufB, infoB, chB));
  if (n < 1) return { skipped: "no pixel data in one of the grabs (truncated file?)" };
  const stride = Math.max(1, Math.ceil(n / (maxPixels || 250000)));
  // Every stride-th pixel's byte offset, walking the strips once — never one entry per pixel.
  const strided = (buf, info, ch) => { const out = []; let next = 0, seen = 0; const px = step * ch;
    for (let st = 0; st < info.stripOffsets.length && out.length * stride < n; st++) {
      const start = info.stripOffsets[st], end = Math.min(buf.length, start + info.stripByteCounts[st]), inStrip = Math.max(0, Math.floor((end - start) / px));
      while (next < seen + inStrip && out.length * stride < n) { out.push(start + (next - seen) * px); next += stride; }
      seen += inStrip;
    } return out; };
  const oa = strided(bufA, infoA, chA), ob = strided(bufB, infoB, chB), m = Math.min(oa.length, ob.length);
  const d = [];
  for (let i = 0; i < m; i++) {
    const A = [0, 1, 2].map((c) => rd(bufA, infoA, oa[i] + Math.min(c, chA - 1) * step));
    const Bp = [0, 1, 2].map((c) => rd(bufB, infoB, ob[i] + Math.min(c, chB - 1) * step));
    d.push(deltaE2000(labOf(A), labOf(Bp)));
  }
  d.sort((x, y) => x - y);
  const mean = d.reduce((t, v) => t + v, 0) / (d.length || 1);
  return { pixels: d.length, stride, mean: +mean.toFixed(2), p95: +(d[Math.floor(0.95 * (d.length - 1))] || 0).toFixed(2),
    max: +(d[d.length - 1] || 0).toFixed(2), visible_pct: +((100 * d.filter((v) => v > 2).length) / (d.length || 1)).toFixed(1),
    reading: mean < 1 ? "invisible" : mean < 2 ? "just visible" : mean < 5 ? "visible" : "obvious" };
}

// Distribution distance between two grabs of DIFFERENT content (two shots
// of a scene): how far the target's levels, curves, chroma and hue content
// sit from the reference. Lower is closer; the parts are reported so the
// number can be argued with.
function statsDistance(ref, tgt) {
  const meanDiff = ref.stats.map((c, i) => +(tgt.stats[i].mean_pct - c.mean_pct).toFixed(2));
  const curveRms = ref.stats.map((c, i) => { let e = 0; for (let k = 1; k <= 7; k++) e += (tgt.stats[i].pctl[k] - c.pctl[k]) ** 2; return +Math.sqrt(e / 7).toFixed(2); });
  const chroma = +(tgt.joint.chroma_p90_pct - ref.joint.chroma_p90_pct).toFixed(2);
  const RH = smoothHue(ref.joint.hue_hist), TH = smoothHue(tgt.joint.hue_hist);
  let overlap = 0;
  for (let k = 0; k < HUE_BINS; k++) overlap += Math.sqrt(RH[k] * TH[k]);
  const skinA = ref.joint.skin.angle_deg, skinB = tgt.joint.skin.angle_deg;
  const skin = skinA !== null && skinB !== null ? +((((skinB - skinA) + 540) % 360) - 180).toFixed(1) : null;
  const score = curveRms.reduce((t, v) => t + v, 0) / 3 + Math.abs(meanDiff.reduce((t, v) => t + Math.abs(v), 0)) / 3
    + 0.5 * Math.abs(chroma) + 10 * (1 - overlap) + (skin === null ? 0 : Math.abs(skin) / 5);
  return { score: +score.toFixed(2), mean_rgb_diff_pct: meanDiff, curve_rms_pct: curveRms, chroma_p90_diff_pct: chroma,
    hue_overlap: +overlap.toFixed(3), skin_angle_diff_deg: skin };
}

function tiffDiffStats(bufA, infoA, bufB, infoB) {
  const comparable = infoA && infoB && infoA.compression === 1
    && infoB.compression === 1 && infoA.bitsPerSample === infoB.bitsPerSample
    && infoA.width === infoB.width && infoA.height === infoB.height
    && infoA.stripOffsets && infoB.stripOffsets;
  if (!comparable)
    return { skipped: "pixel stats need two uncompressed TIFFs of the "
                      + "same size and depth" };
  const bits = infoA.bitsPerSample, step = bits >> 3;
  const channels = Math.max(1, Math.min(4, infoA.samplesPerPixel || 3));
  const flat = (buf, info) => {
    const spans = [];
    for (let i = 0; i < info.stripOffsets.length; i++)
      spans.push([info.stripOffsets[i],
                  Math.min(buf.length,
                           info.stripOffsets[i] + info.stripByteCounts[i])]);
    return spans;
  };
  const read = (buf, info, spans, cursor) => {
    while (cursor.s < spans.length && cursor.o + step > spans[cursor.s][1]) {
      cursor.s += 1; cursor.o = cursor.s < spans.length
                                 ? spans[cursor.s][0] : 0;
    }
    if (cursor.s >= spans.length) return null;
    const o = cursor.o; cursor.o += step;
    return bits === 8 ? buf[o]
      : (info.littleEndian ? buf.readUInt16LE(o) : buf.readUInt16BE(o));
  };
  const spansA = flat(bufA, infoA), spansB = flat(bufB, infoB);
  const curA = { s: 0, o: spansA.length ? spansA[0][0] : 0 };
  const curB = { s: 0, o: spansB.length ? spansB[0][0] : 0 };
  const sumAbs = new Array(channels).fill(0);
  const maxAbs = new Array(channels).fill(0);
  let samples = 0, differing = 0, c = 0;
  for (;;) {
    const va = read(bufA, infoA, spansA, curA);
    const vb = read(bufB, infoB, spansB, curB);
    if (va === null || vb === null) break;
    const d = Math.abs(va - vb);
    if (d) differing += 1;
    sumAbs[c] += d; if (d > maxAbs[c]) maxAbs[c] = d;
    samples += 1; c = (c + 1) % channels;
  }
  const per = samples / channels || 1;
  const full = bits === 8 ? 255 : 65535;
  return {
    samples_compared: samples,
    differing_samples_pct: +(100 * differing / (samples || 1)).toFixed(3),
    mean_abs_diff_rgb_pct: sumAbs.slice(0, 3)
      .map((v) => +(100 * v / per / full).toFixed(4)),
    max_abs_diff_rgb_pct: maxAbs.slice(0, 3)
      .map((v) => +(100 * v / full).toFixed(3)),
  };
}

tool("compare_stills",
  "Compare two exported still files by bytes and (for uncompressed TIFFs "
  + "of matching size/depth) by pixels: % of samples differing, mean and "
  + "max per-channel difference as % of full scale. Use this to verify "
  + "whether two grabs are the same image — e.g. the graded vs pre_grade "
  + "honesty check — instead of guessing from file sizes.",
  { path_a: { type: "string", description: "First file (absolute path)." },
    path_b: { type: "string", description: "Second file (absolute path)." } },
  ["path_a", "path_b"], async (state, a) => {
    let bufA, bufB;
    try { bufA = fs.readFileSync(String(a.path_a)); }
    catch (e) { throw new ResolveError("Cannot read " + a.path_a + ": "
                                       + e.message); }
    try { bufB = fs.readFileSync(String(a.path_b)); }
    catch (e) { throw new ResolveError("Cannot read " + a.path_b + ": "
                                       + e.message); }
    const out = { size_a: bufA.length, size_b: bufB.length,
                  byte_identical: bufA.length === bufB.length
                                  && bufA.equals(bufB) };
    if (!out.byte_identical)
      out.pixel_stats = tiffDiffStats(bufA, parseTiff(bufA),
                                      bufB, parseTiff(bufB));
    out.verdict = out.byte_identical
      ? "byte-identical: the exact same image"
      : (out.pixel_stats && out.pixel_stats.differing_samples_pct === 0
         ? "same pixels, different bytes (metadata differs)"
         : "images differ");
    return out;
  });

tool("compare_grades",
  "Head-to-head scoring of grade VERSIONS on one clip against a reference "
  + "clip (e.g. a 'Colourlab' version vs a 'Claude' version, made by "
  + "Colour page > Local Versions). Loads each named version in turn, "
  + "grabs the clip, scores it, then restores the version that was active. "
  + "Same source content (a duplicate of the reference clip, or the same "
  + "media and frame) gives per-pixel ΔE2000 (mean/p95, under 1 invisible); "
  + "different shots of a scene give a distribution distance (levels, "
  + "curves, chroma, hue overlap, skin angle; lower is closer) because "
  + "per-pixel ΔE between different content means nothing. mode auto "
  + "picks by media identity; force it with mode pixel|stats. Nothing is "
  + "changed on the clip except the active version, which is put back.",
  { reference: { type: "number", description: "1-based track position of the reference clip." },
    target: { type: "number", description: "1-based track position of the clip that carries the versions." },
    versions: { type: "array", items: { type: "string" }, description: "Local version names to score (default: every local version on the target)." },
    track: { type: "number", description: "Video track (default 1)." },
    mode: { type: "string", enum: ["auto", "pixel", "stats"], description: "auto (default), pixel = per-pixel ΔE2000, stats = distribution distance." },
    out_dir: { type: "string", description: "Grab directory; default /tmp." } },
  ["reference", "target"], async (state, a) => {
    const tl = timeline(state);
    const items = tl.GetItemListInTrack("video", Number(a.track) || 1) || [];
    const refItem = items[Number(a.reference) - 1], tgtItem = items[Number(a.target) - 1];
    if (!refItem || !tgtItem) throw new ResolveError("Track has " + items.length + " clips; reference/target must be 1-based positions on it.");
    if (refItem === tgtItem) throw new ResolveError("Reference and target are the same clip — compare a duplicate or another shot.");
    if (typeof tgtItem.LoadVersionByName !== "function" || typeof tgtItem.GetVersionNameList !== "function"
        || typeof tgtItem.GetCurrentVersion !== "function")
      throw new ResolveError("This Resolve exposes no complete version API on timeline items (LoadVersionByName / "
        + "GetVersionNameList / GetCurrentVersion) — without it the active version could not be put back afterwards.");
    const available = tgtItem.GetVersionNameList(0) || [];
    const wanted = Array.isArray(a.versions) && a.versions.length ? a.versions.map(String) : available.slice();
    const missing = wanted.filter((v) => !available.includes(v));
    if (missing.length) throw new ResolveError("No local version named " + missing.join(", ") + " on " + tgtItem.GetName() + "; it has: " + (available.join(", ") || "none") + ".");
    if (!wanted.length) throw new ResolveError(tgtItem.GetName() + " has no local versions to compare.");
    const current = tgtItem.GetCurrentVersion();
    if (!current || !current.versionName)
      throw new ResolveError("GetCurrentVersion returned nothing for " + tgtItem.GetName() + " — cannot promise to restore the active version, so nothing was loaded.");
    // Same content = same media (unique id, else file path, else name) AND
    // the same SOURCE mid-frame, which is what each grab measures.
    const mediaKey = (it) => { const mp = it.GetMediaPoolItem && it.GetMediaPoolItem(); if (!mp) return null;
      try { if (typeof mp.GetUniqueId === "function") { const u = mp.GetUniqueId(); if (u) return "id:" + u; } } catch (e) {}
      try { const fp = mp.GetClipProperty && mp.GetClipProperty("File Path"); if (fp) return "path:" + fp; } catch (e) {}
      return mp.GetName ? "name:" + mp.GetName() : null; };
    const srcMid = (it) => (it.GetLeftOffset ? it.GetLeftOffset() : 0) + Math.floor((Number(it.GetDuration()) || 2) / 2);
    const sameMedia = mediaKey(refItem) !== null && mediaKey(refItem) === mediaKey(tgtItem) && srcMid(refItem) === srcMid(tgtItem);
    const mode = a.mode && a.mode !== "auto" ? String(a.mode) : (sameMedia ? "pixel" : "stats");
    const ref = await measureItem(state, refItem, a, { no_proxy: true });
    const refBuf = fs.readFileSync(ref.file), refInfo = parseTiff(refBuf);
    const out = { reference: refItem.GetName(), target: tgtItem.GetName(), mode,
      why_mode: mode === "pixel" ? (sameMedia ? "same media and source frame: per-pixel ΔE2000 is meaningful" : "forced: only meaningful if both grabs show the same content")
        : "different shots: distribution distance (per-pixel ΔE between different content would be noise)",
      results: [] };
    try {
      for (const name of wanted) {
        const row = { version: name };
        try {
          if (!tgtItem.LoadVersionByName(name, 0)) throw new ResolveError("LoadVersionByName returned false");
          const m = await measureItem(state, tgtItem, a, { no_proxy: true });
          if (mode === "pixel") {
            const buf = fs.readFileSync(m.file);
            row.delta_e = tiffDeltaE(refBuf, refInfo, buf, parseTiff(buf));
            row.score = row.delta_e.mean;
          } else {
            row.distance = statsDistance(ref, m);
            row.score = row.distance.score;
          }
          row.grab = m.file;
        } catch (e) { row.error = e.message; }
        out.results.push(row);
      }
    } finally {
      out.restored = tgtItem.LoadVersionByName(current.versionName, current.versionType === undefined ? 0 : current.versionType)
        ? current.versionName : "FAILED to restore " + current.versionName + " — check the clip's version in the Color page";
    }
    const skipped = out.results.filter((r) => r.delta_e && r.delta_e.skipped);
    if (skipped.length)
      out.note = "Per-pixel ΔE skipped for " + skipped.map((r) => r.version).join(", ") + ": " + skipped[0].delta_e.skipped
        + " — rerun with mode stats, or compare grabs of the same size.";
    const scored = out.results.filter((r) => typeof r.score === "number").sort((x, y) => x.score - y.score);
    if (scored.length) {
      out.ranking = scored.map((r) => r.version + " (" + r.score + ")");
      out.closest = scored[0].version;
      if (scored.length > 1) {
        const gap = scored[1].score - scored[0].score;
        out.verdict = scored[0].version + " is closest to " + refItem.GetName() + (mode === "pixel"
          ? " at ΔE " + scored[0].score + " (" + scored[0].delta_e.reading + "); " + scored[1].version + " is " + gap.toFixed(2) + " ΔE behind"
            + (gap < 0.5 ? " — a tie to the eye." : ".")
          : " (distance " + scored[0].score + " vs " + scored[1].score + "); a gap under 1 is not decisive.");
      }
    }
    return out;
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
  if (needsApproval(state, name, input)) {
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
  parseTiff, tiffCensus, parseExr, effectiveDepthLabel, shrinkProxy,
  parseSonySidecar, tiffStats, matchGate, deriveCdl, displayPctToDi,
  diDecode, diEncode, applyLook, generateCube, detectCuts, styleAggregate,
  fitCdl, balanceEstimate, hueMatchRecipe, writeTiff16, jointStats, runCdlLoop,
  sampleDi, simStats, refineCdl, measureBuffer, measureItem, simHueStats, hueCost, refineHueRecipe, TOLERANCE_PCT,
  labOf, deltaE2000, tiffDeltaE, statsDistance,
  rgbToHsv, hsvToRgb, P_LEVELS, HUE_SECTORS, HUE_BINS, SKIN_LINE_DEG, DI,
  percentile, dropFrameTimecode, timelineLabel, findYtDlp, expandSlash, SLASH_COMMANDS, slashRoute,
  readConfig, writeConfig, geminiKey, CONFIG_FILE, geminiErrorText,
};
