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
  check("/train alone explains the setup; /style asks for the profile read", /brew install yt-dlp ffmpeg/.test(slash.expandSlash("/train", "assistant")) && /style_profile/.test(slash.expandSlash("/style", "music")));
  const music = slash.slashRoute("/train https://a/1", "music");
  check("in Claude Music /train points at the Claude Assistant panel", music.kind === "unknown" && /Claude Assistant panel/.test(music.note), JSON.stringify(music));
  check("commandsFor hides the study commands from the music menu", slash.commandsFor("music").every((c) => !c.assistantOnly) && slash.commandsFor("assistant").some((c) => c.name === "train"));
  check("unknown /foo is answered locally; a path passes through prefixed; plain text is untouched",
    /No command called \/foo/.test(slash.slashRoute("/foo", "assistant").note) && /^Message from the panel/.test(slash.slashRoute("/Users/josh/a.mov grade this", "assistant").prompt) && slash.slashRoute("hello", "assistant").prompt === "hello");

  console.log(failures ? failures + " FAILURES" : "ALL STYLE CHECKS PASSED");
  process.exit(failures ? 1 : 0);
})().catch((err) => { console.error("TEST CRASHED", err); process.exit(1); });
