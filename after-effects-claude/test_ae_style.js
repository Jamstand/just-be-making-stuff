// Style study for the AE panel: the measurement, the profile file, the
// downloader/sampler over fake binaries, the Gemini wire over a fake http,
// and the /train macro — all without After Effects.
"use strict";
const fs = require("fs"), os = require("os"), path = require("path");
const HOME = fs.mkdtempSync(path.join(os.tmpdir(), "ae-style-home-"));
process.env.HOME = HOME; process.env.USERPROFILE = HOME;
delete process.env.GEMINI_API_KEY;
const style = require("./com.jamstand.claude.ae/stylelib.js");
const slash = require("./com.jamstand.claude.ae/slash.js");

let failures = 0;
function check(name, ok, detail) {
  console.log((ok ? "  ok  " : "FAIL  ") + name + (ok ? "" : "  " + (detail || "")));
  if (!ok) failures += 1;
}
const W = style.SAMPLE_W, H = style.SAMPLE_H;
function frame(level, rg, bg, seed) {
  const px = Buffer.alloc(W * H * 3);
  for (let p = 0; p < W * H; p++) {
    const tex = ((p * 7 + seed) % 5) - 2;
    px[p * 3] = Math.max(0, Math.min(255, level + rg + tex)); px[p * 3 + 1] = Math.max(0, Math.min(255, level + tex)); px[p * 3 + 2] = Math.max(0, Math.min(255, level + bg + tex));
  }
  return px;
}

(async () => {
  // ---- measurement over synthetic frames: three shots, two cuts
  const frames = [];
  for (let i = 0; i < 24; i++) {
    const t = i * 0.5;
    frames.push({ t, rgb: t < 4 ? frame(40, 0, 0, i) : t < 8 ? frame(200, 30, 0, i) : frame(90, 0, 25, i) });
  }
  const r = await style.studyFile("/fake/reel.mp4", { frames, interval_s: 0.5, source: "unit-reel", fps: 30 });
  const e = r.entry;
  check("studyFile: two cuts, three shots of 4 s each", e.cuts === 2 && e.shots.length === 3 && e.shot_lengths_s.join() === "4,4,4" && e.duration_s === 12 && e.complete, JSON.stringify(e.shot_lengths_s));
  check("studyFile: per-shot level and cast are measured (dark neutral, bright warm, mid cool)",
    Math.abs(e.shots[0].mean_level_pct - 40 / 255 * 100) < 1 && e.shots[1].cast_rg > 10 && Math.abs(e.shots[1].cast_bg) < 1 && e.shots[2].cast_bg > 8,
    JSON.stringify(e.shots));
  check("studyFile: first diff is unknown, cut diffs are hot, within-shot diffs are cold, timecodes present",
    r.diffs[0] === null && r.diffs[8] >= 8 && r.diffs[16] >= 8 && r.diffs[3] < 8 && e.shots[1].start_timecode === "00:00:04:00", JSON.stringify(r.diffs));
  const fast = await style.studyFile("/fake/x.mp4", { frames: frames.map((f, i) => ({ t: f.t, rgb: i % 2 ? frame(30, 0, 0, i) : frame(220, 0, 0, i) })), interval_s: 0.5 });
  check("studyFile: a stride warning when most neighbour diffs are cuts", fast.warnings.length === 1 && /smaller interval_s/.test(fast.warnings[0]), JSON.stringify(fast.warnings));
  let thrown = null; try { await style.studyFile("/fake/y.mp4", { frames: [frames[0]] }); } catch (err) { thrown = err.message; }
  check("studyFile: one frame is refused plainly", /is it a video/.test(thrown || ""), thrown);

  // ---- the profile file: merge, replace, aggregate, corruption survival
  const p1 = style.loadProfile("unit profile");
  check("loadProfile: fresh profile in ~/ClaudeAssistantStyle", p1.profile.edits.length === 0 && p1.file.startsWith(HOME) && /unit_profile\.json$/.test(p1.file), p1.file);
  style.mergeEntry(p1.profile, e);
  style.mergeEntry(p1.profile, Object.assign({}, e, { studied: "again" }));   // same source → replaced, not blended
  const agg = style.saveProfile(p1.profile, p1.file);
  check("saveProfile: same source replaces its entry; aggregate matches the Resolve schema",
    p1.profile.edits.length === 1 && agg.edits_studied === 1 && agg.cuts_per_minute === 10 && agg.shot_length_s.median === 4 && agg.cast_tendency === "mixed/neutral" && fs.existsSync(p1.file) && !fs.existsSync(p1.file + ".tmp"),
    JSON.stringify(agg));
  const summary = style.summariseProfile(p1.profile, 20);
  check("summariseProfile: one line per edit with cuts/min and shot lengths", summary.edits.length === 1 && summary.edits[0].cuts_per_minute === 10 && summary.edits[0].warm_shots === 1 && summary.edits[0].cool_shots === 1, JSON.stringify(summary));
  fs.writeFileSync(p1.file, "{ not json");
  const p2 = style.loadProfile("unit profile");
  check("loadProfile: a damaged profile is set aside, never overwritten silently", p2.profile.edits.length === 0 && p2.recoveredFrom && fs.existsSync(p2.recoveredFrom) && style.listProfiles().join() === "", p2.recoveredFrom);

  // ---- downloader + sampler over the harness fakes
  const fakebin = path.join(__dirname, "verify-electron", "fakebin");
  const dl = await style.downloadVideo("https://www.tiktok.com/t/ZP8vojUtd/", path.join(HOME, "ClaudeAssistantStudy"), { bin: path.join(fakebin, "yt-dlp") });
  check("downloadVideo: yt-dlp's output template lands in ~/ClaudeAssistantStudy", /ClaudeAssistantStudy\/study_\w+\.mp4$/.test(dl) && fs.existsSync(dl), dl);
  let dlErr = null; try { await style.downloadVideo("https://example.com/fail", HOME, { bin: path.join(fakebin, "yt-dlp") }); } catch (err) { dlErr = err.message; }
  check("downloadVideo: a yt-dlp failure surfaces its stderr", /yt-dlp failed \(exit 1\).*Unsupported URL/.test(dlErr || ""), dlErr);
  let noBin = null; try { await style.downloadVideo("https://x", HOME, { bin: "/nonexistent/yt-dlp" }); } catch (err) { noBin = err.message; }
  check("downloadVideo: a missing binary is a plain error", /Could not run yt-dlp/.test(noBin || ""), noBin);
  const probe = await style.probeVideo(dl, { ffmpeg: path.join(fakebin, "ffmpeg") });
  check("probeVideo: duration, fps and size parsed from ffmpeg's stderr", probe.duration_s === 12 && probe.fps === 30 && probe.width === 1080 && probe.height === 1920, JSON.stringify(probe));
  const sampled = await style.sampleFrames(dl, { interval_s: 0.5, ffmpeg: path.join(fakebin, "ffmpeg") });
  check("sampleFrames: 24 raw frames at 0.5 s", sampled.length === 24 && sampled[0].rgb.length === W * H * 3 && sampled[23].t === 11.5, sampled.length);
  const real = await style.studyFile(dl, { interval_s: 0.5, ffmpeg: path.join(fakebin, "ffmpeg"), source: "https://www.tiktok.com/t/ZP8vojUtd/", fps: probe.fps });
  check("studyFile over ffmpeg: the fake reel's two cuts and three shots", real.entry.cuts === 2 && real.entry.shots.length === 3 && real.entry.source.startsWith("https://"), JSON.stringify(real.entry.shot_lengths_s));

  // ---- a truncated download: frames stop part-way, ffmpeg still exits 0 → refused, never written
  const truncVid = path.join(HOME, "ClaudeAssistantStudy", "trunc.mp4");
  fs.writeFileSync(truncVid, JSON.stringify(Object.assign(JSON.parse(fs.readFileSync(dl, "utf8")), { truncate_at: 5 })));
  const tprobe = await style.probeVideo(truncVid, { ffmpeg: path.join(fakebin, "ffmpeg") });
  let covErr = null;
  try { await style.studyFile(truncVid, { interval_s: 0.5, ffmpeg: path.join(fakebin, "ffmpeg"), expect_duration_s: tprobe.duration_s }); } catch (err) { covErr = err.message; }
  check("studyFile: a decode that covers 5 s of a 12 s file is refused with ffmpeg's complaint, not written as complete",
    /decoded only 5\.0 s of a 12\.0 s file/.test(covErr || "") && /partial file/.test(covErr || ""), covErr);
  const shortOk = await style.studyFile(truncVid, { interval_s: 0.5, ffmpeg: path.join(fakebin, "ffmpeg") });
  check("studyFile: without an expected length the decode warnings still ride along", shortOk.entry.samples_counted === 10 && shortOk.warnings.some((w) => /ffmpeg reported/.test(w)), JSON.stringify(shortOk.warnings));

  // ---- reads never move a damaged file; a re-study keeps the Gemini notes
  const p3 = style.loadProfile("keep notes");
  style.mergeEntry(p3.profile, Object.assign({}, e, { source: "reel-1", content_notes: "night rolling shots" }));
  style.mergeEntry(p3.profile, Object.assign({}, e, { source: "reel-1", studied: "again" }));
  check("mergeEntry: re-studying a source keeps its content notes and says so", p3.profile.edits.length === 1 && p3.profile.edits[0].content_notes === "night rolling shots" && p3.profile.edits[0].notes_kept === true);
  style.saveProfile(p3.profile, p3.file);
  check("readProfile: reads back the saved profile; listSources names the entries", style.readProfile("keep notes").profile.edits.length === 1 && style.listSources(style.readProfile("keep notes").profile).join() === "reel-1");
  fs.writeFileSync(p3.file, "{ broken");
  let readErr = null; try { style.readProfile("keep notes"); } catch (err) { readErr = err.message; }
  check("readProfile: a damaged file throws and stays exactly where it is", readErr && fs.existsSync(p3.file) && fs.readFileSync(p3.file, "utf8") === "{ broken", readErr);
  check("saveProfile: no stray temp files left beside the profile", !fs.readdirSync(style.STYLE_DIR).some((n) => /\.tmp/.test(n)), fs.readdirSync(style.STYLE_DIR).join());

  // ---- links as users paste them
  check("extractLinks: trailing punctuation off, scheme-less kept, repeats dropped, short links kept",
    slash.extractLinks("/train: https://www.instagram.com/reel/X/?igsh=abc==, https://www.tiktok.com/t/ZP8vojUtd/. (https://a/1) www.tiktok.com/t/Q/ https://a/1 youtu.be/abc").join("|")
      === "https://www.instagram.com/reel/X/?igsh=abc==|https://www.tiktok.com/t/ZP8vojUtd/|https://a/1|https://www.tiktok.com/t/Q/|https://youtu.be/abc",
    JSON.stringify(slash.extractLinks("/train: https://www.instagram.com/reel/X/?igsh=abc==, https://www.tiktok.com/t/ZP8vojUtd/. (https://a/1) www.tiktok.com/t/Q/ https://a/1 youtu.be/abc")));
  check("/train: and /train, before the links still expand; /trainn with links in Claude Music is redirected, not told it needs links",
    slash.slashRoute("/train: https://a/1", "assistant").kind === "expand" && slash.slashRoute("/train,https://a/1", "assistant").kind === "expand"
    && /Claude Assistant panel/.test(slash.slashRoute("/trainn https://a/1", "music").note) && /Claude Assistant panel/.test(slash.expandSlash("/style", "music")));

  // ---- the real ffmpeg, when this machine has one: a synthetic three-shot mp4, then its truncated twin
  const realFfmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"].find((p) => fs.existsSync(p));
  if (realFfmpeg) {
    const { execFileSync } = require("child_process");
    const vid = path.join(HOME, "real.mp4");
    execFileSync(realFfmpeg, ["-y", "-v", "error", "-f", "lavfi", "-i", "color=c=0x282828:s=320x180:r=30:d=4", "-f", "lavfi", "-i", "color=c=0xE6C8C8:s=320x180:r=30:d=4",
      "-f", "lavfi", "-i", "color=c=0x5A5A78:s=320x180:r=30:d=4", "-filter_complex", "[0:v][1:v][2:v]concat=n=3:v=1:a=0[v]", "-map", "[v]", "-c:v", "mpeg4", "-q:v", "3", "-movflags", "+faststart", vid]);
    const rp = await style.probeVideo(vid, { ffmpeg: realFfmpeg });
    const rr = await style.studyFile(vid, { interval_s: 0.5, ffmpeg: realFfmpeg, expect_duration_s: rp.duration_s, fps: rp.fps, source: "real" });
    check("REAL ffmpeg (" + realFfmpeg + "): probe 12 s / 30 fps / 320x180; study finds 2 cuts, 3 shots, warm middle, cool end",
      rp.duration_s === 12 && rp.fps === 30 && rp.width === 320 && rp.height === 180 && rr.entry.cuts === 2 && rr.entry.shots.length === 3 && rr.entry.shots[1].cast_rg > 5 && rr.entry.shots[2].cast_bg > 5 && rr.warnings.length === 0,
      JSON.stringify({ rp, entry: rr.entry, warnings: rr.warnings }));
    const bytes = fs.readFileSync(vid), trunc = path.join(HOME, "real-trunc.mp4");
    fs.writeFileSync(trunc, bytes.subarray(0, Math.floor(bytes.length * 0.55)));
    const tp = await style.probeVideo(trunc, { ffmpeg: realFfmpeg });
    let realErr = null;
    try { await style.studyFile(trunc, { interval_s: 0.5, ffmpeg: realFfmpeg, expect_duration_s: tp.duration_s }); } catch (err) { realErr = err.message; }
    check("REAL ffmpeg: the file cut at 55% still probes as 12 s but the study is refused (" + (realErr || "").slice(0, 60) + "…)",
      tp.duration_s === 12 && /decoded only|is it a video|ffmpeg failed/.test(realErr || ""), realErr);
  } else console.log("  --  no real ffmpeg on this machine; the fake covers the wire");

  // ---- frames from After Effects: the ffmpeg-free route, end to end
  const { encodePng, planFrame } = require("./verify-electron/pngwrite.js");
  const aePlan = JSON.parse(fs.readFileSync(dl, "utf8"));
  const aeDir = path.join(HOME, "ae-frames");
  fs.mkdirSync(aeDir, { recursive: true });
  const hostCalls = [];
  let lateOnce = true;
  const stubHost = async (name, args) => {
    hostCalls.push(name);
    if (name === "study_open")
      return { item: "reel.mp4", comp: "__ClaudeStudyFrame__", duration_s: aePlan.duration, fps: aePlan.fps,
               width: aePlan.width, height: aePlan.height, sample_width: 135, sample_height: 240,
               project_bpc: 8, working_space: "sRGB IEC61966-2.1" };
    if (name === "study_sample") {
      const batch = args.times.slice(0, 7);            // fewer than asked: the budget ran out
      return { files: batch.map((t, i) => {
        const file = path.join(aeDir, "s" + (args.index + i) + ".png");
        const write = () => fs.writeFileSync(file, encodePng(135, 240, planFrame(aePlan, t, 135, 240)));
        if (lateOnce && i === 0) { lateOnce = false; setTimeout(write, 120); }   // AE finishes writing late
        else write();
        return { t, file };
      }), wrote: batch.length, next_index: args.index + batch.length };
    }
    if (name === "study_close") return { removed: 2 };
    throw new Error("unexpected host call " + name);
  };
  const aeFrames = await style.sampleFramesViaAe("/study/reel.mp4", { interval_s: 0.5, host: stubHost });
  check("sampleFramesViaAe: every sample time comes back, in batches, waiting for a frame AE finishes late",
    aeFrames.length === 24 && aeFrames[0].t === 0 && aeFrames[23].t === 11.5
    && aeFrames[0].rgb.length === W * H * 3 && hostCalls.filter((c) => c === "study_sample").length === 4
    && hostCalls[0] === "study_open" && hostCalls[hostCalls.length - 1] === "study_close",
    JSON.stringify({ n: aeFrames.length, calls: hostCalls.length }));
  check("sampleFramesViaAe: reports what After Effects said about the source and the project",
    aeFrames.source.duration_s === 12 && aeFrames.source.fps === 30 && aeFrames.source.project_bpc === 8
    && aeFrames.source.working_space === "sRGB IEC61966-2.1", JSON.stringify(aeFrames.source));
  check("sampleFramesViaAe: the frames it hands back are deleted from disk as they are read",
    fs.readdirSync(aeDir).length === 0, fs.readdirSync(aeDir).join());
  const aeStudy = await style.studyFile("/study/reel.mp4", { frames: aeFrames, interval_s: 0.5, source: "ae-route", fps: 30, expect_duration_s: 12 });
  check("the After Effects route measures the same edit as the ffmpeg route: 2 cuts, 3 shots of 4 s",
    aeStudy.entry.cuts === real.entry.cuts && aeStudy.entry.shots.length === real.entry.shots.length
    && aeStudy.entry.shot_lengths_s.join() === real.entry.shot_lengths_s.join()
    && Math.abs(aeStudy.entry.shots[1].cast_rg - real.entry.shots[1].cast_rg) < 1.5,
    JSON.stringify({ ae: aeStudy.entry.shot_lengths_s, ff: real.entry.shot_lengths_s, aeCast: aeStudy.entry.shots[1].cast_rg, ffCast: real.entry.shots[1].cast_rg }));
  let closedAfterThrow = false;
  const brokenHost = async (name, args) => {
    if (name === "study_open") return { duration_s: 4, fps: 30, width: 100, height: 100, sample_width: 50, sample_height: 50 };
    if (name === "study_sample") return { files: [{ t: 0, file: path.join(aeDir, "not-a-png.png") }] };
    if (name === "study_close") { closedAfterThrow = true; return { removed: 1 }; }
  };
  fs.writeFileSync(path.join(aeDir, "not-a-png.png"), "definitely not a PNG at all, no IEND here");
  let aeErr = null;
  try { await style.sampleFramesViaAe("/study/x.mp4", { interval_s: 1, host: brokenHost, sleep: async () => {} }); } catch (err) { aeErr = err.message; }
  check("sampleFramesViaAe: a frame that never arrives is a plain error, and the study is closed anyway",
    /never finished writing/.test(aeErr || "") && /Allow Scripts to Write Files/.test(aeErr || "") && closedAfterThrow, aeErr);
  let stallErr = null;
  try { await style.sampleFramesViaAe("/study/x.mp4", { interval_s: 1, host: async (n) => n === "study_open" ? { duration_s: 4, fps: 30 } : { files: [] } }); } catch (err) { stallErr = err.message; }
  check("sampleFramesViaAe: After Effects returning nothing stops instead of looping for ever", /stopped returning frames/.test(stallErr || ""), stallErr);

  // ---- fetching yt-dlp without Homebrew
  const { Readable } = require("stream");
  const fakeRes = (status, body, headers) => { const r = Readable.from([Buffer.from(body)]); r.statusCode = status; r.headers = headers || {}; return r; };
  const seen = [];
  const fakeGet = (url, cb) => {
    seen.push(url);
    const r = /SHA2-256SUMS$/.test(url)
      ? fakeRes(200, "deadbeef  yt-dlp_linux\n" + require("crypto").createHash("sha256").update(Buffer.alloc(4096, 7)).digest("hex") + "  yt-dlp_macos\n")
      : seen.length === 1 ? fakeRes(302, "", { location: "https://objects.example/real" })
      : fakeRes(200, Buffer.alloc(4096, 7));
    setTimeout(() => cb(r), 0);
    return { on() {}, setTimeout() {} };
  };
  const binOut = path.join(HOME, "bin", "yt-dlp");
  const dlRes = await style.downloadTo(style.YT_DLP_URL("darwin"), binOut, { get: fakeGet });
  check("downloadTo: follows the redirect GitHub's latest URL answers with, writes the file, leaves no .part",
    dlRes.bytes === 4096 && fs.existsSync(binOut) && seen.length === 2 && /yt-dlp_macos$/.test(seen[0])
    && !fs.readdirSync(path.join(HOME, "bin")).some((n) => /\.part/.test(n)), JSON.stringify({ dlRes, seen }));
  const sum = await style.verifyChecksum(binOut, "yt-dlp_macos", { get: fakeGet });
  check("verifyChecksum: matches the SHA-256 the release publishes for our asset", sum.checked && sum.match, JSON.stringify(sum));
  fs.appendFileSync(binOut, "tampered");
  const bad = await style.verifyChecksum(binOut, "yt-dlp_macos", { get: fakeGet });
  check("verifyChecksum: a changed file does not match", bad.checked && !bad.match, JSON.stringify({ checked: bad.checked, match: bad.match }));
  const missing = await style.verifyChecksum(binOut, "yt-dlp_windows", { get: fakeGet });
  check("verifyChecksum: an asset the sums file does not list is reported unchecked, not failed", !missing.checked && /do not list/.test(missing.why), JSON.stringify(missing));
  const noSums = await style.verifyChecksum(binOut, "yt-dlp_macos", { get: (u, cb) => { setTimeout(() => cb(fakeRes(404, "")), 0); return { on() {}, setTimeout() {} }; } });
  check("verifyChecksum: unreachable checksums are unchecked, never a false match", !noSums.checked && !noSums.match, JSON.stringify(noSums));
  let tiny = null;
  try { await style.downloadTo("https://x/y", path.join(HOME, "bin", "tiny"), { get: (u, cb) => { setTimeout(() => cb(fakeRes(200, "nope")), 0); return { on() {}, setTimeout() {} }; } }); } catch (err) { tiny = err.message; }
  check("downloadTo: a suspiciously small body is refused and nothing is left behind",
    /only 4 bytes/.test(tiny || "") && !fs.existsSync(path.join(HOME, "bin", "tiny")), tiny);

  // ---- the panel's own bin folder is searched first
  const myBin = path.join(HOME, "panelbin");
  fs.mkdirSync(myBin, { recursive: true });
  const fakeYt = path.join(myBin, "yt-dlp");
  fs.writeFileSync(fakeYt, "#!/bin/sh\necho 2026.08.19\n"); fs.chmodSync(fakeYt, 0o755);
  style.addBinDir(myBin);
  check("addBinDir: a tool the panel installed itself wins over anything on PATH", style.findYtDlp() === fakeYt, style.findYtDlp());
  check("binVersion: reports the first line a tool prints", (await style.binVersion(fakeYt)) === "2026.08.19", await style.binVersion(fakeYt));
  check("binVersion: a binary that will not run is null, never a throw", (await style.binVersion(path.join(myBin, "nope"))) === null);
  check("ytDlpAgeDays: a dated version tells you how stale it is; anything else is null",
    style.ytDlpAgeDays("2026.08.19", Date.UTC(2026, 8, 11)) === 23 && style.ytDlpAgeDays("2025.12.01", Date.UTC(2026, 8, 11)) === 284
    && style.ytDlpAgeDays("nightly build") === null && style.ytDlpAgeDays("") === null);

  // ---- Gemini over a fake wire (upload wrapped, poll bare, thoughts dropped)
  const gCalls = [];
  const fakeHttp = async (url, opts) => {
    gCalls.push({ url, method: (opts && opts.method) || "GET" });
    if (url.endsWith("/upload/v1beta/files")) return { status: 200, headers: { "x-goog-upload-url": "https://generativelanguage.googleapis.com/up/1" }, json: null };
    if (url.endsWith("/up/1")) return { status: 200, headers: {}, json: { file: { uri: "https://g/files/f1", name: "files/f1", state: "ACTIVE" } } };
    if (url.includes(":generateContent")) return { status: 200, headers: {}, json: { candidates: [{ content: { parts: [
      { thought: true, text: "internal reasoning" }, { text: "Opens on a static wide; night rolling shots follow." }, { text: "Grade leans teal in the shadows." }] } }],
      usageMetadata: { totalTokenCount: 4321 } } };
    return { status: 204, headers: {}, json: null };
  };
  const w = await style.watchVideo(fakeHttp, "test-key", dl, {});
  check("watchVideo: upload → ask → delete; text parts joined, thoughts dropped",
    /static wide/.test(w.answer) && /teal/.test(w.answer) && !/internal reasoning/.test(w.answer) && w.tokens === 4321
    && gCalls.some((c) => c.url.endsWith("/upload/v1beta/files")) && gCalls.some((c) => c.url.includes(":generateContent")) && gCalls.some((c) => c.method === "DELETE"),
    JSON.stringify({ w, gCalls }));
  check("geminiErrorText: bad key and quota are told apart",
    /rejected the API key/.test(style.geminiErrorText(400, { error: { status: "INVALID_ARGUMENT", details: [{ reason: "API_KEY_INVALID" }] } }))
    && /rate limit/.test(style.geminiErrorText(429, { error: { status: "RESOURCE_EXHAUSTED" } })) && /overloaded/.test(style.geminiErrorText(503, {})));
  let flaky = 0;
  const flakyHttp = async () => { flaky += 1; return flaky < 3 ? { status: 503, headers: {}, json: {} } : { status: 200, headers: {}, json: { ok: 1 } }; };
  const gc = await style.geminiCall(flakyHttp, "https://x/v1beta/models", {}, null, 3);
  check("geminiCall: transient 503s are retried away", gc.status === 200 && flaky === 3, JSON.stringify({ gc, flaky }));
  check("geminiKey: none stored → null (env cleared, config absent)", style.geminiKey() === null);

  // ---- the /train macro and routing
  const ex = slash.expandSlash("/train https://a/1 https://b/2", "assistant");
  check("/train expands to one-at-a-time marching orders with all three steps", /2 edit\(s\)/.test(ex) && /study_url/.test(ex) && /study_edit/.test(ex) && /watch_video/.test(ex) && /style_profile/.test(ex) && /NOT optional/.test(ex), ex);
  check("/trainhttps://… (no space) and /trainn are still /train", slash.slashRoute("/trainhttps://a/1", "assistant").kind === "expand" && slash.slashRoute("/trainn https://a/1", "assistant").kind === "expand");
  check("/train alone points at install_yt_dlp, never at Homebrew, and says ffmpeg is optional",
    /install_yt_dlp/.test(slash.expandSlash("/train", "assistant")) && /ffmpeg is optional/.test(slash.expandSlash("/train", "assistant"))
    && !/brew install/i.test(slash.expandSlash("/train", "assistant")) && !/brew install/i.test(slash.expandSlash("/train https://a/1", "assistant"))
    && /never tell the user to install ffmpeg or Homebrew/.test(slash.expandSlash("/train https://a/1", "assistant"))
    && /style_profile/.test(slash.expandSlash("/style", "music")), slash.expandSlash("/train", "assistant"));
  const music = slash.slashRoute("/train https://a/1", "music");
  check("in Claude Music /train points at the Claude Assistant panel", music.kind === "unknown" && /Claude Assistant panel/.test(music.note), JSON.stringify(music));
  check("commandsFor hides the study commands from the music menu", slash.commandsFor("music").every((c) => !c.assistantOnly) && slash.commandsFor("assistant").some((c) => c.name === "train"));
  check("unknown /foo is answered locally; a path passes through prefixed; plain text is untouched",
    /No command called \/foo/.test(slash.slashRoute("/foo", "assistant").note) && /^Message from the panel/.test(slash.slashRoute("/Users/josh/a.mov grade this", "assistant").prompt) && slash.slashRoute("hello", "assistant").prompt === "hello");

  console.log(failures ? failures + " FAILURES" : "ALL STYLE CHECKS PASSED");
  process.exit(failures ? 1 : 0);
})().catch((err) => { console.error("TEST CRASHED", err); process.exit(1); });
