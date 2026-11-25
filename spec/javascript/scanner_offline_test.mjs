import assert from "node:assert/strict"
import test from "node:test"

const { keptCopyKey } = await import(new URL("../../app/javascript/scanner/offline.js", import.meta.url))

const CONFIG = { eventId: "event-1", userId: "user-1", contexts: { "context-1": "Main door" } }

test("keys the kept scanner on its assets and config, in any order", () => {
  const key = keptCopyKey([ "/assets/a-1.js", "/assets/b-1.css" ], CONFIG)

  assert.equal(keptCopyKey([ "/assets/b-1.css", "/assets/a-1.js" ], CONFIG), key)
  assert.notEqual(keptCopyKey([ "/assets/a-2.js", "/assets/b-1.css" ], CONFIG), key)
  assert.notEqual(keptCopyKey([ "/assets/a-1.js", "/assets/b-1.css" ], { ...CONFIG, userId: "user-2" }), key)
  assert.notEqual(keptCopyKey([ "/assets/a-1.js", "/assets/b-1.css" ], { ...CONFIG, contexts: {} }), key)
})
