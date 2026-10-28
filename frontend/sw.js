"use strict";

/*
  Service worker for installing ElisCaretex as an app (PWA).

  It deliberately caches almost nothing:
  - Pages, scripts, styles and every Supabase request always come from the
    network, so the app never shows stale data or an old session.
  - Only the offline page is cached, to show a clear message
    when the device has no connection.

  Change CACHE_VERSION when offline.html changes.
*/

const CACHE_VERSION = "2026-10-28-1";
const OFFLINE_CACHE = `elis-offline-${CACHE_VERSION}`;
const OFFLINE_URL = "./offline.html";
const OFFLINE_ASSETS = [OFFLINE_URL];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(OFFLINE_CACHE)
      .then((cache) => cache.addAll(OFFLINE_ASSETS.map((url) => new Request(url, { cache: "reload" }))))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    const names = await caches.keys();
    await Promise.all(
      names
        .filter((name) => name.startsWith("elis-offline-") && name !== OFFLINE_CACHE)
        .map((name) => caches.delete(name))
    );
    if (self.registration.navigationPreload) {
      await self.registration.navigationPreload.enable();
    }
    await self.clients.claim();
  })());
});

self.addEventListener("fetch", (event) => {
  const request = event.request;

  // Only page loads are handled. Everything else (scripts, styles, Supabase
  // API and auth calls) goes straight to the network untouched.
  if (request.method !== "GET" || request.mode !== "navigate") return;

  event.respondWith((async () => {
    try {
      const preloaded = await event.preloadResponse;
      if (preloaded) return preloaded;
      return await fetch(request);
    } catch (error) {
      const cache = await caches.open(OFFLINE_CACHE);
      const offline = await cache.match(OFFLINE_URL);
      return offline || Response.error();
    }
  })());
});
