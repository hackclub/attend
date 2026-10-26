import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

const utilUrl = new URL("../../app/javascript/utils/drop_blank_fields.js", import.meta.url)
const { dropBlankFields } = await import(utilUrl)

const controllerUrl = new URL("../../app/javascript/controllers/auto_submit_controller.js", import.meta.url)
const controllerSource = await readFile(controllerUrl, "utf8")
const runnableSource = controllerSource
  .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
  .replace('import { dropBlankFields } from "utils/drop_blank_fields"', `import { dropBlankFields } from "${utilUrl}"`)
const { default: AutoSubmitController } = await import(`data:text/javascript;base64,${Buffer.from(runnableSource).toString("base64")}`)

// The form's query is whatever the test says it is; FormData(form) needs a DOM.
function buildController({ query = "" } = {}) {
  const controller = new AutoSubmitController()
  const state = { query, submits: 0, resets: 0 }
  controller.element = {
    reset() { state.resets += 1 },
    requestSubmit() {
      state.submits += 1
      controller.submitted()
    }
  }
  controller.searchTarget = { value: "", defaultValue: "" }
  controller.delayValue = 300
  controller.query = () => state.query
  return { controller, state }
}

test("dropBlankFields drops blanks without taking same-named values with them", () => {
  const formData = new FormData()
  formData.append("search", "")
  formData.append("roles[]", "")
  formData.append("roles[]", "lead")
  formData.append("status", "complete")

  dropBlankFields(formData)

  assert.deepEqual([ ...formData ], [ [ "roles[]", "lead" ], [ "status", "complete" ] ])
})

test("connect resets the controls and remembers what the results are filtered by", () => {
  const { controller, state } = buildController({ query: "?search=ada" })

  controller.connect()

  assert.equal(state.resets, 1)
  assert.equal(controller.submittedQuery, "?search=ada")
})

test("a debounced change submits once the delay passes", (t) => {
  t.mock.timers.enable({ apis: [ "setTimeout" ] })
  const { controller, state } = buildController()
  controller.connect()

  state.query = "?search=ad"
  controller.debouncedSubmit({})
  state.query = "?search=ada"
  controller.debouncedSubmit({})
  t.mock.timers.tick(299)
  assert.equal(state.submits, 0)

  t.mock.timers.tick(1)
  assert.equal(state.submits, 1)
  assert.equal(controller.submittedQuery, "?search=ada")
})

test("a change back to the last submitted query isn't re-sent, even before the URL catches up", (t) => {
  t.mock.timers.enable({ apis: [ "setTimeout" ] })
  const { controller, state } = buildController()
  controller.connect()

  state.query = "?search=abc"
  controller.debouncedSubmit({})
  t.mock.timers.tick(300)
  assert.equal(state.submits, 1)

  // Typed "d" and deleted it while results for "abc" are still loading.
  controller.debouncedSubmit({})
  t.mock.timers.tick(300)
  assert.equal(state.submits, 1)
})

test("IME composition waits for compositionend", (t) => {
  t.mock.timers.enable({ apis: [ "setTimeout" ] })
  const { controller, state } = buildController()
  controller.connect()

  state.query = "?search=%E3%81%82"
  controller.debouncedSubmit({ isComposing: true })
  t.mock.timers.tick(300)
  assert.equal(state.submits, 0)

  controller.debouncedSubmit({})
  t.mock.timers.tick(300)
  assert.equal(state.submits, 1)
})

test("cancel drops a change that hasn't been sent", (t) => {
  t.mock.timers.enable({ apis: [ "setTimeout" ] })
  const { controller, state } = buildController()
  controller.connect()

  state.query = "?search=ada"
  controller.debouncedSubmit({})
  controller.cancel()
  t.mock.timers.tick(300)

  assert.equal(state.submits, 0)
})

test("keepTypedSearch keeps what's typed and moves the field's default to the results", (t) => {
  const { controller } = buildController()
  t.after(() => { delete globalThis.document })
  globalThis.document = { activeElement: controller.searchTarget }
  controller.searchTarget.value = "ada lo"
  const newElement = { value: "ada", defaultValue: "ada" }

  controller.keepTypedSearch({ detail: { newElement } })

  assert.equal(newElement.value, "ada lo")
  assert.equal(newElement.defaultValue, "ada")
  assert.equal(controller.searchTarget.defaultValue, "ada")
})

test("keepTypedSearch leaves the field to the results when nobody is typing", (t) => {
  const { controller } = buildController()
  t.after(() => { delete globalThis.document })
  globalThis.document = { activeElement: null }
  controller.searchTarget.value = "stale"
  const newElement = { value: "ada", defaultValue: "ada" }

  controller.keepTypedSearch({ detail: { newElement } })

  assert.equal(newElement.value, "ada")
})
