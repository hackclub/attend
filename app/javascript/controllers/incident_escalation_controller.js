import { Controller } from "@hotwired/stimulus"

// Reveals the HQ escalation fields when the organizer ticks "Escalate to
// Hack Club HQ", and asks for confirmation before a form escalates.
//
// On the new-incident form the checkbox decides whether the submit escalates.
// The standalone escalate form on an incident's page always does, and says so
// with data-incident-escalation-always-value="true". The edit form has
// neither, so it never confirms.
export default class extends Controller {
  static targets = ["checkbox", "fields"]
  static values = { always: Boolean, level: String }

  connect() {
    this.toggle()
  }

  toggle() {
    if (!this.hasCheckboxTarget || !this.hasFieldsTarget) return
    const on = this.checkboxTarget.checked
    this.fieldsTarget.classList.toggle("hidden", !on)
    this.fieldsTarget.querySelectorAll("input, select").forEach((el) => { el.disabled = !on })
  }

  escalating() {
    if (this.alwaysValue) return true
    return this.hasCheckboxTarget && this.checkboxTarget.checked
  }

  confirm(event) {
    if (!this.escalating()) return
    const level = this.element.querySelector("select[name='incident[severity]']")?.value || this.levelValue
    const line = level === "s0"
      ? "S0 pages Hack Club HQ's safeguarding team by phone right now. Continue?"
      : "This files a confidential report with Hack Club HQ's safeguarding team. Continue?"
    if (!window.confirm(line)) event.preventDefault()
  }
}
