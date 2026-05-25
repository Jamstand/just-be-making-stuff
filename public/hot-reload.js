// Dev hot-reload — subscribes to /dev/live (SSE) and reloads the page
// when the server reports a public/ file change. Also exposes a tiny
// floating "↻ pull" button that calls POST /dev/pull, so you can update
// + reload without leaving the browser.
(function () {
  if (window.__hotReloadInstalled) return;
  window.__hotReloadInstalled = true;

  let lastSeen = 0;
  let es;
  function connect() {
    try { es?.close(); } catch {}
    es = new EventSource('/dev/live');
    es.onmessage = (e) => {
      try {
        const { t, file } = JSON.parse(e.data);
        if (!t || t === lastSeen) return;
        if (!lastSeen) { lastSeen = t; return; } // initial event — don't reload on connect
        console.log('[hot-reload] change detected:', file, '— reloading');
        lastSeen = t;
        location.reload();
      } catch {}
    };
    es.onerror = () => {
      // Reconnect after a short delay (server restart etc.).
      setTimeout(connect, 1500);
    };
  }
  connect();

  // Floating "↻ pull" button — runs `git pull` server-side; the
  // hot-reload SSE will then push a reload once files change.
  const btn = document.createElement('button');
  btn.textContent = '↻ pull';
  btn.title = 'Run git pull on the server and auto-reload when files change';
  btn.style.cssText = 'position:fixed;left:24px;bottom:24px;z-index:9999;background:#0e7c4a;color:#fff;border:0;border-radius:8px;padding:8px 14px;font-family:monospace;font-size:12px;font-weight:700;cursor:pointer;box-shadow:0 4px 12px rgba(14,124,74,.4)';
  btn.addEventListener('click', async () => {
    const orig = btn.textContent;
    btn.textContent = '↻ pulling…';
    btn.disabled = true;
    try {
      const r = await fetch('/dev/pull', { method: 'POST' });
      const j = await r.json();
      if (!j.ok) throw new Error(j.error || 'pull failed');
      btn.textContent = '↻ pulled';
      // The SSE listener will reload us once fs.watch fires. If no files
      // actually changed (already up-to-date), reset the button.
      setTimeout(() => { btn.textContent = orig; btn.disabled = false; }, 2500);
    } catch (err) {
      btn.textContent = '✕ pull failed';
      console.error('[hot-reload] pull error:', err);
      setTimeout(() => { btn.textContent = orig; btn.disabled = false; }, 2500);
    }
  });
  // Defer button insert until DOM is ready.
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => document.body.appendChild(btn));
  } else {
    document.body.appendChild(btn);
  }
})();
