"use strict";

// Registers the service worker that makes ElisCaretex installable as an app.
// The worker lives at the site root (next to index.html) so it covers every page.
(function registerElisServiceWorker() {
  if (!("serviceWorker" in navigator) || !window.isSecureContext) return;

  const script = document.currentScript;
  const workerUrl = new URL("../../sw.js", script ? script.src : window.location.href);

  window.addEventListener("load", () => {
    navigator.serviceWorker
      .register(workerUrl.href, { scope: new URL("./", workerUrl).href })
      .catch((error) => console.warn("Service worker registration failed:", error));
  });
})();
