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

function FakeGroup(name, matchName) {
  this.name = name; this.matchName = matchName;
  this._props = []; this.numProperties = 0;
}
FakeGroup.prototype.addProperty = function (mn) {
  let child;
  if (mn === "ADBE Mask Atom") child = makeMask();
  else child = makeEffect(mn);
  this._props.push(child); this.numProperties = this._props.length;
  return child;
};
FakeGroup.prototype.property = function (key) {
  if (typeof key === "number") return this._props[key - 1];
  for (const p of this._props)
    if (p.matchName === key || p.name === key) return p;
  return null;
};

function makeEffect(mn) {
  const g = new FakeGroup(mn.replace("ADBE ", ""), mn);
  g._props = [new FakeProperty("Blurriness", mn + " Blurriness", 0),
              new FakeProperty("Direction", mn + " Direction", 0)];
  g.numProperties = 2;
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
    name: name, startTime: 0, inPoint: 0, outPoint: 10,
    timeRemapEnabled: false, canSetTimeRemapEnabled: true,
    moveToEnd: function () { comp._order.push(name); },
    _groups: {
      "ADBE Time Remapping": new FakeProperty("Time Remap",
                                              "ADBE Time Remapping", 0),
      "ADBE Effect Parade": new FakeGroup("Effects", "ADBE Effect Parade"),
      "ADBE Mask Parade": new FakeGroup("Masks", "ADBE Mask Parade"),
      "ADBE Transform Group": (function () {
        const t = new FakeGroup("Transform", "ADBE Transform Group");
        t._props = [new FakeProperty("Position", "ADBE Position", [0, 0]),
                    new FakeProperty("Scale", "ADBE Scale", [100, 100]),
                    new FakeProperty("Opacity", "ADBE Opacity", 100)];
        t.numProperties = 3;
        return t;
      })(),
    },
    property: function (key) { return this._groups[key] || null; },
  };
  return layer;
}

function makeComp(name, w, h, fps, dur) {
  const comp = Object.create(CompItem.prototype);
  comp.name = name; comp.width = w; comp.height = h;
  comp.frameRate = fps; comp.duration = dur; comp.time = 0;
  comp.numLayers = 0; comp._layers = []; comp._order = [];
  comp.layers = {
    add: function (item, dur2) {
      const l = makeLayer(item.name, comp);
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
    fs.writeFileSync(f.fsName, "PNGDATA@" + t);
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
      project._items.push(c); project.numItems = project._items.length;
      project.activeItem = c;
      return c;
    } },
    importFile: function (io) {
      const f = Object.create(FootageItem.prototype);
      f.name = path.basename(io._path); f.duration = 5;
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
           preferences: { getPrefAsLong: function () { return 1; } } },
    CompItem: CompItem, FootageItem: FootageItem,
    File: (function () {
      function F(p) { this.fsName = p; this._path = p; }
      Object.defineProperty(F.prototype, "exists",
        { get: function () { return fs.existsSync(this.fsName); } });
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
    Date: Date, isFinite: isFinite, parseInt: parseInt,
    $: { sleep: function () {} },
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
check("add_clip: source in/out honoured",
      r.ok && r.data.in_s === 2 && r.data.out_s === 3.5, JSON.stringify(r));

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
check("grab_frame: file written and returned",
      r.ok && fs.existsSync(r.data.file)
      && fs.readFileSync(r.data.file, "utf8") === "PNGDATA@1.25",
      JSON.stringify(r));
try { fs.unlinkSync(r.data.file); } catch (e) {}

r = invoke("list_render_templates", {});
check("render templates listed",
      r.ok && r.data.output_modules.some((t) => /H\.264/.test(t)),
      JSON.stringify(r));

r = invoke("run_extendscript", { code: "1 + 41" });
check("run_extendscript returns the value", r.ok && r.data.result === 42,
      JSON.stringify(r));

r = invoke("speed_ramp", { layer: 99, keys: [] });
check("bad layer index is a clean JSON error, never a bare throw",
      r.ok === false && /has \d+ layers/.test(r.error), JSON.stringify(r));

r = invoke("no_such_tool", {});
check("unknown tool is a clean error",
      r.ok === false && /Unknown host tool/.test(r.error));

console.log(failures ? "\n" + failures + " FAILURES"
                     : "\nALL AE HOST CHECKS PASSED");
process.exit(failures ? 1 : 0);
