// node bench_match.js — ΔE2000 benchmark of the Claude Assistant (Resolve
// panel) colour tools on a known scene: a 24-patch ColorChecker + grey ramp
// rendered display-referred (Rec.709 gamma 2.4), disturbed camera-side in
// linear light, then measured/matched with the panel's OWN code path
// (writeTiff16 -> tiffStats -> fitCdl/runCdlLoop, hueMatchRecipe ->
// applyLook, balanceEstimate). The "Resolve node" is the same DI-log CDL
// model the tools assume; a live grab through the DRT can differ.
"use strict";
const tools = require("./tools.js");
const CC = [[115,82,68],[194,150,130],[98,122,157],[87,108,67],[133,128,177],[103,189,170],
  [214,126,44],[80,91,166],[193,90,99],[94,60,108],[157,188,64],[224,163,46],
  [56,61,150],[70,148,73],[175,54,60],[231,199,31],[187,86,149],[8,133,161],
  [243,243,242],[200,200,200],[160,160,160],[122,122,121],[85,85,85],[52,52,52]];
const g24 = (v) => Math.pow(Math.max(0, v), 2.4), ig24 = (l) => Math.pow(Math.max(0, l), 1 / 2.4);
const c01 = (v) => Math.min(1, Math.max(0, v));
const encDI = (lin) => tools.diEncode(lin), decDI = (y) => tools.diDecode(y);
function scene(seed) {
  let s = seed; const rnd = () => { s = (s * 1103515245 + 12345) & 0x7fffffff; return s / 0x7fffffff - 0.5; };
  const px = [];
  for (const p of CC) for (let k = 0; k < 400; k++) px.push(p.map((v) => c01(v / 255 + 0.01 * rnd())));
  for (let k = 0; k < 4000; k++) { const v = k / 4000; px.push([v, v, v].map((x) => c01(x + 0.01 * rnd()))); }
  return px;
}
function disturb(px, d) {
  return px.map(([r, g, b]) => {
    let lin = [g24(r), g24(g), g24(b)].map((v, c) => v * Math.pow(2, d.stops || 0) * (d.wb || [1, 1, 1])[c]);
    lin = lin.map((v) => 0.18 * Math.pow(v / 0.18, d.contrast || 1));
    if (d.hueOnly) { const isGreen = lin[1] > lin[0] * 1.15 && lin[1] > lin[2] * 1.15; if (isGreen) lin = lin.map((v, c) => v * d.hueOnly[c]); }
    if (d.sat !== undefined) { const l = 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]; lin = lin.map((v) => l + (v - l) * d.sat); }
    return lin.map((v) => c01(ig24(v)));
  });
}
// the panel's real measurement path
function measure(px) { return tools.measureBuffer(tools.writeTiff16(px, px.length, 1)); }
// the Color-page node: DI-log in, ASC CDL (slope, offset, power, sat), DI-log out
function applyCdl(px, m) {
  const sl = m.Slope.split(" ").map(Number), of = m.Offset.split(" ").map(Number), pw = m.Power.split(" ").map(Number), sat = Number(m.Saturation);
  return px.map((p) => {
    let o = p.map((v, c) => Math.pow(Math.max(0, encDI(g24(v)) * sl[c] + of[c]), pw[c]));
    if (sat !== 1) { const l = 0.2126 * o[0] + 0.7152 * o[1] + 0.0722 * o[2]; o = o.map((v) => l + (v - l) * sat); }
    return o.map((y) => c01(ig24(decDI(Math.max(0, y)))));
  });
}
function applyLut(px, look) { return px.map((p) => tools.applyLook(p.map((v) => encDI(g24(v))), look).map((y) => c01(ig24(decDI(y))))); }
const lab = tools.labOf, de2000 = tools.deltaE2000;   // the project's one perceptual yardstick
function patchMeans(px) { const out = []; for (let i = 0; i < 24; i++) { const s = px.slice(i * 400, i * 400 + 400); out.push([0, 1, 2].map((c) => s.reduce((t, p) => t + p[c], 0) / s.length)); } return out; }
function dE(refPx, px) { const a = patchMeans(refPx), b = patchMeans(px); const d = a.map((p, i) => de2000(lab(p), lab(b[i]))); return { mean: +(d.reduce((t, x) => t + x, 0) / 24).toFixed(2), max: +Math.max(...d).toFixed(2), skin: +((d[0] + d[1]) / 2).toFixed(2) }; }
const greyCast = (px) => { const m = patchMeans(px).slice(18); const rg = m.reduce((t, p) => t + (p[0] - p[1]), 0) / 6, bg = m.reduce((t, p) => t + (p[2] - p[1]), 0) / 6; return { r_minus_g_pct: +(100 * rg).toFixed(2), b_minus_g_pct: +(100 * bg).toFixed(2) }; };

module.exports = { scene, disturb, measure, applyCdl, applyLut, dE, patchMeans, greyCast, lab, de2000, CC };
if (require.main !== module) return;
(async () => {
  const ref = scene(1);
  const refM = measure(ref);
  const cases = {
    "A. -0.7 stop, warm WB (R×1.12 B×0.88)": { stops: -0.7, wb: [1.12, 1, 0.88] },
    "B. +0.5 stop, cool WB (R×0.9 B×1.15), contrast 0.85": { stops: 0.5, wb: [0.9, 1, 1.15], contrast: 0.85 },
    "C. tungsten vs daylight (R×1.35 G×1.05 B×0.62)": { stops: 0, wb: [1.35, 1.05, 0.62] },
    "C2. tungsten + 0.7 sat + contrast 1.2": { stops: 0, wb: [1.35, 1.05, 0.62], sat: 0.7, contrast: 1.2 },
    "D. 3 stops under (day vs dusk)": { stops: -3 },
    "E. greens only shifted (foliage cast)": { hueOnly: [1.15, 0.95, 0.8] },
    "E2. -0.4 stop, warm, AND greens shifted": { stops: -0.4, wb: [1.1, 1, 0.9], hueOnly: [1.15, 0.95, 0.8] },
  };
  console.log("== match_shot (new fitter + loop) then match_hues, ΔE2000 over 24 patches");
  for (const [name, d] of Object.entries(cases)) {
    const tgt = disturb(scene(2), d);
    const before = dE(ref, tgt);
    const gate = tools.matchGate(refM.stats, measure(tgt).stats);
    if (gate.refuse) { console.log(JSON.stringify({ case: name, before, verdict: "REFUSED: " + gate.reason.split(".")[0] })); continue; }
    let pending = null, current = tgt;
    const item = { GetName: () => "target", SetCDL: (m) => { pending = m; current = applyCdl(tgt, m); return true; } };
    const loop = await tools.runCdlLoop(refM, item, async () => measure(current), { tgt0: measure(tgt), nodeIndex: 1,
      maxIterations: Number(process.env.BENCH_ITER) || 3, power: process.env.BENCH_POWER !== "0", saturation: process.env.BENCH_SAT !== "0" });
    const afterGlobal = dE(ref, current);
    const row = { case: name, before, after_match_shot: afterGlobal, rounds: loop.iterations.length, converged: loop.converged, cdl: loop.final_cdl };
    // hue-selective residue -> LUT
    const curM = measure(current);
    const gap = Math.max(...refM.stats.map((c, i) => Math.max(Math.abs(c.mean_pct - curM.stats[i].mean_pct), Math.abs(c.pctl[4] - curM.stats[i].pctl[4]))));
    if (gap > 3) { row.after_match_hues = "refused: global gap " + gap.toFixed(1) + "% (match_shot did not converge)"; console.log(JSON.stringify(row)); continue; }
    const recipe = tools.hueMatchRecipe(refM.joint, curM.joint, {});
    if (process.env.BENCH_DEBUG) console.log("   recipe:", JSON.stringify(recipe.sectors));
    const verified = recipe.hue_adjustments.length ? tools.refineHueRecipe(refM.joint, curM.samples, recipe.hue_adjustments, {}) : { hue_adjustments: [] };
    if (verified.hue_adjustments.length) {
      const afterHue = dE(ref, applyLut(current, { hue_adjustments: verified.hue_adjustments }));
      row.after_match_hues = afterHue; row.hue_verify = { proposed: recipe.hue_adjustments.length, kept: verified.hue_adjustments.length, cost: verified.cost_before + " -> " + verified.cost_after };
      row.hue_sectors_adjusted = verified.hue_adjustments.map((h) => h.hue + "°:" + h.shift + "/" + h.sat + "/" + h.gain);
    } else row.after_match_hues = "nothing to do (" + recipe.hue_adjustments.length + " proposed, none survived simulation)";
    console.log(JSON.stringify(row));
  }
  {
    const tgt = disturb(scene(2), cases["E. greens only shifted (foliage cast)"]), mT = measure(tgt);
    const recipe = tools.hueMatchRecipe(refM.joint, mT.joint, {});
    const verified = tools.refineHueRecipe(refM.joint, mT.samples, recipe.hue_adjustments, {});
    console.log(JSON.stringify({ case: "E-hue-only. greens shifted, match_hues WITHOUT match_shot first", before: dE(ref, tgt),
      after_match_hues: dE(ref, applyLut(tgt, { hue_adjustments: verified.hue_adjustments })), kept: verified.hue_adjustments.length + "/" + recipe.hue_adjustments.length, evals: verified.evals }));
  }
  console.log("== auto_balance (no reference): cast on the six grey patches, exposure");
  for (const [name, d] of Object.entries({ "warm + 0.7 under": { stops: -0.7, wb: [1.18, 1, 0.82] }, "cool + 0.5 over": { stops: 0.5, wb: [0.88, 1, 1.2] }, "already neutral": {} })) {
    const tgt = disturb(scene(2), d);
    const m0 = measure(tgt);
    const est = tools.balanceEstimate({ channels: m0.stats, joint: m0.joint }, {});
    if (est.refuse) { console.log(JSON.stringify({ case: name, refused: est.reason })); continue; }
    const after = applyCdl(tgt, { Slope: "1 1 1", Offset: est.offset.join(" "), Power: "1 1 1", Saturation: "1" });
    const stopsLeft = Math.log2(g24(patchMeans(after)[21][1]) / g24(patchMeans(ref)[21][1]));
    console.log(JSON.stringify({ case: name, cast_before: greyCast(tgt), cast_after: greyCast(after), gains: est.gains, exposure_applied_stops: est.exposure_stops,
      grey_patch_vs_original_stops: +stopsLeft.toFixed(2), dE_vs_original: dE(ref, after) }));
  }
  console.log("== skin check on the two skin patches (dark/light skin), hue-rotated 12° toward red");
  const skinPx = scene(1).slice(0, 800);
  const rot = skinPx.map((p) => { const [h, s, v] = tools.rgbToHsv(...p); return tools.hsvToRgb((h - 12 + 360) % 360, s, v); });
  console.log(JSON.stringify({ original: measure(skinPx).joint.skin, rotated: measure(rot).joint.skin }));
})();
