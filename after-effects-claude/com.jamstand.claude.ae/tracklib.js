// Tracking bridge for the AE panel — the two things After Effects itself
// will not let a script do: run a tracker, and produce a moving matte.
//   * Mocha Pro: its bundled python3 exposes the documented mocha.project
//     API (Project.track_layers, AE exporters). We drive it as a child
//     process with host/mocha_job.py and apply the exports ourselves.
//   * fal.ai SAM 3: hosted video segmentation (queue REST API).
// Plain CommonJS with injectable seams so all of it runs under node in
// tests; panel.js requires it inside CEP.
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const https = require("https");
const http = require("http");
const { spawn } = require("child_process");

// ------------------------------------------------------------- config
// Shared with the Resolve plugin: one file, 0600, keys never echoed.
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

// -------------------------------------------------------------- Mocha
// Interpreter locations from the Mocha 2026.5 Python guide; the version
// folder varies, so each pattern is a list of literal segments and
// RegExp segments matched against directory entries (newest first).
function expandPattern(parts) {
  let paths = [parts[0]];
  for (const part of parts.slice(1)) {
    const next = [];
    for (const base of paths) {
      if (part instanceof RegExp) {
        let entries = [];
        try { entries = fs.readdirSync(base); } catch (e) {}
        for (const e of entries.sort().reverse())
          if (part.test(e)) next.push(path.join(base, e));
      } else next.push(path.join(base, part));
    }
    paths = next;
  }
  return paths.filter((p) => { try { return fs.existsSync(p); }
                               catch (e) { return false; } });
}

function findMochaPython(config) {
  const cfg = config || readConfig();
  const found = [];
  if (cfg.mocha_python && fs.existsSync(cfg.mocha_python))
    found.push({ python: cfg.mocha_python, kind: "config" });
  for (const p of expandPattern(["/Applications", /^Mocha Pro/i,
                                 "Contents/MacOS/python3"]))
    found.push({ python: p, kind: "standalone" });
  for (const p of expandPattern(["/Library/Application Support/Adobe/Common/"
      + "Plug-ins/7.0/MediaCore/BorisFX", /^MochaPro/i, "Resources/mochaui",
      /\.app$/, "Contents/MacOS/python3"]))
    found.push({ python: p, kind: "adobe-plugin" });
  return found;
}

// Run host/mocha_job.py under Mocha's python. The script prints exactly
// one line starting with "CA_RESULT " — everything else is Mocha chatter
// that goes to mocha.log next to the job.
function runMochaJob(python, job, opts) {
  opts = opts || {};
  return new Promise((resolve, reject) => {
    fs.mkdirSync(opts.workdir, { recursive: true });
    const jobPath = path.join(opts.workdir, "job.json");
    fs.writeFileSync(jobPath, JSON.stringify(job, null, 2));
    const sp = opts.spawnImpl || spawn;
    let child;
    try {
      child = sp(python, [opts.scriptPath, jobPath], {
        cwd: opts.workdir,
        env: Object.assign({}, process.env, { PYTHONUNBUFFERED: "1" },
                           opts.env || {}) });
    } catch (e) { return reject(e); }
    let out = "", err = "", finished = false;
    const timeoutMs = opts.timeoutMs || 30 * 60 * 1000;
    const finish = (e, r) => {
      if (finished) return;
      finished = true; clearTimeout(timer);
      if (e) reject(e); else resolve(r);
    };
    const timer = setTimeout(() => {
      try { child.kill("SIGKILL"); } catch (e) {}
      finish(new Error("Mocha job timed out after "
        + Math.round(timeoutMs / 60000) + " min. Log tail:\n"
        + (out + "\n" + err).trim().slice(-800)));
    }, timeoutMs);
    child.stdout.on("data", (d) => { out += d; if (opts.onLog) opts.onLog(String(d)); });
    child.stderr.on("data", (d) => { err += d; if (opts.onLog) opts.onLog(String(d)); });
    child.on("error", (e) => finish(new Error("Could not run Mocha's python3 ("
      + python + "): " + e.message)));
    child.on("close", (code) => {
      const log = (out + "\n" + err).trim();
      try { fs.writeFileSync(path.join(opts.workdir, "mocha.log"), log); }
      catch (e) {}
      const line = out.split("\n").filter((l) => l.startsWith("CA_RESULT ")).pop();
      let result = null;
      if (line) { try { result = JSON.parse(line.slice(10)); } catch (e) {} }
      if (!result)
        return finish(new Error("Mocha python exited " + code
          + " without a result. Log tail:\n" + log.slice(-1500)));
      if (!result.ok)
        return finish(new Error("Mocha: " + result.error
          + (result.traceback ? "\n" + String(result.traceback).slice(-1200) : "")));
      const data = result.data || {};
      data.log_tail = log.slice(-600);
      finish(null, data);
    });
  });
}

// ------------------------------------------- AE keyframe data (text)
// "Adobe After Effects 8.0 Keyframe Data": tab-separated; header lines
// are indented, block headers are not ("Effects<TAB>Corner Pin #1<TAB>
// Upper Left"), then an indented "Frame" column line and indented rows.
function parseAeKeyframeText(text) {
  const lines = String(text).replace(/^﻿/, "").replace(/\r\n?/g, "\n")
    .split("\n");
  if (!/Adobe After Effects .*Keyframe Data/i.test(lines[0] || ""))
    throw new Error("Not an After Effects keyframe data file (first line: "
      + JSON.stringify((lines[0] || "").slice(0, 60)) + ")");
  const header = {}, blocks = [];
  let cur = null;
  for (const raw of lines.slice(1)) {
    if (!raw.trim()) continue;
    if (/^End of Keyframe Data/i.test(raw.trim())) break;
    if (raw[0] !== "\t") {
      const cols = raw.split("\t").filter((c) => c !== "");
      cur = { group: cols[0], name: cols[1] || "", prop: cols[2] || "",
              columns: [], keys: [] };
      blocks.push(cur);
      continue;
    }
    const cols = raw.split("\t").slice(1).filter((c) => c !== "");
    if (!cols.length) continue;
    if (!cur) {
      const val = parseFloat(cols[1]);
      header[cols[0].trim()] = isNaN(val) ? (cols[1] || "").trim() : val;
      continue;
    }
    if (cols[0].trim() === "Frame") {
      cur.columns = cols.slice(1).map((c) => c.trim());
      continue;
    }
    const frame = parseFloat(cols[0]);
    if (isNaN(frame)) continue;
    cur.keys.push({ frame, values: cols.slice(1).map(parseFloat)
                                        .filter((v) => !isNaN(v)) });
  }
  return { fps: header["Units Per Second"], width: header["Source Width"],
           height: header["Source Height"],
           par: header["Source Pixel Aspect Ratio"], header,
           blocks: blocks.filter((b) => b.keys.length) };
}

// ------------------------------------------- corner-pin geometry
// Mocha exports the corners of ITS planar surface, which we could not
// place through the API (the guide's Surface0X parameter path does not
// resolve). The plane's motion is a homography, so the exported quad at
// frame 0 -> frame t defines H_t, and any quad we actually want (the
// shape's bounding box by default) is H_t applied to it.
function solveLinear(A, b) {
  const n = b.length;
  const M = A.map((row, i) => row.concat([b[i]]));
  for (let c = 0; c < n; c++) {
    let p = c;
    for (let r = c + 1; r < n; r++) if (Math.abs(M[r][c]) > Math.abs(M[p][c])) p = r;
    if (Math.abs(M[p][c]) < 1e-12) return null;
    [M[c], M[p]] = [M[p], M[c]];
    for (let r = 0; r < n; r++) {
      if (r === c) continue;
      const f = M[r][c] / M[c][c];
      for (let k = c; k <= n; k++) M[r][k] -= f * M[c][k];
    }
  }
  return M.map((row, i) => row[n] / row[i]);
}

function solveHomography(src, dst) {
  const A = [], b = [];
  for (let i = 0; i < 4; i++) {
    const [x, y] = src[i], [u, v] = dst[i];
    A.push([x, y, 1, 0, 0, 0, -u * x, -u * y]); b.push(u);
    A.push([0, 0, 0, x, y, 1, -v * x, -v * y]); b.push(v);
  }
  const h = solveLinear(A, b);
  return h && h.concat([1]);
}

function applyH(H, [x, y]) {
  const w = H[6] * x + H[7] * y + H[8];
  return [(H[0] * x + H[1] * y + H[2]) / w, (H[3] * x + H[4] * y + H[5]) / w];
}

const CORNER_NAMES = {
  UL: /upper\s*left|top\s*left/i, UR: /upper\s*right|top\s*right/i,
  LL: /lower\s*left|bottom\s*left/i, LR: /lower\s*right|bottom\s*right/i,
};
function cornerBlocks(blocks) {
  const found = {};
  for (const key of Object.keys(CORNER_NAMES)) {
    found[key] = blocks.find((b) => b.group === "Effects" && CORNER_NAMES[key].test(b.prop));
    if (!found[key]) return null;
  }
  return found;
}

// Per-frame quads [UL, UR, LL, LR] keyed by frame, only where all four exist.
function cornerQuads(corners) {
  const byFrame = new Map();
  for (const key of ["UL", "UR", "LL", "LR"])
    for (const k of corners[key].keys) {
      if (!byFrame.has(k.frame)) byFrame.set(k.frame, {});
      byFrame.get(k.frame)[key] = k.values.slice(0, 2);
    }
  const quads = [];
  for (const [frame, q] of [...byFrame.entries()].sort((a, b) => a[0] - b[0]))
    if (q.UL && q.UR && q.LL && q.LR) quads.push({ frame, quad: [q.UL, q.UR, q.LL, q.LR] });
  return quads;
}

// target: {UL,UR,LL,LR} in source pixels. Returns new blocks (others
// untouched) whose corners follow the tracked plane from that target.
function retargetCornerPin(blocks, target) {
  const corners = cornerBlocks(blocks);
  if (!corners) return { blocks, retargeted: false, reason: "no 4-corner effect blocks" };
  const quads = cornerQuads(corners);
  if (!quads.length) return { blocks, retargeted: false, reason: "no complete frames" };
  const base = quads[0].quad;
  const tgt = [target.UL, target.UR, target.LL, target.LR];
  const out = {};
  let skipped = 0;
  for (const { frame, quad } of quads) {
    const H = solveHomography(base, quad);
    if (!H) { skipped += 1; continue; }
    const moved = tgt.map((p) => applyH(H, p));
    ["UL", "UR", "LL", "LR"].forEach((key, i) => {
      (out[key] = out[key] || []).push({ frame, values: moved[i] });
    });
  }
  const replaced = blocks.map((b) => {
    const key = Object.keys(corners).find((k) => corners[k] === b);
    return key ? Object.assign({}, b, { keys: out[key] || [] }) : b;
  });
  return { blocks: replaced, retargeted: true, frames: quads.length, skipped };
}

// Where does the track stop being believable? Corners leaving the frame
// and centroid jumps are the two failure modes seen live (the region ran
// off frame right, then re-locked onto the road).
function trackReport(blocks, width, height, fps) {
  const corners = cornerBlocks(blocks);
  if (!corners) return null;
  const quads = cornerQuads(corners);
  if (!quads.length) return null;
  const margin = Math.max(4, width * 0.02);
  const jumpPx = width * 0.15;
  let firstPartial = null, firstOff = null, firstJump = null, prevC = null;
  for (const { frame, quad } of quads) {
    const xs = quad.map((p) => p[0]), ys = quad.map((p) => p[1]);
    const minx = Math.min(...xs), maxx = Math.max(...xs);
    const miny = Math.min(...ys), maxy = Math.max(...ys);
    const off = maxx < 0 || minx > width || maxy < 0 || miny > height;
    const partial = minx < -margin || maxx > width + margin || miny < -margin || maxy > height + margin;
    const c = [(minx + maxx) / 2, (miny + maxy) / 2];
    if (off && firstOff === null) firstOff = frame;
    if (partial && firstPartial === null) firstPartial = frame;
    if (prevC && Math.hypot(c[0] - prevC[0], c[1] - prevC[1]) > jumpPx && firstJump === null)
      firstJump = frame;
    prevC = c;
  }
  const bad = [firstPartial, firstOff, firstJump].filter((f) => f !== null);
  const first = quads[0].frame, last = quads[quads.length - 1].frame;
  const usableUntil = bad.length ? Math.max(first, Math.min(...bad) - 1) : last;
  const rep = { frames: quads.length, first_frame: first, last_frame: last,
    first_partially_offscreen_frame: firstPartial, first_offscreen_frame: firstOff,
    first_jump_frame: firstJump, usable_until_frame: usableUntil,
    usable_until_s: fps ? Math.round(usableUntil / fps * 1000) / 1000 : null,
    verdict: usableUntil >= last ? "region stayed in frame with no jumps"
      : "region leaves the frame or jumps at frame " + Math.min(...bad)
        + " — keys after " + (fps ? (usableUntil / fps).toFixed(2) + "s" : "frame " + usableUntil)
        + " are the tracker holding onto something else" };
  return rep;
}

// ------------------------------------------------------ PNG readiness
// AE's saveFrameToPng finishes the file after the script call returns;
// a PNG is complete when it stops growing and ends with the IEND chunk.
function pngComplete(file) {
  try {
    const st = fs.statSync(file);
    if (st.size < 12) return false;
    const fd = fs.openSync(file, "r");
    const tail = Buffer.alloc(8);
    try { fs.readSync(fd, tail, 0, 8, st.size - 8); } finally { fs.closeSync(fd); }
    return tail.toString("latin1").startsWith("IEND");
  } catch (e) { return false; }
}

async function waitForPng(file, timeoutMs, opts) {
  const nap = (opts && opts.sleep) || sleep;
  const started = Date.now();
  let last = -1, stable = 0, size = 0;
  for (;;) {
    await nap((opts && opts.pollMs) || 200);
    try { size = fs.statSync(file).size; } catch (e) { size = -1; }
    stable = (size > 0 && size === last) ? stable + 1 : 0;
    last = size;
    if (stable >= 1 && pngComplete(file))
      return { bytes: size, waited_ms: Date.now() - started };
    if (Date.now() - started > (timeoutMs || 30000))
      throw new Error(size < 0
        ? "AE never created " + file + " — is 'Allow Scripts to Write Files' on?"
        : "AE is still writing " + file + " after " + Math.round(timeoutMs / 1000)
          + "s (" + size + " bytes). The render may be heavy — try Half "
          + "resolution, grab_source_frame instead of the whole comp, or wait "
          + "and try again.");
  }
}

// ------------------------------------------------------------- HTTP
function httpRequest(url, opts, body) {
  opts = opts || {};
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const mod = u.protocol === "http:" ? http : https;
    const headers = Object.assign({}, opts.headers || {});
    if (body !== undefined && body !== null && !opts.bodyFile
        && headers["Content-Length"] === undefined)
      headers["Content-Length"] = Buffer.byteLength(body);
    const req = mod.request({
      hostname: u.hostname, port: u.port || undefined,
      path: u.pathname + u.search, method: opts.method || "GET", headers,
      timeout: opts.timeoutMs || 120000,
    }, (r) => {
      if (opts.toFile) {
        const ws = fs.createWriteStream(opts.toFile);
        let bytes = 0;
        r.on("data", (d) => { bytes += d.length; });
        r.pipe(ws);
        ws.on("finish", () => resolve({ status: r.statusCode,
          headers: r.headers, text: "", json: null, bytes }));
        ws.on("error", reject);
        return;
      }
      const chunks = [];
      r.on("data", (d) => chunks.push(d));
      r.on("end", () => {
        const text = Buffer.concat(chunks).toString("utf8");
        let json = null;
        try { json = JSON.parse(text); } catch (e) {}
        resolve({ status: r.statusCode, headers: r.headers, text, json });
      });
    });
    req.on("timeout", () => req.destroy(new Error("timed out")));
    req.on("error", reject);
    if (opts.bodyFile) fs.createReadStream(opts.bodyFile).pipe(req);
    else { if (body !== undefined && body !== null) req.write(body); req.end(); }
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ------------------------------------------------------------ fal.ai
// Queue API + CDN upload, shapes verified against fal's docs and the
// @fal-ai/client storage source (initiate / initiate-multipart / PUT /
// complete). Inputs must be URLs, so the footage is uploaded first.
const FAL_REST = "https://rest.alpha.fal.ai";
const FAL_QUEUE = "https://queue.fal.run";
const MIME = { ".mp4": "video/mp4", ".mov": "video/quicktime",
               ".webm": "video/webm", ".m4v": "video/x-m4v",
               ".gif": "image/gif", ".png": "image/png",
               ".jpg": "image/jpeg", ".jpeg": "image/jpeg" };
const mimeFor = (name) => MIME[path.extname(name).toLowerCase()]
                          || "application/octet-stream";

function falError(what, r) {
  const detail = (r.json && (r.json.detail || r.json.message))
    ? JSON.stringify(r.json.detail || r.json.message) : (r.text || "").slice(0, 300);
  return new Error(what + ": HTTP " + r.status + " " + detail);
}

async function falUpload(key, filePath, opts) {
  opts = opts || {};
  const req = opts.request || httpRequest;
  const size = fs.statSync(filePath).size;
  const name = path.basename(filePath);
  const contentType = mimeFor(name);
  const auth = { Authorization: "Key " + key, "Content-Type": "application/json" };
  const threshold = opts.multipartThreshold || 90 * 1024 * 1024;
  if (size <= threshold) {
    const init = await req(FAL_REST + "/storage/upload/initiate?storage_type=fal-cdn-v3",
      { method: "POST", headers: auth },
      JSON.stringify({ content_type: contentType, file_name: name }));
    if (init.status >= 300 || !init.json || !init.json.upload_url)
      throw falError("fal upload initiate failed", init);
    const put = await req(init.json.upload_url, { method: "PUT",
      headers: { "Content-Type": contentType, "Content-Length": size },
      bodyFile: filePath, timeoutMs: 60 * 60 * 1000 });
    if (put.status >= 300) throw falError("fal upload failed", put);
    return init.json.file_url;
  }
  const init = await req(FAL_REST + "/storage/upload/initiate-multipart?storage_type=fal-cdn-v3",
    { method: "POST", headers: auth },
    JSON.stringify({ content_type: contentType, file_name: name }));
  if (init.status >= 300 || !init.json || !init.json.upload_url)
    throw falError("fal multipart initiate failed", init);
  const u = new URL(init.json.upload_url);
  const base = u.origin + u.pathname.replace(/\/$/, ""), search = u.search;
  const chunk = opts.chunkBytes || 10 * 1024 * 1024;
  const parts = [];
  const fd = fs.openSync(filePath, "r");
  try {
    for (let partNumber = 1, offset = 0; offset < size; partNumber++, offset += chunk) {
      const len = Math.min(chunk, size - offset);
      const buf = Buffer.alloc(len);
      fs.readSync(fd, buf, 0, len, offset);
      const r = await req(base + "/" + partNumber + search, { method: "PUT",
        headers: { "Content-Type": contentType, "Content-Length": len },
        timeoutMs: 20 * 60 * 1000 }, buf);
      if (r.status >= 300) throw falError("fal multipart part " + partNumber + " failed", r);
      const etag = (r.json && r.json.etag) || r.headers.etag;
      if (!etag) throw new Error("fal multipart part " + partNumber + ": no etag in reply");
      parts.push({ partNumber, etag });
      if (opts.onProgress) opts.onProgress(offset + len, size);
    }
  } finally { fs.closeSync(fd); }
  const done = await req(base + "/complete" + search,
    { method: "POST", headers: { "Content-Type": "application/json" } },
    JSON.stringify({ parts }));
  if (done.status >= 300) throw falError("fal multipart complete failed", done);
  return init.json.file_url;
}

async function falSubmit(key, model, input, opts) {
  const req = (opts && opts.request) || httpRequest;
  const r = await req(FAL_QUEUE + "/" + model, { method: "POST",
    headers: { Authorization: "Key " + key, "Content-Type": "application/json" } },
    JSON.stringify(input));
  if (r.status === 401 || r.status === 403)
    throw new Error("fal rejected the API key (HTTP " + r.status + ") — set_fal_key again.");
  if (r.status >= 300 || !r.json || !r.json.request_id)
    throw falError("fal submit failed", r);
  return { request_id: r.json.request_id,
           status_url: r.json.status_url || FAL_QUEUE + "/" + model + "/requests/" + r.json.request_id + "/status",
           response_url: r.json.response_url || FAL_QUEUE + "/" + model + "/requests/" + r.json.request_id };
}

async function falWait(key, submitted, opts) {
  opts = opts || {};
  const req = opts.request || httpRequest;
  const nap = opts.sleep || sleep;
  const started = Date.now();
  const timeoutMs = opts.timeoutMs || 30 * 60 * 1000;
  let delay = opts.pollMs || 3000, last = "";
  for (;;) {
    if (Date.now() - started > timeoutMs)
      throw new Error("fal request " + submitted.request_id + " still "
        + (last || "queued") + " after " + Math.round(timeoutMs / 60000) + " min.");
    const s = await req(submitted.status_url + "?logs=1", { method: "GET",
      headers: { Authorization: "Key " + key } });
    if (s.status === 429) { await nap(Math.min(delay * 2, 20000)); continue; }
    if (s.status >= 300) throw falError("fal status failed", s);
    const status = (s.json && s.json.status) || "";
    if (status !== last && opts.onStatus) opts.onStatus(status, s.json);
    last = status;
    if (status === "COMPLETED") break;
    if (s.json && (s.json.error || s.json.error_type))
      throw new Error("fal job failed: " + JSON.stringify(s.json.error || s.json.error_type));
    await nap(delay);
  }
  const r = await req(submitted.response_url, { method: "GET",
    headers: { Authorization: "Key " + key } });
  if (r.status >= 300) throw falError("fal result failed", r);
  return r.json;
}

async function download(url, dest, opts) {
  const req = (opts && opts.request) || httpRequest;
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  const r = await req(url, { method: "GET", toFile: dest, timeoutMs: 60 * 60 * 1000 });
  if (r.status >= 300) throw new Error("download failed: HTTP " + r.status + " " + url);
  return dest;
}

// RLM reads RLM_LICENSE (file path or port@host) and the ISV-specific
// genarts_LICENSE; a user with a license file or server puts it in the
// config as mocha_license and every Mocha child process gets it.
function mochaEnv(config) {
  const cfg = config || readConfig();
  if (!cfg.mocha_license) return {};
  return { RLM_LICENSE: String(cfg.mocha_license),
           genarts_LICENSE: String(cfg.mocha_license) };
}

const LICENSE_RE = /License Error|license|RLM|checkout/i;
const CONTEXT_RE = /rendering context|OpenGL|GL context/i;
function explainMochaError(message) {
  if (CONTEXT_RE.test(message))
    return message + "\n\nMocha's tracker needs an OpenGL rendering context "
      + "and the process it ran in could not get one. mocha_status now runs "
      + "a 3-frame probe track and tries Qt application variants "
      + "(widgets / gui / offscreen) until one tracks, then remembers it "
      + "(mocha_qt in ~/.claude-assistant.json). Rerun mocha_status; if "
      + "every variant fails, track in the Mocha GUI inside AE and hand the "
      + "exports to apply_track_file.";
  if (!LICENSE_RE.test(message)) return message;
  return message + "\n\nThis is Mocha's license, not the bridge: RLM found "
    + "no license to check out for a process outside After Effects. Fixes, "
    + "in order: (1) in AE apply Effect > Boris FX Mocha > Mocha Pro to a "
    + "layer, press its 'Mocha' button to launch the GUI and sign in / "
    + "activate, close it, then rerun mocha_status — a cached login license "
    + "should now be visible; (2) if you have a license file or server, "
    + "put its path or port@host in ~/.claude-assistant.json as "
    + "mocha_license; (3) no Mocha Pro license at all: Mocha AE (free with "
    + "AE) has no Python — track by hand there and press 'Create AE Masks' "
    + "/ 'Create Track Data' on the effect, or use ai_segment for a matte.";
}

module.exports = { pngComplete, waitForPng, solveHomography, applyH, retargetCornerPin, trackReport,
  cornerBlocks, mochaEnv, explainMochaError, CONFIG_FILE, readConfig, writeConfig, findMochaPython,
  expandPattern, runMochaJob, parseAeKeyframeText, httpRequest, falUpload,
  falSubmit, falWait, download, mimeFor, FAL_QUEUE, FAL_REST };
