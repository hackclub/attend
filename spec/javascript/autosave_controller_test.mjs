import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

const controllerUrl = new URL("../../app/javascript/controllers/autosave_controller.js", import.meta.url)
const controllerSource = await readFile(controllerUrl, "utf8")
const runnableSource = controllerSource.replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
const { default: AutosaveController } = await import(`data:text/javascript;base64,${Buffer.from(runnableSource).toString("base64")}`)

class FakeFormData {
  constructor() {
    this.values = new Map()
  }

  append(name, value) {
    this.values.set(name, value)
  }

  delete(name) {
    this.values.delete(name)
  }

  set(name, value) {
    this.values.set(name, value)
  }
}

function deferred() {
  let resolve
  const promise = new Promise((resolver) => { resolve = resolver })
  return { promise, resolve }
}

function classList() {
  const classes = new Set(["hidden"])
  return {
    contains(name) { return classes.has(name) },
    toggle(name, force) {
      if (force) classes.add(name)
      else classes.delete(name)
    }
  }
}

let documentStatus = null

function buildController({ files = [], skippedLegs = [], pendingDeletions = [], notifyOnly = false, statusInside = true } = {}) {
  const status = { textContent: "", classList: classList() }
  const retry = { hidden: true }
  const listeners = new Map()
  const form = {
    querySelector(selector) {
      if (selector === '[data-autosave-target="status"]') return statusInside ? status : null
      if (selector === '[data-autosave-target="retry"]') return retry
      if (selector.includes("message[")) return null
      return null
    },
    querySelectorAll(selector) {
      if (selector === 'input[type="file"]') return files
      if (selector === 'input[type="tel"]') return []
      if (selector === "input[data-autosave-pending-deletion]") return pendingDeletions
      if (selector === "[data-autosave-skip]") return skippedLegs
      return []
    },
    addEventListener(name, handler) { listeners.set(name, handler) },
    removeEventListener(name) { listeners.delete(name) },
    setAttribute() {},
    requestSubmit() { this.requestSubmitCalls = (this.requestSubmitCalls || 0) + 1 }
  }

  const controller = new AutosaveController()
  Object.assign(controller, {
    element: form,
    hasUrlValue: true,
    urlValue: "/onboarding/profile",
    hasCreateUrlValue: false,
    notifyOnlyValue: notifyOnly
  })
  controller.connect()

  return { controller, status, retry, form }
}

globalThis.FormData = FakeFormData
globalThis.document = {
  getElementById(id) { return id === "save-status" ? documentStatus : null },
  addEventListener() {},
  removeEventListener() {},
  querySelector(selector) {
    assert.equal(selector, 'meta[name="csrf-token"]')
    return { content: "token" }
  },
  createElement() { return {} }
}
globalThis.window = {
  addEventListener() {},
  removeEventListener() {},
  history: { replaceState() {} }
}

test("a validation failure keeps the form dirty and exposes its errors and retry action", async () => {
  const { controller, status, retry } = buildController()
  globalThis.fetch = async () => ({
    ok: false,
    json: async () => ({ success: false, errors: [ "Phone is not a valid phone number" ] })
  })

  controller.input({ target: { type: "text" } })
  await controller.save()

  assert.equal(status.textContent, "Not saved: Phone is not a valid phone number")
  assert.equal(retry.hidden, false)
  assert.equal(controller.hasUnsavedChanges(), true)
  controller.disconnect()
})

test("an older response cannot show saved while a newer edit is queued", async () => {
  const first = deferred()
  const second = deferred()
  let calls = 0
  globalThis.fetch = () => {
    calls += 1
    return calls === 1 ? first.promise : second.promise
  }
  const { controller, status } = buildController()

  controller.input({ target: { type: "text" } })
  const firstSave = controller.save()
  controller.input({ target: { type: "text" } })
  controller.save()
  first.resolve({ ok: true, json: async () => ({ success: true, saved_at: "2026-09-10T08:00:00Z" }) })
  await firstSave

  assert.equal(calls, 2)
  assert.doesNotMatch(status.textContent, /^Saved at/)

  second.resolve({ ok: true, json: async () => ({ success: true, saved_at: "2026-09-10T08:00:01Z" }) })
  await controller.currentRequest

  assert.match(status.textContent, /^Saved at/)
  assert.equal(controller.hasUnsavedChanges(), false)
  controller.disconnect()
})

test("a selected file stays visibly pending after text autosaves and warns before navigation", async () => {
  const file = { type: "file", name: "participant[headshot]", files: [ { name: "photo.png" } ] }
  const { controller, status } = buildController({ files: [ file ] })
  globalThis.fetch = async () => ({
    ok: true,
    json: async () => ({ success: true, saved_at: "2026-09-10T08:00:00Z" })
  })

  controller.change({ target: file })
  assert.match(status.textContent, /Save & Continue/)

  const navigation = { preventDefaultCalled: false, preventDefault() { this.preventDefaultCalled = true } }
  controller.beforeUnload(navigation)
  assert.equal(navigation.preventDefaultCalled, true)
  assert.equal(navigation.returnValue, "")

  controller.input({ target: { type: "text" } })
  await controller.save()

  assert.match(status.textContent, /Text saved/)
  assert.match(status.textContent, /photo.*Save & Continue/i)
  assert.equal(controller.hasUnsavedChanges(), true)
  controller.disconnect()
})

test("notify-only forms expose unsaved changes without making a request", () => {
  let calls = 0
  globalThis.fetch = () => { calls += 1 }
  const { controller, status } = buildController({ notifyOnly: true })

  controller.input({ target: { type: "text" } })

  assert.equal(calls, 0)
  assert.equal(controller.timeout, null)
  assert.match(status.textContent, /unsaved changes/i)
  assert.equal(controller.hasUnsavedChanges(), true)
  controller.disconnect()
})

test("turbo navigation asks before leaving dirty onboarding input", () => {
  const { controller } = buildController()
  controller.input({ target: { type: "text" } })
  let confirmations = 0
  globalThis.window.confirm = () => {
    confirmations += 1
    return false
  }
  const visit = { prevented: false, preventDefault() { this.prevented = true } }

  controller.beforeVisit(visit)

  assert.equal(confirmations, 1)
  assert.equal(visit.prevented, true)
  controller.disconnect()
})

test("explicit submit waits for an in-flight autosave before submitting full form data", async () => {
  const pending = deferred()
  globalThis.fetch = () => pending.promise
  const { controller, form } = buildController()
  controller.input({ target: { type: "text" } })
  controller.save()
  const submit = {
    prevented: false,
    submitter: { name: "commit" },
    preventDefault() { this.prevented = true }
  }

  controller.handleSubmit(submit)

  assert.equal(submit.prevented, true)
  assert.equal(form.requestSubmitCalls || 0, 0)
  pending.resolve({ ok: true, json: async () => ({ success: true, saved_at: "2026-09-10T08:00:00Z" }) })
  await controller.pendingSubmit

  assert.equal(form.requestSubmitCalls, 1)
  assert.equal(controller.submitting, true)
  controller.disconnect()
})

test("new flight details remain pending while existing leg edits can autosave", () => {
  const field = { name: "travel_inbound[travel_legs_attributes][1][flight_code]", value: "" }
  const newLeg = {
    dataset: { autosaveNew: "true" },
    querySelector() { return null },
    querySelectorAll() { return [ field ] }
  }
  const { controller, status } = buildController({ skippedLegs: [ newLeg ] })

  controller.input({ target: field })

  assert.match(status.textContent, /new flight details.*Save & Continue/i)
  assert.equal(controller.hasUnsavedChanges(), true)
  controller.disconnect()
})

test("removed flight details remain pending for explicit save", () => {
  const deletion = {
    name: "travel_inbound[travel_legs_attributes][1][_destroy]",
    value: "1"
  }
  const { controller, status } = buildController({ pendingDeletions: [ deletion ] })

  controller.change({ target: { type: "hidden" } })

  assert.match(status.textContent, /removed flight details.*Save & Continue/i)
  assert.equal(controller.hasUnsavedChanges(), true)
  controller.disconnect()
})

test("the shared admin message form keeps using its external save status", async () => {
  const externalStatus = { textContent: "Draft", classList: classList() }
  documentStatus = externalStatus
  globalThis.fetch = async () => ({
    ok: true,
    json: async () => ({ success: true, saved_at: "2026-09-10T08:00:00Z" })
  })
  const { controller } = buildController({ statusInside: false })

  await controller.save({ target: { type: "select-one" } })

  assert.match(externalStatus.textContent, /^Saved at/)
  assert.equal(controller.hasUnsavedChanges(), false)
  controller.disconnect()
  documentStatus = null
})
