// The CEP host API the real CSInterface.js calls into. evalScript is
// forwarded to host-sim.js (forked) so no vm context ever runs in Blink.
const path = require("path"), os = require("os");
const { fork } = require("child_process");
const EXT = process.env.AE_EXT;
const sim = fork(path.join(__dirname, "host-sim.js"), [], { env: Object.assign({}, process.env, { AE_EXT: EXT }) });
const pending = new Map(); let seq = 0;
sim.on("message", (m) => { const cb = pending.get(m.id); pending.delete(m.id); if (cb) cb(m.out); });
window.__adobe_cep__ = {
  evalScript(script, cb) { const id = ++seq; pending.set(id, cb); sim.send({ id, script }); },
  getSystemPath(t) { return t === "extension" ? EXT : os.homedir(); },
  getHostEnvironment() { return JSON.stringify({ appName: "AEFT", appVersion: "26.0", appLocale: "en_US", appUILocale: "en_US", appId: "AEFT", isAppOnline: true, appSkinInfo: {} }); },
  invokeSync() { return ""; }, invokeAsync() {}, addEventListener() {}, removeEventListener() {}, registerKeyEventsInterest() {},
  resizeContent() {}, requestOpenExtension() {}, initResourceBundle() { return ""; }, setScaleFactorChangedHandler() {}, registerInvalidCertificateCallback() {}, loadSnapshot() { return ""; } };
