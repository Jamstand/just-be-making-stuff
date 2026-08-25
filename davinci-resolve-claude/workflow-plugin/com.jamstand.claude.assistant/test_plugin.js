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
function fakeResolve() {
  const markers = {};
  const timeline = {
    GetName: () => "Timeline 1",
    GetSetting: (k) => (k === "timelineFrameRate" ? "24" : ""),
    GetCurrentTimecode: () => "01:00:00:00",
    SetCurrentTimecode: (tc) => tc !== "bad",
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
  const root = { GetName: () => "Master",
                 GetClipList: () => clips, GetSubFolderList: () => [] };
  const mediaPool = {
    GetRootFolder: () => root,
    AppendToTimeline: (items) => items.map(() => ({})),
    ImportMedia: (paths) => paths.map((p) => ({ GetName: () => path.basename(p) })),
    AddSubFolder: (parent, name) => ({ GetName: () => name }),
  };
  const project = {
    GetName: () => "Demo",
    GetCurrentTimeline: () => timeline,
    GetMediaPool: () => mediaPool,
    GetTimelineCount: () => 1,
    GetTimelineByIndex: () => timeline,
    SetCurrentTimeline: () => true,
    GetRenderPresetList: () => ["YouTube 1080p"],
    IsRenderingInProgress: () => false,
    GetRenderJobList: () => [],
  };
  return {
    GetProjectManager: () => ({ GetCurrentProject: () => project }),
    GetCurrentPage: () => "edit",
    OpenPage: (p) => ["media", "cut", "edit", "fusion", "color",
                      "fairlight", "deliver"].includes(p),
    _markers: markers,
  };
}

async function main() {
  const resolve = fakeResolve();
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

  // -- bridge round trip through the real bridge.js child ----------------
  state.permissionMode = "Never ask";
  const bridge = await tools.startBridge(state, () => {});
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
  await new Promise((res) => setTimeout(res, 700));
  child.kill();
  bridge.server.close();

  check("mcp replies: no reply to the notification", replies.length === 3,
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

  console.log(failures ? "\n" + failures + " FAILURES"
                       : "\nALL PLUGIN CHECKS PASSED (" +
                         tools.TOOLS.length + " JS tools)");
  process.exit(failures ? 1 : 0);
}

main().catch((err) => { console.error(err); process.exit(1); });
