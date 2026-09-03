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
        env: Object.assign({}, process.env, { PYTHONUNBUFFERED: "1" }) });
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

module.exports = { CONFIG_FILE, readConfig, writeConfig, findMochaPython,
  expandPattern, runMochaJob, parseAeKeyframeText, httpRequest, falUpload,
  falSubmit, falWait, download, mimeFor, FAL_QUEUE, FAL_REST };
