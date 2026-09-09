#!/usr/bin/env node
// Headless tests for audiolib.js: WAV parsing, decode routing, and the
// beat/bass analyser on a synthesised track whose beats we know exactly.
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const audio = require("./com.jamstand.claude.ae/audiolib.js");

let failures = 0;
function check(label, ok, detail) {
  if (ok) console.log("  ok  " + label);
  else { failures += 1; console.log("FAIL  " + label + "  " + (detail || "")); }
}
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ca-audio-"));

// A 24-second "track" at 128 BPM: kick (60 Hz burst) on every beat, the bar's
// first kick louder, snare-ish noise on 2 and 4, a quiet intro for the first
// 4 bars (no kick, pad only), then full drums = the "drop" at bar 5.
function synth(sr, bpm, seconds, firstBeat) {
  const n = Math.floor(sr * seconds);
  const x = new Float32Array(n);
  const beat = 60 / bpm;
  let seed = 7;
  const rnd = () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff - 0.5; };
  for (let i = 0; i < n; i++) x[i] = 0.02 * Math.sin(2 * Math.PI * 220 * i / sr) + 0.004 * rnd();   // pad + hiss
  const kicks = [];
  for (let k = 0; ; k++) {
    const t = firstBeat + k * beat;
    if (t >= seconds) break;
    const bar = Math.floor(k / 4), inBar = k % 4;
    if (bar < 4) continue;                                     // intro: no drums
    const amp = inBar === 0 ? 0.9 : 0.6;
    const s0 = Math.round(t * sr);
    for (let j = 0; j < Math.round(0.09 * sr); j++) {
      const env = Math.exp(-j / (0.03 * sr));
      x[s0 + j] += amp * env * Math.sin(2 * Math.PI * 60 * j / sr);
    }
    kicks.push({ t, downbeat: inBar === 0 });
    if (inBar === 1 || inBar === 3)
      for (let j = 0; j < Math.round(0.05 * sr); j++) x[s0 + j] += 0.25 * Math.exp(-j / (0.02 * sr)) * rnd();
  }
  return { samples: x, kicks, beat };
}

(async () => {
  const sr = 22050;
  const { samples, kicks, beat } = synth(sr, 128, 24, 0.31);
  const wav = audio.writeWav(samples, sr);
  const parsed = audio.parseWav(wav);
  check("parseWav: 16-bit mono round trip", parsed.sampleRate === sr && parsed.channels === 1
    && parsed.samples.length === samples.length && Math.abs(parsed.samples[1000] - samples[1000]) < 1e-3);
  // stereo 24-bit hand-built header
  const st = Buffer.alloc(44 + 6 * 4);
  st.write("RIFF", 0); st.writeUInt32LE(36 + 24, 4); st.write("WAVE", 8); st.write("fmt ", 12);
  st.writeUInt32LE(16, 16); st.writeUInt16LE(1, 20); st.writeUInt16LE(2, 22); st.writeUInt32LE(48000, 24);
  st.writeUInt32LE(48000 * 6, 28); st.writeUInt16LE(6, 32); st.writeUInt16LE(24, 34); st.write("data", 36); st.writeUInt32LE(24, 40);
  for (let i = 0; i < 4; i++) for (let c = 0; c < 2; c++) { const v = (c ? -1 : 1) * 0x400000; const p = 44 + (i * 2 + c) * 3; st[p] = v & 255; st[p + 1] = (v >> 8) & 255; st[p + 2] = (v >> 16) & 255; }
  const p24 = audio.parseWav(st);
  check("parseWav: 24-bit stereo downmixes to mono", p24.channels === 2 && p24.samples.length === 4 && Math.abs(p24.samples[0]) < 1e-6, JSON.stringify(Array.from(p24.samples)));
  let threw = null; try { audio.parseWav(Buffer.from("not a wav file at all")); } catch (e) { threw = e.message; }
  check("parseWav: rejects non-WAV", /not a WAV/.test(threw), threw);

  const t0 = Date.now();
  const a = audio.analyze(parsed.samples, parsed.sampleRate);
  const ms = Date.now() - t0;
  check("analyze: tempo within 1 BPM of 128 (" + a.bpm + ") in " + ms + " ms", Math.abs(a.bpm - 128) <= 1, JSON.stringify({ bpm: a.bpm, conf: a.tempo_confidence }));
  // beats vs known kicks (in the drums section)
  const kickTimes = kicks.map((k) => k.t);
  const drumBeats = a.beats.filter((t) => t >= kickTimes[0] - 0.05);
  const errs = drumBeats.map((t) => Math.min(...kickTimes.map((k) => Math.abs(k - t))));
  const within = errs.filter((e) => e <= 0.035).length / (errs.length || 1);
  check("analyze: " + Math.round(within * 100) + "% of beats within 35 ms of a kick, " + drumBeats.length + " beats over " + kickTimes.length + " kicks",
    within >= 0.9 && Math.abs(drumBeats.length - kickTimes.length) <= 2, JSON.stringify(errs.slice(0, 8)));
  const dbErr = a.downbeats.filter((t) => t >= kickTimes[0] - 0.05).map((t) =>
    Math.min(...kicks.filter((k) => k.downbeat).map((k) => Math.abs(k.t - t))));
  check("analyze: downbeats land on the accented kicks", dbErr.length >= 4 && dbErr.filter((e) => e <= 0.035).length / dbErr.length >= 0.9, JSON.stringify(dbErr.slice(0, 6)));
  const hitErr = a.bass_hits.map((h) => Math.min(...kickTimes.map((k) => Math.abs(k - h.t))));
  const hitsOnKicks = hitErr.filter((e) => e <= 0.035).length;
  check("analyze: bass hits = the kicks (" + hitsOnKicks + "/" + a.bass_hits.length + " on a kick, " + kickTimes.length + " kicks)",
    hitsOnKicks >= kickTimes.length * 0.9 && a.bass_hits.length <= kickTimes.length + 3, JSON.stringify(a.bass_hits.slice(0, 5)));
  const strongOnDown = a.bass_hits.filter((h) => kicks.some((k) => k.downbeat && Math.abs(k.t - h.t) <= 0.035)).map((h) => h.strength);
  const strongOnOther = a.bass_hits.filter((h) => kicks.some((k) => !k.downbeat && Math.abs(k.t - h.t) <= 0.035)).map((h) => h.strength);
  const avg = (v) => v.reduce((s, x) => s + x, 0) / (v.length || 1);
  check("analyze: accented kicks score stronger than the rest", avg(strongOnDown) > avg(strongOnOther), JSON.stringify([avg(strongOnDown), avg(strongOnOther)]));
  const firstDrum = kickTimes[0];
  check("analyze: the drop is found where the drums start (" + a.drop_s + " vs " + firstDrum.toFixed(2) + ")",
    a.drop_s !== null && Math.abs(a.drop_s - firstDrum) <= beat * 1.05, JSON.stringify(a.sections));
  check("analyze: sections labelled intro/build/drop and energy curve sane",
    a.sections.length >= 2 && a.sections[0].kind === "intro" && a.sections.some((s) => s.kind === "drop")
    && a.energy.length === Math.ceil(24 / 0.25) && Math.max(...a.energy) === 1, JSON.stringify(a.sections.map((s) => s.kind)));

  check("analyze: 110-bucket waveform envelope, normalised, version 2", a.v === 2 && a.wave.length === 110 && Math.max(...a.wave) === 1
    && a.wave.slice(0, 15).every((w) => w < 0.3) && a.wave.slice(40, 60).some((w) => w > 0.6), JSON.stringify(a.wave.slice(0, 20)));

  // resample path (44.1k input)
  const up = audio.resample(parsed.samples, sr, 44100);
  const a2 = audio.analyze(up, 44100);
  check("analyze: 44.1 kHz input is resampled, same tempo", Math.abs(a2.bpm - a.bpm) <= 0.5, a2.bpm);

  // cut planning
  const grid = a.downbeats;
  const cuts = audio.planCuts(grid, [2, 1, 1], firstDrum - 0.1, 5, null);
  check("planCuts: cuts start on the first grid point at/after start_s and span whole bars",
    cuts.length === 5 && Math.abs(cuts[0].start_s - a.downbeats.find((t) => t >= firstDrum - 0.1)) < 1e-9
    && cuts[0].beats === 2 && Math.abs(cuts[0].end_s - cuts[0].start_s - 2 * (a.downbeats[1] - a.downbeats[0])) < 0.05
    && cuts[1].start_s === cuts[0].end_s, JSON.stringify(cuts));
  check("planCuts: stops at maxEnd / grid end", audio.planCuts(grid, [1], 0, 999, null).length === grid.length - 1
    && audio.planCuts(grid, [1], 0, 999, grid[3] + 0.001).length === 3);
  check("nearestGrid", audio.nearestGrid(1.0, [0, 0.9, 2]) === 0.9);

  // decode routing through a recorded runner
  const calls = [];
  const fakeRun = async (cmd, args) => { calls.push([cmd, args]); fs.writeFileSync(args[args.length - 1], wav); return { stdout: "", stderr: "" }; };
  const mp3 = path.join(tmp, "song.mp3"); fs.writeFileSync(mp3, "fake mp3 bytes");
  const out = await audio.decodeToWav(mp3, path.join(tmp, "cache"), { run: fakeRun, afconvert: "afconvert" });
  check("decodeToWav: afconvert -f WAVE -d LEI16@22050 -c 1 in out; cached by size+mtime",
    calls.length === 1 && calls[0][0] === "afconvert" && calls[0][1].join(" ").includes("-d LEI16@22050 -c 1")
    && out.endsWith(".wav") && fs.existsSync(out), JSON.stringify(calls));
  const out2 = await audio.decodeToWav(mp3, path.join(tmp, "cache"), { run: fakeRun, afconvert: "afconvert" });
  check("decodeToWav: second call is a cache hit", out2 === out && calls.length === 1);
  const failThenOk = async (cmd, args) => { calls.push([cmd, args]); if (args.includes("-c")) throw new Error("bad option -c"); fs.writeFileSync(args[args.length - 1], wav); return {}; };
  const m4a = path.join(tmp, "song2.m4a"); fs.writeFileSync(m4a, "fake");
  await audio.decodeToWav(m4a, path.join(tmp, "cache"), { run: failThenOk, afconvert: "afconvert" });
  check("decodeToWav: old afconvert without -c falls back", calls.length === 3 && !calls[2][1].includes("-c"));
  const wavIn = path.join(tmp, "in.wav"); fs.writeFileSync(wavIn, wav);
  check("decodeToWav: WAV passes through untouched", (await audio.decodeToWav(wavIn, path.join(tmp, "cache"), { run: fakeRun })) === wavIn);

  // library listing
  const lib = path.join(tmp, "lib"); fs.mkdirSync(lib);
  for (const n of ["b.mp3", "a.wav", ".hidden.mp3", "notes.txt", "c.M4A"]) fs.writeFileSync(path.join(lib, n), "x");
  const songs = audio.listSongs([lib, path.join(tmp, "missing")]);
  check("listSongs: audio files only, sorted, hidden skipped, missing dir ignored",
    songs.map((s) => s.name).join() === "a,b,c" && songs[2].ext === ".m4a", JSON.stringify(songs.map((s) => s.name)));

  console.log(failures ? "\nFAILURES: " + failures : "\nALL AUDIO CHECKS PASSED");
  process.exit(failures ? 1 : 0);
})().catch((e) => { console.error("TEST DRIVER FAILED", e); process.exit(1); });
