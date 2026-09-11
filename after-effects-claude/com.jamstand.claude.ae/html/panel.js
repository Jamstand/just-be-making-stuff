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
const audio = require(path.join(EXT_ROOT, "audiolib.js"));
const MOCHA_SCRIPT = path.join(EXT_ROOT, "host", "mocha_job.py");
const USER_DATA = path.join(os.homedir(), "Library", "Application Support",
                            "ClaudeAssistantAE");
// Which panel this page is: "assistant" (everything) or "music" (Claude
// Music: the music / beat tools plus the basics, tracking and mattes
// hidden, its own prompt and chat history). Set by music.html.
const PANEL = (typeof window !== "undefined" && window.CLAUDE_PANEL === "music")
  ? "music" : "assistant";
const HIDDEN_IN_MUSIC = new Set(["study_url", "study_edit", "watch_video", "gemini_status", "set_gemini_key",
  "media_tools", "install_yt_dlp",
  "mocha_status", "mocha_track", "mocha_cancel",
  "apply_track_file", "track_history", "set_fal_key", "fal_status", "ai_segment"]);
const isHidden = (name) => PANEL === "music" && HIDDEN_IN_MUSIC.has(name);
fs.mkdirSync(USER_DATA, { recursive: true });

const MODELS = ["claude-opus-5", "claude-fable-5", "claude-sonnet-5",
                "claude-haiku-4-5"];
const EFFORTS = ["low", "medium", "high", "xhigh", "max"];
const PERMISSION_MODES = ["Ask before edits", "Always ask", "Never ask"];

// Slash commands (the "/" menu, /train, routing) live in slash.js; the
// style study (yt-dlp, ffmpeg, the profile file, Gemini) in stylelib.js.
const slashlib = require(path.join(EXT_ROOT, "slash.js"));
const style = require(path.join(EXT_ROOT, "stylelib.js"));
const BIN_DIR = path.join(USER_DATA, "bin");      // yt-dlp the panel installed itself
style.addBinDir(BIN_DIR);
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
  "MUSIC: music_list shows the songs in ~/Music/Claude Assistant (or",
  "music_dirs in the config); analyze_music gives bpm, beats, downbeats,",
  "bass hits, sections and drop_s; add_music puts a song in the comp;",
  "beat_control makes a BEAT null with keyframed sliders (Beat, Bar, Bass,",
  "Energy, BPM) plus bar/drop markers; cut_to_beats lays clips on the",
  "grid; beat_effects wires punch / shake / flash / zoom expressions to",
  "those sliders; speed_ramp can land on drop_s. Pick a song whose length",
  "and energy suit the edit, tell the user which and why.",
  "STYLE: study_url (download a reel with yt-dlp) → study_edit (cut",
  "rhythm, shot lengths, exposure, cast into ~/ClaudeAssistantStyle/",
  "<profile>.json, shared with the Resolve panel) → watch_video (Gemini",
  "watches it for the content read) learn an editor's style from finished",
  "edits; the /train macro drives all three. style_profile reads the",
  "profile: whenever the user asks for THEIR style, read it first and use",
  "its cuts per minute and shot lengths with cut_to_beats, and its content",
  "notes for shot choices, structure and look. ffmpeg is OPTIONAL — without",
  "it study_edit has After Effects decode the video itself (slower, and it",
  "asks once before importing into a temporary folder it removes again).",
  "yt-dlp is the one thing the study needs, and install_yt_dlp fetches it",
  "without Homebrew. When a study fails, call media_tools and pass its",
  "advice on rather than sending the user to a package manager.",
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

const MUSIC_SYSTEM_PROMPT = [
  "You are Claude Music, a panel inside Adobe After Effects that cuts and",
  "animates to music through the mcp__ae__* tools. Workflow: music_list",
  "(songs in ~/Music/Claude Assistant or music_dirs in the config) →",
  "analyze_music (bpm, beats, downbeats, bass hits, sections, drop_s) →",
  "add_music → beat_control (a BEAT null with keyframed Beat / Bar / Bass /",
  "Energy / BPM sliders plus bar and drop markers) → cut_to_beats (clips on",
  "the beat grid, patterns in beats) → beat_effects (punch, shake, flash,",
  "zoom, opacity expressions driven by those sliders) and speed_ramp to",
  "land on drop_s. Pick a song whose length and energy suit the edit and",
  "say which and why; when the library is empty, say where to drop files.",
  "style_profile reads the editor's style profile (cuts per minute, shot",
  "lengths, content notes from studied edits): when the user asks for",
  "their style, read it first and cut to it. Studying new edits (/train)",
  "lives in the Claude Assistant panel.",
  "Tracking, mattes and Mocha live in the Claude Assistant panel, not here.",
  "Chats do not share memory but the PROJECT persists, and the Claude",
  "Assistant panel may be open beside you: keyframes, masks, Corner Pins",
  "and layers you do not remember are someone else's work — never rebuild",
  "or delete keyframes you did not create in THIS chat without asking.",
  "apply_effect returns each effect's real property list, use it; output",
  "codecs are template-only.",
  "run_extendscript is the escape hatch (full AE DOM); ES3 ONLY in that",
  "code — var, no arrow functions, no const/let, no template strings, no",
  "JSON object. Times are SECONDS. Layer indexes are 1-based, top of stack",
  "= 1; add_clip appends to the bottom. Name what you add. The panel may",
  "pause a modifying tool call for the user's approval; if declined or",
  "timed out, never retry unchanged. Be concise: lead with the result.",
].join(" ");

// ------------------------------------------------------------ host bridge
function evalHost(name, args) {
  return new Promise((resolveP, rejectP) => {
    // JSON leaves U+2028/2029 raw; inside a JS string literal they end the
    // line and break the call.
    const call = ("CA_invoke(" + JSON.stringify(name) + ","
      + JSON.stringify(JSON.stringify(args || {})) + ")")
      .replace(/\u2028/g, "\\u2028").replace(/\u2029/g, "\\u2029");
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
      const p = spawn(cmd[0], cmd[1], { stdio: ["pipe", "ignore", "ignore"],
                                        windowsHide: true });
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
      execFile(cmd[0], cmd[1], { encoding: "utf8", maxBuffer: 64 << 20,
                                 windowsHide: true },
        (err, out) => err ? reject(err) : resolve(process.platform === "win32"
          ? String(out).replace(/\r?\n$/, "") : out));   // Get-Clipboard adds one
    });
  },
};

// ------------------------------------------------------------ tool registry
const TOOLS = [];
function tool(name, description, params, required, opts, fn) {
  TOOLS.push({ name, description, params: params || {},
               required: required || [], readonly: !!(opts && opts.readonly),
               // readonlyWhen(input): for a tool that touches the project
               // only for some arguments (study_edit needs After Effects
               // itself when ffmpeg is missing, and nothing otherwise).
               readonlyWhen: (opts && opts.readonlyWhen) || null,
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
    const sweep = async () => { try { await evalHost("remove_temp_comp", {}); }
                                catch (e) {} };
    let data;
    try { data = await evalHost("grab_source_frame", a); }
    catch (e) { await sweep(); throw e; }      // host may have made the comp
    try {
      return await finishGrab(data, { source: data.source, width: data.width,
        height: data.height, source_time_s: data.source_time_s,
        coordinates: "source pixels, origin top-left — pass these to "
          + "mocha_track's shape as-is" });
    } finally { await sweep(); }                // every __ClaudeGrab__ comp
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
// Mocha runs for minutes; if the panel closes or AE quits, the child must
// not keep tracking at full CPU for nothing.
const liveMocha = new Set();
function watchChild(child) {
  liveMocha.add(child);
  child.on("close", () => liveMocha.delete(child));
}
window.addEventListener("beforeunload", () => {
  for (const c of liveMocha) { try { c.kill("SIGKILL"); } catch (e) {} }
});

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
      if (shapes.normalized && info.source) {
        for (const sh of shapes.shapes)
          for (const f of sh.frames)
            f.points = f.points.map(([x, y]) => [x * info.source.width, y * info.source.height]);
        (out.warnings = out.warnings || []).push(kind + ": export had no Source "
          + "Width/Height — points scaled by the layer's source size");
      }
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
    if (/pin/.test(kind) && info.source) {
      out.track_report = track.trackReport(blocks, info.source.width,
                                           info.source.height, fps);
      if (blocks !== parsed.blocks)
        out.mocha_surface_report = track.trackReport(parsed.blocks,
          info.source.width, info.source.height, fps);
    }
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
  if (!isFinite(startS) || !isFinite(endS))
    throw new Error("start_s and end_s must be numbers (SOURCE seconds).");
  if (endS <= startS)
    throw new Error("end_s (" + endS + ") must be later than start_s (" + startS
      + ") — both in SOURCE seconds; this layer's trimmed range is "
      + info.source_in_s + "–" + info.source_out_s + "s.");
  const startF = Math.max(0, Math.round(startS * fps));
  const endF = Math.round(endS * fps) - 1;
  if (endF - startF + 1 < 2)
    throw new Error("That range is under two frames at " + fps + " fps — widen end_s.");
  const found = track.findMochaPython();
  if (!found.length)
    throw new Error("Mocha Pro's python3 was not found — run mocha_status.");
  const wanted = (Array.isArray(a.exports) && a.exports.length) ? a.exports
                                                                : ["mask", "corner_pin"];
  const bad = wanted.filter((k) => !["mask", "corner_pin",
    "corner_pin_motion_blur", "power_pin", "transform"].includes(k));
  if (bad.length) throw new Error("Unknown exports: " + bad.join(", "));
  const b = bbox(shape);
  // Corners in any order; assigned by position so no bow-ties.
  const corners = track.cornersFromQuad(a.surface)
    || { UL: [b.minx, b.miny], UR: [b.maxx, b.miny], LL: [b.minx, b.maxy], LR: [b.maxx, b.maxy] };
  const surface = [corners.UL, corners.UR, corners.LR, corners.LL];   // Mocha: clockwise
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
      env: track.mochaEnv(), onSpawn: watchChild });
  } catch (e) { throw new Error(track.explainMochaError(e.message)); }
  const label = (startF / fps).toFixed(1).replace(/\.0$/, "") + "-"
    + ((endF + 1) / fps).toFixed(1).replace(/\.0$/, "") + "s";
  const out = { python: found[0].python, project: data.project, workdir,
    label, source: info.source.name, fps, start_frame: startF, end_frame: endF,
    frames: data.frames, track_seconds: data.track_seconds,
    exports: data.exports, notes: data.notes || [], applied: [], warnings: [],
    surface: corners };
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
  if (Array.isArray(a.surface) && a.surface.length === 4) {
    out.surface = track.cornersFromQuad(a.surface);
    if (!out.surface) throw new Error("surface must be 4 numeric [x,y] corners.");
  }
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
  out.warnings = [];
  if (info.time_remap || (info.stretch && info.stretch !== 100))
    out.warnings.push("Layer is retimed (stretch " + info.stretch + "%"
      + (info.time_remap ? ", time remap" : "") + "): the matte is aligned by "
      + "start time only and will drift — retime the matte layer the same way.");
  if (a.apply !== false) {
    try {
      out.applied = await evalHost("import_and_matte", { layer: a.layer,
        comp: a.comp, file: dest, matte: a.matte || "luma" });
    } catch (e) {
      out.applied = null;
      out.apply_error = e.message;
      out.next = "Segmentation succeeded and is saved at result_file (already "
        + "paid for — do NOT re-run ai_segment). Applying it failed: "
        + e.message + ". Fix the cause (AE 23+ for track mattes, or the layer "
        + "index) and import result_file with import_media / import_and_matte.";
    }
  }
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
        { scriptPath: MOCHA_SCRIPT, workdir, timeoutMs: 180000, env,
          onSpawn: watchChild });
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
            timeoutMs: 180000, env, onSpawn: watchChild });
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
                 + "surface, any order (assigned by position); default: "
                 + "the shape's bounding box" },
    start_s: { type: "number" }, end_s: { type: "number" },
    exports: { type: "array", items: { type: "string" } },
    apply: { type: "boolean" }, layer_name: { type: "string" },
    mask_name: { type: "string" }, mask_mode: { type: "string",
      description: "add (default), subtract, none" },
    mask_feather: { type: "number" }, mask_inverted: { type: "boolean" },
    roto_bezier: { type: "boolean", description: "smooth the 64-vertex "
      + "outline (default true)" } },
  ["layer"], {}, mochaTrack);

tool("mocha_cancel",
  "Stop the Mocha track or probe this panel is running (kills the Mocha "
  + "python process; nothing is applied). Read-only.",
  {}, [], { readonly: true }, async () => {
    let killed = 0;
    for (const c of liveMocha) { try { c.kill("SIGKILL"); killed += 1; } catch (e) {} }
    return { killed };
  });

tool("apply_track_file",
  "Apply a Mocha export file: a .shape4ae (After Effects Mask Data → native "
  + "mask keyframes) or an AE keyframe .txt (Corner Pin / CC Power Pin / "
  + "Transform data) onto a layer — from the Mocha GUI, or from an earlier "
  + "mocha_track run's folder (see track_history). Source frame f lands at "
  + "layer start + f/fps. surface = 4 [x,y] corners to retarget a corner "
  + "pin onto (e.g. a door's box at the first tracked frame).",
  { layer: { type: "number" }, comp: { type: "string" },
    file: { type: "string" }, time_offset_s: { type: "number" },
    surface: { type: "array", items: { type: "array" },
               description: "4 [x,y] corners, any order" },
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

// ------------------------------------------------------ music / beats
const AUDIO_DIR = path.join(USER_DATA, "audio");

function musicDirs() {
  const cfg = track.readConfig();
  const dirs = Array.isArray(cfg.music_dirs) ? cfg.music_dirs.slice() : [];
  const def = audio.defaultMusicDir();
  if (!dirs.includes(def)) dirs.unshift(def);
  return dirs;
}
// The folder the user chose (music_dirs[0]) or the default — what the panel
// shows as "the library"; musicDirs() always lists the default first.
function libraryDir() {
  const cfg = track.readConfig();
  return (Array.isArray(cfg.music_dirs) && cfg.music_dirs[0]) || audio.defaultMusicDir();
}

function resolveSong(nameOrFile) {
  if (!nameOrFile) throw new Error("Which song? Give a file path or a name from music_list.");
  const s = String(nameOrFile);
  if (fs.existsSync(s)) return s;
  const songs = audio.listSongs(musicDirs());
  const low = s.toLowerCase();
  const hit = songs.find((x) => x.name.toLowerCase() === low)
    || songs.find((x) => path.basename(x.file).toLowerCase() === low)
    || songs.find((x) => x.name.toLowerCase().includes(low));
  if (!hit) throw new Error("No song '" + s + "' in " + musicDirs().join(", ")
    + ". Drop songs into " + audio.defaultMusicDir() + " or give a full path.");
  return hit.file;
}

async function analysisFor(file, force) {
  fs.mkdirSync(AUDIO_DIR, { recursive: true });
  const key = audio.cacheKey(file);
  const cache = path.join(AUDIO_DIR, key + ".json");
  if (!force && fs.existsSync(cache)) {
    try { const c = JSON.parse(fs.readFileSync(cache, "utf8")); if (c && c.v >= 2) return c; } catch (e) {}
  }
  // The analysis itself is synchronous and blocks the panel for a few
  // seconds; yielding a frame after each stage lets the listening view paint.
  const paint = () => new Promise((r) => setTimeout(r, 30));
  sendUI("music_progress", { file, stage: "decoding", pct: 10 }, false);
  await paint();
  const wav = await audio.decodeToWav(file, AUDIO_DIR);
  sendUI("music_progress", { file, stage: "listening", pct: 45 }, false);
  await paint();
  const pcm = audio.parseWav(fs.readFileSync(wav));
  const a = audio.analyze(pcm.samples, pcm.sampleRate);
  sendUI("music_progress", { file, stage: "done", pct: 100 }, false);
  a.file = file; a.analyzed_at = new Date().toISOString();
  fs.writeFileSync(cache, JSON.stringify(a));
  return a;
}

function summary(a) {
  return { file: a.file, duration_s: a.duration_s, bpm: a.bpm, beat_s: a.beat_s,
    tempo_confidence: a.tempo_confidence, beats: a.beats.length, bars: a.downbeats.length,
    first_beat_s: a.beats[0], first_downbeat_s: a.downbeats[0], bass_hits: a.bass_hits.length,
    drop_s: a.drop_s, sections: a.sections.map((s) => ({ kind: s.kind, start_s: s.start_s,
      end_s: s.end_s, bars: s.bars, energy: s.energy })),
    downbeats_first_32: a.downbeats.slice(0, 32),
    // For the panel's strips only: every bar and the 110-bucket envelope.
    // Keys starting with "_" never reach the model (see the MCP result path);
    // assistant.callTool merges _panel back to the top level for the UI.
    _panel: { downbeats: a.downbeats, wave: a.wave || null },
    note: "beat/downbeat/bass-hit times are SONG seconds; add the music layer's "
      + "start (offset_s) to get comp time" };
}

async function sliderKeys(comp, layerIndex, name, keys, hold) {
  let r = null;
  if (!keys.length) return evalHost("set_slider_keys", { comp, layer: layerIndex, effect_name: name, value: 0 });
  for (let i = 0; i < keys.length; i += 400)
    r = await evalHost("set_slider_keys", { comp, layer: layerIndex, effect_name: name,
      keys: keys.slice(i, i + 400), append: i > 0, hold: !!hold });
  return r;
}

tool("music_list",
  "The song library: every audio file in ~/Music/Claude Assistant (plus any "
  + "music_dirs in ~/.claude-assistant.json), with cached bpm/duration where "
  + "a song was analysed before. Drop songs into that folder to add them.",
  { dir: { type: "string", description: "extra folder to include this time" } },
  [], { readonly: true }, async (s, a) => {
    const dirs = musicDirs().concat(a.dir ? [String(a.dir)] : []);
    try { fs.mkdirSync(audio.defaultMusicDir(), { recursive: true }); } catch (e) {}
    const waves = {};
    const songs = audio.listSongs(dirs).map((song) => {
      const out = Object.assign({}, song);
      try {
        const cache = path.join(AUDIO_DIR, audio.cacheKey(song.file) + ".json");
        if (fs.existsSync(cache)) {
          const a = JSON.parse(fs.readFileSync(cache, "utf8"));
          out.bpm = a.bpm; out.duration_s = a.duration_s; out.drop_s = a.drop_s; out.analyzed = true;
          if (a.wave) waves[song.file] = a.wave;
        }
      } catch (e) {}
      return out;
    });
    return { dirs, folders: dirs, library_dir: libraryDir(), songs, count: songs.length,
      _panel: { waves },
      hint: songs.length ? "analyze_music <name> for beats; add_music <name> to put it in the comp"
        : "No songs yet — drop MP3/M4A/WAV files into " + audio.defaultMusicDir() };
  });

tool("analyze_music",
  "Beats for a song: bpm, beat and downbeat (bar) times, bass hits with "
  + "strength, sections (intro/build/drop/verse/quiet) and drop_s. Decodes "
  + "with macOS afconvert (or ffmpeg), analyses locally, caches the result. "
  + "Times are SONG seconds.",
  { song: { type: "string", description: "name from music_list or a file path" },
    force: { type: "boolean" } }, ["song"], { readonly: true },
  async (s, a) => summary(await analysisFor(resolveSong(a.song), a.force)));

tool("add_music",
  "Import a song and add it to the comp as the bottom layer starting at "
  + "start_s (default 0). Returns the layer index and the beat summary with "
  + "offset_s = start_s so beat times can be placed in comp time. "
  + "extend_comp lengthens the comp to fit the song.",
  { song: { type: "string" }, comp: { type: "string" }, start_s: { type: "number" },
    in_s: { type: "number", description: "SONG time the clip starts from (default 0): trim so a drop lands where you want" },
    extend_comp: { type: "boolean" } }, ["song"], {},
  async (s, a) => {
    const file = resolveSong(a.song);
    const analysis = await analysisFor(file, false);
    await evalHost("import_media", { paths: [file] });
    const itemName = path.basename(file);
    const start = a.start_s !== undefined ? Number(a.start_s) : 0;
    const inS = Math.max(0, Math.min(analysis.duration_s - 0.1, Number(a.in_s) || 0));
    const clip = await evalHost("add_clip", { item_name: itemName, comp: a.comp,
      start_s: start, in_s: inS, out_s: analysis.duration_s });
    let extended = null;
    if (a.extend_comp)
      extended = await evalHost("run_extendscript", { code:
        "var c=null,i;for(i=1;i<=app.project.numItems;i++){var it=app.project.item(i);"
        + "if(it instanceof CompItem&&it.name===" + JSON.stringify(a.comp || "") + ")c=it;}"
        + "if(!c)c=app.project.activeItem;var need=" + (start + analysis.duration_s - inS)
        + ";if(c.duration<need)c.duration=need;c.duration" });
    // offset_s maps SONG time to comp time: comp_t = song_t + offset_s
    return Object.assign({ layer: clip.layer, item: itemName, offset_s: start - inS, in_s: inS,
      comp_end_s: start + analysis.duration_s - inS, comp_extended_to_s: extended && extended.result },
      summary(analysis));
  });

tool("beat_control",
  "Make (or refresh) a guide null named BEAT in the comp with keyframed "
  + "Slider Controls any expression can read: Beat (1 at every beat, decaying "
  + "to 0), Bar (same on downbeats), Bass (0→strength→0 around each bass hit, "
  + "150 ms), Energy (0-1 every 0.25 s), BPM (constant). Also drops comp "
  + "markers on bars and the drop. offset_s = where the song starts in the "
  + "comp (add_music's offset_s). Then use beat_effects or your own "
  + "expressions: thisComp.layer(\"BEAT\").effect(\"Bass\")(\"Slider\").",
  { song: { type: "string" }, comp: { type: "string" }, offset_s: { type: "number" },
    layer_name: { type: "string" },
    markers: { type: "string", description: "bars (default), beats, sections, or none" },
    from_s: { type: "number", description: "comp time to start at (default 0): the music layer's in point, so nothing lands on an inaudible head" },
    until_s: { type: "number", description: "comp time to stop at (default: the whole song)" } },
  ["song"], {},
  async (s, a) => {
    const file = resolveSong(a.song);
    const an = await analysisFor(file, false);
    const off = Number(a.offset_s) || 0;
    const name = a.layer_name || "BEAT";
    let found = await evalHost("find_layer", { comp: a.comp, name });
    let layer = found.index;
    if (!layer) layer = (await evalHost("add_null", { comp: a.comp, name, guide: true })).layer;
    const beatLen = an.beat_s;
    const beatKeys = [], barKeys = [], bassKeys = [], energyKeys = [];
    for (const t of an.beats) { beatKeys.push([off + t, 1], [off + t + beatLen * 0.9, 0]); }
    for (const t of an.downbeats) { barKeys.push([off + t, 1], [off + t + beatLen * 4 * 0.9, 0]); }
    for (const h of an.bass_hits) { bassKeys.push([off + h.t - 0.02, 0], [off + h.t, h.strength], [off + h.t + 0.15, 0]); }
    an.energy.forEach((e, i) => energyKeys.push([off + i * an.energy_step_s, e]));
    // A trimmed song (add_music in_s) starts before comp time 0: keys and
    // markers before 0 (or past until_s) are dropped, not written negative.
    const until = a.until_s !== undefined ? Number(a.until_s) : Infinity;
    const from = a.from_s !== undefined ? Math.max(0, Number(a.from_s) || 0) : 0;
    const inRange = (k) => k[0] >= from - 1e-6 && k[0] <= until;
    const dedupe = (keys) => { const m = new Map(); for (const k of keys.filter(inRange)) m.set(Math.round(k[0] * 1000), k); return [...m.values()].sort((x, y) => x[0] - y[0]); };
    const out = { layer, name, offset_s: off, sliders: {} };
    out.sliders.Beat = (await sliderKeys(a.comp, layer, "Beat", dedupe(beatKeys))).keys;
    out.sliders.Bar = (await sliderKeys(a.comp, layer, "Bar", dedupe(barKeys))).keys;
    out.sliders.Bass = (await sliderKeys(a.comp, layer, "Bass", dedupe(bassKeys))).keys;
    out.sliders.Energy = (await sliderKeys(a.comp, layer, "Energy", dedupe(energyKeys))).keys;
    await evalHost("set_slider_keys", { comp: a.comp, layer, effect_name: "BPM", value: an.bpm });
    const mode = a.markers || "bars";
    if (mode !== "none") {
      const marks = [];
      if (mode === "beats") an.beats.forEach((t, i) => marks.push({ t: off + t, comment: "♪ beat " + (i + 1) }));
      else if (mode === "bars") an.downbeats.forEach((t, i) => marks.push({ t: off + t, comment: "♪ bar " + (i + 1) }));
      // drop_s = 0 means the song opens at full energy — nothing to mark
      if (an.drop_s !== null && an.drop_s > 0.5) marks.push({ t: off + an.drop_s, comment: "♪ DROP" });
      for (const sec of an.sections) if (sec.kind !== "drop") marks.push({ t: off + sec.start_s, comment: "♪ " + sec.kind });
      const kept = marks.filter((m) => m.t >= from - 1e-6 && m.t <= until);
      let r = null;
      if (!kept.length) r = await evalHost("set_markers", { comp: a.comp, markers: [], clear_prefix: "♪" });
      for (let i = 0; i < kept.length; i += 300)
        r = await evalHost("set_markers", { comp: a.comp, markers: kept.slice(i, i + 300),
          clear_prefix: i === 0 ? "♪" : undefined });
      out.markers = r && r.total;
      // markers_written counts the grid asked for (beats/bars, or the
      // sections); the DROP marker is reported on its own.
      const isGrid = (m) => /^♪ (beat|bar) /.test(m.comment);
      out.markers_written = mode === "sections" ? kept.filter((m) => m.comment !== "♪ DROP").length : kept.filter(isGrid).length;
      out.markers_total = kept.length;
      out.drop_marker = kept.some((m) => m.comment === "♪ DROP");
    }
    out.from_s = from; out.until_s = until === Infinity ? null : until;
    out.expression_example = "thisComp.layer(\"" + name + "\").effect(\"Bass\")(\"Slider\")";
    out.drop_comp_s = an.drop_s === null ? null : off + an.drop_s;
    return out;
  });

tool("cut_to_beats",
  "Lay clips on the beat grid: each clip runs for pattern[k] beats (or bars "
  + "with on:'bars'), back to back from the first grid point at/after "
  + "start_s (comp seconds). items = footage names from the project; they "
  + "cycle if there are more cuts than items, each reuse continuing from "
  + "where that item left off. Uses add_clip, so clips land under existing "
  + "layers. Returns the cut list.",
  { song: { type: "string" }, comp: { type: "string" },
    items: { type: "array", items: { type: "string" } },
    offset_s: { type: "number", description: "song start in comp (add_music's offset_s)" },
    start_s: { type: "number" }, end_s: { type: "number" },
    pattern: { type: "array", items: { type: "number" },
      description: "beats per cut, e.g. [4,4,2,2,1,1,1,1] (default)" },
    on: { type: "string", description: "beats (default) or bars" },
    count: { type: "number" },
    source_in_s: { type: "array", items: { type: "number" },
      description: "per item: where in the source to start (default 0)" } },
  ["song", "items"], {},
  async (s, a) => {
    if (!Array.isArray(a.items) || !a.items.length) throw new Error("items: give at least one footage name.");
    const an = await analysisFor(resolveSong(a.song), false);
    const off = Number(a.offset_s) || 0;
    const grid = (a.on === "bars" ? an.downbeats : an.beats).map((t) => off + t);
    const count = a.count || a.items.length;
    const cuts = audio.planCuts(grid, a.pattern, Number(a.start_s) || 0, count,
                                a.end_s !== undefined ? Number(a.end_s) : null);
    if (!cuts.length) throw new Error("No grid points at/after start_s " + (a.start_s || 0)
      + " — the song's grid runs " + grid[0] + "–" + grid[grid.length - 1] + "s in comp time.");
    const cursor = a.items.map((_, i) => Number((a.source_in_s || [])[i]) || 0);
    const placed = [];
    for (let k = 0; k < cuts.length; k++) {
      const i = k % a.items.length;
      const dur = cuts[k].end_s - cuts[k].start_s;
      const r = await evalHost("add_clip", { item_name: a.items[i], comp: a.comp,
        start_s: cuts[k].start_s, in_s: cursor[i], out_s: cursor[i] + dur });
      cursor[i] += dur;
      placed.push({ item: a.items[i], layer: r.layer, comp_in_s: r.comp_start_s,
        comp_out_s: r.comp_end_s, source_in_s: r.source_in_s, beats: cuts[k].beats });
    }
    return { cuts: placed.length, grid: a.on === "bars" ? "bars" : "beats", bpm: an.bpm,
      first_cut_s: placed[0].comp_in_s, last_cut_end_s: placed[placed.length - 1].comp_out_s, placed };
  });

tool("beat_effects",
  "Wire a layer to the BEAT sliders (beat_control first): style punch "
  + "(scale pumps on hits), shake (position jitter on hits), zoom (slow "
  + "scale on bars), flash (a white ADD solid above the layer that pops on "
  + "hits), opacity (dips between beats). on: bass (default), beat, bar or energy. "
  + "amount: punch/zoom = percent (8), shake = px (12), flash/opacity = "
  + "percent (60). Expressions stay editable in AE.",
  { layer: { type: "number" }, comp: { type: "string" },
    style: { type: "string" }, on: { type: "string" }, amount: { type: "number" },
    control_layer: { type: "string" } }, ["layer", "style"], {},
  async (s, a) => {
    const ctl = a.control_layer || "BEAT";
    const sliderName = a.on === "beat" ? "Beat" : a.on === "bar" ? "Bar" : a.on === "energy" ? "Energy" : "Bass";
    const src = "thisComp.layer(\"" + ctl + "\").effect(\"" + sliderName + "\")(\"Slider\")";
    const found = await evalHost("find_layer", { comp: a.comp, name: ctl });
    if (!found.index) throw new Error("No '" + ctl + "' layer in the comp — run beat_control first.");
    const amt = a.amount;
    const T = "ADBE Transform Group";
    let r;
    switch (String(a.style)) {
      case "punch": {
        const k = (amt !== undefined ? amt : 8) / 100;
        r = await evalHost("set_expression", { comp: a.comp, layer: a.layer, path: [T, "ADBE Scale"],
          expression: "var p = " + src + ";\nvalue * (1 + " + k + " * p)" });
        break;
      }
      case "zoom": {
        const k = (amt !== undefined ? amt : 5) / 100;
        r = await evalHost("set_expression", { comp: a.comp, layer: a.layer, path: [T, "ADBE Scale"],
          expression: "var p = thisComp.layer(\"" + ctl + "\").effect(\"Bar\")(\"Slider\");\nvalue * (1 + " + k + " * p)" });
        break;
      }
      case "shake": {
        const px = amt !== undefined ? amt : 12;
        r = await evalHost("set_expression", { comp: a.comp, layer: a.layer, path: [T, "ADBE Position"],
          expression: "var p = " + src + ";\nseedRandom(index + Math.floor(time * 30), true);\n"
            + "value + [random(-" + px + ", " + px + "), random(-" + px + ", " + px + ")] * p" });
        break;
      }
      case "opacity": {
        const k = amt !== undefined ? amt : 60;
        r = await evalHost("set_expression", { comp: a.comp, layer: a.layer, path: [T, "ADBE Opacity"],
          expression: "var p = " + src + ";\nvalue * (1 - " + (k / 100) + " * (1 - p))" });
        break;
      }
      case "flash": {
        const k = amt !== undefined ? amt : 60;
        const solid = await evalHost("add_solid", { comp: a.comp, name: "FLASH (" + sliderName + ")",
          color: [1, 1, 1], above_layer: a.layer, blend: "add" });
        r = await evalHost("set_expression", { comp: a.comp, layer: solid.layer, path: [T, "ADBE Opacity"],
          expression: src + " * " + k });
        r.solid_layer = solid.layer;
        break;
      }
      default:
        throw new Error("style must be punch, zoom, shake, opacity or flash.");
    }
    if (r && r.error) throw new Error("After Effects rejected the expression: " + r.error);
    return Object.assign({ style: a.style, on: sliderName, control: ctl }, r);
  });

tool("set_expression",
  "Set (or clear with an empty string) an expression on a property by "
  + "match-name path, e.g. [\"ADBE Transform Group\",\"ADBE Scale\"] or "
  + "[\"ADBE Effect Parade\",\"Glow\",\"ADBE Glo2-0002\"]. Returns AE's "
  + "expression error text if it did not compile.",
  { layer: { type: "number" }, comp: { type: "string" },
    path: { type: "array", items: { type: "string" } }, expression: { type: "string" } },
  ["layer", "path"], {});

tool("add_solid",
  "Add a comp-sized solid: color [r,g,b] 0-1, optional above_layer, blend "
  + "add/screen, adjustment:true for an adjustment layer, start_s/end_s, opacity.",
  { comp: { type: "string" }, name: { type: "string" }, color: { type: "array" },
    above_layer: { type: "number" }, blend: { type: "string" }, adjustment: { type: "boolean" },
    start_s: { type: "number" }, end_s: { type: "number" }, opacity: { type: "number" } }, [], {});

tool("add_null", "Add a null object layer (guide:true keeps it out of renders).",
  { comp: { type: "string" }, name: { type: "string" }, guide: { type: "boolean" },
    shy: { type: "boolean" } }, [], {});

tool("set_markers",
  "Comp markers (or a layer's with layer set): [{t, comment, duration}] in "
  + "comp seconds; clear_prefix removes existing markers whose comment starts "
  + "with it first.",
  { comp: { type: "string" }, layer: { type: "number" },
    markers: { type: "array", items: { type: "object" } },
    clear_prefix: { type: "string" } }, ["markers"], {});

// ------------------------------------------------- other MCP servers
tool("list_layers",
  "Every layer in a comp (default: the active comp): index, name, kind "
  + "(footage/solid/null/text/comp/audio), in/out, whether it carries audio "
  + "or video, and the source file where there is one.",
  { comp: { type: "string" } }, [], { readonly: true },
  (s, a) => evalHost("list_layers", { comp: a.comp }));

tool("music_undo",
  "Take back what Claude Music put in a comp: remove layers by name (the "
  + "music layer, BEAT, FLASH solids), clear expressions on the listed "
  + "properties, and remove the ♪ markers. Only what is named is touched.",
  { comp: { type: "string" },
    layers: { type: "array", items: {},
      description: "names (topmost layer of each name goes) or {name, index, start_s} to remove one layer by identity" },
    expressions: { type: "array", items: { type: "object" },
      description: "[{layer: index or name, path: [match names]}]" },
    clear_markers: { type: "boolean" } }, [], {},
  async (s, a) => {
    const out = { comp: a.comp || null, removed: [], cleared: 0, markers_cleared: false };
    for (const e of a.expressions || []) {
      let idx = e.layer;
      if (typeof idx === "string") idx = (await evalHost("find_layer", { comp: a.comp, name: idx })).index;
      if (!idx) continue;
      const r = await evalHost("set_expression", { comp: a.comp, layer: idx, path: e.path, expression: "" });
      if (!r.error) out.cleared += 1;
    }
    if (a.layers && a.layers.length) {
      const r = await evalHost("remove_layers", { comp: a.comp, names: a.layers });
      out.removed = r.removed || []; out.missed = r.missed || [];
    }
    if (a.clear_markers !== false) {
      await evalHost("set_markers", { comp: a.comp, markers: [], clear_prefix: "♪" });
      out.markers_cleared = true;
    }
    return out;
  });

tool("set_music_dir",
  "Set the song library folder (music_dirs in ~/.claude-assistant.json); "
  + "empty resets to ~/Music/Claude Assistant.",
  { dir: { type: "string" } }, [], {},
  (s, a) => {
    const dir = String(a.dir || "").trim();
    track.writeConfig({ music_dirs: dir ? [dir] : [] });
    return { music_dirs: musicDirs(), library_dir: libraryDir() };
  });

// ------------------------------------------------------------ style study
// "Training" done honestly: a finished edit is measured (cuts, shot
// lengths, exposure, cast) and, with a Gemini key, watched; the result is
// a profile file future turns read. Same file as the Resolve panel's.
tool("study_url",
  "Paste-a-link studying: download a video from a URL (TikTok, Instagram, "
  + "YouTube — anything yt-dlp handles; needs 'brew install yt-dlp ffmpeg' "
  + "once) into ~/ClaudeAssistantStudy, ready for study_edit. Only study "
  + "content you are entitled to view; the download is for local analysis. "
  + "Nothing is added to the project.",
  { url: { type: "string" } }, ["url"], { readonly: true }, async (s, a) => {
    const url = String(a.url || "").trim();
    if (!/^https?:\/\//i.test(url)) throw new Error("study_url needs an http(s) link.");
    if (!s._testDownload && !style.findYtDlp())
      throw new Error("yt-dlp is not installed — it is what fetches the video. The panel can install it "
        + "itself: run install_yt_dlp (no Homebrew needed). ffmpeg is NOT required; without it After "
        + "Effects reads the frames.");
    const file = s._testDownload ? await s._testDownload(url, style.STUDY_DIR)
                                 : await style.downloadVideo(url, style.STUDY_DIR);
    const out = { downloaded: file, url, size_mb: Math.round(fs.statSync(file).size / 1048576 * 10) / 10 };
    if (style.findFfmpeg()) { try { out.probe = await style.probeVideo(file); } catch (e) { out.probe = { note: e.message }; } }
    else out.frames_from = "After Effects (no ffmpeg here) — study_edit will ask once before importing the video into a temporary folder";
    out.next = "study_edit with this file (source = the link), then watch_video with profile car-edits and the same source.";
    return out;
  });

tool("study_edit",
  "Study a finished edit from a video FILE (the one study_url downloaded, or "
  + "any local video) and distil its style into a persistent profile "
  + "(~/ClaudeAssistantStyle/<name>.json, the same file the DaVinci Resolve "
  + "panel writes): a thumbnail every interval_s (default 0.5 s) via ffmpeg, "
  + "cuts as big neighbour-sample pixel diffs (cut_threshold, default 8% mean "
  + "— calibrate against diff_series on the first run), each shot's exposure "
  + "and cast, merged as one entry (a re-study of the same source replaces "
  + "it). With ffmpeg installed a 60 s reel takes a few seconds and nothing "
  + "in the project is touched. WITHOUT ffmpeg After Effects decodes the "
  + "video itself — slower, and it imports the file into a temporary folder "
  + "it removes again, so the panel asks the user once.",
  { file: { type: "string" },
    name: { type: "string", description: "Profile name (default car-edits)." },
    source: { type: "string", description: "Label for what is studied (default the file name) — use the link." },
    interval_s: { type: "number" }, cut_threshold: { type: "number" },
    via: { type: "string", description: "'ffmpeg' (default when installed) or 'after-effects' to force AE to read the frames." } },
  ["file"], { readonlyWhen: (a) => !!style.findFfmpeg() && a.via !== "after-effects" }, async (s, a) => {
    const file = String(a.file || "");
    if (!fs.existsSync(file)) throw new Error("No such file: " + file);
    const interval = Math.max(0.1, Number(a.interval_s) || 0.5);
    const viaAe = a.via === "after-effects" || !style.findFfmpeg();
    let probe = null, frames = null;
    if (viaAe) {
      frames = await style.sampleFramesViaAe(file, { interval_s: interval, host: evalHost,
        onProgress: (pr) => sendUI("study_progress", { done: pr.done, total: pr.total,
          text: "Reading frame " + pr.done + " of " + pr.total + " in After Effects…" }, false) });
      probe = frames.source || null;
      sendUI("study_progress", { done: 0, total: 0, text: "" }, false);
    } else {
      try { probe = await style.probeVideo(file); } catch (e) {}
      frames = await style.sampleFrames(file, { interval_s: interval });
    }
    // the study first (seconds), then load → merge → save in one go
    const r = await style.studyFile(file, { frames, interval_s: interval, cut_threshold: a.cut_threshold,
                                            source: a.source, fps: probe && probe.fps,
                                            expect_duration_s: probe && probe.duration_s });   // throws on a truncated decode
    if (probe && probe.duration_s) r.entry.duration_s = probe.duration_s;   // the container's exact length (coverage checked above)
    r.entry.sampled_with = viaAe ? "after-effects" : "ffmpeg";
    if (viaAe && probe) { r.entry.project_bpc = probe.project_bpc || null; r.entry.working_space = probe.working_space || null; }
    const loaded = style.loadProfile(a.name || "car-edits");
    style.mergeEntry(loaded.profile, r.entry);
    const aggregate = style.saveProfile(loaded.profile, loaded.file);
    const e = r.entry;
    const out = { studied: e.source, file, sampled_with: e.sampled_with, samples: e.samples_counted, interval_s: e.interval_s,
      cut_threshold: e.cut_threshold, duration_s: e.duration_s, cuts: e.cuts,
      cuts_per_minute: e.duration_s ? +(60 * e.cuts / e.duration_s).toFixed(1) : null,
      shots: e.shots.length, shot_lengths_s: e.shot_lengths_s.slice(0, 60), diff_series: r.diffs.slice(0, 150),
      profile_file: loaded.file, aggregate };
    if (r.warnings.length) out.stride_warning = r.warnings.join(" ");
    if (viaAe) out.colour_note = "Frames came through After Effects, so exposure and cast carry the project's "
      + "colour management (" + (probe && probe.project_bpc ? probe.project_bpc + " bpc" : "unknown depth")
      + (probe && probe.working_space ? ", " + probe.working_space : "") + "). Entries sampled with ffmpeg are "
      + "not exactly comparable on those two numbers; cuts and shot lengths are.";
    if (e.notes_kept) out.notes_kept = "the Gemini content notes from the earlier study of this source were kept";
    if (loaded.recoveredFrom)
      out.profile_recovered = "Previous profile was unreadable; preserved at " + loaded.recoveredFrom + " (nothing was overwritten silently).";
    return out;
  });

tool("watch_video",
  "Gemini video eyes: upload a LOCAL video file (e.g. the file study_url "
  + "downloaded) to Google's Gemini API and have it actually WATCH the "
  + "footage — shot types, subjects, structure, look, text and transitions — "
  + "the content half pixel statistics cannot see. Needs a Gemini API key "
  + "stored via set_gemini_key (free at aistudio.google.com). With profile + "
  + "source the answer is merged into that style-profile entry as "
  + "content_notes. The file goes to Google for analysis and is deleted "
  + "there right after (48h auto-expiry is the backstop).",
  { file: { type: "string" }, question: { type: "string" }, model: { type: "string" },
    low_res: { type: "boolean" }, profile: { type: "string" }, source: { type: "string" } },
  ["file"], { readonly: true }, async (s, a) => {
    const key = style.geminiKey();
    if (!key) throw new Error("No Gemini API key stored. Get a free one at aistudio.google.com (Get API key), then run set_gemini_key.");
    const file = String(a.file || "");
    if (!fs.existsSync(file)) throw new Error("No such file: " + file);
    const doReq = s._testHttp || style.httpsRequest;
    const w = await style.watchVideo(doReq, key, file, { question: a.question, model: a.model, low_res: a.low_res });
    const out = { model: w.model, answer: w.answer, tokens: w.tokens };
    if (a.profile && w.answer) {
      // merge only into the entry for THIS source (or this file) — never
      // into "the last one", which in a /train run is the previous link
      try {
        const read = style.readProfile(a.profile);
        const src = String(a.source || "");
        const entry = read.profile && (read.profile.edits.find((e) => e.source === src)
          || (!src && read.profile.edits.find((e) => e.file === file)));
        if (entry) { entry.content_notes = w.answer; style.saveProfile(read.profile, read.file);
                     out.merged_into = { profile: path.basename(read.file), source: entry.source }; }
        else out.merge_note = read.profile
          ? "no entry with source " + JSON.stringify(src || "(none given)") + " in " + path.basename(read.file)
            + " — run study_edit with that source first; entries: " + JSON.stringify(style.listSources(read.profile))
          : "no profile " + JSON.stringify(a.profile) + " yet — run study_edit first";
      } catch (e) { out.merge_note = "could not merge: " + e.message; }
    }
    return out;
  });

tool("gemini_status",
  "Whether a Gemini API key is configured (env GEMINI_API_KEY or "
  + "~/.claude-assistant.json) — shows only its last 4 characters; validate: "
  + "true also checks it against Google's models endpoint (one free call).",
  { validate: { type: "boolean" } }, [], { readonly: true }, async (s, a) => {
    const key = style.geminiKey();
    if (!key) return { key_stored: false, config_file: style.CONFIG_FILE,
      how_to: "set_gemini_key with a key from aistudio.google.com (Get API key)" };
    const out = { key_stored: true, key_ending: "..." + key.slice(-4),
      source: process.env.GEMINI_API_KEY ? "environment" : style.CONFIG_FILE };
    if (a.validate) {
      const doReq = s._testHttp || style.httpsRequest;
      const check = await style.geminiCall(doReq, "https://" + style.GEMINI_HOST + "/v1beta/models",
        { timeoutMs: 20000, headers: { "x-goog-api-key": key } });
      out.valid = check.status === 200;
      if (!out.valid) out.problem = style.geminiErrorText(check.status, check.json);
    }
    return out;
  });

tool("set_gemini_key",
  "Store the Gemini API key (from aistudio.google.com) in ~/.claude-assistant.json "
  + "(mode 0600) after checking it against Google. Never echoed back.",
  { key: { type: "string" } }, ["key"], { readonly: true }, async (s, a) => {
    const key = String(a.key || "").trim();
    if (key.length < 20 || /\s/.test(key)) throw new Error("That does not look like an API key.");
    const doReq = s._testHttp || style.httpsRequest;
    const check = await style.geminiCall(doReq, "https://" + style.GEMINI_HOST + "/v1beta/models",
      { timeoutMs: 20000, headers: { "x-goog-api-key": key } });
    if (check.status !== 200) throw new Error("Key stored NOWHERE — validation failed: " + style.geminiErrorText(check.status, check.json));
    track.writeConfig({ gemini_api_key: key });
    return { stored: true, file: track.CONFIG_FILE, key_ending: "..." + key.slice(-4), validated: "models list call succeeded" };
  });

tool("media_tools",
  "What the style study needs and what is actually installed here: yt-dlp "
  + "(fetches the videos), ffmpeg (OPTIONAL — After Effects reads the frames "
  + "when it is missing), and whether After Effects is allowed to write "
  + "files. Call this first whenever a study fails, and read the advice back "
  + "to the user verbatim. Read-only.",
  {}, [], { readonly: true }, async () => {
    const yt = style.findYtDlp(), ff = style.findFfmpeg();
    const out = { bin_dir: BIN_DIR, yt_dlp: null, ffmpeg: null, advice: [] };
    if (yt) {
      out.yt_dlp = { path: yt, version: await style.binVersion(yt), installed_by_panel: yt.indexOf(BIN_DIR) === 0 };
      out.yt_dlp.age_days = style.ytDlpAgeDays(out.yt_dlp.version);
    }
    if (ff) out.ffmpeg = { path: ff, version: await style.binVersion(ff) };
    try {
      const ov = await evalHost("get_project_overview", {});
      out.after_effects = { reachable: true, scripting_write_enabled: !!ov.scripting_write_enabled };
    } catch (e) { out.after_effects = { reachable: false, error: e.message }; }
    const aeOk = out.after_effects.reachable && out.after_effects.scripting_write_enabled;
    out.can_download = !!yt;
    out.can_read_frames = !!ff || aeOk;
    out.frames_come_from = ff ? "ffmpeg (fast)" : aeOk ? "After Effects itself — slower, and it asks before importing" : "nowhere yet";
    if (!yt) out.advice.push("yt-dlp is missing, so no link can be downloaded. Run install_yt_dlp — the panel fetches the official standalone build into its own bin folder. No Homebrew needed.");
    if (!ff) out.advice.push("ffmpeg is missing. That is fine: After Effects decodes the video instead. Installing ffmpeg would only make studying faster, and Homebrew is not required for anything here.");
    if (!aeOk && !ff) out.advice.push(out.after_effects.reachable
      ? "After Effects will not let scripts write files, so it cannot hand over frames either. Turn on Preferences > Scripting & Expressions > Allow Scripts to Write Files and Access Network."
      : "After Effects is not answering the panel, so it cannot read frames: " + out.after_effects.error);
    if (yt && out.yt_dlp.age_days !== null && out.yt_dlp.age_days > 90)
      out.advice.push("This yt-dlp is " + out.yt_dlp.age_days + " days old. Instagram and TikTok change how they serve video every few weeks, so an old build is the usual reason a link stops downloading — run install_yt_dlp to replace it.");
    if (yt && out.can_read_frames) out.advice.push("Everything the study needs is here. If a link still fails to download, yt-dlp is probably out of date — install_yt_dlp fetches the newest build.");
    return out;
  });

tool("install_yt_dlp",
  "Install (or update) yt-dlp — the downloader behind /train — by fetching "
  + "the project's own standalone build from its GitHub releases into the "
  + "panel's bin folder and making it executable. No Homebrew, no Python. "
  + "Instagram and TikTok change often and yt-dlp's fixes follow within "
  + "days, so running this again is the usual cure for a link that suddenly "
  + "will not download. Downloads an executable, so the panel asks first.",
  { url: { type: "string", description: "Override the download URL (rarely needed)." },
    nightly: { type: "boolean", description: "After installing, switch to the nightly channel — extractor fixes land there days before the stable build." } },
  [], {}, async (s, a) => {
    const url = String(a.url || style.YT_DLP_URL());
    const before = style.findYtDlp();
    const dest = path.join(BIN_DIR, process.platform === "win32" ? "yt-dlp.exe" : "yt-dlp");
    const got = await (s._testFetch ? s._testFetch(url, dest) : style.downloadTo(url, dest));
    // Check the bytes against the checksums the release publishes before
    // anything is made executable.
    const asset = url.split("/").pop();
    const sum = s._testVerify ? await s._testVerify(dest, asset) : await style.verifyChecksum(dest, asset);
    if (sum.checked && !sum.match) {
      try { fs.unlinkSync(dest); } catch (e) {}
      throw new Error("The download did not match the checksum yt-dlp publishes (" + sum.got.slice(0, 12)
        + "… vs " + sum.want.slice(0, 12) + "…), so it was deleted. Try again; if it keeps happening, "
        + "something between here and GitHub is altering the file.");
    }
    try { fs.chmodSync(dest, 0o755); } catch (e) {}
    const version = await style.binVersion(dest);
    if (!version)
      throw new Error("Downloaded " + dest + " (" + (got && got.bytes) + " bytes) but it would not run. "
        + "If macOS blocked it, allow it in System Settings > Privacy & Security, or in Terminal run: "
        + "xattr -d com.apple.quarantine " + JSON.stringify(dest));
    let channel = "stable";
    if (a.nightly) {
      const sw = await new Promise((done) => execFile(dest, ["--update-to", "nightly"], { timeout: 120000 },
        (err, so, se) => done(err ? String(se || err.message).slice(-200) : null)));
      channel = sw ? "stable (switching to nightly failed: " + sw + ")" : "nightly";
    }
    return { installed: dest, version, channel, bytes: got && got.bytes, from: url,
             checksum: sum.checked ? "matched the published SHA-256" : "not verified — " + sum.why,
             replaced: before && before !== dest ? before + " is still on your PATH; the panel uses its own copy" : undefined,
             note: "Run this again any time a link stops downloading — it fetches the newest build." };
  });

tool("style_profile",
  "Read a style profile (~/ClaudeAssistantStyle/<name>.json, default "
  + "car-edits — the same file the Resolve panel writes): the aggregate (cuts "
  + "per minute, shot lengths, exposure, cast tendency) plus one line per "
  + "studied edit and its content notes. Read it FIRST whenever the user "
  + "asks for an edit in their style.",
  { name: { type: "string" }, notes_chars: { type: "number", description: "content notes per edit (default 700)" } },
  [], { readonly: true }, async (s, a) => {
    const names = style.listProfiles();
    const want = String(a.name || "car-edits");
    const noProfile = PANEL === "music"
      ? "Nothing studied yet — /train <links> in the Claude Assistant panel (Window › Extensions › Claude Assistant) builds one."
      : "Nothing studied yet — /train <links> (study_url → study_edit → watch_video) builds one.";
    if (!fs.existsSync(style.profileFile(want)))
      return { profile: want, exists: false, profiles: names, hint: names.length ? "Pick one of profiles." : noProfile };
    let read;
    try { read = style.readProfile(want); }                   // a READ never moves the file
    catch (e) { return { profile: want, file: style.profileFile(want), exists: true, unreadable: true, error: e.message,
      hint: "The profile file is damaged; the next study_edit sets it aside (kept as .corrupt-*) and starts fresh." }; }
    return Object.assign({ file: read.file, exists: true, profiles: names }, style.summariseProfile(read.profile, a.notes_chars));
  });

tool("download_file",
  "Fetch a URL (e.g. a clip another MCP server generated) into "
  + "~/Library/Application Support/ClaudeAssistantAE/downloads and return "
  + "the local path — then import_media / add_clip it.",
  { url: { type: "string" }, name: { type: "string", description: "file name to save as" } },
  ["url"], { readonly: true }, async (s, a) => {
    const url = String(a.url || "");
    if (!/^https?:\/\//i.test(url)) throw new Error("download_file needs an http(s) URL.");
    let name = a.name || "";
    if (!name) { try { name = path.basename(new URL(url).pathname) || ""; } catch (e) {} }
    if (!name || !/\.[a-z0-9]{2,5}$/i.test(name)) name = (name || "download") + ".mp4";
    const dest = path.join(USER_DATA, "downloads", Date.now().toString(36) + "-" + name.replace(/[^\w.\-]+/g, "_"));
    await track.download(url, dest);
    const size = fs.statSync(dest).size;
    if (size < 1024) throw new Error("Downloaded only " + size + " bytes from " + url + " — not a media file?");
    return { file: dest, size_mb: Math.round(size / 1048576 * 10) / 10 };
  });

tool("mcp_status",
  "Which extra MCP servers (Higgsfield etc.) this panel attaches to each "
  + "turn, and which names in extra_mcp could not be found in Claude Code's "
  + "own config. Read-only.",
  {}, [], { readonly: true }, async () => {
    const cfg = track.readConfig();
    const known = track.claudeCodeServers();
    const extra = track.extraMcpServers(cfg, known);
    const inherit = mcpMode(cfg) === "inherit";
    const servers = {};
    // inherit: names Claude Code resolves itself (claude.ai connectors) are
    // attached too, even with no local definition to show a URL for.
    const names = Object.keys(extra.servers).concat(inherit ? extra.missing : []);
    for (const name of names) {
      const def = extra.servers[name] || { inherited: true };
      const seen = mcpObserved && mcpObserved.servers && mcpObserved.servers[name];
      let advice = seen ? track.mcpAdvice(name, seen, def) : "no turn has reported on it yet";
      const entry = { status: seen ? seen.status : "unknown", usable: !!seen && !advice,
        url: def.url || null,
        tools: seen ? seen.tools.map((t) => "mcp__" + name + "__" + t) : [] };
      if (def.url && !inherit && advice) {
        entry.endpoint = await track.probeMcpEndpoint(def.url);
        if (!entry.endpoint.alive) advice = "its URL is wrong: " + entry.endpoint.note
          + " Fix it in Terminal: claude mcp remove " + name + " ; claude mcp add -s user "
          + "--transport http " + name + " " + (track.KNOWN_MCP_URLS[name] || "<correct url>")
          + " ; then `claude`, /mcp, Authenticate.";
      }
      entry.problem = advice;
      servers[name] = entry;
    }
    return { extra_mcp: cfg.extra_mcp || null, mode: inherit ? "inherit" : "strict",
      attached: names,
      servers, observed_at: mcpObserved ? mcpObserved.at : null,
      missing: inherit ? [] : extra.missing, known_in_claude_code: Object.keys(known),
      hint: "'attached' only means the server is in this turn's config; "
        + "'usable' means the CLI reported it connected and listed its tools. "
        + "Never guess tool names: call only the ones listed here. mode strict = "
        + "the panel passes the server's own definition; mode inherit = the CLI "
        + "loads everything Claude Code has (claude.ai connectors included, "
        + "slower start) — mcp_connect <name> use_claude_code_connections:true." };
  });

const mcpMode = (cfg) => ((cfg || {}).extra_mcp_mode === "inherit" ? "inherit" : "strict");

tool("mcp_connect",
  "Attach an MCP server to every panel turn from now on: name as it appears "
  + "in Claude Code (claude mcp list), or name + url for a hosted server "
  + "(higgsfield = https://mcp.higgsfield.ai/mcp — the bare host is a 404). "
  + "Sign-in itself happens once in a terminal: claude mcp add -s user "
  + "--transport http <name> <url>, then run `claude`, type /mcp, "
  + "Authenticate. use_claude_code_connections:true makes the CLI load all of "
  + "Claude Code's own servers instead (claude.ai connectors included; slower "
  + "start) — the fallback when the headless run cannot reuse the sign-in. "
  + "Use enabled:false to detach.",
  { name: { type: "string" }, url: { type: "string" }, enabled: { type: "boolean" },
    use_claude_code_connections: { type: "boolean" } },
  ["name"], { readonly: true }, async (s, a) => {
    const name = String(a.name || "").trim().toLowerCase().replace(/[^a-z0-9_-]/g, "");
    if (!name || name === "ae") throw new Error("Give the server's name (letters, digits, - or _).");
    const cfg = track.readConfig();
    let extra = cfg.extra_mcp;
    if (Array.isArray(extra)) extra = Object.fromEntries(extra.map((n) => [n, true]));
    extra = Object.assign({}, extra || {});
    if (a.enabled === false) delete extra[name];
    else extra[name] = a.url ? { type: "http", url: String(a.url) } : true;
    const patch = { extra_mcp: extra };
    if (typeof a.use_claude_code_connections === "boolean")
      patch.extra_mcp_mode = a.use_claude_code_connections ? "inherit" : "strict";
    track.writeConfig(patch);
    const mode = mcpMode(Object.assign({}, cfg, patch));
    const known = track.claudeCodeServers();
    const now = track.extraMcpServers({ extra_mcp: extra }, known);
    const out = { extra_mcp: extra, mode, attached_next_turn: Object.keys(now.servers),
      missing: now.missing };
    const def = now.servers[name];
    if (def && def.url && mode === "strict") {
      out.endpoint = await track.probeMcpEndpoint(def.url);
      if (!out.endpoint.alive)
        out.next = "The URL Claude Code has for " + name + " is wrong (" + out.endpoint.note
          + ") In Terminal: claude mcp remove " + name + " ; claude mcp add -s user --transport http "
          + name + " " + (track.KNOWN_MCP_URLS[name] || "<correct url>") + " ; then `claude`, /mcp, "
          + name + ", Authenticate, /exit.";
    }
    if (!out.next) out.next = mode === "inherit"
      ? "From the next message the CLI loads Claude Code's own servers and " + name
        + "'s tools are allowed — this uses the sign-in Claude Code already has."
      : now.missing.includes(name)
        ? "Claude Code does not know '" + name + "' yet: in Terminal run  claude mcp add -s user "
          + "--transport http " + name + " " + (a.url || track.KNOWN_MCP_URLS[name] || "<url>")
          + "  then `claude`, /mcp, Authenticate, /exit. The panel picks it up on the next message."
        : "Attached from the next message (a new chat is not needed). If the next turn's NOTE says "
          + "needs sign-in even after you authenticated in Terminal, call mcp_connect " + name
          + " use_claude_code_connections:true.";
    return out;
  });

// ------------------------------------------------------------ approvals
const state = { permissionMode: "Ask before edits", approveAllEdits: false,
                pendingApproval: null, onApprovalNeeded: null };

function needsApproval(name, input) {
  const entry = TOOLS.find((t) => t.name === name);
  const mode = state.permissionMode;
  if (mode === "Always ask") return true;
  if (mode !== "Ask before edits") return false;
  if (state.approveAllEdits) return false;
  if (entry && entry.readonly) return false;
  if (entry && entry.readonlyWhen) {
    try { if (entry.readonlyWhen(input || {})) return false; } catch (e) {}
  }
  return true;
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
  if (needsApproval(name, input) && !quoteOnly) {
    const declined = await requestApproval(name, input || {});
    if (declined) return { ok: false, text: declined };
  }
  try {
    const result = await entry.fn(state, input || {});
    let images = null;
    if (result && typeof result === "object") {
      images = result._images || null;
      for (const k of Object.keys(result)) if (k[0] === "_") delete result[k];   // panel-only fields
    }
    const out = { ok: true, text: JSON.stringify(result) };
    if (images) out.images = images;
    return out;
  } catch (e) {
    return { ok: false, text: e.message || String(e) };
  }
}

function toolSchemas() {
  return TOOLS.filter((t) => !isHidden(t.name)).map((t) => ({ name: t.name, description: t.description,
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
      if (isHidden(p.name))
        return { jsonrpc: "2.0", id, result: { isError: true, content: [{ type: "text",
          text: p.name + " is not part of Claude Music — open Window > Extensions > "
            + "Claude Assistant for tracking, mattes and Mocha." }] } };
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
let history = historyLib.makeHistory(path.join(USER_DATA,
  PANEL === "music" ? "chats-music" : "chats"));
let chatId = historyLib.newChatId();
let msgLog = [];
let pendingRecap = "";
// What the CLI last reported about the extra MCP servers (system/init
// event): status + tool names. Persisted so the next chat's prompt and
// mcp_status know it too. turnExtra = the servers attached to the current turn.
const MCP_OBSERVED_FILE = path.join(USER_DATA, "mcp-observed.json");
let mcpObserved = null;
try { mcpObserved = JSON.parse(fs.readFileSync(MCP_OBSERVED_FILE, "utf8")); } catch (e) {}
let turnExtra = { servers: {}, missing: [] };
let panelContext = "";
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
  // Extra MCP servers (Higgsfield etc.) ride along on every turn.
  const cfg = track.readConfig();
  const extra = track.extraMcpServers(cfg, track.claudeCodeServers());
  const inherit = mcpMode(cfg) === "inherit";
  // inherit: the CLI loads Claude Code's own servers (connectors included) and
  // only the AE bridge is added; strict: exactly ae + the extra definitions.
  const servers = Object.assign({}, inherit ? {} : extra.servers, { ae: {
    type: "http",
    url: "http://127.0.0.1:" + bridge.port + "/mcp",
    headers: { Authorization: "Bearer " + bridge.token } } });
  fs.writeFileSync(mcpPath, JSON.stringify({ mcpServers: servers }));
  const extraNames = Object.keys(extra.servers).concat(inherit ? extra.missing : [])
    .filter((n, i, arr) => arr.indexOf(n) === i);
  turnExtra = { servers: Object.assign({}, extra.servers), missing: inherit ? [] : extra.missing };
  if (inherit) for (const n of extra.missing) turnExtra.servers[n] = { inherited: true };
  let sys = PANEL === "music" ? MUSIC_SYSTEM_PROMPT : SYSTEM_PROMPT;
  if (extraNames.length) {
    sys += "\nOther MCP servers attached this turn: " + extraNames.map((n) =>
      n + " (tools mcp__" + n + "__*)").join(", ") + ". Their results are "
      + "URLs, not files: download_file the ones you need, then import_media / "
      + "add_clip them. Say when a step spends that service's credits."
      + " 'Attached' is not 'connected': if a call returns 'No such tool "
      + "available', call mcp_status — it reports each server's real status "
      + "and tool names — and relay its problem text to the user instead of "
      + "guessing other names.";
    for (const n of extraNames) {
      const seen = mcpObserved && mcpObserved.servers && mcpObserved.servers[n];
      const advice = seen ? track.mcpAdvice(n, seen, extra.servers[n]) : null;
      if (seen && advice)
        sys += "\nLast turn " + n + " was " + seen.status + " — " + advice
          + " Until then do not call its tools.";
      else if (seen && seen.tools.length)
        sys += "\n" + n + " tools seen last turn: " + seen.tools.map((t) =>
          "mcp__" + n + "__" + t).join(", ") + ".";
      else if (track.KNOWN_MCP_TOOLS[n])
        sys += "\n" + n + " core tools (from its published server): "
          + track.KNOWN_MCP_TOOLS[n].map((t) => "mcp__" + n + "__" + t).join(", ")
          + ". mcp_status lists what this CLI actually got.";
    }
  }
  if (turnExtra.missing.length)
    sys += "\nextra_mcp names not found in Claude Code's config (not attached): "
      + turnExtra.missing.join(", ") + " — tell the user to run `claude mcp add`.";
  if (panelContext) sys += "\nPanel state right now (what the user sees): " + panelContext;
  fs.writeFileSync(sysPath, sys);
  const argv = ["-p", "--output-format", "stream-json", "--verbose"]
    .concat(inherit ? [] : ["--strict-mcp-config"])
    .concat(["--mcp-config", mcpPath, "--allowedTools", "mcp__ae__*"])
    .concat(extraNames.map((n) => "mcp__" + n + "__*"))
    .concat(["--tools", "",
             "--append-system-prompt-file", sysPath, "--model", model]);
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
    const extraNames = Object.keys(turnExtra.servers);
    if (extraNames.length || (event.mcp_servers || []).length > 1) {
      mcpObserved = track.observeMcpInit(event, extraNames);
      try { fs.writeFileSync(MCP_OBSERVED_FILE, JSON.stringify(mcpObserved)); }
      catch (e) {}
      for (const n of extraNames) {
        const advice = track.mcpAdvice(n, mcpObserved.servers[n], turnExtra.servers[n]);
        if (advice) sendUI("notice", n + " " + advice);
      }
    }
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
  const workdir = path.join(USER_DATA, "turn-" + PANEL + "-" + Date.now()
                            + "-" + Math.random().toString(36).slice(2, 7));
  if (!sessionId && pendingRecap) text = pendingRecap + "\n\n" + text;
  let argv;
  try { argv = buildTurn(workdir, model, effort); }
  catch (e) { sendUI("error", e.message); busy = false;
              sendUI("done", {}); return; }
  const child = spawn(binary, argv, { env: cliEnv(), cwd: USER_DATA,
                                      windowsHide: true });
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
    const route = slashlib.slashRoute(text, PANEL);
    sendUI("you", String(text).trim());
    if (route.kind === "unknown") { sendUI("notice", route.note); sendUI("done", {}); return true; }
    busy = true;
    runTurn(MODELS.includes(model) ? model : MODELS[0],
            EFFORTS.includes(effort) ? effort : "medium",
            route.prompt);
    return true;
  },
  approval(decision, guidance) {
    if (state.pendingApproval) state.pendingApproval.answer(decision, guidance);
  },
  newChat() {
    autosave();
    // "Yes for this session" ends with the chat it was given in: a new chat
    // reads as a fresh start, so edits are asked about again.
    const approvalsReset = state.approveAllEdits;
    state.approveAllEdits = false;
    sessionId = null; pendingRecap = "";
    chatId = historyLib.newChatId(); msgLog = [];
    return { approvals_reset: approvalsReset };
  },
  config() {
    return Promise.resolve({ models: MODELS, efforts: EFFORTS,
                             modes: PERMISSION_MODES, commands: slashlib.commandsFor(PANEL) });
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
  // The panel's own controls (Claude Music) call tools directly: the user
  // clicked, so no approval card. Throws on failure.
  async callTool(name, args) {
    const entry = TOOLS.find((t) => t.name === name);
    if (!entry || isHidden(name)) throw new Error("No tool " + name + " in this panel.");
    const result = await entry.fn(state, args || {});
    if (result && typeof result === "object") {
      delete result._images;
      if (result._panel && typeof result._panel === "object") { Object.assign(result, result._panel); delete result._panel; }
    }
    return result;
  },
  // What the panel is showing (track, analysis, comp) — appended to the
  // system prompt each turn so the notes column knows the state.
  setContext(text) { panelContext = String(text || "").slice(0, 4000); },
  panel: PANEL,
};

state.onApprovalNeeded = (pending) =>
  sendUI("approval", { name: pending.name, input: pending.input });

startBridge((kind, name, payload) => {
  if (kind === "result")
    sendUI("toolresult", { name, ok: payload.ok, ms: payload.ms });
}).then((b) => { bridge = b; });

})();
