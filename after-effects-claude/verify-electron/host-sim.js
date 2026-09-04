// Stand-in for AE's ExtendScript engine: the REAL host/ae-tools.jsx running
// in a vm over a fake AE scripting DOM, in its OWN process (Node's vm
// crashes Blink inside a renderer: "ToExecutionContext(context)").
const fs = require("fs"), path = require("path"), vm = require("vm"), os = require("os");
const EXT = process.env.AE_EXT;
function CompItem() {} function FootageItem() {}
function Prop(name, mn, v) { this.name = name; this.matchName = mn; this._v = v; this._keys = []; this.numKeys = 0; this._eases = {}; }
Object.defineProperty(Prop.prototype, "value", { get() { return this._v; } });
Prop.prototype.setValue = function (v) { this._v = v; };
Prop.prototype.setValueAtTime = function (t, v) { this._keys.push([t, v]); this.numKeys = this._keys.length; };
Prop.prototype.removeKey = function (i) { this._keys.splice(i - 1, 1); this.numKeys = this._keys.length; };
Prop.prototype.setTemporalEaseAtKey = function (i, a, b) { this._eases[i] = [a, b]; };
Prop.prototype.setInterpolationTypeAtKey = function () {};
Prop.prototype.keyTime = function (i) { return this._keys[i - 1][0]; };
function Group(name, mn) { this.name = name; this.matchName = mn; this._p = []; this.numProperties = 0; }
Group.prototype.remove = function () { const a = this._parent._p; a.splice(a.indexOf(this), 1); this._parent.numProperties = a.length; };
Group.prototype.addProperty = function (mn) { const g = new Group(mn.replace("ADBE ", ""), mn); g._parent = this;
  if (mn === "ADBE Mask Atom") { g.name = "Mask " + (this._p.length + 1); g._p = [new Prop("Mask Path", "ADBE Mask Shape", null), new Prop("Mask Feather", "ADBE Mask Feather", [0, 0])]; }
  else if (/corner pin/i.test(mn)) g._p = ["Upper Left", "Upper Right", "Lower Left", "Lower Right"].map((n, i) => new Prop(n, "ADBE Corner Pin-000" + (i + 1), [0, 0]));
  else g._p = [new Prop("Blurriness", mn + " Blurriness", 0)];
  g.numProperties = g._p.length; this._p.push(g); this.numProperties = this._p.length; return g; };
Group.prototype.property = function (k) { return typeof k === "number" ? this._p[k - 1] : (this._p.find((p) => p.matchName === k || p.name === k) || null); };
function makeLayer(name, comp) { const tg = new Group("Transform", "ADBE Transform Group");
  tg._p = [new Prop("Anchor Point", "ADBE Anchor Point", [0, 0]), new Prop("Position", "ADBE Position", [960, 540]), new Prop("Scale", "ADBE Scale", [100, 100]), new Prop("Rotation", "ADBE Rotate Z", 0)]; tg.numProperties = 4;
  const groups = { "ADBE Time Remapping": new Prop("Time Remap", "ADBE Time Remapping", 0),
  "ADBE Effect Parade": new Group("Effects", "ADBE Effect Parade"), "ADBE Mask Parade": new Group("Masks", "ADBE Mask Parade"), "ADBE Transform Group": tg };
  const l = { name, startTime: 0, inPoint: 0, outPoint: 10, stretch: 100, hasVideo: true, selected: false, source: null, timeRemapEnabled: false, canSetTimeRemapEnabled: true,
    moveToEnd() {}, moveBefore(o) { const a = comp._layers; a.splice(a.indexOf(l), 1); a.splice(a.indexOf(o), 0, l); },
    setTrackMatte(m, t) { l._trackMatte = { matte: m.name, type: t }; }, property(k) { return groups[k] || null; } };
  Object.defineProperty(l, "index", { get() { return comp._layers.indexOf(l) + 1; } }); return l; }
function makeComp(name, w, h, fps, dur) { const c = Object.create(CompItem.prototype);
  Object.assign(c, { name, width: w, height: h, frameRate: fps, duration: dur, time: 0, numLayers: 0, _layers: [] });
  c.layers = { add(item) { const l = makeLayer(item.name, c); l.source = item; c._layers.unshift(l); c.numLayers = c._layers.length; return l; } };
  c.layer = (i) => c._layers[i - 1]; c.openInViewer = () => {};
  c.remove = () => { project._items.splice(project._items.indexOf(c), 1); project.numItems = project._items.length; };
  c.saveFrameToPng = (t, f) => fs.writeFileSync(f.fsName, Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==", "base64"));
  return c; }
const project = { file: null, numItems: 0, _items: [], activeItem: null, item(i) { return project._items[i - 1]; },
  items: { addComp(n, w, h, pa, d, fps) { const c = makeComp(n, w, h, fps, d); project._items.push(c); project.numItems = project._items.length; project.activeItem = c; return c; } },
  importFile(io) { const f = Object.create(FootageItem.prototype); f.name = path.basename(io._path); f.duration = 5; f.width = 1920; f.height = 1080; f.frameRate = 24; f.hasVideo = true; f.mainSource = { file: { fsName: io._path }, isStill: false }; project._items.push(f); project.numItems = project._items.length; return f; },
  renderQueue: { items: { add() { return { outputModule() { return { templates: ["H.264 - Match Render Settings - 15 Mbps"], applyTemplate() {}, file: null }; }, applyTemplate() {}, remove() {}, templates: ["Best Settings"], status: "DONE" }; } }, render() {}, queueInAME() {} } };
function FileC(p) { this.fsName = p; this._path = p; this._pos = 0; }
Object.defineProperty(FileC.prototype, "exists", { get() { return fs.existsSync(this.fsName); } });
Object.defineProperty(FileC.prototype, "length", { get() { try { return fs.statSync(this.fsName).size; } catch (e) { return 0; } } });
FileC.prototype.open = function () { return fs.existsSync(this.fsName); };
FileC.prototype.seek = function (pos, mode) { const n = this.length; this._pos = mode === 2 ? Math.max(0, n - pos) : mode === 1 ? this._pos + pos : pos; return true; };
FileC.prototype.read = function (n) { const b = fs.readFileSync(this.fsName); const s = b.slice(this._pos, this._pos + n).toString("latin1"); this._pos += n; return s; };
FileC.prototype.close = function () { return true; };
const ctx = vm.createContext({ app: { project, beginUndoGroup() {}, endUndoGroup() {}, preferences: { getPrefAsLong: () => 1 },
    findMenuCommandId(n) { return /paste mocha mask/i.test(n) ? 5007 : 0; },
    executeCommand(id) { if (id !== 5007) return; for (const it of project._items) if (it instanceof CompItem) for (const l of it._layers) if (l.selected) {
      const m = l.property("ADBE Mask Parade").addProperty("ADBE Mask Atom"); const mp = m.property("ADBE Mask Shape");
      for (let k = 0; k < 3; k++) mp.setValueAtTime(it.time + k / 24, { vertices: [[k, k]] }); } } },
  TrackMatteType: { LUMA: "LUMA", LUMA_INVERTED: "LUMA_INVERTED", ALPHA: "ALPHA", ALPHA_INVERTED: "ALPHA_INVERTED" },
  CompItem, FootageItem, File: FileC, Folder: Object.assign(function (p) { this.fsName = p; this.exists = fs.existsSync(p); this.create = () => fs.mkdirSync(p, { recursive: true }); }, { userData: { fsName: os.homedir() } }),
  ImportOptions: function (f) { this._path = f._path; }, Shape: function () { this.vertices = []; this.closed = false; },
  KeyframeEase: function (s, i) { this.speed = s; this.influence = i; }, KeyframeInterpolationType: { HOLD: 3 }, MaskMode: { SUBTRACT: 6914 }, RQItemStatus: { DONE: "DONE" },
  Date, isFinite, parseInt, $: { sleep() {} } });
vm.runInContext(fs.readFileSync(path.join(EXT, "host", "ae-tools.jsx"), "utf8"), ctx);

process.on("message", ({ id, script }) => {
  let out;
  try { out = String(vm.runInContext(script, ctx)); }
  catch (e) { out = "EvalScript error."; }
  process.send({ id, out });
});
