// studio-sfx.js — minimal Web Audio SFX library.
// Generates short ear-friendly tones for stream events without any
// asset files. Exposes window.StudioSFX.play(name).

(function () {
  let ctx = null;
  function getCtx() {
    if (!ctx) {
      const AC = window.AudioContext || window.webkitAudioContext;
      if (!AC) return null;
      try { ctx = new AC(); } catch { return null; }
    }
    return ctx;
  }

  function envelope(gain, t0, peak, attack, decay) {
    gain.gain.setValueAtTime(0, t0);
    gain.gain.linearRampToValueAtTime(peak, t0 + attack);
    gain.gain.exponentialRampToValueAtTime(0.0001, t0 + attack + decay);
  }

  function tone(freq, duration, opts = {}) {
    const c = getCtx();
    if (!c) return;
    const t0 = c.currentTime + (opts.delay || 0);
    const osc = c.createOscillator();
    const gain = c.createGain();
    osc.type = opts.type || 'sine';
    osc.frequency.setValueAtTime(freq, t0);
    if (opts.bendTo) {
      osc.frequency.exponentialRampToValueAtTime(opts.bendTo, t0 + duration);
    }
    osc.connect(gain).connect(c.destination);
    envelope(gain, t0, opts.peak ?? 0.18, opts.attack ?? 0.005, duration);
    osc.start(t0);
    osc.stop(t0 + duration + 0.05);
  }

  const SOUNDS = {
    'event.subtrain': () => {
      // Crisp two-note rise
      tone(880,  0.10, { type: 'sine', peak: 0.16 });
      tone(1320, 0.22, { type: 'sine', peak: 0.18, delay: 0.08 });
    },
    'event.follow': () => {
      tone(660, 0.14, { type: 'triangle', peak: 0.14 });
      tone(990, 0.18, { type: 'triangle', peak: 0.14, delay: 0.07 });
    },
    'event.tip': () => {
      tone(1046, 0.14, { type: 'triangle', peak: 0.18 });           // C6
      tone(1318, 0.18, { type: 'triangle', peak: 0.18, delay: 0.1 });// E6
      tone(1568, 0.24, { type: 'triangle', peak: 0.18, delay: 0.2 });// G6
    },
    'event.cheer': () => {
      tone(740, 0.10, { type: 'sine', peak: 0.15 });
      tone(987, 0.16, { type: 'sine', peak: 0.15, delay: 0.07 });
    },
  };

  window.StudioSFX = {
    play(name) {
      const fn = SOUNDS[name];
      if (fn) fn();
    },
  };
})();
