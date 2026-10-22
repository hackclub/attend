import { Controller } from "@hotwired/stimulus"

// The search a debounced submit sent, so the page it renders can pick up
// where typing left off: cursor back in the field, and anything typed while
// it loaded put back and searched for in turn.
let lastSearch = null

// Submits the form as soon as a filter changes, so there's no Filter button
// to press. Text input is debounced so each keystroke isn't a request.
export default class extends Controller {
  static targets = ["search"]
  static values = { delay: { type: Number, default: 300 } }

  connect() {
    const search = lastSearch
    lastSearch = null
    if (!search || !this.hasSearchTarget || location.search !== search.query) return

    if (search.unsent !== undefined) {
      this.searchTarget.value = search.unsent
      this.debouncedSubmit()
    }
    if (search.refocus) {
      const end = this.searchTarget.value.length
      this.searchTarget.focus()
      this.searchTarget.setSelectionRange(end, end)
    }
  }

  disconnect() {
    if (this.debounceTimer && lastSearch) lastSearch.unsent = this.searchTarget.value
    this.cancel()
  }

  // Following a link drops a search that hasn't been sent yet, so it can't
  // take over the navigation.
  cancel() {
    clearTimeout(this.debounceTimer)
    this.debounceTimer = null
  }

  submit() {
    this.cancel()
    this.element.requestSubmit()
  }

  debouncedSubmit() {
    this.cancel()
    this.debounceTimer = setTimeout(() => {
      this.debounceTimer = null
      if (this.hasSearchTarget) {
        lastSearch = {
          query: `?${new URLSearchParams(new FormData(this.element))}`,
          refocus: document.activeElement === this.searchTarget
        }
      }
      this.element.requestSubmit()
    }, this.delayValue)
  }
}
