import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

const controllerUrl = new URL("../../app/javascript/controllers/travel_form_controller.js", import.meta.url)
const controllerSource = await readFile(controllerUrl, "utf8")
const runnableSource = controllerSource.replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
const { default: TravelFormController } = await import(`data:text/javascript;base64,${Buffer.from(runnableSource).toString("base64")}`)

globalThis.document = {
  createElement() { return { dataset: {} } }
}

test("removing a persisted flight leg marks it for deletion and notifies autosave", () => {
  const appended = []
  const events = []
  const container = {
    appendChild(input) { appended.push(input) },
    querySelectorAll() { return [] }
  }
  const idField = {
    name: "travel_inbound[travel_legs_attributes][1][id]",
    value: "leg-uuid"
  }
  const leg = {
    parentElement: container,
    querySelector() { return idField },
    remove() {}
  }
  const controller = new TravelFormController()
  controller.element = {
    dispatchEvent(event) { events.push(event.type) }
  }

  controller.removeLeg({
    preventDefault() {},
    currentTarget: { closest() { return leg } }
  })

  assert.deepEqual(appended.map((input) => [ input.name, input.value ]), [
    [ "travel_inbound[travel_legs_attributes][1][id]", "leg-uuid" ],
    [ "travel_inbound[travel_legs_attributes][1][_destroy]", "1" ]
  ])
  assert.equal(appended[0].dataset.autosavePendingDeletion, "true")
  assert.equal(appended[1].dataset.autosavePendingDeletion, "true")
  assert.deepEqual(events, [ "change" ])
})
