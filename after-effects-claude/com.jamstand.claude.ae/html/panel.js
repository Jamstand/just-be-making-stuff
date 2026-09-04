// Claude Assistant for After Effects — panel logic (CEP 12, Node 17 via
// --enable-nodejs --mixed-context). One context: this file provides the
// `assistant` API that app.js (shared with the Resolve plugin) consumes,
// plus the CLI turn runner, the MCP TCP bridge, the AE tool registry
// (dispatching into host/ae-tools.jsx via CSInterface.evalScript), and
// approvals/history.
"use strict";
/* global CSInterface, SystemPath */

// CEP runs every <script> of the panel in ONE shared page scope (unlike
// Electron, where main and renderer are separate processes). Top-level
// let/const here would collide with app.js — live launch #3 died on
// "Identifier 'busy' has already been declared" before app.js could parse.
// Everything lives inside this IIFE; only window.assistant is exposed.
(function () {

// A silent panel is the worst failure mode. If CEP ignored --enable-nodejs
// (or --mixed-context), `require` does not exist and nothing below can run:
// say so on screen instead of leaving an empty top bar.
if (typeof require !== "function") {
  const chat = document.getElementById("chat");
  const box = document.createElement("div");
  box.className = "card error";
  box.textContent = "Node.js is not available in this panel: CEP did not "
    + "honour the manifest's --enable-nodejs/--mixed-context flags, so the "
    + "assistant cannot start. Check ~/Library/Logs/CSXS/CEP12-AEFT.log "
    + "and the CSXS/manifest.xml CEFCommandLine block.";
  if (chat) chat.appendChild(box);
  throw new Error("CEP Node runtime missing");
}

const fs = require("fs");
const os = require("os");
const path = require("path");
const net = require("net");
const crypto = require("crypto");
const { spawn, execFile } = require("child_process");

const cs = new CSInterface();
// Without this, ⌘C/⌘V/⌘X/⌘A go to After Effects' own Edit menu and the
// panel never sees them (CEP registerKeyEventsInterest, since 6.1).
try {
  const keys = [];
  for (const keyCode of [65, 67, 86, 88])                // A C V X
    for (const mod of ["metaKey", "ctrlKey"]) {
      const k = { keyCode }; k[mod] = true; keys.push(k);
    }
  cs.registerKeyEventsInterest(JSON.stringify(keys));
} catch (e) {}
// Node's __dirname is not a reliable global inside a CEP page script; CEP's
// own API knows where the extension lives (doc-verified SystemPath).
const EXT_ROOT = (function () {
  try { const p = cs.getSystemPath(SystemPath.EXTENSION); if (p) return p; }
  catch (e) {}
  return typeof __dirname === "string" ? path.join(__dirname, "..") : ".";
})();
const historyLib = require(path.join(EXT_ROOT, "history.js"));
const track = require(path.join(EXT_ROOT, "tracklib.js"));
const MOCHA_SCRIPT = path.join(EXT_ROOT, "host", "mocha_job.py");
const USER_DATA = path.join(os.homedir(), "Library", "Application Support",
                            "ClaudeAssistantAE");
fs.mkdirSync(USER_DATA, { recursive: true });

const MODELS = ["claude-opus-5", "claude-fable-5", "claude-sonnet-5",
                "claude-haiku-4-5"];
const EFFORTS = ["low", "medium", "high", "xhigh", "max"];
const PERMISSION_MODES = ["Ask before edits", "Always ask", "Never ask"];
const APPROVAL_TIMEOUT_MS = 120000;

const SYSTEM_PROMPT = [
  "You drive Adobe After Effects for an editor through the mcp__ae__*",
  "tools. run_extendscript is the escape hatch: the full AE scripting DOM",
  "(app.project, CompItem, layers, properties). ES3 ONLY in that code —",
  "var, no arrow functions, no const/let, no template strings, no JSON",
  "object. Hard walls, say so instead of guessing: AE's OWN analysis",
  "(Track Motion, 3D camera tracker, Warp Stabilizer, Mask Tracker) cannot",
  "be started by script. Tracking itself is NOT a wall: mocha_track runs",
  "Mocha Pro's planar tracker headless and lands native mask / Corner Pin",
  "/ Transform keyframes (mocha_status once, then layer_info +",
  "grab_source_frame to pick the region in SOURCE pixels); ai_segment",
  "fetches a SAM 3 object",
  "matte from fal.ai (paid; set_fal_key; dry_run quotes the cost first).",
  "Chats do not share memory but the PROJECT persists: masks, Corner Pins",
  "and layers you do not remember are almost always an earlier chat's work",
  "— call track_history before touching them, and never rebuild or delete",
  "keyframes you did not create in THIS chat without asking. Name what you",
  "add (masks 'Mocha <range>', effects 'Corner Pin (Mocha <range>)').",
  "Output codecs are template-only (no",
  "field-by-field codec settings); Lumetri parameter names are not",
  "documented — apply_effect returns each effect's real property list, use",
  "it. Times are SECONDS. Layer indexes are 1-based, top of stack = 1;",
  "add_clip appends to the bottom. What IS fully scriptable, unlike",
  "DaVinci: speed ramps (speed_ramp / ADBE Time Remapping + eases), masks,",
  "text layers, every effect parameter, per-keyframe animation.",
  "The panel may pause a modifying tool call for the user's approval; if",
  "declined or timed out, never retry unchanged. Be concise: lead with",
  "the result.",
].join(" ");

// ------------------------------------------------------------ host bridge
function evalHost(name, args) {
  return new Promise((resolveP, rejectP) => {
    const call = "CA_invoke(" + JSON.stringify(name) + ","
      + JSON.stringify(JSON.stringify(args || {})) + ")";
    cs.evalScript(call, (raw) => {
      if (raw === "EvalScript error." || raw === undefined || raw === null)
        return rejectP(new Error("ExtendScript failed opaquely (EvalScript "
          + "error) — usually a host-side syntax problem or AE busy."));
      let parsed;
      try { parsed = JSON.parse(raw); }
      catch (e) { return rejectP(new Error("Unparseable host reply: "
        + String(raw).slice(0, 200))); }
      if (!parsed.ok) return rejectP(new Error(parsed.error || "host error"));
      resolveP(parsed.data);
    });
  });
}

// Downscale a grabbed PNG through the panel's own canvas (CEP is Chromium)
// so vision attachments stay small — no Electron nativeImage here.
function shrinkPng(filePath) {
  return new Promise((resolveP) => {
    try {
      const img = new Image();
      img.onload = () => {
        const w = Math.min(1280, img.width);
        const h = Math.round(img.height * (w / img.width));
        const canvas = document.createElement("canvas");
        canvas.width = w; canvas.height = h;
        canvas.getContext("2d").drawImage(img, 0, 0, w, h);
        const dataUrl = canvas.toDataURL("image/jpeg", 0.8);
        resolveP({ data: dataUrl.split(",")[1], media_type: "image/jpeg" });
      };
      img.onerror = () => resolveP(null);
      img.src = "file://" + filePath;
    } catch (e) { resolveP(null); }
  });
}

// ---------------------------------------------------------- clipboard
// The system clipboard via the OS tool: CEF's own copy path is not
// reliable inside a CEP panel, and a Node child process always is.
// null when the tool is missing, so app.js knows to fall back.
const clipboardApi = !findBinary(process.platform === "darwin" ? ["pbcopy"]
    : process.platform === "win32" ? ["powershell.exe", "powershell"]
    : ["xclip"], []) ? null : {
  write(text) {
    return new Promise((resolve, reject) => {
      const cmd = process.platform === "darwin" ? ["pbcopy", []]
        : process.platform === "win32"
          ? ["powershell", ["-NoProfile", "-Command",
             "[Console]::InputEncoding=[Text.Encoding]::UTF8; " +
             "Set-Clipboard -Value ([Console]::In.ReadToEnd())"]]
          : ["xclip", ["-selection", "clipboard"]];
      const p = spawn(cmd[0], cmd[1], { stdio: ["pipe", "ignore", "ignore"] });
      p.on("error", reject);
      p.on("close", (code) => code === 0 ? resolve(true)
        : reject(new Error(cmd[0] + " exited " + code)));
      p.stdin.on("error", () => {});
      p.stdin.end(String(text), "utf8");
    });
  },
  read() {
    return new Promise((resolve, reject) => {
      const cmd = process.platform === "darwin" ? ["pbpaste", []]
        : process.platform === "win32"
          ? ["powershell", ["-NoProfile", "-Command",
             "[Console]::OutputEncoding=[Text.Encoding]::UTF8; " +
             "Get-Clipboard -Raw"]]
          : ["xclip", ["-selection", "clipboard", "-o"]];
      execFile(cmd[0], cmd[1], { encoding: "utf8", maxBuffer: 64 << 20 },
        (err, out) => err ? reject(err) : resolve(out));
    });
  },
};

// ------------------------------------------------------------ tool registry
const TOOLS = [];
function tool(name, description, params, required, opts, fn) {
  TOOLS.push({ name, description, params: params || {},
               required: required || [], readonly: !!(opts && opts.readonly),
               fn: fn || ((state, a) => evalHost(name, a)) });
}

tool("get_project_overview",
  "Project items, comps (size/fps/duration/layers), the active comp, and "
  + "whether AE's 'Allow Scripts to Write Files and Access Network' pref "
  + "is on (grab_frame and render need it).", {}, [], { readonly: true });

tool("import_media", "Import absolute file paths into the project.",
  { paths: { type: "array", items: { type: "string" },
             description: "Absolute paths." } }, ["paths"], {});

tool("create_comp", "Create a comp and open it in the viewer.",
  { name: { type: "string" }, width: { type: "number" },
    height: { type: "number" }, fps: { type: "number" },
    duration_s: { type: "number" } }, [], {});

tool("add_clip",
  "Add a footage item as a layer: in/out in SOURCE seconds, start_s where "
  + "the cut lands in comp time. Appends beneath existing layers.",
  { item_name: { type: "string" }, comp: { type: "string" },
    start_s: { type: "number" }, in_s: { type: "number" },
    out_s: { type: "number" } }, ["item_name"], {});

tool("speed_ramp",
  "The move Resolve can't do: time-remap a layer with velocity keyframes. "
  + "keys: [{at_s: comp time, source_s: source time, ease_speed, "
  + "ease_influence (0.1-100)}] — a ramp = uneven source spacing; ease "
  + "shapes the acceleration curve.",
  { layer: { type: "number" }, comp: { type: "string" },
    keys: { type: "array", items: { type: "object" } } },
  ["layer", "keys"], {});

tool("set_keyframes",
  "Keyframe (or statically set) any property by match-name path, e.g. "
  + "path [\"ADBE Transform Group\",\"ADBE Scale\"], keys "
  + "[{at_s, value}]. hold:true = hold interpolation.",
  { layer: { type: "number" }, comp: { type: "string" },
    path: { type: "array", items: { type: "string" } },
    keys: { type: "array", items: { type: "object" } },
    hold: { type: "boolean" } }, ["layer", "path", "keys"], {});

tool("apply_effect",
  "Apply any effect by matchName ('ADBE Lumetri', 'ADBE Gaussian Blur 2', "
  + "'CC Force Motion Blur'...) or display name, optionally setting "
  + "properties. The result lists the effect's REAL property names — "
  + "iterate with those instead of guessing (Lumetri's are undocumented).",
  { layer: { type: "number" }, comp: { type: "string" },
    effect: { type: "string" }, settings: { type: "object" } },
  ["layer", "effect"], {});

tool("add_text",
  "Add a styled text layer (font = PostScript name, color = [r,g,b] 0-1).",
  { text: { type: "string" }, font: { type: "string" },
    size: { type: "number" }, color: { type: "array" },
    tracking: { type: "number" }, position: { type: "array" },
    start_s: { type: "number" }, duration_s: { type: "number" },
    comp: { type: "string" } }, ["text"], {});

tool("add_mask",
  "Draw a mask on a layer: vertices [[x,y]...] in layer pixels, optional "
  + "feather (px), inverted, mode 'subtract'. Static: for a mask that "
  + "FOLLOWS a subject use mocha_track (exports 'mask') or ai_segment.",
  { layer: { type: "number" }, comp: { type: "string" },
    vertices: { type: "array" }, feather: { type: "number" },
    inverted: { type: "boolean" }, closed: { type: "boolean" },
    mode: { type: "string" } }, ["layer", "vertices"], {});

async function finishGrab(data, extra) {
  const done = await track.waitForPng(data.file, 30000);
  const out = Object.assign({ file: data.file, bytes: done.bytes,
                              waited_ms: done.waited_ms }, extra);
  const img = await shrinkPng(data.file);
  if (img) out._images = [img];
  else out.note = "frame saved but could not be downscaled for vision";
  return out;
}

tool("grab_frame",
  "Export the COMP frame at time_s as PNG and SEE it (downscaled JPEG to "
  + "vision). Renders the whole layer stack — slow on heavy comps; to look "
  + "at one layer's footage use grab_source_frame.",
  { time_s: { type: "number" }, comp: { type: "string" } }, [],
  { readonly: true },
  async (state, a) => {
    const data = await evalHost("grab_frame", a);
    return finishGrab(data, { time_s: data.time_s, comp: data.comp });
  });

tool("grab_source_frame",
  "SEE one layer's SOURCE footage at source_time_s, rendered alone (a "
  + "throwaway comp that is removed afterwards) — the right way to pick a "
  + "tracking region: what you see is in source pixels, unobscured by the "
  + "layers above. source_time_s = comp time − layer start (see layer_info).",
  { layer: { type: "number" }, comp: { type: "string" },
    source_time_s: { type: "number" } }, ["layer"], { readonly: true },
  async (state, a) => {
    const data = await evalHost("grab_source_frame", a);
    try {
      return await finishGrab(data, { source: data.source, width: data.width,
        height: data.height, source_time_s: data.source_time_s,
        coordinates: "source pixels, origin top-left — pass these to "
          + "mocha_track's shape as-is" });
    } finally {
      try { await evalHost("remove_temp_comp", { name: data.temp_comp }); }
      catch (e) { /* the comp is named __ClaudeGrab__; a later call sweeps it */ }
    }
  });

tool("list_render_templates",
  "Available render-settings and output-module template names (codecs are "
  + "template-only via script).",
  { comp: { type: "string" } }, [], { readonly: true });

tool("render",
  "Render the comp: om_template/rs_template from list_render_templates, "
  + "output = absolute file path. use_ame queues in Media Encoder instead "
  + "(returns immediately); otherwise BLOCKS until done.",
  { comp: { type: "string" }, om_template: { type: "string" },
    rs_template: { type: "string" }, output: { type: "string" },
    use_ame: { type: "boolean" } }, ["output"], {});

tool("run_extendscript",
  "Escape hatch: run arbitrary ExtendScript in AE (full scripting DOM). "
  + "ES3 ONLY — var, no arrows/const/let/JSON/template strings. The last "
  + "expression's value returns (keep it small and JSON-safe).",
  { code: { type: "string" } }, ["code"], {});


// ------------------------------------------------------ tracking bridge
// AE's own trackers stay unscriptable; these go around the wall with
// Mocha Pro's Python (host/mocha_job.py) and fal.ai's SAM 3.
function bbox(points) {
  let minx = Infinity, miny = Infinity, maxx = -Infinity, maxy = -Infinity;
  for (const [x, y] of points) {
    minx = Math.min(minx, x); miny = Math.min(miny, y);
    maxx = Math.max(maxx, x); maxy = Math.max(maxy, y);
  }
  return { minx, miny, maxx, maxy };
}

function requireFile(info) {
  if (!info.source || !info.source.file)
    throw new Error("Layer '" + info.layer + "' has no footage file behind "
      + "it (solid, text, shape or precomp) — track the footage layer, or "
      + "pre-render this one and track the render.");
  if (info.source.is_still)
    throw new Error("The source is a still image — nothing moves.");
  return info.source.file;
}

// Every applied track leaves a line in history.jsonl so a LATER chat (no
// memory of this one) can tell its own earlier work from damage.
const HISTORY_FILE = path.join(USER_DATA, "mocha", "history.jsonl");
function recordTrack(entry) {
  try {
    fs.mkdirSync(path.dirname(HISTORY_FILE), { recursive: true });
    fs.appendFileSync(HISTORY_FILE, JSON.stringify(Object.assign(
      { at: new Date().toISOString() }, entry)) + "\n");
  } catch (e) {}
}
function readHistory(limit) {
  try {
    return fs.readFileSync(HISTORY_FILE, "utf8").trim().split("\n")
      .filter(Boolean).map((l) => { try { return JSON.parse(l); } catch (e) { return null; } })
      .filter(Boolean).slice(-(limit || 20));
  } catch (e) { return []; }
}
// Run folders are the durable record (history.jsonl only started later):
// each holds job.json, the exports, mocha.log and the .mocha project.
function runFolders(limit) {
  const root = path.join(USER_DATA, "mocha");
  let names = [];
  try { names = fs.readdirSync(root).filter((n) => /^\d{4}-\d{2}-\d{2}T/.test(n)); }
  catch (e) { return []; }
  return names.sort().slice(-(limit || 20)).map((n) => {
    const dir = path.join(root, n);
    let job = {};
    try { job = JSON.parse(fs.readFileSync(path.join(dir, "job.json"), "utf8")); } catch (e) {}
    let files = [];
    try { files = fs.readdirSync(dir).filter((f) => /\.(txt|shape4ae|mocha)$/.test(f)); } catch (e) {}
    return { folder: dir, at: n, action: job.action, footage: job.footage,
      frames: job.start_frame !== undefined ? [job.start_frame, job.end_frame] : null,
      fps: job.fps || null, exports: job.exports || null, files,
      shape_bbox: Array.isArray(job.shape) && job.shape.length ? (() => {
        const xs = job.shape.map((p) => p.x), ys = job.shape.map((p) => p.y);
        return [Math.round(Math.min(...xs)), Math.round(Math.min(...ys)),
                Math.round(Math.max(...xs)), Math.round(Math.max(...ys))]; })() : null };
  });
}

async function applyExport(a, info, kind, file, out) {
  const fps = (info.source && info.source.fps) || info.comp_fps;
  const offset = a.time_offset_s !== undefined ? Number(a.time_offset_s)
                                               : info.start_s;
  const stretch = info.stretch || 100;
  const text = fs.readFileSync(file, "utf8");
  if (/Keyframe Data/i.test(text.split("\n")[0])) {
    const shapes = track.parseMochaShapeText(text);
    if (shapes) {
      // Mask export: native mask keyframes, chunked so no single
      // evalScript carries 150 frames × 64 vertices.
      if (shapes.fps && Math.abs(shapes.fps - fps) > 0.01)
        (out.warnings = out.warnings || []).push(kind + ": export header says "
          + shapes.fps + " fps, source is " + fps + " — using the source rate");
      const results = [];
      shapes.shapes.forEach((sh, si) => { sh.maskName = (a.mask_name
        || ("Mocha " + (out.label || "mask")))
        + (shapes.shapes.length > 1 ? " " + (si + 1) : ""); });
      for (const sh of shapes.shapes) {
        let r = null;
        for (let i = 0; i < sh.frames.length; i += 40)
          r = await evalHost("apply_mask_keyframes", { layer: a.layer, comp: a.comp,
            name: sh.maskName, fps, time_offset_s: offset, stretch,
            frames: sh.frames.slice(i, i + 40), append: i > 0,
            mode: a.mask_mode, feather: a.mask_feather, inverted: !!a.mask_inverted,
            roto_bezier: a.roto_bezier !== false });
        results.push(r);
        out.mask_report = track.maskReport(sh.frames, shapes.width || info.source.width,
                                           shapes.height || info.source.height, fps);
      }
      out.applied.push({ kind, file, result: results.length === 1 ? results[0] : results,
        note: "native mask keyframes from Mocha's shape export ("
          + shapes.shapes[0].frames[0].points.length + " vertices/frame"
          + (a.roto_bezier !== false ? ", RotoBezier smoothing" : "") + ")" });
      return;
    }
    const parsed = track.parseAeKeyframeText(text);
    // Frames are frames; the header's rate is only Mocha's belief (live it
    // said 24 for 59.94 footage), so the SOURCE rate converts to seconds.
    if (parsed.fps && Math.abs(parsed.fps - fps) > 0.01)
      (out.warnings = out.warnings || []).push(kind + ": export header says "
        + parsed.fps + " fps, source is " + fps + " — using the source rate");
    let blocks = parsed.blocks;
    if (out.surface && /pin/.test(kind)) {
      const r = track.retargetCornerPin(blocks, out.surface);
      blocks = r.blocks;
      out.corner_pin_retargeted = r.retargeted ? "to the requested surface ("
        + r.frames + " frames" + (r.skipped ? ", " + r.skipped + " degenerate skipped" : "")
        + ")" : "no: " + r.reason;
    }
    if (/pin/.test(kind) && info.source)
      out.track_report = track.trackReport(parsed.blocks, info.source.width,
                                           info.source.height, fps);
    const r = await evalHost("apply_keyframe_data", { layer: a.layer,
      comp: a.comp, fps, blocks, time_offset_s: offset, stretch,
      effect_name: a.effect_name || (/pin/.test(kind) && out.label
        ? "Corner Pin (Mocha " + out.label + ")" : undefined) });
    out.applied.push({ kind, file, result: r });
    return;
  }
  if (!clipboardApi)
    throw new Error("No clipboard route (pbcopy missing): 'Paste Mocha "
      + "mask' needs the shape data on the clipboard. The file is at "
      + file);
  await clipboardApi.write(text);
  const expect = offset + ((out.start_frame || 0) / fps) * stretch / 100;
  const at = a.mask_paste_at === "track_start" ? expect : offset;
  const r = await evalHost("paste_mocha_mask", { layer: a.layer,
    comp: a.comp, time_s: at });
  out.applied.push({ kind, file, result: r, cti_at_s: at,
    check: "mask keys should start near " + expect.toFixed(3) + "s comp "
      + "time; if they landed elsewhere, re-run with mask_paste_at "
      + "'track_start'" });
}

async function mochaTrack(state, a) {
  const info = await evalHost("layer_info", { layer: a.layer, comp: a.comp });
  const footage = requireFile(info);
  const fps = info.source.fps || info.comp_fps;
  let shape = Array.isArray(a.shape) ? a.shape : null;
  if ((!shape || shape.length < 3) && Array.isArray(a.rect) && a.rect.length === 4) {
    const [x, y, w, h] = a.rect.map(Number);
    shape = [[x, y], [x + w, y], [x + w, y + h], [x, y + h]];
  }
  if (!shape || shape.length < 3)
    throw new Error("Give shape (3+ [x,y] points) or rect [x,y,w,h], in SOURCE pixels.");
  shape = shape.map((p) => [Number(p[0]), Number(p[1])]);
  if (shape.some((p) => isNaN(p[0]) || isNaN(p[1])))
    throw new Error("shape points must be numeric [x,y] pairs.");
  const startS = a.start_s !== undefined ? Number(a.start_s) : info.source_in_s;
  const endS = a.end_s !== undefined ? Number(a.end_s) : info.source_out_s;
  const startF = Math.max(0, Math.round(startS * fps));
  const endF = Math.max(startF, Math.round(endS * fps) - 1);
  const found = track.findMochaPython();
  if (!found.length)
    throw new Error("Mocha Pro's python3 was not found — run mocha_status.");
  const wanted = (Array.isArray(a.exports) && a.exports.length) ? a.exports
                                                                : ["mask", "corner_pin"];
  const bad = wanted.filter((k) => !["mask", "corner_pin",
    "corner_pin_motion_blur", "power_pin", "transform"].includes(k));
  if (bad.length) throw new Error("Unknown exports: " + bad.join(", "));
  const b = bbox(shape);
  const surface = (Array.isArray(a.surface) && a.surface.length === 4) ? a.surface
    : [[b.minx, b.miny], [b.maxx, b.miny], [b.maxx, b.maxy], [b.minx, b.maxy]];
  const workdir = path.join(USER_DATA, "mocha",
                            new Date().toISOString().replace(/[:.]/g, "-"));
  sendUI("notice", "Mocha is tracking " + (endF - startF + 1) + " frames of "
    + info.source.name + " (" + found[0].kind + " python) — minutes on long "
    + "shots.", false);
  let data;
  try {
    data = await track.runMochaJob(found[0].python, Object.assign({
      action: "track", footage, project_path: path.join(workdir, "track.mocha"),
      out_dir: workdir, layer_name: a.layer_name || "Claude Track",
      shape: shape.map(([x, y]) => ({ x, y })), surface, fps,
      start_frame: startF, end_frame: endF, exports: wanted,
    }, track.readConfig().mocha_qt || { qt_app: "widgets" }),
    { scriptPath: MOCHA_SCRIPT, workdir, timeoutMs: 45 * 60 * 1000,
      env: track.mochaEnv() });
  } catch (e) { throw new Error(track.explainMochaError(e.message)); }
  const label = (startF / fps).toFixed(1).replace(/\.0$/, "") + "-"
    + ((endF + 1) / fps).toFixed(1).replace(/\.0$/, "") + "s";
  const out = { python: found[0].python, project: data.project, workdir,
    label, source: info.source.name, fps, start_frame: startF, end_frame: endF,
    frames: data.frames, track_seconds: data.track_seconds,
    exports: data.exports, notes: data.notes || [], applied: [], warnings: [],
    surface: { UL: surface[0], UR: surface[1], LR: surface[2], LL: surface[3] } };
  if (info.time_remap)
    out.warnings.push("Layer is time-remapped: keys sit at linear source "
      + "time and will not follow the remap.");
  if (info.stretch && info.stretch !== 100)
    out.warnings.push("Layer stretch " + info.stretch + "% — key times scaled to match.");
  if (a.apply === false) return out;
  for (const kind of wanted) {
    const files = data.exports && data.exports[kind];
    if (!Array.isArray(files)) {
      out.warnings.push(kind + " export failed: " + JSON.stringify(files));
      continue;
    }
    // One export failing to land must not hide the ones that did.
    for (const file of files) {
      try { await applyExport(a, info, kind, file, out); }
      catch (e) { out.applied.push({ kind, file, error: e.message }); }
    }
  }
  recordTrack({ tool: "mocha_track", comp: info.comp, layer: info.layer,
    layer_index: a.layer, source: info.source.name, range_s: label,
    frames: [startF, endF], workdir, exports: wanted,
    applied: out.applied.map((x) => ({ kind: x.kind, result: x.result && (x.result.mask
      || (x.result.applied && x.result.applied.map((y) => y.target).join(", "))), error: x.error })),
    warnings: out.warnings, report: out.track_report || out.mask_report });
  const rep = out.track_report || out.mask_report;
  if (rep && rep.usable_until_frame < rep.last_frame)
    out.warnings.push("Track looks unreliable after " + rep.usable_until_s
      + "s: " + rep.verdict + ". Tighten the shape to textured bodywork or "
      + "shorten end_s.");
  if (rep && (rep.first_frame > startF || rep.last_frame < endF))
    out.warnings.push("Export covers frames " + rep.first_frame + "–"
      + rep.last_frame + " of the requested " + startF + "–" + endF + ".");
  return out;
}

async function applyTrackFile(state, a) {
  if (!a.file || !fs.existsSync(a.file))
    throw new Error("File not found: " + a.file);
  const info = await evalHost("layer_info", { layer: a.layer, comp: a.comp });
  const out = { file: a.file, applied: [], start_frame: 0, warnings: [],
                label: a.label || path.basename(path.dirname(a.file)).slice(0, 19) };
  if (Array.isArray(a.surface) && a.surface.length === 4)
    out.surface = { UL: a.surface[0], UR: a.surface[1], LR: a.surface[2], LL: a.surface[3] };
  const kind = path.extname(a.file).toLowerCase() === ".shape4ae" ? "mask"
             : /corner|pin/i.test(path.basename(a.file)) ? "corner_pin" : "keyframes";
  await applyExport(a, info, kind, a.file, out);
  recordTrack({ tool: "apply_track_file", comp: info.comp, layer: info.layer,
    layer_index: a.layer, source: info.source && info.source.name, file: a.file,
    applied: out.applied.map((x) => ({ kind: x.kind, result: x.result && (x.result.mask
      || (x.result.applied && x.result.applied.map((y) => y.target).join(", "))), error: x.error })) });
  return out;
}

async function aiSegment(state, a) {
  const key = track.readConfig().fal_api_key;
  const info = await evalHost("layer_info", { layer: a.layer, comp: a.comp });
  const file = requireFile(info);
  const ext = path.extname(file).toLowerCase();
  if (![".mp4", ".mov", ".webm", ".m4v", ".gif"].includes(ext))
    throw new Error("fal accepts mp4/mov/webm/m4v/gif; this source is " + ext
      + " — render an H.264 copy (render tool) and segment that.");
  const model = a.model === "sam-3-1" ? "fal-ai/sam-3-1/video" : "fal-ai/sam-3/video";
  const fps = info.source.fps || info.comp_fps || 30;
  const frames = Math.max(1, Math.round((info.source.duration_s || 0) * fps));
  const sizeMb = Math.round(fs.statSync(file).size / 1048576 * 10) / 10;
  const quote = { model, file, frames, size_mb: sizeMb,
    estimated_cost_usd: Math.round((frames / 16)
      * (a.model === "sam-3-1" ? 0.01 : 0.005) * 1000) / 1000,
    note: "fal segments the WHOLE file (not just the layer's in/out) and "
      + "bills per 16 frames." };
  if (a.dry_run) return Object.assign(quote, { key_configured: !!key });
  if (!key)
    throw new Error("No fal.ai key yet — create one at fal.ai/dashboard/keys "
      + "and call set_fal_key.");
  if (!a.prompt && !(a.points && a.points.length) && !(a.boxes && a.boxes.length))
    throw new Error("Say what to segment: prompt (e.g. 'the yellow car'), "
      + "points, or boxes.");
  sendUI("notice", "Uploading " + sizeMb + " MB to fal.ai…", false);
  const videoUrl = await track.falUpload(key, file, {});
  const input = { video_url: videoUrl, prompt: a.prompt || "",
                  apply_mask: a.apply_mask !== false,
                  detection_threshold: a.detection_threshold || 0.5 };
  if (a.points && a.points.length) input.point_prompts = a.points;
  if (a.boxes && a.boxes.length) input.box_prompts = a.boxes;
  if (a.model === "sam-3-1" && a.max_objects) input.max_num_objects = a.max_objects;
  const submitted = await track.falSubmit(key, model, input);
  sendUI("notice", "SAM is working on " + frames + " frames (request "
    + submitted.request_id + ")…", false);
  const result = await track.falWait(key, submitted,
    { onStatus: (s) => sendUI("notice", "fal: " + s, false) });
  const outUrl = result && result.video && result.video.url;
  if (!outUrl)
    throw new Error("fal returned no video: " + JSON.stringify(result).slice(0, 400));
  let outExt = ".mp4";
  try { outExt = path.extname(new URL(outUrl).pathname) || ".mp4"; } catch (e) {}
  const dest = path.join(USER_DATA, "sam", submitted.request_id + outExt);
  await track.download(outUrl, dest);
  const out = Object.assign(quote, { request_id: submitted.request_id,
    result_file: dest, result, applied: null,
    next: "grab_frame the comp: if the matte layer shows the subject cut "
      + "out on black it works as a luma matte; if it is a colour overlay "
      + "on the footage, redo with apply_mask:false or matte:'none'." });
  if (a.apply !== false)
    out.applied = await evalHost("import_and_matte", { layer: a.layer,
      comp: a.comp, file: dest, matte: a.matte || "luma" });
  return out;
}

tool("layer_info",
  "Everything the tracking tools need about a layer: source file on disk, "
  + "source size/fps/duration, start/in/out (comp seconds), source_in_s / "
  + "source_out_s (SOURCE seconds), stretch, time-remap flag, transform.",
  { layer: { type: "number" }, comp: { type: "string" } }, ["layer"],
  { readonly: true });

tool("mocha_status",
  "Find Mocha Pro's bundled python3 (standalone app or the Adobe plug-in "
  + "bundle) and probe it: version and the AE exporters. Run once before "
  + "mocha_track; a license problem shows up here, not mid-track.",
  {}, [], { readonly: true }, async () => {
    const found = track.findMochaPython();
    if (!found.length)
      return { installed: false, looked_in: ["/Applications/Mocha Pro*.app",
        "/Library/Application Support/Adobe/Common/Plug-ins/7.0/MediaCore/"
        + "BorisFX/MochaPro*/Resources/mochaui/*.app"],
        hint: "Set mocha_python in ~/.claude-assistant.json to the python3 "
          + "inside your Mocha app if it lives elsewhere." };
    const workdir = path.join(USER_DATA, "mocha", "probe");
    const env = track.mochaEnv();
    const out = { installed: true, python: found[0].python, kind: found[0].kind,
                  candidates: found, license_env_passed: Object.keys(env) };
    try {
      out.probe = await track.runMochaJob(found[0].python, { action: "probe" },
        { scriptPath: MOCHA_SCRIPT, workdir, timeoutMs: 180000, env });
    } catch (e) {
      out.probe_error = e.message;
      return out;
    }
    // The real gates: RLM checks out a license when a Project is created,
    // and the tracker needs an OpenGL context. Try Qt variants in order
    // until a 3-frame probe track succeeds, then remember the winner.
    const saved = track.readConfig().mocha_qt;
    const variants = [
      saved, { qt_app: "widgets" }, { qt_app: "gui" },
      { qt_app: "widgets", qpa: "offscreen" }, { qt_app: "gui", qpa: "offscreen" },
      { qt_app: "core" },
    ].filter(Boolean).filter((v, i, arr) =>
      arr.findIndex((w) => w.qt_app === v.qt_app && (w.qpa || "") === (v.qpa || "")) === i);
    out.attempts = [];
    for (const v of variants) {
      let lic;
      try {
        lic = await track.runMochaJob(found[0].python,
          Object.assign({ action: "license_check" }, v),
          { scriptPath: MOCHA_SCRIPT, workdir: workdir + "-license",
            timeoutMs: 180000, env });
      } catch (e) {
        out.attempts.push(Object.assign({}, v, { error: e.message.slice(0, 300) }));
        continue;
      }
      out.attempts.push(Object.assign({}, v, { license: lic.license,
        tracking: lic.tracking || null, detail: lic.tracking_detail || lic.detail }));
      out.license = lic.license;
      out.license_detail = lic.detail;
      if (lic.license !== "ok") {
        out.license_help = track.explainMochaError("License checkout failed: "
          + lic.detail + "\n" + (lic.log_tail || ""));
        break;                               // no Qt variant fixes a license
      }
      if (lic.tracking === "ok") {
        out.tracking = "ok";
        out.tracking_detail = lic.tracking_detail;
        out.qt = v;
        track.writeConfig({ mocha_qt: v });
        break;
      }
      out.tracking = "failed";
      out.tracking_detail = lic.tracking_detail;
    }
    if (out.license === "ok" && out.tracking !== "ok")
      out.tracking_help = track.explainMochaError("Probe track failed in every "
        + "Qt variant: " + (out.tracking_detail || "") + " (rendering context)");
    out.ready = out.license === "ok" && out.tracking === "ok";
    return out;
  });

tool("mocha_track",
  "Planar-track a region of a layer's SOURCE footage with Mocha Pro's own "
  + "engine, headless (needs Mocha Pro installed; mocha_status first). "
  + "shape = 3+ [x,y] points in SOURCE pixels (origin top-left) around a "
  + "flat-ish surface visible at start_s — look with grab_source_frame "
  + "(source pixels, nothing to convert); rect [x,y,w,h] "
  + "is a shortcut. start_s/end_s in SOURCE seconds (default: the layer's "
  + "trimmed range). exports: mask (native AE mask keyframes built from "
  + "Mocha's 64-point outline, RotoBezier-smoothed), corner_pin "
  + "(Corner Pin effect keys), power_pin, transform (Position/Scale/"
  + "Rotation keys), corner_pin_motion_blur. apply=true writes them onto "
  + "the layer; apply=false only writes files. Slow: about real time.",
  { layer: { type: "number" }, comp: { type: "string" },
    shape: { type: "array", items: { type: "array" } },
    rect: { type: "array", items: { type: "number" } },
    surface: { type: "array", items: { type: "array" },
               description: "optional 4 [x,y] corners for the corner-pin "
                 + "surface (default: shape bounding box)" },
    start_s: { type: "number" }, end_s: { type: "number" },
    exports: { type: "array", items: { type: "string" } },
    apply: { type: "boolean" }, layer_name: { type: "string" },
    mask_name: { type: "string" }, mask_mode: { type: "string",
      description: "add (default), subtract, none" },
    mask_feather: { type: "number" }, mask_inverted: { type: "boolean" },
    roto_bezier: { type: "boolean", description: "smooth the 64-vertex "
      + "outline (default true)" } },
  ["layer"], {}, mochaTrack);

tool("apply_track_file",
  "Apply a Mocha export file: a .shape4ae (After Effects Mask Data → native "
  + "mask keyframes) or an AE keyframe .txt (Corner Pin / CC Power Pin / "
  + "Transform data) onto a layer — from the Mocha GUI, or from an earlier "
  + "mocha_track run's folder (see track_history). Source frame f lands at "
  + "layer start + f/fps. surface = 4 [x,y] corners to retarget a corner "
  + "pin onto (e.g. a door's box at the first tracked frame).",
  { layer: { type: "number" }, comp: { type: "string" },
    file: { type: "string" }, time_offset_s: { type: "number" },
    surface: { type: "array", items: { type: "array" } },
    label: { type: "string" }, effect_name: { type: "string" },
    mask_name: { type: "string" }, mask_mode: { type: "string" },
    mask_feather: { type: "number" }, mask_inverted: { type: "boolean" },
    roto_bezier: { type: "boolean" } }, ["layer", "file"], {}, applyTrackFile);

tool("track_history",
  "What earlier chats of this panel already tracked and applied in this "
  + "project: run folders (with the raw corner_pin.txt / mask.shape4ae), "
  + "layer, range, mask/effect names, reports. CHECK THIS before treating "
  + "keyframes or masks you do not remember as damage — they are usually a "
  + "previous run of yours, and their exports can be re-applied with "
  + "apply_track_file.",
  { limit: { type: "number" } }, [], { readonly: true },
  async (s, a) => ({ history_file: HISTORY_FILE, applied: readHistory(a.limit || 20),
                     run_folders: runFolders(a.limit || 20) }));

tool("set_fal_key",
  "Store a fal.ai API key (for ai_segment) in ~/.claude-assistant.json "
  + "(mode 0600). The key is never echoed back.",
  { key: { type: "string" } }, ["key"], { readonly: true }, async (s, a) => {
    const k = String(a.key || "").trim();
    if (k.length < 20 || /\s/.test(k))
      throw new Error("That does not look like a fal key (expected "
        + "id:secret from fal.ai/dashboard/keys).");
    track.writeConfig({ fal_api_key: k });
    return { stored: true, file: track.CONFIG_FILE };
  });

tool("fal_status",
  "Is a fal.ai key stored, and does fal accept it? Read-only, free.",
  {}, [], { readonly: true }, async () => {
    const key = track.readConfig().fal_api_key;
    if (!key) return { configured: false, next: "fal.ai/dashboard/keys → set_fal_key" };
    const r = await track.httpRequest(track.FAL_QUEUE
      + "/fal-ai/sam-3/video/requests/00000000-0000-0000-0000-000000000000/status",
      { headers: { Authorization: "Key " + key }, timeoutMs: 20000 });
    return { configured: true, key_accepted: r.status !== 401 && r.status !== 403,
             http_status: r.status, detail: (r.text || "").slice(0, 200) };
  });

tool("ai_segment",
  "Object matte from fal.ai SAM 3 for a layer's SOURCE file (mp4/mov/webm/"
  + "m4v/gif): uploads it, segments by text prompt ('the yellow car') / "
  + "points / boxes, downloads the segmented video, imports it above the "
  + "layer and sets it as the layer's LUMA track matte. PAID: ~$0.005 per "
  + "16 frames (sam-3) or $0.01 (sam-3-1) — dry_run:true returns the quote "
  + "without spending. Needs set_fal_key. Whole file is processed.",
  { layer: { type: "number" }, comp: { type: "string" },
    prompt: { type: "string" }, model: { type: "string",
      description: "'sam-3' (default) or 'sam-3-1'" },
    points: { type: "array", items: { type: "object" },
      description: "[{x,y,label(1=fg,0=bg),object_id}] in source pixels" },
    boxes: { type: "array", items: { type: "object" },
      description: "[{x_min,y_min,x_max,y_max,object_id}]" },
    detection_threshold: { type: "number" }, max_objects: { type: "number" },
    apply_mask: { type: "boolean" }, apply: { type: "boolean" },
    matte: { type: "string", description: "luma (default), luma_inverted, "
      + "alpha, alpha_inverted, none" },
    dry_run: { type: "boolean" } }, ["layer"], {}, aiSegment);

// ------------------------------------------------------------ approvals
const state = { permissionMode: "Ask before edits", approveAllEdits: false,
                pendingApproval: null, onApprovalNeeded: null };

function needsApproval(name) {
  const entry = TOOLS.find((t) => t.name === name);
  const mode = state.permissionMode;
  if (mode === "Always ask") return true;
  if (mode !== "Ask before edits") return false;
  if (state.approveAllEdits) return false;
  return !(entry && entry.readonly);
}

function requestApproval(name, input) {
  return new Promise((resolveP) => {
    const pending = { name, input };
    let done = false;
    const finish = (msg) => {
      if (done) return;
      done = true; clearTimeout(timer);
      state.pendingApproval = null;
      resolveP(msg);
    };
    const timer = setTimeout(() => finish(
      "The approval request timed out after " + APPROVAL_TIMEOUT_MS / 1000
      + "s with no answer — the action was NOT performed."),
      APPROVAL_TIMEOUT_MS);
    pending.answer = (decision, guidance) => {
      if (decision === "always") { state.approveAllEdits = true; finish(null); }
      else if (decision === "run") finish(null);
      else finish("The user declined this action"
        + (guidance ? " and said: " + guidance : "") + ". Do not retry as-is.");
    };
    state.pendingApproval = pending;
    if (state.onApprovalNeeded) state.onApprovalNeeded(pending);
  });
}

async function executeTool(name, input) {
  const entry = TOOLS.find((t) => t.name === name);
  if (!entry) return { ok: false, text: "Unknown tool: " + name };
  const quoteOnly = name === "ai_segment" && input && input.dry_run;
  if (needsApproval(name) && !quoteOnly) {
    const declined = await requestApproval(name, input || {});
    if (declined) return { ok: false, text: declined };
  }
  try {
    const result = await entry.fn(state, input || {});
    let images = null;
    if (result && typeof result === "object" && result._images) {
      images = result._images;
      delete result._images;
    }
    const out = { ok: true, text: JSON.stringify(result) };
    if (images) out.images = images;
    return out;
  } catch (e) {
    return { ok: false, text: e.message || String(e) };
  }
}

function toolSchemas() {
  return TOOLS.map((t) => ({ name: t.name, description: t.description,
    inputSchema: { type: "object", properties: t.params,
                   required: t.required } }));
}

// ------------------------------------------------ MCP server (in-process)
// Live launch #4 hit "No node binary found": the Resolve plugin spawns
// bridge.js under Electron-as-Node, but a CEP panel has no standalone node
// to spawn and the native claude build needs none. So the panel hosts the
// MCP endpoint itself over Streamable HTTP (a transport Claude Code speaks
// natively) using the Node 17 runtime CEP already gives us. Zero children.
const http = require("http");
const SUPPORTED = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
let bridge = null;

async function handleRpc(msg, onEvent) {
  const id = msg.id;
  try {
    if (msg.method === "initialize") {
      const req = (msg.params || {}).protocolVersion;
      return { jsonrpc: "2.0", id, result: {
        protocolVersion: SUPPORTED.indexOf(req) >= 0 ? req : "2025-06-18",
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: "ae", version: "1.0.0" } } };
    }
    if (msg.method === "ping") return { jsonrpc: "2.0", id, result: {} };
    if (msg.method === "tools/list")
      return { jsonrpc: "2.0", id, result: { tools: toolSchemas() } };
    if (msg.method === "tools/call") {
      const p = msg.params || {};
      if (typeof p.name !== "string")
        return { jsonrpc: "2.0", id, error: { code: -32602,
                 message: "Invalid params: 'name' must be a string" } };
      const args = p.arguments || {};
      if (onEvent) onEvent("call", p.name, args);
      const started = Date.now();
      const r = await executeTool(p.name, args);
      if (onEvent) onEvent("result", p.name, { ok: r.ok,
                                                ms: Date.now() - started });
      const content = [];
      for (const img of (r.images || []))
        if (img && img.data) content.push({ type: "image", data: img.data,
          mimeType: img.media_type || "image/jpeg" });
      content.push({ type: "text", text: r.text });
      return { jsonrpc: "2.0", id, result: { content, isError: !r.ok } };
    }
    return { jsonrpc: "2.0", id, error: { code: -32601,
             message: "Method not found: " + msg.method } };
  } catch (e) {
    return { jsonrpc: "2.0", id, error: { code: -32603,
             message: "Internal error: " + e.message } };
  }
}

function startBridge(onEvent) {
  const token = crypto.randomBytes(16).toString("hex");
  const server = http.createServer((req, res) => {
    const reply = (code, body) => {
      res.writeHead(code, body ? { "Content-Type": "application/json" } : {});
      res.end(body ? JSON.stringify(body) : undefined);
    };
    if (req.url !== "/mcp") return reply(404);
    if ((req.headers.authorization || "") !== "Bearer " + token)
      return reply(401);
    if (req.method === "GET") return reply(405);   // no server-push stream
    if (req.method === "DELETE") return reply(200);
    if (req.method !== "POST") return reply(405);
    let body = "";
    req.on("data", (d) => { body += d; });
    req.on("end", async () => {
      let msg;
      try { msg = JSON.parse(body); }
      catch (e) { return reply(400, { jsonrpc: "2.0", id: null,
        error: { code: -32700, message: "Parse error" } }); }
      const batch = Array.isArray(msg);
      const replies = [];
      for (const m of (batch ? msg : [msg])) {
        if (!m || m.method === undefined) continue;   // a client response
        if (!("id" in m) || m.id === null) continue;  // notification: no reply
        replies.push(await handleRpc(m, onEvent));
      }
      if (!replies.length) return reply(202);
      reply(200, batch ? replies : replies[0]);
    });
  });
  return new Promise((resolveP) => {
    server.listen(0, "127.0.0.1", () =>
      resolveP({ server, port: server.address().port, token }));
  });
}

// ------------------------------------------------------------ CLI plumbing
function findBinary(names, extraDirs) {
  const dirs = (process.env.PATH || "").split(path.delimiter)
    .concat(extraDirs || ["/opt/homebrew/bin", "/usr/local/bin",
                          path.join(os.homedir(), ".local", "bin")]);
  for (const name of names)
    for (const dir of dirs) {
      const p = path.join(dir, name);
      try { if (fs.existsSync(p)) return p; } catch (e) {}
    }
  return null;
}

function cliEnv() {
  const env = Object.assign({}, process.env);
  delete env.ANTHROPIC_API_KEY;         // silently overrides subscription auth
  delete env.ANTHROPIC_AUTH_TOKEN;
  env.PATH = [env.PATH || "", "/opt/homebrew/bin", "/usr/local/bin",
              path.join(os.homedir(), ".local", "bin")].join(path.delimiter);
  return env;
}

// ------------------------------------------------------------ chat session
let sessionId = null, busy = false, currentModel = "";
let history = historyLib.makeHistory(path.join(USER_DATA, "chats"));
let chatId = historyLib.newChatId();
let msgLog = [];
let pendingRecap = "";
const PERSISTED_KINDS = new Set(["you", "assistant", "error", "notice",
                                 "toolcall", "toolresult"]);
let uiHandler = null;

function sendUI(kind, payload, persist) {
  if (persist !== false && PERSISTED_KINDS.has(kind))
    msgLog.push({ kind, payload });
  if (uiHandler) uiHandler({ kind, payload });
}

function autosave() {
  try { history.save({ id: chatId, events: msgLog, sessionId,
                       model: currentModel }); } catch (e) {}
}

function buildTurn(workdir, model, effort) {
  fs.mkdirSync(workdir, { recursive: true });
  if (!bridge) throw new Error("The panel's MCP server is not up yet — "
                               + "try again in a second.");
  const mcpPath = path.join(workdir, "mcp.json");
  const sysPath = path.join(workdir, "system.txt");
  fs.writeFileSync(mcpPath, JSON.stringify({ mcpServers: { ae: {
    type: "http",
    url: "http://127.0.0.1:" + bridge.port + "/mcp",
    headers: { Authorization: "Bearer " + bridge.token } } } }));
  fs.writeFileSync(sysPath, SYSTEM_PROMPT);
  const argv = ["-p", "--output-format", "stream-json", "--verbose",
                "--strict-mcp-config", "--mcp-config", mcpPath,
                "--allowedTools", "mcp__ae__*", "--tools", "",
                "--append-system-prompt-file", sysPath, "--model", model];
  if (effort && model.indexOf("haiku") < 0) argv.push("--effort", effort);
  if (sessionId) argv.push("--resume", sessionId);
  return argv;
}

function handleCliEvent(event) {
  if (!event || typeof event !== "object") return;
  if (event.type === "system" && event.subtype === "init") {
    if (event.session_id) sessionId = event.session_id;
    for (const server of event.mcp_servers || [])
      if (server.name === "ae" && server.status === "failed")
        sendUI("notice", "The AE tool bridge did not connect this turn.");
    return;
  }
  if (event.type === "assistant") {
    for (const block of ((event.message || {}).content || [])) {
      if (block.type === "text" && block.text && block.text.trim())
        sendUI("assistant", block.text);
      else if (block.type === "tool_use")
        sendUI("toolcall", { name: (block.name || "").split("__").pop(),
                             input: block.input || {} });
    }
    return;
  }
  if (event.type === "result") {
    if (event.session_id) sessionId = event.session_id;
    const isErr = event.is_error
      || String(event.subtype || "").indexOf("error") === 0;
    if (!isErr) pendingRecap = "";
    if (isErr) {
      let detail = String(event.result || "").trim();
      if (!detail) detail = (event.errors || []).map(String).join("\n");
      if (detail.toLowerCase().includes("no conversation found")) {
        sessionId = null;
        sendUI("notice", "That session no longer exists — send again to "
          + "continue fresh.");
      } else sendUI("error", detail || "Claude Code reported an error.");
    }
  }
}

function runTurn(model, effort, text) {
  const binary = findBinary(["claude"]);
  if (!binary) {
    sendUI("error", "Claude Code CLI not found. Install: npm install -g "
      + "@anthropic-ai/claude-code (then sign in once with `claude`).");
    busy = false; sendUI("done", {});
    return;
  }
  const workdir = path.join(USER_DATA, "turn-" + Date.now());
  if (!sessionId && pendingRecap) text = pendingRecap + "\n\n" + text;
  let argv;
  try { argv = buildTurn(workdir, model, effort); }
  catch (e) { sendUI("error", e.message); busy = false;
              sendUI("done", {}); return; }
  const child = spawn(binary, argv, { env: cliEnv(), cwd: USER_DATA });
  child.stdin.write(text + "\n");
  child.stdin.end();
  let carry = "", stderrText = "";
  const stray = [];
  child.stdout.on("data", (chunk) => {
    carry += chunk.toString("utf8");
    let idx;
    while ((idx = carry.indexOf("\n")) >= 0) {
      const line = carry.slice(0, idx).trim(); carry = carry.slice(idx + 1);
      if (!line) continue;
      try { handleCliEvent(JSON.parse(line)); }
      catch (e) { stray.push(line); }
    }
  });
  child.stderr.on("data", (d) => { stderrText += d.toString("utf8"); });
  child.on("error", (e) => {
    sendUI("error", "Could not run the claude CLI: " + e.message);
    busy = false; sendUI("done", {}); });
  child.on("close", (code) => {
    try { fs.rmSync(workdir, { recursive: true, force: true }); } catch (e) {}
    if (code !== 0 && stderrText) {
      const low = (stderrText + stray.join("\n")).toLowerCase();
      if (low.includes("no conversation found")) {
        sessionId = null;
        sendUI("notice", "That session no longer exists — send again to "
          + "continue fresh.");
      } else sendUI("error", "Claude Code exited with status " + code + "\n"
        + (stderrText || stray.join("\n")).slice(0, 1200));
    }
    busy = false; sendUI("done", {});
    autosave();
  });
}

// -------------------------------------------------- assistant API (app.js)
window.assistant = {
  send({ text, model, effort, permissionMode }) {
    if (busy || !text || !String(text).trim()) return false;
    if (PERMISSION_MODES.includes(permissionMode))
      state.permissionMode = permissionMode;
    currentModel = model;
    busy = true;
    sendUI("you", String(text).trim());
    runTurn(MODELS.includes(model) ? model : MODELS[0],
            EFFORTS.includes(effort) ? effort : "medium",
            String(text).trim());
    return true;
  },
  approval(decision, guidance) {
    if (state.pendingApproval) state.pendingApproval.answer(decision, guidance);
  },
  newChat() {
    autosave();
    sessionId = null; pendingRecap = "";
    chatId = historyLib.newChatId(); msgLog = [];
  },
  config() {
    return Promise.resolve({ models: MODELS, efforts: EFFORTS,
                             modes: PERMISSION_MODES });
  },
  history(action, id) {
    if (action === "list") return Promise.resolve(history.list());
    if (action === "delete") {
      history.remove(id);
      if (id === chatId) { chatId = historyLib.newChatId(); msgLog = [];
                           sessionId = null; }
      return Promise.resolve(true);
    }
    if (action === "open") {
      if (busy) return Promise.resolve({ busy: true });
      if (id === chatId) return Promise.resolve({ current: true });
      const data = history.load(id);
      if (!data) return Promise.resolve(null);
      autosave();
      chatId = id; msgLog = data.events || [];
      sessionId = data.sessionId || null;
      pendingRecap = sessionId ? "" : historyLib.buildRecap(msgLog);
      return Promise.resolve({ events: msgLog, model: data.model,
                               title: data.title });
    }
    return Promise.resolve(null);
  },
  onEvent(handler) { uiHandler = handler; },
  clipboard: clipboardApi,
};

state.onApprovalNeeded = (pending) =>
  sendUI("approval", { name: pending.name, input: pending.input });

startBridge((kind, name, payload) => {
  if (kind === "result")
    sendUI("toolresult", { name, ok: payload.ok, ms: payload.ms });
}).then((b) => { bridge = b; });

})();
