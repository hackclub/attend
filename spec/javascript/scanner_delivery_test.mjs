import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

// delivery.js imports through the importmap, which Node doesn't have.
const source = await readFile(new URL("../../app/javascript/scanner/delivery.js", import.meta.url), "utf8")
const runnable = source.replace('import { newClientScanId } from "scanner/api"', 'const newClientScanId = () => "client-scan-1"')
const { createDelivery } = await import(`data:text/javascript;base64,${Buffer.from(runnable).toString("base64")}`)

const PARTICIPANT = "0b0f6c1e-4f5a-4d0e-9a53-2f1d7c9e8a10"
const SCAN = { participant_id: PARTICIPANT, scan_context_id: "context-1" }

function build(outcome, { queue = true, enqueueFails = false } = {}) {
  const posted = []
  const saved = []
  let synced = 0
  const scanQueue = {
    enqueue: async (record) => {
      if (enqueueFails) throw new Error("quota")
      saved.push(record)
    },
    sync: () => { synced++ }
  }
  const deliver = createDelivery({
    api: { postScan: async (body) => { posted.push(body); return outcome } },
    queue: () => (queue ? scanQueue : null),
    contexts: { "context-1": "Main door" }
  })
  return { deliver, posted, saved, synced: () => synced }
}

const quiet = (run) => async () => {
  const original = console.error
  console.error = () => {}
  try { await run() } finally { console.error = original }
}

test("sends every scan with an id and time of its own", async () => {
  const { deliver, posted, saved, synced } = build({ outcome: "ok", data: { scan_id: "s" } })

  const result = await deliver(SCAN, { label: "ID 0B0F6C1E" })

  assert.deepEqual(result, { status: "recorded", data: { scan_id: "s" } })
  assert.equal(posted[0].client_scan_id, "client-scan-1")
  assert.ok(!Number.isNaN(Date.parse(posted[0].client_scanned_at)))
  assert.deepEqual(saved, [])
  assert.equal(synced(), 1, "a scan getting through sends anything waiting")
})

for (const outcome of [ "unreachable", "server" ]) {
  test(`saves a scan for later when the result is ${outcome}`, async () => {
    const { deliver, posted, saved } = build({ outcome })

    const result = await deliver(SCAN, { label: "ID 0B0F6C1E" })

    assert.deepEqual(result, { status: "queued", reason: outcome })
    assert.deepEqual(saved, [ {
      clientScanId: posted[0].client_scan_id,
      clientScannedAt: posted[0].client_scanned_at,
      body: SCAN,
      label: "ID 0B0F6C1E",
      contextName: "Main door"
    } ])
  })
}

test("saves a badge tap for later", async () => {
  const { deliver, saved } = build({ outcome: "unreachable" })

  const result = await deliver({ badge_token: "badge-token", scan_context_id: "context-1" }, { label: "NFC badge" })

  assert.equal(result.status, "queued")
  assert.equal(saved.length, 1)
})

test("never saves a scan the server turned down", async () => {
  for (const status of [ 404, 409, 422 ]) {
    const { deliver, saved } = build({ outcome: "refused", status, message: "Participant not found for this event" })

    const result = await deliver(SCAN, { label: "ID 0B0F6C1E" })

    assert.deepEqual(result, { status: "failed", message: "Participant not found for this event" })
    assert.deepEqual(saved, [])
  }
})

test("never saves a scan made with an expired session", async () => {
  const { deliver, saved } = build({ outcome: "session" })

  const result = await deliver(SCAN, { label: "ID 0B0F6C1E" })

  assert.equal(result.status, "failed")
  assert.equal(result.reload, true)
  assert.deepEqual(saved, [])
})

test("doesn't save a code that isn't shaped like a participant's", async () => {
  const { deliver, saved } = build({ outcome: "unreachable" })

  const result = await deliver({ participant_id: "https://example.com/menu", scan_context_id: "context-1" }, { label: "ID HTTPS://" })

  assert.equal(result.status, "failed")
  assert.match(result.detail, /not recorded/)
  assert.deepEqual(saved, [])
})

// app.js has already checked its signature by the time it gets here.
test("saves a signed ticket for later", async () => {
  const { deliver, saved } = build({ outcome: "unreachable" })
  const ticket = { participant_id: "T.AED2VKVKVK53WTGMRXO653XO53XO5Z3XVB66Q34V", scan_context_id: "context-1" }

  const result = await deliver(ticket, { label: "Ticket AAAAAAAA" })

  assert.equal(result.status, "queued")
  assert.deepEqual(saved.map((record) => record.body), [ ticket ])
})

test("says the scan was not recorded where scans can't be saved", async () => {
  const offline = await build({ outcome: "unreachable" }, { queue: false }).deliver(SCAN, { label: "ID" })
  assert.equal(offline.status, "failed")
  assert.equal(offline.detail, "The scan was not recorded.")

  const failing = await build({ outcome: "server" }, { queue: false }).deliver(SCAN, { label: "ID" })
  assert.equal(failing.status, "failed")
  assert.match(failing.message, /may not have been recorded/)
})

test("says the scan was not recorded when saving it fails", quiet(async () => {
  const { deliver } = build({ outcome: "unreachable" }, { enqueueFails: true })

  const result = await deliver(SCAN, { label: "ID" })

  assert.equal(result.status, "failed")
  assert.equal(result.detail, "The scan was not recorded.")
}))
