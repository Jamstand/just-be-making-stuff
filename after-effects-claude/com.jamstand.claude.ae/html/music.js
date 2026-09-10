// Claude Music — the panel's own UI (library → listen → results → applied),
// on top of the same engine as Claude Assistant. Loaded BEFORE app.js so it
// can sit in the event stream app.js binds; every button here calls the
// panel's tools directly (assistant.callTool — the user clicked, so no
// approval card), and the current state rides along to the model as panel
// context on every turn.
"use strict";
(function () {
  const A = window.assistant;
  if (!A || typeof A.callTool !== "function") return;   // startup.js paints the error

  const $ = (id) => document.getElementById(id);
  const $$ = (sel, root) => Array.from((root || document).querySelectorAll(sel));
  const fmt = (s) => { s = Math.max(0, Math.round(s || 0)); return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0"); };
  const fmt1 = (s) => { s = Math.max(0, s || 0); const m = Math.floor(s / 60), r = s - m * 60; return m + ":" + (r < 10 ? "0" : "") + r.toFixed(1); };
  const cap = (w) => w ? w.charAt(0).toUpperCase() + w.slice(1) : w;
  const note = (kind, text) => { if (typeof window.card === "function") window.card(kind, kind === "claude" ? "CLAUDE" : "NOTE", text); };

  // ------------------------------------------------------------ state
  const S = {
    view: "empty", prev: "empty", comp: null, layers: [], library: [], dirs: [],
    song: null, analysis: null, fits: [], fit: 0,
    opt: { markers: "bars", range: "fit", tempo: null, offset: 0 },
    applied: null, wiring: [], listenToken: 0, listening: 0, progress: 0, progressEvents: 0,
    waves: {}, libdir: "", busy: null, placeholder: "",
  };
  const libDir = () => S.libdir || S.dirs[0] || "~/Music/Claude Assistant";
  const homeView = () => (S.listening ? "listening" : S.applied ? "applied" : S.analysis ? "results" : S.song ? "track" : "empty");
  const placedSong = () => !!(S.song && S.song.from === "comp");
  // The layer a comp-picked song lives on, found by name and file (an index
  // shifts whenever a layer is added above); the remembered index only
  // breaks a tie. Null when the layer is gone.
  function placedLayer() {
    const s = S.song; if (!s || s.from !== "comp") return null;
    const same = S.layers.filter((l) => l.name === s.name && (!s.file || !l.file || l.file === s.file));
    if (!same.length) return null;
    const hit = same.find((l) => l.index === s.layer) || same[same.length - 1];
    s.layer = hit.index;
    return hit;
  }
  // One thing at a time on the timeline: apply, write and undo refuse to
  // overlap (a double click, or a click while a previous one is still in
  // After Effects); listening is cancellable and stays outside this.
  async function withBusy(what, fn) {
    if (S.busy) { note("notice", "Still " + S.busy + " — one moment."); return; }
    S.busy = what; document.body.classList.add("busy");
    try { return await fn(); } finally { S.busy = null; document.body.classList.remove("busy"); }
  }
  const TICK = { ok: '<svg width="14" height="14" viewBox="0 0 256 256" fill="currentColor" class="ok"><path d="M229.66,77.66l-128,128a8,8,0,0,1-11.32,0l-56-56a8,8,0,0,1,11.32-11.32L96,188.69,218.34,66.34a8,8,0,0,1,11.32,11.32Z"/></svg>' };

  // ------------------------------------------------------------ event stream
  // Sit between panel.js and app.js: our events first, then app.js's.
  let inner = null;
  const origOn = A.onEvent.bind(A);
  A.onEvent = (h) => { inner = h; };
  origOn((ev) => {
    // sendUI is synchronous: a throw here would reject the tool call in
    // flight, so the panel's own rendering never escapes.
    if (ev && ev.kind === "music_progress") { try { onProgress(ev.payload); } catch (e) { console.error("music_progress", e); } return; }
    if (ev && ev.kind === "done") { refreshComp(true).catch(() => {}); refreshLibrary(false).catch(() => {}); }   // the model may have changed the comp or added songs
    if (inner) inner(ev);
  });
  function onProgress(p) {
    if (S.view !== "listening" || !S.song || !p || p.file !== S.song.file) return;   // another file (the notes column asked) is not ours
    S.progressEvents += 1;
    S.progress = Math.max(S.progress, Number(p.pct) || 0);
    $("listen-word").textContent = p.stage === "decoding" ? "Reading the file…" : p.stage === "listening" ? "Listening…" : "Writing the notes…";
    renderWave($("wave-listen"), { fogPct: 100 - S.progress, compVeil: true });
    renderChecklist();
  }

  // ------------------------------------------------------------ data
  async function refreshComp(render, anchorName) {
    try {
      const ov = await A.callTool("get_project_overview", {});
      const comps = ov.comps || [];
      // Once the music is on a comp, stay with that comp even if After Effects
      // (or a turn in the notes) activates another one: undo and the wiring
      // belong to it. If it was deleted there is nothing left to take back.
      const want = S.applied ? S.applied.comp : anchorName;
      let anchored = want ? comps.find((c) => c.name === want) || null : null;
      if (S.applied && !anchored) {
        note("notice", S.applied.comp + " is gone from the project, so there is nothing left to take back.");
        S.applied = null; S.wiring = [];
        if (S.view === "applied") show(S.analysis ? "results" : "track");
      }
      S.comp = anchored || comps.find((c) => c.active) || comps[0] || null;
      if (S.comp) {
        try { const ll = await A.callTool("list_layers", { comp: S.comp.name }); S.layers = ll.layers || []; }
        catch (e) { S.layers = []; }
      } else S.layers = [];
    } catch (e) { S.comp = null; S.layers = []; }
    // the fits depend on the comp's length: keep them true to the comp now on screen
    if (S.analysis && !S.applied) {
      const was = S.fits[S.fit] && S.fits[S.fit].label;
      S.fits = computeFits();
      const same = S.fits.findIndex((f) => f.label === was);
      S.fit = same >= 0 ? same : Math.max(0, S.fits.findIndex((f) => f.pick));
    }
    if (render !== false) renderAll();
  }
  async function refreshLibrary(render) {
    try { const r = await A.callTool("music_list", {}); S.library = r.songs || []; S.dirs = r.dirs || []; S.libdir = r.library_dir || ""; S.waves = r.waves || {}; }
    catch (e) { S.library = []; }
    if (render !== false) renderAll();
  }
  const compDur = () => (S.comp ? Number(S.comp.duration_s) || 0 : 0);
  const compFps = () => (S.comp ? Number(S.comp.fps) || 24 : 24);
  const audioLayers = () => S.layers.filter((l) => l.has_audio && !l.guide);

  // ------------------------------------------------------------ rendering
  function show(view) {
    if (view !== "settings") S.prev = view;
    S.view = view;
    for (const v of ["empty", "library", "track", "listening", "results", "applied", "settings"])
      $("view-" + v).hidden = v !== view;
    if (view === "library") $("libsearch2").focus();
    renderAll();
  }
  function renderAll() {
    const c = S.comp;
    const compLine = c ? c.name + " · " + c.fps + " fps · " + fmt(c.duration_s) : "no comp open";
    for (const e of $$("[data-comp-eyebrow]")) e.textContent = compLine;
    $("dl-comp").textContent = c ? c.name + " · " + c.width + "×" + c.height + " · " + c.fps + " fps · " + fmt(c.duration_s) : "no comp open";
    $("dl-date").textContent = new Date().toLocaleDateString("en-GB", { weekday: "long", day: "numeric", month: "long", year: "numeric" });
    $("dl-lib").textContent = "Library · " + S.library.length + " track" + (S.library.length === 1 ? "" : "s");
    $("lib-sub").textContent = S.library.length ? S.library.length + " track" + (S.library.length === 1 ? "" : "s") + " in " + libDir() : "Nothing here yet";
    renderLibrary($("tracklist"), $("libsearch").value); renderLibrary($("tracklist2"), $("libsearch2").value);
    renderCompLayers($("complayers")); renderCompLayers($("complayers2"));
    if (S.song) {
      for (const e of $$("[data-song-title]")) e.textContent = S.song.name;
      for (const e of $$("[data-song-sub]")) e.textContent = songSub();
    }
    if (S.view === "track") renderTrack();
    if (S.view === "listening") { renderWave($("wave-listen"), { fogPct: 100 - S.progress, compVeil: true }); renderChecklist(); }
    if (S.view === "results") renderResults();
    if (S.view === "applied") renderApplied();
    if (S.view === "settings") renderSettings();
    renderSuggestions();
    syncSegs();
    S.placeholder = S.view === "applied" ? "Ask anything — “bigger bump on the logo”" : S.view === "results" ? "Ask anything — “land the drop at 0:08”"
      : S.song ? "Ask anything — “where's the drop?”" : "Ask anything — “what fits a 30 s ident?”";
    window.music.placeholder = S.placeholder;
    const ap = $("approval"); if (!ap || ap.hidden) $("input").placeholder = S.placeholder;
    A.setContext(contextText());
  }
  // Chromium 99 (CEP 12) has no :has(): the segmented control's selected
  // and focus states are classes on the label, kept in step with the radio.
  function syncSegs(root) {
    for (const lab of $$(".seg-opt", root)) { const i = lab.querySelector("input"); lab.classList.toggle("on", !!(i && i.checked)); }
  }
  document.addEventListener("change", (e) => { if (e.target.matches && e.target.matches(".seg-opt input")) syncSegs(e.target.closest(".seg")); });
  document.addEventListener("focusin", (e) => { if (e.target.matches && e.target.matches(".seg-opt input")) e.target.parentElement.classList.toggle("focus", e.target.matches(":focus-visible")); });
  document.addEventListener("focusout", (e) => { if (e.target.matches && e.target.matches(".seg-opt input")) e.target.parentElement.classList.remove("focus"); });
  function songSub() {
    const s = S.song, a = S.analysis;
    if (!s) return "";
    const bits = [s.ext ? s.ext.replace(".", "").toUpperCase() : "audio"];
    if (a) bits.push(fmt(a.duration_s), a.bpm + " BPM · " + a.bars + " bars");
    else if (s.bpm) bits.push(fmt(s.duration_s), s.bpm + " BPM at a glance");
    else bits.push("from " + (s.from === "comp" ? "this comp" : "your library"));
    return bits.join(" · ");
  }
  function renderLibrary(el, filter) {
    if (!el) return;
    el.replaceChildren();
    const q = String(filter || "").trim().toLowerCase();
    const rows = S.library.filter((t) => !q || t.name.toLowerCase().includes(q));
    if (!S.library.length) {
      const d = document.createElement("div"); d.className = "empty-lib";
      d.textContent = "No tracks yet. Drop songs into " + libDir() + " and they appear here.";
      el.appendChild(d); return;
    }
    for (const t of rows) {
      const r = document.createElement("div");
      r.className = "track" + (S.song && S.song.file === t.file ? " on" : ""); r.tabIndex = 0;
      const n = document.createElement("div"); n.className = "name"; n.textContent = t.name;
      const m = document.createElement("div"); m.className = "meta";
      m.textContent = t.analyzed ? Math.round(t.bpm) + " · " + fmt(t.duration_s) : (t.ext || "").replace(".", "") + " · not listened yet";
      r.append(n, m);
      r.onclick = () => pickSong(t, "library");
      r.onkeydown = (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); pickSong(t, "library"); } };
      el.appendChild(r);
    }
  }
  function renderCompLayers(el) {
    if (!el) return;
    el.replaceChildren();
    const rows = audioLayers();
    if (!rows.length) { const d = document.createElement("div"); d.className = "empty-lib"; d.textContent = S.comp ? "No audio in " + S.comp.name + " yet." : "Open a comp in After Effects."; el.appendChild(d); return; }
    for (const l of rows) {
      const isSong = (S.song && S.song.from === "comp" && l.name === S.song.name && !!l.file) || (S.applied && S.applied.layerName && l.name === S.applied.layerName);
      const r = document.createElement("div"); r.className = "track" + (isSong ? " on" : "");
      const n = document.createElement("div"); n.className = "name"; n.textContent = l.name;
      const m = document.createElement("div"); m.className = "meta"; m.textContent = "audio · " + fmt(l.out_s - l.in_s) + " · layer " + l.index;
      r.append(n, m);
      if (l.file) { r.tabIndex = 0; r.onclick = () => pickSong({ name: l.name, file: l.file, ext: (l.file.match(/\.[a-z0-9]+$/i) || [""])[0], layer: l.index }, "comp"); }
      el.appendChild(r);
    }
  }

  // The waveform strip: analysis.wave (110 buckets) with overlays.
  // opts: compVeil (tint the comp's span), fogPct (unlistened part), sections,
  // drop, cuts (song-second lines), range [in_s, out_s] to show a slice, bars.
  function renderWave(el, opts) {
    if (!el) return;
    opts = opts || {};
    const a = S.analysis;
    const wave = a && a.wave ? a.wave : (S.song && S.waves[S.song.file]) || null;   // listened before: the library remembers the strip
    el.className = "wave" + (wave ? "" : " placeholder");
    el.replaceChildren();
    const L = a ? a.duration_s : (S.song && S.song.duration_s) || 0;
    const range = opts.range || [0, L];
    const span = Math.max(0.001, range[1] - range[0]);
    const pct = (t) => Math.max(0, Math.min(100, (t - range[0]) / span * 100));
    if (opts.labels && opts.labels.length) {
      const lab = document.createElement("div"); lab.className = "labels";
      for (const x of opts.labels) { const s = document.createElement("span"); s.style.left = pct(x.t) + "%"; if (x.hi) s.className = "hi"; s.textContent = x.text; if (x.t > range[0]) s.style.paddingLeft = "5px"; lab.appendChild(s); }
      el.appendChild(lab);
    }
    const bars = document.createElement("div"); bars.className = "bars";
    const n = 110;
    for (let i = 0; i < n; i++) {
      const sp = document.createElement("span");
      let h = 18;
      if (wave) {
        const t0 = range[0] + (i / n) * span, idx = Math.min(wave.length - 1, Math.floor(t0 / Math.max(0.001, L) * wave.length));
        h = Math.max(6, Math.round(wave[idx] * 100));
      }
      sp.style.height = h + "%"; bars.appendChild(sp);
    }
    el.appendChild(bars);
    if (opts.compVeil && compDur() > 0 && L > 0 && !opts.range) {
      const v = document.createElement("div"); v.className = "veil"; v.style.width = Math.min(100, compDur() / L * 100) + "%"; el.appendChild(v);
    }
    for (const t of opts.cuts || []) { if (t <= range[0] || t >= range[1]) continue; const c = document.createElement("div"); c.className = "cut"; c.style.left = pct(t) + "%"; el.appendChild(c); }
    if (opts.drop !== undefined && opts.drop !== null && opts.drop > range[0] && opts.drop < range[1]) { const d = document.createElement("div"); d.className = opts.dropAsLine ? "playline" : "drop"; d.style.left = pct(opts.drop) + "%"; el.appendChild(d); }
    if (opts.fogPct !== undefined && opts.fogPct > 0) { const f = document.createElement("div"); f.className = "fog"; f.style.width = opts.fogPct + "%"; el.appendChild(f); }
    if (opts.bars && opts.bars.length) {
      const bm = document.createElement("div"); bm.className = "barmarks";
      for (const t of opts.bars) { if (t < range[0] || t > range[1]) continue; const s = document.createElement("span"); s.style.left = pct(t) + "%"; bm.appendChild(s); }
      el.appendChild(bm);
    } else if (opts.ticks !== false) { const tk = document.createElement("div"); tk.className = "ticks"; el.appendChild(tk); }
    const tm = document.createElement("div"); tm.className = opts.axis ? "timeaxis" : "times";
    if (opts.axis) {
      for (let k = 0; k <= 4; k++) { const s = document.createElement("span"); s.textContent = fmt(range[0] + span * k / 4 - (opts.axisFrom || 0)); tm.appendChild(s); }
    } else {
      const s0 = document.createElement("span"); s0.style.left = "0"; s0.textContent = "0:00"; tm.appendChild(s0);
      if (opts.compVeil && compDur() > 0 && L > compDur()) { const s1 = document.createElement("span"); s1.className = "hi"; s1.style.left = Math.min(100, compDur() / L * 100) + "%"; s1.style.paddingLeft = "6px"; s1.textContent = "your comp ends here · " + fmt(compDur()); tm.appendChild(s1); }
      const s2 = document.createElement("span"); s2.style.right = "0"; s2.textContent = fmt(L); tm.appendChild(s2);
    }
    el.appendChild(tm);
  }

  function renderTrack() {
    renderWave($("wave-track"), { compVeil: true, drop: S.analysis ? S.analysis.drop_s : null });
    $$("[data-fit-label]").forEach((e) => { e.textContent = "Fit to comp" + (compDur() ? " · " + fmt(compDur()) : ""); });
    const t = $$("[data-tempo]")[0];
    if (S.opt.tempo) t.textContent = S.opt.tempo + " BPM · yours";
    else if (S.analysis) t.textContent = S.analysis.bpm + " BPM · detected";
    else if (S.song && S.song.bpm) t.textContent = Math.round(S.song.bpm) + " BPM · from last time";
    else t.textContent = "found when I listen";
    $("offset").value = String(S.opt.offset || 0);
    for (const seg of ["markers"]) { const r = $$('[data-opt="' + seg + '"] input'); r.forEach((i) => { i.checked = i.value === S.opt[seg]; }); }
    $$('[data-opt="range"] input').forEach((i) => { i.checked = i.value === S.opt.range; i.disabled = placedSong(); });
    $$('[data-opt="range"]').forEach((s) => s.classList.toggle("disabled", placedSong()));
    $("offset").disabled = placedSong();
    $$("[data-placed-note]").forEach((e) => { e.hidden = !placedSong(); });
  }
  function renderChecklist() {
    const el = $("checklist"); el.replaceChildren();
    const p = S.progress, a = S.analysis;
    const rows = [
      ["Tempo", p >= 45 ? (a ? a.bpm + " BPM, steady" : "counting…") : "reading the file", p >= 100],
      ["Bars", p >= 100 ? (a ? "4/4 · " + a.bars + " bars" : "counted") : "next", p >= 100],
      ["Sections", p >= 100 ? (a ? a.sections.length + " found" : "found") : "finding where it turns…", p >= 100],
      ["Kick · bass · energy", p >= 100 ? "read from the mix" : "next", p >= 100],
    ];
    rows.forEach(([k, v, done], i) => {
      const icon = document.createElement("span");
      if (done) icon.innerHTML = TICK.ok; else icon.className = i === 0 || (p >= 45 && i === 2) ? "dotb" : "doto";
      const kk = document.createElement("span"); kk.textContent = k; if (!done && i > 0) kk.className = "muted";
      const vv = document.createElement("span"); vv.className = "muted"; vv.textContent = v;
      el.append(icon, kk, vv);
    });
  }
  // The analyser reports drop_s = 0 when a song opens at full energy; that is
  // not a drop anyone waits for, so the panel treats it as "no drop".
  const dropOf = (a) => (a && a.drop_s !== null && a.drop_s !== undefined && a.drop_s > 0.5 ? a.drop_s : null);
  function heardText() {
    const a = S.analysis, D = compDur();
    if (!a) return "";
    const parts = [];
    parts.push(a.tempo_confidence >= 0.5 ? "A steady pulse at " + a.bpm + " BPM" : "The pulse is loose — I make it " + a.bpm + " BPM, but check it by ear");
    const drop = dropOf(a);
    if (drop !== null) {
      parts.push("the song really opens at " + fmt(drop));
      if (D && drop > D) parts.push("later than your " + Math.round(D) + " seconds, so I'd trim so it lands early");
      else if (D) parts.push("inside your comp");
    } else if (a.drop_s === 0 || (a.sections[0] && a.sections[0].kind === "drop")) parts.push("it opens at full energy from the first bar — no build to wait for");
    else parts.push("it never really opens up — no clear drop, so markers on the bars are the useful part");
    return parts.join(", ") + ".";
  }
  function computeFits() {
    const a = S.analysis, D = compDur();
    const fits = [];
    if (!a) return fits;
    const barLen = a.beat_s * 4, L = a.duration_s;
    const drop = dropOf(a);
    // A song already on the timeline stays where the user put it: the fit is
    // its placement, and apply adds no second copy of the audio. Song time →
    // comp time is + startTime (offset_s); the audible span runs from the
    // layer's in point to its out point or the comp's end.
    if (placedSong()) {
      const placed = placedLayer();
      if (!placed) {
        fits.push({ in_s: 0, gone: true, pick: true, label: "That layer is no longer in " + (S.comp ? S.comp.name : "the comp"), detail: "pick the track again from the library or the comp" });
        return fits;
      }
      const inS = Math.max(0, placed.in_s - placed.start_s);
      const untilComp = Math.min(D || placed.out_s, placed.out_s);
      const dropComp = drop !== null ? drop + placed.start_s : null;
      fits.push({ in_s: inS, offset_s: placed.start_s, from_s: placed.in_s, until_s: untilComp, placed: true, pick: true,
        label: "As it sits on your timeline", detail: (inS > 0 ? "from " + fmt(inS) + " of the song" : "from the top") + (dropComp !== null && dropComp >= placed.in_s && dropComp <= untilComp ? ", the drop lands at " + fmt(dropComp) : "") });
      return fits;
    }
    if (drop !== null && D && drop > D * 0.375) {
      const inS = Math.max(0, drop - 6 * barLen);
      fits.push({ in_s: inS, label: "Open six bars before the drop", detail: "drop lands at " + fmt(drop - inS) + (D ? ", inside your " + fmt(D) : ""), pick: true });
    }
    fits.push({ in_s: 0, label: "Start from the top", detail: L <= D || !D ? "the whole track" + (D && L <= D ? " fits" : "") : (drop !== null && drop <= D ? "the drop lands at " + fmt(drop) : "intro and verse, no drop") });
    const dropSec = a.sections.findIndex((s) => s.kind === "drop");
    const brk = a.sections.findIndex((s, i) => i > dropSec && dropSec >= 0 && s.kind === "quiet");
    if (brk > 0) {
      const next = a.sections.slice(brk + 1).find((s) => s.kind === "drop");
      const inS = a.sections[brk].start_s;
      fits.push({ in_s: inS, label: "Start at the break", detail: next ? "a quiet lead-in, then the next drop at " + fmt(next.start_s - inS) : "a quiet lead-in" });
    }
    if (!fits.some((f) => f.pick)) fits[0].pick = true;
    return fits;
  }
  function renderResults() {
    const a = S.analysis; if (!a) return;
    const D = compDur();
    const st = $("stats"); st.replaceChildren();
    [[a.bpm, "BPM"], ["4/4", "Meter"], [a.bars, "Bars"], [fmt(a.duration_s), "Length"]].forEach(([n, l]) => {
      const d = document.createElement("div"); const nn = document.createElement("div"); nn.className = "n"; nn.textContent = n; const ll = document.createElement("div"); ll.className = "l"; ll.textContent = l; d.append(nn, ll); st.appendChild(d);
    });
    const labels = [];
    if (D && D < a.duration_s) labels.push({ t: 0, text: "Comp · " + fmt(D), hi: true });
    if (dropOf(a) !== null) labels.push({ t: a.drop_s, text: "Drop · " + fmt(a.drop_s), hi: true });
    const last = a.sections[a.sections.length - 1];
    if (last && last.kind !== "drop" && a.sections.length > 2) labels.push({ t: last.start_s, text: cap(last.kind) });
    renderWave($("wave-results"), { compVeil: true, drop: dropOf(a), cuts: a.sections.slice(1).map((s) => s.start_s), labels });
    $("heard").textContent = heardText();
    const sec = $("sections"); sec.replaceChildren();
    const h = document.createElement("div"); h.className = "r h"; h.innerHTML = "<span>At</span><span>Section</span><span>Bars</span>"; sec.appendChild(h);
    const fit = S.fits[S.fit] || { in_s: 0 };
    for (const s of a.sections) {
      const r = document.createElement("div");
      const inComp = D ? (s.end_s > fit.in_s && s.start_s < fit.in_s + D) : true;
      r.className = "r" + (s.kind === "drop" ? " drop" : "") + (!inComp ? " dim" : "");
      const c1 = document.createElement("span"); c1.textContent = fmt(s.start_s);
      const c2 = document.createElement("span"); c2.textContent = cap(s.kind) + (s.kind === "drop" && a.sections.filter((x) => x.kind === "drop").indexOf(s) > 0 ? " " + (a.sections.filter((x) => x.kind === "drop").indexOf(s) + 1) : "");
      const c3 = document.createElement("span"); c3.textContent = s.bars;
      r.append(c1, c2, c3); sec.appendChild(r);
    }
    const fits = $("fits"); fits.replaceChildren();
    $("fit-eyebrow").textContent = S.fits.length > 1 ? S.fits.length + " ways to fit " + fmt(D) : "Fit";
    S.fits.forEach((f, i) => {
      const lab = document.createElement("label"); lab.className = "radio";
      const inp = document.createElement("input"); inp.type = "radio"; inp.name = "fit"; inp.checked = i === S.fit; inp.onchange = () => { S.fit = i; renderResults(); A.setContext(contextText()); };
      const dot = document.createElement("span"); dot.className = "dot";
      const txt = document.createElement("span"); txt.innerHTML = "<span style=\"font-weight:600\"></span> — <span></span>";
      txt.children[0].textContent = f.label; txt.children[1].textContent = f.detail + ".";
      if (f.pick && S.fits.length > 1) { const p = document.createElement("span"); p.className = "pick"; p.textContent = "My pick"; txt.appendChild(p); }
      lab.append(inp, dot, txt); fits.appendChild(lab);
    });
    $$('[data-opt="markers2"] input').forEach((i) => { i.checked = i.value === S.opt.markers; });
  }
  function renderApplied() {
    const ap = S.applied, a = S.analysis; if (!ap || !a) return;
    const D = ap.until_s;                                  // seconds of song on the timeline, from in_s
    const inS = ap.in_s;
    const dropComp = ap.drop_marker ? a.drop_s + ap.offset_s : null;   // the comp time beat_control wrote the ♪ DROP at
    $("applied-sub").textContent = S.song.name + (inS > 0 ? " · from " + fmt(inS) + " of the song" : "") + (dropComp !== null ? " · drop at " + fmt(dropComp) : "") + " · " + ap.markers_written + " " + ap.markerKind + " markers";
    const labels = [];
    const sectionAt = a.sections.find((s) => s.start_s <= inS && s.end_s > inS);
    if (sectionAt) labels.push({ t: inS, text: cap(sectionAt.kind) });
    if (dropComp !== null) labels.push({ t: a.drop_s, text: "Drop · " + fmt(dropComp), hi: true });
    renderWave($("wave-applied"), { range: [inS, inS + D], labels, drop: dropOf(a), dropAsLine: true, bars: a.downbeats || [], axis: true, axisFrom: -ap.offset_s });   // axis in comp time
    const dl = $("donelist"); dl.replaceChildren();
    const lines = [ap.markers_written + " " + ap.markerKind + " markers on the comp"];
    if (dropComp !== null) lines.push("“♪ DROP” marker at " + fmt(dropComp));
    lines.push("BEAT null with Beat, Bar, Bass, Energy and BPM sliders");
    for (const w of ap.written || []) lines.push(w);
    for (const t of lines) { const d = document.createElement("div"); d.innerHTML = TICK.ok; const s = document.createElement("span"); s.textContent = t; d.appendChild(s); dl.appendChild(d); }
    renderWiring();
  }
  const STEMS = [
    { key: "kick", label: "Kick", on: "beat", level: 0.72 },
    { key: "bass", label: "Bass", on: "bass", level: 0.48 },
    { key: "energy", label: "Energy", on: "energy", level: 0.35 },
  ];
  const DRIVES = [
    ["punch", "Scale punch", "Scale"], ["opacity", "Opacity pulse", "Opacity"], ["shake", "Position shake", "Position"],
    ["zoom", "Slow zoom on bars", "Scale"], ["flash", "Flash above it", "Flash"],
  ];
  function targetLayers() {
    const skip = new Set(["BEAT", S.applied && S.applied.layerName].filter(Boolean));
    return S.layers.filter((l) => !skip.has(l.name) && !l.guide && l.kind !== "audio" && !/^FLASH \(/.test(l.name));
  }
  function renderWiring() {
    const el = $("wiring"); el.replaceChildren();
    const layers = targetLayers();
    if (!S.wiring.length) S.wiring = STEMS.map((s, i) => ({ stem: s.key, layer: layers[i] ? layers[i].index : 0, layerName: layers[i] ? layers[i].name : "", drive: i === 0 ? "punch" : i === 1 ? "opacity" : "zoom", feel: i === 0 ? "punch" : "smooth" }));
    STEMS.forEach((stem, i) => {
      const w = S.wiring[i];
      const st = document.createElement("span"); st.className = "stem"; st.innerHTML = "<b></b><span class=\"lvl\"><i></i></span>";
      st.querySelector("b").textContent = stem.label; st.querySelector("i").style.width = Math.round(stem.level * 100) + "%";
      const sel = document.createElement("select"); sel.className = "input";
      const none = document.createElement("option"); none.value = "0"; none.textContent = "Choose a layer…"; sel.appendChild(none);
      for (const l of layers) { const o = document.createElement("option"); o.value = String(l.index); o.textContent = l.name; sel.appendChild(o); }
      const cur = layers.find((x) => x.name === w.layerName);     // by name: indices shift when a layer is added above
      w.layer = cur ? cur.index : 0; if (!cur) w.layerName = "";
      sel.value = String(w.layer || 0);
      sel.onchange = () => { w.layer = Number(sel.value); const l = layers.find((x) => x.index === w.layer); w.layerName = l ? l.name : ""; };
      const drv = document.createElement("select"); drv.className = "input";
      for (const [v, t] of DRIVES) { const o = document.createElement("option"); o.value = v; o.textContent = t; drv.appendChild(o); }
      drv.value = w.drive; drv.onchange = () => { w.drive = drv.value; };
      const seg = document.createElement("div"); seg.className = "seg";
      for (const [v, t] of [["punch", "Punch"], ["smooth", "Smooth"]]) {
        const lab = document.createElement("label"); lab.className = "seg-opt";
        const inp = document.createElement("input"); inp.type = "radio"; inp.name = "feel-" + stem.key; inp.value = v; inp.checked = w.feel === v; inp.onchange = () => { w.feel = v; };
        lab.append(inp, document.createTextNode(t)); seg.appendChild(lab);
      }
      const mid = document.createElement("div"); mid.className = "mid"; mid.append(sel, drv);
      el.append(st, mid, seg);
    });
    syncSegs(el);
  }
  function renderSettings() {
    $("libdir").value = libDir();
    $("libdir-note").textContent = S.library.length + " track" + (S.library.length === 1 ? "" : "s") + " here";
  }
  function renderSuggestions() {
    const el = $("suggest"); el.replaceChildren();
    let tags = [];
    if (S.view === "empty" || S.view === "library") tags = ["What fits a 30 s ident?", "Which track has the most energy?"];
    else if (S.view === "track") tags = ["Where's the drop?", "Is this too slow for a 32 s cut?"];
    else if (S.view === "results") tags = ["Land the drop at 0:08", "Which section should the logo hit on?"];
    else if (S.view === "applied") tags = ["Bigger bump on the logo", "Ease the bass on the background"];
    for (const t of tags) { const s = document.createElement("span"); s.className = "tag tag-accent"; s.textContent = t; s.onclick = () => ask(t); el.appendChild(s); }
  }
  function contextText() {
    const c = S.comp ? S.comp.name + " " + S.comp.width + "x" + S.comp.height + " " + S.comp.fps + "fps " + fmt1(S.comp.duration_s) + "s" : "no comp";
    const parts = ["view=" + S.view, "comp=" + c, "library=" + S.library.length + " tracks"];
    if (S.song) parts.push("track=" + S.song.name + " (" + S.song.file + ")");
    if (S.analysis) parts.push("analysis: " + S.analysis.bpm + " BPM, " + S.analysis.bars + " bars, " + fmt1(S.analysis.duration_s) + " s, drop_s=" + S.analysis.drop_s + ", sections=" + S.analysis.sections.map((s) => s.kind + "@" + s.start_s).join(","));
    if (S.fits.length) parts.push("fit options=" + S.fits.map((f, i) => (i === S.fit ? "*" : "") + f.label + " in_s=" + f.in_s.toFixed(1)).join("; "));
    parts.push("options: markers=" + S.opt.markers + (S.opt.tempo ? " tempo override=" + S.opt.tempo : "") + (placedSong() ? " (the track is the user's own layer: it keeps its place and trim, range/offset do not apply)" : " range=" + S.opt.range + " offset_frames=" + S.opt.offset));
    if (S.applied) parts.push("applied: music layer '" + (S.applied.layerName || (S.song ? S.song.name + " (the user's own layer, left as placed)" : "?")) + "' in_s=" + S.applied.in_s + " offset_s=" + S.applied.offset_s + " markers=" + S.applied.markers_written + " " + S.applied.markerKind + (S.applied.drop_marker ? " + DROP" : "") + " written=" + (S.applied.written || []).join("|"));
    const feel = $("feel") && $("feel").value.trim(); if (feel) parts.push("feel asked for: " + feel);
    return parts.join("; ") + ". The user's clicks in the panel already ran the tools named here; do not redo them, build on them.";
  }

  // ------------------------------------------------------------ actions
  function pickSong(t, from) {
    if (S.busy) { note("notice", "Still " + S.busy + " — pick the next track when it's done."); return; }
    S.song = Object.assign({}, t, { from });
    S.analysis = null; S.fits = []; S.fit = 0; S.applied = null; S.wiring = []; S.opt.tempo = null;
    S.listenToken += 1;
    show("track");
  }
  const inflight = new Map();   // file → analysis promise, so Stop + Listen never runs the same file twice
  function analyze(file) {
    if (!inflight.has(file)) inflight.set(file, A.callTool("analyze_music", { song: file }).finally(() => inflight.delete(file)));
    return inflight.get(file);
  }
  async function listen(quick) {
    if (!S.song) return;
    const token = ++S.listenToken;
    S.listening = token;
    S.progress = 0; S.progressEvents = 0;
    show("listening");
    try {
      await refreshComp(false);                            // the comp may have changed since boot
      if (token !== S.listenToken) return;
      const a = await analyze(S.song.file);
      if (token !== S.listenToken) return;                 // stopped or another track picked
      S.listening = 0;
      S.analysis = a; S.progress = 100;
      S.fits = computeFits(); S.fit = Math.max(0, S.fits.findIndex((f) => f.pick));
      S.song.bpm = a.bpm; S.song.duration_s = a.duration_s;
      refreshLibrary(false);
      if (quick) { S.opt.markers = "bars"; show("results"); await apply(); return; }
      show("results");
      note("claude", heardText() + (S.fits.length > 1 ? " Pick a fit and I'll lay the markers." : ""));
    } catch (e) {
      if (token !== S.listenToken) return;
      S.listening = 0;
      show("track");
      note("error", "I couldn't listen to " + S.song.name + ": " + (e.message || e));
    } finally { if (S.listening === token) S.listening = 0; }
  }
  function apply() { return withBusy("putting it on the timeline", applyNow); }
  async function applyNow() {
    const a = S.analysis; if (!a) { note("error", "Listen to the track first."); return; }
    const song = S.song;
    await refreshComp(false);                              // the active comp right now, not the one from boot
    if (!S.comp) { note("error", "Open a comp in After Effects first."); return; }
    if (S.song !== song) return;                           // another track was picked meanwhile
    const fit = S.fits[S.fit] || { in_s: 0 };
    if (fit.gone) { note("error", fit.label + " — " + fit.detail + "."); return; }
    const D = compDur();
    const markers = S.opt.markers;                         // read once: the seg stays on screen during the awaits
    const whole = S.opt.range === "whole" && !fit.placed;  // a placed layer keeps its trim
    const offsetS = fit.placed ? 0 : (Number(S.opt.offset) || 0) / compFps();
    const kind = markers === "beats" ? "beat" : markers === "sections" ? "section" : "bar";
    const btn = $$('[data-act="apply"]')[0]; if (btn) { btn.disabled = true; btn.textContent = "Putting it on…"; }
    try {
      let am, from, until, layerName = null, layerIndex = null, untilS;
      if (fit.placed) {
        // the song is already on the timeline where the user put it: no second copy;
        // keys and markers run from its in point to its out point (or the comp's end)
        am = { offset_s: fit.offset_s }; from = fit.from_s; until = fit.until_s; untilS = fit.until_s - fit.offset_s - fit.in_s;
      } else {
        am = await A.callTool("add_music", { song: song.file, comp: S.comp.name, start_s: offsetS, in_s: fit.in_s, extend_comp: whole });
        layerName = am.item; layerIndex = am.layer; from = offsetS; until = whole ? undefined : D;
        untilS = whole ? a.duration_s - fit.in_s : Math.min(D - offsetS, a.duration_s - fit.in_s);
      }
      const bc = await A.callTool("beat_control", { song: song.file, comp: S.comp.name, offset_s: am.offset_s, markers, from_s: from, until_s: until });
      S.applied = { comp: S.comp.name, layerName, layerIndex, placed: !!fit.placed, in_s: fit.in_s, offset_s: am.offset_s, from_s: from, until_s: untilS,
        markers_written: bc.markers_written || 0, drop_marker: !!bc.drop_marker, markerKind: kind, written: [], expressions: [], extraLayers: [] };
      S.wiring = [];
      await refreshComp(false);
      show("applied");
      const dropComp = bc.drop_marker ? a.drop_s + am.offset_s : null;   // comp time, as written
      note("claude", "Done — " + song.name + (fit.placed ? " stays where it is on the timeline" : fit.in_s > 0 ? " opens at " + fmt(fit.in_s) + " of the song" : " starts from the top") + (dropComp !== null ? ", so the drop lands at " + fmt(dropComp) : "") + ". " + S.applied.markers_written + " " + kind + " markers are on the comp and the BEAT null is ready. Pick what each part of the music should drive, then write the expressions.");
    } catch (e) {
      note("error", "That didn't land: " + (e.message || e));
    } finally { if (btn) { btn.disabled = false; btn.textContent = "Put it on the timeline"; } }
  }
  function writeExpressions() { return withBusy("writing expressions", writeExpressionsNow); }
  async function writeExpressionsNow() {
    const ap = S.applied; if (!ap) return;
    // Flash rows add a solid above their layer, which shifts every index
    // below it: they go last, and every row is resolved by NAME against a
    // fresh layer list just before it is written. Undo remembers names too.
    const rows = S.wiring.filter((w) => w.layer && w.layerName).sort((x, y) => (x.drive === "flash") - (y.drive === "flash"));
    if (!rows.length) { note("notice", "Choose a layer for at least one of Kick, Bass or Energy first."); return; }
    const btn = $$('[data-act="write"]')[0]; if (btn) { btn.disabled = true; btn.textContent = "Writing…"; }
    const T = "ADBE Transform Group";
    try {
      for (const w of rows) {
        const stem = STEMS.find((s) => s.key === w.stem);
        const amount = w.drive === "punch" ? (w.feel === "punch" ? 8 : 4) : w.drive === "zoom" ? (w.feel === "punch" ? 6 : 3)
          : w.drive === "shake" ? (w.feel === "punch" ? 12 : 6) : (w.feel === "punch" ? 60 : 30);
        const ll = await A.callTool("list_layers", { comp: ap.comp });
        const cur = (ll.layers || []).find((l) => l.name === w.layerName);   // never by a stale index: that is the wrong layer
        if (!cur) throw new Error("'" + w.layerName + "' is no longer in " + ap.comp + ".");
        const r = await A.callTool("beat_effects", { layer: cur.index, comp: ap.comp, style: w.drive, on: stem.on, amount });
        const prop = w.drive === "shake" ? "ADBE Position" : w.drive === "opacity" ? "ADBE Opacity" : "ADBE Scale";
        if (w.drive === "flash") { if (r.solid_layer) ap.extraLayers.push("FLASH (" + r.on + ")"); }
        else ap.expressions.push({ layer: cur.name, path: [T, prop] });
        const drive = DRIVES.find((d) => d[0] === w.drive);
        ap.written.push(cur.name + " › " + drive[2] + ", driven by " + stem.label + (w.feel === "punch" ? ", punchy" : ", smoothed"));
      }
      await refreshComp(false);
      renderApplied();
      note("claude", "Written. " + ap.written.slice(-rows.length).join("; ") + ". Scrub it — if a bump feels big, tell me and I'll ease it.");
    } catch (e) { note("error", "An expression was refused: " + (e.message || e)); await refreshComp(false); renderApplied(); }
    finally { if (btn) { btn.disabled = false; btn.textContent = "Write expressions"; } }
  }
  function undoAll() { return withBusy("taking it back", undoAllNow); }
  async function undoAllNow() {
    const ap = S.applied; if (!ap) return;
    try {
      // only what the panel added: its music layer (never one the user placed), BEAT, its FLASH solids.
      // add_clip appends the music layer at the BOTTOM, so it is named by identity — name + the
      // startTime the panel gave it (offset_s), bottom-most on a tie — not by "first of that name".
      let music = null;
      if (ap.layerName) {
        const ll = await A.callTool("list_layers", { comp: ap.comp });
        const same = (ll.layers || []).filter((l) => l.name === ap.layerName && Math.abs(Number(l.start_s) - ap.offset_s) < 0.01);
        const pick = same[same.length - 1] || null;
        music = { name: ap.layerName, index: pick ? pick.index : ap.layerIndex, start_s: ap.offset_s };
      }
      const layers = (music ? [music] : []).concat(["BEAT"], ap.extraLayers);
      const r = await A.callTool("music_undo", { comp: ap.comp, layers, expressions: ap.expressions, clear_markers: true });
      S.applied = null; S.wiring = [];
      await refreshComp(false, ap.comp);                   // stay on the comp we were working in
      show("results");
      note("notice", "Taken back: " + (r.removed || []).join(", ") + (r.cleared ? ", " + r.cleared + " expression" + (r.cleared === 1 ? "" : "s") + " cleared" : "") + ", ♪ markers removed" + (ap.placed ? "; your audio layer stays." : "."));
    } catch (e) { note("error", "Undo hit a wall: " + (e.message || e)); }
  }
  function ask(text) {
    $("input").value = text;
    if (typeof window.submit === "function") window.submit(); else $("send").click();
  }
  async function useCompAudio() {
    await refreshComp(false);
    const rows = audioLayers().filter((l) => l.file);
    if (!rows.length) { note("notice", S.comp ? "There's no audio layer with a file in " + S.comp.name + " — put a song on the timeline or pick one from the library." : "Open a comp first."); return; }
    const l = rows.find((x) => !x.has_video) || rows[0];   // a music file before a clip's soundtrack
    pickSong({ name: l.name, file: l.file, ext: (l.file.match(/\.[a-z0-9]+$/i) || [""])[0], layer: l.index }, "comp");
  }
  async function changeLibDir() {
    const dir = window.prompt("Song library folder (empty = ~/Music/Claude Assistant):", S.libdir || "");
    if (dir === null) return;
    try { const r = await A.callTool("set_music_dir", { dir }); S.dirs = r.music_dirs || []; S.libdir = r.library_dir || ""; await refreshLibrary(false); renderAll(); }
    catch (e) { note("error", e.message || String(e)); }
  }
  function tapTempo() {
    const v = window.prompt("Tempo in BPM (empty = use what I detect):", S.opt.tempo || (S.analysis ? S.analysis.bpm : ""));
    if (v === null) return;
    const n = Number(v); S.opt.tempo = n > 20 && n < 400 ? Math.round(n * 10) / 10 : null;
    if (S.opt.tempo) note("notice", "Tempo override noted (" + S.opt.tempo + " BPM). The grid still comes from what I hear — tell me in the notes if the markers land off the beat and I'll shift them.");
    renderTrack();
  }

  document.addEventListener("click", (e) => {
    const t = e.target.closest("[data-act]"); if (!t) return;
    const act = t.dataset.act;
    if (act === "library") show("library");
    else if (act === "back") show(homeView());
    else if (act === "comp-audio") useCompAudio();
    else if (act === "listen") listen(false);
    else if (act === "quick") listen(true);
    else if (act === "stop") { S.listenToken += 1; S.listening = 0; show("track"); }
    else if (act === "apply") apply();
    else if (act === "write") writeExpressions();
    else if (act === "undo") undoAll();
    else if (act === "libdir") changeLibDir();
    else if (act === "tap") tapTempo();
  });
  document.addEventListener("change", (e) => {
    const seg = e.target.closest("[data-opt]"); if (!seg) return;
    const key = seg.dataset.opt === "markers2" ? "markers" : seg.dataset.opt;
    S.opt[key] = e.target.value;
    if (key === "markers") $$('[data-opt="markers"] input, [data-opt="markers2"] input').forEach((i) => { i.checked = i.value === e.target.value; });
    syncSegs();                                            // the mirrored seg in the other view too
    A.setContext(contextText());
  });
  $("offset").addEventListener("change", () => { S.opt.offset = Number($("offset").value) || 0; A.setContext(contextText()); });
  $$("[data-feel]").forEach((t) => { t.onclick = () => { const f = $("feel"); f.value = (f.value ? f.value.replace(/\s*$/, " ") : "") + t.textContent.toLowerCase(); A.setContext(contextText()); }; });
  $("libsearch").addEventListener("input", () => renderLibrary($("tracklist"), $("libsearch").value));
  $("libsearch2").addEventListener("input", () => renderLibrary($("tracklist2"), $("libsearch2").value));
  $("menubtn").onclick = () => show(S.view === "settings" ? homeView() : "settings");
  // After Effects has no "comp changed" event for a panel: read it again
  // whenever the user comes back to the panel (and before every action).
  window.addEventListener("focus", () => { if (!S.busy) refreshComp(true).catch(() => {}); });
  $("notes-toggle").onclick = () => { const n = $("notes"); n.classList.toggle("grown"); $("notes-toggle").textContent = n.classList.contains("grown") ? "Less" : "More"; };
  const dz = $("dropzone");
  dz.addEventListener("dragover", (e) => { e.preventDefault(); dz.classList.add("over"); });
  dz.addEventListener("dragleave", () => dz.classList.remove("over"));
  dz.addEventListener("drop", (e) => {
    e.preventDefault(); dz.classList.remove("over");
    const f = e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files[0];
    const p = f && (f.path || f.name);
    if (!p || !/\.(wav|mp3|m4a|aif|aiff|aac|flac|ogg|caf)$/i.test(p)) { note("notice", "Drop an audio file (wav, mp3, m4a, aif, flac…)."); return; }
    if (!f.path) { note("notice", "This host hands over only the file's name, not its path — copy it into the library folder instead."); return; }
    pickSong({ name: f.name.replace(/\.[^.]+$/, ""), file: f.path, ext: (p.match(/\.[a-z0-9]+$/i) || [""])[0] }, "drop");
  });

  // ------------------------------------------------------------ boot
  window.music = { state: S, show, refresh: () => Promise.all([refreshComp(false), refreshLibrary(false)]).then(renderAll) };
  document.addEventListener("DOMContentLoaded", () => window.music.refresh());
  if (document.readyState !== "loading") window.music.refresh();
})();
