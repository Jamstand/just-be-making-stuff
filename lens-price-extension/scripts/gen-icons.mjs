/*
 * Generates the extension icons (a lens element with a price-tag dot) as PNGs
 * without any dependencies. Run: node scripts/gen-icons.mjs
 */
import { deflateSync } from 'node:zlib';
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const outDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'icons');
mkdirSync(outDir, { recursive: true });

function crc32(buf) {
  let c, table = crc32.table || (crc32.table = (() => {
    const t = new Int32Array(256);
    for (let n = 0; n < 256; n++) {
      c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      t[n] = c;
    }
    return t;
  })());
  let crc = -1;
  for (let i = 0; i < buf.length; i++) crc = (crc >>> 8) ^ table[(crc ^ buf[i]) & 0xff];
  return (crc ^ -1) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}

function encodePng(size, rgba) {
  const raw = Buffer.alloc((size * 4 + 1) * size);
  for (let y = 0; y < size; y++) {
    raw[y * (size * 4 + 1)] = 0; // filter: none
    rgba.copy(raw, y * (size * 4 + 1) + 1, y * size * 4, (y + 1) * size * 4);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8;  // bit depth
  ihdr[9] = 6;  // RGBA
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

function drawIcon(size) {
  const px = Buffer.alloc(size * size * 4);
  const c = (size - 1) / 2;
  const set = (x, y, r, g, b, a = 255) => {
    if (x < 0 || y < 0 || x >= size || y >= size) return;
    const i = (y * size + x) * 4;
    // simple over-composite
    const na = a / 255, oa = px[i + 3] / 255;
    const ra = na + oa * (1 - na);
    if (ra === 0) return;
    px[i] = Math.round((r * na + px[i] * oa * (1 - na)) / ra);
    px[i + 1] = Math.round((g * na + px[i + 1] * oa * (1 - na)) / ra);
    px[i + 2] = Math.round((b * na + px[i + 2] * oa * (1 - na)) / ra);
    px[i + 3] = Math.round(ra * 255);
  };

  const R = size / 2;
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const dx = x - c, dy = y - c;
      const d = Math.hypot(dx, dy);
      const edge = (r, w = 1) => Math.max(0, Math.min(1, (r - d) / w));

      // rounded dark "camera body" square
      const inset = size * 0.02;
      const rad = size * 0.22;
      const qx = Math.max(Math.abs(dx) - (R - inset - rad), 0);
      const qy = Math.max(Math.abs(dy) - (R - inset - rad), 0);
      const dr = Math.hypot(qx, qy);
      const bodyA = Math.max(0, Math.min(1, (rad - dr) / 1.2));
      if (bodyA > 0) set(x, y, 26, 32, 44, Math.round(bodyA * 255));

      // outer lens ring
      const ringOut = edge(size * 0.40, 1.1);
      const ringIn = edge(size * 0.30, 1.1);
      const ring = ringOut - ringIn;
      if (ring > 0) set(x, y, 226, 232, 240, Math.round(ring * 255));

      // inner glass
      const glass = edge(size * 0.27, 1.1);
      if (glass > 0) {
        const t = d / (size * 0.27);
        set(x, y, Math.round(38 + 40 * t), Math.round(120 - 30 * t), Math.round(72 + 10 * t), Math.round(glass * 255));
      }

      // glass highlight
      const hx = x - (c - size * 0.10), hy = y - (c - size * 0.12);
      const hl = Math.max(0, Math.min(1, (size * 0.09 - Math.hypot(hx, hy)) / 1.0));
      if (hl > 0) set(x, y, 240, 250, 244, Math.round(hl * 200));
    }
  }

  // price-tag dot (bottom right)
  const tx = size * 0.74, ty = size * 0.74, tr = size * 0.20;
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const d = Math.hypot(x - tx, y - ty);
      const a = Math.max(0, Math.min(1, (tr - d) / 1.1));
      if (a > 0) set(x, y, 255, 193, 7, Math.round(a * 255));
      const ia = Math.max(0, Math.min(1, (tr * 0.45 - d) / 1.0));
      if (ia > 0) set(x, y, 26, 32, 44, Math.round(ia * 255));
    }
  }

  return encodePng(size, px);
}

for (const size of [16, 32, 48, 128]) {
  writeFileSync(join(outDir, `icon${size}.png`), drawIcon(size));
  console.log(`icons/icon${size}.png`);
}
