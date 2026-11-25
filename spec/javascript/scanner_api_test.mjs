import assert from "node:assert/strict"
import test from "node:test"

globalThis.window = { crypto: globalThis.crypto }
globalThis.document = { querySelector: () => ({ content: "csrf-token" }) }

const { createApi, newClientScanId } =
  await import(new URL("../../app/javascript/scanner/api.js", import.meta.url))

const api = createApi({ scanUrl: "/admin/events/example/scans" })

function respond({ status = 200, json = null, redirected = false, contentType = json ? "application/json" : "text/html" }) {
  return {
    status,
    ok: status >= 200 && status < 300,
    redirected,
    headers: { get: (name) => (name === "content-type" ? contentType : null) },
    json: async () => json
  }
}

async function post(response) {
  const calls = []
  globalThis.fetch = async (url, options) => {
    calls.push({ url, options })
    if (response instanceof Error) throw response
    return response
  }
  const original = console.error
  console.error = () => {}
  try {
    return { result: await api.postScan({ participant_id: "p", client_scan_id: "c" }), calls }
  } finally {
    console.error = original
  }
}

test("posts the scan as JSON with the CSRF token and when it was sent", async () => {
  const { result, calls } = await post(respond({ json: { success: true, scan_id: "s" } }))

  assert.deepEqual(result, { outcome: "ok", data: { success: true, scan_id: "s" } })
  assert.equal(calls[0].url, "/admin/events/example/scans")
  assert.equal(calls[0].options.method, "POST")
  assert.equal(calls[0].options.headers["X-CSRF-Token"], "csrf-token")
  const body = JSON.parse(calls[0].options.body)
  assert.equal(body.participant_id, "p")
  assert.equal(body.client_scan_id, "c")
  assert.ok(!Number.isNaN(Date.parse(body.client_sent_at)))
})

test("tells a request that never arrived from one the server answered", async () => {
  assert.deepEqual((await post(new TypeError("Failed to fetch"))).result, { outcome: "unreachable" })
  assert.deepEqual((await post(respond({ status: 502 }))).result, { outcome: "server", status: 502 })
  assert.deepEqual((await post(respond({ status: 500, json: { error: "boom" } }))).result, { outcome: "server", status: 500 })
})

test("reports what the server said when it turned the scan down", async () => {
  assert.deepEqual(
    (await post(respond({ status: 404, json: { error: "Participant not found for this event" } }))).result,
    { outcome: "refused", status: 404, message: "Participant not found for this event" }
  )
  assert.deepEqual(
    (await post(respond({ status: 422, json: { error: "Invalid scan context" } }))).result,
    { outcome: "refused", status: 422, message: "Invalid scan context" }
  )
  assert.equal((await post(respond({ status: 409, json: { error: "used" } }))).result.outcome, "refused")
  assert.equal((await post(respond({ status: 429 }))).result.outcome, "refused")
})

test("reads a redirect or an HTML page as an expired session", async () => {
  assert.deepEqual((await post(respond({ status: 200, redirected: true }))).result, { outcome: "session" })
  assert.deepEqual((await post(respond({ status: 200 }))).result, { outcome: "session" })
  assert.deepEqual((await post(respond({ status: 401, json: { error: "sign in" } }))).result, { outcome: "session" })
  assert.deepEqual((await post(respond({ status: 403 }))).result, { outcome: "session" })
})

test("makes scan ids the server accepts", () => {
  const ids = new Set(Array.from({ length: 50 }, newClientScanId))
  assert.equal(ids.size, 50)
  for (const id of ids) assert.match(id, /^[A-Za-z0-9_-]{16,64}$/)
})
