import { Controller } from "@hotwired/stimulus"
import { roomingRequest, renderStream, errorMessage } from "utils/rooming_request"

// The "Add staff" modal on the rooming wizard's assignments step. A room
// card opens it with a rooming-room:add-staff event carrying its room id;
// submitting adds the name to that room and renders the turbo stream that
// re-draws the card and the summary bar.
//
// Closing is the page-wide data-hide helper (utils/toggle_hidden). In the
// console the form also carries cs-form-validation, which stops an empty
// submit before it reaches this controller.
export default class extends Controller {
  static targets = ["roomId", "name"]
  static values = { url: String }

  open({ detail: { roomId } }) {
    this.roomIdTarget.value = roomId
    this.nameTarget.value = ""
    this.element.classList.remove("hidden")
    this.nameTarget.focus()
  }

  async submit(event) {
    event.preventDefault()

    const staffName = this.nameTarget.value.trim()
    if (!staffName) {
      alert("Please enter a staff name")
      return
    }

    const response = await roomingRequest(this.urlValue, {
      body: { room_id: this.roomIdTarget.value, staff_name: staffName }, stream: true
    })
    if (response.ok) {
      this.element.classList.add("hidden")
      await renderStream(response)
    } else {
      alert(await errorMessage(response, "Failed to add staff"))
    }
  }
}
