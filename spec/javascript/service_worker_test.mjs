import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"
import vm from "node:vm"

const source = await readFile(new URL("../../app/views/pwa/service-worker.js", import.meta.url), "utf8")

const ORIGIN = "https://attend.test"
const SCANNER = "/admin/events/sample-event/scans/scanner"
const ASSET = "/assets/application-abc123.js"

function fakeCache(entries = {}) {
  const rows = new Map(Object.entries(entries))
  return {
    rows,
    match: async (path) => rows.get(typeof path === "string" ? path : new URL(path.url).pathname + new URL(path.url).search) || undefined,
    put: async (path, response) => { rows.set(path, response) },
    keys: async () => [ ...rows.keys() ].map((path) => ({ url: `${ORIGIN}${path}` })),
    delete: async (request) => rows.delete(new URL(request.url).pathname + new URL(request.url).search)
  }
}

function page(body, contentType = "text/html") {
  return {
    ok: true,
    status: 200,
    redirected: false,
    body,
    headers: { get: (name) => (name.toLowerCase() === "content-type" ? contentType : null) },
    json: async () => JSON.parse(body)
  }
}

// Runs the worker against fake caches, clients and network, and hands back
// its listeners.
async function boot({ kept = {}, clientUrls = {}, network = async (url) => page(`live ${url}`) } = {}) {
  const stores = new Map([ [ "attend-scanner-v1", fakeCache(kept) ] ])
  const listeners = {}
  const fetched = []
  const context = {
    URL,
    console,
    setTimeout,
    clearTimeout,
    JSON,
    Date,
    Set,
    Promise,
    Array,
    Boolean,
    Response: class { constructor(body) { Object.assign(this, page(body, "application/json")) } },
    self: {
      location: { origin: ORIGIN },
      addEventListener: (type, listener) => { listeners[type] = listener },
      skipWaiting() {}
    },
    caches: {
      open: async (name) => {
        if (!stores.has(name)) stores.set(name, fakeCache())
        return stores.get(name)
      },
      delete: async (name) => stores.delete(name),
      keys: async () => [ ...stores.keys() ]
    },
    clients: {
      get: async (id) => (clientUrls[id] ? { url: `${ORIGIN}${clientUrls[id]}` } : undefined),
      claim: async () => {}
    },
    fetch: async (request, options) => {
      const url = typeof request === "string" ? request : request.url
      fetched.push(url)
      return network(url, options)
    }
  }
  vm.runInNewContext(source, context)
  // Let the worker read its cache once, as it does on start.
  await new Promise((resolve) => setTimeout(resolve, 0))

  function fire(type, data) {
    let answer = null
    const waits = []
    const event = {
      ...data,
      respondWith: (promise) => { answer = promise },
      waitUntil: (promise) => { waits.push(promise) }
    }
    listeners[type](event)
    return { answer, settled: Promise.all(waits) }
  }

  function request(path, { method = "GET", clientId = "" } = {}) {
    return fire("fetch", { request: { url: `${ORIGIN}${path}`, method }, clientId })
  }

  return { stores, fetched, fire, request }
}

test("forgets the kept scanner when someone signs out", async () => {
  const worker = await boot({ kept: { [SCANNER]: page("shell"), [ASSET]: page("js") } })

  const { answer, settled } = worker.request("/sign_out", { method: "DELETE" })
  await settled

  assert.equal(answer, null)
  assert.equal(worker.stores.has("attend-scanner-v1"), false)
})

test("forgets the kept scanner when someone signs in", async () => {
  const worker = await boot({ kept: { [SCANNER]: page("shell") } })

  await worker.request("/users/auth/hack_club/callback?code=x").settled

  assert.equal(worker.stores.has("attend-scanner-v1"), false)
})

test("gives the kept assets only to the scanner page", async () => {
  const worker = await boot({
    kept: { [ASSET]: page("kept js") },
    clientUrls: { scanner: SCANNER, other: "/admin/events/sample-event" }
  })

  assert.equal((await worker.request(ASSET, { clientId: "scanner" }).answer).body, "kept js")
  assert.equal((await worker.request(ASSET, { clientId: "other" }).answer).body, `live ${ORIGIN}${ASSET}`)
})

test("leaves assets the scanner never kept to the browser", async () => {
  const worker = await boot({ kept: { [ASSET]: page("kept js") }, clientUrls: { scanner: SCANNER } })

  assert.equal(worker.request("/assets/other-def456.css", { clientId: "scanner" }).answer, null)
  assert.equal(worker.request("/admin/events", { clientId: "scanner" }).answer, null)
})

test("shows the live scanner page when the server answers, and the kept one when it can't", async () => {
  let online = true
  const worker = await boot({
    kept: { [SCANNER]: page("shell") },
    network: async (url) => {
      if (!online) throw new TypeError("Failed to fetch")
      return page(`live ${url}`)
    }
  })

  assert.equal((await worker.request(SCANNER).answer).body, `live ${ORIGIN}${SCANNER}`)
  online = false
  assert.equal((await worker.request(SCANNER).answer).body, "shell")
})

test("only renders the kept scanner again when what it depends on has changed", async () => {
  const worker = await boot({ clientUrls: {} })
  const keep = (key) => worker.fire("message", {
    data: { type: "scanner:keep", assets: [ ASSET ], key },
    source: { url: `${ORIGIN}${SCANNER}` }
  }).settled
  const shellRenders = () => worker.fetched.filter((url) => url.endsWith("?shell=1")).length

  await keep("key-1")
  await keep("key-1")
  assert.equal(shellRenders(), 1)
  assert.equal(worker.fetched.filter((url) => url === ASSET).length, 1)

  await keep("key-2")
  assert.equal(shellRenders(), 2)
})
