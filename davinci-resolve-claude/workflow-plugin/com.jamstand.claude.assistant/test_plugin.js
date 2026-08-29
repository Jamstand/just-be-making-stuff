// Headless checks: `node test_plugin.js`. No Electron, no Resolve — a fake
// Resolve object exercises the tool bodies, and the real bridge.js child is
// driven over stdio against the real TCP bridge server.
"use strict";
const { spawn } = require("child_process");
const path = require("path");
const tools = require("./tools");

let failures = 0;
function check(label, ok, detail) {
  console.log((ok ? "  ok  " : "FAIL  ") + label + (ok ? "" : "  " + (detail || "")));
  if (!ok) failures += 1;
}

// ------------------------------------------------------------ fake Resolve
function fakeResolve(mediaDir) {
  const markers = {};
  const grabState = { calls: 0, exported: [], deleted: [], pages: [],
                      timecodes: [], timelineOps: [] };
  const album = {
    ExportStills: (stills, dir, prefix, fmt) => {
      // Real Resolve: unpredictable filename + a .drx sidecar.
      const file = path.join(dir, prefix + "_1.20260827." + fmt);
      fsmod.writeFileSync(file, fmt === "tif" ? buildTiff16()
        : Buffer.from("89504e470d0a1a0a0011", "hex"));
      fsmod.writeFileSync(path.join(dir, prefix + "_1.drx"), "sidecar");
      grabState.exported.push(file);
      return true;
    },
    DeleteStills: (stills) => { grabState.deleted.push(stills); return true; },
  };
  const currentItem = {
    GetName: () => "C0797.MP4",
    GetStart: () => 86400,
    GetLeftOffset: () => 100,
    GetLUT: (i) => (i === 2 ? "/luts/SL3SG3Ctos709.cube" : ""),
    GetMediaPoolItem: () => ({
      // 60fps media in the 24fps timeline: pre_grade must convert clocks.
      GetClipProperty: (k) =>
        (k === "Input Color Space" ? "S-Gamut3.Cine/S-Log3"
         : k === "FPS" ? 60 : ""),
    }),
  };
  const timeline = {
    GetName: () => "Timeline 1",
    GetSetting: (k) => (k === "timelineFrameRate" ? "24" : ""),
    GetCurrentTimecode: () =>
      grabState.timecodes[grabState.timecodes.length - 1] || "01:00:00:00",
    SetCurrentTimecode: (tc) => { grabState.timecodes.push(tc); return tc !== "bad"; },
    GrabStill: () => {                    // intermittently falsy, like life
      grabState.calls += 1;
      return grabState.calls < 2 ? null : { still: true };
    },
    GetCurrentVideoItem: () => currentItem,
    GetItemListInTrack: (kind, idx) =>
      (kind === "video" && idx === 1 ? [currentItem] : []),
    GetTrackCount: () => 1,
    AddMarker: (frame, color, name, note, dur) => {
      if (markers[frame]) return false;
      markers[frame] = { color, name, note, dur };
      return true;
    },
    GetMarkers: () => markers,
    DeleteMarkersByColor: (c) => {
      let hit = false;
      for (const f of Object.keys(markers))
        if (markers[f].color === c || c === "All") { delete markers[f]; hit = true; }
      return hit;
    },
  };
  const clips = [{ GetName: () => "A001.mov",
                   GetClipProperty: () => ({ FPS: 24, Type: "Video" }) }];
  if (mediaDir)
    clips.push({
      GetName: () => "C0797.MP4",
      GetClipProperty: (k) =>
        (k === "File Path" ? path.join(mediaDir, "C0797.MP4")
         : k === "Input Color Space" ? "Project"
         : k === "Gamma Notes" ? ""
         : k === "FPS" ? "59.94"
         : k === "Type" ? "Video" : ""),
    });
  const root = { GetName: () => "Master",
                 GetClipList: () => clips, GetSubFolderList: () => [] };
  const makeTempTimeline = (name) => ({
    GetName: () => name,
    GetSetting: (k) => (k === "timelineFrameRate" ? "24" : ""),
    GetStartFrame: () => 0,
    GetCurrentTimecode: () => grabState.tempParked || "00:00:00:00",
    SetCurrentTimecode: (tc) => {
      grabState.tempParked = tc;
      grabState.timelineOps.push("park:" + tc);
      return true;
    },
    GrabStill: () => { grabState.timelineOps.push("grab"); return { s: 1 }; },
    GetItemListInTrack: (kind, idx) =>
      (kind === "video" && idx === 1
       ? [{ GetStart: () => 0, GetLeftOffset: () => 0 }] : []),
  });
  const mediaPool = {
    GetRootFolder: () => root,
    AppendToTimeline: (items) => items.map(() => ({})),
    CreateTimelineFromClips: (name, items) => {
      grabState.timelineOps.push("create:" + items.length);
      return makeTempTimeline(name);
    },
    DeleteTimelines: (tls) => {
      grabState.timelineOps.push("delete:" + tls.length);
      return true;
    },
    ImportMedia: (paths) => paths.map((p) => ({ GetName: () => path.basename(p) })),
    AddSubFolder: (parent, name) => ({ GetName: () => name }),
  };
  const project = {
    GetName: () => "Demo",
    GetSetting: (k) => ({ colorScienceMode: "davinciYRGB",
                          colorSpaceInput: "Rec.709 Gamma 2.4",
                          colorSpaceTimeline: "Rec.709 (Scene)",
                          colorSpaceOutput: "Rec.709 (Scene)" }[k] || ""),
    GetCurrentTimeline: () => timeline,
    GetMediaPool: () => mediaPool,
    GetTimelineCount: () => 1,
    GetTimelineByIndex: () => timeline,
    SetCurrentTimeline: (t) => {
      grabState.timelineOps.push("setcur:" + t.GetName());
      return true;
    },
    GetRenderPresetList: () => ["YouTube 1080p"],
    IsRenderingInProgress: () => false,
    GetRenderJobList: () => [],
    GetGallery: () => ({ GetCurrentStillAlbum: () => album }),
  };
  return {
    GetProjectManager: () => ({ GetCurrentProject: () => project }),
    GetCurrentPage: () => "edit",
    OpenPage: (p) => {
      grabState.pages.push(p);
      return ["media", "cut", "edit", "fusion", "color",
              "fairlight", "deliver"].includes(p);
    },
    _markers: markers,
    _grab: grabState,
  };
}
const fsmod = require("fs");
const osmod = require("os");

const SONY_SIDECAR = `<?xml version="1.0" encoding="UTF-8"?>
<NonRealTimeMeta xmlns="urn:schemas-professionalDisc:nonRealTimeMeta:ver.2.20" lastUpdate="2026-08-06T22:27:17-05:00">
\t<Duration value="210"/>
\t<VideoFormat>
\t\t<VideoFrame videoCodec="AVC50_1920_1080_H422P@L42" captureFps="59.94p" formatFps="59.94p"/>
\t</VideoFormat>
\t<Device manufacturer="Sony" modelName="ILCE-6700" serialNo="4294967295"/>
\t<Lens modelName="FE 28-70mm F3.5-5.6 OSS"/>
\t<AcquisitionRecord>
\t\t<Group name="CameraUnitMetadataSet">
\t\t\t<Item name="CaptureGammaEquation" value="s-log3-cine"/>
\t\t\t<Item name="CaptureColorPrimaries" value="s-gamut3-cine"/>
\t\t\t<Item name="CodingEquations" value="rec709"/>
\t\t</Group>
\t</AcquisitionRecord>
\t<RelevantFiles>
\t\t<RelatedTo file="SL3SG3Ctos709.cube" rel="LUT"/>
\t</RelevantFiles>
</NonRealTimeMeta>`;

function buildTiff16() {
  // Minimal little-endian uncompressed 2x1 RGB16 TIFF: samples
  // [0,8000,16000, 24000,40000,65535] -> 2 distinct values per channel.
  const entries = 9, ifd = 8, dataOff = ifd + 2 + entries * 12 + 4;
  const bpsOff = dataOff, stripOff = dataOff + 6;
  const buf = Buffer.alloc(stripOff + 12);
  buf.write("II", 0); buf.writeUInt16LE(42, 2); buf.writeUInt32LE(ifd, 4);
  buf.writeUInt16LE(entries, ifd);
  const tag = (i, id, type, count, value) => {
    const o = ifd + 2 + i * 12;
    buf.writeUInt16LE(id, o); buf.writeUInt16LE(type, o + 2);
    buf.writeUInt32LE(count, o + 4); buf.writeUInt32LE(value, o + 8);
  };
  tag(0, 256, 4, 1, 2);                  // width
  tag(1, 257, 4, 1, 1);                  // height
  tag(2, 258, 3, 3, bpsOff);             // bits per sample -> offset
  tag(3, 259, 3, 1, 1);                  // compression: none
  tag(4, 262, 3, 1, 2);                  // photometric: RGB
  tag(5, 273, 4, 1, stripOff);           // strip offset
  tag(6, 277, 3, 1, 3);                  // samples per pixel
  tag(7, 278, 4, 1, 1);                  // rows per strip
  tag(8, 279, 4, 1, 12);                 // strip byte count
  for (let i = 0; i < 3; i++) buf.writeUInt16LE(16, bpsOff + i * 2);
  [0, 8000, 16000, 24000, 40000, 65535].forEach((v, i) =>
    buf.writeUInt16LE(v, stripOff + i * 2));
  return buf;
}

async function main() {
  const mediaDir = fsmod.mkdtempSync(path.join(osmod.tmpdir(), "ca-media-"));
  fsmod.writeFileSync(path.join(mediaDir, "C0797M01.XML"), SONY_SIDECAR);
  const resolve = fakeResolve(mediaDir);
  const state = tools.makeState(resolve);
  state.permissionMode = "Never ask";

  // -- tool bodies ------------------------------------------------------
  let r = await tools.executeTool(state, "get_workspace_overview", {});
  check("overview reads project/timeline",
        r.ok && r.text.includes("Demo") && r.text.includes("Timeline 1"), r.text);

  r = await tools.executeTool(state, "add_marker", { frame: 10, color: "Red" });
  check("add_marker mutates fake state", r.ok && resolve._markers[10], r.text);
  r = await tools.executeTool(state, "add_marker", { frame: 10, color: "Red" });
  check("duplicate marker surfaces as error",
        !r.ok && r.text.includes("duplicate"), r.text);
  r = await tools.executeTool(state, "list_markers", {});
  check("markers read back", r.ok && r.text.includes("Red"), r.text);

  r = await tools.executeTool(state, "list_media_pool", {});
  check("media pool listing", r.ok && r.text.includes("A001.mov"), r.text);

  r = await tools.executeTool(state, "run_javascript",
    { code: "return { name: project.GetName(), fps: timeline.GetSetting('timelineFrameRate') };" });
  check("run_javascript sees the scripting objects",
        r.ok && r.text.includes("Demo") && r.text.includes("24"), r.text);

  r = await tools.executeTool(state, "nope", {});
  check("unknown tool is friendly", !r.ok && r.text.includes("Unknown"), r.text);

  // -- grab_still: frame parking, retry, sidecar cleanup, image channel --
  const stillDir = fsmod.mkdtempSync(path.join(osmod.tmpdir(), "stills-"));
  r = await tools.executeTool(state, "grab_still",
                              { frame: 120, out_dir: stillDir });
  check("grab_still succeeds", r.ok, r.text);
  check("frame parked via nominal timecode",
        resolve._grab.timecodes.includes("00:00:05:00"),
        String(resolve._grab.timecodes));
  check("color page visited, previous page restored",
        resolve._grab.pages[0] === "color"
        && resolve._grab.pages[resolve._grab.pages.length - 1] === "edit",
        String(resolve._grab.pages));
  check("falsy GrabStill retried", resolve._grab.calls === 2,
        String(resolve._grab.calls));
  check("image side channel populated",
        Array.isArray(r.images) && r.images.length === 1
        && r.images[0].media_type === "image/png"
        && Buffer.from(r.images[0].data, "base64").slice(0, 4)
             .equals(Buffer.from("89504e47", "hex")),
        JSON.stringify(r.images && r.images[0] &&
                       Object.keys(r.images[0])));
  check("image bytes kept out of the JSON text",
        !r.text.includes("89504e47") && !r.text.includes("_images")
        && r.text.includes(stillDir), r.text);
  check("drx sidecar cleaned up",
        !fsmod.readdirSync(stillDir).some((n) => n.endsWith(".drx")),
        String(fsmod.readdirSync(stillDir)));
  check("gallery still deleted after export",
        resolve._grab.deleted.length === 1);

  // 16-bit measurement path: header truth + census + pre-grade versions
  check("default grab is TIFF with parsed 16-bit depth",
        r.text.includes('"bits_per_sample":16')
        && r.text.includes(".tif"), r.text);
  check("census counts distinct levels per channel",
        r.text.includes('"unique_values_rgb":[2,2,2]'), r.text);
  check("clip input colour space rides along",
        r.text.includes("S-Gamut3.Cine/S-Log3"), r.text);
  check("proxy png attached for vision, tif for numbers",
        Array.isArray(r.images) && r.images[0].media_type === "image/png"
        && r.text.includes('"measurement_file"'), r.text);

  resolve._grab.timelineOps.length = 0;
  const rPre = await tools.executeTool(state, "grab_still",
    { pre_grade: true, timecode: "01:00:01:14", out_dir: stillDir });
  check("pre_grade grab succeeds", rPre.ok, rPre.text);
  const ops = resolve._grab.timelineOps
    .map((o) => o.replace(/claude_pregrade_\w+/, "claude_pregrade"));
  // Parked at 01:00:01:14 = 38 timeline frames into the item; 60fps media
  // in the 24 timeline -> source frame 100 + 38*2.5 = 195 -> temp frame
  // 195*(24/60) = 78 -> 00:00:03:06. The clocks must convert, not mix.
  check("pre_grade: temp timeline built, parked on source frame, grabbed, "
        + "then deleted with the original timeline restored",
        JSON.stringify(ops) === JSON.stringify(
          ["create:1", "setcur:claude_pregrade",
           "park:00:00:03:06", "grab",
           "setcur:Timeline 1", "delete:1"]),
        JSON.stringify(ops));
  check("pre_grade flagged in the result",
        rPre.text.includes('"pre_grade":true'), rPre.text);
  check("pre_grade_map reports the parking math and confirms the park",
        rPre.text.includes('"source_frame":195')
        && rPre.text.includes('"temp_fps":24')
        && rPre.text.includes('"dest_frame":78')
        && rPre.text.includes('"parked":true'), rPre.text);
  check("pre_grade grab is a write under Ask-before-edits, plain grab a read",
        tools.needsApproval({ permissionMode: "Ask before edits" },
                            "grab_still", { pre_grade: true }) === true
        && tools.needsApproval({ permissionMode: "Ask before edits" },
                               "grab_still", {}) === false);

  // compare_stills: identical, metadata-only, and genuinely different
  const cmpA = path.join(stillDir, "cmp_a.tif");
  const cmpB = path.join(stillDir, "cmp_b.tif");
  fsmod.writeFileSync(cmpA, buildTiff16());
  fsmod.writeFileSync(cmpB, buildTiff16());
  let rc = await tools.executeTool(state, "compare_stills",
                                   { path_a: cmpA, path_b: cmpB });
  check("compare_stills: identical files byte-identical",
        rc.ok && rc.text.includes('"byte_identical":true'), rc.text);
  const tweaked = buildTiff16();
  tweaked.writeUInt16LE(65535, tweaked.length - 12);   // one sample to full
  fsmod.writeFileSync(cmpB, tweaked);
  rc = await tools.executeTool(state, "compare_stills",
                               { path_a: cmpA, path_b: cmpB });
  check("compare_stills: a changed sample is caught with stats",
        rc.ok && rc.text.includes('"byte_identical":false')
        && rc.text.includes('"differing_samples_pct"')
        && rc.text.includes('"verdict":"images differ"'), rc.text);
  rc = await tools.executeTool(state, "compare_stills",
                               { path_a: cmpA, path_b: "/nope.tif" });
  check("compare_stills: unreadable path is a plain error",
        !rc.ok && rc.text.includes("Cannot read"), rc.text);

  // Phase 2: the pipeline doctor
  const side = tools.parseSonySidecar(SONY_SIDECAR);
  check("sony sidecar parsed to camera ground truth",
        side.capture_gamma === "s-log3-cine"
        && side.expected_input_color_space === "S-Gamut3.Cine/S-Log3"
        && side.capture_fps === "59.94p" && side.camera === "ILCE-6700"
        && side.camera_lut === "SL3SG3Ctos709.cube",
        JSON.stringify(side));
  const rDoc = await tools.executeTool(state, "pipeline_doctor", {});
  check("doctor runs read-only and reports", rDoc.ok, rDoc.text);
  check("doctor: unmanaged project flagged",
        rDoc.text.includes("not colour managed"), rDoc.text);
  check("doctor: sidecar-vs-input mismatch found with the fix named",
        rDoc.text.includes("Camera recorded S-Gamut3.Cine/S-Log3")
        && rDoc.text.includes("Rec.709 Gamma 2.4")
        && rDoc.text.includes("inherited from the project default"),
        rDoc.text);
  check("doctor: empty Gamma Notes traced to unread sidecar",
        rDoc.text.includes("Gamma Notes is empty"), rDoc.text);
  check("doctor: frame-rate mix warning",
        rDoc.text.includes("60 media in a 24 timeline"), rDoc.text);
  check("doctor: conversion LUT on node 2 spotted via GetLUT probe",
        rDoc.text.includes("SL3SG3Ctos709.cube")
        && rDoc.text.includes("log-to-709"), rDoc.text);
  check("doctor: API walls stated",
        rDoc.text.includes("OFX nodes")
        && rDoc.text.includes("cannot"), rDoc.text);

  // parser units: EXR header and depth labels
  const exr = Buffer.concat([
    Buffer.from([0x76, 0x2f, 0x31, 0x01, 2, 0, 0, 0]),
    Buffer.from("compression\0compression\0"),
    Buffer.from([1, 0, 0, 0, 4]),
    Buffer.from("channels\0chlist\0"),
    Buffer.from([8, 0, 0, 0]),
    Buffer.from("R\0"), Buffer.from([1, 0, 0, 0, 0]),
    Buffer.from([0]),
  ]);
  const exrInfo = tools.parseExr(exr);
  check("exr header parsed (half-float, piz)",
        exrInfo && exrInfo.pixelType === "half-float 16"
        && exrInfo.compression === "piz", JSON.stringify(exrInfo));
  check("depth labels honest",
        tools.effectiveDepthLabel([250, 250, 250]).startsWith("8 bit")
        && tools.effectiveDepthLabel([900, 800, 700]).startsWith("~10 bit")
        && tools.effectiveDepthLabel([60000, 1, 1]).startsWith("~14-16"));

  // Under plain node there is no electron module: shrinkProxy must degrade
  // to null quietly so grab_still falls back to the raw-PNG attach path.
  check("shrinkProxy degrades to null without Electron",
        tools.shrinkProxy("/nonexistent.png") === null);

  // -- approvals --------------------------------------------------------
  state.permissionMode = "Ask before edits";
  check("readonly free in ask mode", !tools.needsApproval(state, "list_markers"));
  check("edits gated in ask mode", tools.needsApproval(state, "add_marker"));

  let seen = null;
  state.onApprovalNeeded = (p) => { seen = p; };
  const pendingCall = tools.executeTool(state, "add_marker",
                                        { frame: 20, color: "Blue" });
  await new Promise((res) => setTimeout(res, 20));
  check("approval requested with payload", seen && seen.name === "add_marker");
  seen.answer("run");
  r = await pendingCall;
  check("approved call runs", r.ok && resolve._markers[20], r.text);

  seen = null;
  const declined = tools.executeTool(state, "add_marker",
                                     { frame: 30, color: "Blue" });
  await new Promise((res) => setTimeout(res, 20));
  seen.answer("decline", "green only please");
  r = await declined;
  check("decline carries guidance",
        !r.ok && r.text.includes("green only please") && !resolve._markers[30],
        r.text);

  seen = null;
  const always = tools.executeTool(state, "add_marker",
                                   { frame: 40, color: "Blue" });
  await new Promise((res) => setTimeout(res, 20));
  seen.answer("always");
  r = await always;
  const after = await tools.executeTool(state, "add_marker",
                                        { frame: 50, color: "Blue" });
  check("session-wide consent sticks", r.ok && after.ok, after.text);
  state.approveAllEdits = false;

  // -- renderer fence-split contract (the 2-cycle, not a 3-cycle) --------
  const md = "before\n```js\nx=1\n```\nafter\n```\ny=2\n```\nend";
  const parts = md.split(/^[ \t]*```([\w+-]*)[ \t]*$\n?/m);
  const codeSegs = parts.filter((p, i) => i % 2 === 0 && (i / 2) % 2 === 1);
  const proseSegs = parts.filter((p, i) => i % 2 === 0 && (i / 2) % 2 === 0);
  check("fence split: code segments extracted",
        codeSegs.length === 2 && codeSegs[0].includes("x=1")
        && codeSegs[1].includes("y=2"), JSON.stringify(codeSegs));
  check("fence split: prose survives around fences",
        proseSegs.join("|").includes("before")
        && proseSegs.join("|").includes("after")
        && proseSegs.join("|").includes("end"), JSON.stringify(proseSegs));

  // -- bridge round trip through the real bridge.js child ----------------
  state.permissionMode = "Never ask";
  const bridgeEvents = [];
  const bridge = await tools.startBridge(state, (kind, name, payload) =>
    bridgeEvents.push([kind, name, payload]));
  const child = spawn(process.execPath, [path.join(__dirname, "bridge.js")], {
    env: Object.assign({}, process.env, {
      CLAUDE_RESOLVE_BRIDGE_PORT: String(bridge.port),
      CLAUDE_RESOLVE_BRIDGE_TOKEN: bridge.token,
    }),
  });
  const replies = [];
  let carry = "";
  child.stdout.on("data", (d) => {
    carry += d.toString();
    let i;
    while ((i = carry.indexOf("\n")) >= 0) {
      replies.push(JSON.parse(carry.slice(0, i)));
      carry = carry.slice(i + 1);
    }
  });
  const rpc = (obj) => child.stdin.write(JSON.stringify(obj) + "\n");
  rpc({ jsonrpc: "2.0", id: 0, method: "initialize",
        params: { protocolVersion: "2025-06-18" } });
  rpc({ jsonrpc: "2.0", method: "notifications/initialized" });
  rpc({ jsonrpc: "2.0", id: 1, method: "tools/list" });
  rpc({ jsonrpc: "2.0", id: 2, method: "tools/call",
        params: { name: "add_marker",
                  arguments: { frame: 99, color: "Green" } } });
  const stillDir2 = fsmod.mkdtempSync(path.join(osmod.tmpdir(), "stills2-"));
  rpc({ jsonrpc: "2.0", id: 3, method: "tools/call",
        params: { name: "grab_still", arguments: { out_dir: stillDir2 } } });
  await new Promise((res) => setTimeout(res, 1500));
  child.kill();
  bridge.server.close();

  check("mcp replies: no reply to the notification", replies.length === 4,
        String(replies.length));
  check("initialize echoes id 0 + version",
        replies[0] && replies[0].id === 0 &&
        replies[0].result.protocolVersion === "2025-06-18");
  const listed = replies[1] && replies[1].result.tools;
  check("tools/list forwards the registry",
        Array.isArray(listed) && listed.length === tools.TOOLS.length,
        listed && String(listed.length));
  const call = replies[2] && replies[2].result;
  check("tools/call round-trips into the fake Resolve",
        call && !call.isError && resolve._markers[99],
        JSON.stringify(call));
  const still = replies[3] && replies[3].result;
  check("grab_still arrives as an MCP image block",
        still && !still.isError
        && still.content.some((c) => c.type === "image"
                                     && c.mimeType === "image/png"
                                     && c.data.length > 4)
        && still.content.some((c) => c.type === "text"),
        JSON.stringify(still).slice(0, 200));
  check("bridge emits call + result events for the UI",
        bridgeEvents.some(([k, n]) => k === "call" && n === "add_marker")
        && bridgeEvents.some(([k, n, p]) => k === "result"
                             && n === "add_marker" && p.ok === true
                             && typeof p.ms === "number"),
        JSON.stringify(bridgeEvents));

  // -- history persistence ------------------------------------------------
  const historyLib = require("./history");
  const histDir = fsmod.mkdtempSync(path.join(osmod.tmpdir(), "hist-"));
  const hist = historyLib.makeHistory(histDir);

  check("empty chats are not saved",
        hist.save({ id: "h0", events: [{ kind: "notice", payload: "n" }] }) === null
        && fsmod.readdirSync(histDir).length === 0);

  const events1 = [{ kind: "you", payload: "sort my clips please" },
                   { kind: "toolcall", payload: { name: "add_marker" } },
                   { kind: "toolresult", payload: { name: "add_marker", ok: true } },
                   { kind: "assistant", payload: "done" }];
  const file1 = hist.save({ id: "h1", events: events1,
                            sessionId: "sess-9", model: "claude-opus-5" });
  check("chat saved atomically, no temp corpses",
        !!file1 && !fsmod.readdirSync(histDir).some((n) => n.includes(".tmp")));
  const loaded = hist.load("h1");
  check("session id and events survive the round trip",
        loaded.sessionId === "sess-9" && loaded.events.length === 4
        && loaded.title === "sort my clips please");
  const created1 = loaded.created;
  hist.save({ id: "h1", events: events1.concat([{ kind: "you", payload: "more" }]),
              sessionId: "sess-9", model: "claude-opus-5" });
  check("created stable across resaves", hist.load("h1").created === created1);

  await new Promise((res) => setTimeout(res, 5));   // distinct updated stamps
  hist.save({ id: "h2", events: [{ kind: "you", payload: "second chat" }] });
  fsmod.writeFileSync(path.join(histDir, "broken.json"), "{nope");
  const histRows = hist.list();
  check("list is newest-first and skips corrupt files",
        histRows.length === 2 && histRows[0].id === "h2"
        && histRows[0].turns === 1 && histRows[1].turns === 2,
        JSON.stringify(histRows));
  check("delete removes", hist.remove("h2") && hist.list().length === 1);
  check("delete missing is calm", hist.remove("ghost") === false);

  const recap = historyLib.buildRecap(events1);
  check("recap keeps only the dialogue",
        recap.includes("User: sort my clips") && recap.includes("Claude: done")
        && !recap.includes("add_marker"), recap.slice(0, 120));
  check("empty transcript -> empty recap",
        historyLib.buildRecap([{ kind: "toolcall", payload: {} }]) === "");
  check("recap capped",
        historyLib.buildRecap(Array.from({ length: 80 }, () =>
          ({ kind: "you", payload: "w".repeat(900) }))).length < 8000);

  console.log(failures ? "\n" + failures + " FAILURES"
                       : "\nALL PLUGIN CHECKS PASSED (" +
                         tools.TOOLS.length + " JS tools)");
  process.exit(failures ? 1 : 0);
}

main().catch((err) => { console.error(err); process.exit(1); });
