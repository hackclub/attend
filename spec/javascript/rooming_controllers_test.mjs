import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

// The rooming wizard's assignments step: rooming_assignments_controller
// (drag and drop, server changes), rooming_room_controller (one room card)
// and rooming_staff_modal_controller, with utils/rooming_request under them.
// There is no DOM here, so the page is a small tree of fake elements that
// answer the handful of DOM calls the controllers make.

const source = (path) => readFile(new URL(`../../app/javascript/${path}`, import.meta.url), "utf8")
const asModule = (code) => import(`data:text/javascript;base64,${Buffer.from(code).toString("base64")}`)
const STIMULUS_IMPORT = 'import { Controller } from "@hotwired/stimulus"'
const REQUEST_IMPORT = 'import { roomingRequest, renderStream, errorMessage } from "utils/rooming_request"'

// Stimulus' dispatch(), which the room card uses to ask for changes.
const CONTROLLER_STUB = `class Controller {
  dispatch(name, { detail } = {}) {
    const event = { type: this.identifier + ":" + name, detail }
    this.element.dispatched.push(event)
    return event
  }
}`

const requestSource = (await source("utils/rooming_request.js"))
  .replace('import { Turbo } from "@hotwired/turbo-rails"', "const Turbo = { renderStreamMessage: (html) => globalThis.renderedStreams.push(html) }")
const requestUrl = `data:text/javascript;base64,${Buffer.from(requestSource).toString("base64")}`
const withRequest = (code) => code.replace(REQUEST_IMPORT, `import { roomingRequest, renderStream, errorMessage } from "${requestUrl}"`)

const { default: AssignmentsController } = await asModule(withRequest((await source("controllers/rooming_assignments_controller.js")).replace(STIMULUS_IMPORT, CONTROLLER_STUB)))
const { default: RoomController } = await asModule((await source("controllers/rooming_room_controller.js")).replace(STIMULUS_IMPORT, CONTROLLER_STUB))
const { default: StaffModalController } = await asModule(withRequest((await source("controllers/rooming_staff_modal_controller.js")).replace(STIMULUS_IMPORT, CONTROLLER_STUB)))

// --- a very small DOM --------------------------------------------------------

class Element {
  constructor({ id = null, classes = [], dataset = {}, attributes = {}, value = "" } = {}) {
    this.id = id
    this.dataset = dataset
    this.attributes = attributes
    this.children = []
    this.parentElement = null
    this.listeners = {}
    this.dispatched = []
    this.value = value
    this.defaultValue = value
    this.calls = []
    const set = new Set(classes)
    this.classList = {
      add: (...names) => names.forEach((name) => set.add(name)),
      remove: (...names) => names.forEach((name) => set.delete(name)),
      toggle: (name, force) => (force ? set.add(name) : set.delete(name)),
      contains: (name) => set.has(name)
    }
  }

  append(...children) {
    children.forEach((child) => {
      child.parentElement?.removeChild(child)
      child.parentElement = this
      this.children.push(child)
    })
    return this
  }

  removeChild(child) {
    this.children = this.children.filter((c) => c !== child)
    child.parentElement = null
  }

  remove() { this.parentElement?.removeChild(this) }

  insertBefore(child, reference) {
    child.parentElement?.removeChild(child)
    child.parentElement = this
    const index = reference ? this.children.indexOf(reference) : -1
    if (index === -1) this.children.push(child)
    else this.children.splice(index, 0, child)
  }

  get nextSibling() {
    const siblings = this.parentElement.children
    return siblings[siblings.indexOf(this) + 1] || null
  }

  // Supports what the controllers ask for: comma lists of .class, #id and
  // [attr="value"] compounds.
  matches(selector) {
    return selector.split(",").some((part) => {
      const tokens = part.trim().match(/[.#][\w-]+|\[[\w-]+="[^"]*"\]/g) || []
      return tokens.every((token) => {
        if (token[0] === ".") return this.classList.contains(token.slice(1))
        if (token[0] === "#") return this.id === token.slice(1)
        const [ , name, value ] = token.match(/\[([\w-]+)="([^"]*)"\]/)
        return this.attributes[name] === value
      })
    })
  }

  closest(selector) {
    for (let node = this; node; node = node.parentElement) if (node.matches(selector)) return node
    return null
  }

  querySelectorAll(selector) {
    return this.children.flatMap((child) => [ ...(child.matches(selector) ? [ child ] : []), ...child.querySelectorAll(selector) ])
  }

  addEventListener(name, handler, { signal } = {}) {
    (this.listeners[name] ||= []).push(handler)
    signal?.addEventListener("abort", () => { this.listeners[name] = this.listeners[name].filter((h) => h !== handler) })
  }

  // Fires an event that started on `target`, somewhere under this element.
  fire(name, target, extra = {}) {
    const event = { type: name, target, defaultPrevented: false, preventDefault() { this.defaultPrevented = true }, ...extra }
    ;(this.listeners[name] || []).forEach((handler) => handler(event))
    return event
  }

  focus() { this.calls.push("focus") }
  select() { this.calls.push("select") }
  blur() { this.calls.push("blur") }
}

function dataTransfer(data = {}) {
  return { data, setData(type, value) { this.data[type] = value }, getData(type) { return this.data[type] || "" } }
}

// A board with two rooms and one unassigned participant, wired the way the
// views wire it.
function board(t, { responses = [] } = {}) {
  const page = new Element()
  const unassigned = new Element({ id: "unassigned-drop-zone" })
  const loose = new Element({ classes: [ "draggable-participant" ], dataset: { peId: "pe-1" } })
  const list = new Element({ id: "rooms_list" })
  const room = (id) => {
    const card = new Element({ id: `room_${id}`, classes: [ "room-card" ], dataset: { roomId: id }, attributes: { draggable: "true" } })
    const zone = new Element({ classes: [ "room-drop-zone" ], dataset: { roomId: id } })
    const occupant = new Element({ classes: [ "draggable-participant" ], dataset: { peId: `pe-in-${id}` } })
    card.append(zone.append(occupant))
    return { card, zone, occupant }
  }
  const a = room("a"), b = room("b"), c = room("c")
  page.append(unassigned.append(loose), list.append(a.card, b.card, c.card))

  const state = { requests: [], alerts: [], reloads: 0 }
  const byId = { rooms_list: list, room_a: a.card, room_b: b.card, room_c: c.card, "unassigned-drop-zone": unassigned }
  globalThis.Element = Element
  globalThis.renderedStreams = []
  globalThis.document = {
    getElementById: (id) => byId[id] || null,
    querySelector: () => ({ content: "csrf-token-value" })
  }
  globalThis.fetch = async (url, options) => {
    state.requests.push({ url, ...options })
    return responses.shift() || { ok: true, text: async () => "<turbo-stream></turbo-stream>" }
  }
  globalThis.alert = (message) => state.alerts.push(message)
  globalThis.location = { reload() { state.reloads += 1 } }
  t.after(() => {
    for (const name of [ "Element", "renderedStreams", "document", "fetch", "alert", "location", "confirm" ]) delete globalThis[name]
  })

  const controller = new AssignmentsController()
  controller.element = page
  controller.identifier = "rooming-assignments"
  controller.moveUrlValue = "/rooming/move_assignment"
  controller.reorderUrlValue = "/rooming/reorder_rooms"
  controller.updateRoomUrlValue = "/rooming/update_room"
  controller.destroyRoomUrlValue = "/rooming/destroy_room"
  controller.removeStaffUrlValue = "/rooming/remove_staff"
  controller.acknowledgeUrlValue = "/rooming/acknowledge_trans_nb"
  controller.dropActiveClasses = [ "bg-blue-50", "border-blue-300" ]
  controller.connect()
  return { controller, page, unassigned, loose, list, a, b, c, state }
}

const flush = () => new Promise((resolve) => setImmediate(resolve))
const formEntries = (body) => Array.from(body.entries())

// --- rooming-assignments: participants ---------------------------------------

test("dragging a participant onto a room moves them there and renders the stream", async (t) => {
  const { page, loose, b, state } = board(t)
  const transfer = dataTransfer()

  page.fire("dragstart", loose, { dataTransfer: transfer })
  assert.equal(transfer.data["text/plain"], "pe-1")
  assert.ok(loose.classList.contains("opacity-50"))

  const over = page.fire("dragover", b.occupant, { dataTransfer: transfer })
  assert.ok(over.defaultPrevented, "the zone accepts the drop")
  assert.ok(b.zone.classList.contains("bg-blue-50") && b.zone.classList.contains("border-blue-300"))

  const drop = page.fire("drop", b.occupant, { dataTransfer: transfer })
  page.fire("dragend", loose)
  await flush()

  assert.ok(drop.defaultPrevented)
  assert.ok(!b.zone.classList.contains("bg-blue-50"), "the highlight clears on drop")
  assert.ok(!loose.classList.contains("opacity-50"))
  assert.equal(state.requests.length, 1)
  const [ request ] = state.requests
  assert.equal(request.url, "/rooming/move_assignment")
  assert.equal(request.method, "POST")
  assert.equal(request.headers["X-CSRF-Token"], "csrf-token-value")
  assert.equal(request.headers["Accept"], "text/vnd.turbo-stream.html")
  assert.deepEqual(formEntries(request.body), [ [ "participant_event_id", "pe-1" ], [ "room_id", "b" ] ])
  assert.deepEqual(globalThis.renderedStreams, [ "<turbo-stream></turbo-stream>" ])
})

test("dropping on the unassigned list sends no room, which unassigns", async (t) => {
  const { page, unassigned, a, state } = board(t)
  const transfer = dataTransfer()

  page.fire("dragstart", a.occupant, { dataTransfer: transfer })
  page.fire("drop", unassigned, { dataTransfer: transfer })
  await flush()

  assert.deepEqual(formEntries(state.requests[0].body), [ [ "participant_event_id", "pe-in-a" ] ])
})

test("leaving a zone clears its highlight", (t) => {
  const { page, b } = board(t)

  page.fire("dragover", b.zone, { dataTransfer: dataTransfer() })
  page.fire("dragleave", b.zone)

  assert.ok(!b.zone.classList.contains("bg-blue-50"))
})

test("a refused move shows the server's reason, or a fallback when there is none", async (t) => {
  const refused = { ok: false, json: async () => ({ error: "Room is full" }) }
  const broken = { ok: false, json: async () => { throw new SyntaxError("not JSON") } }
  const { page, b, state } = board(t, { responses: [ refused, broken ] })
  const transfer = dataTransfer({ "text/plain": "pe-1" })

  page.fire("drop", b.zone, { dataTransfer: transfer })
  await flush()
  page.fire("drop", b.zone, { dataTransfer: transfer })
  await flush()

  assert.deepEqual(state.alerts, [ "Room is full", "Failed to move participant" ])
  assert.deepEqual(globalThis.renderedStreams, [])
})

test("a drop that carries no participant, or lands outside a zone, does nothing", async (t) => {
  const { page, list, b, state } = board(t)

  page.fire("drop", b.zone, { dataTransfer: dataTransfer() })
  const outside = page.fire("drop", list, { dataTransfer: dataTransfer({ "text/plain": "pe-1" }) })
  await flush()

  assert.equal(state.requests.length, 0)
  assert.ok(!outside.defaultPrevented)
})

// --- rooming-assignments: room order -----------------------------------------

test("dragging a room card past another reorders the list and saves the order", async (t) => {
  const { page, list, a, c, state } = board(t)
  const transfer = dataTransfer()

  page.fire("dragstart", a.card, { dataTransfer: transfer })
  assert.equal(transfer.data["text/room-id"], "a")
  assert.equal(transfer.effectAllowed, "move")
  assert.ok(a.card.classList.contains("opacity-50"))

  // Over another card's drop zone: it's a room being dragged, so the zone
  // must not light up or take the drop as a participant move.
  const over = page.fire("dragover", c.zone, { dataTransfer: transfer })
  assert.ok(over.defaultPrevented)
  assert.ok(!c.zone.classList.contains("bg-blue-50"))

  page.fire("drop", c.zone, { dataTransfer: transfer })
  page.fire("dragend", a.card)
  await flush()

  assert.deepEqual(list.children.map((card) => card.dataset.roomId), [ "b", "c", "a" ])
  assert.ok(!a.card.classList.contains("opacity-50"))
  assert.equal(state.requests.length, 1)
  assert.equal(state.requests[0].url, "/rooming/reorder_rooms")
  assert.equal(state.requests[0].headers["Accept"], undefined)
  assert.deepEqual(formEntries(state.requests[0].body), [ [ "room_ids[]", "b" ], [ "room_ids[]", "c" ], [ "room_ids[]", "a" ] ])
})

test("dragging a room card up puts it before the one it's dropped on", async (t) => {
  const { page, list, a, c } = board(t)
  const transfer = dataTransfer()

  page.fire("dragstart", c.card, { dataTransfer: transfer })
  page.fire("drop", a.card, { dataTransfer: transfer })
  await flush()

  assert.deepEqual(list.children.map((card) => card.dataset.roomId), [ "c", "a", "b" ])
})

test("a participant dragged inside a room card doesn't start a room reorder", async (t) => {
  const { page, a, b, state } = board(t)
  const transfer = dataTransfer()

  page.fire("dragstart", a.occupant, { dataTransfer: transfer })
  page.fire("drop", b.zone, { dataTransfer: transfer })
  await flush()

  assert.equal(transfer.data["text/room-id"], undefined)
  assert.equal(state.requests[0].url, "/rooming/move_assignment")
})

test("a locked plan's cards aren't draggable, so nothing starts", (t) => {
  const { page, a } = board(t)
  a.card.attributes.draggable = "false"
  const transfer = dataTransfer()

  page.fire("dragstart", a.card, { dataTransfer: transfer })

  assert.deepEqual(transfer.data, {})
  assert.ok(!a.card.classList.contains("opacity-50"))
})

test("disconnecting unbinds everything", async (t) => {
  const { controller, page, b, state } = board(t)

  controller.disconnect()
  page.fire("drop", b.zone, { dataTransfer: dataTransfer({ "text/plain": "pe-1" }) })
  await flush()

  assert.equal(state.requests.length, 0)
})

// --- rooming-assignments: what room cards ask for ------------------------------

test("a rename is sent as a turbo-stream PATCH, and a failure says so", async (t) => {
  const { page, a, state } = board(t, { responses: [ { ok: true, text: async () => "<turbo-stream></turbo-stream>" }, { ok: false } ] })

  page.fire("rooming-room:rename", a.card, { detail: { roomId: "a", name: "Suite & Co" } })
  await flush()

  const [ request ] = state.requests
  assert.equal(request.url, "/rooming/update_room")
  assert.equal(request.method, "PATCH")
  assert.equal(request.headers["Content-Type"], "application/x-www-form-urlencoded")
  assert.equal(request.headers["Accept"], "text/vnd.turbo-stream.html")
  assert.equal(request.body, "room_id=a&name=Suite+%26+Co")
  assert.equal(globalThis.renderedStreams.length, 1)
  assert.deepEqual(state.alerts, [])

  page.fire("rooming-room:rename", a.card, { detail: { roomId: "a", name: "Again" } })
  await flush()
  assert.deepEqual(state.alerts, [ "Failed to rename room" ])
})

test("deleting a room removes its card once the request is back", async (t) => {
  const { page, list, b, state } = board(t)

  page.fire("rooming-room:delete", b.card, { detail: { roomId: "b", card: b.card } })
  await flush()

  assert.equal(state.requests[0].url, "/rooming/destroy_room")
  assert.equal(state.requests[0].method, "DELETE")
  assert.equal(state.requests[0].body, "room_id=b")
  assert.deepEqual(list.children.map((card) => card.dataset.roomId), [ "a", "c" ])
})

test("removing staff renders the stream; acknowledging reloads", async (t) => {
  const { page, a, state } = board(t)

  page.fire("rooming-room:remove-staff", a.card, { detail: { roomId: "a", staffName: "Captain Placeholder" } })
  await flush()
  assert.equal(state.requests[0].url, "/rooming/remove_staff")
  assert.equal(state.requests[0].method, "DELETE")
  assert.equal(state.requests[0].body, "room_id=a&staff_name=Captain+Placeholder")
  assert.equal(globalThis.renderedStreams.length, 1)

  page.fire("rooming-room:acknowledge", a.card, { detail: { assignmentId: "ra-9" } })
  await flush()
  assert.equal(state.requests[1].url, "/rooming/acknowledge_trans_nb")
  assert.equal(state.requests[1].body, "assignment_id=ra-9")
  assert.equal(state.reloads, 1)
})

// --- rooming-room ------------------------------------------------------------

function roomCard(t, { name = "Room 101", confirms = true } = {}) {
  const card = new Element({ id: "room_a", classes: [ "room-card" ], dataset: { roomId: "a" } })
  const display = new Element()
  const input = new Element({ classes: [ "hidden" ], value: name })
  const prompts = []
  globalThis.confirm = (message) => { prompts.push(message); return confirms }
  t.after(() => { delete globalThis.confirm })

  const controller = new RoomController()
  controller.element = card
  controller.identifier = "rooming-room"
  controller.nameDisplayTarget = display
  controller.nameInputTarget = input
  return { controller, card, display, input, prompts }
}

test("clicking the name swaps in the input, focused with the name selected", (t) => {
  const { controller, display, input } = roomCard(t)

  controller.editName()

  assert.ok(display.classList.contains("hidden"))
  assert.ok(!input.classList.contains("hidden"))
  assert.deepEqual(input.calls, [ "focus", "select" ])
})

test("leaving the field with a new name asks for the rename; an unchanged name doesn't", (t) => {
  const { controller, card, display, input } = roomCard(t)

  controller.editName()
  controller.saveName()
  assert.deepEqual(card.dispatched, [])
  assert.ok(input.classList.contains("hidden") && !display.classList.contains("hidden"))

  controller.editName()
  input.value = "Room 102"
  controller.saveName()
  assert.deepEqual(card.dispatched, [ { type: "rooming-room:rename", detail: { roomId: "a", name: "Room 102" } } ])
})

test("Enter leaves the field; Escape puts the saved name back without renaming", (t) => {
  const { controller, card, display, input } = roomCard(t)
  const key = (name) => ({ key: name, defaultPrevented: false, preventDefault() { this.defaultPrevented = true } })

  controller.editName()
  input.value = "Typed"
  const enter = key("Enter")
  controller.nameKey(enter)
  assert.ok(enter.defaultPrevented)
  assert.equal(input.calls.at(-1), "blur")

  const escape = key("Escape")
  controller.nameKey(escape)
  assert.ok(escape.defaultPrevented)
  assert.equal(input.value, "Room 101")
  assert.ok(input.classList.contains("hidden") && !display.classList.contains("hidden"))

  // Hiding the field blurs it; that save must find nothing to rename.
  controller.saveName()
  assert.deepEqual(card.dispatched, [])

  const other = key("a")
  controller.nameKey(other)
  assert.ok(!other.defaultPrevented)
})

test("delete and remove-staff confirm first, and do nothing when declined", (t) => {
  const declined = roomCard(t, { confirms: false })
  declined.controller.delete()
  declined.controller.removeStaff({ currentTarget: { dataset: { staffName: "Captain Placeholder" } } })
  assert.deepEqual(declined.prompts, [ "Delete this room?", "Remove Captain Placeholder from this room?" ])
  assert.deepEqual(declined.card.dispatched, [])

  const { controller, card } = roomCard(t)
  controller.delete()
  controller.removeStaff({ currentTarget: { dataset: { staffName: "Captain Placeholder" } } })
  assert.deepEqual(card.dispatched, [
    { type: "rooming-room:delete", detail: { roomId: "a", card } },
    { type: "rooming-room:remove-staff", detail: { roomId: "a", staffName: "Captain Placeholder" } }
  ])
})

test("acknowledge and add-staff pass on what the button carries", (t) => {
  const { controller, card } = roomCard(t)

  controller.acknowledge({ currentTarget: { dataset: { acknowledgeTransNb: "ra-9" } } })
  controller.addStaff()

  assert.deepEqual(card.dispatched, [
    { type: "rooming-room:acknowledge", detail: { assignmentId: "ra-9" } },
    { type: "rooming-room:add-staff", detail: { roomId: "a" } }
  ])
})

// --- rooming-staff-modal -----------------------------------------------------

function staffModal(t, { responses = [] } = {}) {
  const modal = new Element({ id: "add-staff-modal", classes: [ "hidden" ] })
  const roomId = new Element()
  const name = new Element({ value: "left over" })
  const state = { requests: [], alerts: [] }
  globalThis.renderedStreams = []
  globalThis.document = { querySelector: () => ({ content: "csrf-token-value" }) }
  globalThis.fetch = async (url, options) => {
    state.requests.push({ url, ...options })
    return responses.shift() || { ok: true, text: async () => "<turbo-stream></turbo-stream>" }
  }
  globalThis.alert = (message) => state.alerts.push(message)
  t.after(() => { for (const key of [ "renderedStreams", "document", "fetch", "alert" ]) delete globalThis[key] })

  const controller = new StaffModalController()
  controller.element = modal
  controller.roomIdTarget = roomId
  controller.nameTarget = name
  controller.urlValue = "/rooming/add_staff"
  return { controller, modal, roomId, name, state }
}

const submitEvent = () => ({ defaultPrevented: false, preventDefault() { this.defaultPrevented = true } })

test("a room card's add-staff event opens the modal for that room, empty and focused", (t) => {
  const { controller, modal, roomId, name } = staffModal(t)

  controller.open({ detail: { roomId: "b" } })

  assert.ok(!modal.classList.contains("hidden"))
  assert.equal(roomId.value, "b")
  assert.equal(name.value, "")
  assert.deepEqual(name.calls, [ "focus" ])
})

test("submitting adds the trimmed name, closes the modal and renders the stream", async (t) => {
  const { controller, modal, name, state } = staffModal(t)
  controller.open({ detail: { roomId: "b" } })
  name.value = "  Captain Placeholder "
  const event = submitEvent()

  await controller.submit(event)

  assert.ok(event.defaultPrevented, "the form never submits natively")
  assert.equal(state.requests[0].url, "/rooming/add_staff")
  assert.equal(state.requests[0].method, "POST")
  assert.equal(state.requests[0].headers["Accept"], "text/vnd.turbo-stream.html")
  assert.equal(state.requests[0].body, "room_id=b&staff_name=Captain+Placeholder")
  assert.ok(modal.classList.contains("hidden"))
  assert.equal(globalThis.renderedStreams.length, 1)
})

test("an empty name asks for one, and a refusal keeps the modal open with the reason", async (t) => {
  const refused = { ok: false, json: async () => ({ error: "Cannot add staff to room with participants" }) }
  const { controller, modal, name, state } = staffModal(t, { responses: [ refused ] })
  controller.open({ detail: { roomId: "b" } })

  name.value = "   "
  await controller.submit(submitEvent())
  assert.equal(state.requests.length, 0)

  name.value = "Captain Placeholder"
  await controller.submit(submitEvent())
  assert.deepEqual(state.alerts, [ "Please enter a staff name", "Cannot add staff to room with participants" ])
  assert.ok(!modal.classList.contains("hidden"))
  assert.deepEqual(globalThis.renderedStreams, [])
})
