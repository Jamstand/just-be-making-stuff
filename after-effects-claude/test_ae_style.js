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
