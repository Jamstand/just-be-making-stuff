// Drives the REAL panel HTML/CSS/app.js in a real Chromium from file://
// (the same origin scheme CEP uses). panel.js is replaced per case since
// plain Chromium has no `require`. Cases reproduce the suspected CEP
// failure modes and check each one is now VISIBLE on screen.
"use strict";
const { chromium } = require("playwright");
const path = require("path");
const HTML = "file://" + path.join(__dirname, "com.jamstand.claude.ae", "html", "index.html");
const OUT = __dirname;
const FAKE_ASSISTANT = `
  window.assistant = {
    config() { return Promise.resolve({ models: ["claude-opus-5","claude-fable-5","claude-sonnet-5","claude-haiku-4-5"],
               efforts: ["low","medium","high","xhigh","max"],
               modes: ["Ask before edits","Always ask","Never ask"] }); },
    onEvent() {}, history() { return Promise.resolve([]); },
    send() { return true; }, approval() {}, newChat() {} };`;

async function drive(label, opts) {
  const browser = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium",
    args: ["--no-sandbox"] });
  const page = await browser.newPage({ viewport: { width: 700, height: 560 } });
  const console_ = [];
  page.on("console", (m) => { if (m.type() === "error") console_.push(m.text()); });
  page.on("pageerror", (e) => console_.push("pageerror: " + e.message));
  if (!opts.realPanel)
    await page.route("**/panel.js", (r) => r.fulfill({ body: opts.panelBody || "",
      contentType: "application/javascript" }));
  await page.addInitScript((opts.injectAssistant === false ? "" : FAKE_ASSISTANT) + (opts.initExtra || ""));
  await page.goto(HTML);
  await page.waitForTimeout(400);
  const state = await page.evaluate(() => ({
    model: document.getElementById("model").options.length,
    effort: document.getElementById("effort").options.length,
    mode: document.getElementById("mode").options.length,
    cards: [...document.querySelectorAll("#chat .card")].map((c) => c.className + " | " + c.textContent.slice(0, 110)),
  }));
  const shot = path.join(OUT, "ae-ui-" + label + ".png");
  await page.screenshot({ path: shot });
  console.log("=== " + label + " ===");
  console.log(JSON.stringify(state, null, 1));
  console.log("console errors:", console_.length ? console_ : "(none)");
  await browser.close();
  return state;
}

(async () => {
  await drive("A-normal", {});
  await drive("B-localStorage-denied", { initExtra: `
    Object.defineProperty(window, "localStorage", { get() {
      throw new DOMException("Failed to read the 'localStorage' property from 'Window': Access is denied for this document.", "SecurityError"); } });` });
  await drive("C-panel-js-dies-at-top-level", { injectAssistant: false,
    panelBody: `throw new ReferenceError("__dirname is not defined");` });
  await drive("E-REAL-panel-js-shares-scope-with-app-js", { injectAssistant: false, realPanel: true,
    initExtra: `window.require = function () { throw new Error("no node in test browser"); };` });
  await drive("D-config-rejects", { injectAssistant: false, panelBody: `
    window.assistant = { config() { return Promise.reject(new Error("boom from config")); },
      onEvent() {}, history() { return Promise.resolve([]); }, send() {}, approval() {}, newChat() {} };` });
})().catch((e) => { console.error("DRIVER FAILED", e); process.exit(1); });
