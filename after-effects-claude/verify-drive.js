// Drives the AE panel's real wiring end to end over real processes/sockets.
// REAL: bridge.js (spawned, MCP over stdio) -> TCP -> panel.js startBridge/
//       executeTool/approvals -> evalHost -> CA_invoke in host/ae-tools.jsx.
// SHIMMED (cannot exist in a Linux container): CEP's CSInterface (evalScript
//       runs the exact string CEP would eval, inside a vm holding the real
//       host script), the AE scripting DOM (`app`), and Chromium's Image/canvas.
"use strict";
const fs = require("fs"), path = require("path"), os = require("os");
const vm = require("vm"), net = require("net"), crypto = require("crypto");
const { spawn } = require("child_process");

const EXT = path.join(__dirname, "com.jamstand.claude.ae");
const HOME = fs.mkdtempSync(path.join(os.tmpdir(), "ae-home-"));
process.env.HOME = HOME;                       // isolate ~/Library writes

// ---------------------------------------------------------------- fake AE
function CompItem() {} function FootageItem() {}
function Prop(name, mn, v) { this.name = name; this.matchName = mn; this._v = v;
  this._keys = []; this.numKeys = 0; this._eases = {}; }
Object.defineProperty(Prop.prototype, "value", { get() { return this._v; } });
Prop.prototype.setValue = function (v) { this._v = v; };
Prop.prototype.setValueAtTime = function (t, v) { this._keys.push([t, v]); this.numKeys = this._keys.length; };
Prop.prototype.removeKey = function (i) { this._keys.splice(i - 1, 1); this.numKeys = this._keys.length; };
Prop.prototype.setTemporalEaseAtKey = function (i, a, b) { this._eases[i] = [a, b]; };
Prop.prototype.setInterpolationTypeAtKey = function () {};
function Group(name, mn) { this.name = name; this.matchName = mn; this._p = []; this.numProperties = 0; }
Group.prototype.addProperty = function (mn) {
  const g = new Group(mn, mn);
  g._p = mn === "ADBE Mask Atom"
    ? [new Prop("Mask Path", "ADBE Mask Shape"), new Prop("Mask Feather", "ADBE Mask Feather", [0, 0])]
    : [new Prop("Blurriness", mn + " Blurriness", 0), new Prop("Direction", mn + " Direction", 0)];
  g.numProperties = g._p.length; this._p.push(g); this.numProperties = this._p.length; return g; };
Group.prototype.property = function (k) {
  if (typeof k === "number") return this._p[k - 1];
  return this._p.find((p) => p.matchName === k || p.name === k) || null; };
function makeLayer(name, comp) {
  const tr = new Group("Transform", "ADBE Transform Group");
  tr._p = [new Prop("Position", "ADBE Position", [0, 0]), new Prop("Scale", "ADBE Scale", [100, 100])];
  const groups = { "ADBE Time Remapping": new Prop("Time Remap", "ADBE Time Remapping", 0),
    "ADBE Effect Parade": new Group("Effects", "ADBE Effect Parade"),
    "ADBE Mask Parade": new Group("Masks", "ADBE Mask Parade"), "ADBE Transform Group": tr };
  return { name, startTime: 0, inPoint: 0, outPoint: 10, timeRemapEnabled: false,
    canSetTimeRemapEnabled: true, moveToEnd() {}, property(k) { return groups[k] || null; }, _groups: groups };
}
function makeComp(name, w, h, fps, dur) {
  const c = Object.create(CompItem.prototype);
  Object.assign(c, { name, width: w, height: h, frameRate: fps, duration: dur, time: 0, numLayers: 0, _layers: [] });
  c.layers = { add(item) { const l = makeLayer(item.name, c); c._layers.unshift(l); c.numLayers = c._layers.length; return l; },
    addText(t) { const l = makeLayer("TXT:" + t, c);
      const tp = new Group("Text", "ADBE Text Properties");
      tp._p = [new Prop("Source Text", "ADBE Text Document", { font: "", fontSize: 0, fillColor: [1,1,1], tracking: 0 })];
      tp.numProperties = 1; l._groups["ADBE Text Properties"] = tp;
      c._layers.unshift(l); c.numLayers = c._layers.length; return l; } };
  c.layer = (i) => c._layers[i - 1]; c.openInViewer = () => {};
  // write a REAL 1x1 PNG so the panel's downscale path has bytes to read
  c.saveFrameToPng = (t, f) => fs.writeFileSync(f.fsName, Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==", "base64"));
  return c;
}
const project = { file: null, numItems: 0, _items: [], activeItem: null,
  item(i) { return project._items[i - 1]; },
  items: { addComp(n, w, h, pa, d, fps) { const c = makeComp(n, w, h, fps, d);
    project._items.push(c); project.numItems = project._items.length; project.activeItem = c; return c; } },
  importFile(io) { const f = Object.create(FootageItem.prototype); f.name = path.basename(io._path); f.duration = 5;
    project._items.push(f); project.numItems = project._items.length; return f; },
  renderQueue: { items: { add() { return { outputModule() { return { templates: ["H.264 - Match Render Settings - 15 Mbps"], applyTemplate() {}, file: null }; },
    applyTemplate() {}, remove() {}, templates: ["Best Settings"], status: "DONE" }; } }, render() {}, queueInAME() {} } };
function FileC(p) { this.fsName = p; this._path = p; }
Object.defineProperty(FileC.prototype, "exists", { get() { return fs.existsSync(this.fsName); } });
const aeCtx = vm.createContext({
  app: { project, beginUndoGroup() {}, endUndoGroup() {}, preferences: { getPrefAsLong: () => 1 } },
  CompItem, FootageItem, File: FileC,
  Folder: Object.assign(function (p) { this.fsName = p; this.exists = fs.existsSync(p); this.create = () => fs.mkdirSync(p, { recursive: true }); },
    { userData: { fsName: HOME } }),
  ImportOptions: function (f) { this._path = f._path; },
  Shape: function () { this.vertices = []; this.closed = false; },
  KeyframeEase: function (s, i) { this.speed = s; this.influence = i; },
  KeyframeInterpolationType: { HOLD: 3 }, MaskMode: { SUBTRACT: 6914 }, RQItemStatus: { DONE: "DONE" },
  Date, isFinite, parseInt, $: { sleep() {} },
});
vm.runInContext(fs.readFileSync(path.join(EXT, "host", "ae-tools.jsx"), "utf8"), aeCtx);

// -------------------------------------------------------------- CEP shim
const evalLog = [];
global.window = global;
global.CSInterface = class { evalScript(script, cb) {
  evalLog.push(script.slice(0, 80));
  let out; try { out = String(vm.runInContext(script, aeCtx)); }
  catch (e) { out = "EvalScript error."; }            // exactly what CEP hands back
  setImmediate(() => cb(out)); } };
global.Image = class { set src(v) { this._w = 1; setImmediate(() => this.onload && this.onload()); }
  get width() { return 1920; } get height() { return 1080; } };
global.document = { createElement() { return { width: 0, height: 0,
  getContext() { return { drawImage() {} }; },
  toDataURL() { return "data:image/jpeg;base64,/9j/FAKEJPEG"; } }; } };

// capture the TCP server + token that panel.js keeps private
let server = null;
const realCreate = net.createServer;
net.createServer = function () { server = realCreate.apply(net, arguments); return server; };
crypto.randomBytes = () => Buffer.from("00112233445566778899aabbccddeeff", "hex");
const TOKEN = "00112233445566778899aabbccddeeff";

require(path.join(EXT, "html", "panel.js"));    // the real panel brain
const ui = [];
window.assistant.onEvent((e) => { ui.push(e);
  if (e.kind === "approval") { console.log("   [UI] approval card for", e.payload.name);
    setTimeout(() => window.assistant.approval(nextDecision.shift() || "run", "make it cheaper"), 50); } });
const nextDecision = [];

// ------------------------------------------------------------- MCP client
function mcp(env) {
  const child = spawn(process.execPath, [path.join(EXT, "bridge.js")], { env });
  const lines = []; let carry = "";
  child.stdout.on("data", (d) => { carry += d; let i;
    while ((i = carry.indexOf("\n")) >= 0) { const l = carry.slice(0, i); carry = carry.slice(i + 1); if (l.trim()) lines.push(JSON.parse(l)); } });
  child.stderr.on("data", (d) => process.stderr.write("[bridge stderr] " + d));
  return { child, lines,
    send(o) { child.stdin.write(JSON.stringify(o) + "\n"); },
    waitFor(id, ms) { return new Promise((res, rej) => { const t0 = Date.now();
      (function poll() { const hit = lines.find((l) => l.id === id);
        if (hit) return res(hit); if (Date.now() - t0 > (ms || 5000)) return rej(new Error("no reply for id " + id));
        setTimeout(poll, 20); })(); }); } };
}
const show = (label, obj) => console.log("\n### " + label + "\n" + JSON.stringify(obj).slice(0, 700));

(async () => {
  await new Promise((r) => (function w() { server && server.listening ? r() : setTimeout(w, 10); })());
  const port = server.address().port;
  console.log("panel TCP bridge listening on 127.0.0.1:" + port + " token=" + TOKEN);
  const env = Object.assign({}, process.env, { CLAUDE_RESOLVE_BRIDGE_PORT: String(port), CLAUDE_RESOLVE_BRIDGE_TOKEN: TOKEN });
  const c = mcp(env);
  let id = 0;
  const call = async (method, params) => { const my = ++id; c.send({ jsonrpc: "2.0", id: my, method, params }); return c.waitFor(my); };
  const tool = (name, args) => call("tools/call", { name, arguments: args });

  show("initialize", await call("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "verify", version: "0" } }));
  const list = await call("tools/list", {});
  show("tools/list -> " + list.result.tools.length + " tools", list.result.tools.map((t) => t.name));

  show("get_project_overview (read-only, no approval expected)", await tool("get_project_overview", {}));
  show("create_comp (WRITE under 'Ask before edits' -> must raise the approval card)", await tool("create_comp", { name: "Verify", width: 1080, height: 1920, fps: 59.94, duration_s: 20 }));
  nextDecision.push("decline");
  show("import_media DECLINED with guidance", await tool("import_media", { paths: ["/nope.mp4"] }));
  nextDecision.push("always");
  const tmp = path.join(HOME, "C0392.MP4"); fs.writeFileSync(tmp, "x");
  show("import_media approved 'always'", await tool("import_media", { paths: [tmp] }));
  show("add_clip (should NOT prompt now — session-wide consent)", await tool("add_clip", { item_name: "C0392.MP4", in_s: 2, out_s: 3.5, start_s: 0 }));
  show("speed_ramp with eases", await tool("speed_ramp", { layer: 1, keys: [{ at_s: 0, source_s: 2 }, { at_s: 1, source_s: 2.4, ease_influence: 60 }, { at_s: 1.5, source_s: 3.4 }] }));
  const grab = await tool("grab_frame", { time_s: 1.25 });
  show("grab_frame -> content block types", grab.result.content.map((b) => b.type + (b.mimeType ? ":" + b.mimeType : "")));
  show("run_extendscript escape hatch", await tool("run_extendscript", { code: "app.project.activeItem.numLayers * 10" }));

  console.log("\n===== PROBES =====");
  show("🔍 speed_ramp layer 99 (bad index)", await tool("speed_ramp", { layer: 99, keys: [] }));
  show("🔍 unknown tool", await tool("definitely_not_a_tool", {}));
  show("🔍 tools/call with non-string name", await call("tools/call", { name: 42 }));
  show("🔍 unknown method", await call("nonsense/method", {}));
  c.send({ jsonrpc: "2.0", method: "notifications/initialized" });          // no id -> must get NO reply
  c.send({ jsonrpc: "2.0", id: 0, method: "ping" });                         // id 0 IS a request
  await new Promise((r) => setTimeout(r, 300));
  show("🔍 id:0 ping answered? / notification silent?", { repliesWithId0: c.lines.filter((l) => l.id === 0).length,
    totalReplies: c.lines.length, expectedReplies: id + 1 });
  show("🔍 run_extendscript that THROWS in the host", await tool("run_extendscript", { code: "throw new Error('boom')" }));
  show("🔍 run_extendscript with a SYNTAX error (CEP hands back 'EvalScript error.')", await tool("run_extendscript", { code: "this is not javascript" }));

  const bad = mcp(Object.assign({}, env, { CLAUDE_RESOLVE_BRIDGE_TOKEN: "wrong" }));
  bad.send({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} });
  show("🔍 second bridge with WRONG token -> tools/list", await bad.waitFor(1));
  bad.child.kill();

  console.log("\nUI events seen by app.js layer:", ui.map((e) => e.kind + (e.kind === "toolresult" ? "(" + e.payload.name + ":" + (e.payload.ok ? "ok" : "FAIL") + ")" : "")).join(" "));
  console.log("evalScript strings handed to 'CEP' (first 3):", evalLog.slice(0, 3));
  c.child.kill(); server.close(); process.exit(0);
})().catch((e) => { console.error("DRIVER FAILED:", e); process.exit(1); });
