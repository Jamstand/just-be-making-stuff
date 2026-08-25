// Sandboxed bridge between the renderer and main — the only surface the UI
// can reach (contextIsolation is on, per Resolve 19.0.2+ guidance).
"use strict";
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("assistant", {
  send: (payload) => ipcRenderer.invoke("send", payload),
  approval: (decision, guidance) =>
    ipcRenderer.invoke("approval", { decision, guidance }),
  newChat: () => ipcRenderer.invoke("newchat"),
  config: () => ipcRenderer.invoke("config"),
  onEvent: (fn) => ipcRenderer.on("event", (evt, data) => fn(data)),
});
