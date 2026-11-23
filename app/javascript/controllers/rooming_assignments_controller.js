import { Controller } from "@hotwired/stimulus"
import { roomingRequest, renderStream, errorMessage } from "utils/rooming_request"

// The rooming wizard's assignments step: drag a participant between rooms or
// back to the unassigned list, drag a room card to reorder the rooms, and
// carry out the changes each room card asks for.
//
// Shared by the original admin and the console, which differ only in markup
// and in the classes a drop zone takes while something is dragged over it
// (`data-rooming-assignments-drop-active-class`).
//
// Every listener is delegated from this element, so the room cards, the
// rooms list and the unassigned list can all be replaced by a turbo stream
// without anything being bound again. The markup hooks are the classes and
// ids the page has always had:
//   .draggable-participant[data-pe-id]   a participant that can be dragged
//   .room-drop-zone[data-room-id]        a room that can take participants
//   #unassigned-drop-zone                the unassigned list
//   .room-card[data-room-id]             a room card, draggable to reorder
//   #rooms_list                          the room cards' container
//
// Room cards have their own controller (rooming-room) for renaming and their
// buttons. It asks for server changes with rooming-room:* events, handled
// here so the URLs live in one place.
const PARTICIPANT = ".draggable-participant"
const DROP_ZONE = ".room-drop-zone, #unassigned-drop-zone"
const ROOM_CARD = ".room-card"

export default class extends Controller {
  static values = {
    moveUrl: String,
    reorderUrl: String,
    updateRoomUrl: String,
    destroyRoomUrl: String,
    removeStaffUrl: String,
    acknowledgeUrl: String
  }
  static classes = ["dropActive"]

  connect() {
    this.draggedRoomId = null
    this.listeners = new AbortController()

    const on = (name, handler) => {
      this.element.addEventListener(name, handler.bind(this), { signal: this.listeners.signal })
    }
    on("dragstart", this.dragStart)
    on("dragend", this.dragEnd)
    on("dragover", this.dragOver)
    on("dragleave", this.dragLeave)
    on("drop", this.drop)
    on("rooming-room:rename", this.renameRoom)
    on("rooming-room:delete", this.deleteRoom)
    on("rooming-room:remove-staff", this.removeStaff)
    on("rooming-room:acknowledge", this.acknowledge)
  }

  disconnect() {
    this.listeners.abort()
  }

  // --- drag and drop -------------------------------------------------------

  dragStart(event) {
    // dragend never reaches this element when the dragged node was replaced
    // mid-drag (a turbo stream re-rendering the rooms), so a room drag can be
    // left behind; every new drag starts clean.
    this.draggedRoomId = null
    const source = elementOf(event.target)

    // A participant sits inside a room card, so check for it first: dragging
    // one must not also start a room reorder.
    const participant = source?.closest(PARTICIPANT)
    if (participant) {
      event.dataTransfer.setData("text/plain", participant.dataset.peId)
      participant.classList.add("opacity-50")
      return
    }

    const card = source?.closest(`${ROOM_CARD}[draggable="true"]`)
    if (!card) return

    this.draggedRoomId = card.dataset.roomId
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/room-id", this.draggedRoomId)
    card.classList.add("opacity-50")
  }

  dragEnd(event) {
    elementOf(event.target)?.closest(`${PARTICIPANT}, ${ROOM_CARD}`)?.classList.remove("opacity-50")
    this.draggedRoomId = null
  }

  dragOver(event) {
    if (this.draggedRoomId) {
      if (!elementOf(event.target)?.closest(ROOM_CARD)) return

      event.preventDefault()
      event.dataTransfer.dropEffect = "move"
      return
    }

    const zone = elementOf(event.target)?.closest(DROP_ZONE)
    if (!zone) return

    event.preventDefault()
    zone.classList.add(...this.dropActiveClasses)
  }

  dragLeave(event) {
    elementOf(event.target)?.closest(DROP_ZONE)?.classList.remove(...this.dropActiveClasses)
  }

  drop(event) {
    if (this.draggedRoomId) {
      this.dropRoom(event)
      this.draggedRoomId = null
      return
    }

    const zone = elementOf(event.target)?.closest(DROP_ZONE)
    if (!zone) return

    event.preventDefault()
    zone.classList.remove(...this.dropActiveClasses)

    const participantEventId = event.dataTransfer.getData("text/plain")
    if (!participantEventId) return

    // The unassigned list has no data-room-id: no room means unassign.
    this.moveAssignment(participantEventId, zone.dataset.roomId)
  }

  dropRoom(event) {
    const target = elementOf(event.target)?.closest(ROOM_CARD)
    if (!target) return

    event.preventDefault()

    const list = document.getElementById("rooms_list")
    const dragged = document.getElementById(`room_${this.draggedRoomId}`)
    if (!list || !dragged || target === dragged || target.parentElement !== list) return

    const cards = Array.from(list.children)
    if (cards.indexOf(dragged) < cards.indexOf(target)) {
      list.insertBefore(dragged, target.nextSibling)
    } else {
      list.insertBefore(dragged, target)
    }

    this.persistRoomOrder(list)
  }

  // --- server changes ------------------------------------------------------

  async moveAssignment(participantEventId, roomId) {
    const body = new FormData()
    body.append("participant_event_id", participantEventId)
    if (roomId) body.append("room_id", roomId)

    const response = await roomingRequest(this.moveUrlValue, { body, stream: true })
    if (response.ok) {
      await renderStream(response)
    } else {
      alert(await errorMessage(response, "Failed to move participant"))
    }
  }

  async persistRoomOrder(list) {
    const body = new FormData()
    list.querySelectorAll(ROOM_CARD).forEach((card) => body.append("room_ids[]", card.dataset.roomId))

    await roomingRequest(this.reorderUrlValue, { body })
  }

  async renameRoom({ detail: { roomId, name, revert } }) {
    const response = await roomingRequest(this.updateRoomUrlValue, {
      method: "PATCH", body: { room_id: roomId, name }, stream: true
    })
    if (response.ok) {
      await renderStream(response)
    } else {
      revert?.()
      alert(await errorMessage(response, "Failed to rename room"))
    }
  }

  // The card only goes once the server has deleted the room: a refused
  // delete (a locked plan, say) leaves it, and the next reorder, alone.
  async deleteRoom({ detail: { roomId, card } }) {
    const response = await roomingRequest(this.destroyRoomUrlValue, { method: "DELETE", body: { room_id: roomId } })
    if (response.ok) {
      card.remove()
    } else {
      alert(await errorMessage(response, "Failed to delete room"))
    }
  }

  async removeStaff({ detail: { roomId, staffName } }) {
    const response = await roomingRequest(this.removeStaffUrlValue, {
      method: "DELETE", body: { room_id: roomId, staff_name: staffName }, stream: true
    })
    if (response.ok) await renderStream(response)
  }

  // Acknowledging changes flags on the card and the counts in the summary
  // bar, and the action answers with no body, so reload for the fresh page.
  async acknowledge({ detail: { assignmentId } }) {
    const response = await roomingRequest(this.acknowledgeUrlValue, { body: { assignment_id: assignmentId } })
    if (response.ok) {
      location.reload()
    } else {
      alert(await errorMessage(response, "Failed to acknowledge"))
    }
  }
}

// A drag that starts on selected text reports the text node as its target.
function elementOf(node) {
  return node instanceof Element ? node : node?.parentElement
}
