import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

const controllerUrl = new URL("../../app/javascript/controllers/headshot_upload_controller.js", import.meta.url)
const controllerSource = await readFile(controllerUrl, "utf8")
const runnableSource = controllerSource.replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
const { default: HeadshotUploadController } = await import(`data:text/javascript;base64,${Buffer.from(runnableSource).toString("base64")}`)

class FakeFormData {
  constructor() {
    this.values = new Map()
  }

  append(name, value) {
    this.values.set(name, value)
  }
}

class FakeFileReader {
  readAsDataURL(file) {
    this.onload({ target: { result: `data:image/png;base64,${file.name}` } })
  }
}

function deferred() {
  let resolve
  let reject
  const promise = new Promise((resolver, rejecter) => {
    resolve = resolver
    reject = rejecter
  })
  return { promise, resolve, reject }
}

function classList() {
  const classes = new Set()
  return {
    contains(name) { return classes.has(name) },
    toggle(name, force) {
      if (force) classes.add(name)
      else classes.delete(name)
    }
  }
}

function buildController({ src = "/current.png", staged = "", required = false, hidden = false } = {}) {
  const input = { files: [], value: "", required }
  const stagedInput = { value: staged }
  const preview = { hidden }
  const image = {
    src,
    getAttribute(name) { return name === "src" ? this.src : null },
    removeAttribute(name) { if (name === "src") this.src = null }
  }
  const caption = { textContent: "Current headshot" }
  const status = { textContent: "", classList: classList() }
  const events = []
  const element = { dispatchEvent(event) { events.push(event) } }

  const controller = new HeadshotUploadController()
  Object.assign(controller, {
    element,
    urlValue: "/onboarding/headshot",
    inputTarget: input,
    stagedTarget: stagedInput,
    previewTarget: preview,
    imageTarget: image,
    captionTarget: caption,
    statusTarget: status
  })
  controller.connect()

  return { controller, input, stagedInput, preview, image, caption, status, events }
}

function pick(input, name = "new.png") {
  input.files = [ { name } ]
  input.value = `C:\\fakepath\\${name}`
}

globalThis.FormData = FakeFormData
globalThis.FileReader = FakeFileReader
globalThis.document = {
  querySelector(selector) {
    assert.equal(selector, 'meta[name="csrf-token"]')
    return { content: "token" }
  }
}

test("a staged photo leaves the form, so submit sends its signed id instead", async () => {
  const { controller, input, stagedInput, preview, image, caption, status, events } = buildController({ required: true, hidden: true, src: null })
  let request
  globalThis.fetch = async (url, options) => {
    request = { url, options }
    return { ok: true, json: async () => ({ success: true, signed_id: "signed-123" }) }
  }

  pick(input)
  await controller.upload()

  assert.equal(request.url, "/onboarding/headshot")
  assert.equal(request.options.method, "POST")
  assert.equal(request.options.body.values.get("headshot").name, "new.png")
  assert.equal(stagedInput.value, "signed-123")
  assert.equal(input.value, "")
  assert.equal(input.required, false)
  assert.equal(preview.hidden, false)
  assert.match(image.src, /new\.png/)
  assert.equal(caption.textContent, "New headshot")
  assert.match(status.textContent, /Save & Continue/)
  assert.equal(events.length, 1)
  assert.equal(events[0].bubbles, true)
})

test("a refused photo puts the field back as it loaded and shows why", async () => {
  const { controller, input, stagedInput, preview, image, caption, status } = buildController({ staged: "from-page", required: false })
  globalThis.fetch = async () => ({
    ok: false,
    json: async () => ({ success: false, error: "Headshot must be a JPEG, PNG, or WebP image" })
  })

  pick(input, "notes.txt")
  await controller.upload()

  assert.equal(stagedInput.value, "from-page")
  assert.equal(input.value, "")
  assert.equal(input.required, false)
  assert.equal(image.src, "/current.png")
  assert.equal(caption.textContent, "Current headshot")
  assert.equal(preview.hidden, false)
  assert.equal(status.textContent, "Headshot must be a JPEG, PNG, or WebP image")
  assert.equal(status.classList.contains("text-(--danger-strong)"), true)
})

test("a refused first photo makes the field required again", async () => {
  const { controller, input, preview, image } = buildController({ required: true, hidden: true, src: null })
  globalThis.fetch = async () => ({ ok: false, json: async () => ({ success: false, error: "Too big" }) })

  pick(input)
  await controller.upload()

  assert.equal(input.required, true)
  assert.equal(preview.hidden, true)
  assert.equal(image.src, null)
})

test("an upload that can't reach the server leaves the file to go with the form", async () => {
  const { controller, input, stagedInput, status } = buildController()
  globalThis.fetch = async () => { throw new TypeError("Failed to fetch") }

  pick(input)
  await controller.upload()

  assert.equal(stagedInput.value, "")
  assert.notEqual(input.value, "")
  assert.match(status.textContent, /upload when you press Save & Continue/)
  assert.equal(status.classList.contains("text-(--danger-strong)"), false)
})

test("a slow response to an earlier pick can't replace a later one", async () => {
  const first = deferred()
  const second = deferred()
  const responses = [ first, second ]
  globalThis.fetch = () => responses.shift().promise
  const { controller, input, stagedInput } = buildController()

  pick(input, "first.png")
  const firstUpload = controller.upload()
  pick(input, "second.png")
  const secondUpload = controller.upload()

  second.resolve({ ok: true, json: async () => ({ success: true, signed_id: "second" }) })
  await secondUpload
  first.resolve({ ok: true, json: async () => ({ success: true, signed_id: "first" }) })
  await firstUpload

  assert.equal(stagedInput.value, "second")
})

test("closing the file picker without choosing keeps a staged photo", async () => {
  let calls = 0
  globalThis.fetch = () => { calls += 1 }
  const { controller, input, stagedInput } = buildController({ staged: "signed-123" })

  input.files = []
  await controller.upload()

  assert.equal(calls, 0)
  assert.equal(stagedInput.value, "signed-123")
})
