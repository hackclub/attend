import assert from "node:assert/strict"
import test from "node:test"

globalThis.window = { addEventListener() {} }
globalThis.document = { addEventListener() {}, visibilityState: "visible" }

const { createScanQueue, retryDelay, MAX_SERVER_ERRORS } =
  await import(new URL("../../app/javascript/scanner/sync.js", import.meta.url))

const SCOPE = { eventId: "event-1", userId: "user-1" }

function memoryStore(records = []) {
  const rows = new Map(records.map((record) => [ record.clientScanId, { ...record } ]))
  return {
    rows,
    all: async () => [ ...rows.values() ].map((row) => ({ ...row })),
    put: async (record) => { rows.set(record.clientScanId, { ...record }) },
    remove: async (clientScanId) => { rows.delete(clientScanId) }
  }
}

function queued(clientScanId, clientScannedAt, overrides = {}) {
  return {
    clientScanId,
    clientScannedAt,
    body: { participant_id: `participant-${clientScanId}`, scan_context_id: "context-1" },
    label: "ID 0000",
    status: "queued",
    attempts: 1,
    ...SCOPE,
    ...overrides
  }
}

// `answers` maps a client_scan_id to the outcome the server gives it.
function build(records, answers) {
  const store = memoryStore(records)
  const posted = []
  const synced = []
  const controller = new AbortController()
  const queue = createScanQueue({
    store,
    scope: SCOPE,
    signal: controller.signal,
    api: {
      postScan: async (body) => {
        posted.push(body)
        return answers[body.client_scan_id] || { outcome: "ok", data: { scan_id: body.client_scan_id } }
      }
    },
    onChange() {},
    onSynced: (record, data) => synced.push([ record.clientScanId, data ])
  })
  return { store, posted, synced, queue, stop: () => controller.abort() }
}

test("sends queued scans oldest first, with the id and time they were saved under", async () => {
  const { store, posted, synced, queue, stop } = build([
    queued("b", "2026-08-24T09:42:00.000Z"),
    queued("a", "2026-08-24T09:41:00.000Z")
  ], {})

  await queue.load()
  await queue.sync()
  stop()

  assert.deepEqual(posted.map((body) => body.client_scan_id), [ "a", "b" ])
  assert.deepEqual(posted[0], {
    participant_id: "participant-a",
    scan_context_id: "context-1",
    client_scan_id: "a",
    client_scanned_at: "2026-08-24T09:41:00.000Z"
  })
  assert.deepEqual(synced.map(([ id ]) => id), [ "a", "b" ])
  assert.equal(store.rows.size, 0)
  assert.deepEqual(queue.snapshot().queued, [])
})

test("keeps a scan queued while the server can't be reached, and stops there", async () => {
  const { store, posted, queue, stop } = build([
    queued("a", "2026-08-24T09:41:00.000Z"),
    queued("b", "2026-08-24T09:42:00.000Z")
  ], { a: { outcome: "unreachable" } })

  await queue.load()
  await queue.sync()
  stop()

  assert.deepEqual(posted.map((body) => body.client_scan_id), [ "a" ])
  assert.equal(store.rows.get("a").status, "queued")
  assert.equal(store.rows.get("a").attempts, 2)
  assert.equal(queue.snapshot().queued.length, 2)
})

test("retries after a server error too", async () => {
  const { store, queue, stop } = build([ queued("a", "2026-08-24T09:41:00.000Z") ], { a: { outcome: "server", status: 503 } })

  await queue.load()
  await queue.sync()
  stop()

  assert.equal(store.rows.get("a").status, "queued")
})

test("doesn't let one scan the server fails on hold up the ones behind it", async () => {
  const { store, posted, synced, queue, stop } = build([
    queued("a", "2026-08-24T09:41:00.000Z"),
    queued("b", "2026-08-24T09:42:00.000Z")
  ], { a: { outcome: "server", status: 500 } })

  await queue.load()
  await queue.sync()
  stop()

  assert.deepEqual(posted.map((body) => body.client_scan_id), [ "a", "b" ])
  assert.deepEqual(synced.map(([ id ]) => id), [ "b" ])
  assert.equal(store.rows.get("a").status, "queued")
  assert.equal(store.rows.get("a").serverErrors, 1)
  assert.deepEqual(queue.snapshot().queued.map((record) => record.clientScanId), [ "a" ])
})

test("sets a scan aside for the operator once the server has failed on it too often", async () => {
  const { store, queue, stop } = build([
    queued("a", "2026-08-24T09:41:00.000Z", { serverErrors: MAX_SERVER_ERRORS - 1 }),
    queued("b", "2026-08-24T09:42:00.000Z")
  ], { a: { outcome: "server", status: 500 } })

  await queue.load()
  await queue.sync()
  stop()

  assert.equal(store.rows.get("a").status, "rejected")
  assert.match(store.rows.get("a").error, /kept failing/)
  assert.deepEqual(queue.snapshot().queued, [])
})

test("never sets scans aside while the server is failing on all of them", async () => {
  const records = [ "a", "b", "c", "d" ].map((id, i) =>
    queued(id, `2026-08-24T09:4${i}:00.000Z`, { serverErrors: MAX_SERVER_ERRORS - 1 }))
  const down = { outcome: "server", status: 503 }
  const { store, posted, queue, stop } = build(records, { a: down, b: down, c: down, d: down })

  await queue.load()
  await queue.sync()
  stop()

  // Three in a row and it stops asking, as it would for no connection.
  assert.deepEqual(posted.map((body) => body.client_scan_id), [ "a", "b", "c" ])
  assert.deepEqual([ ...store.rows.values() ].map((row) => row.status), [ "queued", "queued", "queued", "queued" ])
  assert.equal(queue.snapshot().queued.length, 4)
})

test("keeps a scan the server turned down where the operator can see it, and carries on", async () => {
  const { store, posted, synced, queue, stop } = build([
    queued("a", "2026-08-24T09:41:00.000Z"),
    queued("b", "2026-08-24T09:42:00.000Z")
  ], { a: { outcome: "refused", status: 404, message: "Participant not found for this event" } })

  await queue.load()
  await queue.sync()

  const state = queue.snapshot()
  assert.deepEqual(state.queued, [])
  assert.deepEqual(state.rejected.map((record) => [ record.clientScanId, record.error ]), [ [ "a", "Participant not found for this event" ] ])
  assert.equal(store.rows.get("a").status, "rejected")
  assert.deepEqual(synced.map(([ id ]) => id), [ "b" ])

  // Rejected for good: never sent again, and gone once dismissed.
  await queue.sync()
  assert.deepEqual(posted.map((body) => body.client_scan_id), [ "a", "b" ])
  await queue.dismiss("a")
  stop()
  assert.equal(store.rows.size, 0)
  assert.deepEqual(queue.snapshot().rejected, [])
})

test("holds on to queued scans when the session has expired", async () => {
  const { store, posted, queue, stop } = build([
    queued("a", "2026-08-24T09:41:00.000Z"),
    queued("b", "2026-08-24T09:42:00.000Z")
  ], { a: { outcome: "session" } })

  await queue.load()
  await queue.sync()
  stop()

  const state = queue.snapshot()
  assert.equal(state.sessionExpired, true)
  assert.equal(state.queued.length, 2)
  assert.deepEqual(state.rejected, [])
  assert.deepEqual(posted.map((body) => body.client_scan_id), [ "a" ])
  assert.equal(store.rows.size, 2)
})

test("only sends scans saved for this event by this user", async () => {
  const { store, posted, queue, stop } = build([
    queued("mine", "2026-08-24T09:41:00.000Z"),
    queued("other-event", "2026-08-24T09:40:00.000Z", { eventId: "event-2" }),
    queued("other-user", "2026-08-24T09:39:00.000Z", { userId: "user-2" })
  ], {})

  await queue.load()
  assert.equal(queue.snapshot().elsewhere, 2)
  await queue.sync()
  stop()

  assert.deepEqual(posted.map((body) => body.client_scan_id), [ "mine" ])
  assert.deepEqual([ ...store.rows.keys() ].sort(), [ "other-event", "other-user" ])
})

test("saves a new scan under this event and user", async () => {
  const { store, queue, stop } = build([], {})

  await queue.load()
  await queue.enqueue({ clientScanId: "new", clientScannedAt: "2026-08-24T09:41:00.000Z", body: { participant_id: "p" }, label: "ID P" })
  stop()

  assert.deepEqual(store.rows.get("new"), {
    clientScanId: "new",
    clientScannedAt: "2026-08-24T09:41:00.000Z",
    body: { participant_id: "p" },
    label: "ID P",
    ...SCOPE,
    status: "queued",
    attempts: 1
  })
})

test("discards only this scanner's queued scans", async () => {
  const { store, queue, stop } = build([
    queued("mine", "2026-08-24T09:41:00.000Z"),
    queued("turned-down", "2026-08-24T09:40:00.000Z", { status: "rejected" }),
    queued("other-event", "2026-08-24T09:40:00.000Z", { eventId: "event-2" })
  ], {})

  await queue.load()
  await queue.discardQueued()
  stop()

  assert.deepEqual([ ...store.rows.keys() ].sort(), [ "other-event", "turned-down" ])
})

test("backs off from two seconds to a minute", () => {
  for (let failures = 1; failures <= 12; failures++) {
    const expected = Math.min(60000, 2000 * 2 ** (failures - 1))
    const delay = retryDelay(failures)
    assert.ok(delay >= expected * 0.8 && delay <= expected * 1.2, `${delay}ms after ${failures} failures`)
  }
})
