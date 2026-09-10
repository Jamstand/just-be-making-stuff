// Style study for the After Effects panel — "training" done honestly.
// A finished edit (a downloaded reel) is broken down into measurable style:
// cut rhythm, shot lengths, exposure and colour-cast tendencies, plus (with
// a Gemini key) a content read of what is on screen. It is persisted as a
// profile future sessions read: ~/ClaudeAssistantStyle/<name>.json, the
// SAME file and schema the DaVinci Resolve panel writes, so both panels
// learn from the same edits and the user can open and correct it. No model
// weights change; the profile file IS the memory.
//
// yt-dlp does the downloading and ffmpeg the frame sampling (a 60 s reel is
// ~120 thumbnail frames in a few seconds). Both: brew install yt-dlp ffmpeg.
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const https = require("https");
const { spawn } = require("child_process");

const STYLE_DIR = path.join(os.homedir(), "ClaudeAssistantStyle");
const STUDY_DIR = path.join(os.homedir(), "ClaudeAssistantStudy");
const CONFIG_FILE = path.join(os.homedir(), ".claude-assistant.json");
const SAMPLE_W = 64, SAMPLE_H = 36;              // thumbnails: plenty for level / cast / cut diffs
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function readConfig() {
  try { return JSON.parse(fs.readFileSync(CONFIG_FILE, "utf8")) || {}; } catch (e) { return {}; }
}
function geminiKey() { return process.env.GEMINI_API_KEY || readConfig().gemini_api_key || null; }

// ------------------------------------------------------------ the profile
function percentile(sorted, p) {
  if (!sorted.length) return null;
  const at = Math.min(sorted.length - 1, Math.max(0, Math.round(p * (sorted.length - 1))));
  return sorted[at];
}

// diffs[i] = mean abs pixel difference between samples i and i+1 (% of full
// scale). A run of over-threshold entries is ONE cut (a cut plus settling,
// or a whip pan) — collapse it.
function detectCuts(diffs, threshold) {
  const cuts = [];
  let inRun = false;
  for (let i = 0; i < diffs.length; i++) {
    if (diffs[i] !== null && diffs[i] >= threshold) { if (!inRun) cuts.push(i); inRun = true; }
    else if (diffs[i] !== null) inRun = false;
  }
  return cuts;
}

// Identical to the Resolve panel's styleAggregate: the two share the file.
function styleAggregate(edits) {
  const lens = edits.flatMap((e) => e.shot_lengths_s || []).sort((x, y) => x - y);
  const levels = edits.flatMap((e) => (e.shots || []).map((sh) => sh.mean_level_pct))
    .filter((v) => v !== null && v !== undefined).sort((x, y) => x - y);
  const casts = edits.flatMap((e) => (e.shots || []));
  const totalS = edits.reduce((t, e) => t + (e.duration_s || 0), 0);
  const totalCuts = edits.reduce((t, e) => t + (e.cuts || 0), 0);
  const warm = casts.filter((sh) => (sh.cast_rg || 0) > 1).length;
  const cool = casts.filter((sh) => (sh.cast_bg || 0) > 1).length;
  return {
    edits_studied: edits.length,
    total_duration_s: +totalS.toFixed(1),
    cuts_per_minute: totalS ? +(60 * totalCuts / totalS).toFixed(1) : null,
    shot_length_s: { median: percentile(lens, 0.5), p25: percentile(lens, 0.25), p75: percentile(lens, 0.75),
                     shortest: lens[0] || null, longest: lens[lens.length - 1] || null },
    mean_level_pct_median: percentile(levels, 0.5),
    dark_shot_fraction: casts.length
      ? +(casts.filter((sh) => (sh.mean_level_pct || 0) < 25).length / casts.length).toFixed(2) : null,
    cast_tendency: casts.length
      ? (warm > cool * 1.5 ? "warm-leaning" : cool > warm * 1.5 ? "cool-leaning" : "mixed/neutral") : null,
  };
}

function profileFile(name) {
  return path.join(STYLE_DIR, String(name || "car-edits").replace(/[^\w.-]+/g, "_").slice(0, 60) + ".json");
}

// Load with corruption survival: damaged bytes are kept beside the file,
// never overwritten silently — hours of study may be recoverable by hand.
function loadProfile(name) {
  fs.mkdirSync(STYLE_DIR, { recursive: true });
  const file = profileFile(name);
  let profile = null, recoveredFrom = null;
  if (fs.existsSync(file)) {
    try {
      profile = JSON.parse(fs.readFileSync(file, "utf8"));
      if (!profile || !Array.isArray(profile.edits)) throw new Error("profile has no edits array");
    } catch (e) {
      recoveredFrom = file + ".corrupt-" + Date.now().toString(36);
      try { fs.renameSync(file, recoveredFrom); } catch (e2) {}
      profile = null;
    }
  }
  if (!profile) profile = { name: path.basename(file, ".json"), edits: [] };
  return { profile, file, recoveredFrom };
}

function saveProfile(profile, file) {
  profile.aggregate = styleAggregate(profile.edits);
  profile.updated = new Date().toISOString();
  const tmp = file + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(profile, null, 2));
  fs.renameSync(tmp, file);                                   // atomic: no half-written profiles
  return profile.aggregate;
}

// A re-study of the same source replaces its entry; nothing is blended.
function mergeEntry(profile, entry) {
  profile.edits = profile.edits.filter((e) => e.source !== entry.source);
  profile.edits.push(entry);
  return profile;
}

function listProfiles() {
  try {
    return fs.readdirSync(STYLE_DIR).filter((n) => /\.json$/.test(n) && !/\.corrupt-/.test(n) && !/\.tmp$/.test(n))
      .map((n) => n.replace(/\.json$/, ""));
  } catch (e) { return []; }
}

// Compact for the model: the aggregate plus one line per edit and the
// content notes trimmed.
function summariseProfile(profile, maxNotes) {
  const cap = Number(maxNotes) || 700;
  return {
    name: profile.name, updated: profile.updated || null,
    aggregate: profile.aggregate || styleAggregate(profile.edits),
    edits: profile.edits.map((e) => {
      const lens = (e.shot_lengths_s || []).slice().sort((x, y) => x - y);
      const shots = e.shots || [];
      return { source: e.source, complete: !!e.complete, duration_s: e.duration_s, cuts: e.cuts,
        cuts_per_minute: e.duration_s ? +(60 * (e.cuts || 0) / e.duration_s).toFixed(1) : null,
        shot_length_s: { median: percentile(lens, 0.5), shortest: lens[0] || null, longest: lens[lens.length - 1] || null },
        warm_shots: shots.filter((sh) => (sh.cast_rg || 0) > 1).length,
        cool_shots: shots.filter((sh) => (sh.cast_bg || 0) > 1).length,
        content_notes: e.content_notes ? String(e.content_notes).slice(0, cap) + (String(e.content_notes).length > cap ? " …" : "") : null };
    }),
  };
}

// ------------------------------------------------------------ binaries
// GUI apps get a bare PATH on macOS, so probe the usual homes as well.
function findBin(name) {
  const homes = ["/opt/homebrew/bin", "/usr/local/bin", path.join(os.homedir(), ".local", "bin")];
  const dirs = (process.env.PATH || "").split(path.delimiter).filter(Boolean).concat(homes);
  for (const d of dirs) {
    const p = path.join(d, name);
    try { fs.accessSync(p, fs.constants.X_OK); return p; } catch (e) {}
  }
  return null;
}
const findYtDlp = () => findBin("yt-dlp");
const findFfmpeg = () => findBin("ffmpeg");
const SETUP_HINT = "One-time setup in Terminal: brew install yt-dlp ffmpeg   (then retry).";

function downloadVideo(url, dir, opts) {
  opts = opts || {};
  return new Promise((resolveP, rejectP) => {
    const bin = opts.bin || findYtDlp();
    if (!bin) return rejectP(new Error("yt-dlp is not installed — it does the actual downloading. " + SETUP_HINT));
    fs.mkdirSync(dir, { recursive: true });
    const stamp = Date.now().toString(36) + Math.random().toString(36).slice(2, 5);
    const template = path.join(dir, "study_" + stamp + ".%(ext)s");
    const child = spawn(bin, ["-f", "mp4/bv*+ba/b", "--merge-output-format", "mp4", "--no-playlist", "--no-warnings",
                              "-o", template, url], { stdio: ["ignore", "pipe", "pipe"], windowsHide: true });
    let err = "";
    child.stderr.on("data", (d) => { err += d; });
    const timer = setTimeout(() => { try { child.kill(); } catch (e) {} rejectP(new Error("Download timed out after 180s.")); }, opts.timeoutMs || 180000);
    child.on("error", (e) => { clearTimeout(timer); rejectP(new Error("Could not run yt-dlp: " + e.message)); });
    child.on("close", (code) => {
      clearTimeout(timer);
      const hit = fs.readdirSync(dir).find((n) => n.startsWith("study_" + stamp + "."));
      if (code === 0 && hit) resolveP(path.join(dir, hit));
      else rejectP(new Error("yt-dlp failed (exit " + code + "): " + err.trim().slice(-500)));
    });
  });
}

// ffmpeg -i prints the container facts to stderr; that is all probe needs.
function probeVideo(file, opts) {
  opts = opts || {};
  return new Promise((resolveP, rejectP) => {
    const bin = opts.ffmpeg || findFfmpeg();
    if (!bin) return rejectP(new Error("ffmpeg is not installed — it reads the frames. " + SETUP_HINT));
    const child = spawn(bin, ["-hide_banner", "-i", file], { stdio: ["ignore", "ignore", "pipe"], windowsHide: true });
    let err = "";
    child.stderr.on("data", (d) => { err += d; });
    const timer = setTimeout(() => { try { child.kill(); } catch (e) {} rejectP(new Error("ffmpeg probe timed out.")); }, opts.timeoutMs || 30000);
    child.on("error", (e) => { clearTimeout(timer); rejectP(new Error("Could not run ffmpeg: " + e.message)); });
    child.on("close", () => {
      clearTimeout(timer);
      const d = /Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)/.exec(err);
      const f = /(\d+(?:\.\d+)?)\s*fps/.exec(err);
      const s = /,\s*(\d{2,5})x(\d{2,5})/.exec(err);
      if (!d) return rejectP(new Error("ffmpeg could not read " + path.basename(file) + ": " + err.trim().slice(-300)));
      resolveP({ duration_s: +(Number(d[1]) * 3600 + Number(d[2]) * 60 + Number(d[3])).toFixed(2),
                 fps: f ? Number(f[1]) : null, width: s ? Number(s[1]) : null, height: s ? Number(s[2]) : null });
    });
  });
}

// Thumbnail frames every interval_s seconds as raw RGB (SAMPLE_W×SAMPLE_H).
function sampleFrames(file, opts) {
  opts = opts || {};
  const interval = Math.max(0.1, Number(opts.interval_s) || 0.5);
  return new Promise((resolveP, rejectP) => {
    const bin = opts.ffmpeg || findFfmpeg();
    if (!bin) return rejectP(new Error("ffmpeg is not installed — it reads the frames. " + SETUP_HINT));
    const args = ["-hide_banner", "-v", "error", "-i", file, "-an", "-sn", "-dn",
                  "-vf", "fps=1/" + interval + ",scale=" + SAMPLE_W + ":" + SAMPLE_H + ":flags=area",
                  "-pix_fmt", "rgb24", "-f", "rawvideo", "-"];
    const child = spawn(bin, args, { stdio: ["ignore", "pipe", "pipe"], windowsHide: true });
    const chunks = []; let err = "";
    child.stdout.on("data", (d) => chunks.push(d));
    child.stderr.on("data", (d) => { err += d; });
    const timer = setTimeout(() => { try { child.kill(); } catch (e) {} rejectP(new Error("ffmpeg sampling timed out after " + ((opts.timeoutMs || 180000) / 1000) + "s.")); }, opts.timeoutMs || 180000);
    child.on("error", (e) => { clearTimeout(timer); rejectP(new Error("Could not run ffmpeg: " + e.message)); });
    child.on("close", (code) => {
      clearTimeout(timer);
      const raw = Buffer.concat(chunks), size = SAMPLE_W * SAMPLE_H * 3;
      const n = Math.floor(raw.length / size);
      if (code !== 0 && !n) return rejectP(new Error("ffmpeg failed (exit " + code + "): " + err.trim().slice(-300)));
      const frames = [];
      for (let i = 0; i < n; i++) frames.push({ t: +(i * interval).toFixed(3), rgb: raw.subarray(i * size, (i + 1) * size) });
      resolveP(frames);
    });
  });
}

// ------------------------------------------------------------ measurement
function frameStats(rgb) {
  let r = 0, g = 0, b = 0; const n = rgb.length / 3;
  for (let i = 0; i < rgb.length; i += 3) { r += rgb[i]; g += rgb[i + 1]; b += rgb[i + 2]; }
  const pct = (v) => v / n / 255 * 100;
  const R = pct(r), G = pct(g), B = pct(b);
  return { mean_pct: [+R.toFixed(2), +G.toFixed(2), +B.toFixed(2)], level: (R + G + B) / 3, rg: R - G, bg: B - G };
}
function frameDiff(a, b) {
  const n = Math.min(a.length, b.length); let s = 0;
  for (let i = 0; i < n; i++) s += Math.abs(a[i] - b[i]);
  return n ? s / n / 255 * 100 : 0;
}
function timecode(seconds, fps) {
  const nominal = Math.max(1, Math.round(Number(fps) || 30));
  const f = Math.max(0, Math.floor(seconds * nominal));
  const pad = (n) => String(n).padStart(2, "0");
  return pad(Math.floor(f / (3600 * nominal))) + ":" + pad(Math.floor(f / (60 * nominal)) % 60) + ":"
    + pad(Math.floor(f / nominal) % 60) + ":" + pad(f % nominal);
}

// The whole edit in one pass (ffmpeg is fast enough that batching is not
// needed): shots, cuts, per-shot level and cast, as a profile entry.
async function studyFile(file, opts) {
  opts = opts || {};
  const interval = Math.max(0.1, Number(opts.interval_s) || 0.5);
  const threshold = Number(opts.cut_threshold) || 8;
  const frames = opts.frames || await sampleFrames(file, { interval_s: interval, ffmpeg: opts.ffmpeg });
  if (frames.length < 2) throw new Error("Only " + frames.length + " frame(s) came out of " + path.basename(file) + " — is it a video?");
  const fps = Number(opts.fps) || 30;
  const entry = { source: String(opts.source || path.basename(file)), file, studied: new Date().toISOString(),
    studied_with: "after-effects", samples_counted: frames.length, interval_s: interval, cut_threshold: threshold,
    duration_s: +(frames.length * interval).toFixed(1), cuts: 0, shot_lengths_s: [], shots: [], complete: true };
  let shot = null, inRun = false, prev = null;
  const diffs = [];
  const closeShot = () => {
    if (!shot || !shot.n) { shot = null; return; }
    const done = { start_s: +shot.start_s.toFixed(2), start_timecode: timecode(shot.start_s, fps),
      length_s: +(shot.n * interval).toFixed(2), mean_level_pct: +(shot.sum_level / shot.n).toFixed(2),
      cast_rg: +(shot.sum_rg / shot.n).toFixed(2), cast_bg: +(shot.sum_bg / shot.n).toFixed(2) };
    entry.shots.push(done); entry.shot_lengths_s.push(done.length_s);
    shot = null;
  };
  frames.forEach((f, i) => {
    const st = frameStats(f.rgb);
    const diff = prev ? +frameDiff(prev, f.rgb).toFixed(2) : null;
    diffs.push(diff);
    if (diff !== null && diff >= threshold) { if (!inRun) { closeShot(); entry.cuts += 1; } inRun = true; }
    else if (diff !== null) inRun = false;
    if (!shot) shot = { start_s: f.t !== undefined ? f.t : i * interval, n: 0, sum_level: 0, sum_rg: 0, sum_bg: 0 };
    shot.n += 1; shot.sum_level += st.level; shot.sum_rg += st.rg; shot.sum_bg += st.bg;
    prev = f.rgb;
  });
  closeShot();
  const hot = diffs.filter((d) => d !== null && d >= threshold).length;
  const warnings = [];
  if (diffs.length && hot > diffs.length * 0.3)
    warnings.push("Over 30% of neighbour diffs exceed the cut threshold — the edit may cut faster than this stride "
      + "resolves; re-study with a smaller interval_s.");
  return { entry, diffs, warnings };
}

// ------------------------------------------------------------ Gemini video eyes
// Same wire code as the Resolve panel (verified against the ai.google.dev
// docs there): resumable upload, poll until ACTIVE, generateContent, delete.
const GEMINI_HOST = "generativelanguage.googleapis.com";
const GEMINI_MODEL_DEFAULT = "gemini-3.7-flash";
const VIDEO_MIME = { mp4: "video/mp4", mov: "video/mov", webm: "video/webm", avi: "video/avi", mpg: "video/mpg",
                     mpeg: "video/mpeg", wmv: "video/wmv", flv: "video/x-flv", "3gp": "video/3gpp" };
const WATCH_PROMPT_DEFAULT =
  "You are analysing a finished short-form edit for an editor studying its style. Report concretely: "
  + "1) Shot list with timestamps: subject, shot size (wide/medium/close/detail), camera movement "
  + "(static/pan/orbit/gimbal/FPV/handheld), day or night. 2) Structure: how it opens, builds, and pays off. "
  + "3) Pacing character in words. 4) The grade/look in plain colour terms (contrast, cast, saturation, where it "
  + "leans). 5) Text, transitions and effects used. 6) Anything distinctive worth imitating. Be brief and specific.";

function httpsRequest(url, opts, body) {
  return new Promise((res, rej) => {
    const u = new URL(url);
    const req = https.request({ hostname: u.hostname, path: u.pathname + u.search,
      method: (opts && opts.method) || "GET", headers: (opts && opts.headers) || {},
      timeout: (opts && opts.timeoutMs) || 120000 }, (r) => {
      const chunks = [];
      r.on("data", (d) => chunks.push(d));
      r.on("end", () => {
        const text = Buffer.concat(chunks).toString("utf8");
        let json = null; try { json = JSON.parse(text); } catch (e) {}
        res({ status: r.statusCode, headers: r.headers, text, json });
      });
    });
    req.on("timeout", () => { req.destroy(new Error("timed out")); });
    req.on("error", rej);
    if (body) req.write(body);
    req.end();
  });
}

// Back off on 429/5xx/network, never retry 400/403.
async function geminiCall(doReq, url, opts, body, tries) {
  let last = { status: 0 };
  for (let i = 0; i < (tries || 3); i++) {
    if (i) await sleep(1500 * Math.pow(2, i - 1));
    try { last = await doReq(url, opts, body); }
    catch (e) { last = { status: 0, headers: {}, json: null, text: e.message }; continue; }
    if (last.status && last.status < 500 && last.status !== 429) return last;
  }
  return last;
}

function geminiErrorText(status, json) {
  const e = (json && json.error) || {};
  const reason = (e.details || []).map((d) => d && d.reason).filter(Boolean)[0];
  if (reason === "API_KEY_INVALID")
    return "Gemini rejected the API key as invalid — re-check it (aistudio.google.com > Get API key) and store it again with set_gemini_key.";
  if (e.status === "RESOURCE_EXHAUSTED") return "Gemini rate limit hit (free tier). Wait a minute and retry; daily quotas reset at midnight Pacific.";
  if (e.status === "PERMISSION_DENIED") return "The Gemini key is valid but lacks permission for this API.";
  if (e.status === "FAILED_PRECONDITION") return "Gemini free tier is not available for this project/region — enable billing in Google AI Studio.";
  if (e.status === "NOT_FOUND") return "The uploaded video is gone on Google's side (files expire after 48h) — re-run to upload again.";
  if (status === 503 || e.status === "UNAVAILABLE")
    return "Google's Gemini service is temporarily overloaded (503). Already retried with backoff — wait a few minutes and try again; nothing is wedged on our side.";
  if (status === 0) return "Could not reach Google at all (network error: " + ((json && json.text) || "unknown") + ").";
  return "Gemini error HTTP " + status + ": " + (e.message || "no detail").slice(0, 300);
}

async function geminiUploadVideo(doReq, key, file) {
  const bytes = fs.readFileSync(file);
  if (bytes.length > 2 * 1024 * 1024 * 1024) throw new Error("Video exceeds Gemini's 2GB per-file cap.");
  const ext = path.extname(file).slice(1).toLowerCase();
  const mime = VIDEO_MIME[ext] || "video/mp4";
  const start = await geminiCall(doReq, "https://" + GEMINI_HOST + "/upload/v1beta/files",
    { method: "POST", timeoutMs: 30000, headers: { "x-goog-api-key": key, "X-Goog-Upload-Protocol": "resumable",
      "X-Goog-Upload-Command": "start", "X-Goog-Upload-Header-Content-Length": String(bytes.length),
      "X-Goog-Upload-Header-Content-Type": mime, "Content-Type": "application/json" } },
    JSON.stringify({ file: { display_name: path.basename(file) } }));
  if (start.status !== 200) throw new Error(geminiErrorText(start.status, start.json));
  const uploadUrl = start.headers["x-goog-upload-url"];
  if (!uploadUrl) throw new Error("Gemini upload start returned no x-goog-upload-url header.");
  const up = await doReq(uploadUrl, { method: "POST", timeoutMs: 150000, headers: { "Content-Length": String(bytes.length),
    "X-Goog-Upload-Offset": "0", "X-Goog-Upload-Command": "upload, finalize" } }, bytes);
  const fileObj = up.json && up.json.file;                 // the upload response IS wrapped
  if (up.status !== 200 || !fileObj || !fileObj.uri) throw new Error(geminiErrorText(up.status, up.json));
  let st = fileObj.state, name = fileObj.name;
  for (let i = 0; i < 15 && st === "PROCESSING"; i++) {      // the poll GET returns a BARE File
    await sleep(5000);
    const poll = await geminiCall(doReq, "https://" + GEMINI_HOST + "/v1beta/" + name,
      { timeoutMs: 15000, headers: { "x-goog-api-key": key } }, null, 2);
    const f = (poll.json && poll.json.file) || poll.json || {};
    st = f.state || st;
    if (f.error) throw new Error("Gemini could not process the video: " + (f.error.message || JSON.stringify(f.error)));
  }
  if (st !== "ACTIVE") throw new Error("Gemini file never became ACTIVE (state " + st + ") — try again or use a shorter clip.");
  return { uri: fileObj.uri, name, mime };
}

async function watchVideo(doReq, key, file, opts) {
  opts = opts || {};
  const up = await geminiUploadVideo(doReq, key, file);
  const model = String(opts.model || GEMINI_MODEL_DEFAULT);
  const body = { contents: [{ parts: [{ text: String(opts.question || WATCH_PROMPT_DEFAULT) },
                                       { fileData: { mimeType: up.mime, fileUri: up.uri } }] }] };
  if (opts.low_res) body.generationConfig = { mediaResolution: "MEDIA_RESOLUTION_LOW" };
  const gen = await geminiCall(doReq, "https://" + GEMINI_HOST + "/v1beta/models/" + model + ":generateContent",
    { method: "POST", timeoutMs: 150000, headers: { "x-goog-api-key": key, "Content-Type": "application/json" } },
    JSON.stringify(body));
  try { await doReq("https://" + GEMINI_HOST + "/v1beta/" + up.name, { method: "DELETE", headers: { "x-goog-api-key": key } }); } catch (e) {}
  if (gen.status !== 200) throw new Error(geminiErrorText(gen.status, gen.json));
  const cands = (gen.json && gen.json.candidates) || [];
  if (!cands.length) {
    const block = gen.json && gen.json.promptFeedback && gen.json.promptFeedback.blockReason;
    throw new Error("Gemini returned no answer" + (block ? " (blocked: " + block + ")" : "") + ".");
  }
  const answer = ((cands[0].content || {}).parts || []).filter((pt) => typeof pt.text === "string" && !pt.thought)
    .map((pt) => pt.text).join("\n").trim();
  return { model, answer, tokens: gen.json.usageMetadata && gen.json.usageMetadata.totalTokenCount };
}

module.exports = { STYLE_DIR, STUDY_DIR, CONFIG_FILE, SAMPLE_W, SAMPLE_H, GEMINI_HOST, GEMINI_MODEL_DEFAULT,
  WATCH_PROMPT_DEFAULT, SETUP_HINT, readConfig, geminiKey, percentile, detectCuts, styleAggregate, profileFile,
  loadProfile, saveProfile, mergeEntry, listProfiles, summariseProfile, findBin, findYtDlp, findFfmpeg,
  downloadVideo, probeVideo, sampleFrames, frameStats, frameDiff, timecode, studyFile, httpsRequest, geminiCall,
  geminiErrorText, geminiUploadVideo, watchVideo };
