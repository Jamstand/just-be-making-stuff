// Test-only PNG writer: the fake After Effects (host-sim) and the style
// unit test both need to produce real PNGs for the panel's own decoder to
// read, so the decode path is exercised rather than stubbed. Not shipped.
"use strict";
const zlib = require("zlib");

const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[n] = c; }
  return t;
})();
function crc32(buf) { let c = -1; for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 255] ^ (c >>> 8); return (c ^ -1) | 0; }

function chunk(type, data) {
  const head = Buffer.alloc(8);
  head.writeUInt32BE(data.length, 0); head.write(type, 4, "latin1");
  const crc = Buffer.alloc(4);
  crc.writeInt32BE(crc32(Buffer.concat([Buffer.from(type, "latin1"), data])), 0);
  return Buffer.concat([head, data, crc]);
}

// 8-bit RGB, no interlacing — what After Effects writes.
function encodePng(w, h, rgb) {
  const stride = w * 3, raw = Buffer.alloc(h * (stride + 1));
  for (let y = 0; y < h; y++) { raw[y * (stride + 1)] = 0; rgb.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride); }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", ihdr), chunk("IDAT", zlib.deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]);
}

// The picture the fake video (fakebin/yt-dlp's JSON shot plan) shows at t,
// with the same per-pixel texture fakebin/ffmpeg draws so both routes give
// comparable numbers.
function planFrame(plan, t, w, h) {
  const shots = (plan && plan.shots) || [];
  const shot = shots.find((s) => t < s.until) || shots[shots.length - 1] || { level: 128, rg: 0, bg: 0 };
  const i = Math.round(t * 2), px = Buffer.alloc(w * h * 3);
  const clamp = (v) => Math.max(0, Math.min(255, v));
  for (let p = 0; p < w * h; p++) {
    const tex = ((p * 7 + i) % 5) - 2;
    px[p * 3] = clamp(shot.level + shot.rg + tex);
    px[p * 3 + 1] = clamp(shot.level + tex);
    px[p * 3 + 2] = clamp(shot.level + shot.bg + tex);
  }
  return px;
}

module.exports = { encodePng, planFrame, crc32 };
