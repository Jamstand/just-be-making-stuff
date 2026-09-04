#!/usr/bin/env node
// Headless tests for tracklib.js: the AE keyframe-text parser, Mocha
// python discovery + job runner (fake interpreters), and the fal.ai
// upload / submit / poll / download client through a recorded request().
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const http = require("http");

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ca-tracklib-"));
process.env.HOME = tmp;                    // CONFIG_FILE resolves under here
const track = require("./com.jamstand.claude.ae/tracklib.js");

let failures = 0;
function check(label, ok, detail) {
  if (ok) console.log("  ok  " + label);
  else { failures += 1; console.log("FAIL  " + label + "  " + (detail || "")); }
}
const exe = (name, body) => {
  const p = path.join(tmp, name);
  fs.writeFileSync(p, "#!/usr/bin/env node\n" + body);
  fs.chmodSync(p, 0o755);
  return p;
};

(async () => {
  // ------------------------------------------------ keyframe text parser
  const sample = ["Adobe After Effects 8.0 Keyframe Data", "",
    "\tUnits Per Second\t23.976", "\tSource Width\t1920", "\tSource Height\t1080",
    "\tSource Pixel Aspect Ratio\t1", "\tComp Pixel Aspect Ratio\t1", "",
    "Effects\tCorner Pin #1\tUpper Left #2", "\tFrame\tX pixels\tY pixels\t",
    "\t0\t100.5\t200.25\t", "\t1\t101\t201\t", "",
    "Effects\tCorner Pin #1\tLower Right #5", "\tFrame\tX pixels\tY pixels\t",
    "\t0\t500\t600\t", "",
    "Transform\tPosition", "\tFrame\tX pixels\tY pixels\tZ pixels\t", "\t0\t960\t540\t0\t", "",
    "Transform\tRotation", "\tFrame\tdegrees\t", "\t0\t12.5\t", "",
    "End of Keyframe Data", ""].join("\r\n");
  const p = track.parseAeKeyframeText(sample);
  check("parse: header (CRLF, trailing tabs)", p.fps === 23.976 && p.width === 1920
    && p.height === 1080 && p.par === 1, JSON.stringify(p.header));
  check("parse: 4 blocks with group/name/prop", p.blocks.length === 4
    && p.blocks[0].group === "Effects" && p.blocks[0].name === "Corner Pin #1"
    && p.blocks[0].prop === "Upper Left #2" && p.blocks[2].name === "Position",
    JSON.stringify(p.blocks.map((b) => [b.group, b.name, b.prop, b.keys.length])));
  check("parse: numeric values and frames", p.blocks[0].keys[0].values[0] === 100.5
    && p.blocks[0].keys[1].frame === 1 && p.blocks[2].keys[0].values.length === 3
    && p.blocks[3].keys[0].values[0] === 12.5
    && p.blocks[0].columns.join() === "X pixels,Y pixels");
  let threw = null;
  try { track.parseAeKeyframeText("hello\nworld"); } catch (e) { threw = e.message; }
  check("parse: rejects non-keyframe text", /Not an After Effects keyframe/.test(threw), threw);

  // ------------------------------------------------ Mocha python discovery
  const fakePy = exe("python3", "console.log('hi')");
  const found = track.findMochaPython({ mocha_python: fakePy });
  check("findMochaPython: config override first", found[0] && found[0].python === fakePy
    && found[0].kind === "config", JSON.stringify(found));
  check("findMochaPython: missing config path ignored",
    track.findMochaPython({ mocha_python: path.join(tmp, "nope") })
      .every((f) => f.kind !== "config"));
  for (const v of ["2025", "2026.5"]) {
    const d = path.join(tmp, "apps", "Mocha Pro " + v + ".app", "Contents", "MacOS");
    fs.mkdirSync(d, { recursive: true });
    fs.writeFileSync(path.join(d, "python3"), "");
  }
  const ex = track.expandPattern([path.join(tmp, "apps"), /^Mocha Pro/, "Contents/MacOS/python3"]);
  check("expandPattern: version folders, newest first", ex.length === 2 && /2026\.5/.test(ex[0]),
    JSON.stringify(ex));

  // ------------------------------------------------ Mocha job runner
  const script = path.join(tmp, "mocha_job.py");
  const okPy = exe("ok-python", "const j=require(process.argv[3]);console.log('Mocha chatter');"
    + "console.log('CA_RESULT '+JSON.stringify({ok:true,data:{echo:j.action,frames:3}}));");
  const r1 = await track.runMochaJob(okPy, { action: "probe" },
    { scriptPath: script, workdir: path.join(tmp, "w1"), timeoutMs: 10000 });
  check("runMochaJob: argv = [script, job.json], CA_RESULT parsed, log kept",
    r1.echo === "probe" && r1.frames === 3 && /chatter/.test(r1.log_tail)
    && fs.existsSync(path.join(tmp, "w1", "mocha.log"))
    && JSON.parse(fs.readFileSync(path.join(tmp, "w1", "job.json"), "utf8")).action === "probe",
    JSON.stringify(r1));
  const badPy = exe("bad-python", "console.error('ImportError: No module named mocha');process.exit(1);");
  let e2 = null;
  try { await track.runMochaJob(badPy, { action: "probe" },
    { scriptPath: script, workdir: path.join(tmp, "w2"), timeoutMs: 10000 }); }
  catch (e) { e2 = e.message; }
  check("runMochaJob: no result -> error carries exit code + log",
    /exited 1/.test(e2) && /No module named mocha/.test(e2), e2);
  const licPy = exe("lic-python", "console.log('CA_RESULT '+JSON.stringify({ok:false,error:'license: not activated',traceback:'Traceback...'}));");
  let e3 = null;
  try { await track.runMochaJob(licPy, { action: "track" },
    { scriptPath: script, workdir: path.join(tmp, "w3"), timeoutMs: 10000 }); }
  catch (e) { e3 = e.message; }
  check("runMochaJob: script-reported failure surfaces verbatim",
    /Mocha: license: not activated/.test(e3) && /Traceback/.test(e3), e3);
  const slowPy = exe("slow-python", "setTimeout(()=>{},5000);");
  let e4 = null;
  try { await track.runMochaJob(slowPy, { action: "track" },
    { scriptPath: script, workdir: path.join(tmp, "w4"), timeoutMs: 400 }); }
  catch (e) { e4 = e.message; }
  check("runMochaJob: timeout kills the interpreter and says so", /timed out/.test(e4), e4);
  let e5 = null;
  try { await track.runMochaJob(path.join(tmp, "missing-python"), { action: "probe" },
    { scriptPath: script, workdir: path.join(tmp, "w5"), timeoutMs: 1000 }); }
  catch (e) { e5 = e.message; }
  check("runMochaJob: missing interpreter is a clean error", /Could not run Mocha's python3/.test(e5), e5);

  const envPy = exe("env-python", "console.log('CA_RESULT '+JSON.stringify({ok:true,data:{rlm:process.env.RLM_LICENSE||null,isv:process.env.genarts_LICENSE||null}}));");
  const r6 = await track.runMochaJob(envPy, { action: "probe" },
    { scriptPath: script, workdir: path.join(tmp, "w6"), timeoutMs: 10000,
      env: track.mochaEnv({ mocha_license: "5053@licserver" }) });
  check("runMochaJob: mocha_license reaches the child as RLM_LICENSE + genarts_LICENSE",
    r6.rlm === "5053@licserver" && r6.isv === "5053@licserver", JSON.stringify(r6));
  check("mochaEnv: nothing configured -> nothing injected", Object.keys(track.mochaEnv({})).length === 0);
  const lic = track.explainMochaError("Mocha: could not open the footage in Mocha (RuntimeError: License Error: 2   ISV name: genarts)");
  check("explainMochaError: license failures get the fix list, others pass through",
    /sign in/.test(lic) && /mocha_license/.test(lic) && /Mocha AE/.test(lic)
    && track.explainMochaError("footage not found") === "footage not found", lic.slice(0, 120));

  const ctx = track.explainMochaError("Mocha: tracking failed after 0.0s: RuntimeError: Can't obtain rendering context");
  check("explainMochaError: rendering-context failures point at mocha_status's Qt ladder",
    /OpenGL rendering context/.test(ctx) && /mocha_qt/.test(ctx) && /apply_track_file/.test(ctx), ctx.slice(0, 100));

  // ------------------------------------------------ Mocha shape export
  const pt = (x, y) => "Point(" + x + "," + y + ",0,0.5,-8.88178e-16,-0.030752,0.341831,0.299147)";
  const shapeText = ["Adobe After Effects 6.0 Keyframe Data", "", "\tUnits Per Second\t24",
    "\tSource Width\t1920", "\tSource Height\t1080", "\tSource Pixel Aspect Ratio\t1",
    "\tComp Pixel Aspect Ratio\t1", "", "", "Effects\tmocha shape #1\tShape data", "\tFrame",
    "\t0\tBezier(" + pt(0.5, 0.5) + pt(0.75, 0.5) + pt(0.75, 0.75) + pt(0.5, 0.75) + ")",
    "\t1\tBezier(" + pt(0.51, 0.5) + pt(0.76, 0.5) + pt(0.76, 0.75) + pt(0.51, 0.75) + ")", "",
    "Effects\tmocha shape #2\tShape data", "\tFrame",
    "\t0\tBezier(" + pt(0.1, 0.1) + pt(0.2, 0.1) + pt(0.2, 0.2) + ")", "",
    "End of Keyframe Data", ""].join("\r\n");
  const sh = track.parseMochaShapeText(shapeText);
  check("parseMochaShapeText: header, two shapes, frames, points scaled to source pixels",
    sh && sh.fps === 24 && sh.width === 1920 && sh.shapes.length === 2
    && sh.shapes[0].name === "mocha shape #1" && sh.shapes[0].frames.length === 2
    && sh.shapes[0].frames[0].points.length === 4
    && sh.shapes[0].frames[0].points[0].join() === "960,540"
    && sh.shapes[0].frames[1].points[1][0] === 0.76 * 1920
    && sh.shapes[1].frames[0].points.length === 3, JSON.stringify(sh && sh.shapes.map((s) => [s.name, s.frames.length])));
  check("parseMochaShapeText: plain corner-pin text has no shapes -> null", track.parseMochaShapeText(sample) === null);
  check("parseMochaShapeText: non-keyframe text -> null", track.parseMochaShapeText("hello") === null);
  const mrep = track.maskReport(sh.shapes[0].frames, 1920, 1080, 60);
  check("maskReport: per-frame vertex boxes feed the same usable-range logic",
    mrep && mrep.frames === 2 && mrep.usable_until_frame === 1 && /stayed in frame/.test(mrep.verdict), JSON.stringify(mrep));

  // ------------------------------------------------ PNG readiness (panel-side wait)
  const png = path.join(tmp, "grab.png");
  fs.writeFileSync(png, "partial");
  setTimeout(() => fs.appendFileSync(png, "morebytes"), 120);
  setTimeout(() => fs.appendFileSync(png, "IEND\0\0\0\0"), 300);
  const w1 = await track.waitForPng(png, 5000, { pollMs: 50 });
  check("waitForPng: resolves once the file stops growing and ends in IEND",
    w1.bytes === fs.statSync(png).size && w1.waited_ms >= 300 && track.pngComplete(png), JSON.stringify(w1));
  const stuck = path.join(tmp, "stuck.png");
  fs.writeFileSync(stuck, "partial forever");
  const w2 = await track.waitForPng(stuck, 300, { pollMs: 50 }).catch((e) => e.message);
  check("waitForPng: a half-written file times out with advice, not a truncated image",
    /still writing/.test(w2) && /grab_source_frame/.test(w2), w2);
  const w3 = await track.waitForPng(path.join(tmp, "never.png"), 300, { pollMs: 50 }).catch((e) => e.message);
  check("waitForPng: a file AE never creates names the scripting preference", /never created/.test(w3) && /Allow Scripts/.test(w3), w3);

  // ------------------------------------------------ corner-pin geometry
  const sq = [[0, 0], [100, 0], [0, 100], [100, 100]];             // UL UR LL LR
  const H = track.solveHomography(sq, [[10, 20], [210, 20], [10, 220], [210, 220]]);
  const centre = track.applyH(H, [50, 50]);
  check("homography: 4-point DLT maps the centre", Math.abs(centre[0] - 110) < 1e-6 && Math.abs(centre[1] - 120) < 1e-6, JSON.stringify(centre));
  const persp = track.solveHomography(sq, [[0, 0], [100, 10], [0, 100], [100, 90]]);
  const pp = track.applyH(persp, [100, 50]);
  check("homography: perspective (non-affine) quad solves", persp && Math.abs(pp[0] - 100) < 1e-6 && Math.abs(pp[1] - 50) < 1e-6, JSON.stringify(pp));
  check("homography: degenerate quad -> null", track.solveHomography(sq, [[0, 0], [0, 0], [0, 0], [0, 0]]) === null);
  const mk = (name, keys) => ({ group: "Effects", name: "Corner Pin #1", prop: name, keys });
  const pinBlocks = [
    mk("Upper Left #2", [{ frame: 0, values: [0, 0] }, { frame: 1, values: [10, 20] }]),
    mk("Upper Right #3", [{ frame: 0, values: [100, 0] }, { frame: 1, values: [210, 20] }]),
    mk("Lower Left #4", [{ frame: 0, values: [0, 100] }, { frame: 1, values: [10, 220] }]),
    mk("Lower Right #5", [{ frame: 0, values: [100, 100] }, { frame: 1, values: [210, 220] }]),
    { group: "Transform", name: "Position", prop: "", keys: [{ frame: 0, values: [1, 2] }] },
  ];
  const rt = track.retargetCornerPin(pinBlocks, { UL: [25, 25], UR: [75, 25], LL: [25, 75], LR: [75, 75] });
  const ul = rt.blocks[0].keys, lr = rt.blocks[3].keys;
  check("retargetCornerPin: frame 0 = the requested quad, later frames follow the plane",
    rt.retargeted && ul[0].values.join() === "25,25" && Math.abs(ul[1].values[0] - 60) < 1e-6
    && Math.abs(ul[1].values[1] - 70) < 1e-6 && Math.abs(lr[1].values[0] - 160) < 1e-6
    && rt.blocks[4].keys[0].values.join() === "1,2", JSON.stringify(rt.blocks.map((b) => b.keys)));
  const noPin = track.retargetCornerPin([pinBlocks[4]], { UL: [0, 0], UR: [1, 0], LL: [0, 1], LR: [1, 1] });
  check("retargetCornerPin: no corner blocks -> untouched, reason names what it saw",
    noPin.retargeted === false && /saw: Transform\/Position×1/.test(noPin.reason), noPin.reason);
  const loose = pinBlocks.slice(0, 4).map((b, i) => Object.assign({}, b, { group: "Effect",
    prop: ["upper-left #2", "Upper  Right", "LOWER_LEFT", "Lower Right #5"][i] }));
  check("cornerBlocks: hyphens, case, underscores, double spaces and #n suffixes all match",
    !!track.cornerBlocks(loose) && track.retargetCornerPin(loose, { UL: [25, 25], UR: [75, 25], LL: [25, 75], LR: [75, 75] }).retargeted === true);
  const rep = track.trackReport(pinBlocks, 1920, 1080, 60);
  check("trackReport: clean track is usable to the last frame", rep.usable_until_frame === 1 && /stayed in frame/.test(rep.verdict), JSON.stringify(rep));
  const drift = pinBlocks.slice(0, 4).map((b) => Object.assign({}, b, { keys: b.keys.concat(
    [{ frame: 2, values: [b.keys[1].values[0] + 5, b.keys[1].values[1] + 5] },
     { frame: 3, values: [b.keys[1].values[0] + 1900, b.keys[1].values[1]] },
     { frame: 4, values: [b.keys[1].values[0] + 2500, b.keys[1].values[1]] }]) }));
  const rep2 = track.trackReport(drift, 1920, 1080, 60);
  check("trackReport: region running off frame right is caught, usable range ends before it",
    rep2.first_partially_offscreen_frame === 3 && rep2.first_offscreen_frame === 4
    && rep2.first_jump_frame === 3 && rep2.usable_until_frame === 2 && Math.abs(rep2.usable_until_s - 0.033) < 1e-3,
    JSON.stringify(rep2));

  // ------------------------------------------------ fal.ai client
  const calls = [];
  const fakeReq = async (url, opts, body) => {
    calls.push({ url, method: (opts && opts.method) || "GET",
      headers: (opts && opts.headers) || {}, body, bodyFile: opts && opts.bodyFile });
    const ok = (json, headers) => ({ status: 200, json, text: json ? JSON.stringify(json) : "", headers: headers || {} });
    if (/initiate-multipart/.test(url))
      return ok({ upload_url: "https://up.example/mp/abc?sig=1", file_url: "https://cdn.example/f/big.mp4" });
    if (/upload\/initiate\?/.test(url))
      return ok({ upload_url: "https://up.example/put/abc", file_url: "https://cdn.example/f/small.mp4" });
    if (/\/mp\/abc\/complete/.test(url)) return ok({});
    if (/\/mp\/abc\/(\d+)\?sig=1$/.test(url))
      return ok(null, { etag: '"e' + url.match(/\/(\d+)\?/)[1] + '"' });
    if (/up\.example\/put/.test(url)) return ok(null);
    if (/queue\.fal\.run\/fal-ai\/sam-3\/video$/.test(url))
      return ok({ request_id: "req1",
        status_url: "https://queue.fal.run/fal-ai/sam-3/video/requests/req1/status",
        response_url: "https://queue.fal.run/fal-ai/sam-3/video/requests/req1" });
    if (/req1\/status/.test(url)) {
      const n = calls.filter((c) => /req1\/status/.test(c.url)).length;
      if (n === 1) return { status: 429, json: null, text: "slow down", headers: {} };
      return ok({ status: n === 2 ? "IN_QUEUE" : n === 3 ? "IN_PROGRESS" : "COMPLETED" });
    }
    if (/requests\/req1$/.test(url)) return ok({ video: { url: "https://cdn.example/out.mp4" } });
    if (/req2\/status/.test(url)) return ok({ status: "IN_PROGRESS", error: "boom" });
    return { status: 500, json: null, text: "unexpected " + url, headers: {} };
  };
  const small = path.join(tmp, "small.mp4");
  fs.writeFileSync(small, Buffer.alloc(1000));
  const url1 = await track.falUpload("KEY", small, { request: fakeReq });
  const initCall = calls.find((c) => /upload\/initiate\?/.test(c.url));
  const putCall = calls.find((c) => /up\.example\/put/.test(c.url));
  check("falUpload: initiate (key, content type) then PUT streams the file",
    url1 === "https://cdn.example/f/small.mp4" && initCall.method === "POST"
    && initCall.headers.Authorization === "Key KEY"
    && JSON.parse(initCall.body).content_type === "video/mp4"
    && JSON.parse(initCall.body).file_name === "small.mp4"
    && putCall.method === "PUT" && putCall.bodyFile === small
    && putCall.headers["Content-Length"] === 1000 && !putCall.headers.Authorization,
    JSON.stringify([initCall, putCall]));
  const big = path.join(tmp, "big.mp4");
  fs.writeFileSync(big, Buffer.alloc(2500));
  calls.length = 0;
  const url2 = await track.falUpload("KEY", big,
    { request: fakeReq, multipartThreshold: 2000, chunkBytes: 1000 });
  const partCalls = calls.filter((c) => /\/mp\/abc\/\d+\?sig=1$/.test(c.url));
  const complete = calls.find((c) => /complete/.test(c.url));
  check("falUpload: multipart = 3 parts (1000/1000/500), etags collected, complete posted",
    url2 === "https://cdn.example/f/big.mp4" && partCalls.length === 3
    && partCalls[0].body.length === 1000 && partCalls[2].body.length === 500
    && complete && /\/complete\?sig=1$/.test(complete.url)
    && JSON.parse(complete.body).parts.map((x) => x.etag).join() === '"e1","e2","e3"',
    JSON.stringify({ parts: partCalls.map((c) => c.url), complete: complete && complete.url }));
  calls.length = 0;
  const sub = await track.falSubmit("KEY", "fal-ai/sam-3/video",
    { video_url: url1, prompt: "car" }, { request: fakeReq });
  check("falSubmit: JSON body, Key auth, request id + urls",
    sub.request_id === "req1" && /req1\/status$/.test(sub.status_url)
    && JSON.parse(calls[0].body).prompt === "car" && calls[0].headers.Authorization === "Key KEY",
    JSON.stringify(sub));
  const statuses = [];
  const res = await track.falWait("KEY", sub, { request: fakeReq, sleep: async () => {},
    pollMs: 1, onStatus: (s) => statuses.push(s) });
  check("falWait: survives 429, IN_QUEUE→IN_PROGRESS→COMPLETED, fetches the result",
    res.video.url === "https://cdn.example/out.mp4"
    && statuses.join(">") === "IN_QUEUE>IN_PROGRESS>COMPLETED",
    JSON.stringify({ res, statuses }));
  let e6 = null;
  try { await track.falWait("KEY", { request_id: "req2",
    status_url: "https://queue.fal.run/x/requests/req2/status",
    response_url: "https://queue.fal.run/x/requests/req2" },
    { request: fakeReq, sleep: async () => {}, pollMs: 1 }); }
  catch (e) { e6 = e.message; }
  check("falWait: job error surfaces", /fal job failed: "boom"/.test(e6), e6);
  let e7 = null;
  try { await track.falWait("KEY", sub, { request: async () => ({ status: 200,
    json: { status: "IN_QUEUE" }, text: "", headers: {} }),
    sleep: async () => {}, pollMs: 1, timeoutMs: 5 }); }
  catch (e) { e7 = e.message; }
  check("falWait: timeout names the last status", /still IN_QUEUE after/.test(e7), e7);
  const e8 = await track.falSubmit("BAD", "fal-ai/sam-3/video", {}, { request: async () =>
    ({ status: 401, json: { detail: "Unauthorized" }, text: "", headers: {} }) })
    .catch((e) => e.message);
  check("falSubmit: 401 says to re-set the key", /rejected the API key/.test(e8), e8);
  const e9 = await track.falSubmit("KEY", "fal-ai/sam-3/video", {}, { request: async () =>
    ({ status: 422, json: { detail: [{ msg: "video_url required" }] }, text: "", headers: {} }) })
    .catch((e) => e.message);
  check("falSubmit: validation error carries fal's detail", /HTTP 422/.test(e9) && /video_url required/.test(e9), e9);

  // ------------------------------------------------ download (real socket)
  const srv = http.createServer((req, res) => {
    res.writeHead(200, { "Content-Type": "video/mp4" });
    res.end(Buffer.alloc(4096, 7));
  });
  await new Promise((r) => srv.listen(0, "127.0.0.1", r));
  const dest = path.join(tmp, "dl", "out.mp4");
  await track.download("http://127.0.0.1:" + srv.address().port + "/out.mp4", dest);
  check("download: streams to disk, creates the folder", fs.statSync(dest).size === 4096);
  srv.close();

  // ------------------------------------------------ config
  const cfg = track.writeConfig({ fal_api_key: "abc:def" });
  check("config: round trip, mode 0600, under $HOME",
    cfg.fal_api_key === "abc:def" && track.readConfig().fal_api_key === "abc:def"
    && (fs.statSync(track.CONFIG_FILE).mode & 0o777) === 0o600
    && track.CONFIG_FILE.startsWith(tmp), track.CONFIG_FILE);
  check("mimeFor", track.mimeFor("a.MOV") === "video/quicktime" && track.mimeFor("x.bin") === "application/octet-stream");

  console.log(failures ? "\nFAILURES: " + failures : "\nALL TRACKLIB CHECKS PASSED");
  process.exit(failures ? 1 : 0);
})().catch((e) => { console.error("TEST DRIVER FAILED", e); process.exit(1); });
