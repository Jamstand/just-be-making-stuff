// Face Sweep (phone) service worker: keeps the app shell and the face-model
// files available offline. Scope is this folder only, so it never touches the
// other apps on this site.
const CACHE_PREFIX = 'face-sweep-phone-';
const CACHE = CACHE_PREFIX + 'v1';
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
      .then((keys) => Promise.all(keys.filter((k) => k.startsWith(CACHE_PREFIX) && k !== CACHE).map((k) => caches.delete(k)))) // only our own old versions: CacheStorage is shared by every app on this origin
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
      if (res && res.ok && res.type !== 'opaque') { const copy = res.clone(); event.waitUntil(c.put(req, copy).catch(() => {})); }
      return res;
    })());
    return;
  }

  if (url.origin !== self.location.origin) return;

  // App shell: network first, but a slow network is not a failure. If the network hasn't
  // answered within 4 s serve the cached copy and let the download finish in the background;
  // with nothing cached, wait for the network however long it takes.
  event.respondWith((async () => {
    const net = fetch(req).catch(() => null);
    let timedOut = false;
    const fresh = await Promise.race([net, new Promise((r) => setTimeout(() => { timedOut = true; r(null); }, 4000))]);
    const cached = await caches.match(req, { ignoreSearch: true });
    if (fresh && fresh.ok) {
      const copy = fresh.clone();
      event.waitUntil(caches.open(CACHE).then((c) => c.put(req, copy)).catch(() => {}));
      return fresh;
    }
    if (cached) {
      if (timedOut) event.waitUntil(net.then((r) => (r && r.ok) ? caches.open(CACHE).then((c) => c.put(req, r)) : null).catch(() => {}));
      return cached;
    }
    const late = timedOut ? await net : fresh;
    return late || Response.error();
  })());
});
