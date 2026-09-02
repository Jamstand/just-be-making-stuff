// Electron host standing in for CEP: one page with DOM + Node (mixed
// context), the real extension files loaded untouched.
const { app, BrowserWindow } = require("electron");
const path = require("path");
const EXT = process.env.AE_EXT;
app.whenReady().then(() => {
  const win = new BrowserWindow({ width: 900, height: 700, show: true,
    webPreferences: { nodeIntegration: true, contextIsolation: false,
      sandbox: false, preload: path.join(__dirname, "preload.js") } });
  win.webContents.on("render-process-gone", (e, d) =>
    console.error("RENDER-PROCESS-GONE " + JSON.stringify(d)));
  app.on("child-process-gone", (e, d) =>
    console.error("CHILD-PROCESS-GONE " + JSON.stringify(d)));
  win.loadFile(path.join(EXT, "html", "index.html"));
});
app.on("window-all-closed", () => app.quit());
