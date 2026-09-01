// Chat history persistence for the Claude Assistant plugin — plain Node so
// tests can drive it without Electron. One JSON file per chat under the
// app's userData dir.
//
// Hardening carried over from the Python panel's adversarial review:
// - Atomic writes (temp file + rename): a crash mid-save can never destroy
//   the previous good snapshot.
// - `created` comes from an in-memory cache, then file mtime — never a full
//   re-parse of the archive per save.
// - Pruning is mtime-based, capped, and pins the file just written so a
//   clock rollback can't make a save delete itself.
// - Corrupt files are skipped calmly everywhere.
"use strict";
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const KEEP = 100;

function makeHistory(dir) {
  const createdCache = {};

  function fileOf(id) { return path.join(dir, id + ".json"); }

  function save(chat) {
    // chat: {id, events: [{kind, payload}], sessionId, model}
    if (!chat || !chat.id) return null;
    if (!chat.events || !chat.events.some((e) => e.kind === "you")) return null;
    fs.mkdirSync(dir, { recursive: true });
    const file = fileOf(chat.id);
    let created = createdCache[chat.id];
    if (!created) {
      try { created = fs.statSync(file).mtimeMs; } catch (e) { created = Date.now(); }
      createdCache[chat.id] = created;
    }
    const data = {
      id: chat.id, title: title(chat.events), created, updated: Date.now(),
      model: chat.model || "", sessionId: chat.sessionId || null,
      events: chat.events,
    };
    const tmp = file + "." + crypto.randomBytes(6).toString("hex") + ".tmp";
    try {
      fs.writeFileSync(tmp, JSON.stringify(data));
      fs.renameSync(tmp, file);           // atomic on the same filesystem
    } finally {
      try { if (fs.existsSync(tmp)) fs.unlinkSync(tmp); } catch (e) {}
    }
    prune(file);
    return file;
  }

  function title(events) {
    const first = (events || []).find((e) => e.kind === "you");
    if (!first) return "Untitled chat";
    const text = String(first.payload || "").replace(/\s+/g, " ").trim();
    return text.length > 58 ? text.slice(0, 57) + "…" : (text || "Untitled chat");
  }

  function list() {
    let names;
    try { names = fs.readdirSync(dir).filter((n) => n.endsWith(".json")); }
    catch (e) { return []; }
    const out = [];
    for (const name of names) {
      try {
        const data = JSON.parse(fs.readFileSync(path.join(dir, name), "utf8"));
        out.push({
          id: data.id, title: data.title || "Untitled",
          updated: Number(data.updated) || 0,
          turns: (data.events || []).filter((e) => e.kind === "you").length,
        });
      } catch (e) { /* corrupt file: skip, never crash the browser */ }
    }
    out.sort((a, b) => b.updated - a.updated);
    return out;
  }

  function load(id) {
    try { return JSON.parse(fs.readFileSync(fileOf(String(id)), "utf8")); }
    catch (e) { return null; }
  }

  function remove(id) {
    try { fs.unlinkSync(fileOf(String(id))); return true; }
    catch (e) { return false; }
  }

  function prune(keepFile) {
    try {
      const names = fs.readdirSync(dir).filter((n) => n.endsWith(".json"));
      if (names.length <= KEEP) return;
      const entries = names
        .filter((n) => !keepFile || path.join(dir, n) !== keepFile)
        .map((n) => {
          const p = path.join(dir, n);
          try { return [fs.statSync(p).mtimeMs, p]; } catch (e) { return null; }
        })
        .filter(Boolean)
        .sort((a, b) => b[0] - a[0]);
      const spare = keepFile ? KEEP - 1 : KEEP;
      for (const [, p] of entries.slice(Math.max(0, spare)))
        try { fs.unlinkSync(p); } catch (e) {}
    } catch (e) { /* pruning is best-effort */ }
  }

  return { save, list, load, remove, prune, title };
}

function buildRecap(events, maxEntries, maxChars) {
  // A compact dialogue digest for reopened chats whose CLI session is gone:
  // the model reads this instead of the lost server-side context.
  maxEntries = maxEntries || 30;
  maxChars = maxChars || 6000;
  const lines = [];
  for (const e of events || []) {
    if (e.kind !== "you" && e.kind !== "assistant") continue;
    let text = String(e.payload || "").replace(/\s+/g, " ").trim();
    if (text.length > 500) text = text.slice(0, 500) + "…";
    lines.push((e.kind === "you" ? "User: " : "Claude: ") + text);
  }
  let recap = lines.slice(-maxEntries).join("\n");
  if (recap.length > maxChars) recap = recap.slice(-maxChars);
  if (!recap) return "";
  return "<earlier_conversation_recap>\n" + recap +
    "\n</earlier_conversation_recap>\nThis chat was reopened from history " +
    "and the original session context is unavailable; the recap above is " +
    "the visible transcript so far. Continue the conversation naturally.";
}

function newChatId() { return crypto.randomBytes(16).toString("hex"); }

module.exports = { makeHistory, buildRecap, newChatId, KEEP };
