// POST one JSON-RPC message to the panel's Streamable-HTTP MCP endpoint,
// the way the claude CLI does for a {type:"http"} server. Shared by the fake
// CLI (fakebin/claude) and drive.js.
const http = require("http");
module.exports = function mcpRpc(cfg) {
  return (body) => new Promise((res, rej) => {
    const u = new URL(cfg.url); const data = JSON.stringify(body);
    const req = http.request({ host: u.hostname, port: u.port, path: u.pathname, method: "POST",
      headers: Object.assign({ "Content-Type": "application/json", "Accept": "application/json, text/event-stream" }, cfg.headers || {}) },
      (r) => { let t = ""; r.on("data", (d) => { t += d; }); r.on("end", () => res(t ? JSON.parse(t) : null)); });
    req.on("error", rej); req.end(data); });
};
