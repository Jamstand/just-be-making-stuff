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
  const grabState = { calls: 0, exported: [], deleted: [], pages: [],
                      timecodes: [] };
  const album = {
    ExportStills: (stills, dir, prefix, fmt) => {
      // Real Resolve: unpredictable filename + a .drx sidecar.
      const png = path.join(dir, prefix + "_1.20260827.png");
      fsmod.writeFileSync(png, Buffer.from("89504e470d0a1a0a0011", "hex"));
      fsmod.writeFileSync(path.join(dir, prefix + "_1.drx"), "sidecar");
      grabState.exported.push(png);
      return true;
    },
    DeleteStills: (stills) => { grabState.deleted.push(stills); return true; },
  };
  const timeline = {
    GetName: () => "Timeline 1",
    GetSetting: (k) => (k === "timelineFrameRate" ? "24" : ""),
    GetCurrentTimecode: () => "01:00:00:00",
    SetCurrentTimecode: (tc) => { grabState.timecodes.push(tc); return tc !== "bad"; },
    GrabStill: () => {                    // intermittently falsy, like life
      grabState.calls += 1;
      return grabState.calls < 2 ? null : { still: true };
    },
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

  console.log(failures ? "\n" + failures + " FAILURES"
                       : "\nALL PLUGIN CHECKS PASSED (" +
                         tools.TOOLS.length + " JS tools)");
  process.exit(failures ? 1 : 0);
}

main().catch((err) => { console.error(err); process.exit(1); });
