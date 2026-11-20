// This worker exists so the app is installable, and so the check-in scanner
// can be reloaded at a venue door with no connection.
//
// It is deliberately narrow. The only page it ever keeps is the scanner, as
// a copy rendered without any scan data, plus the scripts and stylesheets
// that page declares. Everything else goes straight to the network as if
// this worker weren't here, so Turbo pages can never go stale behind a cache,
// and no participant data, search result or API response is ever stored.
const SCANNER_CACHE = "attend-scanner-v1"
const SCANNER_PAGE = /^\/admin\/events\/[^/]+\/scans\/scanner$/
const ASSET_PREFIX = "/assets/"
const MAX_ASSETS = 500
// How long a scanner page load may hang before the kept copy is shown.
const PAGE_TIMEOUT_MS = 5000

self.addEventListener("install", () => self.skipWaiting())
self.addEventListener("activate", (event) => event.waitUntil((async () => {
  for (const name of await caches.keys()) {
    if (name.startsWith("attend-scanner-") && name !== SCANNER_CACHE) await caches.delete(name)
  }
  await clients.claim()
})()))

// The scanner page asks to be kept (app/javascript/scanner/offline.js).
self.addEventListener("message", (event) => {
  if (event.data?.type !== "scanner:keep" || !event.source?.url) return
  event.waitUntil(keepScanner(new URL(event.source.url), event.data.assets))
})

async function keepScanner(page, assets) {
  // Which page to keep comes from who is asking, never from the message.
  if (page.origin !== self.location.origin || !SCANNER_PAGE.test(page.pathname)) return

  const cache = await caches.open(SCANNER_CACHE)

  // `?shell=1` renders the scanner with an empty Recent Scans list, so the
  // copy on the device holds no participant names.
  try {
    const shell = await fetch(`${page.pathname}?shell=1`, { credentials: "same-origin" })
    const isPage = (shell.headers.get("content-type") || "").includes("text/html")
    if (shell.ok && !shell.redirected && isPage) await cache.put(page.pathname, shell)
  } catch (_) {
    // Offline already: keep whatever copy we have.
  }

  const wanted = new Set(
    (Array.isArray(assets) ? assets : [])
      .filter((path) => typeof path === "string" && path.startsWith(ASSET_PREFIX))
      .slice(0, MAX_ASSETS)
  )
  for (const path of wanted) {
    if (await cache.match(path, { ignoreVary: true })) continue
    try {
      const response = await fetch(path, { credentials: "same-origin" })
      if (response.ok) await cache.put(path, response)
    } catch (_) {
      // Picked up on the next visit.
    }
  }

  // Drop assets from earlier deploys.
  for (const request of await cache.keys()) {
    const path = new URL(request.url).pathname
    if (path.startsWith(ASSET_PREFIX) && !wanted.has(path)) await cache.delete(request)
  }
}

self.addEventListener("fetch", (event) => {
  const request = event.request
  if (request.method !== "GET") return

  const url = new URL(request.url)
  if (url.origin !== self.location.origin) return

  if (SCANNER_PAGE.test(url.pathname)) {
    event.respondWith(scannerPage(request, url))
  } else if (url.pathname.startsWith(ASSET_PREFIX)) {
    // Fingerprinted files: a kept copy is byte-for-byte what the network
    // would return. Only assets the scanner page declared are ever in here.
    event.respondWith(keptCopy(url.pathname).then((kept) => kept || fetch(request)))
  }
  // Anything else: no respondWith, so the browser handles it untouched.
})

async function keptCopy(path) {
  const cache = await caches.open(SCANNER_CACHE)
  return cache.match(path, { ignoreVary: true })
}

// Network first, always: the kept copy is only for when the server can't be
// reached, takes too long, or is failing.
async function scannerPage(request, url) {
  const kept = await keptCopy(url.pathname)
  if (!kept) return fetch(request)

  const network = fetch(request)
  const timeout = new Promise((resolve) => setTimeout(() => resolve(null), PAGE_TIMEOUT_MS))
  try {
    const response = await Promise.race([ network, timeout ])
    if (response && response.status < 500) return response
  } catch (_) {
    // Unreachable.
  }
  // Don't leave the abandoned request to reject unhandled.
  network.catch(() => {})
  return kept
}

// Add a service worker for processing Web Push notifications:
//
// self.addEventListener("push", async (event) => {
//   const { title, options } = await event.data.json()
//   event.waitUntil(self.registration.showNotification(title, options))
// })
//
// self.addEventListener("notificationclick", function(event) {
//   event.notification.close()
//   event.waitUntil(
//     clients.matchAll({ type: "window" }).then((clientList) => {
//       for (let i = 0; i < clientList.length; i++) {
//         let client = clientList[i]
//         let clientPath = (new URL(client.url)).pathname
//
//         if (clientPath == event.notification.data.path && "focus" in client) {
//           return client.focus()
//         }
//       }
//
//       if (clients.openWindow) {
//         return clients.openWindow(event.notification.data.path)
//       }
//     })
//   )
// })
