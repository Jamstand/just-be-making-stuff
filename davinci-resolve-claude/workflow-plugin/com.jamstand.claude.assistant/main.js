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
const { app, BrowserWindow, ipcMain } = require("electron");
const { spawn } = require("child_process");
const path = require("path");
const fs = require("fs");
const os = require("os");
const tools = require("./tools");

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

function log(msg) { console.error("[claude-assistant] " + msg); }

function loadWorkflowIntegration() {
  // The installer copies the platform build from Resolve's own SamplePlugin
  // folder; the name must stay exactly WorkflowIntegration.node.
  return require(path.join(__dirname, "WorkflowIntegration.node"));
}

function sendUI(kind, payload) {
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
  return env;
}

const SYSTEM_PROMPT = [
  "You drive DaVinci Resolve for a video editor through the mcp__resolve__*",
  "tools. Use run_javascript only when no dedicated tool fits; the API there",
  "is Resolve's documented scripting API (resolve/project/timeline/mediaPool).",
  "Hard limits of Resolve's API — say so instead of guessing: no Color-page",
  "node creation, power windows, qualifiers, tracker, or grade readback;",
  "no in-place trim/razor/move of existing clips; no audio mixing.",
  "The panel may pause a modifying tool call for the user's approval. If a",
  "result says the user declined or it timed out, never retry it unchanged;",
  "fold their guidance into what you do next.",
  "Be concise: editors are mid-task. Lead with the result.",
].join(" ");

function buildTurn(workdir, model, effort, prompt) {
  fs.mkdirSync(workdir, { recursive: true });
  const mcpPath = path.join(workdir, "mcp.json");
  const sysPath = path.join(workdir, "system.txt");
  // "node" is always on PATH wherever the claude CLI works (the CLI itself
  // runs on it) — never point this at Electron's own execPath.
  fs.writeFileSync(mcpPath, JSON.stringify({
    mcpServers: { resolve: { command: "node",
                             args: [path.join(__dirname, "bridge.js")] } },
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
  try { if (bridge) bridge.server.close(); } catch (e) {}
  try { if (wi) wi.CleanUp(); } catch (e) {}
  try { if (win && !win.isDestroyed()) win.destroy(); } catch (e) {}
  app.quit();
}

app.whenReady().then(async () => {
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
    bridge = await tools.startBridge(state, (kind, name, input) => {
      // tool activity flows to the transcript as it happens
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
});

app.on("window-all-closed", () => shutdown());

// ------------------------------------------------------------------ IPC
ipcMain.handle("send", (evt, { text, model, effort, permissionMode }) => {
  if (busy || !text || !String(text).trim()) return false;
  if (state && tools.PERMISSION_MODES.includes(permissionMode))
    state.permissionMode = permissionMode;
  busy = true;
  sendUI("you", String(text).trim());
  runTurn(MODELS.includes(model) ? model : MODELS[0],
          EFFORTS.includes(effort) ? effort : "medium", String(text).trim());
  return true;
});

ipcMain.handle("approval", (evt, { decision, guidance }) => {
  if (state && state.pendingApproval)
    state.pendingApproval.answer(decision, guidance || "");
  return true;
});

ipcMain.handle("newchat", () => {
  sessionId = null;
  if (state) state.approveAllEdits = false;
  return true;
});

ipcMain.handle("config", () => ({ models: MODELS, efforts: EFFORTS,
                                  modes: tools.PERMISSION_MODES }));
