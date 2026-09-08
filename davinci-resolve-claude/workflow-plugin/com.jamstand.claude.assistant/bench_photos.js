// node bench_photos.js <image.jpg|png> ... — the bench_match.js pipeline on
// real photographs: known camera-side shifts, the panel's own measure →
// fit → simulated-node loop → verified hue pass, scored as ΔE2000 over
// EVERY pixel (mean / p95) against the undisturbed frame. Needs jpeg-js /
// pngjs on NODE_PATH. Same caveat as bench_match: the tools' pipeline
// model, not a live Resolve grab.
"use strict";
const fs = require("fs"), path = require("path");
const tools = require("./tools.js");
const B = require("./bench_match.js");
const { disturb, measure, applyCdl, applyLut, lab, de2000 } = B;
function load(file, maxW) {
  const buf = fs.readFileSync(file);
  let w, h, data;
  if (/\.png$/i.test(file)) { const p = require("pngjs").PNG.sync.read(buf); w = p.width; h = p.height; data = p.data; }
  else { const j = require("jpeg-js").decode(buf, { useTArray: true }); w = j.width; h = j.height; data = j.data; }
  const s = Math.max(1, Math.ceil(w / (maxW || 320)));
  const W = Math.floor(w / s), H = Math.floor(h / s), px = [];
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    let r = 0, g = 0, b = 0;
    for (let dy = 0; dy < s; dy++) for (let dx = 0; dx < s; dx++) { const o = 4 * ((y * s + dy) * w + (x * s + dx)); r += data[o]; g += data[o + 1]; b += data[o + 2]; }
    px.push([r, g, b].map((v) => v / (255 * s * s)));
  }
  return { px, W, H };
}
function dE(a, b) {
  const d = new Float32Array(a.length);
  for (let i = 0; i < a.length; i++) d[i] = de2000(lab(a[i]), lab(b[i]));
  const sorted = Array.from(d).sort((x, y) => x - y);
  return { mean: +(sorted.reduce((t, v) => t + v, 0) / sorted.length).toFixed(2), p95: +sorted[Math.floor(0.95 * (sorted.length - 1))].toFixed(2) };
}
const crop = (img, x0, x1) => { const out = []; for (let y = 0; y < img.H; y++) for (let x = Math.floor(x0 * img.W); x < Math.floor(x1 * img.W); x++) out.push(img.px[y * img.W + x]); return out; };
async function matchShot(refPx, tgtPx) {
  const refM = measure(refPx), tgtM = measure(tgtPx);
  const gate = tools.matchGate(refM.stats, tgtM.stats);
  if (gate.refuse) return { refused: gate.reason.split(".")[0] };
  let current = tgtPx;
  const item = { GetName: () => "t", SetCDL: (m) => { current = applyCdl(tgtPx, m); return true; } };
  const loop = await tools.runCdlLoop(refM, item, async () => measure(current), { tgt0: tgtM, nodeIndex: 1, maxIterations: 3 });
  return { px: current, cdl: loop.final_cdl, rounds: loop.iterations.length, converged: loop.converged, refM };
}
function matchHues(refM, px) {
  const m = measure(px);
  const gap = Math.max(...refM.stats.map((c, i) => Math.max(Math.abs(c.mean_pct - m.stats[i].mean_pct), Math.abs(c.pctl[4] - m.stats[i].pctl[4]))));
  if (gap > 3) return { skipped: "global gap " + gap.toFixed(1) + "%" };
  const recipe = tools.hueMatchRecipe(refM.joint, m.joint, {});
  if (recipe.refused) return { skipped: "refused: " + recipe.refused.split(":")[0] };
  const v = tools.refineHueRecipe(refM.joint, m.samples, recipe.hue_adjustments, {});
  if (!v.hue_adjustments.length) return { skipped: "nothing survived simulation (" + recipe.hue_adjustments.length + " proposed)" };
  return { px: applyLut(px, { hue_adjustments: v.hue_adjustments }), kept: v.hue_adjustments.length + "/" + recipe.hue_adjustments.length };
}
const cases = {
  "A -0.7 stop, warm": { stops: -0.7, wb: [1.12, 1, 0.88] },
  "B +0.5 stop, cool, flat": { stops: 0.5, wb: [0.9, 1, 1.15], contrast: 0.85 },
  "C tungsten vs daylight": { wb: [1.35, 1.05, 0.62] },
  "C2 tungsten + sat 0.7 + contrast 1.2": { wb: [1.35, 1.05, 0.62], sat: 0.7, contrast: 1.2 },
  "E greens-only cast": { hueOnly: [1.15, 0.95, 0.8] },
};
(async () => {
  const files = process.argv.slice(2);
  const imgs = files.map((f) => ({ name: path.basename(f), img: load(f, 320) }));
  for (const { name, img } of imgs) {
    console.log("== " + name + " (" + img.W + "x" + img.H + ")");
    const ref = img.px;
    for (const [cname, d] of Object.entries(cases)) {
      const tgt = disturb(ref, d);
      const row = { case: cname, before: dE(ref, tgt) };
      if (d.hueOnly) {
        const h = matchHues(measure(ref), tgt);
        row.match_hues_alone = h.px ? dE(ref, h.px) : h.skipped;
        if (h.kept) row.kept = h.kept;
      }
      const ms = await matchShot(ref, tgt);
      if (ms.refused) { row.match_shot = ms.refused; console.log(JSON.stringify(row)); continue; }
      row.match_shot = dE(ref, ms.px); row.rounds = ms.rounds; row.converged = ms.converged;
      const h2 = matchHues(ms.refM, ms.px);
      row.then_match_hues = h2.px ? dE(ref, h2.px) : h2.skipped;
      console.log(JSON.stringify(row));
    }
    // Different framing: reference is the left 60%, target the right 60% (shifted A); truth = undisturbed right crop
    const left = crop(img, 0, 0.6), rightTrue = crop(img, 0.4, 1), right = disturb(rightTrue, cases["A -0.7 stop, warm"]);
    const ms = await matchShot(left, right);
    console.log(JSON.stringify({ case: "F different framing (left 60% vs right 60%), A shift", before: dE(rightTrue, right),
      match_shot: ms.refused ? ms.refused : dE(rightTrue, ms.px), rounds: ms.rounds, converged: ms.converged }));
    // Auto balance, no reference
    const warm = disturb(ref, { stops: -0.5, wb: [1.18, 1, 0.82] });
    const m0 = measure(warm);
    const est = tools.balanceEstimate({ channels: m0.stats, joint: m0.joint }, {});
    if (!est.refuse) {
      const bal = applyCdl(warm, { Slope: "1 1 1", Offset: est.offset.join(" "), Power: "1 1 1", Saturation: "1" });
      const mb = measure(bal);
      console.log(JSON.stringify({ case: "G auto_balance (warm, no reference)", neutral_cast_before: est.cast_before,
        neutral_cast_after: { r_minus_g_pct: +(mb.joint.neutral_mean_pct[0] - mb.joint.neutral_mean_pct[1]).toFixed(2), b_minus_g_pct: +(mb.joint.neutral_mean_pct[2] - mb.joint.neutral_mean_pct[1]).toFixed(2) },
        dE_vs_original_before: dE(ref, warm), dE_vs_original_after: dE(ref, bal), exposure_stops: est.exposure_stops }));
    } else console.log(JSON.stringify({ case: "G auto_balance", refused: est.reason }));
  }
  // Wrong use: different photos as reference/target
  if (imgs.length >= 2) {
    const a = imgs[0].img.px, b = imgs[1].img.px;
    const ms = await matchShot(a, b);
    const h = matchHues(measure(a), b);
    console.log(JSON.stringify({ case: "H different subjects (" + imgs[0].name + " -> " + imgs[1].name + ")",
      match_shot: ms.refused ? ms.refused : "ran: " + ms.rounds + " rounds, converged " + ms.converged + " (changes the look toward the reference's statistics)",
      match_hues: h.px ? "applied " + h.kept : h.skipped }));
  }
})();
