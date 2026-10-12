import { Controller } from "@hotwired/stimulus"

// Cloudscape inline edit for one table cell
// (cloudscape.design/patterns/resource-management/edit/inline-edit). The cell
// renders a read view (value + pencil, or a lock when it can't be edited) and
// a hidden form. Choosing the value swaps in the form; Enter or the confirm
// icon submits, Escape, the dismiss icon, or choosing elsewhere discards. The
// server answers with the whole cell as a turbo stream: back in read mode
// with a success icon, or still editing with the error under the control.
// Only one cell edits at a time.
const OPEN_EVENT = "cs-inline-edit:open"

export default class extends Controller {
  static targets = ["read", "form", "trigger", "input", "cancel", "submit", "submitIcon", "spinner", "reason", "error"]
  static values = { editing: Boolean, focus: Boolean, original: String }

  connect() {
    this.closeOthers = (event) => { if (event.detail !== this.element) this.discard() }
    this.clickAway = (event) => { if (!this.element.contains(event.target)) this.discard() }
    window.addEventListener(OPEN_EVENT, this.closeOthers)

    if (this.editingValue) this.listenForClickAway()
    if (this.focusValue) {
      const target = this.editingValue ? this.inputTarget : this.triggerTarget
      target.focus()
    }
  }

  disconnect() {
    window.removeEventListener(OPEN_EVENT, this.closeOthers)
    document.removeEventListener("pointerdown", this.clickAway, true)
  }

  edit() {
    window.dispatchEvent(new CustomEvent(OPEN_EVENT, { detail: this.element }))
    this.readTarget.hidden = true
    this.formTarget.hidden = false
    this.inputTarget.focus()
    this.listenForClickAway()
  }

  cancel() {
    if (this.discard()) this.triggerTarget.focus()
  }

  keydown(event) {
    if (event.key === "Escape") {
      event.preventDefault()
      this.cancel()
    } else if (event.key === "Enter" && event.target === this.inputTarget) {
      // A native select doesn't submit its form on Enter.
      event.preventDefault()
      this.formTarget.requestSubmit()
    }
  }

  submitting() {
    this.busy = true
    // Turbo has already read the form, so disabling the select doesn't drop it.
    this.inputTarget.disabled = true
    this.cancelTarget.disabled = true
    this.submitTarget.disabled = true
    this.submitTarget.setAttribute("aria-label", "Submitting")
    this.submitIconTarget.hidden = true
    this.spinnerTarget.hidden = false
  }

  // A successful or failed response replaces this cell. This only runs on its
  // own when the request never got an answer (network error), so put the
  // controls back and let the admin try again.
  submitted({ detail }) {
    if (detail.success || detail.fetchResponse) return
    this.busy = false
    this.inputTarget.disabled = false
    this.cancelTarget.disabled = false
    this.submitTarget.disabled = false
    this.submitTarget.setAttribute("aria-label", "Submit")
    this.submitIconTarget.hidden = false
    this.spinnerTarget.hidden = true
  }

  toggleReason() {
    this.reasonTarget.hidden = !this.reasonTarget.hidden
    if (!this.reasonTarget.hidden) this.listenForClickAway()
  }

  // Returns true when there was something to close.
  discard() {
    if (this.busy) return false
    document.removeEventListener("pointerdown", this.clickAway, true)

    if (this.hasReasonTarget) {
      const wasOpen = !this.reasonTarget.hidden
      this.reasonTarget.hidden = true
      return wasOpen
    }
    if (this.formTarget.hidden) return false

    // After a failed submit the select holds the rejected choice; discarding
    // goes back to the saved role and drops the error.
    this.inputTarget.value = this.originalValue
    this.inputTarget.removeAttribute("aria-invalid")
    this.inputTarget.removeAttribute("aria-describedby")
    this.errorTargets.forEach((error) => error.remove())
    this.formTarget.hidden = true
    this.readTarget.hidden = false
    return true
  }

  listenForClickAway() {
    document.addEventListener("pointerdown", this.clickAway, true)
  }
}
