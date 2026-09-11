// A small PNG reader, so the panel can measure the frames After Effects
// writes without any outside help. AE's saveFrameToPng gives 8-bit RGB or
// RGBA, uncompressed-interlace-free; this handles those plus 16-bit and
// palette PNGs (ffmpeg writes those in the tests) and says plainly when it
// meets something it does not know.
//
// Node's zlib does the inflating; everything else is the PNG spec's five
// row filters. Deliberately dependency-free and DOM-free: it runs in the
// panel and in a unit test the same way.
"use strict";
const zlib = require("zlib");

const CHANNELS = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 };   // grey, rgb, palette, grey+a, rgba

// The bytes of a finished PNG end with the IEND chunk; After Effects
// returns from saveFrameToPng before the file is always fully on disk, so
// callers poll with this before reading.
function pngComplete(buf) {
  if (!buf || buf.length < 20) return false;
  return buf.toString("latin1", buf.length - 8, buf.length - 4) === "IEND";
}

function paeth(a, b, c) {
  const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
  return (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
}

// -> { width, height, rgb } with rgb an 8-bit RGB buffer (width*height*3).
// Any alpha is composited over black, which is what a filled frame looks
// like anyway and keeps the numbers comparable with ffmpeg's rgb24.
function decodePng(input) {
  const buf = Buffer.isBuffer(input) ? input : Buffer.from(input);
  if (buf.length < 8 || buf.readUInt32BE(0) !== 0x89504e47 || buf.readUInt32BE(4) !== 0x0d0a1a0a)
    throw new Error("not a PNG file");
  let width = 0, height = 0, depth = 0, type = 0, interlace = 0;
  let palette = null, trns = null, sawIhdr = false, sawIend = false;
  const idat = [];
  let p = 8;
  while (p + 8 <= buf.length) {
    const len = buf.readUInt32BE(p);
    const name = buf.toString("latin1", p + 4, p + 8);
    const at = p + 8;
    if (len > buf.length || at + len > buf.length)
      throw new Error("PNG is truncated inside its " + name + " chunk");
    if (name === "IHDR") {
      width = buf.readUInt32BE(at); height = buf.readUInt32BE(at + 4);
      depth = buf[at + 8]; type = buf[at + 9]; interlace = buf[at + 12];
      sawIhdr = true;
    } else if (name === "PLTE") palette = buf.subarray(at, at + len);
    else if (name === "tRNS") trns = buf.subarray(at, at + len);
    else if (name === "IDAT") idat.push(buf.subarray(at, at + len));
    else if (name === "IEND") { sawIend = true; break; }
    p = at + len + 4;                                  // + CRC
  }
  if (!sawIhdr) throw new Error("PNG has no header chunk");
  if (!sawIend) throw new Error("PNG is truncated (no IEND) — still being written?");
  if (!width || !height) throw new Error("PNG header says " + width + "x" + height);
  if (interlace) throw new Error("interlaced (Adam7) PNGs are not supported here");
  const ch = CHANNELS[type];
  if (!ch) throw new Error("unknown PNG colour type " + type);
  if (type === 3) { if (depth !== 8) throw new Error("palette PNGs are supported at 8 bits, not " + depth); if (!palette) throw new Error("palette PNG with no PLTE chunk"); }
  else if (depth !== 8 && depth !== 16) throw new Error("PNG bit depth " + depth + " is not supported (8 or 16 only)");
  if (!idat.length) throw new Error("PNG has no image data");

  const raw = zlib.inflateSync(Buffer.concat(idat));
  const bytes = depth >> 3 || 1;                       // per sample
  const bpp = Math.max(1, ch * bytes);                 // per pixel, for the filters
  const stride = width * bpp;
  if (raw.length < height * (stride + 1))
    throw new Error("PNG data is short: " + raw.length + " bytes for " + height + " rows of " + stride);

  // Unfilter in place, row by row (each row is prefixed with its filter id).
  const lines = Buffer.alloc(height * stride);
  let src = 0;
  for (let y = 0; y < height; y++) {
    const filter = raw[src++];
    if (filter > 4) throw new Error("unknown PNG row filter " + filter + " on row " + y);
    const row = y * stride, prev = row - stride;
    if (filter === 0) { raw.copy(lines, row, src, src + stride); }
    else for (let x = 0; x < stride; x++) {
      const v = raw[src + x];
      const a = x >= bpp ? lines[row + x - bpp] : 0;
      const b = y ? lines[prev + x] : 0;
      const c = (y && x >= bpp) ? lines[prev + x - bpp] : 0;
      lines[row + x] = 255 & (filter === 1 ? v + a
        : filter === 2 ? v + b
        : filter === 3 ? v + ((a + b) >> 1)
        : v + paeth(a, b, c));
    }
    src += stride;
  }

  const rgb = Buffer.alloc(width * height * 3);
  const step = depth === 16 ? 2 : 1;                   // 16-bit: the high byte is plenty
  for (let i = 0, n = width * height; i < n; i++) {
    const at2 = i * bpp;
    let r, g, b, a = 255;
    if (type === 3) {
      const idx = lines[at2] * 3;
      r = palette[idx]; g = palette[idx + 1]; b = palette[idx + 2];
      if (trns && lines[at2] < trns.length) a = trns[lines[at2]];
    } else if (type === 0 || type === 4) {
      r = g = b = lines[at2];
      if (type === 4) a = lines[at2 + step];
    } else {
      r = lines[at2]; g = lines[at2 + step]; b = lines[at2 + 2 * step];
      if (type === 6) a = lines[at2 + 3 * step];
    }
    const o = i * 3;
    if (a === 255) { rgb[o] = r; rgb[o + 1] = g; rgb[o + 2] = b; }
    else { rgb[o] = (r * a / 255) | 0; rgb[o + 1] = (g * a / 255) | 0; rgb[o + 2] = (b * a / 255) | 0; }
  }
  return { width, height, rgb };
}

// Box-average down (or nearest-neighbour up) to tw x th — the same job
// ffmpeg's scale=...:flags=area does, so both routes measure alike.
function resampleRgb(rgb, w, h, tw, th) {
  if (w === tw && h === th) return rgb;
  const out = Buffer.alloc(tw * th * 3);
  for (let y = 0; y < th; y++) {
    const y0 = Math.floor(y * h / th), y1 = Math.max(y0 + 1, Math.floor((y + 1) * h / th));
    for (let x = 0; x < tw; x++) {
      const x0 = Math.floor(x * w / tw), x1 = Math.max(x0 + 1, Math.floor((x + 1) * w / tw));
      let r = 0, g = 0, b = 0, n = 0;
      for (let yy = y0; yy < y1 && yy < h; yy++) {
        let at = (yy * w + x0) * 3;
        for (let xx = x0; xx < x1 && xx < w; xx++, at += 3) { r += rgb[at]; g += rgb[at + 1]; b += rgb[at + 2]; n++; }
      }
      const o = (y * tw + x) * 3;
      out[o] = n ? Math.round(r / n) : 0; out[o + 1] = n ? Math.round(g / n) : 0; out[o + 2] = n ? Math.round(b / n) : 0;
    }
  }
  return out;
}

module.exports = { decodePng, resampleRgb, pngComplete, CHANNELS };
