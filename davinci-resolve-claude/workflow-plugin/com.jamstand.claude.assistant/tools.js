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
  "pipeline_doctor", "study_edit",
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
      const dirs = [String(a.out_dir || (process.platform === "win32"
                                         ? os.tmpdir() : "/tmp")),
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
    });
  }
  return out;
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

tool("match_shot",
  "Phase 4: match one clip's colour to a reference clip using per-channel "
  + "Reinhard statistics (mean/stddev) computed in the CDL's own working "
  + "space (DaVinci Intermediate log, estimated from display-referred "
  + "grabs and refined by a measure-apply-regrab loop). Writes the result "
  + "as CDL slope/offset on ONE node of the target (power 1, saturation "
  + "1) — non-destructive, revert values included, every write logged to "
  + "a JSON sidecar. REFUSES to match shots in different exposure or "
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
    const grabEntry = TOOLS.find((t) => t.name === "grab_still");
    const midFrame = (item) => item.GetStart()
      + Math.floor((Number(item.GetDuration()) || 2) / 2);
    const measure = async (item) => {
      const g = await grabEntry.fn(state, { frame: midFrame(item),
                                            format: "tif",
                                            out_dir: a.out_dir });
      const buf = fs.readFileSync(g.measurement_file);
      const st = tiffStats(buf, parseTiff(buf));
      if (!st.channels)
        throw new ResolveError("Could not measure " + item.GetName() + ": "
                               + (st.skipped || "no stats"));
      return { stats: st.channels, proxy: (g._images || [])[0],
               file: g.measurement_file };
    };

    const ref = await measure(refItem);
    let tgt = await measure(tgtItem);
    const gate = matchGate(ref.stats, tgt.stats);
    const out = { reference: refItem.GetName(), target: tgtItem.GetName(),
                  gate };
    if (gate.refuse) {
      out.refused = true;
      out._images = [ref.proxy, tgt.proxy].filter(Boolean);
      return out;                       // nothing written, and we say why
    }

    let cdl = deriveCdl(ref.stats, tgt.stats);
    out.proposed_cdl = { node: nodeIndex, slope: cdlStr(cdl.slope),
                         offset: cdlStr(cdl.offset), power: "1 1 1",
                         saturation: "1" };
    if (a.dry_run) {
      out.dry_run = true;
      out._images = [ref.proxy, tgt.proxy].filter(Boolean);
      return out;
    }

    const iterations = [];
    const maxIter = Math.min(5, Math.max(1, Number(a.max_iterations) || 3));
    for (let i = 1; i <= maxIter; i++) {
      const okWrite = tgtItem.SetCDL({
        NodeIndex: String(nodeIndex), Slope: cdlStr(cdl.slope),
        Offset: cdlStr(cdl.offset), Power: "1 1 1", Saturation: "1" });
      if (!okWrite)
        throw new ResolveError("SetCDL returned false on node " + nodeIndex
          + " of " + tgtItem.GetName() + " (iteration " + i + ").");
      tgt = await measure(tgtItem);
      const resid = ref.stats.map((rc, c) =>
        +(rc.mean_pct - tgt.stats[c].mean_pct).toFixed(2));
      iterations.push({ iteration: i,
        cdl: { slope: cdlStr(cdl.slope), offset: cdlStr(cdl.offset) },
        residual_mean_pct_rgb: resid });
      if (Math.max.apply(null, resid.map(Math.abs)) < 0.75) break;
      // Compose the residual correction onto the running CDL.
      const corr = deriveCdl(ref.stats, tgt.stats);
      cdl = { slope: cdl.slope.map((sl, c) => Math.min(4, Math.max(0.25,
                sl * corr.slope[c]))),
              offset: cdl.offset.map((of, c) =>
                of * corr.slope[c] + corr.offset[c]) };
    }
    out.iterations = iterations;
    out.final_cdl = iterations[iterations.length - 1].cdl;
    out.final_residual_mean_pct_rgb =
      iterations[iterations.length - 1].residual_mean_pct_rgb;
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

// Slash commands: prompt macros the panel expands before the model sees
// them. The transcript shows what the user typed; the model receives the
// expanded marching orders.
function expandSlash(text) {
  const t = String(text || "").trim();
  if (!/^\/study\b/i.test(t)) return null;
  const urls = t.match(/https?:\/\/\S+/g) || [];
  if (!urls.length)
    return "The user typed /study without links. Explain briefly: "
      + "/study <link> [<link> ...] downloads each video (TikTok, "
      + "Instagram, YouTube), builds a study timeline, and analyses it "
      + "into the car-edits style profile.";
  return "Study these " + urls.length + " edit(s) into the car-edits "
    + "style profile, STRICTLY one at a time:\n"
    + urls.map((u, i) => (i + 1) + ". " + u).join("\n")
    + "\nFor each link in order: call study_url with it; once the study "
    + "timeline is current, call study_edit and keep resuming with "
    + "next_start_frame until that edit reports complete; then move to "
    + "the next link. If one link fails, say why and continue with the "
    + "rest. Finish with the profile aggregate and a plain-English "
    + "read of what it says about the style.";
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
  diDecode, applyLook, generateCube, detectCuts, styleAggregate,
  percentile, dropFrameTimecode, timelineLabel, findYtDlp, expandSlash,
  readConfig, writeConfig, geminiKey, CONFIG_FILE,
};
