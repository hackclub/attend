import { Controller } from "@hotwired/stimulus"

// Set when a debounced search submits, so the re-rendered page can put the
// cursor back in the search field and typing carries on uninterrupted.
let refocusSearch = false

// Submits the form as soon as a filter changes, so there's no Filter button
// to press. Text input is debounced so each keystroke isn't a request.
export default class extends Controller {
  static targets = ["search"]
  static values = { delay: { type: Number, default: 300 } }

  connect() {
    if (refocusSearch && this.hasSearchTarget) {
      const end = this.searchTarget.value.length
      this.searchTarget.focus()
      this.searchTarget.setSelectionRange(end, end)
    }
    refocusSearch = false
  }

  disconnect() {
    if (this.debounceTimer) clearTimeout(this.debounceTimer)
  }

  submit() {
    if (this.debounceTimer) clearTimeout(this.debounceTimer)
    this.element.requestSubmit()
  }

  debouncedSubmit() {
    if (this.debounceTimer) clearTimeout(this.debounceTimer)
    this.debounceTimer = setTimeout(() => {
      refocusSearch = this.hasSearchTarget && document.activeElement === this.searchTarget
      this.element.requestSubmit()
    }, this.delayValue)
  }
}
