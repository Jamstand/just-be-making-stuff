// Claude Assistant for After Effects — panel logic (CEP 12, Node 17 via
// --enable-nodejs --mixed-context). One context: this file provides the
// `assistant` API that app.js (shared with the Resolve plugin) consumes,
// plus the CLI turn runner, the MCP TCP bridge, the AE tool registry
// (dispatching into host/ae-tools.jsx via CSInterface.evalScript), and
// approvals/history.
"use strict";
/* global CSInterface, SystemPath */

// CEP runs every <script> of the panel in ONE shared page scope (unlike
// Electron, where main and renderer are separate processes). Top-level
// let/const here would collide with app.js — live launch #3 died on
// "Identifier 'busy' has already been declared" before app.js could parse.
// Everything lives inside this IIFE; only window.assistant is exposed.
(function () {

// A silent panel is the worst failure mode. If CEP ignored --enable-nodejs
// (or --mixed-context), `require` does not exist and nothing below can run:
// say so on screen instead of leaving an empty top bar.
if (typeof require !== "function") {
  const chat = document.getElementById("chat");
  const box = document.createElement("div");
  box.className = "card error";
  box.textContent = "Node.js is not available in this panel: CEP did not "
    + "honour the manifest's --enable-nodejs/--mixed-context flags, so the "
    + "assistant cannot start. Check ~/Library/Logs/CSXS/CEP12-AEFT.log "
    + "and the CSXS/manifest.xml CEFCommandLine block.";
  if (chat) chat.appendChild(box);
  throw new Error("CEP Node runtime missing");
}

const fs = require("fs");
const os = require("os");
const path = require("path");
const net = require("net");
const crypto = require("crypto");
const { spawn, execFile } = require("child_process");

const cs = new CSInterface();
// Without this, ⌘C/⌘V/⌘X/⌘A go to After Effects' own Edit menu and the
// panel never sees them (CEP registerKeyEventsInterest, since 6.1).
try {
  const keys = [];
  for (const keyCode of [65, 67, 86, 88])                // A C V X
    for (const mod of ["metaKey", "ctrlKey"]) {
      const k = { keyCode }; k[mod] = true; keys.push(k);
    }
  cs.registerKeyEventsInterest(JSON.stringify(keys));
} catch (e) {}
// Node's __dirname is not a reliable global inside a CEP page script; CEP's
// own API knows where the extension lives (doc-verified SystemPath).
const EXT_ROOT = (function () {
  try { const p = cs.getSystemPath(SystemPath.EXTENSION); if (p) return p; }
  catch (e) {}
  return typeof __dirname === "string" ? path.join(__dirname, "..") : ".";
})();
const historyLib = require(path.join(EXT_ROOT, "history.js"));
const USER_DATA = path.join(os.homedir(), "Library", "Application Support",
                            "ClaudeAssistantAE");
fs.mkdirSync(USER_DATA, { recursive: true });

const MODELS = ["claude-opus-5", "claude-fable-5", "claude-sonnet-5",
                "claude-haiku-4-5"];
const EFFORTS = ["low", "medium", "high", "xhigh", "max"];
const PERMISSION_MODES = ["Ask before edits", "Always ask", "Never ask"];
const APPROVAL_TIMEOUT_MS = 120000;

const SYSTEM_PROMPT = [
  "You drive Adobe After Effects for an editor through the mcp__ae__*",
  "tools. run_extendscript is the escape hatch: the full AE scripting DOM",
  "(app.project, CompItem, layers, properties). ES3 ONLY in that code —",
  "var, no arrow functions, no const/let, no template strings, no JSON",
  "object. Hard walls, say so instead of guessing: tracker/3D-camera-",
  "tracker/Warp-Stabilizer ANALYSIS cannot be invoked by script (reading",
  "existing track data works); output codecs are template-only (no",
  "field-by-field codec settings); Lumetri parameter names are not",
  "documented — apply_effect returns each effect's real property list, use",
  "it. Times are SECONDS. Layer indexes are 1-based, top of stack = 1;",
  "add_clip appends to the bottom. What IS fully scriptable, unlike",
  "DaVinci: speed ramps (speed_ramp / ADBE Time Remapping + eases), masks,",
  "text layers, every effect parameter, per-keyframe animation.",
  "The panel may pause a modifying tool call for the user's approval; if",
  "declined or timed out, never retry unchanged. Be concise: lead with",
  "the result.",
].join(" ");

// ------------------------------------------------------------ host bridge
function evalHost(name, args) {
  return new Promise((resolveP, rejectP) => {
    const call = "CA_invoke(" + JSON.stringify(name) + ","
      + JSON.stringify(JSON.stringify(args || {})) + ")";
    cs.evalScript(call, (raw) => {
      if (raw === "EvalScript error." || raw === undefined || raw === null)
        return rejectP(new Error("ExtendScript failed opaquely (EvalScript "
          + "error) — usually a host-side syntax problem or AE busy."));
      let parsed;
      try { parsed = JSON.parse(raw); }
      catch (e) { return rejectP(new Error("Unparseable host reply: "
        + String(raw).slice(0, 200))); }
      if (!parsed.ok) return rejectP(new Error(parsed.error || "host error"));
      resolveP(parsed.data);
    });
  });
}

// Downscale a grabbed PNG through the panel's own canvas (CEP is Chromium)
// so vision attachments stay small — no Electron nativeImage here.
function shrinkPng(filePath) {
  return new Promise((resolveP) => {
    try {
      const img = new Image();
      img.onload = () => {
        const w = Math.min(1280, img.width);
        const h = Math.round(img.height * (w / img.width));
        const canvas = document.createElement("canvas");
        canvas.width = w; canvas.height = h;
        canvas.getContext("2d").drawImage(img, 0, 0, w, h);
        const dataUrl = canvas.toDataURL("image/jpeg", 0.8);
        resolveP({ data: dataUrl.split(",")[1], media_type: "image/jpeg" });
      };
      img.onerror = () => resolveP(null);
      img.src = "file://" + filePath;
    } catch (e) { resolveP(null); }
  });
}

// ------------------------------------------------------------ tool registry
const TOOLS = [];
function tool(name, description, params, required, opts, fn) {
  TOOLS.push({ name, description, params: params || {},
               required: required || [], readonly: !!(opts && opts.readonly),
               fn: fn || ((state, a) => evalHost(name, a)) });
}

tool("get_project_overview",
  "Project items, comps (size/fps/duration/layers), the active comp, and "
  + "whether AE's 'Allow Scripts to Write Files and Access Network' pref "
  + "is on (grab_frame and render need it).", {}, [], { readonly: true });

tool("import_media", "Import absolute file paths into the project.",
  { paths: { type: "array", items: { type: "string" },
             description: "Absolute paths." } }, ["paths"], {});

tool("create_comp", "Create a comp and open it in the viewer.",
  { name: { type: "string" }, width: { type: "number" },
    height: { type: "number" }, fps: { type: "number" },
    duration_s: { type: "number" } }, [], {});

tool("add_clip",
  "Add a footage item as a layer: in/out in SOURCE seconds, start_s where "
  + "the cut lands in comp time. Appends beneath existing layers.",
  { item_name: { type: "string" }, comp: { type: "string" },
    start_s: { type: "number" }, in_s: { type: "number" },
    out_s: { type: "number" } }, ["item_name"], {});

tool("speed_ramp",
  "The move Resolve can't do: time-remap a layer with velocity keyframes. "
  + "keys: [{at_s: comp time, source_s: source time, ease_speed, "
  + "ease_influence (0.1-100)}] — a ramp = uneven source spacing; ease "
  + "shapes the acceleration curve.",
  { layer: { type: "number" }, comp: { type: "string" },
    keys: { type: "array", items: { type: "object" } } },
  ["layer", "keys"], {});

tool("set_keyframes",
  "Keyframe (or statically set) any property by match-name path, e.g. "
  + "path [\"ADBE Transform Group\",\"ADBE Scale\"], keys "
  + "[{at_s, value}]. hold:true = hold interpolation.",
  { layer: { type: "number" }, comp: { type: "string" },
    path: { type: "array", items: { type: "string" } },
    keys: { type: "array", items: { type: "object" } },
    hold: { type: "boolean" } }, ["layer", "path", "keys"], {});

tool("apply_effect",
  "Apply any effect by matchName ('ADBE Lumetri', 'ADBE Gaussian Blur 2', "
  + "'CC Force Motion Blur'...) or display name, optionally setting "
  + "properties. The result lists the effect's REAL property names — "
  + "iterate with those instead of guessing (Lumetri's are undocumented).",
  { layer: { type: "number" }, comp: { type: "string" },
    effect: { type: "string" }, settings: { type: "object" } },
  ["layer", "effect"], {});

tool("add_text",
  "Add a styled text layer (font = PostScript name, color = [r,g,b] 0-1).",
  { text: { type: "string" }, font: { type: "string" },
    size: { type: "number" }, color: { type: "array" },
    tracking: { type: "number" }, position: { type: "array" },
    start_s: { type: "number" }, duration_s: { type: "number" },
    comp: { type: "string" } }, ["text"], {});

tool("add_mask",
  "Draw a mask on a layer: vertices [[x,y]...] in layer pixels, optional "
  + "feather (px), inverted, mode 'subtract'. Static — AE's trackers are "
  + "not scriptable, so masks do not follow subjects.",
  { layer: { type: "number" }, comp: { type: "string" },
    vertices: { type: "array" }, feather: { type: "number" },
    inverted: { type: "boolean" }, closed: { type: "boolean" },
    mode: { type: "string" } }, ["layer", "vertices"], {});

tool("grab_frame",
  "Export the comp frame at time_s as PNG and SEE it (downscaled JPEG to "
  + "vision). Uses the undocumented saveFrameToPng — if this AE build "
  + "lacks it the error says so honestly.",
  { time_s: { type: "number" }, comp: { type: "string" } }, [],
  { readonly: true },
  async (state, a) => {
    const data = await evalHost("grab_frame", a);
    const out = { file: data.file, time_s: data.time_s, comp: data.comp };
    const img = await shrinkPng(data.file);
    if (img) out._images = [img];
    else out.note = "frame saved but could not be downscaled for vision";
    return out;
  });

tool("list_render_templates",
  "Available render-settings and output-module template names (codecs are "
  + "template-only via script).",
  { comp: { type: "string" } }, [], { readonly: true });

tool("render",
  "Render the comp: om_template/rs_template from list_render_templates, "
  + "output = absolute file path. use_ame queues in Media Encoder instead "
  + "(returns immediately); otherwise BLOCKS until done.",
  { comp: { type: "string" }, om_template: { type: "string" },
    rs_template: { type: "string" }, output: { type: "string" },
    use_ame: { type: "boolean" } }, ["output"], {});

tool("run_extendscript",
  "Escape hatch: run arbitrary ExtendScript in AE (full scripting DOM). "
  + "ES3 ONLY — var, no arrows/const/let/JSON/template strings. The last "
  + "expression's value returns (keep it small and JSON-safe).",
  { code: { type: "string" } }, ["code"], {});

// ------------------------------------------------------------ approvals
const state = { permissionMode: "Ask before edits", approveAllEdits: false,
                pendingApproval: null, onApprovalNeeded: null };

function needsApproval(name) {
  const entry = TOOLS.find((t) => t.name === name);
  const mode = state.permissionMode;
  if (mode === "Always ask") return true;
  if (mode !== "Ask before edits") return false;
  if (state.approveAllEdits) return false;
  return !(entry && entry.readonly);
}

function requestApproval(name, input) {
  return new Promise((resolveP) => {
    const pending = { name, input };
    let done = false;
    const finish = (msg) => {
      if (done) return;
      done = true; clearTimeout(timer);
      state.pendingApproval = null;
      resolveP(msg);
    };
    const timer = setTimeout(() => finish(
      "The approval request timed out after " + APPROVAL_TIMEOUT_MS / 1000
      + "s with no answer — the action was NOT performed."),
      APPROVAL_TIMEOUT_MS);
    pending.answer = (decision, guidance) => {
      if (decision === "always") { state.approveAllEdits = true; finish(null); }
      else if (decision === "run") finish(null);
      else finish("The user declined this action"
        + (guidance ? " and said: " + guidance : "") + ". Do not retry as-is.");
    };
    state.pendingApproval = pending;
    if (state.onApprovalNeeded) state.onApprovalNeeded(pending);
  });
}

async function executeTool(name, input) {
  const entry = TOOLS.find((t) => t.name === name);
  if (!entry) return { ok: false, text: "Unknown tool: " + name };
  if (needsApproval(name)) {
    const declined = await requestApproval(name, input || {});
    if (declined) return { ok: false, text: declined };
  }
  try {
    const result = await entry.fn(state, input || {});
    let images = null;
    if (result && typeof result === "object" && result._images) {
      images = result._images;
      delete result._images;
    }
    const out = { ok: true, text: JSON.stringify(result) };
    if (images) out.images = images;
    return out;
  } catch (e) {
    return { ok: false, text: e.message || String(e) };
  }
}

function toolSchemas() {
  return TOOLS.map((t) => ({ name: t.name, description: t.description,
    inputSchema: { type: "object", properties: t.params,
                   required: t.required } }));
}

// ------------------------------------------------ MCP server (in-process)
// Live launch #4 hit "No node binary found": the Resolve plugin spawns
// bridge.js under Electron-as-Node, but a CEP panel has no standalone node
// to spawn and the native claude build needs none. So the panel hosts the
// MCP endpoint itself over Streamable HTTP (a transport Claude Code speaks
// natively) using the Node 17 runtime CEP already gives us. Zero children.
const http = require("http");
const SUPPORTED = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
let bridge = null;

async function handleRpc(msg, onEvent) {
  const id = msg.id;
  try {
    if (msg.method === "initialize") {
      const req = (msg.params || {}).protocolVersion;
      return { jsonrpc: "2.0", id, result: {
        protocolVersion: SUPPORTED.indexOf(req) >= 0 ? req : "2025-06-18",
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: "ae", version: "1.0.0" } } };
    }
    if (msg.method === "ping") return { jsonrpc: "2.0", id, result: {} };
    if (msg.method === "tools/list")
      return { jsonrpc: "2.0", id, result: { tools: toolSchemas() } };
    if (msg.method === "tools/call") {
      const p = msg.params || {};
      if (typeof p.name !== "string")
        return { jsonrpc: "2.0", id, error: { code: -32602,
                 message: "Invalid params: 'name' must be a string" } };
      const args = p.arguments || {};
      if (onEvent) onEvent("call", p.name, args);
      const started = Date.now();
      const r = await executeTool(p.name, args);
      if (onEvent) onEvent("result", p.name, { ok: r.ok,
                                                ms: Date.now() - started });
      const content = [];
      for (const img of (r.images || []))
        if (img && img.data) content.push({ type: "image", data: img.data,
          mimeType: img.media_type || "image/jpeg" });
      content.push({ type: "text", text: r.text });
      return { jsonrpc: "2.0", id, result: { content, isError: !r.ok } };
    }
    return { jsonrpc: "2.0", id, error: { code: -32601,
             message: "Method not found: " + msg.method } };
  } catch (e) {
    return { jsonrpc: "2.0", id, error: { code: -32603,
             message: "Internal error: " + e.message } };
  }
}

function startBridge(onEvent) {
  const token = crypto.randomBytes(16).toString("hex");
  const server = http.createServer((req, res) => {
    const reply = (code, body) => {
      res.writeHead(code, body ? { "Content-Type": "application/json" } : {});
      res.end(body ? JSON.stringify(body) : undefined);
    };
    if (req.url !== "/mcp") return reply(404);
    if ((req.headers.authorization || "") !== "Bearer " + token)
      return reply(401);
    if (req.method === "GET") return reply(405);   // no server-push stream
    if (req.method === "DELETE") return reply(200);
    if (req.method !== "POST") return reply(405);
    let body = "";
    req.on("data", (d) => { body += d; });
    req.on("end", async () => {
      let msg;
      try { msg = JSON.parse(body); }
      catch (e) { return reply(400, { jsonrpc: "2.0", id: null,
        error: { code: -32700, message: "Parse error" } }); }
      const batch = Array.isArray(msg);
      const replies = [];
      for (const m of (batch ? msg : [msg])) {
        if (!m || m.method === undefined) continue;   // a client response
        if (!("id" in m) || m.id === null) continue;  // notification: no reply
        replies.push(await handleRpc(m, onEvent));
      }
      if (!replies.length) return reply(202);
      reply(200, batch ? replies : replies[0]);
    });
  });
  return new Promise((resolveP) => {
    server.listen(0, "127.0.0.1", () =>
      resolveP({ server, port: server.address().port, token }));
  });
}

// ------------------------------------------------------------ CLI plumbing
function findBinary(names, extraDirs) {
  const dirs = (process.env.PATH || "").split(path.delimiter)
    .concat(extraDirs || ["/opt/homebrew/bin", "/usr/local/bin",
                          path.join(os.homedir(), ".local", "bin")]);
  for (const name of names)
    for (const dir of dirs) {
      const p = path.join(dir, name);
      try { if (fs.existsSync(p)) return p; } catch (e) {}
    }
  return null;
}

function cliEnv() {
  const env = Object.assign({}, process.env);
  delete env.ANTHROPIC_API_KEY;         // silently overrides subscription auth
  delete env.ANTHROPIC_AUTH_TOKEN;
  env.PATH = [env.PATH || "", "/opt/homebrew/bin", "/usr/local/bin",
              path.join(os.homedir(), ".local", "bin")].join(path.delimiter);
  return env;
}

// ------------------------------------------------------------ chat session
let sessionId = null, busy = false, currentModel = "";
let history = historyLib.makeHistory(path.join(USER_DATA, "chats"));
let chatId = historyLib.newChatId();
let msgLog = [];
let pendingRecap = "";
const PERSISTED_KINDS = new Set(["you", "assistant", "error", "notice",
                                 "toolcall", "toolresult"]);
let uiHandler = null;

function sendUI(kind, payload, persist) {
  if (persist !== false && PERSISTED_KINDS.has(kind))
    msgLog.push({ kind, payload });
  if (uiHandler) uiHandler({ kind, payload });
}

function autosave() {
  try { history.save({ id: chatId, events: msgLog, sessionId,
                       model: currentModel }); } catch (e) {}
}

function buildTurn(workdir, model, effort) {
  fs.mkdirSync(workdir, { recursive: true });
  if (!bridge) throw new Error("The panel's MCP server is not up yet — "
                               + "try again in a second.");
  const mcpPath = path.join(workdir, "mcp.json");
  const sysPath = path.join(workdir, "system.txt");
  fs.writeFileSync(mcpPath, JSON.stringify({ mcpServers: { ae: {
    type: "http",
    url: "http://127.0.0.1:" + bridge.port + "/mcp",
    headers: { Authorization: "Bearer " + bridge.token } } } }));
  fs.writeFileSync(sysPath, SYSTEM_PROMPT);
  const argv = ["-p", "--output-format", "stream-json", "--verbose",
                "--strict-mcp-config", "--mcp-config", mcpPath,
                "--allowedTools", "mcp__ae__*", "--tools", "",
                "--append-system-prompt-file", sysPath, "--model", model];
  if (effort && model.indexOf("haiku") < 0) argv.push("--effort", effort);
  if (sessionId) argv.push("--resume", sessionId);
  return argv;
}

function handleCliEvent(event) {
  if (!event || typeof event !== "object") return;
  if (event.type === "system" && event.subtype === "init") {
    if (event.session_id) sessionId = event.session_id;
    for (const server of event.mcp_servers || [])
      if (server.name === "ae" && server.status === "failed")
        sendUI("notice", "The AE tool bridge did not connect this turn.");
    return;
  }
  if (event.type === "assistant") {
    for (const block of ((event.message || {}).content || [])) {
      if (block.type === "text" && block.text && block.text.trim())
        sendUI("assistant", block.text);
      else if (block.type === "tool_use")
        sendUI("toolcall", { name: (block.name || "").split("__").pop(),
                             input: block.input || {} });
    }
    return;
  }
  if (event.type === "result") {
    if (event.session_id) sessionId = event.session_id;
    const isErr = event.is_error
      || String(event.subtype || "").indexOf("error") === 0;
    if (!isErr) pendingRecap = "";
    if (isErr) {
      let detail = String(event.result || "").trim();
      if (!detail) detail = (event.errors || []).map(String).join("\n");
      if (detail.toLowerCase().includes("no conversation found")) {
        sessionId = null;
        sendUI("notice", "That session no longer exists — send again to "
          + "continue fresh.");
      } else sendUI("error", detail || "Claude Code reported an error.");
    }
  }
}

function runTurn(model, effort, text) {
  const binary = findBinary(["claude"]);
  if (!binary) {
    sendUI("error", "Claude Code CLI not found. Install: npm install -g "
      + "@anthropic-ai/claude-code (then sign in once with `claude`).");
    busy = false; sendUI("done", {});
    return;
  }
  const workdir = path.join(USER_DATA, "turn-" + Date.now());
  if (!sessionId && pendingRecap) text = pendingRecap + "\n\n" + text;
  let argv;
  try { argv = buildTurn(workdir, model, effort); }
  catch (e) { sendUI("error", e.message); busy = false;
              sendUI("done", {}); return; }
  const child = spawn(binary, argv, { env: cliEnv(), cwd: USER_DATA });
  child.stdin.write(text + "\n");
  child.stdin.end();
  let carry = "", stderrText = "";
  const stray = [];
  child.stdout.on("data", (chunk) => {
    carry += chunk.toString("utf8");
    let idx;
    while ((idx = carry.indexOf("\n")) >= 0) {
      const line = carry.slice(0, idx).trim(); carry = carry.slice(idx + 1);
      if (!line) continue;
      try { handleCliEvent(JSON.parse(line)); }
      catch (e) { stray.push(line); }
    }
  });
  child.stderr.on("data", (d) => { stderrText += d.toString("utf8"); });
  child.on("error", (e) => {
    sendUI("error", "Could not run the claude CLI: " + e.message);
    busy = false; sendUI("done", {}); });
  child.on("close", (code) => {
    try { fs.rmSync(workdir, { recursive: true, force: true }); } catch (e) {}
    if (code !== 0 && stderrText) {
      const low = (stderrText + stray.join("\n")).toLowerCase();
      if (low.includes("no conversation found")) {
        sessionId = null;
        sendUI("notice", "That session no longer exists — send again to "
          + "continue fresh.");
      } else sendUI("error", "Claude Code exited with status " + code + "\n"
        + (stderrText || stray.join("\n")).slice(0, 1200));
    }
    busy = false; sendUI("done", {});
    autosave();
  });
}

// -------------------------------------------------- assistant API (app.js)
window.assistant = {
  send({ text, model, effort, permissionMode }) {
    if (busy || !text || !String(text).trim()) return false;
    if (PERMISSION_MODES.includes(permissionMode))
      state.permissionMode = permissionMode;
    currentModel = model;
    busy = true;
    sendUI("you", String(text).trim());
    runTurn(MODELS.includes(model) ? model : MODELS[0],
            EFFORTS.includes(effort) ? effort : "medium",
            String(text).trim());
    return true;
  },
  approval(decision, guidance) {
    if (state.pendingApproval) state.pendingApproval.answer(decision, guidance);
  },
  newChat() {
    autosave();
    sessionId = null; pendingRecap = "";
    chatId = historyLib.newChatId(); msgLog = [];
  },
  config() {
    return Promise.resolve({ models: MODELS, efforts: EFFORTS,
                             modes: PERMISSION_MODES });
  },
  history(action, id) {
    if (action === "list") return Promise.resolve(history.list());
    if (action === "delete") {
      history.remove(id);
      if (id === chatId) { chatId = historyLib.newChatId(); msgLog = [];
                           sessionId = null; }
      return Promise.resolve(true);
    }
    if (action === "open") {
      if (busy) return Promise.resolve({ busy: true });
      if (id === chatId) return Promise.resolve({ current: true });
      const data = history.load(id);
      if (!data) return Promise.resolve(null);
      autosave();
      chatId = id; msgLog = data.events || [];
      sessionId = data.sessionId || null;
      pendingRecap = sessionId ? "" : historyLib.buildRecap(msgLog);
      return Promise.resolve({ events: msgLog, model: data.model,
                               title: data.title });
    }
    return Promise.resolve(null);
  },
  onEvent(handler) { uiHandler = handler; },
  // The system clipboard via the OS tool: CEF's own copy path is not
  // reliable inside a CEP panel, and a Node child process always is.
  // Exposed only when the tool exists, so app.js knows to fall back.
  clipboard: !findBinary(process.platform === "darwin" ? ["pbcopy"]
      : process.platform === "win32" ? ["powershell.exe", "powershell"]
      : ["xclip"], []) ? null : {
    write(text) {
      return new Promise((resolve, reject) => {
        const cmd = process.platform === "darwin" ? ["pbcopy", []]
          : process.platform === "win32"
            ? ["powershell", ["-NoProfile", "-Command",
               "[Console]::InputEncoding=[Text.Encoding]::UTF8; " +
               "Set-Clipboard -Value ([Console]::In.ReadToEnd())"]]
            : ["xclip", ["-selection", "clipboard"]];
        const p = spawn(cmd[0], cmd[1], { stdio: ["pipe", "ignore", "ignore"] });
        p.on("error", reject);
        p.on("close", (code) => code === 0 ? resolve(true)
          : reject(new Error(cmd[0] + " exited " + code)));
        p.stdin.on("error", () => {});
        p.stdin.end(String(text), "utf8");
      });
    },
    read() {
      return new Promise((resolve, reject) => {
        const cmd = process.platform === "darwin" ? ["pbpaste", []]
          : process.platform === "win32"
            ? ["powershell", ["-NoProfile", "-Command",
               "[Console]::OutputEncoding=[Text.Encoding]::UTF8; " +
               "Get-Clipboard -Raw"]]
            : ["xclip", ["-selection", "clipboard", "-o"]];
        execFile(cmd[0], cmd[1], { encoding: "utf8", maxBuffer: 64 << 20 },
          (err, out) => err ? reject(err) : resolve(out));
      });
    },
  },
};

state.onApprovalNeeded = (pending) =>
  sendUI("approval", { name: pending.name, input: pending.input });

startBridge((kind, name, payload) => {
  if (kind === "result")
    sendUI("toolresult", { name, ok: payload.ok, ms: payload.ms });
}).then((b) => { bridge = b; });

})();
