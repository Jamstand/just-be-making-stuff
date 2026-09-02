// Claude Assistant — DaVinci Resolve Workflow Integration (Electron main).
//
// Resolve launches this with its own bundled Electron when the user clicks
// Workspace > Workflow Integrations > Claude Assistant. Architecture:
//
//   renderer (HTML chat UI) <-IPC-> main (this file)
//       main: WorkflowIntegration.node -> live Resolve object
//             tools.js                 -> JS tools + loopback bridge server
//             claude CLI (-p, stream-json) spawned per turn; its MCP server
//             is bridge.js, which forwards tool calls back over TCP.
//
// Hard-won rules honoured here (from the sibling Python plugin):
// - ANTHROPIC_API_KEY silently overrides subscription auth: strip it.
// - The CLI keys its session store to cwd: pin cwd to a stable dir.
// - Prompt goes via STDIN and configs via files, never the command line.
// - On quit: CleanUp() + destroy the window, or an orphaned electron.exe
//   keeps WorkflowIntegration.node locked on Windows.

"use strict";
const { app, BrowserWindow, ipcMain, clipboard } = require("electron");
const { spawn } = require("child_process");
const path = require("path");
const fs = require("fs");
const os = require("os");
const tools = require("./tools");
const historyLib = require("./history");

const PLUGIN_ID = "com.jamstand.claude.assistant";
const MODELS = ["claude-opus-5", "claude-fable-5", "claude-sonnet-5",
                "claude-haiku-4-5"];
const EFFORTS = ["low", "medium", "high", "xhigh", "max"];

let win = null;
let wi = null;                 // WorkflowIntegration.node module
let state = null;              // tools.js state (resolve handle, approvals)
let bridge = null;             // {server, port, token}
let sessionId = null;          // claude CLI session for --resume
let busy = false;
let history = null;            // historyLib.makeHistory(userData/chats)
let chatId = historyLib.newChatId();
let msgLog = [];               // persisted {kind, payload} transcript events
let pendingRecap = "";         // injected once when a saved session is gone
let currentModel = "";
const PERSISTED_KINDS = new Set(["you", "assistant", "error", "notice",
                                 "toolcall", "toolresult"]);

function autosave() {
  try {
    if (history) history.save({ id: chatId, events: msgLog,
                                sessionId, model: currentModel });
  } catch (e) { log("autosave failed: " + e.message); }
}

function log(msg) { console.error("[claude-assistant] " + msg); }

function loadWorkflowIntegration() {
  // The installer copies the platform build from Resolve's own SamplePlugin
  // folder; the name must stay exactly WorkflowIntegration.node.
  return require(path.join(__dirname, "WorkflowIntegration.node"));
}

function sendUI(kind, payload, persist) {
  if (persist !== false && PERSISTED_KINDS.has(kind))
    msgLog.push({ kind, payload });
  if (win && !win.isDestroyed()) win.webContents.send("event", { kind, payload });
}

// ------------------------------------------------------------- CLI plumbing
function findClaudeBinary() {
  const exe = process.platform === "win32" ? "claude.cmd" : "claude";
  const candidates = [];
  for (const dir of (process.env.PATH || "").split(path.delimiter))
    candidates.push(path.join(dir, exe));
  if (process.platform === "win32") {
    candidates.push(path.join(process.env.APPDATA || "", "npm", "claude.cmd"));
  } else {
    candidates.push("/usr/local/bin/claude", "/opt/homebrew/bin/claude",
                    path.join(os.homedir(), ".local", "bin", "claude"));
  }
  return candidates.find((c) => { try { return fs.existsSync(c); } catch (e) { return false; } });
}

function cliEnv() {
  const env = Object.assign({}, process.env);
  delete env.ANTHROPIC_API_KEY;      // would silently bill API credits
  delete env.ANTHROPIC_AUTH_TOKEN;
  env.CLAUDE_RESOLVE_BRIDGE_PORT = String(bridge.port);
  env.CLAUDE_RESOLVE_BRIDGE_TOKEN = bridge.token;
  // GUI-launched processes get a minimal PATH on macOS; give the CLI the
  // places node/npm actually live so its own spawns can work too.
  if (process.platform !== "win32") {
    env.PATH = [env.PATH || "", "/opt/homebrew/bin", "/usr/local/bin",
                path.join(os.homedir(), ".local", "bin")].join(path.delimiter);
  }
  return env;
}

const SYSTEM_PROMPT = [
  "You drive DaVinci Resolve for a video editor through the mcp__resolve__*",
  "tools. Use run_javascript only when no dedicated tool fits; the API there",
  "is Resolve's documented scripting API (resolve/project/timeline/mediaPool).",
  "Hard limits of Resolve's API — state them up front instead of guessing:",
  "masking and tracking cannot be done. The scripting API exposes no power",
  "windows, no qualifiers, and no tracker — there is no route to draw a",
  "mask on the Color page or track it across frames. Also: no direct",
  "Color-page node creation (grade_template stamps layouts via .drx), no",
  "grade readback, no in-place trim/razor/move, no audio mixing. Working",
  "substitutes that DO exist: per-frame luminance/chroma keying and static",
  "masks via the Fusion comp.Execute route (apply_vignette).",
  "The panel may pause a modifying tool call for the user's approval. If a",
  "result says the user declined or it timed out, never retry it unchanged;",
  "fold their guidance into what you do next.",
  "Be concise: editors are mid-task. Lead with the result.",
].join(" ");

function buildTurn(workdir, model, effort, prompt) {
  fs.mkdirSync(workdir, { recursive: true });
  const mcpPath = path.join(workdir, "mcp.json");
  const sysPath = path.join(workdir, "system.txt");
  // Resolve launches this plugin with the bare GUI PATH (no /opt/homebrew/bin
  // on macOS), so "node" may not resolve for the CLI's MCP spawn. Electron
  // itself IS node when ELECTRON_RUN_AS_NODE=1 — fully self-contained.
  fs.writeFileSync(mcpPath, JSON.stringify({
    mcpServers: { resolve: {
      command: process.execPath,
      args: [path.join(__dirname, "bridge.js")],
      env: { ELECTRON_RUN_AS_NODE: "1",
             CLAUDE_RESOLVE_BRIDGE_PORT: String(bridge.port),
             CLAUDE_RESOLVE_BRIDGE_TOKEN: bridge.token } } },
  }));
  fs.writeFileSync(sysPath, SYSTEM_PROMPT);
  const argv = ["-p", "--output-format", "stream-json", "--verbose",
                "--strict-mcp-config", "--mcp-config", mcpPath,
                "--allowedTools", "mcp__resolve__*", "--tools", "",
                "--append-system-prompt-file", sysPath,
                "--model", model];
  if (effort && model.indexOf("haiku") < 0) argv.push("--effort", effort);
  if (sessionId) argv.push("--resume", sessionId);
  return { argv, prompt };
}

function runTurn(model, effort, text) {
  const binary = findClaudeBinary();
  if (!binary) {
    sendUI("error", "Claude Code CLI not found. Install it with: npm install -g @anthropic-ai/claude-code");
    sendUI("done", {});
    return;
  }
  const workdir = path.join(app.getPath("userData"), "turn-" + Date.now());
  if (!sessionId && pendingRecap) {
    // Reopened chat whose CLI session is gone: rebuild context from the
    // saved transcript instead. Cleared once a turn succeeds.
    text = pendingRecap + "\n\n" + text;
  }
  const { argv, prompt } = buildTurn(workdir, model, effort, text);
  // Stable cwd so CLI sessions survive Resolve restarts (session store is
  // keyed to the working directory).
  const opts = { env: cliEnv(), cwd: app.getPath("userData") };
  let child;
  if (process.platform === "win32" && binary.endsWith(".cmd")) {
    child = spawn("cmd.exe", ["/d", "/s", "/c", binary].concat(argv), opts);
  } else {
    child = spawn(binary, argv, opts);
  }
  child.stdin.write(prompt + "\n");
  child.stdin.end();
  let carry = "";
  const stray = [];
  child.stdout.on("data", (chunk) => {
    carry += chunk.toString("utf8");
    let idx;
    while ((idx = carry.indexOf("\n")) >= 0) {
      const line = carry.slice(0, idx).trim(); carry = carry.slice(idx + 1);
      if (!line) continue;
      let event;
      try { event = JSON.parse(line); } catch (e) { stray.push(line); continue; }
      handleCliEvent(event);
    }
  });
  let stderrText = "";
  child.stderr.on("data", (d) => { stderrText += d.toString("utf8"); });
  child.on("close", (code) => {
    try { fs.rmSync(workdir, { recursive: true, force: true }); } catch (e) {}
    if (code !== 0 && stderrText) {
      const low = (stderrText + stray.join("\n")).toLowerCase();
      if (low.includes("no conversation found")) {
        sessionId = null;
        sendUI("notice", "That session no longer exists — send again to continue fresh.");
      } else {
        sendUI("error", "Claude Code exited with status " + code + "\n" +
               (stderrText || stray.join("\n")).slice(0, 1200));
      }
    }
    busy = false;
    sendUI("done", {});
    autosave();                          // chats save after every turn
  });
}

function handleCliEvent(event) {
  if (!event || typeof event !== "object") return;
  if (event.type === "system" && event.subtype === "init") {
    if (event.session_id) sessionId = event.session_id;
    for (const server of event.mcp_servers || [])
      if (server.name === "resolve" && server.status === "failed")
        sendUI("notice", "The Resolve tool bridge did not connect this turn.");
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
    if (!event.is_error && String(event.subtype || "").indexOf("error") !== 0)
      pendingRecap = "";                 // context re-established server-side
    if (event.is_error || String(event.subtype || "").indexOf("error") === 0) {
      let detail = String(event.result || "").trim();
      if (!detail) detail = (event.errors || []).map(String).join("\n");
      const low = detail.toLowerCase();
      if (low.includes("no conversation found")) {
        sessionId = null;
        sendUI("notice", "That session no longer exists — send again to continue fresh.");
      } else {
        sendUI("error", detail || "Claude Code reported an error.");
      }
    }
  }
}

// ---------------------------------------------------------------- lifecycle
function shutdown() {
  try { autosave(); } catch (e) {}
  try { if (bridge) bridge.server.close(); } catch (e) {}
  try { if (wi) wi.CleanUp(); } catch (e) {}
  try { if (win && !win.isDestroyed()) win.destroy(); } catch (e) {}
  app.quit();
}

// ---------------------------------------------------------- self-update
// On launch: pull the repo, copy the plugin over this install, relaunch
// once so the NEW code actually runs. Every step is best-effort — a dead
// network, missing repo, wrong branch, or read-only install must never
// stop the panel from opening. Opt out by creating a file named
// ".auto-update-off" next to this main.js.
const REPO_DIR = path.join(os.homedir(), "just-be-making-stuff");
const REPO_BRANCH = "claude/davinci-resolve-claude-plugin-bw69a6";
const REPO_PLUGIN = path.join(REPO_DIR, "davinci-resolve-claude",
                              "workflow-plugin", PLUGIN_ID);

function run(cmd, args, opts) {
  return new Promise((res) => {
    let out = "", err = "";
    let child;
    try { child = spawn(cmd, args, Object.assign({ stdio:
      ["ignore", "pipe", "pipe"] }, opts || {})); }
    catch (e) { return res({ code: -1, out: "", err: e.message }); }
    child.stdout.on("data", (d) => { out += d; });
    child.stderr.on("data", (d) => { err += d; });
    const t = setTimeout(() => { try { child.kill(); } catch (e) {} },
                         30000);
    child.on("error", (e) => { clearTimeout(t);
                               res({ code: -1, out, err: e.message }); });
    child.on("close", (code) => { clearTimeout(t);
                                  res({ code, out, err }); });
  });
}

function copyTree(from, to) {
  // Contents-over-install copy: never deletes (WorkflowIntegration.node
  // lives in the install and is not in the repo).
  for (const name of fs.readdirSync(from)) {
    const src = path.join(from, name), dst = path.join(to, name);
    if (fs.statSync(src).isDirectory()) {
      fs.mkdirSync(dst, { recursive: true });
      copyTree(src, dst);
    } else fs.copyFileSync(src, dst);
  }
}

async function selfUpdate() {
  if (process.env.CLAUDE_ASSISTANT_RELAUNCHED === "1")
    return "updated — running the new code";
  if (fs.existsSync(path.join(__dirname, ".auto-update-off"))) return null;
  if (!fs.existsSync(path.join(REPO_DIR, ".git"))) return null;
  const git = fs.existsSync("/usr/bin/git") ? "/usr/bin/git" : "git";
  const at = (args) => run(git, ["-C", REPO_DIR].concat(args));
  const branch = (await at(["branch", "--show-current"])).out.trim();
  if (branch !== REPO_BRANCH)
    return "auto-update skipped: repo is on branch '" + branch + "'";
  const before = (await at(["rev-parse", "HEAD"])).out.trim();
  const pull = await at(["pull", "--ff-only"]);
  if (pull.code !== 0)
    return "auto-update skipped: git pull failed (" +
           pull.err.trim().slice(0, 120) + ")";
  const after = (await at(["rev-parse", "HEAD"])).out.trim();
  if (!before || after === before) return null;   // already current
  try {
    fs.accessSync(__dirname, fs.constants.W_OK);
    copyTree(REPO_PLUGIN, __dirname);
  } catch (e) {
    return "update fetched but this folder is not writable — "
      + (process.platform === "win32"
         ? "grant your user write access to " + __dirname
         : "run once: sudo chown -R $USER \"" + __dirname + "\"");
  }
  app.relaunch({ env: Object.assign({}, process.env,
                                    { CLAUDE_ASSISTANT_RELAUNCHED: "1" }) });
  app.exit(0);
  return "relaunching";
}

app.whenReady().then(async () => {
  let updateNote = null;
  try { updateNote = await selfUpdate(); } catch (e) {
    updateNote = "auto-update error: " + e.message;
  }
  history = historyLib.makeHistory(path.join(app.getPath("userData"), "chats"));
  try {
    wi = loadWorkflowIntegration();
    const ok = wi.Initialize(PLUGIN_ID);
    if (!ok) throw new Error("WorkflowIntegration.Initialize returned false");
    wi.SetAPITimeout(120);              // Resolve modal dialogs block API calls
    wi.RegisterCallback("ResolveQuit", () => shutdown());
    const resolve = wi.GetResolve();
    if (!resolve) throw new Error("GetResolve() returned null");
    state = tools.makeState(resolve);
  } catch (err) {
    log("Resolve init failed: " + err.message);
    // Still open the window so the failure is visible, not a silent no-show.
  }

  if (state) {
    bridge = await tools.startBridge(state, (kind, name, payload) => {
      if (kind === "result") sendUI("toolresult", { name, ok: payload.ok,
                                                    ms: payload.ms });
    });
    state.onApprovalNeeded = (pending) =>
      sendUI("approval", { name: pending.name, input: pending.input });
  }

  win = new BrowserWindow({
    width: 900, height: 720,
    title: "Claude Assistant — DaVinci Resolve",
    backgroundColor: "#1e1e22",
    webPreferences: { preload: path.join(__dirname, "preload.js"),
                      sandbox: true, contextIsolation: true },
  });
  win.setMenuBarVisibility(false);
  win.loadFile(path.join(__dirname, "renderer", "index.html"));
  win.on("closed", () => shutdown());

  if (!state)
    win.webContents.once("did-finish-load", () =>
      sendUI("error", "Could not connect to Resolve. Was this launched from " +
             "Workspace > Workflow Integrations inside Resolve Studio?"));
  if (updateNote)
    win.webContents.once("did-finish-load", () =>
      sendUI("notice", "Auto-update: " + updateNote));
});

app.on("window-all-closed", () => shutdown());

// ------------------------------------------------------------------ IPC
ipcMain.handle("send", (evt, { text, model, effort, permissionMode }) => {
  if (busy || !text || !String(text).trim()) return false;
  if (state && tools.PERMISSION_MODES.includes(permissionMode))
    state.permissionMode = permissionMode;
  currentModel = model;
  busy = true;
  sendUI("you", String(text).trim());
  // Slash commands expand into full instructions; the transcript keeps
  // what the user typed.
  const prompt = tools.expandSlash(text) || String(text).trim();
  runTurn(MODELS.includes(model) ? model : MODELS[0],
          EFFORTS.includes(effort) ? effort : "medium", prompt);
  return true;
});

ipcMain.handle("approval", (evt, { decision, guidance }) => {
  if (state && state.pendingApproval)
    state.pendingApproval.answer(decision, guidance || "");
  return true;
});

ipcMain.handle("newchat", () => {
  autosave();                            // archive the outgoing conversation
  chatId = historyLib.newChatId();
  msgLog = [];
  sessionId = null;
  pendingRecap = "";
  if (state) state.approveAllEdits = false;
  return true;
});

ipcMain.handle("history", (evt, { action, id }) => {
  if (!history) return null;
  if (action === "list") return history.list();
  if (action === "delete") {
    history.remove(id);
    if (id === chatId)
      chatId = historyLib.newChatId();   // or autosave resurrects the file
    return history.list();
  }
  if (action === "open") {
    if (busy) return { busy: true };
    if (id === chatId) return { current: true };
    autosave();                          // keep the chat we're leaving
    const data = history.load(id);
    if (!data) return null;
    chatId = data.id;
    msgLog = data.events || [];
    sessionId = data.sessionId || null;
    pendingRecap = historyLib.buildRecap(msgLog);
    if (data.model) currentModel = data.model;
    return { events: msgLog, model: data.model || null,
             title: data.title || "chat" };
  }
  return null;
});

ipcMain.handle("config", () => ({ models: MODELS, efforts: EFFORTS,
                                  modes: tools.PERMISSION_MODES }));

// The renderer is sandboxed, so the system clipboard lives here.
ipcMain.handle("clipboard", (evt, { op, text }) => {
  if (op === "write") { clipboard.writeText(String(text)); return true; }
  return clipboard.readText();
});
