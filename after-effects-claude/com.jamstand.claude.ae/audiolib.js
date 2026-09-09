// Music for the AE panel: a song library, a beat/bass analyser, and the
// arithmetic that turns beats into cut lists. No native modules — the
// decoder is macOS's own afconvert (or ffmpeg where present), everything
// after that is plain JS on PCM samples. Testable under node.
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const { execFile } = require("child_process");

const SR = 22050;                 // analysis sample rate
const HOP = 512;                  // 23.2 ms per onset frame
const AUDIO_EXT = [".mp3", ".m4a", ".aac", ".wav", ".aif", ".aiff", ".mp4", ".mov", ".caf"];

// ------------------------------------------------------------ library
function defaultMusicDir() {
  return path.join(os.homedir(), "Music", "Claude Assistant");
}

function listSongs(dirs) {
  const out = [];
  for (const dir of dirs) {
    let names = [];
    try { names = fs.readdirSync(dir); } catch (e) { continue; }
    for (const n of names.sort()) {
      if (n.startsWith(".")) continue;
      const ext = path.extname(n).toLowerCase();
      if (!AUDIO_EXT.includes(ext)) continue;
      const file = path.join(dir, n);
      let st;
      try { st = fs.statSync(file); } catch (e) { continue; }
      if (!st.isFile()) continue;
      out.push({ name: path.basename(n, path.extname(n)), file, ext, size_mb: Math.round(st.size / 1048576 * 10) / 10 });
    }
  }
  return out;
}

function cacheKey(file) {
  const st = fs.statSync(file);
  return crypto.createHash("sha1").update(file + "|" + st.size + "|" + st.mtimeMs).digest("hex").slice(0, 16);
}

// ------------------------------------------------------------- decode
function which(name, extra) {
  const dirs = (process.env.PATH || "").split(path.delimiter).concat(extra || []);
  for (const d of dirs) {
    const p = path.join(d, name);
    try { if (fs.existsSync(p)) return p; } catch (e) {}
  }
  return null;
}

function run(cmd, args, opts) {
  return new Promise((resolve, reject) => {
    execFile(cmd, args, Object.assign({ windowsHide: true, maxBuffer: 8 << 20 }, opts || {}),
      (err, stdout, stderr) => err ? reject(new Error(cmd + " failed: " + (stderr || err.message).toString().slice(-400)))
                                   : resolve({ stdout: String(stdout), stderr: String(stderr) }));
  });
}

// -> path of a mono 16-bit 22.05 kHz WAV (the input itself if it is a WAV).
async function decodeToWav(file, cacheDir, opts) {
  opts = opts || {};
  const ext = path.extname(file).toLowerCase();
  if (ext === ".wav") return file;
  fs.mkdirSync(cacheDir, { recursive: true });
  const out = path.join(cacheDir, cacheKey(file) + ".wav");
  if (fs.existsSync(out) && fs.statSync(out).size > 44) return out;
  const exec = opts.run || run;
  if (process.platform === "darwin" || opts.afconvert) {
    const af = opts.afconvert || "afconvert";
    try {
      await exec(af, ["-f", "WAVE", "-d", "LEI16@" + SR, "-c", "1", file, out]);
    } catch (e) {
      await exec(af, ["-f", "WAVE", "-d", "LEI16@" + SR, file, out]);   // older afconvert: no -c
    }
    return out;
  }
  const ff = opts.ffmpeg || which(process.platform === "win32" ? "ffmpeg.exe" : "ffmpeg",
                                  ["/opt/homebrew/bin", "/usr/local/bin"]);
  if (ff) {
    await exec(ff, ["-y", "-loglevel", "error", "-i", file, "-ac", "1", "-ar", String(SR), "-f", "wav", out]);
    return out;
  }
  throw new Error("Cannot decode " + ext + " here: no afconvert (macOS) or ffmpeg on PATH. "
    + "Convert the song to WAV, or install ffmpeg.");
}

// ---------------------------------------------------------------- WAV
function parseWav(buf) {
  if (buf.length < 12 || buf.toString("ascii", 0, 4) !== "RIFF" || buf.toString("ascii", 8, 12) !== "WAVE")
    throw new Error("not a WAV file");
  let off = 12, fmt = null, data = null;
  while (off + 8 <= buf.length) {
    const id = buf.toString("ascii", off, off + 4);
    const size = buf.readUInt32LE(off + 4);
    const body = off + 8;
    if (id === "fmt ") {
      fmt = { format: buf.readUInt16LE(body), channels: buf.readUInt16LE(body + 2),
              sampleRate: buf.readUInt32LE(body + 4), bits: buf.readUInt16LE(body + 14) };
      if (fmt.format === 0xFFFE && size >= 26) fmt.format = buf.readUInt16LE(body + 24); // extensible
    } else if (id === "data") {
      data = { start: body, size: Math.min(size, buf.length - body) };
    }
    off = body + size + (size & 1);
  }
  if (!fmt || !data) throw new Error("WAV without fmt/data chunks");
  if (fmt.format !== 1 && fmt.format !== 3) throw new Error("unsupported WAV encoding " + fmt.format);
  const bytes = fmt.bits / 8;
  const frames = Math.floor(data.size / (bytes * fmt.channels));
  const mono = new Float32Array(frames);
  for (let i = 0; i < frames; i++) {
    let acc = 0;
    for (let c = 0; c < fmt.channels; c++) {
      const p = data.start + (i * fmt.channels + c) * bytes;
      let v;
      if (fmt.format === 3) v = bytes === 4 ? buf.readFloatLE(p) : buf.readDoubleLE(p);
      else if (bytes === 1) v = (buf[p] - 128) / 128;
      else if (bytes === 2) v = buf.readInt16LE(p) / 32768;
      else if (bytes === 3) v = (((buf[p] | (buf[p + 1] << 8) | (buf[p + 2] << 16)) << 8) >> 8) / 8388608;
      else v = buf.readInt32LE(p) / 2147483648;
      acc += v;
    }
    mono[i] = acc / fmt.channels;
  }
  return { sampleRate: fmt.sampleRate, channels: fmt.channels, bits: fmt.bits, samples: mono };
}

function writeWav(samples, sampleRate) {     // 16-bit mono; used by tests and fakes
  const n = samples.length;
  const buf = Buffer.alloc(44 + n * 2);
  buf.write("RIFF", 0); buf.writeUInt32LE(36 + n * 2, 4); buf.write("WAVE", 8);
  buf.write("fmt ", 12); buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20); buf.writeUInt16LE(1, 22);
  buf.writeUInt32LE(sampleRate, 24); buf.writeUInt32LE(sampleRate * 2, 28); buf.writeUInt16LE(2, 32);
  buf.writeUInt16LE(16, 34); buf.write("data", 36); buf.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) buf.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round(samples[i] * 32767))), 44 + i * 2);
  return buf;
}

function resample(samples, from, to) {
  if (from === to) return samples;
  const ratio = from / to;
  const n = Math.floor(samples.length / ratio);
  const out = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    const x = i * ratio, j = Math.floor(x), f = x - j;
    out[i] = samples[j] * (1 - f) + (samples[Math.min(j + 1, samples.length - 1)] || 0) * f;
  }
  return out;
}

// ---------------------------------------------------------------- DSP
function biquad(x, sr, fc, kind) {            // RBJ cookbook, Q = 0.707
  const w0 = 2 * Math.PI * fc / sr, cw = Math.cos(w0), al = Math.sin(w0) / (2 * 0.7071);
  let b0, b1, b2;
  if (kind === "low") { b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = (1 - cw) / 2; }
  else { b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = (1 + cw) / 2; }
  const a0 = 1 + al, a1 = -2 * cw, a2 = 1 - al;
  const y = new Float32Array(x.length);
  let x1 = 0, x2 = 0, y1 = 0, y2 = 0;
  for (let i = 0; i < x.length; i++) {
    const v = (b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0;
    x2 = x1; x1 = x[i]; y2 = y1; y1 = v; y[i] = v;
  }
  return y;
}

function hopRms(x) {
  const n = Math.floor(x.length / HOP);
  const out = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    let s = 0;
    for (let j = i * HOP; j < (i + 1) * HOP; j++) s += x[j] * x[j];
    out[i] = Math.sqrt(s / HOP);
  }
  return out;
}

function onsetEnvelope(e) {                  // rectified log-energy difference, lightly smoothed
  const o = new Float32Array(e.length);
  for (let i = 1; i < e.length; i++) {
    const d = Math.log10(e[i] + 1e-6) - Math.log10(e[i - 1] + 1e-6);
    o[i] = d > 0 ? d : 0;
  }
  const s = new Float32Array(e.length);
  for (let i = 0; i < e.length; i++) s[i] = (o[i] + (o[i - 1] || 0) + (o[i + 1] || 0)) / 3;
  return s;
}

function stats(a) {
  let m = 0; for (const v of a) m += v; m /= a.length || 1;
  let v = 0; for (const x of a) v += (x - m) * (x - m); v = Math.sqrt(v / (a.length || 1));
  return { mean: m, std: v };
}

// Autocorrelation of the onset envelope with a log-normal prior around
// 120 BPM (Ellis 2007), then the half/double sanity check.
function estimateTempo(onset, hopSec) {
  const { mean } = stats(onset);
  const x = Array.from(onset, (v) => v - mean);
  const n = x.length;
  const minLag = Math.max(2, Math.round(60 / 220 / hopSec)), maxLag = Math.min(n - 1, Math.round(60 / 55 / hopSec));
  const score = new Map();
  let best = { lag: 0, score: -Infinity };
  for (let lag = minLag; lag <= maxLag; lag++) {
    let s = 0;
    for (let i = lag; i < n; i++) s += x[i] * x[i - lag];
    s /= (n - lag);
    const bpm = 60 / (lag * hopSec);
    const prior = Math.exp(-0.5 * Math.pow(Math.log2(bpm / 120), 2));
    const sc = s * prior;
    score.set(lag, sc);
    if (sc > best.score) best = { lag, score: sc };
  }
  if (!best.lag) return { bpm: 120, lagHops: 60 / 120 / hopSec, confidence: 0 };
  // parabolic refinement of the lag
  let lag = best.lag;
  const y0 = score.get(lag - 1), y1 = score.get(lag), y2 = score.get(lag + 1);
  if (y0 !== undefined && y2 !== undefined) {
    const d = (y0 - y2) / (2 * (y0 - 2 * y1 + y2) || 1);
    if (isFinite(d) && Math.abs(d) < 1) lag += d;
  }
  let bpm = 60 / (lag * hopSec);
  // prefer the 80–170 range when the alternative octave is nearly as strong
  const alt = (mult) => { const l = Math.round(best.lag * mult); return score.has(l) ? score.get(l) : -Infinity; };
  if (bpm < 80 && alt(0.5) > 0.6 * best.score) { bpm *= 2; lag /= 2; }
  else if (bpm > 170 && alt(2) > 0.6 * best.score) { bpm /= 2; lag *= 2; }
  const { std } = stats(Array.from(score.values()));
  return { bpm, lagHops: lag, confidence: std > 0 ? Math.min(1, best.score / (3 * std)) : 0 };
}

// Dynamic-programming beat tracker (Ellis 2007): every beat is one period
// after the previous one, give or take, wherever the onsets are strongest.
function trackBeats(onset, period, tightness) {
  tightness = tightness || 300;
  const n = onset.length;
  const { mean, std } = stats(onset);
  const local = Array.from(onset, (v) => (v - mean) / (std || 1));
  const score = new Float64Array(n), back = new Int32Array(n).fill(-1);
  const pmin = Math.max(1, Math.round(period / 2)), pmax = Math.round(period * 2);
  for (let i = 0; i < n; i++) {
    let best = -Infinity, bi = -1;
    for (let p = pmin; p <= pmax; p++) {
      const j = i - p;
      if (j < 0) break;
      const s = score[j] - tightness * Math.pow(Math.log(p / period), 2);
      if (s > best) { best = s; bi = j; }
    }
    score[i] = local[i] + (bi >= 0 ? best : 0);
    back[i] = bi;
  }
  let end = -1, bestS = -Infinity;
  for (let i = Math.max(0, n - Math.round(period * 1.5)); i < n; i++)
    if (score[i] > bestS) { bestS = score[i]; end = i; }
  const beats = [];
  for (let i = end; i >= 0; i = back[i]) { beats.push(i); if (back[i] < 0) break; }
  return beats.reverse();
}

function pickPeaks(env, hopSec, opts) {
  const minGap = Math.max(1, Math.round((opts.minGapSec || 0.11) / hopSec));
  const win = Math.round((opts.windowSec || 1) / hopSec);
  const peaks = [];
  let gmax = 0; for (const v of env) if (v > gmax) gmax = v;
  for (let i = 1; i < env.length - 1; i++) {
    if (!(env[i] >= env[i - 1] && env[i] > env[i + 1])) continue;
    if (env[i] < gmax * 0.08) continue;
    const lo = Math.max(0, i - win), hi = Math.min(env.length, i + win);
    const { mean, std } = stats(env.subarray(lo, hi));
    if (env[i] < mean + (opts.k || 1.5) * std) continue;
    if (peaks.length && i - peaks[peaks.length - 1].i < minGap) {
      if (env[i] > peaks[peaks.length - 1].v) peaks[peaks.length - 1] = { i, v: env[i] };
      continue;
    }
    peaks.push({ i, v: env[i] });
  }
  const vals = peaks.map((p) => p.v).sort((a, b) => a - b);
  const p95 = vals.length ? vals[Math.floor(vals.length * 0.95)] || vals[vals.length - 1] : 1;
  return peaks.map((p) => ({ t: p.i * hopSec, strength: Math.min(1, p.v / (p95 || 1)) }));
}

// ------------------------------------------------------------ analyse
function analyze(samplesIn, sampleRate, opts) {
  opts = opts || {};
  const x = resample(samplesIn, sampleRate, SR);
  const hopSec = HOP / SR;
  const duration = x.length / SR;
  const bassSig = biquad(biquad(x, SR, 150, "low"), SR, 150, "low");
  const full = hopRms(x), bass = hopRms(bassSig);
  const onset = onsetEnvelope(full), bassOnset = onsetEnvelope(bass);
  // mix: bass drives the pulse, full-band keeps hats/snare in the picture
  const mixed = new Float32Array(onset.length);
  for (let i = 0; i < onset.length; i++) mixed[i] = onset[i] + 1.5 * bassOnset[i];
  const tempo = estimateTempo(mixed, hopSec);
  const beatIdx = trackBeats(mixed, tempo.lagHops, opts.tightness);
  const beats = beatIdx.map((i) => Math.round(i * hopSec * 1000) / 1000);
  // downbeats: the phase (of 4) whose beats carry the most bass onset
  let phase = 0, phaseScore = -Infinity;
  for (let p = 0; p < 4; p++) {
    let s = 0, c = 0;
    for (let k = p; k < beatIdx.length; k += 4) { s += bassOnset[beatIdx[k]] + 0.5 * onset[beatIdx[k]]; c++; }
    if (c && s / c > phaseScore) { phaseScore = s / c; phase = p; }
  }
  const downbeats = beats.filter((_, k) => k % 4 === phase);
  const bassHits = pickPeaks(bassOnset, hopSec, { k: 1.5, minGapSec: 0.11, windowSec: 1.0 });
  // energy per bar (relative to the loudest bar, not the loudest transient),
  // sections, drop
  const barEnergy = [];
  for (let k = 0; k + 1 < downbeats.length; k++) {
    const a = Math.round(downbeats[k] / hopSec), b = Math.round(downbeats[k + 1] / hopSec);
    let s = 0, c = 0;
    for (let i = a; i < b && i < full.length; i++) { s += full[i]; c++; }
    barEnergy.push({ start_s: downbeats[k], end_s: downbeats[k + 1], energy: c ? s / c : 0 });
  }
  const barMax = Math.max(1e-9, ...barEnergy.map((b) => b.energy));
  for (const b of barEnergy) b.energy /= barMax;
  const label = (e) => e >= 0.7 ? "high" : e >= 0.42 ? "mid" : "low";
  const sections = [];
  for (const bar of barEnergy) {
    const l = label(bar.energy);
    const last = sections[sections.length - 1];
    if (last && last.label === l) { last.end_s = bar.end_s; last.bars += 1; last.energy = (last.energy * (last.bars - 1) + bar.energy) / last.bars; }
    else sections.push({ start_s: bar.start_s, end_s: bar.end_s, label: l, bars: 1, energy: bar.energy });
  }
  for (const s of sections) s.energy = Math.round(s.energy * 100) / 100;
  // the drop: first sustained high section that follows something lower
  let dropS = null;
  for (let i = 0; i < sections.length; i++) {
    const s = sections[i];
    if (s.label === "high" && s.bars >= 2 && (i === 0 ? false : sections[i - 1].label !== "high")) { dropS = s.start_s; break; }
  }
  if (dropS === null) { const hi = sections.find((s) => s.label === "high"); dropS = hi ? hi.start_s : null; }
  sections.forEach((s, i) => {
    if (s.label === "high") s.kind = "drop";
    else if (i === 0) s.kind = "intro";
    else if (dropS !== null && s.end_s <= dropS + 1e-6 && s.label === "mid") s.kind = "build";
    else s.kind = s.label === "low" ? "quiet" : "verse";
  });
  const energyCurve = [];
  const step = 0.25;
  for (let t = 0; t < duration; t += step) {
    const a = Math.round(t / hopSec), b = Math.min(full.length, Math.round((t + step) / hopSec));
    let s = 0, c = 0;
    for (let i = a; i < b; i++) { s += full[i]; c++; }
    energyCurve.push(c ? s / c : 0);
  }
  const curveMax = Math.max(1e-9, ...energyCurve);
  for (let i = 0; i < energyCurve.length; i++) energyCurve[i] = Math.round(energyCurve[i] / curveMax * 100) / 100;
  // A 110-bucket RMS envelope for the panel's waveform strip (0..1).
  const wave = [];
  const WB = 110;
  for (let k = 0; k < WB; k++) {
    const a = Math.floor(k * full.length / WB), b = Math.max(a + 1, Math.floor((k + 1) * full.length / WB));
    let s = 0, c = 0;
    for (let i = a; i < b && i < full.length; i++) { s += full[i]; c++; }
    wave.push(c ? s / c : 0);
  }
  const waveMax = Math.max(1e-9, ...wave);
  for (let i = 0; i < wave.length; i++) wave[i] = Math.round(wave[i] / waveMax * 100) / 100;
  return {
    v: 2, wave,
    duration_s: Math.round(duration * 1000) / 1000, bpm: Math.round(tempo.bpm * 10) / 10,
    tempo_confidence: Math.round(tempo.confidence * 100) / 100,
    beat_s: Math.round(60 / tempo.bpm * 1000) / 1000, beats, downbeats,
    downbeat_phase: phase, bass_hits: bassHits.map((h) => ({ t: Math.round(h.t * 1000) / 1000,
      strength: Math.round(h.strength * 100) / 100 })),
    sections, drop_s: dropS, energy_step_s: step, energy: energyCurve,
  };
}

// --------------------------------------------------------------- cuts
// Cut list on the grid: each cut lasts pattern[k] beats (or bars), starting
// at the first grid point at/after startS; stops at the grid's end or maxEnd.
function planCuts(grid, pattern, startS, count, maxEnd) {
  pattern = (pattern && pattern.length ? pattern : [4, 4, 2, 2, 1, 1, 1, 1]).map((n) => Math.max(1, Math.round(n)));
  let gi = grid.findIndex((t) => t >= (startS || 0) - 1e-6);
  if (gi < 0) return [];
  const cuts = [];
  for (let k = 0; k < count; k++) {
    const n = pattern[k % pattern.length];
    const ei = gi + n;
    if (ei >= grid.length) break;
    const s = grid[gi], e = grid[ei];
    if (maxEnd && e > maxEnd + 1e-6) break;
    cuts.push({ start_s: s, end_s: e, beats: n });
    gi = ei;
  }
  return cuts;
}

function nearestGrid(t, grid) {
  let best = null, bd = Infinity;
  for (const g of grid) { const d = Math.abs(g - t); if (d < bd) { bd = d; best = g; } }
  return best;
}

module.exports = { SR, HOP, AUDIO_EXT, defaultMusicDir, listSongs, cacheKey, decodeToWav,
  parseWav, writeWav, resample, analyze, planCuts, nearestGrid, estimateTempo, trackBeats };
