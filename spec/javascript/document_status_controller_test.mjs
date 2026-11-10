import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

const controllerUrl = new URL("../../app/javascript/controllers/document_status_controller.js", import.meta.url)
const controllerSource = await readFile(controllerUrl, "utf8")
const runnableSource = controllerSource.replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
const { default: DocumentStatusController } = await import(`data:text/javascript;base64,${Buffer.from(runnableSource).toString("base64")}`)

// A stand-in document whose visibility the test flips, and a fetch that
// answers with whatever the server would say is signed.
function setup(t, { signed = [] } = {}) {
  const listeners = {}
  const state = { fetches: 0, reloads: 0, signed }
  globalThis.document = {
    hidden: false,
    documentElement: { hasAttribute: () => false },
    addEventListener(type, fn) { listeners[type] = fn },
    removeEventListener(type) { delete listeners[type] }
  }
  globalThis.fetch = async () => {
    state.fetches += 1
    return { ok: true, json: async () => ({ signed_consent_ids: state.signed }) }
  }
  globalThis.window = { location: { reload() { state.reloads += 1 } } }
  t.after(() => { delete globalThis.document; delete globalThis.fetch; delete globalThis.window })

  const controller = new DocumentStatusController()
  controller.urlValue = "/onboarding/documents/status"
  controller.signedIdsValue = []
  controller.intervalValue = 5000
  controller.maxIntervalValue = 30000
  controller.backoffValue = 1.5
  return { controller, state, listeners }
}

// Lets the awaited fetch/json promises settle between timer ticks.
const flush = () => new Promise((resolve) => setImmediate(resolve))

async function advance(t, ms) {
  t.mock.timers.tick(ms)
  await flush()
}

test("polls slower the longer the page sits unchanged, up to the cap", async (t) => {
  t.mock.timers.enable({ apis: [ "setTimeout" ] })
  const { controller, state } = setup(t)
  controller.connect()

  for (const delay of [ 5000, 7500, 11250, 16875, 25312.5, 30000, 30000 ]) {
    const before = state.fetches
    await advance(t, delay - 1)
    assert.equal(state.fetches, before, `no poll before ${delay}ms`)
    await advance(t, 1)
    assert.equal(state.fetches, before + 1, `a poll at ${delay}ms`)
  }

  controller.disconnect()
})

test("coming back to the tab checks at once and restarts the fast polling", async (t) => {
  t.mock.timers.enable({ apis: [ "setTimeout" ] })
  const { controller, state, listeners } = setup(t)
  controller.connect()
  for (const delay of [ 5000, 7500, 11250 ]) await advance(t, delay)
  assert.equal(state.fetches, 3)

  listeners.visibilitychange()
  await flush()
  assert.equal(state.fetches, 4)

  await advance(t, 7500)
  assert.equal(state.fetches, 5)

  controller.disconnect()
})

test("reloads once the signed set changes, then stops polling", async (t) => {
  t.mock.timers.enable({ apis: [ "setTimeout" ] })
  const { controller, state } = setup(t, { signed: [ "abc" ] })
  controller.connect()

  await advance(t, 5000)
  assert.equal(state.reloads, 1)

  await advance(t, 60000)
  assert.equal(state.fetches, 1)
})
