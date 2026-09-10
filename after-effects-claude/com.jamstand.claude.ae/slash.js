// Slash commands for the After Effects panels. The "/" menu in app.js lists
// SLASH_COMMANDS (sent with the config); macros expand before the model
// sees them; local:true ones the page answers itself. Claude Code reads a
// leading slash as one of ITS commands ("Unknown command: /train"), so
// every typed line goes through slashRoute before the CLI sees it.
"use strict";

const SLASH_COMMANDS = [
  { name: "study", args: "<link> [<link> …]", assistantOnly: true,
    description: "Study finished edits into your style profile (TikTok, Instagram, YouTube links)" },
  { name: "train", args: "<link> [<link> …]", assistantOnly: true,
    description: "Same as /study — train the style profile on finished edits" },
  { name: "style", args: "", description: "What the style profile has learned so far" },
  { name: "help", args: "", local: true, description: "What Claude can do here, and these commands" },
  { name: "tools", args: "", description: "List the tools this panel gives Claude, one line each" },
  { name: "mcp", args: "", description: "Which other MCP servers are attached and usable right now" },
  { name: "new", args: "", local: true, description: "Start a new chat (Claude's memory of this session is cleared)" },
  { name: "history", args: "", local: true, description: "Open past chats" },
  { name: "copy", args: "", local: true, description: "Copy the whole conversation as text" },
];

function commandsFor(panel) {
  return SLASH_COMMANDS.filter((c) => panel !== "music" || !c.assistantOnly);
}

// Typo-tolerant (/stuudy, /trainn) and forgiving of a missing space before
// the first link (/trainhttps://…).
const STUDY_RE = /^\/(stu+d+y|trai+n+)(?=\s|$|https?:)/i;

function expandSlash(text, panel) {
  const t = String(text || "").trim();
  const m = STUDY_RE.exec(t);
  if (m && panel !== "music") {
    const typed = /^t/i.test(m[1]) ? "/train" : "/study";
    const urls = t.match(/https?:\/\/\S+/g) || [];
    if (!urls.length)
      return "The user typed " + typed + " without links. Explain briefly: " + typed + " <link> [<link> ...] downloads "
        + "each video (TikTok, Instagram, YouTube — needs yt-dlp and ffmpeg: brew install yt-dlp ffmpeg), measures "
        + "its cut rhythm, shot lengths, exposure and colour cast into the car-edits style profile "
        + "(~/ClaudeAssistantStyle, shared with the Resolve panel), and with a Gemini key has Gemini watch it for "
        + "the content read" + (typed === "/train" ? " (/train and /study are the same command)" : "") + ".";
    return "Study these " + urls.length + " edit(s) into the car-edits style profile, STRICTLY one at a time. For EACH "
      + "link, all three steps in order:\n" + urls.map((u, i) => (i + 1) + ". " + u).join("\n")
      + "\nSTEP A: study_url with the link (downloads the video into ~/ClaudeAssistantStudy; if it fails because "
      + "yt-dlp or ffmpeg is missing, tell the user the brew line once and stop).\n"
      + "STEP B: study_edit with the downloaded file and the link as the source label (the measurements: cuts, shot "
      + "lengths, exposure, cast).\n"
      + "STEP C: watch_video on that file with profile car-edits and the same source label — Gemini watches the "
      + "footage and its content read merges into the profile. This step is NOT optional; if it fails over a missing "
      + "or invalid Gemini key, report that plainly once (set_gemini_key stores one from aistudio.google.com), skip "
      + "further watch attempts, and keep studying the remaining links.\n"
      + "If a link fails entirely, say why and continue with the rest. Finish with style_profile: the aggregate and "
      + "a plain-English read of the style — the numbers AND the content notes together.";
  }
  if (/^\/style\b/i.test(t))
    return "Call style_profile and give a plain-English read of the style it has learned — cut rhythm, shot lengths, "
      + "exposure, cast, and the content notes — then how you would apply it to the current comp. If there is no "
      + "profile yet, say so and point at /train <links>.";
  if (/^\/tools?\b/i.test(t))
    return "List the tools you have in this panel, grouped by what they do, one short line each, named the way the "
      + "user would say them rather than by tool id. No preamble.";
  if (/^\/mcp\b/i.test(t))
    return "Call mcp_status and say plainly which extra MCP servers are attached, which are usable right now, and "
      + "what to do about any that are not.";
  return null;
}

// expand a macro | answer an unknown /word locally | pass text through
// (prefixed when it starts with "/", a file path, so the CLI never reads it
// as a command).
function slashRoute(text, panel) {
  const t = String(text || "").trim();
  const expanded = expandSlash(t, panel);
  if (expanded) return { kind: "expand", prompt: expanded };
  const first = t.split(/\s+/)[0] || "";
  const m = /^\/([a-z][a-z-]*)(?=$|https?:)/i.exec(first);
  if (m) {
    const name = m[1].toLowerCase();
    const cmd = SLASH_COMMANDS.find((c) => c.name === name);
    let note;
    if (cmd && cmd.assistantOnly && panel === "music")
      note = "/" + name + " lives in the Claude Assistant panel (Window › Extensions › Claude Assistant) — it studies finished edits into a style profile. Here, type / to see what Claude Music has.";
    else if (cmd && cmd.local) note = "/" + name + " works on its own — type it without anything after it.";
    else if (STUDY_RE.test("/" + name)) note = "/" + name + " needs links after it: /train <link> [<link> …].";
    else note = "No command called /" + name + " — type / to see the list. Anything that doesn't start with / goes to Claude as written.";
    return { kind: "unknown", name, note };
  }
  return { kind: "text", prompt: t.startsWith("/") ? "Message from the panel (a path, not a command): " + t : t };
}

module.exports = { SLASH_COMMANDS, commandsFor, expandSlash, slashRoute };
