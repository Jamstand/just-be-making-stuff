// Renderer logic: transcript, approvals, settings. All DOM building goes
// through document.createElement + textContent — model output is never
// interpreted as HTML, so nothing it says can script this window.
"use strict";
/* global assistant */

const chat = document.getElementById("chat");
const input = document.getElementById("input");
const sendBtn = document.getElementById("send");
const statusEl = document.getElementById("status");
const dot = document.getElementById("dot");
const approvalBox = document.getElementById("approval");

let busy = false;
let approvalPending = false;
let toolCount = 0;
let turnStart = 0;
let tick = null;

function el(tag, cls, text) {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text !== undefined) node.textContent = text;
  return node;
}

function scroll() { chat.scrollTop = chat.scrollHeight; }

function inline(target, text) {
  // **bold** and `code`, as DOM nodes — model output is never HTML.
  for (const part of String(text).split(/(\*\*[^*]+\*\*|`[^`\n]+`)/g)) {
    if (part.startsWith("**") && part.endsWith("**"))
      target.appendChild(el("b", "", part.slice(2, -2)));
    else if (part.startsWith("`") && part.endsWith("`") && part.length > 2)
      target.appendChild(el("code", "", part.slice(1, -1)));
    else target.appendChild(document.createTextNode(part));
  }
}

function codeCard(codeText, language) {
  const box = el("div", "codecard");
  const head = el("div", "head");
  head.appendChild(el("span", "", (language || "code").toUpperCase()));
  head.appendChild(copyButton(() => String(codeText)));
  box.appendChild(head);
  box.appendChild(el("pre", "", String(codeText)));
  return box;
}

function markdown(container, text) {
  // Fenced blocks become code cards; prose keeps its line structure
  // (paragraphs, dashed lists) via pre-wrap styling in CSS.
  // One captured group means split() yields text, lang, text, lang, text…
  // — odd slots are fence tags, and the even slots alternate prose / code
  // (the same trap the Python renderer's review caught: never assume a
  // 3-cycle here).
  const parts = String(text).split(/^[ \t]*```([\w+-]*)[ \t]*$\n?/m);
  for (let i = 0; i < parts.length; i++) {
    if (i % 2 === 1) continue;                 // language tag
    const isCode = (i / 2) % 2 === 1;
    if (isCode) {
      container.appendChild(codeCard(parts[i].replace(/\n$/, ""), parts[i - 1]));
    } else if (parts[i]) {
      const prose = el("div", "prose");
      inline(prose, parts[i].replace(/^\n+|\n+$/g, ""));
      if (prose.childNodes.length) container.appendChild(prose);
    }
  }
}

// ---------------------------------------------------------------- clipboard
// Inside After Effects a CEP panel never receives ⌘C/⌘V — the host's own
// Edit menu eats them — and a bare Electron window has no Edit menu to copy
// a selection with. So every card carries a Copy button, the top bar has
// Copy chat, and the shortcuts are handled here by hand through whichever
// clipboard route the panel layer exposes (pbcopy / Electron clipboard),
// falling back to the browser's own.
const transcript = [];                 // [{who, text}] in screen order

async function copyText(text) {
  text = String(text);
  if (assistant.clipboard && assistant.clipboard.write) {
    try { await assistant.clipboard.write(text); return true; } catch (e) {}
  }
  const focused = document.activeElement;
  try {
    const ta = el("textarea", "clip-ta");
    ta.value = text; ta.setAttribute("readonly", "");
    document.body.appendChild(ta);
    ta.select(); ta.setSelectionRange(0, text.length);
    const ok = document.execCommand("copy");
    ta.remove();
    if (focused && focused.focus) focused.focus();
    if (ok) return true;
  } catch (e) {}
  try {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      await navigator.clipboard.writeText(text); return true;
    }
  } catch (e) {}
  return false;
}

function flash(btn, message, bad) {
  const label = btn.dataset.label || (btn.dataset.label = btn.textContent);
  btn.textContent = message;
  btn.classList.toggle("bad", !!bad);
  clearTimeout(btn._flash);
  btn._flash = setTimeout(() => { btn.textContent = label;
                                  btn.classList.remove("bad"); }, 1400);
}

function copyButton(getText) {
  const btn = el("button", "copybtn", "Copy");
  btn.title = "Copy to clipboard";
  btn.onclick = (evt) => {
    evt.stopPropagation();
    copyText(getText()).then((ok) => flash(btn, ok ? "Copied ✓" : "Copy failed", !ok));
  };
  return btn;
}

function transcriptText() {
  return transcript.map((e) => (e.who ? e.who + ": " : "") + e.text)
    .join("\n\n");
}

const copyChatBtn = document.getElementById("copychat");
copyChatBtn.onclick = () => {
  if (!transcript.length) { flash(copyChatBtn, "Nothing yet", true); return; }
  copyText(transcriptText()).then((ok) =>
    flash(copyChatBtn, ok ? "Copied ✓" : "Copy failed", !ok));
};

function insertAtCursor(text) {
  const a = input.selectionStart, b = input.selectionEnd;
  input.value = input.value.slice(0, a) + text + input.value.slice(b);
  input.selectionStart = input.selectionEnd = a + text.length;
}

document.addEventListener("keydown", (evt) => {
  if (!(evt.metaKey || evt.ctrlKey) || evt.altKey) return;
  const key = String(evt.key).toLowerCase();
  const inInput = document.activeElement === input;
  if (key === "c" || key === "x") {
    const text = inInput
      ? input.value.slice(input.selectionStart, input.selectionEnd)
      : String(window.getSelection());
    if (!text) return;
    evt.preventDefault();
    copyText(text);
    if (key === "x" && inInput) insertAtCursor("");
  } else if (key === "v") {
    if (!inInput || !(assistant.clipboard && assistant.clipboard.read)) return;
    evt.preventDefault();
    assistant.clipboard.read().then((t) => { if (t) insertAtCursor(String(t)); },
                                    () => {});
  } else if (key === "a" && inInput) {
    evt.preventDefault();
    input.select();
  }
});

function card(kind, who, text) {
  const box = el("div", "card " + kind);
  box.appendChild(el("span", "who", who));
  box.appendChild(copyButton(() => String(text)));
  const body = el("div", "body");
  markdown(body, text);
  box.appendChild(body);
  chat.appendChild(box);
  transcript.push({ who, text: String(text) });
  scroll();
}

const openToolLines = {};              // name -> [status spans awaiting result]

function toolLine(name, args) {
  toolCount += 1;
  const line = el("div", "toolline");
  line.appendChild(el("span", "glyph", "›"));
  line.appendChild(el("span", "", name));
  if (name === "run_javascript" && args && args.code) {
    line.appendChild(el("span", "args", "" ));
    chat.appendChild(line);
    chat.appendChild(codeCard(String(args.code), "javascript"));
  } else {
    const summary = Object.entries(args || {})
      .map(([k, v]) => k + ": " + JSON.stringify(v)).join(", ");
    line.appendChild(el("span", "args", summary.slice(0, 160)));
    chat.appendChild(line);
    transcript.push({ who: "", text: "› " + name + "  " + summary });
  }
  const status = el("span", "status", "…");
  line.appendChild(status);
  (openToolLines[name] = openToolLines[name] || []).push(status);
  setStatus();
  scroll();
}

function toolResult(name, ok, ms) {
  const waiting = openToolLines[name];
  const status = waiting && waiting.shift();
  if (!status) return;
  status.textContent = (ok ? "✓" : "✕") +
    (ms >= 100 ? " " + (ms / 1000).toFixed(1) + "s" : "");
  status.className = "status " + (ok ? "ok" : "bad");
}

function setStatus() {
  if (busy) {
    const secs = Math.floor((Date.now() - turnStart) / 1000);
    statusEl.textContent = "Claude is working… " + secs + "s · " +
      toolCount + " tool" + (toolCount === 1 ? "" : "s");
    dot.className = "busy";
  } else if (toolCount) {
    const secs = Math.floor((Date.now() - turnStart) / 1000);
    statusEl.textContent = "Ready · " + toolCount + " tool call" +
      (toolCount === 1 ? "" : "s") + " · " + secs + "s";
    dot.className = "";
  } else {
    statusEl.textContent = "Ready";
    dot.className = "";
  }
}

function setBusy(value) {
  busy = value;
  sendBtn.disabled = value && !approvalPending;
  if (value) { turnStart = turnStart || Date.now();
               tick = tick || setInterval(setStatus, 500); }
  else { clearInterval(tick); tick = null; }
  setStatus();
}

function showApproval(payload) {
  approvalPending = true;
  document.getElementById("ap-title").textContent =
    "Approval — " + payload.name;
  const args = payload.input || {};
  document.getElementById("ap-detail").textContent =
    args.code ? String(args.code) : JSON.stringify(args, null, 2);
  approvalBox.hidden = false;
  input.placeholder = "1 = yes · 2 = yes for this session · 3 = no — or type guidance";
  sendBtn.disabled = false;
  scroll();
}

function answerApproval(decision, guidance) {
  if (!approvalPending) return;
  approvalPending = false;
  approvalBox.hidden = true;
  input.placeholder = "Ask Claude…  (Enter to send)";
  assistant.approval(decision, guidance || "");
  card("notice", "NOTE", decision === "decline"
    ? "Declined." + (guidance ? " Sent your guidance to Claude." : "")
    : decision === "always" ? "Approved for the rest of this session."
    : "Approved — running.");
  setBusy(busy);
}

document.getElementById("ap-run").onclick = () => answerApproval("run");
document.getElementById("ap-always").onclick = () => answerApproval("always");
document.getElementById("ap-no").onclick = () => answerApproval("decline");
document.addEventListener("keydown", (evt) => {
  if (approvalPending && evt.key === "Escape") answerApproval("decline");
});

function submit() {
  const text = input.value.trim();
  if (approvalPending) {
    input.value = "";
    if (text === "" || text === "1" || /^y(es)?$/i.test(text)) answerApproval("run");
    else if (text === "2") answerApproval("always");
    else if (text === "3" || /^no?$/i.test(text)) answerApproval("decline");
    else answerApproval("decline", text);
    return;
  }
  if (busy || !text) return;
  input.value = "";
  toolCount = 0; turnStart = Date.now();
  setBusy(true);
  assistant.send({ text,
    model: document.getElementById("model").value,
    effort: document.getElementById("effort").value,
    permissionMode: document.getElementById("mode").value });
}

sendBtn.onclick = submit;
input.addEventListener("keydown", (evt) => {
  if (evt.key === "Enter") submit();
});

document.getElementById("newchat").onclick = () => {
  assistant.newChat();
  chat.replaceChildren(); transcript.length = 0;
  toolCount = 0; turnStart = 0;
  card("notice", "NOTE", "New chat — Claude's memory of this session is cleared.");
  setStatus();
};

function dispatch(kind, payload) {
  if (kind === "you") card("you", "YOU", payload);
  else if (kind === "assistant") card("claude", "CLAUDE", payload);
  else if (kind === "error") card("error", "ERROR", payload);
  else if (kind === "notice") card("notice", "NOTE", payload);
  else if (kind === "toolcall") toolLine(payload.name, payload.input);
  else if (kind === "toolresult") toolResult(payload.name, payload.ok, payload.ms);
  else if (kind === "approval") showApproval(payload);
  else if (kind === "done") setBusy(false);
}
assistant.onEvent(({ kind, payload }) => dispatch(kind, payload));

// ---------------------------------------------------------------- history
const histPanel = document.getElementById("histpanel");
const histList = document.getElementById("histlist");

async function refreshHistory() {
  const chats = (await assistant.history("list")) || [];
  histList.replaceChildren();
  if (!chats.length)
    histList.appendChild(el("div", "hp-empty",
      "No saved chats yet — chats save themselves after each reply."));
  for (const chat of chats) {
    const row = el("div", "hp-row");
    const main = el("div", "hp-main");
    main.appendChild(el("div", "hp-title", chat.title));
    main.appendChild(el("div", "hp-meta",
      new Date(chat.updated).toLocaleString() + " · " + chat.turns +
      " turn" + (chat.turns === 1 ? "" : "s")));
    main.onclick = () => openChat(chat.id);
    row.appendChild(main);
    const del = el("button", "hp-del", "✕");
    del.title = "Delete this chat";
    del.onclick = async (evt) => {
      evt.stopPropagation();
      await assistant.history("delete", chat.id);
      refreshHistory();
    };
    row.appendChild(del);
    histList.appendChild(row);
  }
}

async function openChat(id) {
  const data = await assistant.history("open", id);
  if (!data) return;
  if (data.busy) { card("notice", "NOTE",
    "Wait for the current turn to finish before switching chats."); return; }
  histPanel.hidden = true;
  if (data.current) return;              // already on screen
  chat.replaceChildren(); transcript.length = 0;
  toolCount = 0; turnStart = 0;
  for (const e of data.events || []) {
    if (e.kind === "toolresult")
      toolResult(e.payload.name, e.payload.ok, e.payload.ms);
    else if (e.kind !== "approval" && e.kind !== "done")
      dispatch(e.kind, e.payload);
  }
  if (data.model) {
    const select = document.getElementById("model");
    if ([...select.options].some((o) => o.value === data.model))
      select.value = data.model;
  }
  card("notice", "NOTE", "Restored “" + (data.title || "chat") +
    "” — continue where you left off.");
  setStatus();
}

document.getElementById("historybtn").onclick = () => {
  histPanel.hidden = !histPanel.hidden;
  if (!histPanel.hidden) refreshHistory();
};
document.getElementById("histclose").onclick = () => { histPanel.hidden = true; };

assistant.config().then(({ models, efforts, modes }) => {
  const fill = (id, values, chosen) => {
    const select = document.getElementById(id);
    for (const value of values) {
      const opt = el("option", "", value);
      opt.value = value;
      select.appendChild(opt);
    }
    const saved = localStorage.getItem("ca-" + id);
    select.value = values.includes(saved) ? saved : chosen;
    select.onchange = () => localStorage.setItem("ca-" + id, select.value);
  };
  fill("model", models, models[0]);
  fill("effort", efforts, "medium");
  fill("mode", modes, "Ask before edits");
  card("notice", "NOTE", "Connected. Ask me anything — e.g. \"add a red " +
    "marker at every cut on V1\" — or paste /study <link> <link> to " +
    "learn a style from TikTok/Instagram edits.");
});
