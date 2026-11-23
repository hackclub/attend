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
// The page says what its kept copy depends on (scanner/offline.js). While
// that is unchanged the copy is only rendered again once it is this old.
const KEPT_COPY_MAX_AGE_MS = 6 * 60 * 60 * 1000
// How long a scanner page load may wait for the server to start answering
// before the kept copy is shown. Long, because the kept copy has no Recent
// Scans and a slow connection is still better than none; it is for a
// connection that claims to be up but carries nothing.
const PAGE_TIMEOUT_MS = 15000
// Requests that sign someone in or out, or switch who is signed in. The kept
// scanner page belongs to whoever was signed in when it was kept (it carries
// their user id and form token), so it goes when they do: otherwise the next
// person to open the scanner offline would scan as them.
const SESSION_CHANGE = /^\/(sign_out|dev_sign_in|stop_impersonation)$|^\/users\/auth\/|^\/admin\/users\/[^/]+\/impersonation$/

// Paths of the assets in the kept copy, read once when the worker starts, so
// a page can be told apart from the scanner's assets without opening the
// cache on every request.
let keptAssets = null
const keptAssetsLoaded = loadKeptAssets()

async function loadKeptAssets() {
  try {
    const cache = await caches.open(SCANNER_CACHE)
    const paths = (await cache.keys()).map((request) => new URL(request.url).pathname)
    keptAssets = new Set(paths.filter((path) => path.startsWith(ASSET_PREFIX)))
  } catch (_) {
    keptAssets = new Set()
  }
}

async function forgetScanner() {
  keptAssets = new Set()
  await caches.delete(SCANNER_CACHE)
}

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
  event.waitUntil(keepScanner(new URL(event.source.url), event.data.assets, event.data.key))
})

// Where the kept copy's key and age are noted, beside the copy itself.
const keptKeyPath = (page) => `${page.pathname}?kept`

async function keptCopyIsCurrent(cache, page, key) {
  if (typeof key !== "string" || !(await cache.match(page.pathname))) return false
  try {
    const noted = await (await cache.match(keptKeyPath(page)))?.json()
    return noted?.key === key && Date.now() - noted.keptAt < KEPT_COPY_MAX_AGE_MS
  } catch (_) {
    return false
  }
}

async function keepScanner(page, assets, key) {
  // Which page to keep comes from who is asking, never from the message.
  if (page.origin !== self.location.origin || !SCANNER_PAGE.test(page.pathname)) return

  const cache = await caches.open(SCANNER_CACHE)
  if (await keptCopyIsCurrent(cache, page, key)) return
  let complete = true

  // `?shell=1` renders the scanner with an empty Recent Scans list, so the
  // copy on the device holds no participant names.
  try {
    const shell = await fetch(`${page.pathname}?shell=1`, { credentials: "same-origin" })
    const isPage = (shell.headers.get("content-type") || "").includes("text/html")
    if (shell.ok && !shell.redirected && isPage) await cache.put(page.pathname, shell)
    else complete = false
  } catch (_) {
    // Offline already: keep whatever copy we have.
    complete = false
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
      else complete = false
    } catch (_) {
      // Picked up on the next visit.
      complete = false
    }
  }

  // Drop assets from earlier deploys.
  for (const request of await cache.keys()) {
    const path = new URL(request.url).pathname
    if (path.startsWith(ASSET_PREFIX) && !wanted.has(path)) await cache.delete(request)
  }
  await loadKeptAssets()

  // Only a copy that is all there is spared on the next visit.
  if (complete && typeof key === "string") {
    await cache.put(keptKeyPath(page), new Response(JSON.stringify({ key, keptAt: Date.now() }), {
      headers: { "Content-Type": "application/json" }
    }))
  }
}

self.addEventListener("fetch", (event) => {
  const request = event.request
  const url = new URL(request.url)
  if (url.origin !== self.location.origin) return

  if (SESSION_CHANGE.test(url.pathname)) {
    // Only watched, never answered: the request goes on as normal.
    event.waitUntil(forgetScanner())
    return
  }

  if (request.method !== "GET") return

  if (SCANNER_PAGE.test(url.pathname)) {
    event.respondWith(scannerPage(request, url))
  } else if (url.pathname.startsWith(ASSET_PREFIX) && (keptAssets === null || keptAssets.has(url.pathname))) {
    // Fingerprinted files: a kept copy is byte-for-byte what the network
    // would return. Only assets the scanner page declared are ever in here,
    // and only the scanner page is given them.
    event.respondWith(scannerAsset(event, request, url.pathname))
  }
  // Anything else: no respondWith, so the browser handles it untouched.
})

async function scannerAsset(event, request, path) {
  await keptAssetsLoaded
  if (keptAssets.has(path) && await fromScannerPage(event)) {
    const kept = await keptCopy(path)
    if (kept) return kept
  }
  return fetch(request)
}

async function fromScannerPage(event) {
  const client = event.clientId && await clients.get(event.clientId)
  return Boolean(client) && SCANNER_PAGE.test(new URL(client.url).pathname)
}

async function keptCopy(path) {
  const cache = await caches.open(SCANNER_CACHE)
  return cache.match(path, { ignoreVary: true })
}

// Network first, always: the kept copy is only for when the server can't be
// reached, doesn't start answering within PAGE_TIMEOUT_MS, or is failing.
async function scannerPage(request, url) {
  const kept = await keptCopy(url.pathname)
  if (!kept) return fetch(request)

  const network = fetch(request)
  let timer
  const timeout = new Promise((resolve) => { timer = setTimeout(() => resolve(null), PAGE_TIMEOUT_MS) })
  try {
    const response = await Promise.race([ network, timeout ])
    if (response && response.status < 500) return response
  } catch (_) {
    // Unreachable.
  } finally {
    clearTimeout(timer)
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
