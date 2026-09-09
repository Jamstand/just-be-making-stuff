// Drives the REAL AE panel (real panel.js + Node, real app.js, real DOM) in
// Electron under xvfb, with a fake claude CLI speaking real MCP-over-HTTP
// back to the panel. Every observation is a pixel or DOM read of the
// running panel.
// Needs: npm i playwright electron (PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1) in
// after-effects-claude/, then: xvfb-run -a node verify-electron/drive.js
const { _electron } = require("playwright");
const path = require("path"), fs = require("fs"), os = require("os");
const EXT = path.join(__dirname, "..", "com.jamstand.claude.ae");
const HOME = fs.mkdtempSync(path.join(os.tmpdir(), "ae-el-home-"));
// Point the tracking bridge at the fake Mocha python (file-backed exports).
fs.writeFileSync(path.join(HOME, ".claude-assistant.json"),
  JSON.stringify({ mocha_python: path.join(__dirname, "fakebin", "mocha-python3") }));
const shots = [];
const shot = async (page, name) => { const p = path.join(__dirname, "shot-" + name + ".png"); await page.screenshot({ path: p }); shots.push(p); console.log("  [shot] " + name); };
const cards = (page) => page.evaluate(() => [...document.querySelectorAll("#chat .card, #chat .toolline")]
  .map((c) => (c.classList.contains("toolline") ? "TOOL " : "") + c.className.replace("card ", "") + " | " + c.textContent.replace(/\s+/g, " ").trim().slice(0, 120)));
const status = (page) => page.evaluate(() => document.getElementById("status").textContent);
// Full card text (cards() truncates at 120 chars): [{cls, text}]
const fullCards = (page) => page.evaluate(() => [...document.querySelectorAll("#chat .card")]
  .map((c) => ({ cls: c.className.replace("card ", ""), text: c.textContent.replace(/\s+/g, " ").trim() })));

(async () => {
  const app = await _electron.launch({
    executablePath: require("electron"),
    args: ["--no-sandbox", "--no-zygote", path.join(__dirname, "main.js")],
    env: Object.assign({}, process.env, { AE_EXT: EXT, HOME,
      PATH: path.join(__dirname, "fakebin") + ":" + process.env.PATH }) });
  app.process().stderr.on("data", (d) => { const t = String(d); if (/GONE|FATAL|crash/i.test(t)) console.log("  [electron stderr] " + t.trim()); });
  const page = await app.firstWindow();
  page.on("pageerror", (e) => console.log("  [pageerror] " + e.message));
  page.on("console", (m) => { if (m.type() === "error") console.log("  [console.error] " + m.text()); });

  console.log("### 1. startup");
  await page.waitForFunction(() => document.querySelector("#chat .card.notice"), null, { timeout: 8000 });
  console.log(JSON.stringify({ model: await page.$eval("#model", (s) => [...s.options].map((o) => o.value)),
    effort: await page.$eval("#effort", (s) => s.value), mode: await page.$eval("#mode", (s) => s.value),
    cards: await cards(page), status: await status(page) }, null, 1));
  await shot(page, "1-connected");

  console.log("### 1b. 🔍 can this renderer spawn a child at all?");
  try { console.log("  spawnSync('true') ->", await page.evaluate(() => { const r = require("child_process").spawnSync("true"); return "status " + r.status; })); }
  catch (e) { console.log("  spawn probe FAILED: " + e.message); }
  console.log("### 2. send 'hello' -> fake CLI runs get_project_overview then create_comp (write -> approval card)");
  await page.fill("#input", "hello");
  await page.press("#input", "Enter");
  await page.waitForFunction(() => !document.getElementById("approval").hidden, null, { timeout: 8000 });
  console.log(JSON.stringify({ approval_title: await page.$eval("#ap-title", (e) => e.textContent),
    approval_detail: await page.$eval("#ap-detail", (e) => e.textContent.slice(0, 120)),
    status: await status(page), placeholder: await page.$eval("#input", (i) => i.placeholder) }, null, 1));
  await shot(page, "2-approval-card");

  console.log("### 3. click 'Yes, run it'");
  await page.click("#ap-run");
  await page.waitForFunction(() => document.getElementById("status").textContent.startsWith("Ready"), null, { timeout: 8000 });
  console.log(JSON.stringify({ cards: await cards(page), status: await status(page),
    approval_hidden: await page.$eval("#approval", (e) => e.hidden) }, null, 1));
  await shot(page, "3-turn-complete");

  console.log("### 3b. Copy button on the CLAUDE card -> system clipboard (fake xclip in fakebin = pbcopy stand-in)");
  const clipFile = path.join(HOME, "clip.txt");
  const readClip = () => fs.existsSync(clipFile) ? fs.readFileSync(clipFile, "utf8") : "(no clipboard write)";
  await page.hover("#chat .card.claude:last-of-type");
  await page.click("#chat .card.claude:last-of-type .copybtn");
  await page.waitForFunction(() => document.querySelector("#chat .card.claude:last-of-type .copybtn").textContent !== "Copy", null, { timeout: 4000 });
  console.log(JSON.stringify({ button: await page.$eval("#chat .card.claude:last-of-type .copybtn", (b) => b.textContent),
    clipboard: readClip(), route: await page.evaluate(() => !!(window.assistant.clipboard && window.assistant.clipboard.write)) }, null, 1));
  await shot(page, "3b-copy-button");
  await page.waitForTimeout(1600);
  console.log("  label restored: " + await page.$eval("#chat .card.claude:last-of-type .copybtn", (b) => b.textContent));

  console.log("### 3c. 🔍 drag-select text in a card, press Ctrl/⌘+C -> handled by the panel, not the host");
  fs.writeFileSync(clipFile, "STALE");
  await page.evaluate(() => { const p = document.querySelector("#chat .card.claude:last-of-type .prose"); const s = window.getSelection(); s.removeAllRanges(); s.selectAllChildren(p); });
  await page.keyboard.press("Control+c");
  await page.waitForTimeout(400);
  console.log(JSON.stringify({ selection: await page.evaluate(() => String(window.getSelection())), clipboard: readClip() }, null, 1));

  console.log("### 3d. 🔍 Copy chat -> whole transcript");
  await page.click("#copychat");
  await page.waitForTimeout(400);
  console.log(JSON.stringify({ button: await page.$eval("#copychat", (b) => b.textContent), clipboard: readClip() }, null, 1));
  await shot(page, "3d-copy-chat");

  console.log("### 3e. 🔍 paste into the input with Ctrl/⌘+V (reads through xclip -o)");
  fs.writeFileSync(clipFile, "speed-ramp layer 2 into the drop");
  await page.click("#input"); await page.fill("#input", "please ");
  await page.keyboard.press("Control+v");
  await page.waitForTimeout(400);
  console.log(JSON.stringify({ input: await page.$eval("#input", (i) => i.value) }, null, 1));
  await page.fill("#input", "");

  console.log("### 3f. 🔍 native route dies (pbcopy missing) -> browser fallback still copies");
  await page.evaluate(() => { window.__origClipWrite = window.assistant.clipboard.write;
    window.assistant.clipboard.write = () => Promise.reject(new Error("no pbcopy")); });
  await page.click("#chat .card.you .copybtn");
  await page.waitForTimeout(400);
  console.log(JSON.stringify({ button: await page.$eval("#chat .card.you .copybtn", (b) => b.textContent),
    electron_clipboard: await app.evaluate(({ clipboard }) => clipboard.readText()) }, null, 1));
  await page.evaluate(() => { window.assistant.clipboard.write = window.__origClipWrite; });
  await page.waitForTimeout(1600);

  console.log("### 4. 🔍 second turn, DECLINE via Escape");
  await page.fill("#input", "make another one");
  await page.press("#input", "Enter");
  await page.waitForFunction(() => !document.getElementById("approval").hidden, null, { timeout: 8000 });
  await page.keyboard.press("Escape");
  await page.waitForFunction(() => document.getElementById("status").textContent.startsWith("Ready"), null, { timeout: 8000 });
  const after = await cards(page);
  console.log(JSON.stringify({ last_cards: after.slice(-4) }, null, 1));
  await shot(page, "4-declined");

  console.log("### 5. 🔍 History panel (autosave after turns) + New chat");
  await page.click("#historybtn");
  await page.waitForTimeout(300);
  console.log(JSON.stringify({ hist_hidden: await page.$eval("#histpanel", (e) => e.hidden),
    rows: await page.$$eval("#histlist .hp-title", (r) => r.map((x) => x.textContent)) }, null, 1));
  await shot(page, "5-history");
  await page.click("#histclose");
  await page.click("#newchat");
  console.log(JSON.stringify({ after_newchat: await cards(page) }, null, 1));

  console.log("### 6. 🔍 empty send + Enter spam does nothing");
  await page.fill("#input", "   ");
  for (let i = 0; i < 5; i++) await page.press("#input", "Enter");
  await page.waitForTimeout(300);
  console.log(JSON.stringify({ cards: (await cards(page)).length, status: await status(page) }, null, 1));

  console.log("### 8. 🔍 tracking bridge: 'track the car' -> mocha_status, import, comp, clip, mocha_track (fake Mocha python) -> keys + mask applied");
  await page.fill("#input", "track the car");
  await page.press("#input", "Enter");
  await page.waitForFunction(() => !document.getElementById("approval").hidden, null, { timeout: 8000 });
  console.log("  first approval: " + await page.$eval("#ap-title", (e) => e.textContent) + " -> 'Yes for this session'");
  await page.click("#ap-always");
  await page.waitForFunction(() => document.getElementById("status").textContent.startsWith("Ready"), null, { timeout: 60000 });
  const trackCards = await cards(page);
  console.log(JSON.stringify({ cards: trackCards.slice(-8) }, null, 1));
  const lastText = await page.$eval("#chat .card.claude:last-of-type .prose", (e) => e.textContent);
  let tracked = null; try { tracked = JSON.parse(lastText.replace(/^Tracked — /, "")); } catch (e) {}
  console.log(JSON.stringify({ tracked_ok: !!tracked, frames: tracked && tracked.frames, exports: tracked && Object.keys(tracked.exports || {}),
    applied: tracked && tracked.applied.map((a) => a.kind + ": " + JSON.stringify(a.result).slice(0, 160)), warnings: tracked && tracked.warnings,
    corner_pin_retargeted: tracked && tracked.corner_pin_retargeted, track_report: tracked && tracked.track_report,
    mask: tracked && (tracked.applied.find((x) => x.kind === "mask") || {}).result, mask_report: tracked && tracked.mask_report }, null, 1));
  await shot(page, "8-tracking");

  console.log("### 9. 🔍 music: synth song -> music_list, analyze, add_music, beat_control, cut_to_beats, beat_effects");
  await page.fill("#input", "make a beat edit");
  await page.press("#input", "Enter");
  await page.waitForFunction(() => !document.getElementById("approval").hidden || document.getElementById("status").textContent.startsWith("Ready"), null, { timeout: 30000 });
  if (!(await page.$eval("#approval", (e) => e.hidden))) await page.click("#ap-always");
  await page.waitForFunction(() => document.getElementById("status").textContent.startsWith("Ready"), null, { timeout: 90000 });
  const beatText = await page.$eval("#chat .card.claude:last-of-type .prose", (e) => e.textContent);
  let beat = null; try { beat = JSON.parse(beatText.replace(/^Beat — /, "")); } catch (e) {}
  console.log(JSON.stringify({ ok: !!beat, songs: beat && beat.songs, bpm: beat && beat.analysis.bpm, beats: beat && beat.analysis.beats,
    drop_s: beat && beat.analysis.drop_s, first_downbeat: beat && beat.analysis.first_downbeat_s,
    music_layer: beat && beat.music.layer, sliders: beat && beat.control.sliders, markers: beat && beat.control.markers,
    cuts: beat && beat.cuts.cuts, first_cut_s: beat && beat.cuts.first_cut_s, cut_beats: beat && beat.cuts.placed && beat.cuts.placed.map((p) => p.beats),
    punch: beat && (beat.punch.enabled !== undefined ? beat.punch.enabled : beat.punch), flash_solid: beat && beat.flash.solid_layer,
    errors: beat && Object.entries(beat).filter(([k, v]) => v && v.error).map(([k, v]) => k + ": " + String(v.error).slice(0, 200)) }, null, 1));
  console.log(JSON.stringify({ tool_lines: (await cards(page)).filter((c) => /^TOOL/.test(c)).slice(-9) }, null, 1));
  await shot(page, "9-beat");

  console.log("### 10. 🔍 extra MCP servers: extra_mcp in the config rides along in mcp.json + allowedTools");
  // Stand-in for mcp.higgsfield.ai: bare host 404s, /mcp answers 401 + Bearer.
  const probeSrv = require("http").createServer((req, res) => {
    if (req.url === "/mcp") { res.writeHead(401, { "www-authenticate": 'Bearer resource_metadata="x"' }); res.end("{}"); }
    else { res.writeHead(404, { "content-type": "application/json" }); res.end('{"error":"not found"}'); }
  }).listen(0, "127.0.0.1");
  await new Promise((r) => probeSrv.on("listening", r));
  const hfUrl = "http://127.0.0.1:" + probeSrv.address().port;
  fs.writeFileSync(path.join(HOME, ".claude.json"), JSON.stringify({ mcpServers: { higgsfield: { type: "http", url: hfUrl } } }));
  const cfgPath = path.join(HOME, ".claude-assistant.json");
  fs.writeFileSync(cfgPath, JSON.stringify(Object.assign(JSON.parse(fs.readFileSync(cfgPath, "utf8")), { extra_mcp: ["higgsfield", "ghost"] })));
  await page.fill("#input", "hello");
  await page.press("#input", "Enter");
  await page.waitForFunction(() => document.getElementById("status").textContent.startsWith("Ready"), null, { timeout: 30000 });
  const last = JSON.parse(fs.readFileSync(path.join(HOME, "last-turn.json"), "utf8"));
  const mcp = last.mcp, argvDump = last.argv, sysTxt = last.system;
  console.log(JSON.stringify({ servers: mcp && Object.keys(mcp.mcpServers),
    higgsfield_url_is_claude_codes: !!mcp && mcp.mcpServers.higgsfield && mcp.mcpServers.higgsfield.url === hfUrl,
    allowed: argvDump && argvDump.slice(argvDump.indexOf("--allowedTools") + 1, argvDump.indexOf("--tools")),
    prompt_mentions: /mcp__higgsfield__/.test(sysTxt) && /ghost/.test(sysTxt) }, null, 1));
  console.log("### 10b. 🔍 server needs sign-in: the init event says needs-auth -> NOTE card + mcp_status says so; after sign-in the real tool names reach the prompt");
  const before10 = (await fullCards(page)).length;
  await page.fill("#input", "is higgsfield working");
  await page.press("#input", "Enter");
  await page.waitForFunction(() => document.getElementById("status").textContent.startsWith("Ready"), null, { timeout: 30000 });
  let after10 = (await fullCards(page)).slice(before10);
  const mcpJson = (c) => { try { return JSON.parse(c.text.replace(/^.*?MCP — /, "").replace(/Copy$/, "")); } catch (e) { return null; } };
  const stJson1 = after10.filter((c) => c.cls === "claude" && /MCP — /.test(c.text)).map(mcpJson).pop() || null;
  const hf1 = stJson1 && stJson1.servers && stJson1.servers.higgsfield;
  console.log(JSON.stringify({ note: (after10.find((c) => c.cls === "notice" && /higgsfield/.test(c.text)) || {}).text || null,
    status: hf1 && { status: hf1.status, usable: hf1.usable, endpoint_http: hf1.endpoint && hf1.endpoint.status,
      problem: hf1.problem && hf1.problem.replace(hfUrl, "<hf>") }, attached: stJson1 && stJson1.attached }, null, 1));
  await shot(page, "10b-needs-auth");
  fs.writeFileSync(path.join(HOME, ".fake-mcp-authed"), "1");
  const sysBefore = JSON.parse(fs.readFileSync(path.join(HOME, "last-turn.json"), "utf8")).system;
  await page.fill("#input", "is higgsfield working now");
  await page.press("#input", "Enter");
  await page.waitForFunction(() => document.getElementById("status").textContent.startsWith("Ready"), null, { timeout: 30000 });
  after10 = (await fullCards(page)).slice(before10);
  const stJson2 = after10.filter((c) => c.cls === "claude" && /MCP — /.test(c.text)).map(mcpJson).pop() || null;
  await page.fill("#input", "hello");
  await page.press("#input", "Enter");
  await page.waitForFunction(() => document.getElementById("status").textContent.startsWith("Ready"), null, { timeout: 30000 });
  const sysAfter = JSON.parse(fs.readFileSync(path.join(HOME, "last-turn.json"), "utf8")).system;
  const observed = JSON.parse(fs.readFileSync(path.join(HOME, "Library", "Application Support", "ClaudeAssistantAE", "mcp-observed.json"), "utf8"));
  const hf2 = stJson2 && stJson2.servers && stJson2.servers.higgsfield;
  console.log(JSON.stringify({ status_after_signin: hf2 && { status: hf2.status, usable: hf2.usable, tools: hf2.tools, problem: hf2.problem, probed: "endpoint" in hf2 },
    notes_after_signin: (await fullCards(page)).slice(before10).filter((c) => c.cls === "notice" && /higgsfield/.test(c.text)).length,
    prompt_before_signin: (sysBefore.match(/Last turn higgsfield was [^\n]*/) || [null])[0],
    prompt_after_signin: (sysAfter.match(/higgsfield tools seen last turn: [^\n]*/) || [null])[0],
    persisted: observed.servers && observed.servers.higgsfield }, null, 1));

  console.log("### 10c. 🔍 use_claude_code_connections (inherit mode): no --strict-mcp-config, only ae in mcp.json, extra names still allowed");
  fs.writeFileSync(cfgPath, JSON.stringify(Object.assign(JSON.parse(fs.readFileSync(cfgPath, "utf8")), { extra_mcp_mode: "inherit" })));
  await page.fill("#input", "hello");
  await page.press("#input", "Enter");
  await page.waitForFunction(() => document.getElementById("status").textContent.startsWith("Ready"), null, { timeout: 30000 });
  const inh = JSON.parse(fs.readFileSync(path.join(HOME, "last-turn.json"), "utf8"));
  console.log(JSON.stringify({ strict: inh.argv.includes("--strict-mcp-config"), servers: Object.keys(inh.mcp.mcpServers),
    allowed: inh.argv.slice(inh.argv.indexOf("--allowedTools") + 1, inh.argv.indexOf("--tools")),
    prompt_mentions_ghost_as_missing: /not found in Claude Code's config[^\n]*ghost/.test(inh.system) }, null, 1));

  probeSrv.close();

  console.log("### 11. 🔍 Claude Music panel: music.html = same engine, music prompt, tracking tools hidden, own history dir");
  const app2 = await _electron.launch({
    executablePath: require("electron"),
    args: ["--no-sandbox", "--no-zygote", path.join(__dirname, "main.js")],
    env: Object.assign({}, process.env, { AE_EXT: EXT, HOME, AE_PAGE: "music.html",
      PATH: path.join(__dirname, "fakebin") + ":" + process.env.PATH }) });
  const page2 = await app2.firstWindow();
  page2.on("pageerror", (e) => console.log("  [pageerror music] " + e.message));
  await page2.waitForFunction(() => document.querySelector("#chat .card"), null, { timeout: 8000 });
  await page2.fill("#input", "hello");
  await page2.press("#input", "Enter");
  await page2.waitForSelector("#approval:not([hidden])", { timeout: 15000 });   // create_comp asks, like step 2
  await page2.click("#ap-run");
  await page2.waitForFunction(() => document.getElementById("status").textContent.startsWith("Ready"), null, { timeout: 30000 });
  const mt = JSON.parse(fs.readFileSync(path.join(HOME, "last-turn.json"), "utf8"));
  const rpc = require("./mcp-rpc.js")(mt.mcp.mcpServers.ae);
  const list = await rpc({ jsonrpc: "2.0", id: 1, method: "tools/list" });
  const names = list.result.tools.map((t) => t.name);
  const hiddenCall = await rpc({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "mocha_track", arguments: {} } });
  console.log(JSON.stringify({ title: await page2.title(), placeholder: await page2.$eval("#input", (i) => i.placeholder),
    prompt_is_music: /^You are Claude Music/.test(mt.system), tools: names.length,
    has_music_tools: ["music_list", "analyze_music", "add_music", "beat_control", "cut_to_beats", "beat_effects"].every((n) => names.includes(n)),
    hides_tracking: ["mocha_track", "ai_segment", "apply_track_file", "track_history"].every((n) => !names.includes(n)),
    keeps_basics: ["grab_frame", "grab_source_frame", "add_mask", "run_extendscript"].every((n) => names.includes(n)),
    music_html_drift_lines: (() => { const a = fs.readFileSync(path.join(EXT, "html", "index.html"), "utf8").split("\n"), b = fs.readFileSync(path.join(EXT, "html", "music.html"), "utf8").split("\n");
      return b.filter((l) => !a.includes(l)).length; })(),
    workdir_names_per_panel: fs.readdirSync(path.join(HOME, "Library", "Application Support", "ClaudeAssistantAE")).filter((d) => /^turn-/.test(d)).length === 0,
    hidden_call: hiddenCall.result && hiddenCall.result.isError && hiddenCall.result.content[0].text.slice(0, 60),
    history_dirs: fs.readdirSync(path.join(HOME, "Library", "Application Support", "ClaudeAssistantAE")).filter((d) => /^chats/.test(d)).sort(),
    last_card: (await page2.$$eval("#chat .card", (cs) => cs.map((c) => c.textContent.replace(/\s+/g, " ").trim().slice(0, 80)))).pop() }, null, 1));
  await page2.screenshot({ path: path.join(__dirname, "shot-11-music.png") });
  console.log("  [shot] 11-music");
  await app2.close();

  console.log("### 12. 🔍 Claude Music UI: library → listen → results → applied → expressions → undo, narrow and wide");
  const app3 = await _electron.launch({
    executablePath: require("electron"),
    args: ["--no-sandbox", "--no-zygote", path.join(__dirname, "main.js")],
    env: Object.assign({}, process.env, { AE_EXT: EXT, HOME, AE_PAGE: "music.html",
      PATH: path.join(__dirname, "fakebin") + ":" + process.env.PATH }) });
  const page3 = await app3.firstWindow();
  page3.on("pageerror", (e) => console.log("  [pageerror music-ui] " + e.message));
  page3.on("console", (m) => { if (m.type() === "error") console.log("  [console.error music-ui] " + m.text()); });
  await page3.setViewportSize({ width: 420, height: 680 });
  await page3.waitForFunction(() => document.querySelector("#chat .card.claude") && document.querySelectorAll("#tracklist2 .track, #tracklist .track, .empty-lib").length, null, { timeout: 15000 });
  // a comp with a clip to drive, made through the panel's own tools
  await page3.evaluate(async () => {
    await assistant.callTool("create_comp", { name: "Ident", width: 1920, height: 1080, fps: 24, duration_s: 12 });
    const f = require("path").join(require("os").tmpdir(), "fake-logo.mp4"); require("fs").writeFileSync(f, "x");
    await assistant.callTool("import_media", { paths: [f] });
    await assistant.callTool("add_clip", { item_name: "fake-logo.mp4", comp: "Ident", start_s: 0, in_s: 0, out_s: 5 });
    await window.music.refresh();
  });
  const st0 = await page3.evaluate(() => ({ view: music.state.view, comp: music.state.comp && music.state.comp.name,
    greeting: (document.querySelector("#chat .card.claude .body") || {}).textContent.slice(0, 40), eyebrow: document.querySelector("#view-empty [data-comp-eyebrow]").textContent,
    library: music.state.library.map((t) => t.name), title: document.title }));
  console.log(JSON.stringify(st0));
  await page3.click('[data-act="library"]');
  await page3.click("#tracklist2 .track");
  const st1 = await page3.evaluate(() => ({ view: music.state.view, song: music.state.song && music.state.song.name, tempo: document.querySelector("[data-tempo]").textContent,
    sub: document.querySelector("#view-track [data-song-sub]").textContent, placeholder: document.querySelector("#wave-track").classList.contains("placeholder") }));
  console.log(JSON.stringify(st1));
  await page3.screenshot({ path: path.join(__dirname, "shot-12a-track.png") });
  await page3.click('[data-act="listen"]');
  await page3.waitForFunction(() => music.state.view === "results", null, { timeout: 60000 });
  const st2 = await page3.evaluate(() => ({ view: music.state.view, bpm: music.state.analysis.bpm, bars: music.state.analysis.bars,
    stats: [...document.querySelectorAll("#stats .n")].map((n) => n.textContent), sections: document.querySelectorAll("#sections .r").length - 1,
    fits: [...document.querySelectorAll("#fits .radio")].map((r) => r.textContent.trim().slice(0, 60)), heard: document.getElementById("heard").textContent.slice(0, 90),
    wave_bars: document.querySelectorAll("#wave-results .bars span").length, veil: !!document.querySelector("#wave-results .veil"), notes: document.querySelectorAll("#chat .card.claude").length }));
  console.log(JSON.stringify(st2));
  await page3.screenshot({ path: path.join(__dirname, "shot-12b-results-narrow.png") });
  await page3.click('[data-act="apply"]');
  await page3.waitForFunction(() => music.state.view === "applied", null, { timeout: 30000 });
  const st3 = await page3.evaluate(() => ({ view: music.state.view, sub: document.getElementById("applied-sub").textContent, done: [...document.querySelectorAll("#donelist div")].map((d) => d.textContent),
    wiring_rows: document.querySelectorAll("#wiring select").length / 2, layers: music.state.layers.map((l) => l.name + ":" + l.kind), barmarks: document.querySelectorAll("#wave-applied .barmarks span").length }));
  console.log(JSON.stringify(st3));
  await page3.selectOption("#wiring select", { label: "fake-logo.mp4" });
  await page3.click('[data-act="write"]');
  await page3.waitForFunction(() => music.state.applied && music.state.applied.written.length > 0, null, { timeout: 30000 });
  const st4 = await page3.evaluate(() => ({ written: music.state.applied.written, expressions: music.state.applied.expressions, last_note: [...document.querySelectorAll("#chat .card")].pop().textContent.slice(0, 80) }));
  console.log(JSON.stringify(st4));
  await page3.setViewportSize({ width: 940, height: 720 });
  await page3.waitForTimeout(300);
  await page3.screenshot({ path: path.join(__dirname, "shot-12c-applied-wide.png") });
  const wide = await page3.evaluate(() => ({ dateline: getComputedStyle(document.getElementById("dateline")).display, library_col: getComputedStyle(document.getElementById("library")).display,
    dl: document.getElementById("dl-comp").textContent + " | " + document.getElementById("dl-lib").textContent, cols: getComputedStyle(document.getElementById("stage")).gridTemplateColumns.split(" ").length }));
  console.log(JSON.stringify(wide));
  await page3.fill("#input", "hello");
  await page3.press("#input", "Enter");
  await page3.waitForSelector("#approval:not([hidden])", { timeout: 15000 });
  await page3.click("#ap-run");
  await page3.waitForFunction(() => document.getElementById("status").textContent.startsWith("Ready"), null, { timeout: 30000 });
  const ctx = JSON.parse(fs.readFileSync(path.join(HOME, "last-turn.json"), "utf8")).system;
  // the fake turn made and activated "Hello Comp"; the panel must stay on the comp the music is on
  const anchored = await page3.evaluate(() => ({ comp: music.state.comp && music.state.comp.name, eyebrow: document.querySelector("#view-applied [data-comp-eyebrow]").textContent }));
  console.log(JSON.stringify({ prompt_has_panel_state: /Panel state right now/.test(ctx), mentions_track: /track=beat-test/.test(ctx), mentions_applied: /applied: music layer/.test(ctx),
    stays_on_applied_comp_after_turn: anchored.comp === "Ident", eyebrow_after_turn: anchored.eyebrow }));
  await page3.click('[data-act="undo"]');
  await page3.waitForFunction(() => music.state.view === "results" && !music.state.applied, null, { timeout: 30000 });
  const st5 = await page3.evaluate(() => ({ view: music.state.view, comp: music.state.comp && music.state.comp.name, layers: music.state.layers.map((l) => l.name), last_note: [...document.querySelectorAll("#chat .card")].pop().textContent.slice(0, 120) }));
  console.log(JSON.stringify(st5));
  await page3.click("#menubtn");
  const st6 = await page3.evaluate(() => ({ view: music.state.view, models: document.getElementById("model").options.length, libdir: document.getElementById("libdir").value }));
  console.log(JSON.stringify(st6));
  await app3.close();

  console.log("### 7. 🔍 resize narrow — layout survives?");
  for (const w of [420, 320]) {
    await page.setViewportSize({ width: w, height: 560 });
    await page.waitForTimeout(200);
    console.log(w + "px: " + JSON.stringify({ overflowX: await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth),
      overflowY: await page.evaluate(() => document.documentElement.scrollHeight > document.documentElement.clientHeight),
      inputVisible: await page.$eval("#input", (i) => i.getBoundingClientRect().bottom <= window.innerHeight),
      newChatVisible: await page.$eval("#newchat", (b) => b.getBoundingClientRect().right <= window.innerWidth),
      topbarHeight: await page.$eval("#topbar", (t) => t.getBoundingClientRect().height) }));
    await shot(page, "7-narrow-" + w);
  }

  await app.close();
  console.log("SHOTS " + shots.join(" "));
})().catch(async (e) => { console.error("DRIVER FAILED:", e.message); process.exit(1); });
