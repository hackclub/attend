// Asks the service worker (app/views/pwa/service-worker.js) to keep this
// page loadable without a connection: a copy of the page with no scan data in
// it, and the scripts and stylesheets it runs on. Nothing else is cached; in
// particular no participant, search result or API response ever is.
const ASSET_PREFIX = "/assets/"

function assetPaths() {
  const paths = new Set()
  const add = (value) => {
    try {
      const url = new URL(value, window.location.href)
      if (url.origin === window.location.origin && url.pathname.startsWith(ASSET_PREFIX)) paths.add(url.pathname)
    } catch (_) {
      // Not a URL; nothing to keep.
    }
  }

  document.querySelectorAll('link[rel~="stylesheet"][href], link[rel="modulepreload"][href]').forEach((link) => add(link.href))
  document.querySelectorAll("script[src]").forEach((script) => add(script.src))
  // Every module the page could import, loaded yet or not.
  try {
    const importmap = JSON.parse(document.querySelector('script[type="importmap"]').textContent)
    Object.values(importmap.imports || {}).forEach(add)
  } catch (_) {
    // No importmap to read; the entries below still cover what has loaded.
  }
  // Fonts and images pulled in by the stylesheets.
  performance.getEntriesByType("resource").forEach((entry) => add(entry.name))

  return [...paths]
}

export function keepAvailableOffline() {
  if (!("serviceWorker" in navigator)) return

  navigator.serviceWorker.ready.then((registration) => {
    // After the page has settled, so late-loading assets are listed too.
    setTimeout(() => {
      registration.active?.postMessage({ type: "scanner:keep", assets: assetPaths() })
    }, 3000)
  }).catch((error) => console.warn("Scanner can't be kept for offline use:", error))
}
