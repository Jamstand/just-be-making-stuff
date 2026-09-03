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
    clipboard_got_mask_data: /After Effects Mask Data/.test(fs.existsSync(path.join(HOME, "clip.txt")) ? fs.readFileSync(path.join(HOME, "clip.txt"), "utf8") : "") }, null, 1));
  await shot(page, "8-tracking");

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
