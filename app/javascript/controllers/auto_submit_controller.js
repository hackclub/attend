import { Controller } from "@hotwired/stimulus"

// Submits the form as soon as a filter changes, so there's no Filter button
// to press. Text input is debounced so each keystroke isn't a request.
//
// The page morphs on these submits (turbo_refreshes_with :morph), so the
// form, its controls and this controller stay in place: focus, caret and
// anything typed while results load all carry over.
export default class extends Controller {
  static targets = ["search"]
  static values = { delay: { type: Number, default: 300 } }

  // Back restores a cached copy of the page with the controls as they were
  // left, which can be a filter that never ran. Show what the results were
  // filtered by instead.
  connect() {
    this.element.reset()
  }

  disconnect() {
    this.cancel()
  }

  // A link, another form or Back/Forward drops a search that hasn't been
  // sent yet, so it can't abort what the user just started.
  cancel() {
    clearTimeout(this.debounceTimer)
    this.debounceTimer = null
  }

  // Keep what's being typed when results for an earlier search arrive. The
  // field's default still follows the results, which is what connect()
  // resets to on Back.
  keepTypedSearch({ detail: { newElement } }) {
    if (document.activeElement !== this.searchTarget && !this.debounceTimer) return

    this.searchTarget.defaultValue = newElement.defaultValue
    newElement.value = this.searchTarget.value
  }

  // Leave empty filters out of the URL.
  dropBlank({ formData }) {
    for (const [name, value] of [...formData]) {
      if (value === "") formData.delete(name)
    }
  }

  submit() {
    this.element.requestSubmit()
  }

  debouncedSubmit(event) {
    this.cancel()
    // Wait for IME and dead-key input to be committed before searching.
    if (event.isComposing) return

    this.debounceTimer = setTimeout(() => {
      this.debounceTimer = null
      if (this.query() !== location.search) this.element.requestSubmit()
    }, this.delayValue)
  }

  query() {
    const params = new URLSearchParams(new FormData(this.element)).toString()
    return params ? `?${params}` : ""
  }
}
