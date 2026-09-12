// Style study for the After Effects panel — "training" done honestly.
// A finished edit (a downloaded reel) is broken down into measurable style:
// cut rhythm, shot lengths, exposure and colour-cast tendencies, plus (with
// a Gemini key) a content read of what is on screen. It is persisted as a
// profile future sessions read: ~/ClaudeAssistantStyle/<name>.json, the
// SAME file and schema the DaVinci Resolve panel writes, so both panels
// learn from the same edits and the user can open and correct it. No model
// weights change; the profile file IS the memory.
//
// yt-dlp does the downloading (install_yt_dlp fetches it, no Homebrew) and
// ffmpeg the frame sampling when it happens to be installed (a 60 s reel is
// ~120 thumbnail frames in a few seconds); without ffmpeg, After Effects
// decodes the frames itself (sampleFramesViaAe).
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const https = require("https");
const crypto = require("crypto");
const { spawn } = require("child_process");
const png = require(path.join(__dirname, "pnglib.js"));

const STYLE_DIR = path.join(os.homedir(), "ClaudeAssistantStyle");
const STUDY_DIR = path.join(os.homedir(), "ClaudeAssistantStudy");
const CONFIG_FILE = path.join(os.homedir(), ".claude-assistant.json");
const SAMPLE_W = 64, SAMPLE_H = 36;              // thumbnails: plenty for level / cast / cut diffs
const AE_LONG_EDGE = 240;                        // AE renders the source shape this big, then we box-average down
const AE_BATCH = 30;                             // frames per host call (each one blocks After Effects)
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

// Read without side effects: throws with the parse error when the file is
// damaged (style_profile and watch_video use this; only a study may set a
// damaged file aside).
function readProfile(name) {
  const file = profileFile(name);
  if (!fs.existsSync(file)) return { profile: null, file };
  const profile = JSON.parse(fs.readFileSync(file, "utf8"));
  if (!profile || !Array.isArray(profile.edits)) throw new Error("profile has no edits array");
  return { profile, file };
}

// Load for WRITING, with corruption survival: damaged bytes are kept beside
// the file, never overwritten silently — hours of study may be recoverable
// by hand.
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
  // a per-write temp name: both panels may save the same profile at once
  const tmp = file + ".tmp-" + process.pid + "-" + Math.random().toString(36).slice(2, 8);
  fs.writeFileSync(tmp, JSON.stringify(profile, null, 2));
  fs.renameSync(tmp, file);                                   // atomic: no half-written profiles
  return profile.aggregate;
}

// A re-study of the same source replaces its measurements; nothing is
// blended — but the Gemini content read (the slow, quota-costing half) is
// carried over when the new entry has none.
function mergeEntry(profile, entry) {
  const old = profile.edits.find((e) => e.source === entry.source);
  if (old && old.content_notes && !entry.content_notes) { entry.content_notes = old.content_notes; entry.notes_kept = true; }
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
function listSources(profile) { return (profile && profile.edits ? profile.edits : []).map((e) => e.source); }

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
// GUI apps get a bare PATH on macOS, so probe the usual homes as well. The
// panel's own bin folder comes first: a tool it installed itself is the one
// it can keep up to date.
const extraBinDirs = [];
function addBinDir(dir) { if (dir && !extraBinDirs.includes(dir)) extraBinDirs.unshift(dir); }
function findBin(name) {
  const homes = ["/opt/homebrew/bin", "/usr/local/bin", path.join(os.homedir(), ".local", "bin")];
  const exe = process.platform === "win32" && !/\.exe$/i.test(name) ? name + ".exe" : name;
  const dirs = extraBinDirs.concat((process.env.PATH || "").split(path.delimiter).filter(Boolean), homes);
  for (const d of dirs) {
    const p = path.join(d, exe);
    try { fs.accessSync(p, fs.constants.X_OK); return p; } catch (e) {}
  }
  return null;
}
const findYtDlp = () => findBin("yt-dlp");
const findFfmpeg = () => findBin("ffmpeg");
const SETUP_HINT = "The panel can install yt-dlp itself (install_yt_dlp) — no Homebrew needed.";

// `<bin> --version`, for reporting what is installed. Never throws.
function binVersion(bin, opts) {
  return new Promise((resolveP) => {
    let child;
    try { child = spawn(bin, ["--version"], { stdio: ["ignore", "pipe", "pipe"], windowsHide: true }); }
    catch (e) { return resolveP(null); }
    let out = "";
    child.stdout.on("data", (d) => { out += d; });
    child.stderr.on("data", (d) => { out += d; });
    const timer = setTimeout(() => { try { child.kill(); } catch (e) {} resolveP(null); }, (opts && opts.timeoutMs) || 8000);
    child.on("error", () => { clearTimeout(timer); resolveP(null); });
    child.on("close", () => { clearTimeout(timer); resolveP((out.trim().split(/\r?\n/)[0] || "").slice(0, 120) || null); });
  });
}

function downloadVideo(url, dir, opts) {
  opts = opts || {};
  return new Promise((resolveP, rejectP) => {
    const bin = opts.bin || findYtDlp();
    if (!bin) return rejectP(new Error("yt-dlp is not installed — it does the actual downloading. " + SETUP_HINT));
    fs.mkdirSync(dir, { recursive: true });
    const stamp = Date.now().toString(36) + Math.random().toString(36).slice(2, 5);
    const template = path.join(dir, "study_" + stamp + ".%(ext)s");
    // Without ffmpeg, yt-dlp cannot merge separate video and audio streams:
    // ask only for formats that arrive as one file (reels normally do).
    const merge = opts.ffmpeg !== undefined ? opts.ffmpeg : findFfmpeg();
    const fmt = merge ? "mp4/bv*+ba/b" : "b[ext=mp4]/b[ext=mov]/b";
    const args = ["-f", fmt, "--no-playlist", "--no-progress", "-o", template, url];
    if (merge) args.splice(2, 0, "--merge-output-format", "mp4");
    // after_move runs once the file is in place, so this prints WITHOUT
    // turning the run into a simulation. It is how the panel learns the
    // clip's real length when there is no ffmpeg to probe with.
    if (!opts.noPrint) args.splice(0, 0, "--print", "after_move:duration=%(duration)s");
    const child = spawn(bin, args, { stdio: ["ignore", "pipe", "pipe"], windowsHide: true });
    let err = "", said = "";
    child.stdout.on("data", (d) => { said += d; });             // never let a chatty download fill the pipe and stall
    child.stderr.on("data", (d) => { err += d; });
    const timer = setTimeout(() => { try { child.kill(); } catch (e) {} rejectP(new Error("Download timed out after 180s.")); }, opts.timeoutMs || 180000);
    child.on("error", (e) => { clearTimeout(timer); rejectP(new Error("Could not run yt-dlp: " + e.message)); });
    child.on("close", (code) => {
      clearTimeout(timer);
      const hit = fs.readdirSync(dir).find((n) => n.startsWith("study_" + stamp + "."));
      if (code === 0 && hit) {
        const m = /duration=([\d.]+)/.exec(said);
        return resolveP({ file: path.join(dir, hit), duration_s: m ? Number(m[1]) : null });
      }
      // an older yt-dlp may not know --print after_move: try once without it
      if (!opts.noPrint && /--print|after_move|no such option|unrecognized/i.test(err))
        return resolveP(downloadVideo(url, dir, Object.assign({}, opts, { noPrint: true })));
      rejectP(new Error("yt-dlp failed (exit " + code + "): " + err.trim().slice(-500)));
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
      const rot = /displaymatrix:\s*rotation of\s*(-?\d+(?:\.\d+)?)\s*degrees/i.exec(err);
      if (!d) return rejectP(new Error("ffmpeg could not read " + path.basename(file) + ": " + err.trim().slice(-300)));
      let w = s ? Number(s[1]) : null, h = s ? Number(s[2]) : null;
      const rotation = rot ? ((Math.round(Number(rot[1])) % 360) + 360) % 360 : 0;
      if ((rotation === 90 || rotation === 270) && w && h) { const t = w; w = h; h = t; }   // phone video: display size, not coded size
      resolveP({ duration_s: +(Number(d[1]) * 3600 + Number(d[2]) * 60 + Number(d[3])).toFixed(2),
                 fps: f ? Number(f[1]) : null, width: w, height: h, rotation });
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
      // ffmpeg exits 0 on a truncated file and just stops emitting: what it
      // complained about rides along so the caller can judge coverage.
      frames.decode_errors = err.trim() ? err.trim().split(/\r?\n/).slice(-5) : [];
      frames.exit_code = code;
      resolveP(frames);
    });
  });
}

// yt-dlp versions are dates. Its extractors for Instagram and TikTok break
// and get fixed constantly, and yt-dlp itself warns once a build is 90 days
// old — so an old one is the first thing to suspect when a link fails.
function ytDlpAgeDays(version, now) {
  const m = /(\d{4})\.(\d{2})\.(\d{2})/.exec(String(version || ""));
  if (!m) return null;
  const built = Date.UTC(+m[1], +m[2] - 1, +m[3]);
  const days = Math.floor(((now === undefined ? Date.now() : now) - built) / 86400000);
  return days >= 0 ? days : null;
}

// ------------------------------------------------------- fetching yt-dlp
// yt-dlp ships a standalone executable, which is the whole point here: a
// user without Homebrew (or on a macOS too new for it) can still download
// the reels. Redirects are followed because GitHub's "latest" URL is one.
const YT_DLP_ASSET = { darwin: "yt-dlp_macos", win32: "yt-dlp.exe", linux: "yt-dlp_linux" };
const YT_DLP_BASE = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/";
const YT_DLP_URL = (platform) => YT_DLP_BASE + (YT_DLP_ASSET[platform || process.platform] || "yt-dlp");
const YT_DLP_SUMS = YT_DLP_BASE + "SHA2-256SUMS";

// The release publishes "<sha256>  <asset>" lines; check the bytes we got
// against the one for our asset. A download that cannot be checked is
// reported as unchecked, but one that does not MATCH is thrown away.
async function verifyChecksum(file, assetName, opts) {
  opts = opts || {};
  let sums;
  try { sums = (await downloadTo(opts.sumsUrl || YT_DLP_SUMS, null, Object.assign({ text: true }, opts))).text; }
  catch (e) { return { checked: false, why: "could not fetch the published checksums (" + e.message + ")" }; }
  const line = String(sums).split(/\r?\n/).find((l) => l.trim().split(/\s+/)[1] === assetName);
  if (!line) return { checked: false, why: "the published checksums do not list " + assetName };
  const want = line.trim().split(/\s+/)[0].toLowerCase();
  const got = crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
  return { checked: true, match: got === want, want, got };
}

// dest null + opts.text -> resolve the body as a string instead of a file.
function downloadTo(url, dest, opts) {
  opts = opts || {};
  const get = opts.get || https.get;
  const hops = Number(opts.maxRedirects) || 6;
  return new Promise((resolveP, rejectP) => {
    let done = false;
    const finish = (err, value) => { if (done) return; done = true; err ? rejectP(err) : resolveP(value); };
    const step = (u, left) => {
      let req;
      try {
        req = get(u, (res) => {
         try {
          const code = res.statusCode;
          if (code >= 300 && code < 400 && res.headers.location) {
            res.on("error", (e) => finish(e));
            res.resume();
            if (!left) return finish(new Error("too many redirects fetching " + url));
            return step(new URL(res.headers.location, u).toString(), left - 1);
          }
          if (code !== 200) { res.resume(); return finish(new Error("HTTP " + code + " fetching " + u)); }
          if (opts.text) {
            let body = "";
            res.setEncoding("utf8");
            res.on("data", (d) => { body += d; });
            res.on("error", (e) => finish(e));
            res.on("end", () => finish(null, { text: body, bytes: body.length }));
            return;
          }
          fs.mkdirSync(path.dirname(dest), { recursive: true });
          const tmp = dest + ".part-" + process.pid;
          const out = fs.createWriteStream(tmp);
          let bytes = 0;
          res.on("data", (d) => { bytes += d.length; });
          res.on("error", (e) => { try { out.destroy(); fs.unlinkSync(tmp); } catch (e2) {} finish(e); });
          out.on("error", (e) => finish(e));
          out.on("close", () => {
            if (bytes < 1024) { try { fs.unlinkSync(tmp); } catch (e) {} return finish(new Error("only " + bytes + " bytes came back from " + u)); }
            try { fs.renameSync(tmp, dest); } catch (e) { return finish(e); }
            finish(null, { file: dest, bytes });
          });
          res.pipe(out);
         } catch (e) { finish(e); }
        });
      } catch (e) { return finish(e); }
      req.on("error", (e) => finish(e));
      req.setTimeout(opts.timeoutMs || 180000, () => { req.destroy(new Error("timed out fetching " + u)); });
    };
    step(url, hops);
  });
}

// Install a downloaded tool the careful way: fetch beside the real path,
// check it against the checksums the project publishes, run it, and only
// then move it into place — so a bad download can never replace a working
// copy, and nothing unverified is ever made executable.
async function installTool(opts) {
  const dest = opts.dest, url = opts.url, staging = dest + ".new";
  const fetchTo = opts.fetch || downloadTo;
  const verify = opts.verify || verifyChecksum;
  const version = opts.version || binVersion;
  const scrap = (msg) => { try { fs.unlinkSync(staging); } catch (e) {} return new Error(msg); };
  if (opts.base && String(url).indexOf(opts.base) !== 0)
    throw new Error("Only fetches from " + opts.base + " — a file from anywhere else cannot be checked "
      + "against the checksums that project publishes.");
  const got = await fetchTo(url, staging);
  const asset = String(url).split("/").pop();
  const sum = await verify(staging, asset);
  if (sum.checked && !sum.match)
    throw scrap("The download did not match the published checksum (" + String(sum.got).slice(0, 12) + "… vs "
      + String(sum.want).slice(0, 12) + "…), so it was thrown away and nothing was replaced. Try again; if it keeps "
      + "happening, something between here and the server is altering the file.");
  if (!sum.checked && !opts.allowUnverified)
    throw scrap("Could not check the download against the published checksums (" + sum.why + "), so nothing was "
      + "installed. Try again in a moment, or say to install it anyway.");
  try { fs.chmodSync(staging, 0o755); } catch (e) {}
  const ran = await version(staging);
  if (!ran)
    throw scrap("Downloaded " + (got && got.bytes) + " bytes but it would not run, so nothing was replaced."
      + (process.platform === "darwin" ? " If macOS blocked it, allow it in System Settings > Privacy & Security, "
        + "or in Terminal run: xattr -d com.apple.quarantine " + JSON.stringify(dest) : ""));
  fs.renameSync(staging, dest);                    // only now does the working copy change
  return { installed: dest, version: ran, bytes: got && got.bytes,
           checksum: sum.checked ? "matched the published SHA-256" : "not verified — " + sum.why };
}

// ---------------------------------------------- frames from After Effects
// The ffmpeg-free route: After Effects decodes the video itself. It imports
// the file into a temporary folder, renders a tiny comp with saveFrameToPng
// at each sample time, and removes everything afterwards — see study_open /
// study_sample / study_close in host/ae-tools.jsx. Slower than ffmpeg (a
// render per frame) but it needs nothing installed.
//
// host(name, args) is the panel's evalHost bridge.
async function sampleFramesViaAe(file, opts) {
  opts = opts || {};
  const host = opts.host;
  if (typeof host !== "function") throw new Error("no After Effects bridge to read frames with");
  const interval = Math.max(0.1, Number(opts.interval_s) || 0.5);
  const nap = opts.sleep || sleep;
  const run = opts.run || (Date.now().toString(36) + Math.random().toString(36).slice(2, 6));
  const open = await host("study_open", { file, run, long_edge: Number(opts.long_edge) || AE_LONG_EDGE });
  const frameDir = open.frame_dir || null;
  // Frames a cancelled study left behind would sit under the same names and
  // satisfy the "is it written yet?" poll at once, so the previous reel's
  // picture would be measured as this one's. Every other run goes first.
  if (frameDir) {
    try {
      const root = path.dirname(frameDir);
      for (const n of fs.readdirSync(root))
        if (path.join(root, n) !== frameDir) fs.rmSync(path.join(root, n), { recursive: true, force: true });
    } catch (e) {}
  }
  const deadline = Date.now() + (Number(opts.total_budget_ms) || 10 * 60 * 1000);
  try {
    const duration = Number(open.duration_s) || 0;
    if (!(duration > 0)) throw new Error("After Effects reports no duration for " + path.basename(file));
    const count = Math.max(1, Math.floor(duration / interval + 1e-6));
    const times = [];
    for (let k = 0; k < count; k++) times.push(+(k * interval).toFixed(3));
    const frames = [];
    let i = 0, stalls = 0;
    while (i < times.length) {
      const batch = times.slice(i, i + (Number(opts.batch) || AE_BATCH));
      const r = await host("study_sample", { times: batch, index: i, budget_ms: opts.budget_ms || 8000 });
      const got = (r && r.files) || [];
      if (!got.length) {
        if (++stalls > 2) throw new Error("After Effects stopped returning frames at " + times[i].toFixed(1) + " s of " + path.basename(file));
        continue;
      }
      stalls = 0;
      if (Date.now() > deadline)
        throw new Error("Studying " + path.basename(file) + " through After Effects passed "
          + Math.round((Number(opts.total_budget_ms) || 600000) / 60000) + " minutes at frame " + i
          + " of " + times.length + " — stopped. Shorten the clip, raise interval_s, or install ffmpeg for the fast path.");
      for (const g of got) {
        // saveFrameToPng can return before the bytes are all on disk
        let buf = null;
        for (let tries = 0; tries < 250 && !buf; tries++) {
          try { const b = fs.readFileSync(g.file); if (png.pngComplete(b)) buf = b; } catch (e) {}
          if (!buf) await nap(40);
        }
        if (!buf) throw new Error("After Effects never finished writing " + g.file
          + " — is Preferences > Scripting & Expressions > Allow Scripts to Write Files and Access Network on?");
        try { fs.unlinkSync(g.file); } catch (e) {}
        const img = png.decodePng(buf);
        if (!frames.length) {                          // what did AE really give us?
          frames.png_format = img.format;
          frames.render_size = img.width + "x" + img.height;
          if (open.sample_width && (img.width !== open.sample_width || img.height !== open.sample_height))
            frames.geometry_note = "After Effects rendered " + img.width + "x" + img.height + " where the comp is "
              + open.sample_width + "x" + open.sample_height + " — the frames were measured at that size.";
        }
        frames.push({ t: g.t, rgb: png.resampleRgb(img.rgb, img.width, img.height, SAMPLE_W, SAMPLE_H) });
      }
      i += got.length;
      if (opts.onProgress) { try { opts.onProgress({ done: i, total: times.length }); } catch (e) {} }
    }
    frames.decode_errors = [];
    frames.exit_code = 0;
    frames.source = { duration_s: duration, fps: Number(open.fps) || null,
                      width: Number(open.width) || null, height: Number(open.height) || null,
                      sample_width: open.sample_width, sample_height: open.sample_height,
                      pixel_aspect: open.pixel_aspect || null, native_fps: open.native_fps || null,
                      conform_fps: open.conform_fps || null, ae_version: open.ae_version || null,
                      project_bpc: open.project_bpc || null, working_space: open.working_space || null,
                      linear_blending: open.linear_blending === undefined ? null : open.linear_blending,
                      png_format: frames.png_format || null, render_size: frames.render_size || null,
                      geometry_note: frames.geometry_note || null };
    return frames;
  } finally {
    try { await host("study_close", {}); } catch (e) {}
    if (frameDir) { try { fs.rmSync(frameDir, { recursive: true, force: true }); } catch (e) {} }
  }
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
  // A truncated or damaged file decodes part-way and ffmpeg still exits 0:
  // a study of the readable prefix must never be written as the whole edit.
  const expect = Number(opts.expect_duration_s) || 0;
  const covered = frames.length * interval;
  const sampler = opts.sampler || (frames.source ? "After Effects" : "ffmpeg");
  if (expect && covered < expect - Math.max(1.5, interval * 2))
    throw new Error(sampler + " read only " + covered.toFixed(1) + " s of a " + expect.toFixed(1) + " s file — the download is "
      + "truncated or damaged; delete it and study_url the link again"
      + (frames.decode_errors && frames.decode_errors.length ? " (ffmpeg: " + frames.decode_errors.join(" | ").slice(0, 300) + ")" : "") + ".");
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
  if (frames.decode_errors && frames.decode_errors.length)
    warnings.push("ffmpeg reported while decoding: " + frames.decode_errors.join(" | ").slice(0, 300));
  // Pixel-for-pixel identical frames at the end mean one of two things and
  // the pixels cannot tell them apart: an edit that holds on a card, or a
  // file that stopped decoding. Record it as the fact it is — the length
  // yt-dlp reported is what actually catches a short file.
  let frozen = 0;
  for (let i = diffs.length - 1; i > 0 && diffs[i] === 0; i--) frozen += 1;
  const frozenS = frozen * interval;
  if (frozenS >= 3) {
    entry.static_tail_s = +frozenS.toFixed(1);
    if (frozen >= diffs.length * 0.25)
      warnings.push("The last " + frozenS.toFixed(1) + " s are pixel-for-pixel identical — either the edit ends on a "
        + "held frame, or the file stops early. Nothing here can tell those apart; if the length looks short, "
        + "download it again.");
  }
  if (frames.geometry_note) warnings.push(frames.geometry_note);
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
  readProfile, loadProfile, saveProfile, mergeEntry, listProfiles, listSources, summariseProfile,
  addBinDir, findBin, findYtDlp, findFfmpeg, binVersion, AE_LONG_EDGE, AE_BATCH, sampleFramesViaAe,
  YT_DLP_ASSET, YT_DLP_URL, YT_DLP_BASE, YT_DLP_SUMS, downloadTo, verifyChecksum, ytDlpAgeDays, installTool,
  downloadVideo, probeVideo, sampleFrames, frameStats, frameDiff, timecode, studyFile, httpsRequest, geminiCall,
  geminiErrorText, geminiUploadVideo, watchVideo };
