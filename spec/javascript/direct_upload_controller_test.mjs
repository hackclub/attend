import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

async function importWith(path, replacements) {
  let source = await readFile(new URL(path, import.meta.url), "utf8")
  for (const [ from, to ] of replacements) source = source.replace(from, to)
  return import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`)
}

const { default: DirectUploadController } = await importWith("../../app/javascript/controllers/direct_upload_controller.js", [
  [ 'import { Controller } from "@hotwired/stimulus"', "class Controller {}" ],
  [ 'import { directUpload } from "utils/direct_upload"', "const directUpload = (...args) => globalThis.directUpload(...args)" ]
])

const { directUpload } = await importWith("../../app/javascript/utils/direct_upload.js", [
  [ 'import { DirectUpload } from "@rails/activestorage"', "function DirectUpload(...args) { return new globalThis.FakeDirectUpload(...args) }" ]
])

function deferred() {
  let resolve
  const promise = new Promise((resolver) => { resolve = resolver })
  return { promise, resolve }
}

function buildController() {
  const input = {
    name: "participant[public_profile_photo]",
    files: [],
    removeAttribute(attribute) { if (attribute === "name") this.name = "" }
  }
  const signedId = { value: "" }
  const status = { textContent: "" }
  const controller = new DirectUploadController()
  Object.assign(controller, {
    urlValue: "/rails/active_storage/direct_uploads",
    inputTarget: input,
    signedIdTarget: signedId,
    statusTarget: status,
    hasStatusTarget: true
  })
  controller.connect()
  return { controller, input, signedId, status }
}

test("a stored photo is sent as its signed id, not as the file", async () => {
  globalThis.directUpload = async () => "blob-signed-id"
  const { controller, input, signedId, status } = buildController()

  input.files = [ { name: "me.png" } ]
  await controller.upload()

  assert.equal(signedId.value, "blob-signed-id")
  assert.equal(input.name, "")
  assert.match(status.textContent, /Uploaded/)
})

test("a failed direct upload leaves the file to be posted with the form", async () => {
  globalThis.directUpload = async () => null
  const { controller, input, signedId, status } = buildController()

  input.files = [ { name: "me.png" } ]
  await controller.upload()

  assert.equal(signedId.value, "")
  assert.equal(input.name, "participant[public_profile_photo]")
  assert.equal(status.textContent, "")
})

test("picking again puts the file back in the form until the new upload lands", async () => {
  const second = deferred()
  const uploads = [ Promise.resolve("first-id"), second.promise ]
  globalThis.directUpload = () => uploads.shift()
  const { controller, input, signedId } = buildController()

  input.files = [ { name: "first.png" } ]
  await controller.upload()
  input.files = [ { name: "second.png" } ]
  const pending = controller.upload()

  assert.equal(signedId.value, "")
  assert.equal(input.name, "participant[public_profile_photo]")

  second.resolve("second-id")
  await pending
  assert.equal(signedId.value, "second-id")
})

test("clearing the picker forgets the uploaded photo", async () => {
  globalThis.directUpload = async () => "blob-signed-id"
  const { controller, input, signedId } = buildController()

  input.files = [ { name: "me.png" } ]
  await controller.upload()
  input.files = []
  await controller.upload()

  assert.equal(signedId.value, "")
  assert.equal(input.name, "participant[public_profile_photo]")
})

test("directUpload resolves the signed id of the stored blob", async () => {
  globalThis.FakeDirectUpload = class {
    constructor(file, url) { this.file = file; this.url = url }
    create(callback) { callback(null, { signed_id: `signed:${this.file.name}:${this.url}` }) }
  }

  assert.equal(await directUpload({ name: "me.png" }, "/uploads"), "signed:me.png:/uploads")
})

test("directUpload resolves null when storage refuses the upload", async () => {
  globalThis.FakeDirectUpload = class {
    create(callback) { callback("Error storing \"me.png\". Status: 0") }
  }

  assert.equal(await directUpload({ name: "me.png" }, "/uploads"), null)
})

test("directUpload resolves null when it can't even start", async () => {
  globalThis.FakeDirectUpload = class {
    constructor() { throw new Error("no FileReader") }
  }

  assert.equal(await directUpload({ name: "me.png" }, "/uploads"), null)
  assert.equal(await directUpload({ name: "me.png" }, ""), null)
})
