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
                      timecodes: [], timelineOps: [], cdls: [],
                      setLuts: {}, fusionOps: [], lutReject: false,
                      nodeLabels: {} };
  // Real Resolve hands back HOLLOW tool handles (live-verified), so the
  // fake comp only exposes what worked live: comp-level methods + Execute.
  grabState.vignettePresent = false;
  grabState.fusionComp = {
    AddTool: () => ({}),                        // hollow, like life
    FindTool: (nm) => {
      if (nm === "MediaIn1" || nm === "MediaOut1") return {};
      if ((nm === "ClaudeVignetteBC" || nm === "ClaudeVignetteMask")
          && grabState.vignettePresent) return {};
      return null;
    },
    Execute: (lua) => {
      grabState.fusionOps.push(lua);
      if (/AddTool/.test(lua)) grabState.vignettePresent = true;
      if (/Delete/.test(lua)) grabState.vignettePresent = false;
    },
  };
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
    GetLUT: (i) => (i === 2 ? "/luts/SL3SG3Ctos709.cube"
                    : grabState.setLuts[i] || ""),
    SetLUT: (i, lutPath) => {
      if (grabState.lutReject) return false;
      grabState.setLuts[i] = lutPath; return true;
    },
    GetDuration: () => 84,
    GetNodeGraph: () => ({ GetNodeLabel: () => "" }),  // no setter, like life
    GetFusionCompByIndex: () => grabState.fusionComp,
    GetMediaPoolItem: () => ({
      // 60fps media in the 24fps timeline: pre_grade must convert clocks.
      GetClipProperty: (k) =>
        (k === "Input Color Space" ? "S-Gamut3.Cine/S-Log3"
         : k === "FPS" ? 60 : ""),
    }),
  };
  const secondItem = {
    GetName: () => "C0572.MP4",
    GetNodeGraph: () => ({
      ApplyGradeFromDRX: (file, mode) => {
        grabState.drxApplied = { file, mode, clip: "C0572.MP4",
                                 route: "node graph" };
        return true;
      },
      SetNodeLabel: (n, label) => { grabState.nodeLabels[n] = label;
                                    return true; },
      GetNodeLabel: (n) => grabState.nodeLabels[n] || "",
    }),
    GetStart: () => 86484,
    GetDuration: () => 84,
    GetLeftOffset: () => 0,
    GetLUT: () => "",
    GetMediaPoolItem: currentItem.GetMediaPoolItem,
    SetCDL: (m) => { grabState.cdls.push(m); return true; },
  };
  const timeline = {
    GetName: () => "Timeline 1",
    ApplyGradeFromDRX: (file, mode, item) => {
      grabState.drxApplied = { file, mode,
                               clip: item && item.GetName() };
      return true;
    },
    GetSetting: (k) => (k === "timelineFrameRate" ? "24" : ""),
    GetCurrentTimecode: () => {                 // seek lands one read late,
      const held = grabState.staleReads || 0;   // like real Resolve
      if (held > 0) {
        grabState.staleReads = held - 1;
        return grabState.prevTimecode || "01:00:00:00";
      }
      return grabState.timecodes[grabState.timecodes.length - 1]
             || "01:00:00:00";
    },
    SetCurrentTimecode: (tc) => {
      grabState.prevTimecode =
        grabState.timecodes[grabState.timecodes.length - 1] || "01:00:00:00";
      grabState.timecodes.push(tc);
      grabState.staleReads = 1;
      return tc !== "bad";
    },
    GrabStill: () => {                    // intermittently falsy, like life
      grabState.calls += 1;
      return grabState.calls < 2 ? null : { still: true };
    },
    GetStartFrame: () => 86400,
    GetEndFrame: () => 86448,
    GetCurrentVideoItem: () => currentItem,
    GetItemListInTrack: (kind, idx) =>
      (kind === "video" && idx === 1 ? [currentItem, secondItem] : []),
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
    AddSubFolder: (parent, name) => {
      grabState.binsAdded = (grabState.binsAdded || []).concat(name);
      return { GetName: () => name };
    },
    SetCurrentFolder: (f) => {
      grabState.currentBin = f && f.GetName(); return true;
    },
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

  // Phase 3: QC scanner on the fake's known pixel values
  const st = tools.tiffStats(buildTiff16(), tools.parseTiff(buildTiff16()));
  check("tiffStats: exact per-channel stats from known samples",
        st.channels[0].min === 0 && st.channels[0].max === 24000
        && st.channels[0].mean_pct === 18.31
        && st.channels[0].at_exact_max_pct === 50
        && st.channels[2].max === 65535, JSON.stringify(st));
  const rQc = await tools.executeTool(state, "qc_scan", { out_dir: stillDir });
  check("qc_scan walks the track and measures at full depth",
        rQc.ok && rQc.text.includes('"clips_scanned":2')
        && rQc.text.includes('"measured":"pre-grade source pixels'),
        rQc.text);
  check("qc_scan names its measurement space and exposure model",
        rQc.text.includes('"measurement_space":"raw source code values')
        && rQc.text.includes('"exposure_model":"slog3"'), rQc.text);
  check("qc_scan flags plateaus and cast with thresholds stated",
        rQc.text.includes("clipped-highlights")
        && rQc.text.includes("crushed-shadows")
        && rQc.text.includes("colour-cast")
        && rQc.text.includes('"plateau_pct":0.5'), rQc.text);

  // Phase 4: the matcher's gate, math, and closed loop
  const mkCh = (m, sd) => [0, 1, 2].map(() => ({ mean_pct: m, std_pct: sd }));
  check("matchGate refuses a 6-stop day/night gap",
        tools.matchGate(mkCh(44, 10), mkCh(7.5, 5)).refuse === true
        && /stops apart/.test(
             tools.matchGate(mkCh(44, 10), mkCh(7.5, 5)).reason));
  check("matchGate refuses a 10x contrast regime gap",
        tools.matchGate(mkCh(44, 20), mkCh(44, 2)).refuse === true
        && /Contrast regimes/.test(
             tools.matchGate(mkCh(44, 20), mkCh(44, 2)).reason));
  check("matchGate passes near-neighbours",
        tools.matchGate(mkCh(44, 10), mkCh(40, 9)).refuse === false);
  check("deriveCdl on identical stats is the identity grade",
        (() => { const c = tools.deriveCdl(mkCh(44, 10), mkCh(44, 10));
                 return c.slope.every((v) => Math.abs(v - 1) < 1e-9)
                     && c.offset.every((v) => Math.abs(v) < 1e-9); })());
  const rMatch = await tools.executeTool(state, "match_shot",
    { reference: 1, target: 2, out_dir: stillDir });
  check("match_shot runs the closed loop and converges",
        rMatch.ok && rMatch.text.includes('"refuse":false')
        && rMatch.text.includes('"final_cdl"'), rMatch.text);
  check("identical frames produce a neutral CDL write",
        resolve._grab.cdls.length === 1
        && resolve._grab.cdls[0].Slope === "1.0000 1.0000 1.0000"
        && resolve._grab.cdls[0].Offset === "0.0000 0.0000 0.0000"
        && resolve._grab.cdls[0].NodeIndex === "1",
        JSON.stringify(resolve._grab.cdls));
  check("match_shot logs the write and hands back the revert",
        rMatch.text.includes('"log_file"')
        && rMatch.text.includes('"revert"')
        && rMatch.text.includes('"Slope":"1 1 1"'), rMatch.text);
  check("match_shot attaches both proxies for eyeballing",
        Array.isArray(rMatch.images) && rMatch.images.length === 2,
        JSON.stringify((rMatch.images || []).length));

  // Phase 5: look designer
  const ident = tools.generateCube({}, 9).trim().split("\n");
  check("empty look generates an identity LUT",
        ident[1] === "LUT_3D_SIZE 9"
        && ident[2] === "0.000000 0.000000 0.000000"
        && ident[ident.length - 1] === "1.000000 1.000000 1.000000"
        && ident.length === 2 + 9 * 9 * 9, ident.length + " lines");
  check("applyLook identity holds mid-lattice",
        tools.applyLook([0.4, 0.5, 0.6], {})
          .every((v, i) => Math.abs(v - [0.4, 0.5, 0.6][i]) < 1e-9));
  check("warmth pushes red up and blue down",
        (() => { const w = tools.applyLook([0.5, 0.5, 0.5], { warmth: 1 });
                 return w[0] > 0.5 && w[2] < 0.5
                        && Math.abs(w[1] - 0.5) < 1e-9; })());
  check("hue adjustment desaturates only the targeted hue",
        (() => { const L = { hue_adjustments: [{ hue: 0, width: 30,
                                                 sat: 0 }] };
                 const red = tools.applyLook([0.8, 0.2, 0.2], L);
                 const blue = tools.applyLook([0.2, 0.2, 0.8], L);
                 return Math.abs(red[0] - red[1]) < 0.01
                        && Math.abs(blue[2] - 0.8) < 1e-6; })());
  check("di round-trip", Math.abs(tools.diDecode(0.336) - 0.18) < 0.01);
  const rLook = await tools.executeTool(state, "design_look",
    { look: { warmth: 0.5, contrast: 1.1 }, name: "test look",
      size: 9, out_dir: stillDir });
  check("design_look writes, applies, and verifies the cube",
        rLook.ok && rLook.text.includes('"verified":true')
        && fsmod.readFileSync(
             JSON.parse(rLook.text).lut_file, "utf8")
             .startsWith("# Generated"), rLook.text);
  resolve._grab.lutReject = true;       // the Mac install's live behaviour
  const rLook2 = await tools.executeTool(state, "design_look",
    { look: {}, size: 9, out_dir: stillDir });
  check("design_look degrades to manual-load when SetLUT is dead",
        rLook2.ok && rLook2.text.includes('"applied":false')
        && rLook2.text.includes("manual_load"), rLook2.text);
  resolve._grab.lutReject = false;
  const rVig = await tools.executeTool(state, "apply_vignette",
    { amount: 0.4 });
  check("apply_vignette drives Fusion via Execute lua, then verifies",
        rVig.ok
        && resolve._grab.fusionOps.some((l) =>
             /AddTool\("EllipseMask"/.test(l) && /m\.Invert = 1/.test(l)
             && /b\.Gain = 0\.6000/.test(l)
             && /mo\.Input = b\.Output/.test(l))
        && rVig.text.includes('"tools_present_after_execute":true'),
        rVig.text);
  const rVigOff = await tools.executeTool(state, "apply_vignette",
    { action: "remove" });
  check("apply_vignette remove executes and confirms absence",
        rVigOff.ok && rVigOff.text.includes('"removed":true'), rVigOff.text);

  // node graph templates via .drx
  const os2 = require("os");
  const tmplDir = path.join(os2.homedir(), "ClaudeNodeTemplates");
  let rT = await tools.executeTool(state, "grade_template",
    { action: "save", name: "four node layout" });
  check("grade_template save captures the drx sidecar",
        rT.ok && fsmod.existsSync(path.join(tmplDir,
                                            "four_node_layout.drx")),
        rT.text);
  rT = await tools.executeTool(state, "grade_template", { action: "list" });
  check("grade_template list finds it",
        rT.ok && rT.text.includes("four_node_layout"), rT.text);
  rT = await tools.executeTool(state, "grade_template",
    { action: "apply", name: "four node layout", clip: 2 });
  check("grade_template apply stamps via the node graph route",
        rT.ok && resolve._grab.drxApplied
        && resolve._grab.drxApplied.route === "node graph"
        && resolve._grab.drxApplied.mode === 0
        && resolve._grab.drxApplied.file.endsWith("four_node_layout.drx")
        && rT.text.includes('"route":"node graph"'), rT.text);
  rT = await tools.executeTool(state, "grade_template",
    { action: "apply", name: "does not exist" });
  check("grade_template apply of a missing name is a plain error",
        !rT.ok && rT.text.includes("No template named"), rT.text);
  // a drx whose payload hides inside base64(zlib(...)), like real DaVinci
  const zlib3 = require("zlib");
  const hidden = "<?xml version=\"1.0\"?><g><blob>"
    + zlib3.deflateSync(Buffer.from("node label EXP here")).toString("base64")
    .padEnd(220, "A")            // long enough to look like a blob run
    + "</blob></g>";
  fsmod.writeFileSync(path.join(tmplDir, "wrapped.drx"), hidden);
  let rW = await tools.executeTool(state, "grade_template",
    { action: "inspect", name: "wrapped", search: ["EXP"] });
  check("inspect decodes base64+zlib blobs and searches inside",
        rW.ok && rW.text.includes("base64@")
        && rW.text.includes('"term":"EXP"'), rW.text);
  try { fsmod.unlinkSync(path.join(tmplDir, "wrapped.drx")); } catch (e) {}

  rT = await tools.executeTool(state, "grade_template",
    { action: "inspect", name: "four node layout",
      search: ["sidecar", "EXP"] });
  check("grade_template inspect reports format and finds strings",
        rT.ok && rT.text.includes('"term":"sidecar"')
        && rT.text.includes('"encoding":"utf8"')
        && !rT.text.includes('"term":"EXP"')
        && rT.text.includes("feasible"), rT.text);
  try { fsmod.unlinkSync(path.join(tmplDir, "four_node_layout.drx")); }
  catch (e) {}

  // node labels
  let rL = await tools.executeTool(state, "label_nodes",
    { labels: { 1: "EXP", 2: "WB" }, clip: 2 });
  check("label_nodes sets and reads back when the setter exists",
        rL.ok && resolve._grab.nodeLabels[1] === "EXP"
        && rL.text.includes('"readback":"WB"'), rL.text);
  rL = await tools.executeTool(state, "label_nodes",
    { labels: { 1: "EXP" } });          // currentItem: no SetNodeLabel
  check("label_nodes hands back the manual .drx route otherwise",
        rL.ok && rL.text.includes('"settable":false')
        && rL.text.includes("grade_template save"), rL.text);

  // study_edit: cut detection units + profile round trip
  check("detectCuts collapses runs and respects the threshold",
        JSON.stringify(tools.detectCuts([1, 2, 50, 3, 60, 61, 2], 8))
          === "[2,4]"
        && tools.detectCuts([1, 2, 3], 8).length === 0);
  check("styleAggregate summarises across edits",
        (() => { const ag = tools.styleAggregate([
            { duration_s: 30, cuts: 10,
              shot_lengths_s: [1, 2, 3],
              shots: [{ mean_level_pct: 20, cast_rg: 2, cast_bg: 0 }] },
            { duration_s: 30, cuts: 20,
              shot_lengths_s: [0.5, 1.5],
              shots: [{ mean_level_pct: 60, cast_rg: 3, cast_bg: -1 }] }]);
          return ag.edits_studied === 2 && ag.cuts_per_minute === 30
                 && ag.shot_length_s.median === 1.5
                 && ag.cast_tendency === "warm-leaning"; })());
  const styleFile = path.join(osmod.homedir(), "ClaudeAssistantStyle",
                              "test_profile.json");
  try { fsmod.unlinkSync(styleFile); } catch (e) {}
  const tifsBefore = fsmod.readdirSync(stillDir)
    .filter((n) => n.endsWith(".tif")).length;
  let rS = await tools.executeTool(state, "study_edit",
    { name: "test profile", source: "unit-edit", out_dir: stillDir,
      max_samples: 3, interval_frames: 12 });
  check("study_edit samples, detects, and writes the profile",
        rS.ok && rS.text.includes('"samples":3')
        && rS.text.includes('"cuts_this_batch":0')
        && fsmod.existsSync(styleFile), rS.text);
  check("study_edit deletes its grab files as it goes",
        fsmod.readdirSync(stillDir).filter((n) => n.endsWith(".tif"))
          .length === tifsBefore,
        String(fsmod.readdirSync(stillDir)));
  rS = await tools.executeTool(state, "study_edit",
    { name: "test profile", source: "unit-edit", out_dir: stillDir,
      max_samples: 3, interval_frames: 12,
      start_frame: JSON.parse(rS.text).next_start_frame || 86436 });
  const prof = JSON.parse(fsmod.readFileSync(styleFile, "utf8"));
  check("study_edit resumes into the same entry and finalises",
        rS.ok && prof.edits.length === 1
        && prof.edits[0].complete === true
        && prof.aggregate.edits_studied === 1, JSON.stringify(prof));
  // The seam fix: a cut-free timeline studied in two batches must yield
  // ONE shot spanning everything, not one per batch.
  check("study_edit: batch seams do not split shots",
        prof.edits[0].shots.length === 1
        && prof.edits[0].shot_lengths_s[0] === 2
        && prof.edits[0].cuts === 0, JSON.stringify(prof.edits[0]));
  // Number(null) === 0 must not send a resume to frame zero.
  const parkedBefore = resolve._grab.timecodes.length;
  rS = await tools.executeTool(state, "study_edit",
    { name: "test profile", source: "unit-edit-2", out_dir: stillDir,
      max_samples: 2, interval_frames: 12, start_frame: null });
  check("study_edit: null cursor is a fresh study from timeline start",
        rS.ok && resolve._grab.timecodes[parkedBefore] === "01:00:00:00",
        JSON.stringify(resolve._grab.timecodes.slice(parkedBefore)));
  // Corrupt profile survival: damaged bytes preserved, never clobbered.
  fsmod.writeFileSync(styleFile, "{ definitely not json");
  rS = await tools.executeTool(state, "study_edit",
    { name: "test profile", source: "unit-edit-3", out_dir: stillDir,
      max_samples: 2, interval_frames: 12 });
  const backups = fsmod.readdirSync(path.dirname(styleFile))
    .filter((n) => n.startsWith("test_profile.json.corrupt-"));
  check("study_edit preserves a corrupt profile instead of clobbering",
        rS.ok && rS.text.includes("profile_recovered")
        && backups.length >= 1
        && JSON.parse(fsmod.readFileSync(styleFile, "utf8"))
             .edits.length === 1, rS.text);
  for (const b of backups) {
    try { fsmod.unlinkSync(path.join(path.dirname(styleFile), b)); }
    catch (e) {}
  }
  try { fsmod.unlinkSync(styleFile); } catch (e) {}
  // Drop-frame timecode vectors (standard SMPTE checks).
  check("dropFrameTimecode matches the standard vectors",
        tools.dropFrameTimecode(1800, 29.97) === "00:01:00;02"
        && tools.dropFrameTimecode(17982, 29.97) === "00:10:00;00"
        && tools.dropFrameTimecode(3600, 59.94) === "00:01:00;04"
        && tools.dropFrameTimecode(0, 29.97) === "00:00:00;00");
  // no_proxy grabs attach nothing and export no proxy file.
  const rNp = await tools.executeTool(state, "grab_still",
    { frame: 130, out_dir: stillDir, no_proxy: true });
  check("grab_still no_proxy attaches no image",
        rNp.ok && (!rNp.images || rNp.images.length === 0)
        && !rNp.text.includes("proxy_png"), rNp.text);

  // study_url: download seam injected, the Resolve side is real fakes
  state._testDownload = async (url, dir) => {
    const f = path.join(dir, "study_testvid.mp4");
    fsmod.writeFileSync(f, "fake video bytes for " + url);
    return f;
  };
  let rU = await tools.executeTool(state, "study_url",
    { url: "https://www.tiktok.com/@x/video/123", keep_file: false });
  check("study_url imports into the bin and builds the study timeline",
        rU.ok && rU.text.includes('"imported_to_bin":"Studied Edits"')
        && rU.text.includes('"timeline":"study_study_testvid"')
        && rU.text.includes("file deleted after import")
        && (resolve._grab.binsAdded || []).includes("Studied Edits")
        && resolve._grab.timelineOps.some((o) =>
             o === "setcur:study_study_testvid"),
        rU.text);
  delete state._testDownload;
  check("findYtDlp degrades to a PATH guess, never throws",
        typeof tools.findYtDlp() === "string" || tools.findYtDlp() === null);

  // /study slash command expansion
  const three = tools.expandSlash(
    "/study https://tiktok.com/a https://instagram.com/b https://youtu.be/c");
  check("/study expands links into one-at-a-time marching orders",
        three && three.includes("3 edit(s)")
        && three.includes("https://instagram.com/b")
        && three.includes("study_url") && three.includes("next_start_frame"),
        three);
  check("/study bare asks for an explanation, plain text stays null",
        /explain/i.test(tools.expandSlash("/study") || "")
        && tools.expandSlash("study this for me") === null
        && tools.expandSlash("hello") === null);

  // Gemini video eyes: fake Google's wire behaviour exactly, including
  // the doc-verified asymmetry (upload response wrapped in {file}, poll
  // response a BARE File) and the bad-key error shape.
  const gCalls = [];
  process.env.GEMINI_API_KEY = "test-key-for-fake-wire";
  state._testHttp = async (url, opts, body) => {
    gCalls.push({ url, method: (opts && opts.method) || "GET" });
    if (url.endsWith("/upload/v1beta/files"))
      return { status: 200,
               headers: { "x-goog-upload-url":
                          "https://generativelanguage.googleapis.com/up/1" },
               json: null };
    if (url.endsWith("/up/1"))
      return { status: 200, headers: {},
               json: { file: { uri: "https://g/files/f1", name: "files/f1",
                               state: "PROCESSING" } } };
    if (url.endsWith("/v1beta/files/f1") && (!opts || opts.method !== "DELETE")
        && !(opts && opts.method === "DELETE"))
      return { status: 200, headers: {},
               json: { name: "files/f1", state: "ACTIVE" } };  // bare File
    if (url.includes(":generateContent"))
      return { status: 200, headers: {}, json: {
        candidates: [{ content: { parts: [
          { thought: true, text: "internal reasoning" },
          { text: "Opens on a static wide; night rolling shots follow." },
          { text: "Grade leans teal in the shadows." } ] } }],
        usageMetadata: { totalTokenCount: 4321 } } };
    return { status: 204, headers: {}, json: null };
  };
  let rG = await tools.executeTool(state, "watch_video",
    { file: path.join(stillDir, "cmp_a.tif"), profile: "test profile2",
      source: "unit-edit" });
  check("watch_video runs the full upload/poll/ask flow",
        rG.ok
        && gCalls.some((c) => c.url.endsWith("/upload/v1beta/files"))
        && gCalls.some((c) => c.url.includes(":generateContent"))
        && gCalls.some((c) => c.method === "DELETE"),
        JSON.stringify(gCalls));
  check("watch_video joins text parts and drops thought parts",
        rG.text.includes("static wide")
        && rG.text.includes("teal in the shadows")
        && !rG.text.includes("internal reasoning")
        && rG.text.includes('"tokens":4321'), rG.text);
  state._testHttp = async () => ({ status: 400, headers: {}, json: {
    error: { code: 400, message: "API key not valid.",
             status: "INVALID_ARGUMENT",
             details: [{ reason: "API_KEY_INVALID" }] } } });
  rG = await tools.executeTool(state, "set_gemini_key",
    { key: "AIzaFakeButLongEnough12345" });
  check("set_gemini_key refuses to store a key Google rejects",
        !rG.ok && rG.text.includes("rejected the API key")
        && !fsmod.existsSync(tools.CONFIG_FILE)
           || !(tools.readConfig().gemini_api_key), rG.text);
  state._testHttp = async () => ({ status: 200, headers: {},
                                   json: { models: [] } });
  rG = await tools.executeTool(state, "set_gemini_key",
    { key: "AIzaFakeButLongEnough12345" });
  check("set_gemini_key stores after validation, never echoes the key",
        rG.ok && rG.text.includes('"key_ending":"...2345"')
        && !rG.text.includes("AIzaFakeButLongEnough")
        && tools.readConfig().gemini_api_key
           === "AIzaFakeButLongEnough12345", rG.text);
  check("geminiErrorText maps quota and bad-key distinctly",
        /rate limit/.test(tools.geminiErrorText(429,
          { error: { status: "RESOURCE_EXHAUSTED" } }))
        && /rejected the API key/.test(tools.geminiErrorText(400,
          { error: { status: "INVALID_ARGUMENT",
                     details: [{ reason: "API_KEY_INVALID" }] } })));
  delete state._testHttp;
  delete process.env.GEMINI_API_KEY;
  try { fsmod.unlinkSync(tools.CONFIG_FILE); } catch (e) {}
  try { fsmod.unlinkSync(path.join(osmod.homedir(),
    "ClaudeAssistantStyle", "test_profile2.json")); } catch (e) {}

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
