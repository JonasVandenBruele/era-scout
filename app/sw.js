// App-schil offline beschikbaar. Database-verkeer (Supabase) wordt nooit gecachet:
// niet-verzonden bezoeken staan in de wachtrij van de app zelf.
const CACHE = "nod-shell-v4";
const SHELL = ["./", "index.html", "app.js", "styles.css", "config.js", "vendor/supabase.js", "manifest.webmanifest",
  "icons/icon.svg", "icons/apple-touch-icon.png", "icons/icon-192.png"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => Promise.allSettled(SHELL.map((u) => c.add(u)))).then(() => self.skipWaiting()));
});
self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});
self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  const sameOrigin = url.origin === location.origin;
  const fonts = url.hostname === "fonts.googleapis.com" || url.hostname === "fonts.gstatic.com";
  if (e.request.method !== "GET" || (!sameOrigin && !fonts)) return;
  // Netwerk eerst zodat updates meteen binnenkomen; zonder verbinding de bewaarde versie.
  e.respondWith(
    fetch(e.request).then((res) => {
      if (res.ok || res.type === "opaque") {
        const copy = res.clone();
        caches.open(CACHE).then((c) => c.put(e.request, copy));
      }
      return res;
    }).catch(() => caches.match(e.request).then((r) => r || caches.match("index.html")))
  );
});
