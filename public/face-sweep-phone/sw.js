// Face Sweep (phone) service worker: keeps the app shell and the face-model
// files available offline. Scope is this folder only, so it never touches the
// other apps on this site.
const CACHE = 'face-sweep-phone-v1';
const SHELL = ['./', './index.html', './manifest.webmanifest', './icon.svg', './icon-180.png', './icon-192.png', './icon-512.png', '../face-sweep-core.js'];
const CDN_HOST = 'cdn.jsdelivr.net';

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const c = await caches.open(CACHE);
    await Promise.all(SHELL.map((u) => c.add(u).catch(() => {})));
  })());
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  // Model + library files are version-pinned: cache first, forever.
  if (url.hostname === CDN_HOST) {
    event.respondWith((async () => {
      const c = await caches.open(CACHE);
      const hit = await c.match(req);
      if (hit) return hit;
      const res = await fetch(req);
      if (res && res.ok && res.type !== 'opaque') c.put(req, res.clone()).catch(() => {});
      return res;
    })());
    return;
  }

  if (url.origin !== self.location.origin) return;

  // App shell: network first (short timeout), cache as fallback.
  event.respondWith((async () => {
    try {
      const fresh = await Promise.race([
        fetch(req),
        new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), 4000)),
      ]);
      if (fresh && fresh.status === 200 && fresh.type === 'basic') {
        const copy = fresh.clone();
        caches.open(CACHE).then((c) => c.put(req, copy)).catch(() => {});
      }
      return fresh;
    } catch {
      const cached = await caches.match(req, { ignoreSearch: true });
      if (cached) return cached;
      throw new Error('offline and no cache');
    }
  })());
});
