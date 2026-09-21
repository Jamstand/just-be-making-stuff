// Keeps the uploader's shell available offline. API calls and everything
// cross-origin go straight to the network.
const CACHE = 'uploader-v1';
const SHELL = ['upload.html', 'upload.webmanifest', 'upload-icon.png',
  'fonts/inter.woff2', 'fonts/caveat.woff2', 'fonts/cormorant-garamond.woff2', 'fonts/cormorant-garamond-italic.woff2'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  // only the uploader's own files — the portfolio and everything else are left alone
  if (e.request.method !== 'GET' || url.origin !== location.origin) return;
  if (!SHELL.some(p => url.pathname.endsWith('/' + p))) return;
  // network first so an updated app wins; cache keeps it opening offline
  e.respondWith(
    fetch(e.request).then(res => {
      const copy = res.clone();
      caches.open(CACHE).then(c => c.put(e.request, copy));
      return res;
    }).catch(() => caches.match(e.request))
  );
});
