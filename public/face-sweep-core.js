/* Face Sweep core — shared by face-sweep.html (desktop, File System Access API)
   and face-sweep-phone.html (phone, photo picker). On-device face detection and
   recognition, media decoding, photo dates, clustering, and the IndexedDB schema.
   Nothing here talks to a server; the only network use is downloading the model
   files once from a public CDN. */
(function (global) {
'use strict';

const LIB = {
  faceapi: 'https://cdn.jsdelivr.net/npm/@vladmandic/face-api@1.7.15/dist/face-api.js',
  faceapiIntegrity: 'sha384-M5nePoB6/w/a9JhtegEibSLGiJy/+QMZZMfvcxjWVCQW/HPwrQ7i21V/Px/8AyVA',
  models:  'https://cdn.jsdelivr.net/npm/@vladmandic/face-api@1.7.15/model/',
  heic:    'https://cdn.jsdelivr.net/npm/heic2any@0.0.4/dist/heic2any.min.js',
  heicIntegrity: 'sha384-OTofQ0MEeiSgh62havBcemCIK0gqj809wX6UA0uPISNMRnR6NZyCdGzX3SbLrgwL',
  // Must match the TensorFlow.js version bundled in face-api (see its dist/tfjs.version.js).
  wasm:    'https://cdn.jsdelivr.net/npm/@tensorflow/tfjs-backend-wasm@4.22.0/dist/',
};
const IMAGE_EXT = new Set(['jpg','jpeg','jfif','png','webp','gif','bmp','avif','heic','heif']);
const VIDEO_EXT = new Set(['mp4','m4v','mov','webm','mkv','avi','3gp','mpg','mpeg','wmv','mts','m2ts']);
const MIN_FACE_SCORE = 0.5;
const CLUSTER_DIST = 0.5;

/* ---------------------------------------------------------------- small helpers */
const extOf = (name) => { const i = String(name || '').lastIndexOf('.'); return i < 0 ? '' : name.slice(i + 1).toLowerCase(); };
function kindOf(file) {
  const ext = extOf(file.name), type = file.type || '';
  if (IMAGE_EXT.has(ext) || type.startsWith('image/')) return 'image';
  if (VIDEO_EXT.has(ext) || type.startsWith('video/')) return 'video';
  return null;
}
function dist(a, b) { let s = 0; for (let i = 0; i < a.length; i++) { const v = a[i] - b[i]; s += v * v; } return Math.sqrt(s); }
function confLabel(d) { return d <= 0.45 ? 'strong' : d <= 0.52 ? 'likely' : 'possible'; }
function withTimeout(p, ms, what) {
  let t; const timeout = new Promise((_, rej) => { t = setTimeout(() => rej(new Error(what || 'timed out')), ms); });
  return Promise.race([p, timeout]).finally(() => clearTimeout(t));
}
function canvasToBlob(c, type, q) { return new Promise((res, rej) => c.toBlob((b) => b ? res(b) : rej(new Error('toBlob failed')), type, q)); }
function loadScript(src, integrity) {
  return new Promise((res, rej) => {
    const s = document.createElement('script'); s.src = src; s.async = true; s.crossOrigin = 'anonymous';
    if (integrity) s.integrity = integrity;
    s.onload = res; s.onerror = () => rej(new Error('Could not load ' + src));
    document.head.appendChild(s);
  });
}
// Decode failures that will not change on retry. Anything else (timeouts, a script that
// failed to download, a lost GPU context) deserves another attempt next time.
const isPermanentError = (why) => /cannot decode|no video track|no frames could be read|empty image|not supported/i.test(why || '');
const isIOS = () => /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
const isAndroid = () => /Android/i.test(navigator.userAgent);

/* ---------------------------------------------------------------- IndexedDB (shared schema) */
const DB_NAME = 'facesweep', DB_VER = 1;
let dbPromise = null;
function openDB() {
  if (dbPromise) return dbPromise;
  dbPromise = new Promise((res, rej) => {
    const r = indexedDB.open(DB_NAME, DB_VER);
    r.onupgradeneeded = () => {
      const db = r.result;
      db.createObjectStore('roots', { keyPath: 'id' });
      const f = db.createObjectStore('faces', { keyPath: 'key' }); f.createIndex('rootId', 'rootId');
      db.createObjectStore('people', { keyPath: 'id' });
      const o = db.createObjectStore('ops', { keyPath: 'id' }); o.createIndex('rootId', 'rootId');
    };
    r.onsuccess = () => res(r.result);
    r.onerror = () => rej(r.error);
  });
  return dbPromise;
}
function req(r) { return new Promise((res, rej) => { r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); }); }
const idb = {
  async get(store, key) { const db = await openDB(); return req(db.transaction(store).objectStore(store).get(key)); },
  async put(store, val) { const db = await openDB(); return req(db.transaction(store, 'readwrite').objectStore(store).put(val)); },
  async del(store, key) { const db = await openDB(); return req(db.transaction(store, 'readwrite').objectStore(store).delete(key)); },
  async all(store, index, value) {
    const db = await openDB(); const os = db.transaction(store).objectStore(store);
    return req(index ? os.index(index).getAll(value) : os.getAll());
  },
};
const faceKey = (rootId, relPath) => rootId + '|' + relPath;

/* ---------------------------------------------------------------- face model */
let modelPromise = null, ssdOpts = null, statusHandler = null;
function setModelStatusHandler(fn) { statusHandler = fn; }
function say(cls, text) { try { if (statusHandler) statusHandler(cls, text); } catch {} }
function ensureModels() {
  if (modelPromise) return modelPromise;
  modelPromise = (async () => {
    say('busy', 'Face model: downloading (about 12 MB, once)…');
    if (!global.faceapi) await loadScript(LIB.faceapi, LIB.faceapiIntegrity);
    // Without WebGL (some phones, privacy browsers) TensorFlow.js falls back to the
    // WebAssembly backend. The face-api bundle doesn't ship its .wasm files, so point
    // it at the matching official package, then wait for the backend to initialise.
    const tf = global.faceapi.tf;
    try { if (typeof tf.setWasmPaths === 'function') tf.setWasmPaths(LIB.wasm); } catch {}
    try { await tf.ready(); } catch {}
    await global.faceapi.nets.ssdMobilenetv1.loadFromUri(LIB.models);
    await global.faceapi.nets.faceLandmark68Net.loadFromUri(LIB.models);
    await global.faceapi.nets.faceRecognitionNet.loadFromUri(LIB.models);
    say('ok', 'Face model: ready (' + global.faceapi.tf.getBackend() + ')');
  })().catch((e) => { modelPromise = null; say('err', 'Face model failed: ' + e.message); throw e; });
  return modelPromise;
}
function modelsReady() { return !!(global.faceapi && global.faceapi.nets.faceRecognitionNet.isLoaded); }
async function detectFaces(canvas) {
  await ensureModels();
  const faceapi = global.faceapi;
  ssdOpts = ssdOpts || new faceapi.SsdMobilenetv1Options({ minConfidence: MIN_FACE_SCORE });
  const dets = await faceapi.detectAllFaces(canvas, ssdOpts).withFaceLandmarks().withFaceDescriptors();
  const W = canvas.width, H = canvas.height;
  return dets.map((r) => ({
    d: new Float32Array(r.descriptor),
    score: r.detection.score,
    box: { x: r.detection.box.x / W, y: r.detection.box.y / H, w: r.detection.box.width / W, h: r.detection.box.height / H },
  }));
}

/* ---------------------------------------------------------------- decoding */
// Decodes through an <img> element: every browser applies EXIF orientation there,
// Safari decodes HEIC natively, and memory use matches ordinary web images.
function decodeViaImg(blob, maxSide) {
  const url = URL.createObjectURL(blob);
  return withTimeout((async () => {
    try {
      const img = new Image(); img.decoding = 'async';
      await new Promise((res, rej) => { img.onload = () => res(); img.onerror = () => rej(new Error('cannot decode this image')); img.src = url; });
      try { await img.decode(); } catch {}
      const w0 = img.naturalWidth, h0 = img.naturalHeight;
      if (!w0 || !h0) throw new Error('empty image');
      const scale = Math.min(1, maxSide / Math.max(w0, h0));
      const c = document.createElement('canvas');
      c.width = Math.max(1, Math.round(w0 * scale)); c.height = Math.max(1, Math.round(h0 * scale));
      c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
      img.src = '';
      return c;
    } finally { URL.revokeObjectURL(url); }
  })(), 60000, 'image took too long to decode');
}
async function heicToJpeg(file) {
  if (!global.heic2any) await loadScript(LIB.heic, LIB.heicIntegrity);
  const out = await global.heic2any({ blob: file, toType: 'image/jpeg', quality: 0.9 });
  return Array.isArray(out) ? out[0] : out;
}
async function decodeImage(file, ext, maxSide) {
  ext = ext || extOf(file.name);
  const heic = ext === 'heic' || ext === 'heif' || /hei[cf]/i.test(file.type || '');
  try { return await decodeViaImg(file, maxSide); }
  catch (e) {
    if (!heic) throw e;
    return decodeViaImg(await heicToJpeg(file), maxSide); // browser can't decode HEIC itself (Chrome, Firefox)
  }
}
function once(el, ok, ms, what) {
  return withTimeout(new Promise((res, rej) => {
    const done = () => { cleanup(); res(); };
    const fail = () => { cleanup(); rej(new Error(el.error && el.error.message ? el.error.message : 'cannot decode this video')); };
    function cleanup() { el.removeEventListener(ok, done); el.removeEventListener('error', fail); }
    el.addEventListener(ok, done); el.addEventListener('error', fail);
  }), ms, what);
}
async function* videoFrames(file, nFrames, maxSide) {
  const url = URL.createObjectURL(file);
  const v = document.createElement('video');
  v.muted = true; v.playsInline = true; v.setAttribute('playsinline', ''); v.preload = 'auto'; v.src = url;
  const c = document.createElement('canvas');
  try {
    await once(v, 'loadedmetadata', 20000, 'video took too long to open');
    let dur = v.duration;
    if (!isFinite(dur) || dur <= 0) {
      try { const p = once(v, 'seeked', 8000); v.currentTime = 1e6; await p; dur = v.duration; } catch { dur = 0; }
      if (!isFinite(dur)) dur = 0;
    }
    const n = dur > 0 ? Math.max(1, Math.min(nFrames, Math.ceil(dur / 1.5))) : 1;
    for (let i = 0; i < n; i++) {
      const t = dur > 0 ? Math.min(Math.max(0, dur - 0.05), dur * (i + 0.5) / n) : 0.01;
      const p = once(v, 'seeked', 15000, 'video seek timed out');
      v.currentTime = t; await p;
      if (!v.videoWidth) throw new Error('no video track');
      const scale = Math.min(1, maxSide / Math.max(v.videoWidth, v.videoHeight));
      c.width = Math.round(v.videoWidth * scale); c.height = Math.round(v.videoHeight * scale);
      c.getContext('2d').drawImage(v, 0, 0, c.width, c.height);
      yield { canvas: c, t };
    }
  } finally {
    v.removeAttribute('src'); try { v.load(); } catch {}
    URL.revokeObjectURL(url);
    c.width = c.height = 0;
  }
}
async function thumbOf(canvas, max) {
  const scale = Math.min(1, max / Math.max(canvas.width, canvas.height));
  const c = document.createElement('canvas'); c.width = Math.max(1, Math.round(canvas.width * scale)); c.height = Math.max(1, Math.round(canvas.height * scale));
  c.getContext('2d').drawImage(canvas, 0, 0, c.width, c.height);
  const b = await canvasToBlob(c, 'image/jpeg', 0.8); c.width = c.height = 0;
  return b;
}
async function cropFace(canvas, box) {
  const W = canvas.width, H = canvas.height;
  const size = Math.max(box.w * W, box.h * H) * 1.6;
  const cx = (box.x + box.w / 2) * W, cy = (box.y + box.h / 2) * H;
  const c = document.createElement('canvas'); c.width = c.height = 112;
  const ctx = c.getContext('2d'); ctx.fillStyle = '#E3DFD0'; ctx.fillRect(0, 0, 112, 112);
  ctx.drawImage(canvas, cx - size / 2, cy - size / 2, size, size, 0, 0, 112, 112);
  const b = await canvasToBlob(c, 'image/jpeg', 0.8); c.width = c.height = 0;
  return b;
}
// One-shot processing of an image file: faces (with descriptors and face crops) and a thumbnail.
async function processImage(file, maxSide, opts) {
  const canvas = await decodeImage(file, extOf(file.name), maxSide);
  const faces = await detectFaces(canvas);
  for (const f of faces) f.thumb = await cropFace(canvas, f.box);
  const thumb = faces.length || (opts && opts.alwaysThumb) ? await thumbOf(canvas, (opts && opts.thumbMax) || 360) : null;
  const out = { faces, thumb, width: canvas.width, height: canvas.height };
  canvas.width = canvas.height = 0; // release the backing store now rather than at GC time (matters on iOS)
  return out;
}
// Same for a video: faces from sampled frames, thumbnail from the first frame with a face.
// If opts.shouldStop() interrupts the sampling, the result is flagged partial and must not be cached.
async function processVideo(file, maxSide, nFrames, opts) {
  const faces = []; let thumb = null; let frames = 0; let partial = false;
  for await (const { canvas, t } of videoFrames(file, nFrames, maxSide)) {
    frames++;
    const fs = await detectFaces(canvas);
    for (const f of fs) { f.t = t; f.thumb = await cropFace(canvas, f.box); faces.push(f); }
    if (!thumb && (fs.length || (opts && opts.alwaysThumb))) thumb = await thumbOf(canvas, (opts && opts.thumbMax) || 360);
    if (opts && opts.shouldStop && opts.shouldStop()) { partial = true; break; }
  }
  if (!frames) throw new Error('no frames could be read');
  return { faces, thumb, partial };
}

/* ---------------------------------------------------------------- photo date (EXIF) */
// Reads DateTimeOriginal from JPEG (APP1) or HEIC/HEIF (Exif item) headers without
// decoding the image. Returns a Date, or null if there is no usable EXIF date.
function parseExifDate(s) {
  const m = /^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})/.exec(s || '');
  if (!m) return null;
  const [Y, M, D, h, mi, sec] = m.slice(1).map(Number);
  if (Y < 1900 || Y > 2200 || M < 1 || M > 12 || D < 1 || D > 31 || h > 23 || mi > 59 || sec > 60) return null;
  const d = new Date(Y, M - 1, D, h, mi, Math.min(sec, 59));
  return isNaN(d.getTime()) || d.getMonth() !== M - 1 ? null : d;
}
function tiffDate(dv, tiff) {
  const le = dv.getUint16(tiff) === 0x4949;
  if (dv.getUint16(tiff, le) !== 0x4949 && dv.getUint16(tiff, le) !== 0x4D4D) return null;
  if (dv.getUint16(tiff + 2, le) !== 42) return null;
  const u16 = (p) => dv.getUint16(p, le), u32 = (p) => dv.getUint32(p, le);
  const ascii = (p, n) => { let s = ''; for (let k = 0; k < n && p + k < dv.byteLength; k++) { const c = dv.getUint8(p + k); if (!c) break; s += String.fromCharCode(c); } return s; };
  const readIFD = (p) => {
    const out = {}; if (p + 2 > dv.byteLength) return out;
    const n = u16(p);
    for (let i = 0; i < n; i++) {
      const e = p + 2 + i * 12; if (e + 12 > dv.byteLength) break;
      const tag = u16(e), type = u16(e + 2), cnt = u32(e + 4);
      if (type === 2) { const off = cnt > 4 ? tiff + u32(e + 8) : e + 8; out[tag] = ascii(off, cnt); }
      else if (type === 4 || type === 3) out[tag] = type === 4 ? u32(e + 8) : u16(e + 8);
    }
    return out;
  };
  const ifd0 = readIFD(tiff + u32(tiff + 4));
  let date = null;
  if (ifd0[0x8769]) { const exif = readIFD(tiff + ifd0[0x8769]); date = parseExifDate(exif[0x9003]) || parseExifDate(exif[0x9004]); }
  return date || parseExifDate(ifd0[0x0132]);
}
function jpegDate(dv) {
  if (dv.getUint16(0) !== 0xFFD8) return null;
  let off = 2;
  while (off + 4 <= dv.byteLength) {
    const marker = dv.getUint16(off); if ((marker & 0xFF00) !== 0xFF00) break;
    const len = dv.getUint16(off + 2);
    if (marker === 0xFFE1 && off + 10 <= dv.byteLength && dv.getUint32(off + 4) === 0x45786966) return tiffDate(dv, off + 10);
    if (marker === 0xFFDA) break;
    off += 2 + len;
  }
  return null;
}
// ISO base media (HEIF, MP4, MOV) box walker with an iteration cap so a crafted file can't stall the page.
const fourccAt = (dv, p) => String.fromCharCode(dv.getUint8(p), dv.getUint8(p + 1), dv.getUint8(p + 2), dv.getUint8(p + 3));
function boxesOf(dv, start, end) {
  const out = []; let p = start;
  while (p + 8 <= end && out.length < 4096) {
    let size = dv.getUint32(p); const type = fourccAt(dv, p + 4); let hdr = 8;
    if (size === 1) { if (p + 16 > end) break; size = Number(dv.getBigUint64(p + 8)); hdr = 16; } else if (size === 0) size = end - p;
    if (!(size >= hdr)) break;
    out.push({ type, start: p, body: p + hdr, end: Math.min(end, p + size) }); p += size;
  }
  return out;
}
const ISO_IMAGE_BRANDS = new Set(['heic', 'heix', 'hevc', 'hevx', 'mif1', 'msf1', 'heif', 'avif', 'avis']);
function heifDate(dv) {
  const fourcc = (p) => fourccAt(dv, p);
  const boxes = (start, end) => boxesOf(dv, start, end);
  const top = boxes(0, dv.byteLength);
  if (!top.some((b) => b.type === 'ftyp')) return null;
  const meta = top.find((b) => b.type === 'meta'); if (!meta) return null;
  const inner = boxes(meta.body + 4, meta.end); // meta is a FullBox
  const iinf = inner.find((b) => b.type === 'iinf'), iloc = inner.find((b) => b.type === 'iloc');
  if (!iinf || !iloc) return null;
  const iv = dv.getUint8(iinf.body); const count = iv === 0 ? dv.getUint16(iinf.body + 4) : dv.getUint32(iinf.body + 4);
  const entries = boxes(iinf.body + (iv === 0 ? 6 : 8), iinf.end);
  let exifId = null;
  for (const e of entries) {
    if (e.type !== 'infe') continue; const ver = dv.getUint8(e.body);
    if (ver >= 2) { const id = ver === 2 ? dv.getUint16(e.body + 4) : dv.getUint32(e.body + 4); const type = fourcc(e.body + (ver === 2 ? 8 : 10)); if (type === 'Exif') { exifId = id; break; } }
  }
  if (exifId === null || count === 0) return null;
  const lv = dv.getUint8(iloc.body); let p = iloc.body + 4;
  const b0 = dv.getUint8(p), b1 = dv.getUint8(p + 1); p += 2;
  const offSize = b0 >> 4, lenSize = b0 & 15, baseSize = b1 >> 4, idxSize = lv >= 1 ? (b1 & 15) : 0;
  const itemCount = lv < 2 ? dv.getUint16(p) : dv.getUint32(p); p += lv < 2 ? 2 : 4;
  if (itemCount > 20000) return null;
  const rd = (size) => { let v = 0; if (p + size > dv.byteLength) throw new RangeError('iloc'); if (size === 4) v = dv.getUint32(p); else if (size === 8) v = Number(dv.getBigUint64(p)); p += size; return v; };
  for (let i = 0; i < itemCount; i++) {
    if (p + 8 > dv.byteLength) return null;
    const id = lv < 2 ? dv.getUint16(p) : dv.getUint32(p); p += lv < 2 ? 2 : 4;
    let method = 0; if (lv >= 1) { method = dv.getUint16(p) & 15; p += 2; }
    p += 2; // data_reference_index
    const base = rd(baseSize);
    const extents = dv.getUint16(p); p += 2;
    if (extents > 1000) return null;
    let first = null;
    for (let k = 0; k < extents; k++) { if (idxSize) rd(idxSize); const off = rd(offSize), len = rd(lenSize); if (k === 0) first = { off, len }; }
    if (id === exifId) {
      if (method !== 0 || !first) return null;
      const start = base + first.off; if (start + 8 > dv.byteLength) return null;
      const tiffOff = dv.getUint32(start);
      const tiff = start + 4 + tiffOff; if (tiff + 8 > dv.byteLength) return null;
      return tiffDate(dv, tiff);
    }
  }
  return null;
}
// MP4 / MOV: moov/mvhd creation_time (seconds since 1904-01-01 UTC). Camera apps usually
// put moov at the end of the file, so the tail is scanned when the head has no moov.
function mvhdDate(dv, moov) {
  const mvhd = boxesOf(dv, moov.body, moov.end).find((b) => b.type === 'mvhd');
  if (!mvhd || mvhd.body + 12 > dv.byteLength) return null;
  const ver = dv.getUint8(mvhd.body);
  const secs = ver === 1 ? (mvhd.body + 12 <= dv.byteLength ? Number(dv.getBigUint64(mvhd.body + 4)) : 0) : dv.getUint32(mvhd.body + 4);
  if (!secs) return null;
  const d = new Date((secs - 2082844800) * 1000);
  return d.getFullYear() > 1971 && d.getFullYear() < 2200 ? d : null;
}
function mp4HeadDate(dv) {
  const top = boxesOf(dv, 0, dv.byteLength);
  const moov = top.find((b) => b.type === 'moov');
  return moov ? mvhdDate(dv, moov) : null;
}
function mp4TailDate(dv) {
  for (let i = dv.byteLength - 8; i >= 4; i--) {
    if (fourccAt(dv, i) !== 'moov') continue;
    const size = dv.getUint32(i - 4);
    if (size >= 8 && i - 4 + size === dv.byteLength) { const d = mvhdDate(dv, { body: i + 4, end: dv.byteLength }); if (d) return d; }
  }
  return null;
}
function isoBrand(dv) { const top = boxesOf(dv, 0, Math.min(dv.byteLength, 64)); const f = top.find((b) => b.type === 'ftyp'); return f && f.body + 4 <= dv.byteLength ? fourccAt(dv, f.body) : null; }
// Capture date of a photo or video from its own metadata, without decoding it. Returns a Date or null.
async function mediaDate(file) {
  try {
    const head = new DataView(await file.slice(0, 512 * 1024).arrayBuffer());
    if (head.byteLength < 12) return null;
    const d = jpegDate(head) || heifDate(head) || mp4HeadDate(head);
    if (d) return d;
    const brand = isoBrand(head);
    if (brand && !ISO_IMAGE_BRANDS.has(brand) && file.size > head.byteLength) {
      const tail = new DataView(await file.slice(Math.max(0, file.size - 2 * 1024 * 1024)).arrayBuffer());
      return mp4TailDate(tail);
    }
    return null;
  } catch { return null; }
}
const photoDate = mediaDate;

/* ---------------------------------------------------------------- matching & clustering */
function bestMatch(faces, refs) {
  let best = Infinity, idx = -1;
  for (let i = 0; i < faces.length; i++) { const f = faces[i]; for (const r of refs) { const d = dist(f.d, r); if (d < best) { best = d; idx = i; } } }
  return { best, idx };
}
// Greedy clustering of every face across items; items need { faces }. Returns clusters
// sorted by how many items they appear in: { centroid, members: [{ e: item, f, i }], files: Set(id) }.
function clusterFaces(items, idOf) {
  const all = [];
  for (const e of items) (e.faces || []).forEach((f, i) => all.push({ e, f, i }));
  all.sort((a, b) => b.f.score - a.f.score);
  const clusters = [];
  for (const x of all) {
    let best = null, bd = CLUSTER_DIST;
    for (const c of clusters) { const d = dist(c.centroid, x.f.d); if (d < bd) { bd = d; best = c; } }
    if (best) {
      best.members.push(x); const n = best.members.length;
      for (let k = 0; k < 128; k++) best.centroid[k] += (x.f.d[k] - best.centroid[k]) / n;
      best.files.add(idOf(x.e));
    } else clusters.push({ centroid: new Float32Array(x.f.d), members: [x], files: new Set([idOf(x.e)]) });
  }
  clusters.sort((a, b) => b.files.size - a.files.size);
  return clusters;
}

global.FaceSweepCore = {
  LIB, IMAGE_EXT, VIDEO_EXT, MIN_FACE_SCORE, CLUSTER_DIST,
  extOf, kindOf, dist, confLabel, withTimeout, canvasToBlob, loadScript, isIOS, isAndroid, isPermanentError,
  openDB, idb, faceKey,
  setModelStatusHandler, ensureModels, modelsReady, detectFaces,
  decodeImage, videoFrames, thumbOf, cropFace, processImage, processVideo,
  photoDate, mediaDate, parseExifDate,
  bestMatch, clusterFaces,
};
})(window);
