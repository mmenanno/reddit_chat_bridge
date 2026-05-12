// Service worker for the Reddit Chat Bridge operator console.
//
// Strategy:
//   - Navigations (HTML pages): network-first, fall back to /offline.html
//     when the network rejects. Pages are never served stale to the operator;
//     a fresh fetch is always attempted first.
//   - Same-origin static assets (.css/.js/.png/.svg/.ico/.webmanifest):
//     cache-first, then network. Speeds up repeat loads and survives offline.
//   - POST/PUT/DELETE and cross-origin: pass-through, never cached.
//
// VERSION is substituted at request time from Bridge::BuildInfo.version
// (the project VERSION file) by the /sw.js route handler. Every project
// version bump auto-rotates the cache name, which forces install + activate
// to run fresh on next page load and drops the previous cache.
const VERSION = "v__BUILD_VERSION__";
const STATIC_CACHE = `rcb-static-${VERSION}`;
const PRECACHE = [
  "/offline.html",
  "/application-__BUILD_VERSION__.css",
  "/grain.png",
  "/icons/icon-180.png",
  "/icons/icon-192.png",
  "/icons/icon-512.png",
  "/manifest.webmanifest",
];

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(STATIC_CACHE).then((c) => c.addAll(PRECACHE)));
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== STATIC_CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  if (request.mode === "navigate") {
    event.respondWith(fetch(request).catch(() => caches.match("/offline.html")));
    return;
  }

  if (/\.(css|js|png|svg|ico|webmanifest)$/.test(url.pathname)) {
    event.respondWith(
      caches.match(request).then((hit) =>
        hit || fetch(request).then((response) => {
          const copy = response.clone();
          caches.open(STATIC_CACHE).then((c) => c.put(request, copy));
          return response;
        })
      )
    );
  }
});
