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
  "pipeline_doctor",
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
               description: "Export directory; default /tmp." } },
  [], async (state, a) => {
    const resolve = state.resolve;
    const proj = project(state);
    const tl = timeline(state);
    const format = ["tif", "png"].includes(a.format) ? a.format : "tif";
    let tc = a.timecode ? String(a.timecode) : null;
    if (!tc && a.frame !== undefined && a.frame !== null)
      tc = frameToTimecode(a.frame, tl.GetSetting("timelineFrameRate"));

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
      for (let i = 0; i < 10 && tl.GetCurrentTimecode() !== tc; i++)
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
        for (let i = 0; i < 10; i++) {
          readback = grabTl.GetCurrentTimecode();
          if (readback === dest) break;
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
                   parked: readback === dest };
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
        proxyPath = format === "png" ? measurePath
          : await exportOneStill(album, still, dir, "claude_p" + stamp, "png");
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
    let min = -1, max = -1, sum = 0, n = 0;
    for (let v = 0; v <= full; v++) {
      const k = h[v];
      if (!k) continue;
      if (min < 0) min = v;
      max = v; sum += v * k; n += k;
    }
    let lo = 0, hi = 0;
    const loEnd = Math.round(full * 0.01), hiStart = Math.round(full * 0.99);
    for (let v = 0; v <= loEnd; v++) lo += h[v];
    for (let v = hiStart; v <= full; v++) hi += h[v];
    const pct = (x) => +(100 * x / (n || 1)).toFixed(3);
    out.channels.push({
      min, max,
      mean_pct: +((100 * sum) / (n || 1) / full).toFixed(2),
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
          timecode: frameToTimecode(mid, tlFps),
          format: "tif", pre_grade: preGrade,
          out_dir: a.out_dir,
        });
        delete grab._images;               // numbers only; proxies stay on disk
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
    const exposureModel = rcm
      ? (/gamma 2\.4/i.test(outSpace) ? "gamma24" : "percent")
      : (clips.some((c) => c.slog3) ? "slog3" : "percent");
    const stopsFrom = (level) => {
      if (median === null || !level) return null;
      if (exposureModel === "gamma24")
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
                   + (exposureModel === "gamma24"
                      ? "via output gamma 2.4" : "S-Log3 slope") + ")"
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
  parseSonySidecar, tiffStats,
};
