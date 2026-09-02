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
function Group(name, mn) { this.name = name; this.matchName = mn; this._p = []; this.numProperties = 0; }
Group.prototype.addProperty = function (mn) { const g = new Group(mn, mn);
  g._p = [new Prop("Blurriness", mn + " Blurriness", 0)]; g.numProperties = 1; this._p.push(g); this.numProperties = this._p.length; return g; };
Group.prototype.property = function (k) { return typeof k === "number" ? this._p[k - 1] : (this._p.find((p) => p.matchName === k || p.name === k) || null); };
function makeLayer(name) { const groups = { "ADBE Time Remapping": new Prop("Time Remap", "ADBE Time Remapping", 0),
  "ADBE Effect Parade": new Group("Effects", "ADBE Effect Parade"), "ADBE Mask Parade": new Group("Masks", "ADBE Mask Parade") };
  return { name, startTime: 0, inPoint: 0, outPoint: 10, timeRemapEnabled: false, canSetTimeRemapEnabled: true, moveToEnd() {}, property(k) { return groups[k] || null; } }; }
function makeComp(name, w, h, fps, dur) { const c = Object.create(CompItem.prototype);
  Object.assign(c, { name, width: w, height: h, frameRate: fps, duration: dur, time: 0, numLayers: 0, _layers: [] });
  c.layers = { add(item) { const l = makeLayer(item.name); c._layers.unshift(l); c.numLayers = c._layers.length; return l; } };
  c.layer = (i) => c._layers[i - 1]; c.openInViewer = () => {};
  c.saveFrameToPng = (t, f) => fs.writeFileSync(f.fsName, Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==", "base64"));
  return c; }
const project = { file: null, numItems: 0, _items: [], activeItem: null, item(i) { return project._items[i - 1]; },
  items: { addComp(n, w, h, pa, d, fps) { const c = makeComp(n, w, h, fps, d); project._items.push(c); project.numItems = project._items.length; project.activeItem = c; return c; } },
  importFile(io) { const f = Object.create(FootageItem.prototype); f.name = path.basename(io._path); f.duration = 5; project._items.push(f); project.numItems = project._items.length; return f; },
  renderQueue: { items: { add() { return { outputModule() { return { templates: ["H.264 - Match Render Settings - 15 Mbps"], applyTemplate() {}, file: null }; }, applyTemplate() {}, remove() {}, templates: ["Best Settings"], status: "DONE" }; } }, render() {}, queueInAME() {} } };
function FileC(p) { this.fsName = p; this._path = p; }
Object.defineProperty(FileC.prototype, "exists", { get() { return fs.existsSync(this.fsName); } });
const ctx = vm.createContext({ app: { project, beginUndoGroup() {}, endUndoGroup() {}, preferences: { getPrefAsLong: () => 1 } },
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
