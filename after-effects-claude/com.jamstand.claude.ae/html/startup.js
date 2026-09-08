// Loaded before everything else (shared by index.html and music.html):
// any uncaught error or unhandled rejection from panel.js/app.js becomes a
// visible red card. A silent half-alive panel must never recur.
// Loaded before everything else: any uncaught error or unhandled
// rejection from panel.js/app.js becomes a visible red card. A silent
// half-alive panel (empty dropdowns, no message) must never recur.
(function () {
  var queue = [];
  function paint(text) {
    var chat = document.getElementById("chat");
    if (!chat) { queue.push(text); return; }
    var box = document.createElement("div");
    box.className = "card error";
    var who = document.createElement("span"); who.className = "who";
    who.textContent = "STARTUP ERROR"; box.appendChild(who);
    var body = document.createElement("div"); body.className = "prose";
    body.textContent = text; box.appendChild(body);
    chat.appendChild(box);
  }
  window.addEventListener("error", function (e) {
    paint((e.message || "error") + (e.filename ? "  [" +
      e.filename.split("/").pop() + ":" + e.lineno + "]" : ""));
  });
  window.addEventListener("unhandledrejection", function (e) {
    var r = e.reason;
    paint("Unhandled promise rejection: " +
      (r && r.stack ? r.stack.split("\n").slice(0, 2).join(" ") : String(r)));
  });
  document.addEventListener("DOMContentLoaded", function () {
    queue.forEach(paint); queue = [];
  });
})();
