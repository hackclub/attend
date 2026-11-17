import { Controller } from "@hotwired/stimulus"

// One room card on the rooming wizard's assignments step: click the name to
// rename it, and the card's buttons (delete the room, add or remove staff,
// acknowledge a pairing).
//
// The card is re-rendered by turbo streams after most changes; a fresh card
// connects a fresh controller, so there is nothing to re-bind. The card owns
// the interaction and asks for the change with an event; the page's
// rooming-assignments controller (or, for adding staff, the staff modal)
// makes the request:
//   rooming-room:rename        { roomId, name }
//   rooming-room:delete        { roomId, card }
//   rooming-room:remove-staff  { roomId, staffName }
//   rooming-room:acknowledge   { assignmentId }
//   rooming-room:add-staff     { roomId }
//
// The room id is the card's own data-room-id.
export default class extends Controller {
  static targets = ["nameDisplay", "nameInput"]

  get roomId() {
    return this.element.dataset.roomId
  }

  editName() {
    this.showNameInput(true)
    this.nameInputTarget.focus()
    this.nameInputTarget.select()
  }

  // Enter saves by leaving the field; Escape puts the saved name back.
  nameKey(event) {
    if (event.key === "Enter") {
      event.preventDefault()
      this.nameInputTarget.blur()
    } else if (event.key === "Escape") {
      event.preventDefault()
      this.nameInputTarget.value = this.nameInputTarget.defaultValue
      this.showNameInput(false)
    }
  }

  saveName() {
    this.showNameInput(false)

    const name = this.nameInputTarget.value
    if (name === this.nameInputTarget.defaultValue) return

    this.dispatch("rename", { detail: { roomId: this.roomId, name } })
  }

  delete() {
    if (!confirm("Delete this room?")) return

    this.dispatch("delete", { detail: { roomId: this.roomId, card: this.element } })
  }

  removeStaff({ currentTarget }) {
    const staffName = currentTarget.dataset.staffName
    if (!confirm(`Remove ${staffName} from this room?`)) return

    this.dispatch("remove-staff", { detail: { roomId: this.roomId, staffName } })
  }

  acknowledge({ currentTarget }) {
    this.dispatch("acknowledge", { detail: { assignmentId: currentTarget.dataset.acknowledgeTransNb } })
  }

  addStaff() {
    this.dispatch("add-staff", { detail: { roomId: this.roomId } })
  }

  showNameInput(editing) {
    this.nameDisplayTarget.classList.toggle("hidden", editing)
    this.nameInputTarget.classList.toggle("hidden", !editing)
  }
}
