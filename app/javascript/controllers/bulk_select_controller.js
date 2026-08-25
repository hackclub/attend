import { Controller } from "@hotwired/stimulus"

// Drives the "select tickets, then close them together" toolbar on the support
// inbox. Rows are swapped in and out by Turbo broadcasts, so the tally is
// recalculated whenever a checkbox target connects or disconnects.
export default class extends Controller {
  static targets = ["checkbox", "selectAll", "bar", "count"]

  connect() {
    this.refresh()
  }

  checkboxTargetConnected() {
    this.refresh()
  }

  checkboxTargetDisconnected() {
    this.refresh()
  }

  toggleAll() {
    this.checkboxTargets.forEach((box) => { box.checked = this.selectAllTarget.checked })
    this.refresh()
  }

  toggle() {
    this.refresh()
  }

  refresh() {
    const total = this.checkboxTargets.length
    const selected = this.selectedCount

    if (this.hasSelectAllTarget) {
      this.selectAllTarget.checked = total > 0 && selected === total
      this.selectAllTarget.indeterminate = selected > 0 && selected < total
      this.selectAllTarget.disabled = total === 0
    }

    if (this.hasBarTarget) this.barTarget.classList.toggle("hidden", selected === 0)
    if (this.hasCountTarget) this.countTarget.textContent = `${selected} ${this.noun(selected)} selected`
  }

  confirmClose(event) {
    const selected = this.selectedCount

    if (selected === 0 || !window.confirm(`Close ${selected} ${this.noun(selected)}?`)) {
      event.preventDefault()
    }
  }

  get selectedCount() {
    return this.checkboxTargets.filter((box) => box.checked).length
  }

  noun(count) {
    return count === 1 ? "ticket" : "tickets"
  }
}
