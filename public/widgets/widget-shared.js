// widget-shared.js
// Shared utilities + base styling for the vans_it OBS widget pack.
// Injects the editorial palette, fonts, and common classes; exposes a
// Widget global with URL params, SSE event subscription, and helpers.

(function () {
  // ── Inject base palette + fonts ───────────────────────────────────────────
  const fontLink = document.createElement('link');
  fontLink.rel = 'stylesheet';
  fontLink.href =
    'https://fonts.googleapis.com/css2' +
    '?family=Cormorant+Garamond:ital,wght@0,400;0,500;0,600;1,400;1,500;1,600' +
    '&family=Inter:wght@400;500;600;700' +
    '&family=JetBrains+Mono:wght@400;500;600' +
    '&display=swap';
  document.head.appendChild(fontLink);

  const baseStyle = document.createElement('style');
  baseStyle.textContent = `
    :root {
      --paper:  #f4ecdc;
      --cream:  #fdf9f2;
      --ink:    #1c1612;
      --rust:   #a14a2a;
      --ochre:  #c9974a;
      --plum:   #5a3a82;
      --moss:   #3a5a40;

      --serif:  'Cormorant Garamond', 'EB Garamond', Georgia, serif;
      --sans:   'Inter', system-ui, sans-serif;
      --mono:   'JetBrains Mono', 'Fira Code', monospace;
      --body:   'Inter', system-ui, sans-serif;
    }

    * { margin: 0; padding: 0; box-sizing: border-box; }
    html, body { font-family: var(--body); color: var(--paper); }

    .st-card {
      background: linear-gradient(140deg, rgba(253,249,242,0.10), rgba(244,236,220,0.05));
      backdrop-filter: blur(22px) saturate(140%);
      -webkit-backdrop-filter: blur(22px) saturate(140%);
      border: 1px solid rgba(255,255,255,0.16);
      border-radius: 6px;
      box-shadow:
        0 20px 40px -16px rgba(0,0,0,0.55),
        inset 0 1px 0 rgba(255,255,255,0.18);
      color: var(--paper);
    }

    .st-eyebrow {
      font-family: var(--mono);
      font-size: 10px;
      letter-spacing: 0.26em;
      text-transform: uppercase;
      color: rgba(244,236,220,0.55);
      font-weight: 500;
    }

    .st-livedot {
      width: 8px; height: 8px; border-radius: 50%;
      background: var(--rust);
      box-shadow: 0 0 0 4px rgba(161,74,42,0.18);
      animation: st-pulse 1.6s ease-in-out infinite;
    }
    @keyframes st-pulse {
      0%, 100% { opacity: 1; }
      50%      { opacity: 0.4; }
    }

    .st-rule {
      height: 1px;
      background: linear-gradient(to right, transparent, rgba(244,236,220,0.22), transparent);
    }

    .st-num { font-family: var(--mono); font-feature-settings: 'tnum' 1; }
  `;
  document.head.appendChild(baseStyle);

  // ── URL params ────────────────────────────────────────────────────────────
  const params = new URLSearchParams(location.search);
  const getParam = (name, def) => {
    const v = params.get(name);
    return v != null ? v : def;
  };

  // demo mode is ON by default; disable with ?demo=0
  const demoOn = getParam('demo', '1') !== '0';

  // ── Helpers ───────────────────────────────────────────────────────────────
  function formatUptime(startMs) {
    const s = Math.max(0, Math.floor((Date.now() - startMs) / 1000));
    const hh = Math.floor(s / 3600);
    const mm = Math.floor((s % 3600) / 60);
    const ss = s % 60;
    return (
      String(hh).padStart(2, '0') + ':' +
      String(mm).padStart(2, '0') + ':' +
      String(ss).padStart(2, '0')
    );
  }

  // ── Event bus (local emit + SSE subscribe) ────────────────────────────────
  const listeners = new Map(); // event -> Set<cb>
  let sse = null;

  function ensureSSE() {
    if (sse || typeof EventSource === 'undefined') return;
    const url = getParam('events', '/widget-events');
    try {
      sse = new EventSource(url);
      sse.onmessage = (e) => {
        if (!e.data) return;
        try {
          const msg = JSON.parse(e.data);
          if (msg && msg.event) emit(msg.event, msg.data || {});
        } catch {}
      };
      sse.onerror = () => { /* EventSource auto-reconnects */ };
    } catch {}
  }

  function subscribe(event, cb) {
    ensureSSE();
    if (!listeners.has(event)) listeners.set(event, new Set());
    listeners.get(event).add(cb);
    return () => listeners.get(event)?.delete(cb);
  }

  function emit(event, data) {
    const set = listeners.get(event);
    if (!set) return;
    set.forEach((cb) => { try { cb(data); } catch (e) { console.error(e); } });
  }

  // ── SFX ───────────────────────────────────────────────────────────────────
  function playSFX(name) {
    if (window.StudioSFX && typeof window.StudioSFX.play === 'function') {
      try { window.StudioSFX.play(name); } catch {}
    }
  }

  window.Widget = {
    getParam,
    demoOn,
    formatUptime,
    subscribe,
    emit,
    playSFX,
  };
})();
