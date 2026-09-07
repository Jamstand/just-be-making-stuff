// node bench_match.js — ΔE2000 benchmark of the Claude Assistant (Resolve
// panel) shot matcher on a known,
// camera-like colour shift, using the panel's OWN functions (deriveCdl,
// matchGate, displayPctToDi, diDecode) and the same pipeline model the tool
// assumes: display-referred grab -> stats -> CDL in DI-log -> re-measure.
// Scene: 24 ColorChecker patches (sRGB reference values) + a grey ramp +
// noise, rendered display-referred (Rec.709, gamma 2.4).
"use strict";
const tools = require("./tools.js");
const CC = [[115,82,68],[194,150,130],[98,122,157],[87,108,67],[133,128,177],[103,189,170],
  [214,126,44],[80,91,166],[193,90,99],[94,60,108],[157,188,64],[224,163,46],
  [56,61,150],[70,148,73],[175,54,60],[231,199,31],[187,86,149],[8,133,161],
  [243,243,242],[200,200,200],[160,160,160],[122,122,121],[85,85,85],[52,52,52]];
const g24 = (v) => Math.pow(Math.max(0, v), 2.4), ig24 = (l) => Math.pow(Math.max(0, l), 1 / 2.4);
const encDI = (lin) => tools.displayPctToDi(100 * ig24(lin));      // linear -> DI log
const decDI = (y) => tools.diDecode(y);                              // DI log -> linear
// pixel = [r,g,b] display-referred 0..1
function scene(seed) {
  let s = seed; const rnd = () => { s = (s * 1103515245 + 12345) & 0x7fffffff; return s / 0x7fffffff - 0.5; };
  const px = [];
  for (const p of CC) for (let k = 0; k < 400; k++) px.push(p.map((v) => Math.min(1, Math.max(0, v / 255 + 0.01 * rnd()))));
  for (let k = 0; k < 4000; k++) { const v = k / 4000; px.push([v, v, v].map((x) => Math.min(1, Math.max(0, x + 0.01 * rnd())))); }
  return px;
}
// camera-side disturbance in LINEAR light: exposure, white balance, contrast about 18% grey
function disturb(px, { stops = 0, wb = [1, 1, 1], contrast = 1, hueOnly = null }) {
  return px.map(([r, g, b]) => {
    let lin = [g24(r), g24(g), g24(b)].map((v, c) => v * Math.pow(2, stops) * wb[c]);
    lin = lin.map((v) => 0.18 * Math.pow(v / 0.18, contrast));
    if (hueOnly) {              // a hue-selective shift no global CDL can undo
      const [h, s, v] = tools.rgbToHsv ? tools.rgbToHsv(...lin) : [0, 0, 0];
      // fallback if rgbToHsv is not exported: approximate "greens" as g dominant
      const isGreen = lin[1] > lin[0] * 1.15 && lin[1] > lin[2] * 1.15;
      if (isGreen) lin = [lin[0] * hueOnly[0], lin[1] * hueOnly[1], lin[2] * hueOnly[2]];
    }
    return lin.map((v) => Math.min(1, ig24(v)));
  });
}
function stats(px) {
  return [0, 1, 2].map((c) => {
    let s = 0, q = 0; for (const p of px) { s += p[c]; q += p[c] * p[c]; }
    const m = s / px.length, sd = Math.sqrt(Math.max(0, q / px.length - m * m));
    return { mean_pct: +(100 * m).toFixed(2), std_pct: +(100 * sd).toFixed(2) };
  });
}
function applyCdl(px, cdl) {           // the Color-page node: DI log in, CDL, DI log out
  return px.map((p) => p.map((v, c) => {
    const y = encDI(g24(v)) * cdl.slope[c] + cdl.offset[c];
    return Math.min(1, Math.max(0, ig24(decDI(Math.max(0, y)))));
  }));
}
// CIEDE2000 on the 24 patch means (sRGB display values -> Lab, D65)
function lab(rgb) {
  const l = rgb.map((v) => g24(v));
  const [r, g, b] = l;
  const X = 0.4124 * r + 0.3576 * g + 0.1805 * b, Y = 0.2126 * r + 0.7152 * g + 0.0722 * b, Z = 0.0193 * r + 0.1192 * g + 0.9505 * b;
  const f = (t) => (t > 0.008856 ? Math.cbrt(t) : 7.787 * t + 16 / 116);
  const fx = f(X / 0.95047), fy = f(Y), fz = f(Z / 1.08883);
  return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
}
function de2000([L1, a1, b1], [L2, a2, b2]) {
  const C1 = Math.hypot(a1, b1), C2 = Math.hypot(a2, b2), Cb = (C1 + C2) / 2;
  const G = 0.5 * (1 - Math.sqrt(Math.pow(Cb, 7) / (Math.pow(Cb, 7) + Math.pow(25, 7))));
  const ap1 = a1 * (1 + G), ap2 = a2 * (1 + G), Cp1 = Math.hypot(ap1, b1), Cp2 = Math.hypot(ap2, b2);
  const h = (a, b) => { let t = Math.atan2(b, a) * 180 / Math.PI; return t < 0 ? t + 360 : t; };
  const hp1 = h(ap1, b1), hp2 = h(ap2, b2);
  const dL = L2 - L1, dC = Cp2 - Cp1;
  let dh = hp2 - hp1; if (Cp1 * Cp2 === 0) dh = 0; else if (dh > 180) dh -= 360; else if (dh < -180) dh += 360;
  const dH = 2 * Math.sqrt(Cp1 * Cp2) * Math.sin(dh / 2 * Math.PI / 180);
  const Lb = (L1 + L2) / 2, Cpb = (Cp1 + Cp2) / 2;
  let hb = hp1 + hp2; if (Cp1 * Cp2 !== 0) { if (Math.abs(hp1 - hp2) > 180) hb += hb < 360 ? 360 : -360; hb /= 2; } else hb = hp1 + hp2;
  const T = 1 - 0.17 * Math.cos((hb - 30) * Math.PI / 180) + 0.24 * Math.cos(2 * hb * Math.PI / 180) + 0.32 * Math.cos((3 * hb + 6) * Math.PI / 180) - 0.20 * Math.cos((4 * hb - 63) * Math.PI / 180);
  const Sl = 1 + 0.015 * (Lb - 50) ** 2 / Math.sqrt(20 + (Lb - 50) ** 2), Sc = 1 + 0.045 * Cpb, Sh = 1 + 0.015 * Cpb * T;
  const Rt = -2 * Math.sqrt(Math.pow(Cpb, 7) / (Math.pow(Cpb, 7) + Math.pow(25, 7))) * Math.sin(60 * Math.exp(-(((hb - 275) / 25) ** 2)) * Math.PI / 180);
  return Math.sqrt((dL / Sl) ** 2 + (dC / Sc) ** 2 + (dH / Sh) ** 2 + Rt * (dC / Sc) * (dH / Sh));
}
function patchMeans(px) { const out = []; for (let i = 0; i < 24; i++) { const s = px.slice(i * 400, i * 400 + 400); out.push([0, 1, 2].map((c) => s.reduce((t, p) => t + p[c], 0) / s.length)); } return out; }
function dE(refPx, px) { const a = patchMeans(refPx), b = patchMeans(px); const d = a.map((p, i) => de2000(lab(p), lab(b[i]))); return { mean: +(d.reduce((t, x) => t + x, 0) / 24).toFixed(2), max: +Math.max(...d).toFixed(2), skin: +((d[0] + d[1]) / 2).toFixed(2) }; }

// The tool's closed loop, exactly as match_shot composes it (max 3 rounds, stop < 0.75% residual)
function claudeMatch(refPx, tgtPx, maxIter = 3) {
  const ref = stats(refPx);
  const gate = tools.matchGate(ref, stats(tgtPx));
  if (gate.refuse) return { gate };
  let cdl = tools.deriveCdl(ref, stats(tgtPx)), cur = tgtPx, rounds = [];
  for (let i = 1; i <= maxIter; i++) {
    cur = applyCdl(tgtPx, cdl);
    const st = stats(cur);
    const resid = ref.map((rc, c) => +(rc.mean_pct - st[c].mean_pct).toFixed(2));
    rounds.push({ i, resid, dE: dE(refPx, cur) });
    if (Math.max(...resid.map(Math.abs)) < 0.75) break;
    const corr = tools.deriveCdl(ref, st);
    cdl = { slope: cdl.slope.map((sl, c) => Math.min(4, Math.max(0.25, sl * corr.slope[c]))),
            offset: cdl.offset.map((of, c) => of * corr.slope[c] + corr.offset[c]) };
  }
  return { gate, cdl: { slope: cdl.slope.map((v) => +v.toFixed(3)), offset: cdl.offset.map((v) => +v.toFixed(3)) }, rounds, result: cur };
}
const ref = scene(1);
const cases = {
  "A. -0.7 stop, warm WB (R×1.12 B×0.88)": { stops: -0.7, wb: [1.12, 1, 0.88] },
  "B. +0.5 stop, cool WB (R×0.9 B×1.15), contrast 0.85": { stops: 0.5, wb: [0.9, 1, 1.15], contrast: 0.85 },
  "C. tungsten vs daylight (R×1.35 G×1.05 B×0.62)": { stops: 0, wb: [1.35, 1.05, 0.62] },
  "D. 3 stops under (day vs dusk)": { stops: -3, wb: [1, 1, 1] },
  "E. greens only shifted (foliage cast, needs Region Match)": { stops: 0, wb: [1, 1, 1], hueOnly: [1.15, 0.95, 0.8] },
};
const rows = [];
for (const [name, d] of Object.entries(cases)) {
  const tgt = disturb(scene(2), d);
  const before = dE(ref, tgt);
  const m = claudeMatch(ref, tgt);
  if (m.gate.refuse) { rows.push({ case: name, before, verdict: "REFUSED: " + m.gate.reason.split(".")[0] }); continue; }
  const last = m.rounds[m.rounds.length - 1];
  rows.push({ case: name, before, after: last.dE, rounds: m.rounds.length, cdl: m.cdl, stops_apart: m.gate.stops_apart });
}
for (const r of rows) console.log(JSON.stringify(r));
