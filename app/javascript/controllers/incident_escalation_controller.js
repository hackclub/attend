import { Controller } from "@hotwired/stimulus"

// Reveals the HQ escalation fields when the organizer ticks "Escalate to
// Hack Club HQ", and asks for confirmation before the form sends it.
export default class extends Controller {
  static targets = ["checkbox", "fields"]

  connect() {
    this.toggle()
  }

  toggle() {
    if (!this.hasCheckboxTarget || !this.hasFieldsTarget) return
    const on = this.checkboxTarget.checked
    this.fieldsTarget.classList.toggle("hidden", !on)
    this.fieldsTarget.querySelectorAll("input, select").forEach((el) => { el.disabled = !on })
  }

  confirm(event) {
    if (this.hasCheckboxTarget && !this.checkboxTarget.checked) return
    const level = this.element.querySelector("select[name='incident[severity]']")?.value || this.element.dataset.incidentLevel
    const line = level === "s0"
      ? "S0 pages Hack Club HQ's safeguarding team by phone right now. Continue?"
      : "This files a confidential report with Hack Club HQ's safeguarding team. Continue?"
    if (!window.confirm(line)) event.preventDefault()
  }
}
