#!/usr/bin/env node
// Headless tests for the After Effects host tool layer: ae-tools.jsx is
// plain ES3, so it runs under Node against a fake AE scripting DOM. What
// these tests prove: the tool logic, JSON contract, and error shapes.
// What only live AE can prove: the actual scripting DOM behaviour.
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");

let failures = 0;
function check(label, ok, detail) {
  if (ok) console.log("  ok  " + label);
  else { failures += 1; console.log("FAIL  " + label + "  "
                                    + (detail || "")); }
}

// ------------------------------------------------------- fake AE DOM (ES3)
function FakeProperty(name, matchName, value) {
  this.name = name; this.matchName = matchName; this._value = value;
  this._keys = []; this.numKeys = 0; this._eases = {}; this._interp = {};
}
FakeProperty.prototype.setValue = function (v) { this._value = v; };
Object.defineProperty(FakeProperty.prototype, "value",
  { get: function () { return this._value; } });
FakeProperty.prototype.setValueAtTime = function (t, v) {
  this._keys.push({ t: t, v: v }); this.numKeys = this._keys.length;
};
FakeProperty.prototype.removeKey = function (i) {
  this._keys.splice(i - 1, 1); this.numKeys = this._keys.length;
};
FakeProperty.prototype.setTemporalEaseAtKey = function (i, ein, eout) {
  this._eases[i] = { ein: ein, eout: eout };
};
FakeProperty.prototype.setInterpolationTypeAtKey = function (i, t) {
  this._interp[i] = t;
};
FakeProperty.prototype.keyTime = function (i) { return this._keys[i - 1].t; };

function FakeGroup(name, matchName) {
  this.name = name; this.matchName = matchName;
  this._props = []; this.numProperties = 0;
}
FakeGroup.prototype.addProperty = function (mn) {
  let child;
  if (mn === "ADBE Mask Atom") child = makeMask();
  else child = makeEffect(mn);
  child._parent = this;
  this._props.push(child); this.numProperties = this._props.length;
  return child;
};
FakeGroup.prototype.remove = function () {
  const arr = this._parent._props;
  arr.splice(arr.indexOf(this), 1);
  this._parent.numProperties = arr.length;
};
FakeGroup.prototype.property = function (key) {
  if (typeof key === "number") return this._props[key - 1];
  for (const p of this._props)
    if (p.matchName === key || p.name === key) return p;
  return null;
};

function makeEffect(mn) {
  const g = new FakeGroup(mn.replace("ADBE ", ""), mn);
  if (/corner pin/i.test(mn))
    g._props = ["Upper Left", "Upper Right", "Lower Left", "Lower Right"]
      .map((n, i) => new FakeProperty(n, "ADBE Corner Pin-000" + (i + 1), [0, 0]));
  else if (/power pin/i.test(mn))
    g._props = ["Top Left", "Top Right", "Bottom Left", "Bottom Right"]
      .map((n, i) => new FakeProperty(n, "CC Power Pin-000" + (i + 2), [0, 0]));
  else
    g._props = [new FakeProperty("Blurriness", mn + " Blurriness", 0),
                new FakeProperty("Direction", mn + " Direction", 0)];
  g.numProperties = g._props.length;
  return g;
}
function makeMask() {
  const m = new FakeGroup("Mask 1", "ADBE Mask Atom");
  m._props = [new FakeProperty("Mask Path", "ADBE Mask Shape", null),
              new FakeProperty("Mask Feather", "ADBE Mask Feather", [0, 0])];
  m.numProperties = 2;
  m.inverted = false; m.maskMode = 6913;
  return m;
}

function CompItem() {} function FootageItem() {}
function makeLayer(name, comp) {
  const layer = {
    name: name, startTime: 0, inPoint: 0, outPoint: 10, stretch: 100,
    hasVideo: true, selected: false, source: null, _trackMatte: null,
    timeRemapEnabled: false, canSetTimeRemapEnabled: true,
    moveToEnd: function () { comp._order.push(name); },
    moveBefore: function (other) {
      const arr = comp._layers;
      arr.splice(arr.indexOf(layer), 1);
      arr.splice(arr.indexOf(other), 0, layer);
    },
    setTrackMatte: function (m, t) { layer._trackMatte = { layer: m, type: t }; },
    _groups: {
      "ADBE Time Remapping": new FakeProperty("Time Remap",
                                              "ADBE Time Remapping", 0),
      "ADBE Effect Parade": new FakeGroup("Effects", "ADBE Effect Parade"),
      "ADBE Mask Parade": new FakeGroup("Masks", "ADBE Mask Parade"),
      "ADBE Transform Group": (function () {
        const t = new FakeGroup("Transform", "ADBE Transform Group");
        t._props = [new FakeProperty("Anchor Point", "ADBE Anchor Point", [0, 0]),
                    new FakeProperty("Position", "ADBE Position", [0, 0]),
                    new FakeProperty("Scale", "ADBE Scale", [100, 100]),
                    new FakeProperty("Rotation", "ADBE Rotate Z", 0),
                    new FakeProperty("Opacity", "ADBE Opacity", 100)];
        t.numProperties = 5;
        return t;
      })(),
    },
    property: function (key) { return this._groups[key] || null; },
  };
  Object.defineProperty(layer, "index",
    { get: function () { return comp._layers.indexOf(layer) + 1; } });
  return layer;
}

let pendingPng = null, pngSleeps = 0;

function makeComp(name, w, h, fps, dur) {
  const comp = Object.create(CompItem.prototype);
  comp.name = name; comp.width = w; comp.height = h;
  comp.frameRate = fps; comp.duration = dur; comp.time = 0;
  comp.numLayers = 0; comp._layers = []; comp._order = [];
  comp.layers = {
    add: function (item, dur2) {
      const l = makeLayer(item.name, comp);
      l.source = item;
      comp._layers.unshift(l); comp.numLayers = comp._layers.length;
      return l;
    },
    addText: function (txt) {
      const l = makeLayer("TXT:" + txt, comp);
      const doc = new FakeProperty("Source Text", "ADBE Text Document",
        { font: "", fontSize: 0, fillColor: [1, 1, 1], tracking: 0 });
      const tp = new FakeGroup("Text", "ADBE Text Properties");
      tp._props = [doc]; tp.numProperties = 1;
      l._groups["ADBE Text Properties"] = tp;
      comp._layers.unshift(l); comp.numLayers = comp._layers.length;
      return l;
    },
  };
  comp.layer = function (i) { return comp._layers[i - 1]; };
  comp.openInViewer = function () {};
  comp.saveFrameToPng = function (t, f) {
    // Like AE: the file appears at once; the rest lands after the call.
    fs.writeFileSync(f.fsName, "PNGDATA@" + t);
    pendingPng = f.fsName;
  };
  comp.remove = function () {
    const items = comp._project._items;
    items.splice(items.indexOf(comp), 1);
    comp._project.numItems = items.length;
    if (comp._project.activeItem === comp) comp._project.activeItem = null;
  };
  return comp;
}

function buildSandbox() {
  const project = {
    file: null, numItems: 0, _items: [],
    item: function (i) { return project._items[i - 1]; },
    activeItem: null,
    items: { addComp: function (n, w, h, pa, d, fps) {
      const c = makeComp(n, w, h, fps, d);
      c._project = project;
      project._items.push(c); project.numItems = project._items.length;
      project.activeItem = c;
      return c;
    } },
    importFile: function (io) {
      const f = Object.create(FootageItem.prototype);
      f.name = path.basename(io._path); f.duration = 5;
      f.width = 1920; f.height = 1080; f.frameRate = 24; f.hasVideo = true;
      f.mainSource = { file: { fsName: io._path }, isStill: false };
      project._items.push(f); project.numItems = project._items.length;
      return f;
    },
    renderQueue: { items: { add: function (c) { return {
      outputModule: function () { return {
        templates: ["H.264 - Match Render Settings - 15 Mbps", "Lossless"],
        applyTemplate: function () {}, file: null }; },
      applyTemplate: function () {}, remove: function () {},
      templates: ["Best Settings"], status: "DONE", render: true }; } },
      render: function () {}, queueInAME: function () {} },
  };
  const sandbox = {
    app: { project: project,
           beginUndoGroup: function () {}, endUndoGroup: function () {},
           preferences: { getPrefAsLong: function () { return 1; } },
           _pasteFails: false,
           findMenuCommandId: function (name) {
             return /paste mocha mask/i.test(name) ? 5007 : 0; },
           executeCommand: function (id) {
             if (id !== 5007 || sandbox.app._pasteFails) return;
             for (const it of project._items) if (it instanceof CompItem)
               for (const l of it._layers) if (l.selected) {
                 const m = l._groups["ADBE Mask Parade"].addProperty("ADBE Mask Atom");
                 const mp = m.property("ADBE Mask Shape");
                 for (let k = 0; k < 3; k++)
                   mp.setValueAtTime(it.time + k / 24, { vertices: [[k, k]] });
               }
           } },
    CompItem: CompItem, FootageItem: FootageItem,
    File: (function () {
      function F(p) { this.fsName = p; this._path = p; this._pos = 0; }
      Object.defineProperty(F.prototype, "exists",
        { get: function () { return fs.existsSync(this.fsName); } });
      Object.defineProperty(F.prototype, "length",
        { get: function () { try { return fs.statSync(this.fsName).size; }
                             catch (e) { return 0; } } });
      F.prototype.open = function () { return fs.existsSync(this.fsName); };
      F.prototype.seek = function (pos, mode) {
        const n = this.length;
        this._pos = mode === 2 ? Math.max(0, n - pos)
                  : mode === 1 ? this._pos + pos : pos;
        return true;
      };
      F.prototype.read = function (n) {
        const b = fs.readFileSync(this.fsName);
        const s = b.slice(this._pos, this._pos + n).toString("latin1");
        this._pos += n;
        return s;
      };
      F.prototype.close = function () { return true; };
      return F;
    })(),
    Folder: function (p) { this.fsName = p; this.exists = fs.existsSync(p);
      this.create = function () { fs.mkdirSync(p, { recursive: true }); }; },
    ImportOptions: function (f) { this._path = f._path; },
    Shape: function () { this.vertices = []; this.closed = false; },
    KeyframeEase: function (speed, influence) {
      this.speed = speed; this.influence = influence; },
    KeyframeInterpolationType: { LINEAR: 1, BEZIER: 2, HOLD: 3 },
    MaskMode: { ADD: 6913, SUBTRACT: 6914 },
    RQItemStatus: { DONE: "DONE" },
    TrackMatteType: { LUMA: "LUMA", LUMA_INVERTED: "LUMA_INVERTED",
                      ALPHA: "ALPHA", ALPHA_INVERTED: "ALPHA_INVERTED",
                      NO_TRACK_MATTE: "NONE" },
    Date: Date, isFinite: isFinite, parseInt: parseInt,
    $: { sleep: function () { pngSleeps += 1; } },
  };
  sandbox.Folder.userData = { fsName: require("os").tmpdir() };
  return sandbox;
}

// ------------------------------------------------------------------ tests
const hostSrc = fs.readFileSync(path.join(__dirname,
  "com.jamstand.claude.ae", "host", "ae-tools.jsx"), "utf8");
const sandbox = buildSandbox();
vm.createContext(sandbox);
vm.runInContext(hostSrc, sandbox);
const invoke = (name, args) =>
  JSON.parse(vm.runInContext(
    "CA_invoke(" + JSON.stringify(name) + ","
    + JSON.stringify(JSON.stringify(args || {})) + ")", sandbox));

let r = invoke("get_project_overview", {});
check("overview: empty project, pref surfaced",
      r.ok && r.data.comps.length === 0
      && r.data.scripting_write_enabled === true, JSON.stringify(r));

r = invoke("create_comp", { name: "Edit", width: 1080, height: 1920,
                            fps: 59.94, duration_s: 20 });
check("create_comp", r.ok && r.data.fps === 59.94
      && r.data.width === 1080, JSON.stringify(r));

const tmp = require("os").tmpdir();
fs.writeFileSync(path.join(tmp, "C0392.MP4"), "x");
r = invoke("import_media", { paths: [path.join(tmp, "C0392.MP4"),
                                     "/nope/missing.mp4"] });
check("import_media: imports and reports missing individually",
      r.ok && r.data.imported[0].name === "C0392.MP4"
      && r.data.imported[1].error === "not found", JSON.stringify(r));

r = invoke("add_clip", { item_name: "C0392.MP4", in_s: 2, out_s: 3.5,
                         start_s: 0 });
check("add_clip: source [2,3.5] lands at comp 0 (inPoint is COMP time)",
      r.ok && r.data.comp_start_s === 0 && r.data.comp_end_s === 1.5
      && sandbox.app.project.activeItem.layer(1).startTime === -2,
      JSON.stringify(r));

r = invoke("speed_ramp", { layer: 1, keys: [
  { at_s: 0, source_s: 2 },
  { at_s: 1, source_s: 2.4, ease_speed: 0, ease_influence: 60 },
  { at_s: 1.5, source_s: 3.4 }] });
check("speed_ramp: remap enabled, 3 keys, ease landed",
      r.ok && r.data.keys === 3
      && (function () {
        const sb = sandbox.app.project.activeItem.layer(1);
        return sb.timeRemapEnabled === true
          && sb._groups["ADBE Time Remapping"]._eases[2].ein[0]
             .influence === 60;
      })(), JSON.stringify(r));

r = invoke("apply_effect", { layer: 1, effect: "ADBE Gaussian Blur 2",
                             settings: { Blurriness: 12, Nope: 1 } });
check("apply_effect: sets found props, reports property list honestly",
      r.ok && r.data.set.indexOf("Blurriness") >= 0
      && r.data.set.indexOf("Nope (NOT FOUND)") >= 0
      && r.data.properties.length === 2, JSON.stringify(r));

r = invoke("add_text", { text: "ANTIGRAVITY", size: 120,
                         color: [1, 0.8, 0], start_s: 2, duration_s: 1.5 });
check("add_text: styled and timed",
      r.ok && r.data.start_s === 2 && r.data.out_s === 3.5,
      JSON.stringify(r));

r = invoke("add_mask", { layer: 1, vertices: [[0, 0], [100, 0],
                                              [100, 100]], feather: 40 });
check("add_mask: shape + feather",
      r.ok && r.data.masks === 1, JSON.stringify(r));

r = invoke("grab_frame", { time_s: 1.25 });
check("grab_frame: starts the save and RETURNS AT ONCE (no $.sleep polling in AE)",
      r.ok && fs.existsSync(r.data.file) && pngSleeps === 0
      && fs.readFileSync(r.data.file, "latin1") === "PNGDATA@1.25",
      JSON.stringify(r) + " sleeps=" + pngSleeps);
try { fs.unlinkSync(r.data.file); } catch (e) {}

r = invoke("list_render_templates", {});
check("render templates listed",
      r.ok && r.data.output_modules.some((t) => /H\.264/.test(t)),
      JSON.stringify(r));

r = invoke("run_extendscript", { code: "1 + 41" });
check("run_extendscript returns the value", r.ok && r.data.result === 42,
      JSON.stringify(r));

r = invoke("speed_ramp", { layer: 99, keys: [] });
// ------------------------------------------------- tracking bridge (host)
const tf = path.join(require("os").tmpdir(), "ca-test-car.mp4");
fs.writeFileSync(tf, "fake footage");
invoke("import_media", { paths: [tf] });
invoke("create_comp", { name: "Track", width: 1920, height: 1080, fps: 24,
                        duration_s: 10 });
invoke("add_clip", { item_name: "ca-test-car.mp4", comp: "Track",
                     start_s: 2, in_s: 0.5, out_s: 4 });
let li = invoke("layer_info", { layer: 1, comp: "Track" });
check("layer_info: file, fps, start, SOURCE in/out",
  li.ok && li.data.source.file === tf && li.data.source.fps === 24
  && li.data.start_s === 1.5 && Math.abs(li.data.source_in_s - 0.5) < 1e-9
  && Math.abs(li.data.source_out_s - 4) < 1e-9 && li.data.index === 1
  && li.data.stretch === 100, JSON.stringify(li));
{
  const before = sandbox.app.project.numItems;
  const trackCompIdx = [...Array(before)].map((_, i) => sandbox.app.project.item(i + 1))
    .findIndex((it) => it.name === "Track") + 1;
  const g = invoke("grab_source_frame", { layer: 1, comp: "Track", source_time_s: 1.5 });
  const tmpComp = sandbox.app.project.item(sandbox.app.project.numItems);
  check("grab_source_frame: renders the layer's SOURCE alone in a temp comp at source size",
        g.ok && fs.existsSync(g.data.file) && /^__ClaudeGrab__/.test(g.data.temp_comp)
        && sandbox.app.project.numItems === before + 1 && tmpComp.name === g.data.temp_comp
        && tmpComp.width === 1920 && tmpComp._layers.length === 1
        && g.data.width === 1920 && g.data.source_time_s === 1.5 && trackCompIdx > 0,
        JSON.stringify(g));
  const rm = invoke("remove_temp_comp", { name: g.data.temp_comp });
  check("remove_temp_comp: sweeps only the grab comp", rm.ok && rm.data.removed === 1
        && sandbox.app.project.numItems === before
        && [...Array(before)].every((_, i) => !/__ClaudeGrab__/.test(sandbox.app.project.item(i + 1).name)),
        JSON.stringify(rm));
  try { fs.unlinkSync(g.data.file); } catch (e) {}
}
const trackComp = [...Array(sandbox.app.project.numItems)]
  .map((_, i) => sandbox.app.project.item(i + 1)).find((it) => it.name === "Track");
const trackLayer = trackComp.layer(1);
const kfBlocks = [
  { group: "Effects", name: "Corner Pin #1", prop: "Upper Left #2",
    keys: [{ frame: 0, values: [10, 20] }, { frame: 12, values: [11, 21] }] },
  { group: "Effects", name: "Corner Pin #1", prop: "Lower Right",
    keys: [{ frame: 0, values: [300, 200] }] },
  { group: "Transform", name: "Position", prop: "",
    keys: [{ frame: 24, values: [960, 540, 0] }] },
  { group: "Transform", name: "Rotation", prop: "",
    keys: [{ frame: 24, values: [12.5] }] },
];
let ak = invoke("apply_keyframe_data", { layer: 1, comp: "Track", fps: 24,
  blocks: kfBlocks, time_offset_s: 1.5, stretch: 100 });
const pin = trackLayer._groups["ADBE Effect Parade"].property("Corner Pin");
const ul = pin && pin.property("Upper Left");
const pos = trackLayer._groups["ADBE Transform Group"].property("Position");
const rot = trackLayer._groups["ADBE Transform Group"].property("Rotation");
check("apply_keyframe_data: one Corner Pin effect, keys at start + f/fps",
  ak.ok && ak.data.applied.length === 4
  && trackLayer._groups["ADBE Effect Parade"].numProperties === 1
  && ul && ul._keys.length === 2 && ul._keys[0].t === 1.5 && ul._keys[1].t === 2
  && ul._keys[1].v[0] === 11, JSON.stringify(ak) + " " + JSON.stringify(ul && ul._keys));
check("apply_keyframe_data: Position trimmed to 2D, Rotation scalar, times offset",
  pos._keys.length === 1 && pos._keys[0].t === 2.5 && pos._keys[0].v.length === 2
  && rot._keys[0].v === 12.5, JSON.stringify([pos._keys, rot._keys]));
ak = invoke("apply_keyframe_data", { layer: 1, comp: "Track", fps: 24,
  blocks: kfBlocks.slice(0, 1), time_offset_s: 1.5 });
check("apply_keyframe_data: re-apply replaces, never doubles",
  ak.ok && ul._keys.length === 2 && pin.property("Lower Right")._keys.length === 1,
  JSON.stringify(ul._keys));
ak = invoke("apply_keyframe_data", { layer: 1, comp: "Track", fps: 24,
  blocks: [{ group: "Masks", name: "Mask 1", prop: "Mask Path",
             keys: [{ frame: 0, values: [1] }] }] });
ak = invoke("apply_keyframe_data", { layer: 1, comp: "Track", fps: 24,
  blocks: [{ group: "Effects", name: "CC Power Pin #1", prop: "Top Left",
             keys: [{ frame: 0, values: [1, 2] }] }], effect_name: "CC Power Pin (Mocha 0-4s)" });
check("apply_keyframe_data: a NEW effect takes effect_name so later chats can tell runs apart",
  ak.ok && trackLayer._groups["ADBE Effect Parade"].property("CC Power Pin (Mocha 0-4s)") !== null,
  JSON.stringify(ak));
check("apply_keyframe_data: unsupported group is a clean error",
  !ak.ok && /Unsupported keyframe group/.test(ak.error), JSON.stringify(ak));
let pm = invoke("paste_mocha_mask", { layer: 1, comp: "Track", time_s: 1.5 });
check("paste_mocha_mask: selects the layer, runs the menu command, reports keys",
  pm.ok && pm.data.menu_id === 5007 && pm.data.masks_added.length === 1
  && pm.data.masks_added[0].keys === 3 && pm.data.masks_added[0].first_key_s === 1.5
  && trackLayer.selected === true && trackComp.time === 1.5, JSON.stringify(pm));
sandbox.app._pasteFails = true;
pm = invoke("paste_mocha_mask", { layer: 1, comp: "Track" });
check("paste_mocha_mask: nothing pasted is a clean error naming the cause",
  !pm.ok && /added no mask/.test(pm.error) && /clipboard/.test(pm.error), JSON.stringify(pm));
sandbox.app._pasteFails = false;
const tf2 = path.join(require("os").tmpdir(), "ca-test-matte.mp4");
fs.writeFileSync(tf2, "fake matte");
let im = invoke("import_and_matte", { layer: 1, comp: "Track", file: tf2, matte: "luma" });
check("import_and_matte: matte lands above the layer, luma track matte set, times aligned",
  im.ok && im.data.matte_layer === 1 && im.data.target_layer === 2
  && trackLayer._trackMatte && trackLayer._trackMatte.type === "LUMA"
  && trackComp.layer(1).startTime === 1.5 && trackComp.layer(1).inPoint === 2,
  JSON.stringify(im) + " " + JSON.stringify(trackLayer._trackMatte && trackLayer._trackMatte.type));
im = invoke("import_and_matte", { layer: 2, comp: "Track", file: "/nope/none.mp4" });
check("import_and_matte: missing file is a clean error", !im.ok && /not found/i.test(im.error), JSON.stringify(im));

{
  const frames = (n, start) => [...Array(n)].map((_, i) => ({ frame: start + i,
    points: [[100 + i, 100], [300 + i, 100], [300 + i, 250], [100 + i, 250]] }));
  const masksBefore = trackLayer._groups["ADBE Mask Parade"].numProperties;
  let mk = invoke("apply_mask_keyframes", { layer: trackLayer.index, comp: "Track", name: "Mocha Mask",
    fps: 59.94, time_offset_s: 1.5, stretch: 100, frames: frames(3, 90), feather: 2 });
  const mgrp = trackLayer._groups["ADBE Mask Parade"];
  const mocha = mgrp.property("Mocha Mask");
  const mpath = mocha && mocha.property("ADBE Mask Shape");
  check("apply_mask_keyframes: creates a named mask, keys at start + f/fps, closed 4-vertex shapes",
    mk.ok && mk.data.keys === 3 && mk.data.vertices === 4 && mgrp.numProperties === masksBefore + 1
    && mpath && Math.abs(mpath._keys[0].t - (1.5 + 90 / 59.94)) < 1e-9
    && mpath._keys[0].v.vertices.length === 4 && mpath._keys[0].v.closed === true
    && mocha.rotoBezier === true, JSON.stringify(mk) + " " + (mpath && mpath._keys.length));
  mk = invoke("apply_mask_keyframes", { layer: trackLayer.index, comp: "Track", name: "Mocha Mask",
    fps: 59.94, time_offset_s: 1.5, frames: frames(2, 93), append: true });
  check("apply_mask_keyframes: append adds keys to the same mask (chunked calls)",
    mk.ok && mk.data.keys === 5 && mgrp.numProperties === masksBefore + 1
    && mgrp.property("Mocha Mask") === mocha, JSON.stringify(mk));
  mk = invoke("apply_mask_keyframes", { layer: trackLayer.index, comp: "Track", name: "Mocha Mask",
    fps: 59.94, time_offset_s: 1.5, frames: frames(2, 0) });
  check("apply_mask_keyframes: re-apply replaces the mask instead of stacking keys",
    mk.ok && mk.data.keys === 2 && mgrp.numProperties === masksBefore + 1
    && mgrp.property("Mocha Mask") !== mocha, JSON.stringify(mk));
  mk = invoke("apply_mask_keyframes", { layer: trackLayer.index, comp: "Track", frames: [] });
  check("apply_mask_keyframes: empty frames is a clean error", !mk.ok && /No mask frames/.test(mk.error));
}

check("bad layer index is a clean JSON error, never a bare throw",
      r.ok === false && /has \d+ layers/.test(r.error), JSON.stringify(r));

r = invoke("no_such_tool", {});
check("unknown tool is a clean error",
      r.ok === false && /Unknown host tool/.test(r.error));

console.log(failures ? "\n" + failures + " FAILURES"
                     : "\nALL AE HOST CHECKS PASSED");
process.exit(failures ? 1 : 0);
